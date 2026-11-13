import Foundation
import Observation

/// Feeds discovery events into the machine and performs its I/O. Results and
/// lifecycle state belong to the machine, never to the Tasks performing them.
@MainActor
@Observable
final class FindComputersStore {
    private var machine = FindComputersMachine()

    var computers: [FoundComputer] { machine.computers }
    var sweep: FindComputersMachine.Sweep? { machine.sweep }
    var hasSettled: Bool { machine.hasSettled }
    var isDenied: Bool { machine.isDenied }

    @ObservationIgnored private let browser: any ComputerBrowsing
    @ObservationIgnored private let sweeper: any NetworkSweeping
    @ObservationIgnored private let localSubnet: @Sendable () -> IPv4Subnet?
    @ObservationIgnored private let settleDelay: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var milestone: (Milestone) -> Void = { _ in }
    @ObservationIgnored private var browseTasks: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var settleTasks: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var sweepTasks: [UInt64: Task<Void, Never>] = [:]

    init(
        browser: any ComputerBrowsing = NetworkComputerBrowser(),
        sweeper: any NetworkSweeping = SubnetSweeper(),
        localSubnet: @escaping @Sendable () -> IPv4Subnet? = { LocalWiFiSubnet.current() },
        settleDelay: Duration = .seconds(6),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.browser = browser
        self.sweeper = sweeper
        self.localSubnet = localSubnet
        self.settleDelay = settleDelay
        self.sleep = sleep
    }

    static func makeForPresentation() -> FindComputersStore {
        #if DEBUG
            if DemoFindComputersMode.isEnabled {
                return FindComputersStore(
                    browser: DemoFindComputersMode.Browser(),
                    sweeper: DemoFindComputersMode.Sweeper(),
                    localSubnet: { DemoFindComputersMode.subnet })
            }
        #endif
        return FindComputersStore()
    }

    func start(milestone: @escaping (Milestone) -> Void = { _ in }) {
        self.milestone = milestone
        send(.start(localSubnet()))
    }

    func search() { send(.searchAgain(localSubnet())) }
    func stop() { send(.stop) }

    /// The scene's activity: iOS's Local Network prompt and Control Center
    /// make the app inactive; Settings sends it to the background.
    func appActivityChanged(isActive: Bool) {
        send(isActive ? .appActive(localSubnet()) : .appInactive)
    }

    private func send(_ event: FindComputersMachine.Event) {
        for effect in machine.handle(event) {
            switch effect {
            case .cancelSearch:
                for task in browseTasks.values { task.cancel() }
                for task in sweepTasks.values { task.cancel() }
                browseTasks = [:]
                sweepTasks = [:]
                cancelSettle()
            case .browse(let token):
                let events = browser.events()
                browseTasks[token] = Task { [weak self] in
                    for await event in events {
                        guard let self, !Task.isCancelled else { return }
                        self.send(.browse(token, event))
                    }
                    self?.browseTasks[token] = nil
                }
            case .armSettle(let token):
                settleTasks[token] = Task { [weak self, sleep, settleDelay] in
                    do { try await sleep(settleDelay) } catch { return }
                    guard !Task.isCancelled else { return }
                    self?.send(.settleElapsed(token))
                    self?.settleTasks[token] = nil
                }
            case .cancelSettle:
                cancelSettle()
            case .sweep(let token):
                let events = sweeper.sweep()
                sweepTasks[token] = Task { [weak self] in
                    for await event in events {
                        guard let self, !Task.isCancelled else { return }
                        self.send(.sweep(token, event))
                    }
                    self?.sweepTasks[token] = nil
                }
            case .milestone(let value):
                milestone(value)
            }
        }
    }

    private func cancelSettle() {
        for task in settleTasks.values { task.cancel() }
        settleTasks = [:]
    }
}
