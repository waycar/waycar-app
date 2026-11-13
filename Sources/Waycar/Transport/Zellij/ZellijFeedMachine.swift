import Foundation

/// The watch channel is never redialled in place: EventsSession replaces a lost transport.
struct ZellijFeedMachine: StateMachine {
    enum State: Sendable, Equatable {
        case starting, live
        case lost(TransportError)
        case closed
    }
    enum Event: Sendable {
        case frame
        case failed(TransportError)
        case close
    }
    enum Effect: Sendable, Equatable { case finish(TransportError?) }
    private(set) var state: State = .starting

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.starting, .frame), (.live, .frame):
            state = .live
            return []
        case (.starting, .failed(let error)), (.live, .failed(let error)):
            state = .lost(error)
            return [.finish(error)]
        case (.closed, _), (.lost, .frame), (.lost, .failed):
            return []
        case (_, .close):
            state = .closed
            return [.finish(nil)]
        }
    }
}
