import Foundation

/// One recorder presentation owns its outcome and reason timer. Sending a
/// finished file consumes the outcome before any effect can re-enter.
struct WatchRecorderPresentationMachine: StateMachine {
    enum State: Equatable, Sendable {
        case preparing
        case recording
        case handled
        case showingReason(String, timer: UInt64?)
        case dismissed
    }
    enum Availability: Equatable, Sendable { case unknown, missing, unsupported, busy, ready }
    enum Event: Equatable, Sendable {
        case begin(Availability, busyReason: String)
        case listening
        case finished(URL, duration: Double)
        case cancelled(String?, stays: Bool)
        case cancel
        case reasonElapsed(UInt64)
        case disappear
    }
    enum Effect: Equatable, Sendable {
        case start
        case announce(String)
        case send(URL, duration: Double)
        case dismiss(toDetail: Bool)
        case armReason(UInt64)
    }
    private(set) var state: State = .preparing
    private var lastToken: UInt64 = 0
    var reason: String? {
        if case .showingReason(let reason, _) = state { return reason }
        return nil
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.preparing, .begin(let availability, let reason)):
            switch availability {
            case .unknown: return []
            case .missing:
                state = .dismissed
                return [.dismiss(toDetail: false)]
            case .unsupported:
                state = .dismissed
                return [.dismiss(toDetail: true)]
            case .busy: return show(reason, stays: false)
            case .ready:
                state = .recording
                return [.start]
            }
        case (.recording, .listening): return [.announce("Listening")]
        case (.recording, .finished(let url, let duration)):
            state = .handled
            return [.send(url, duration: duration), .dismiss(toDetail: true)]
        case (.recording, .cancelled(let reason, let stays)):
            guard let reason else {
                state = .dismissed
                return [.dismiss(toDetail: true)]
            }
            return show(reason, stays: stays)
        case (.showingReason(_, let timer?), .reasonElapsed(let token)):
            guard timer == token else { return [] }
            state = .dismissed
            return [.dismiss(toDetail: true)]
        case (_, .disappear):
            // The old view's captured timer can outlive navigation. Consuming
            // its presentation makes it harmless even for the same Agent.
            state = .dismissed
            return []
        case (_, .cancel):
            state = .dismissed
            return [.dismiss(toDetail: true)]
        case (.preparing, _), (.recording, _), (.handled, _), (.showingReason, _), (.dismissed, _):
            return []
        }
    }

    private mutating func show(_ reason: String, stays: Bool) -> [Effect] {
        lastToken += 1
        state = .showingReason(reason, timer: stays ? nil : lastToken)
        return stays ? [.announce(reason)] : [.announce(reason), .armReason(lastToken)]
    }
}
