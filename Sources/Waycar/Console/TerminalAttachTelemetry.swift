import Foundation
import os

/// One terminal pipeline's attach attempts and mosh transport losses, as
/// the network telemetry counts them (#105). An attempt runs from its start
/// to live (`terminal_attach` success) or to its end trying (a failure
/// class, or `cancelled` when stopped or superseded). A live mosh session
/// lost while the pipeline reattaches by itself is reported once the next
/// attempt goes live (`transport_lost` with its recovery time) or once the
/// pipeline gives up (`never`). SSH losses are the Host session's to report:
/// the attach rides the Host's connection.
@MainActor
final class TerminalAttachTelemetry {
    private struct Attempt {
        let started: ContinuousClock.Instant
        let interval: NetworkInterval
        let foregroundReturn: ForegroundReturn?
        var transport: TerminalSessionFlavor?
        var route: TerminalAttachRoute?
    }

    private var attempt: Attempt?
    /// How the last attempt that went live was carried.
    private var liveTransport: TerminalSessionFlavor?
    private var loss: (reason: NetworkAnalytics.Failure, at: ContinuousClock.Instant)?
    private let now: @MainActor () -> ContinuousClock.Instant
    private let foregroundReturn: @MainActor (ContinuousClock.Instant) -> ForegroundReturn?
    private let record: @MainActor (AnalyticsEvent) -> Void

    init(
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
        foregroundReturn: @escaping @MainActor (ContinuousClock.Instant) -> ForegroundReturn? = {
            NetworkTelemetry.foregroundReturn(at: $0)
        },
        record: @escaping @MainActor (AnalyticsEvent) -> Void = { NetworkTelemetry.record($0) }
    ) {
        self.now = now
        self.foregroundReturn = foregroundReturn
        self.record = record
    }

    /// A new attempt starts; one still pending was superseded.
    func began() {
        finishAttempt(.failure(.cancelled))
        let started = now()
        attempt = Attempt(
            started: started, interval: NetworkInterval("terminal attach"),
            foregroundReturn: foregroundReturn(started))
    }

    func transportReady(_ flavor: TerminalSessionFlavor) {
        attempt?.transport = flavor
    }

    func routeResolved(_ route: TerminalAttachRoute) {
        attempt?.route = route
    }

    func wentLive() {
        liveTransport = attempt?.transport ?? liveTransport
        finishAttempt(.success)
        settleLoss(recovered: true)
    }

    /// The run ended by itself: cleanly (`error` nil) or failing.
    /// `restarting` when the pipeline reattaches on its own; otherwise a
    /// pending loss is given up on.
    func runEnded(_ error: (any Error)?, restarting: Bool) {
        if attempt != nil {
            finishAttempt(error.map(NetworkAnalytics.Outcome.init) ?? .failure(.channel))
        } else if let error, liveTransport == .mosh, loss == nil {
            let reason = NetworkAnalytics.Failure(error)
            NetworkLog.logger.notice("mosh transport lost: \(reason.rawValue, privacy: .public)")
            loss = (reason, now())
        }
        if !restarting {
            settleLoss(recovered: false)
        }
    }

    /// The pipeline was stopped: a pending attempt was cancelled, and a
    /// pending loss never recovered.
    func stopped() {
        finishAttempt(.failure(.cancelled))
        settleLoss(recovered: false)
    }

    private func finishAttempt(_ outcome: NetworkAnalytics.Outcome) {
        guard let attempt else { return }
        self.attempt = nil
        attempt.interval.end(outcome.value)
        let report = TerminalAttachReport(
            transport: attempt.transport, route: attempt.route, outcome: outcome,
            duration: now() - attempt.started, foregroundReturn: attempt.foregroundReturn)
        NetworkLog.logger.notice(
            "terminal attach \(outcome.value, privacy: .public) over \(attempt.transport?.rawValue ?? "none", privacy: .public) via \(attempt.route?.rawValue ?? "none", privacy: .public) in \(report.duration.wholeMilliseconds, privacy: .public) ms, background before: \(attempt.foregroundReturn?.absence.wholeMilliseconds ?? -1, privacy: .public) ms"
        )
        record(.terminalAttached(report))
    }

    private func settleLoss(recovered: Bool) {
        guard let loss else { return }
        self.loss = nil
        let elapsed = now() - loss.at
        NetworkLog.logger.notice(
            "mosh transport \(recovered ? "recovered" : "not recovered", privacy: .public) after \(elapsed.wholeMilliseconds, privacy: .public) ms"
        )
        record(
            .transportLost(
                TransportLossReport(
                    transport: .mosh, reason: loss.reason, recovery: recovered ? elapsed : nil)))
    }
}
