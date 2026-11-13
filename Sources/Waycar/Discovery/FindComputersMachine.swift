import Foundation

/// One search for computers: a Bonjour browse, its settling timer, and a
/// sweep of every address on the Wi-Fi, both started by the same tap. Every
/// asynchronous event belongs to a search, timer or sweep token; a stopped or
/// replaced search can never change the next search's results.
///
/// While the app is inactive (iOS's Local Network prompt is up, or Control
/// Center) nothing is reported: a denial seen then may only mean the prompt
/// is unanswered, so the search starts again once the app is active, as an
/// empty one does, since nothing can be found behind the prompt. A count that
/// came in meanwhile is reported then.
struct FindComputersMachine: StateMachine {
    enum Sweep: Equatable, Sendable {
        case running(UInt64), finished, unavailable
    }

    struct Search: Equatable, Sendable {
        let token: UInt64
        let subnet: IPv4Subnet?
        var sweep: Sweep
        var bonjour: [FoundComputer] = []
        var swept: [FoundComputer] = []
        /// Whether this search has reported how many computers it listed.
        var reported = false

        var computers: [FoundComputer] { FoundComputer.merged(bonjour + swept, subnet: subnet) }
        var isSweeping: Bool {
            if case .running = sweep { return true }
            return false
        }
    }

    enum State: Equatable, Sendable {
        case idle
        case searching(Search, timer: UInt64)
        case settled(Search)
        case denied
        case stopped
    }

    enum Event: Equatable, Sendable {
        case start(IPv4Subnet?)
        case searchAgain(IPv4Subnet?)
        case browse(UInt64, BrowseEvent)
        case settleElapsed(UInt64)
        case sweep(UInt64, SweepEvent)
        case appInactive
        case appActive(IPv4Subnet?)
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
    private var isAppActive = true

    var computers: [FoundComputer] { search?.computers ?? [] }
    var sweep: Sweep? { search?.sweep }
    var hasSettled: Bool {
        if case .settled = state { return true }
        return false
    }
    /// A denial behind iOS's prompt shows as still looking: it is checked
    /// again once the app is active.
    var isDenied: Bool { state == .denied && isAppActive }

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
            return [.milestone(.lanScanStarted)] + begin(subnet)

        case (_, .appInactive):
            isAppActive = false
            return []
        case (.denied, .appActive(let subnet)):
            isAppActive = true
            return begin(subnet)
        case (.searching(let search, _), .appActive(let subnet)) where search.computers.isEmpty,
            (.settled(let search), .appActive(let subnet)) where search.computers.isEmpty:
            isAppActive = true
            return begin(subnet)
        case (.settled(var search), .appActive):
            isAppActive = true
            return report(&search)
        case (_, .appActive):
            isAppActive = true
            return []

        case (.searching(var search, let timer), .browse(let token, let event)):
            guard token == search.token else { return [] }
            switch event {
            case .ready:
                // The settle timer already runs from the search's start.
                return []
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
            return report(&search)

        case (_, .stop):
            state = .stopped
            return [.cancelSearch]
        case (.idle, _), (.denied, _), (.stopped, _),
            (.searching, .start), (.settled, .start), (.settled, .settleElapsed):
            return []
        }
    }

    private mutating func nextToken() -> UInt64 {
        lastToken += 1
        return lastToken
    }

    /// The settle timer starts with the search, not at `.ready`: a browser
    /// that only ever waits (Wi-Fi off, no usable interface) must still end
    /// in the empty state and its Search Again.
    private mutating func begin(_ subnet: IPv4Subnet?) -> [Effect] {
        let search = nextToken()
        let timer = nextToken()
        let sweep = nextToken()
        state = .searching(Search(token: search, subnet: subnet, sweep: .running(sweep)), timer: timer)
        return [.cancelSearch, .browse(search), .armSettle(timer), .sweep(sweep)]
    }

    private mutating func settle(_ search: Search) -> [Effect] {
        var search = search
        state = .settled(search)
        return [.cancelSettle] + report(&search)
    }

    /// Reports the row count once, when the browse has settled and the sweep
    /// is over, so the count includes what only the sweep found.
    private mutating func report(_ search: inout Search) -> [Effect] {
        guard isAppActive, !search.reported, !search.isSweeping else { return [] }
        search.reported = true
        state = .settled(search)
        return [.milestone(.lanScanFound(count: search.computers.count))]
    }

    private mutating func deny() -> [Effect] {
        state = .denied
        return isAppActive ? [.cancelSearch, .milestone(.lanPermissionDenied)] : [.cancelSearch]
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
