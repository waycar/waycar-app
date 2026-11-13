import Foundation

/// Phone-side message identity: only definite non-delivery may be retried.
/// In-flight and final ids deduplicate independently of their request payload.
struct WatchMessageLedgerMachine: StateMachine {
    enum Record: Equatable, Sendable {
        case processing(token: UInt64, agentID: ConsoleAgent.ID)
        case retryable(transcript: String?)
        case finished(WatchEvent)
    }

    struct State: Equatable, Sendable {
        var records: [UUID: Record] = [:]
        var order: [UUID] = []
    }

    enum Event: Sendable {
        case receive(UUID)
        case begin(UUID, ConsoleAgent.ID)
        case finished(UUID, token: UInt64, delivery: WatchDelivery, transcript: String?)
    }

    enum Effect: Equatable, Sendable {
        case acknowledge
        case process(token: UInt64, transcript: String?)
        case deliver(WatchEvent)
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0
    let memoryLimit: Int

    init(memoryLimit: Int = 64) { self.memoryLimit = memoryLimit }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .receive(let id):
            switch state.records[id] {
            case .processing: return [.acknowledge]
            case .finished(let event): return [.acknowledge, .deliver(event)]
            case .retryable, nil: return []
            }
        case .begin(let id, let agentID):
            let transcript: String?
            switch state.records[id] {
            case .processing, .finished: return []
            case .retryable(let previous): transcript = previous
            case nil: transcript = nil
            }
            lastToken += 1
            remember(id, .processing(token: lastToken, agentID: agentID))
            return [.process(token: lastToken, transcript: transcript)]
        case .finished(let id, let token, let delivery, let transcript):
            guard case .processing(let current, let agentID) = state.records[id], current == token else {
                return []
            }
            let event = WatchEvent.delivery(messageID: id, WatchAgentID(agentID), delivery)
            if case .notSent = delivery {
                remember(id, .retryable(transcript: transcript))
            } else {
                remember(id, .finished(event))
            }
            return [.deliver(event)]
        }
    }

    private mutating func remember(_ id: UUID, _ record: Record) {
        if state.records.updateValue(record, forKey: id) == nil { state.order.append(id) }
        while state.order.count > memoryLimit, let oldest = state.order.first {
            if case .processing = state.records[oldest] { break }
            state.order.removeFirst()
            state.records[oldest] = nil
        }
    }
}
