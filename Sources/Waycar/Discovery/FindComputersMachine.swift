import Foundation

/// One Bonjour search, its settling timer, and the sweep requested by a tap.
/// Every asynchronous event belongs to a search or sweep token; a stopped or
/// replaced search can never change the next search's results.
struct FindComputersMachine: StateMachine {
    enum Sweep: Equatable, Sendable {
        case idle, running(UInt64), finished, unavailable
    }

    struct Search: Equatable, Sendable {
        let token: UInt64
        let subnet: IPv4Subnet?
        var sweep: Sweep = .idle
        var bonjour: [FoundComputer] = []
        var swept: [FoundComputer] = []

        var computers: [FoundComputer] { FoundComputer.merged(bonjour + swept, subnet: subnet) }
    }

    enum State: Equatable, Sendable {
        case idle
        case searching(Search, timer: UInt64?)
        case settled(Search)
        case denied
        case stopped
    }

    enum Event: Equatable, Sendable {
        case start(IPv4Subnet?)
        case searchAgain(IPv4Subnet?)
        case browse(UInt64, BrowseEvent)
        case settleElapsed(UInt64)
        case scanTapped
        case sweep(UInt64, SweepEvent)
        case stop
    }

    enum Effect: Equatable, Sendable {
        case cancelSearch
        case browse(UInt64)
        case armSettle(UInt64)
        case cancelSettle
        case sweep(UInt64)
        case milestone(Milestone)
    }

    private(set) var state: State = .idle
    private var lastToken: UInt64 = 0

    var computers: [FoundComputer] { search?.computers ?? [] }
    var sweep: Sweep { search?.sweep ?? .idle }
    var hasSettled: Bool {
        if case .settled = state { return true }
        return false
    }
    var isDenied: Bool { state == .denied }

    private var search: Search? {
        switch state {
        case .searching(let search, _), .settled(let search): search
        case .idle, .denied, .stopped: nil
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .start(let subnet)), (.stopped, .start(let subnet)),
            (_, .searchAgain(let subnet)):
            lastToken += 1
            let search = Search(token: lastToken, subnet: subnet)
            state = .searching(search, timer: nil)
            return [.cancelSearch, .milestone(.lanScanStarted), .browse(search.token)]

        case (.searching(var search, let timer), .browse(let token, let event)):
            guard token == search.token else { return [] }
            switch event {
            case .ready:
                guard timer == nil else { return [] }
                lastToken += 1
                state = .searching(search, timer: lastToken)
                return [.armSettle(lastToken)]
            case .computers(let computers):
                search.bonjour = computers
                state = .searching(search, timer: timer)
                return search.computers.isEmpty ? [] : settle(search)
            case .failed:
                return settle(search)
            case .denied:
                return deny()
            }

        case (.settled(var search), .browse(let token, let event)):
            guard token == search.token else { return [] }
            switch event {
            case .computers(let computers):
                search.bonjour = computers
                state = .settled(search)
                return []
            case .denied: return deny()
            case .ready, .failed: return []
            }

        case (.searching(let search, let timer), .settleElapsed(let token)):
            guard token == timer else { return [] }
            return settle(search)

        case (.searching(var search, let timer), .scanTapped):
            guard search.sweep == .idle || search.sweep == .finished else { return [] }
            lastToken += 1
            search.sweep = .running(lastToken)
            search.swept = []
            state = .searching(search, timer: timer)
            return [.sweep(lastToken)]
        case (.settled(var search), .scanTapped):
            guard search.sweep == .idle || search.sweep == .finished else { return [] }
            lastToken += 1
            search.sweep = .running(lastToken)
            search.swept = []
            state = .settled(search)
            return [.sweep(lastToken)]

        case (.searching(var search, let timer), .sweep(let token, let event)):
            guard search.sweep == .running(token) else { return [] }
            if event == .denied { return deny() }
            update(&search, with: event)
            state = .searching(search, timer: timer)
            return search.computers.isEmpty ? [] : settle(search)
        case (.settled(var search), .sweep(let token, let event)):
            guard search.sweep == .running(token) else { return [] }
            if event == .denied { return deny() }
            update(&search, with: event)
            state = .settled(search)
            return []

        case (_, .stop):
            state = .stopped
            return [.cancelSearch]
        case (.idle, _), (.denied, _), (.stopped, _),
            (.searching, .start), (.settled, .start), (.settled, .settleElapsed):
            return []
        }
    }

    private mutating func settle(_ search: Search) -> [Effect] {
        state = .settled(search)
        return [.cancelSettle, .milestone(.lanScanFound(count: search.computers.count))]
    }

    private mutating func deny() -> [Effect] {
        state = .denied
        return [.cancelSearch, .milestone(.lanPermissionDenied)]
    }

    private func update(_ search: inout Search, with event: SweepEvent) {
        switch event {
        case .found(let computer): search.swept.append(computer)
        case .unavailable: search.sweep = .unavailable
        case .finished: search.sweep = .finished
        case .denied: break // Handled before updating the active search.
        }
    }
}
