import Foundation
import Observation
import os
import UIKit

/// The app's *effective* activity, which is deliberately not `scenePhase`.
///
/// Backgrounding opens a grace period: the app keeps running under a UIKit
/// background-execution assertion and holds its Host connections, so glancing
/// at another app, pulling down the notification shade, or answering a
/// message costs nothing on return. Only when the grace period elapses — or
/// the system reclaims its time — does the app consider itself suspended and
/// quiesce the connections: their channels close, while each Host's SSH
/// connection stays open for the return to probe (#105; iOS freezes the
/// sockets anyway once the process is suspended).
enum AppActivityPhase: Sendable, Equatable {
    case active
    case suspended
}

/// What the coordinator hands whoever drives the Host connections.
///
/// Deliberately a stream of events rather than an observation of `phase`.
/// The suspension is produced by a timer *while the app is in the background
/// and drawing nothing*, and the foreground return that follows can land in
/// the same update cycle, so a consumer that only compares the value it last
/// saw can miss the round trip entirely — and with it both the teardown and
/// the resume. That is #142: the app came back holding a connection nothing
/// had torn down and nothing had asked whether it was still alive, so a
/// session whose link died while the app was away kept rendering as
/// connected — no reconnect, no error — until the keepalive got round to
/// noticing, up to its interval plus a request timeout later.
///
/// `activated` is reported on *every* return to the foreground, not only
/// after a suspension: a connection frozen along with the process may have
/// died in the meantime without anything having asked it.
enum AppActivityEvent: Sendable, Equatable {
    case activated
    case suspended
}

/// A UIKit background-execution assertion, reduced to what the coordinator
/// needs so it can be tested without a running `UIApplication`.
struct BackgroundExecutionToken: Hashable, Sendable {
    let rawValue: Int
}

/// What holds the app in the foreground. The app is active while any source
/// is, and the grace period starts only once every source has left.
///
/// SwiftUI's aggregate `scenePhase` covers the app's windows only: with the
/// phone locked and Waycar on the car's screen it reads `.background`, yet
/// iOS keeps the process running for the CarPlay scene. Fed the phase
/// alone, the grace period tore the Host connections down 20 seconds into
/// every drive (docs/design/carplay.md §6).
enum AppActivitySource: Hashable, Sendable {
    /// The phone or iPad windows, through the aggregate scene phase.
    case phone
    /// The CarPlay template scene in the foreground on the car's screen.
    case carPlay
    /// The Apple Watch app: held while it is reachable, and for the length
    /// of each watch request the phone answers headless (`WatchBridge`).
    case watch
}

@MainActor
protocol BackgroundExecutionGranting: AnyObject {
    /// Asks the system for background execution time. Returns nil when the
    /// request is refused, in which case there is no grace period to be had.
    /// `onExpiration` runs on the main actor shortly before the system takes
    /// the time back; the assertion must be ended from it or the app is
    /// killed.
    func begin(
        onExpiration: @escaping @MainActor @Sendable () -> Void
    ) -> BackgroundExecutionToken?

    func end(_ token: BackgroundExecutionToken)

    /// The background execution time the app has left while it holds an
    /// assertion.
    var backgroundTimeRemaining: Duration { get }
}

@MainActor
final class UIKitBackgroundExecutionGranter: BackgroundExecutionGranting {
    func begin(
        onExpiration: @escaping @MainActor @Sendable () -> Void
    ) -> BackgroundExecutionToken? {
        let identifier = UIApplication.shared.beginBackgroundTask(
            withName: "com.otreva.waycar.background-grace"
        ) {
            // UIKit calls this on the main thread but the API is not
            // annotated for it, so hop deliberately instead of asserting an
            // isolation the compiler cannot check.
            Task { @MainActor in onExpiration() }
        }
        guard identifier != .invalid else { return nil }
        return BackgroundExecutionToken(rawValue: identifier.rawValue)
    }

    func end(_ token: BackgroundExecutionToken) {
        UIApplication.shared.endBackgroundTask(
            UIBackgroundTaskIdentifier(rawValue: token.rawValue))
    }

    var backgroundTimeRemaining: Duration {
        // A foreground app reads `.greatestFiniteMagnitude`, which no
        // `Duration` holds; nothing here asks before backgrounding anyway.
        let seconds = UIApplication.shared.backgroundTimeRemaining
        guard seconds.isFinite else { return .seconds(3600) }
        return .seconds(min(max(seconds, 0), 3600))
    }
}

/// Turns foreground edges from every `AppActivitySource` into
/// `AppActivityPhase`, holding a background execution assertion for the
/// length of the grace period. No assertion is asked for while any source
/// is still in the foreground.
///
/// The assertion outlives the phase change on purpose: it is released only
/// once the observer reports its teardown finished (`didFinishSuspending()`),
/// so the SSH connections close cleanly instead of being frozen mid-close.
/// The one exception is expiration, where the system wants its time back
/// immediately and holding on any longer would kill the app.
@MainActor
@Observable
final class AppActivityCoordinator {
    /// iOS grants a background-execution assertion on the order of 30
    /// seconds. Stopping well short of that keeps the deliberate teardown
    /// inside our own budget rather than racing the expiration handler.
    static let defaultGracePeriod: Duration = .seconds(20)

    private var activity: AppActivityMachine

    var phase: AppActivityPhase { activity.phase }

    /// Increments on every foreground return, whether or not the grace period
    /// ever reached `.suspended`.
    ///
    /// `phase` cannot carry that signal. A background→foreground round trip
    /// the grace period absorbs never leaves `.active`, so a SwiftUI
    /// `onChange` on the phase observes nothing and the return goes unnoticed
    /// — the same coalescing `events` exists to defeat. `events` has a single
    /// consumer by construction; screens that come and go need a value they
    /// can observe instead, and a monotonic counter is one no `onChange` can
    /// miss.
    var activationCount: UInt64 { activity.activationCount }

    /// Whether the most recent absence crossed a boundary where iOS could have
    /// suspended the process. This does not claim that suspension occurred or
    /// that any particular layer failed; it identifies when foreground-only
    /// resources can no longer be assumed to have survived (#141).
    ///
    /// An observed `.suspended` transition is conclusive for this policy. The
    /// duration is the fallback for the other real path: iOS freezes the
    /// process before the grace task runs, then the monotonic clock shows on
    /// return that the Background Grace Period elapsed while no Swift task ran.
    var lastAbsenceMayHaveSuspended: Bool { activity.lastAbsenceMayHaveSuspended }

    #if DEBUG
    /// Retained only for the on-device recovery diagnostic. Release behavior
    /// consumes `lastAbsenceMayHaveSuspended`, not this presentation detail.
    var lastAbsenceDuration: Duration? { activity.lastAbsenceDuration }
    #endif

    /// Every transition, in order and exactly once each. Buffered rather than
    /// latest-value: a background→foreground round trip that completes before
    /// the consumer gets to run must still produce both the teardown and the
    /// activation.
    @ObservationIgnored nonisolated let events: AsyncStream<AppActivityEvent>
    @ObservationIgnored
    private nonisolated let eventsContinuation: AsyncStream<AppActivityEvent>.Continuation
    @ObservationIgnored private let granter: any BackgroundExecutionGranting
    /// Injected so a test can state an absence instead of sleeping one.
    /// `ContinuousClock` on purpose: it keeps counting while the process is
    /// suspended, which `SuspendingClock` does not.
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant
    @ObservationIgnored private var grants: [UInt64: BackgroundExecutionToken] = [:]
    @ObservationIgnored private var graceTasks: [UInt64: Task<Void, Never>] = [:]

    init(
        gracePeriod: Duration = AppActivityCoordinator.defaultGracePeriod,
        granter: any BackgroundExecutionGranting = UIKitBackgroundExecutionGranter(),
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.activity = AppActivityMachine(gracePeriod: gracePeriod)
        self.granter = granter
        self.now = now
        (events, eventsContinuation) = AsyncStream.makeStream(
            of: AppActivityEvent.self, bufferingPolicy: .unbounded)
    }

    /// `source` came to the foreground. Every phone return re-proves the
    /// connections and bumps `activationCount`, as before: the windows'
    /// attach terminals key off it. A CarPlay scene joining an app the phone
    /// already holds active is no return; nothing was away.
    func didBecomeActive(_ source: AppActivitySource) {
        send(.becameActive(source, now: now()))
    }

    /// `source` left the foreground. The grace period starts only once no
    /// source is left: while CarPlay shows Waycar on the car's screen, a
    /// locked phone suspends nothing.
    func didEnterBackground(_ source: AppActivitySource) {
        send(.enteredBackground(source, now: now()))
    }

    /// The teardown that `.suspended` asked for has finished; the app no
    /// longer needs to stay awake. No-op after a foreground bounce beat the
    /// teardown home, or when expiration already took the assertion back.
    func didFinishSuspending() {
        send(.teardownFinished)
    }

    /// Whether the suspension's teardown may wait on the network (#105):
    /// only one the grace timer brought, with the background assertion still
    /// held. On the expiration path, without background time, and once the
    /// app is back, the teardown must quiesce locally: iOS freezes the
    /// process at any moment there (TN2277).
    var hasBackgroundTimeForTeardown: Bool {
        activity.hasBackgroundTimeForTeardown
    }

    /// How long work ahead of the suspension's teardown may run now (#105):
    /// at most `limit`, leaving `margin` of the background time for the
    /// teardown itself. Only a suspension the grace timer brought, with the
    /// assertion still held, has any; nil on the expiration path, without
    /// background time, and once the app is back — work there must not wait
    /// on the network (TN2277).
    func backgroundTimeBeforeTeardown(upTo limit: Duration, leaving margin: Duration) -> Duration? {
        guard hasBackgroundTimeForTeardown else { return nil }
        let available = granter.backgroundTimeRemaining - margin
        guard available > .zero else { return nil }
        return min(limit, available)
    }

    private func send(_ event: AppActivityMachine.Event) {
        for effect in activity.handle(event) {
            switch effect {
            case .beginGrace(let token):
                NetworkLog.logger.notice("background: grace period started")
                guard let grant = granter.begin(onExpiration: { [weak self] in
                    self?.send(.grantExpired(token))
                }) else {
                    send(.grantRefused(token))
                    continue
                }
                grants[token] = grant
                let grace = activity.gracePeriod
                graceTasks[token] = Task { [weak self] in
                    guard let self else { return }
                    do { try await Task.sleep(for: grace) } catch { return }
                    guard !Task.isCancelled else { return }
                    send(.graceElapsed(token))
                }
            case .cancelGrace(let token):
                graceTasks.removeValue(forKey: token)?.cancel()
            case .releaseGrant(let token):
                if let grant = grants.removeValue(forKey: token) { granter.end(grant) }
            case .activated(let absence, let crossedGrace, let instant):
                NetworkTelemetry.didReturn(after: absence, crossedGrace: crossedGrace, at: instant)
                eventsContinuation.yield(.activated)
            case .suspended:
                eventsContinuation.yield(.suspended)
                NetworkLog.logger.notice("background: suspending connections")
            }
        }
    }
}
