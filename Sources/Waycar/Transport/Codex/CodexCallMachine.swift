/// Each Codex RPC call from its send to its answer, and the client's end
/// (CODEX-07). A call is `queued` until its frame reaches the head of the
/// socket's write queue, then `committed`: from there a timeout or a
/// cancellation still fails the call, but its frame may already be on the
/// wire, so its send is never withdrawn and the call is never reported unsent.
///
/// The call id, a fresh UUID the client mints, is the token: an answer,
/// timeout or cancellation for an id that is no longer pending is ignored, so
/// every call is settled exactly once.
struct CodexCallMachine: StateMachine {
    enum Phase: Equatable, Sendable {
        /// Waiting in the socket's write queue: it can still be withdrawn.
        case queued
        /// At the head of the write queue: its frame may be on the wire.
        case committed
    }

    enum State: Equatable, Sendable {
        case open(calls: [CodexRPCID: Phase])
        /// The socket ended or the client closed: every call failed.
        case ended
    }

    enum Event: Equatable, Sendable {
        case enqueued(CodexRPCID)
        /// The call's frame reached the head of the write queue.
        case writeBegan(CodexRPCID)
        /// A response with this id arrived.
        case answered(CodexRPCID)
        /// Timed out, cancelled, or its queued write was cancelled.
        case failed(CodexRPCID)
        case ended
    }

    enum Effect: Equatable, Sendable {
        /// Let the frame be written: the call is committed.
        case write(CodexRPCID)
        /// Resume the call; `withdraw` also cancels its queued send.
        case settle(CodexRPCID, withdraw: Bool)
        case stopReader
        case finishEvents
    }

    private(set) var state: State = .open(calls: [:])

    var isEnded: Bool { state == .ended }

    func phase(of id: CodexRPCID) -> Phase? {
        guard case .open(let calls) = state else { return nil }
        return calls[id]
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.ended, _):
            return []
        case (.open(var calls), .enqueued(let id)):
            calls[id] = .queued
            state = .open(calls: calls)
            return []
        case (.open(var calls), .writeBegan(let id)):
            guard calls[id] != nil else { return [] }
            calls[id] = .committed
            state = .open(calls: calls)
            return [.write(id)]
        case (.open(var calls), .answered(let id)):
            // An answer proves the frame was written: nothing to withdraw.
            guard calls.removeValue(forKey: id) != nil else { return [] }
            state = .open(calls: calls)
            return [.settle(id, withdraw: false)]
        case (.open(var calls), .failed(let id)):
            guard let phase = calls.removeValue(forKey: id) else { return [] }
            state = .open(calls: calls)
            return [.settle(id, withdraw: phase == .queued)]
        case (.open(let calls), .ended):
            state = .ended
            return [.stopReader]
                + calls.map { Effect.settle($0.key, withdraw: $0.value == .queued) }
                + [.finishEvents]
        }
    }
}
