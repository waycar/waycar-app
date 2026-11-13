import Foundation
import WatchConnectivity

// MARK: - Phone link

/// Something the iPhone told the watch, already decoded from the wire.
enum WatchInbound: Sendable {
    /// A Watch State, from application context or a refresh.
    case state(WatchState)
    /// Whether the iPhone can take live messages right now.
    case reachability(Bool)
    /// A message's delivery outcome.
    case event(WatchEvent)
    /// A recording's file transfer failed, so the audio never reached the
    /// iPhone. `attempt` is the one `transferVoice` was given, nil when the
    /// transfer did not carry it.
    case voiceTransferFailed(messageID: UUID, agentID: WatchAgentID, attempt: UUID?)
    /// The iPhone's Watch State is in another wire version (`version`), so
    /// one of the two apps needs an update.
    case versionMismatch(Int)
}

/// The watch's only channel to its Hosts: everything goes through the
/// paired iPhone. `WatchSessionClient` is the real one; DEBUG demo mode
/// swaps in a local stand-in. Requests and recordings go through
/// `WatchMessageLink` (requests bounded by `WatchRequester`); `send` throws
/// `WatchLinkError` when no reply arrived and `WatchWireError` when the
/// reply did not decode.
@MainActor
protocol WatchPhoneLink: WatchMessageLink {
    /// Whether the iPhone can take live messages right now.
    var isReachable: Bool { get }
    /// Starts the link; `receive` gets every inbound value on the main
    /// actor, in arrival order.
    func activate(receiving receive: @escaping @MainActor (WatchInbound) -> Void)
}

// MARK: - WatchConnectivity client

/// The `WCSession` wrapper and delegate. WatchConnectivity calls the
/// delegate on its own serial queue: each callback decodes there, so only
/// Sendable wire values cross, and hands them to the main queue in arrival
/// order. Reply and error blocks are `@Sendable` closures that only resume
/// a continuation, so none of them inherits the main actor.
@MainActor
final class WatchSessionClient: NSObject, WatchPhoneLink {
    /// Whether the iPhone can take live messages now, read live from the
    /// session: false until activation completes.
    var isReachable: Bool { Self.isActivated && WCSession.default.isReachable }
    /// The store's inbound handler, set by `activate(receiving:)`.
    private var receive: (@MainActor (WatchInbound) -> Void)?

    /// Sets the delegate and activates the default session; call once,
    /// early in launch, so queued context and user info are not missed.
    func activate(receiving receive: @escaping @MainActor (WatchInbound) -> Void) {
        self.receive = receive
        guard WCSession.isSupported() else {
            WatchLog.logger.error("WCSession is not supported")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        WatchLog.logger.notice("WCSession activating")
    }

    /// Encodes `request`, sends it with `sendMessageData`, and decodes the
    /// reply. Throws `WatchLinkError.unreachable` at once, sending nothing,
    /// until activation completes (sending before is a programmer error in
    /// WatchConnectivity) or while the iPhone is not reachable. Waits as
    /// long as WatchConnectivity does: `WatchRequester` bounds it.
    func send(_ request: WatchRequest) async throws -> WatchReply {
        let session = WCSession.default
        guard Self.isActivated, session.isReachable else {
            WatchLog.logger.notice(
                "\(request.logType, privacy: .public) not sent: activation \(session.activationState.rawValue, privacy: .public), reachable \(session.isReachable, privacy: .public)")
            throw WatchLinkError.unreachable
        }
        let data = try WatchWireCodec.encode(request)
        let reply: Data
        do {
            reply = try await Self.exchange(data)
        } catch {
            let code = (error as NSError).code
            WatchLog.logger.error(
                "\(request.logType, privacy: .public) sendMessageData failed: \((error as NSError).domain, privacy: .public) \(code, privacy: .public)")
            if let error = error as? WCError, Self.unreachableCodes.contains(error.code) {
                throw WatchLinkError.unreachable
            }
            throw WatchLinkError.noAnswer
        }
        do {
            return try WatchWireCodec.decode(WatchReply.self, from: reply)
        } catch {
            WatchLog.logger.error(
                "\(request.logType, privacy: .public) reply of \(reply.count, privacy: .public) bytes did not decode")
            throw error
        }
    }

    /// Queues the recording with its `WatchVoiceFile` metadata and the
    /// watch-local attempt tag. The system delivers it in the background
    /// even if the app suspends.
    func transferVoice(fileAt url: URL, file: WatchVoiceFile, attempt: UUID) throws {
        guard Self.isActivated else { throw WatchLinkError.unreachable }
        let metadata = try WatchWireCodec.encode(file)
        WCSession.default.transferFile(
            url,
            metadata: [WatchWireCodec.fileMetadataKey: metadata, Self.attemptMetadataKey: attempt.uuidString])
    }

    /// Cancels every still-queued transfer of the recording `messageID`.
    func cancelVoiceTransfer(_ messageID: UUID) {
        guard Self.isActivated else { return }
        var cancelled = 0
        for transfer in WCSession.default.outstandingFileTransfers
        where Self.voiceFile(of: transfer)?.messageID == messageID {
            transfer.cancel()
            cancelled += 1
        }
        WatchLog.logger.notice(
            "message \(messageID.uuidString, privacy: .public) recording transfers cancelled: \(cancelled, privacy: .public)")
    }

    // MARK: Main-actor side

    /// Applies inbound values on the main actor.
    private func handle(_ inbound: [WatchInbound]) {
        for item in inbound { receive?(item) }
    }

    /// Hands decoded values to the main actor. `DispatchQueue.main` keeps
    /// them in callback order, so an older context never lands after a
    /// newer one.
    nonisolated private func deliver(_ inbound: [WatchInbound]) {
        guard !inbound.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.handle(inbound) }
        }
    }

    // MARK: Helpers

    /// The `transferFile` metadata key holding the watch's attempt tag; the
    /// iPhone ignores it.
    nonisolated private static let attemptMetadataKey = "waycar.watch.attempt"

    /// WatchConnectivity errors that mean the iPhone cannot be reached, as
    /// opposed to reached but silent.
    nonisolated private static let unreachableCodes: Set<WCError.Code> = [
        .notReachable, .deviceNotPaired, .companionAppNotInstalled, .sessionNotActivated,
        .sessionInactive,
    ]

    /// Whether the default session finished activating.
    nonisolated private static var isActivated: Bool {
        WCSession.default.activationState == .activated
    }

    /// One `sendMessageData` round trip. Nonisolated, and both blocks are
    /// `@Sendable`: WatchConnectivity calls them on its own queue.
    nonisolated private static func exchange(_ data: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            WCSession.default.sendMessageData(
                data,
                replyHandler: { @Sendable reply in continuation.resume(returning: reply) },
                errorHandler: { @Sendable error in continuation.resume(throwing: error) })
        }
    }

    /// The Watch State in an application context dictionary, a wire-version
    /// mismatch, or nil for none or junk.
    nonisolated private static func inbound(fromContext context: [String: Any]) -> WatchInbound? {
        guard let data = context[WatchWireCodec.applicationContextKey] as? Data else { return nil }
        do {
            return .state(try WatchWireCodec.decode(WatchState.self, from: data))
        } catch WatchWireError.versionMismatch(let version) {
            return .versionMismatch(version)
        } catch {
            return nil
        }
    }

    /// The voice metadata a file transfer carries, if it is a recording.
    nonisolated private static func voiceFile(of transfer: WCSessionFileTransfer) -> WatchVoiceFile? {
        guard let data = transfer.file.metadata?[WatchWireCodec.fileMetadataKey] as? Data else {
            return nil
        }
        return try? WatchWireCodec.decode(WatchVoiceFile.self, from: data)
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionClient: WCSessionDelegate {
    /// Activation finished: publishes the last application context the
    /// iPhone sent (it persists across launches) and the reachability.
    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let isReachable = activationState == .activated && session.isReachable
        if let error {
            let nsError = error as NSError
            WatchLog.logger.error(
                "WCSession activation \(activationState.rawValue, privacy: .public) failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public) \(nsError.localizedDescription, privacy: .private)")
        } else {
            WatchLog.logger.notice(
                "WCSession activation \(activationState.rawValue, privacy: .public), reachable \(isReachable, privacy: .public), companion app installed \(session.isCompanionAppInstalled, privacy: .public)")
        }
        var inbound: [WatchInbound] = []
        if activationState == .activated, let context = Self.inbound(fromContext: session.receivedApplicationContext) {
            inbound.append(context)
        }
        inbound.append(.reachability(isReachable))
        deliver(inbound)
    }

    /// The iPhone came into or went out of live-message range.
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        WatchLog.logger.notice("WCSession reachable \(session.isReachable, privacy: .public)")
        deliver([.reachability(session.isReachable)])
    }

    /// A newer Watch State.
    nonisolated func session(
        _ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let inbound = Self.inbound(fromContext: applicationContext) else {
            WatchLog.logger.error("application context did not decode")
            return
        }
        if case .state(let state) = inbound {
            WatchLog.logger.notice("Watch State received: \(state.rows.count, privacy: .public) rows")
        }
        deliver([inbound])
    }

    /// A delivery outcome queued with `transferUserInfo`.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo[WatchWireCodec.userInfoKey] as? Data,
            let event = try? WatchWireCodec.decode(WatchEvent.self, from: data)
        else { return }
        deliver([.event(event)])
    }

    /// A delivery outcome sent live while the watch app was reachable.
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard let event = try? WatchWireCodec.decode(WatchEvent.self, from: messageData) else {
            return
        }
        deliver([.event(event)])
    }

    /// The same, when the iPhone asked for a reply: acknowledged at once,
    /// on the callback queue, so the non-Sendable reply block never moves.
    nonisolated func session(
        _ session: WCSession, didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        self.session(session, didReceiveMessageData: messageData)
        replyHandler((try? WatchWireCodec.encode(WatchReply.received)) ?? Data())
    }

    /// A recording's transfer ended; only a failure matters to the outbox.
    nonisolated func session(
        _ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?
    ) {
        guard let error, let file = Self.voiceFile(of: fileTransfer) else { return }
        let nsError = error as NSError
        WatchLog.logger.error(
            "message \(file.messageID.uuidString, privacy: .public) recording transfer failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
        let attempt = (fileTransfer.file.metadata?[Self.attemptMetadataKey] as? String).flatMap(UUID.init(uuidString:))
        deliver([.voiceTransferFailed(messageID: file.messageID, agentID: file.agentID, attempt: attempt)])
    }
}
