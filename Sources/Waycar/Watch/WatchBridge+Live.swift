import Foundation
import UIKit

extension WatchStateSource {
    /// The app's Console and Host catalog now. `HostStore.hosts` rather
    /// than the Console's catalog, which observation does not track.
    @MainActor
    static func live(_ model: WaycarAppModel, voiceTranscription: Bool) -> WatchStateSource {
        reading(
            console: model.console, hosts: model.hostStore.hosts,
            voiceTranscription: voiceTranscription,
            isSuspended: model.activity.phase == .suspended)
    }

    /// `console`'s verified Agents, shells left out, over `hosts`.
    @MainActor
    static func reading(
        console: ConsoleStore, hosts: [Host], voiceTranscription: Bool, isSuspended: Bool = false
    ) -> WatchStateSource {
        let agents = console.verifiedAgents.excludingShells
        return WatchStateSource(
            agents: agents,
            hosts: hosts,
            statuses: console.hostStatuses,
            awaitingSnapshot: console.hostsAwaitingSnapshot,
            chatModeAgents: Set(agents.filter { console.isChatMode($0) }.map(\.id)),
            voiceTranscription: voiceTranscription,
            isSuspended: isSuspended)
    }
}

extension WatchBridge.Dependencies {
    /// The app's own: `model` builds the app model on first use, so a
    /// watch request that launched the app in the background starts it.
    @MainActor
    static func live(model: @escaping @MainActor () -> WaycarAppModel) -> Self {
        let transcriber = DictationEngines.fileTranscriber
        let voiceTranscription = transcriber != nil
        let backgroundTime = WatchBackgroundTime()
        return Self(
            source: { WatchStateSource.live(model(), voiceTranscription: voiceTranscription) },
            keychainReadable: { KeychainReadability.isReadable() },
            lastReply: { agent in
                let started = ContinuousClock.now
                WatchLog.logger.notice("transcript read started")
                let transcript: ChatTranscriptSnapshot
                do {
                    transcript = try await model().console.readChatTranscript(for: agent, after: nil)
                } catch {
                    let nsError = error as NSError
                    WatchLog.logger.error(
                        "transcript read failed in \(WatchLog.milliseconds(since: started), privacy: .public) ms: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
                    return nil
                }
                let reply = WatchStateBuilder.lastReply(from: transcript)
                let textBytes = transcript.messages.reduce(0) { $0 + $1.text.utf8.count }
                WatchLog.logger.notice(
                    "transcript read in \(WatchLog.milliseconds(since: started), privacy: .public) ms: \(transcript.messages.count, privacy: .public) messages, \(textBytes, privacy: .public) text bytes, last reply \(reply?.utf8.count ?? 0, privacy: .public) bytes")
                return reply
            },
            blockedPrompt: { id in try await model().agentActions.blockedPrompt(for: id) },
            answer: { allow, id, snapshot in
                await model().agentActions.answer(allow: allow, agentID: id, shown: snapshot)
            },
            send: { text, id in await model().agentActions.send(text, to: id, suffix: nil) },
            transcriber: transcriber,
            hold: { onExpiration in
                // Background time first: the headless start below can take a
                // while on a cold launch, and the app must not freeze in it.
                backgroundTime.begin(onExpiration: onExpiration)
                let started = ContinuousClock.now
                let app = model()
                // Idempotent; safe without a window, as the CarPlay-only
                // launch already relies on.
                app.start()
                app.watchDidBecomeActive()
                WatchLog.logger.notice(
                    "app held for the watch; headless start took \(WatchLog.milliseconds(since: started), privacy: .public) ms")
            },
            release: {
                model().watchDidEnterBackground()
                backgroundTime.end()
            },
            now: { Date() })
    }
}

/// The background time a watch request runs on while the app is not in
/// the foreground. One assertion at a time: the bridge holds it from its
/// first hold to its last release.
@MainActor
final class WatchBackgroundTime {
    /// The running background task, or `.invalid`.
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    /// Takes background time; `onExpiration` runs on the main actor shortly
    /// before the system takes it back, and the assertion is ended then.
    func begin(onExpiration: @escaping @MainActor @Sendable () -> Void) {
        end()
        identifier = UIApplication.shared.beginBackgroundTask(
            withName: "com.otreva.waycar.watch-request"
        ) { @Sendable in
            WatchLog.logger.error("watch background task expiring")
            // UIKit calls this on the main thread; run synchronously so the
            // ran-out-of-time replies leave before the handler returns.
            MainActor.assumeIsolated {
                onExpiration()
            }
        }
        let application = UIApplication.shared
        guard identifier != .invalid else {
            WatchLog.logger.error(
                "no background time granted for a watch request, app state \(application.applicationState.rawValue, privacy: .public)")
            return
        }
        WatchLog.logger.notice(
            "watch background task \(self.identifier.rawValue, privacy: .public) began, app state \(application.applicationState.rawValue, privacy: .public), \(WatchLog.backgroundTime(application.backgroundTimeRemaining), privacy: .public) background time left")
    }

    /// Gives the background time back.
    func end() {
        guard identifier != .invalid else { return }
        WatchLog.logger.notice("watch background task \(self.identifier.rawValue, privacy: .public) ended")
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
