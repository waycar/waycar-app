import Foundation
import UIKit
import WatchConnectivity

// MARK: Seam

/// The `WCSession` calls `WatchBridge` makes, so its routing runs against
/// a fake in tests.
@MainActor
protocol WatchSessionChannel: AnyObject {
    /// Whether a watch is paired and has Waycar installed: only then is a
    /// Watch State worth publishing.
    var canPublish: Bool { get }
    /// Whether the watch app is running and reachable for live messages.
    var isReachable: Bool { get }
    /// The encoded `WatchState` last published, which the system keeps
    /// across launches; nil before activation or when none was published.
    var lastApplicationContext: Data? { get }
    /// Starts the session; the bridge's receive calls follow from then on.
    func activate()
    /// Replaces the application context with one encoded `WatchState`.
    func updateApplicationContext(_ state: Data) throws
    /// Sends one encoded `WatchEvent` to the running watch app; `onFailure`
    /// runs on the main actor when it did not get there.
    func sendMessageData(_ event: Data, onFailure: @escaping @MainActor @Sendable () -> Void)
    /// Queues one encoded `WatchEvent` for whenever the watch app next runs.
    func transferUserInfo(_ event: Data)
}

// MARK: WatchConnectivity

/// `WCSession.default` behind `WatchSessionChannel`, and its delegate.
///
/// WatchConnectivity calls the delegate on a background queue. Each
/// callback copies out what it needs there (a received file must be moved
/// before the callback returns, or the system deletes it), then hops to
/// the main queue in arrival order and hands the bridge Sendable values
/// only. The reply handler is not annotated Sendable; WatchConnectivity
/// accepts it from any thread, so it crosses boxed and is called once.
@MainActor
final class ConnectivityWatchSession: NSObject, WCSessionDelegate, WatchSessionChannel {
    /// Where received events go. Set before `activate()`.
    weak var receiver: WatchBridge?

    /// Whether this device can pair with an Apple Watch at all (false on iPad).
    nonisolated static var isSupported: Bool { WCSession.isSupported() }

    /// Activated, paired, and the watch app installed.
    var canPublish: Bool {
        let session = WCSession.default
        return session.activationState == .activated && session.isPaired
            && session.isWatchAppInstalled
    }

    /// Activated and the watch app reachable now.
    var isReachable: Bool {
        let session = WCSession.default
        return session.activationState == .activated && session.isReachable
    }

    /// The Watch State the system kept from the last publish, by any run.
    var lastApplicationContext: Data? {
        let session = WCSession.default
        guard session.activationState == .activated else { return nil }
        return session.applicationContext[WatchWireCodec.applicationContextKey] as? Data
    }

    /// Installs this delegate and activates `WCSession.default`.
    func activate() {
        guard WCSession.isSupported() else {
            WatchLog.logger.notice("WCSession is not supported on this device")
            return
        }
        // Nothing is pending before activation: a recording an earlier
        // run kept and never transcribed is an orphan.
        WatchRecordingFiles.removeAll()
        WCSession.default.delegate = self
        WCSession.default.activate()
        WatchLog.logger.notice("WCSession activating")
    }

    /// Publishes the Watch State under `applicationContextKey`.
    func updateApplicationContext(_ state: Data) throws {
        try WCSession.default.updateApplicationContext([WatchWireCodec.applicationContextKey: state])
    }

    /// A live message; a failure falls back to `onFailure`.
    func sendMessageData(_ event: Data, onFailure: @escaping @MainActor @Sendable () -> Void) {
        // `@Sendable`, so the handler is not taken as main-actor isolated:
        // WatchConnectivity calls it on its own queue.
        WCSession.default.sendMessageData(event, replyHandler: nil) { @Sendable error in
            let nsError = error as NSError
            WatchLog.logger.notice(
                "live event failed, queueing it instead: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
            DispatchQueue.main.async { MainActor.assumeIsolated { onFailure() } }
        }
    }

    /// A queued transfer under `userInfoKey`.
    func transferUserInfo(_ event: Data) {
        WCSession.default.transferUserInfo([WatchWireCodec.userInfoKey: event])
    }

    // MARK: WCSessionDelegate

    /// Activation finished: the bridge publishes and reads reachability.
    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let isReachable = session.isReachable
        if let error {
            let nsError = error as NSError
            WatchLog.logger.error(
                "WCSession activation \(activationState.rawValue, privacy: .public) failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public) \(nsError.localizedDescription, privacy: .private)")
        }
        WatchLog.logger.notice(
            "WCSession activation \(activationState.rawValue, privacy: .public): paired \(session.isPaired, privacy: .public), watch app installed \(session.isWatchAppInstalled, privacy: .public), reachable \(isReachable, privacy: .public)")
        onMain { $0.sessionDidActivate(isReachable: isReachable) }
    }

    /// Nothing to do: the session deactivates next.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        WatchLog.logger.notice("WCSession became inactive")
    }

    /// The user switched watches: activate again for the new one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WatchLog.logger.notice("WCSession deactivated; activating again")
        DispatchQueue.main.async { WCSession.default.activate() }
    }

    /// The watch app came to the foreground or left it.
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        WatchLog.logger.notice("WCSession reachable \(isReachable, privacy: .public)")
        onMain { $0.reachabilityDidChange(isReachable) }
    }

    /// Pairing or the watch app's installation changed.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        WatchLog.logger.notice(
            "WCSession watch state: paired \(session.isPaired, privacy: .public), watch app installed \(session.isWatchAppInstalled, privacy: .public)")
        onMain { $0.watchStateDidChange() }
    }

    /// A request expecting a reply.
    nonisolated func session(
        _ session: WCSession, didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        WatchLog.logger.notice("message of \(messageData.count, privacy: .public) bytes arrived, reply expected")
        let handler = ReplyHandler(send: replyHandler)
        onMain(timing: "message") { bridge in
            bridge.receive(messageData: messageData) { handler.send($0) }
        }
    }

    /// A request without a reply handler.
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        WatchLog.logger.notice("message of \(messageData.count, privacy: .public) bytes arrived, no reply")
        onMain(timing: "message") { $0.receive(messageData: messageData, reply: nil) }
    }

    /// A voice recording, moved out of the inbox before returning.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata?[WatchWireCodec.fileMetadataKey] as? Data
        let kept = WatchRecordingFiles.keep(file.fileURL)
        WatchLog.logger.notice(
            "recording file arrived: kept \(kept != nil, privacy: .public), metadata \(metadata != nil, privacy: .public)")
        onMain(timing: "recording") { $0.receive(recordingAt: kept, metadata: metadata) }
    }

    /// Runs `body` on the main queue, in callback order, with the bridge.
    /// With `timing`, logs how long the hop waited (a main thread busy
    /// elsewhere delays every reply) and the app's state and background
    /// time left (an app about to freeze cannot finish a request).
    private nonisolated func onMain(
        timing label: String? = nil, _ body: @escaping @MainActor @Sendable (WatchBridge) -> Void
    ) {
        let queued = ContinuousClock.now
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let label {
                    let application = UIApplication.shared
                    WatchLog.logger.notice(
                        "\(label, privacy: .public) reached the main queue after \(WatchLog.milliseconds(since: queued), privacy: .public) ms; app state \(application.applicationState.rawValue, privacy: .public), \(WatchLog.backgroundTime(application.backgroundTimeRemaining), privacy: .public) background time left")
                }
                guard let receiver = self.receiver else {
                    WatchLog.logger.error("no watch bridge: a WCSession callback was dropped")
                    return
                }
                body(receiver)
            }
        }
    }
}

/// WatchConnectivity's reply handler, carried to the main actor and
/// called there exactly once.
private struct ReplyHandler: @unchecked Sendable {
    /// The handler WatchConnectivity gave the delegate.
    let send: (Data) -> Void
}

// MARK: Recordings

/// Received watch recordings, moved out of WatchConnectivity's inbox into
/// the app's temporary directory until transcribed, then deleted.
enum WatchRecordingFiles {
    /// The directory recordings wait in.
    static var directory: URL {
        FileManager.default.temporaryDirectory.appending(
            path: "WatchRecordings", directoryHint: .isDirectory)
    }

    /// Moves a just-received file out of the inbox, synchronously; nil
    /// when that failed (the recording is then lost, and the bridge's wait
    /// reports it as not sent).
    static func keep(_ url: URL) -> URL? {
        let fileManager = FileManager.default
        let directory = directory
        let name = url.pathExtension.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(url.pathExtension)"
        let destination = directory.appending(path: name, directoryHint: .notDirectory)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.moveItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// Deletes one recording.
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes every kept recording.
    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
