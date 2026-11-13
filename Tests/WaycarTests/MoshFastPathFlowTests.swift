import Foundation
import Synchronization
import Testing
import WaycarSSH

@testable import Waycar

private let oneAgent = SessionSnapshot.fixture(agents: [.fixture(paneID: "w1:p1")])
private let twoAgents = SessionSnapshot.fixture(
    agents: [.fixture(paneID: "w1:p1"), .fixture(paneID: "w1:p2")])
private let homeNetwork = ScriptedNetworkPathSource.home.key!
private let cafeNetwork = ScriptedNetworkPathSource.cafe.key!

/// A transport whose probe proves mosh and whose bootstrap answers with
/// `bootstrap`.
private func moshTransport(
    _ snapshot: SessionSnapshot = oneAgent,
    bootstrap: MoshBootstrap = MoshFlowFixture.attachBootstrap
) async -> ScriptedTransport {
    let transport = ScriptedTransport(snapshot: snapshot)
    await transport.setMoshProbeAvailable(true)
    await transport.setMoshBootstrap(bootstrap)
    return transport
}

/// Standby mosh around a suspension (#105): made over the still-open SSH
/// connection when Background Grace runs out — never on the expiration
/// path — and used straight away by a return within its age.
@MainActor
@Suite("Mosh standby across suspension", .timeLimit(.minutes(1)))
struct MoshStandbySuspensionTests {
    /// The app away past the grace period with time to spare: the live mosh
    /// Agent gets its standby (at interactive priority, over the connection
    /// the teardown has not closed yet), and only then is it torn down.
    @Test func graceExpiryPreparesAStandbyBeforeTheTeardown() async throws {
        let transport = await moshTransport()
        let flow = MoshFlowFixture(transports: [transport])
        try await flow.startOnMosh()
        _ = try await flow.openLiveMosh()
        let live = flow.mosh.sessions[0]
        let activity = AppActivityCoordinator(
            gracePeriod: .milliseconds(50), granter: ScriptedBackgroundGranter())
        let driver = Task { await ConsoleActivityDriver(activity: activity, console: flow.console).run() }
        defer { driver.cancel() }
        let standbyGate = ScriptedTransportCallGate()
        await transport.setMoshBootstrap(MoshFlowFixture.standbyBootstrap)
        await transport.gateNextMoshBootstrap(on: standbyGate)

        activity.didEnterBackground(.phone)
        try await pollUntil("the standby bootstrap should start") { await standbyGate.entryCount == 1 }
        #expect(live.teardown == nil, "the standby is made before the teardown")
        #expect(flow.console.hostStatuses[flow.host.id] == .connected)
        #expect(await transport.moshBootstrapPriorities.last == .interactive)
        let request = try #require(await transport.moshBootstrapRequests.last)
        #expect(request.target == .agentPane("w1:p1"))
        #expect(request.cols == 80 && request.rows == 24)
        await standbyGate.open()

        try await pollUntil("the teardown should end the live session cleanly") {
            live.teardown == .ended
        }
        try await pollUntil("the Host should suspend") {
            flow.console.hostStatuses[flow.host.id] == .suspended
        }
        #expect(
            flow.fastPath.standbys.standby(for: flow.key())?.bootstrap
                == MoshFlowFixture.standbyBootstrap)
        await flow.tearDown()
    }

    /// Expiration handlers must not wait on the network (TN2277): the system
    /// reclaiming its time tears down with no standby attempted.
    @Test func expirationTearsDownWithoutAStandby() async throws {
        let transport = await moshTransport()
        let flow = MoshFlowFixture(transports: [transport])
        try await flow.startOnMosh()
        _ = try await flow.openLiveMosh()
        let live = flow.mosh.sessions[0]
        let granter = ScriptedBackgroundGranter()
        let activity = AppActivityCoordinator(gracePeriod: .seconds(60), granter: granter)
        let driver = Task { await ConsoleActivityDriver(activity: activity, console: flow.console).run() }
        defer { driver.cancel() }

        activity.didEnterBackground(.phone)
        granter.expireAll()
        try await pollUntil("the expiration should tear the session down") { live.teardown == .ended }
        #expect(await transport.moshBootstrapRequests.count == 1, "only the attach's own bootstrap")
        #expect(flow.fastPath.standbys.standby(for: flow.key()) == nil)
        await flow.tearDown()
    }

    /// Suspends the flow's live mosh Agent through the activity driver and
    /// waits for its standby; returns the coordinator for the return.
    private func suspendWithStandby(
        _ flow: MoshFlowFixture, transport: ScriptedTransport
    ) async throws -> (AppActivityCoordinator, Task<Void, Never>) {
        try await flow.startOnMosh()
        _ = try await flow.openLiveMosh()
        let activity = AppActivityCoordinator(
            gracePeriod: .milliseconds(50), granter: ScriptedBackgroundGranter())
        let driver = Task { await ConsoleActivityDriver(activity: activity, console: flow.console).run() }
        await transport.setMoshBootstrap(MoshFlowFixture.standbyBootstrap)
        activity.didEnterBackground(.phone)
        try await pollUntil("the suspension should leave a standby behind") {
            flow.console.hostStatuses[flow.host.id] == .suspended
                && flow.fastPath.standbys.standby(for: flow.key()) != nil
        }
        #expect(flow.console.agentTerminals.entries.isEmpty)
        return (activity, driver)
    }

    /// Back within the standby's age: the client starts straight at it and
    /// goes live while the Host's SSH connection is still dialling — no SSH
    /// bootstrap, no wait for verification. The new connection then leaves
    /// the mosh session running.
    @Test func aReturnStartsStraightAtTheStandbyWithoutSSH() async throws {
        let before = await moshTransport()
        let after = await moshTransport(bootstrap: MoshFlowFixture.laterBootstrap)
        let reconnect = ScriptedTransportCallGate()
        let flow = MoshFlowFixture(transports: [before, after], gating: [2: reconnect])
        let (activity, driver) = try await suspendWithStandby(flow, transport: before)
        defer { driver.cancel() }

        let returned = ContinuousClock.now
        activity.didBecomeActive(.phone)
        let entry = flow.open(try flow.agent())
        try await pollUntil("the return should start a client") { flow.mosh.sessions.count == 2 }
        let resumed = flow.mosh.sessions[1]
        #expect(resumed.bootstrap == MoshFlowFixture.standbyBootstrap)
        #expect(resumed.firstContactTimeout == MoshAttachCoordinator.standbyFirstContactTimeout)
        resumed.emit("\u{1B}[H$ ready")
        try await pollUntil("the standby's terminal should go live") {
            entry.attach.terminalStatus == .live
        }
        #expect(returned.duration(to: .now) < .seconds(1))
        #expect(flow.console.hostStatuses[flow.host.id] != .connected, "live before SSH is back")
        #expect(await before.moshBootstrapRequests.count == 2)
        #expect(await after.moshBootstrapRequests.isEmpty)
        #expect(flow.fastPath.standbys.standby(for: flow.key()) == nil, "a standby is used once")

        await reconnect.open()
        try await pollUntil("the Host should reconnect") {
            flow.console.hostStatuses[flow.host.id] == .connected
                && !flow.console.hostsAwaitingSnapshot.contains(flow.host.id)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(resumed.teardown == nil, "a new SSH connection leaves the mosh session running")
        #expect(flow.mosh.sessions.count == 2)
        await flow.tearDown()
    }

    /// A standby as old as mosh-server's patience allows no longer counts:
    /// the attach bootstraps its own server over the new connection.
    @Test func aStaleStandbyIsIgnored() async throws {
        let clock = StandbyClock()
        let before = await moshTransport()
        let after = await moshTransport(bootstrap: MoshFlowFixture.laterBootstrap)
        let reconnect = ScriptedTransportCallGate()
        let flow = MoshFlowFixture(
            transports: [before, after], gating: [2: reconnect],
            standbys: StandbyMoshStore(now: { clock.now }))
        let (activity, driver) = try await suspendWithStandby(flow, transport: before)
        defer { driver.cancel() }
        clock.advance(by: StandbyMoshStore.maxAge)

        activity.didBecomeActive(.phone)
        _ = flow.open(try flow.agent())
        await reconnect.open()
        try await pollUntil("the attach should bootstrap its own server") {
            flow.mosh.sessions.count == 2
        }
        try #require(flow.mosh.sessions.count == 2)
        #expect(flow.mosh.sessions[1].bootstrap == MoshFlowFixture.laterBootstrap)
        #expect(flow.mosh.sessions[1].firstContactTimeout == MoshAttachCoordinator.firstContactTimeout)
        #expect(await after.moshBootstrapRequests.count == 1)
        await flow.tearDown()
    }

    /// The standby's server ends (its pane is gone) before the returning
    /// Host verifies its rows: the attach waits for them instead of ending,
    /// then leaves for the pane-gone placeholder without attaching again.
    @Test func aStandbyEndingBeforeVerificationAwaitsTheRowsThenEndsForAGonePane() async throws {
        let before = await moshTransport()
        let after = await moshTransport(.fixture(agents: []), bootstrap: MoshFlowFixture.laterBootstrap)
        let reconnect = ScriptedTransportCallGate()
        let flow = MoshFlowFixture(transports: [before, after], gating: [2: reconnect])
        let (activity, driver) = try await suspendWithStandby(flow, transport: before)
        defer { driver.cancel() }

        activity.didBecomeActive(.phone)
        let entry = flow.open(try flow.agent())
        try await pollUntil("the return should start at the standby") { flow.mosh.sessions.count == 2 }
        flow.mosh.sessions[1].finish()
        try await Task.sleep(for: .milliseconds(100))
        if case .ended = entry.attach.terminalStatus {
            Issue.record("an unverified Host's attach must wait for its rows, not end")
        }

        await reconnect.open()
        try await pollUntil("the verified rows should drop the gone pane") {
            flow.console.agents.isEmpty
        }
        try await pollUntil("a gone pane should end the attach, not reattach it") {
            switch entry.attach.terminalStatus {
            case .ended, .stopped: true
            case .waitingForSize, .connecting, .live: false
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await after.moshBootstrapRequests.isEmpty)
        #expect(await after.attachRequests.isEmpty)
        #expect(flow.mosh.sessions.count == 2)
        await flow.tearDown()
    }

    /// The same, for a pane the verified rows still list: attached once more
    /// the ordinary way.
    @Test func aStandbyEndingBeforeVerificationReattachesAListedPane() async throws {
        let before = await moshTransport()
        let after = await moshTransport(bootstrap: MoshFlowFixture.laterBootstrap)
        let reconnect = ScriptedTransportCallGate()
        let flow = MoshFlowFixture(transports: [before, after], gating: [2: reconnect])
        let (activity, driver) = try await suspendWithStandby(flow, transport: before)
        defer { driver.cancel() }

        activity.didBecomeActive(.phone)
        let entry = flow.open(try flow.agent())
        try await pollUntil("the return should start at the standby") { flow.mosh.sessions.count == 2 }
        flow.mosh.sessions[1].finish()
        await reconnect.open()
        try await pollUntil("the listed pane should be attached again") { flow.mosh.sessions.count == 3 }
        #expect(flow.mosh.sessions[2].bootstrap == MoshFlowFixture.laterBootstrap)
        flow.mosh.sessions[2].emit("\u{1B}[H$ again")
        try await pollUntil("the reattach should go live") { entry.attach.terminalStatus == .live }
        await flow.tearDown()
    }
}

/// The attach path's use of standbys while the app is in front (#105).
@MainActor
@Suite("Mosh standby attach", .timeLimit(.minutes(1)))
struct MoshStandbyAttachTests {
    /// A standby whose server never answers within its short first-contact
    /// window leaves the attach to a fresh bootstrap — and says nothing
    /// about UDP: the server may only have expired.
    @Test func aStandbyThatNeverAnswersFallsBackToAFreshBootstrap() async throws {
        let transport = await moshTransport(bootstrap: MoshFlowFixture.laterBootstrap)
        let flow = MoshFlowFixture(transports: [transport])
        try await flow.startOnMosh()
        await flow.fastPath.standbys.prepare(flow.key(), origin: .speculative) {
            MoshFlowFixture.standbyBootstrap
        }?.value

        let entry = flow.open(try flow.agent())
        try await pollUntil("the client should start at the standby") { flow.mosh.sessions.count == 1 }
        #expect(flow.mosh.sessions[0].bootstrap == MoshFlowFixture.standbyBootstrap)
        #expect(
            flow.mosh.sessions[0].firstContactTimeout == MoshAttachCoordinator.standbyFirstContactTimeout)
        flow.mosh.sessions[0].timeOutFirstContact()

        try await pollUntil("a fresh server should be bootstrapped") { flow.mosh.sessions.count == 2 }
        #expect(flow.mosh.sessions[1].bootstrap == MoshFlowFixture.laterBootstrap)
        flow.mosh.sessions[1].emit("\u{1B}[H$ ready")
        try await pollUntil("the fresh session should go live") { entry.attach.terminalStatus == .live }
        #expect(entry.attach.lastSessionFlavor == .mosh)
        #expect(await transport.attachRequests.isEmpty, "no fallback to SSH")
        #expect(
            flow.console.moshAvailability(
                for: flow.host.id, generation: flow.console.hostConnectionGenerations[flow.host.id] ?? 0))
        await flow.tearDown()
    }

    /// A returning mosh session whose server answers is kept — with a repaint
    /// nudge, not a replacement.
    @Test func aReturningMoshSessionThatHearsItsServerIsKept() async throws {
        let flow = MoshFlowFixture(transports: [await moshTransport()])
        try await flow.startOnMosh()
        let entry = try await flow.openLiveMosh()
        let session = flow.mosh.sessions[0]
        session.setHeardOnReturn(true)

        entry.attach.didBecomeActive(afterPossibleSuspension: true)
        try await pollUntil("the kept session should be asked to repaint") {
            session.resizes == [.resize(cols: 79, rows: 24), .resize(cols: 80, rows: 24)]
        }
        #expect(session.serverContactChecks == 1)
        #expect(session.teardown == nil)
        #expect(flow.mosh.sessions.count == 1)
        #expect(entry.attach.terminalStatus == .live)
        await flow.tearDown()
    }

    /// One whose server stays silent is replaced at once: abandoned, with no
    /// wait for a shutdown acknowledgement that will not come.
    @Test func aReturningMoshSessionWhoseServerIsSilentIsAbandonedAndReplaced() async throws {
        let transport = await moshTransport()
        let flow = MoshFlowFixture(transports: [transport])
        try await flow.startOnMosh()
        let entry = try await flow.openLiveMosh()
        let session = flow.mosh.sessions[0]
        session.setHeardOnReturn(false)
        await transport.setMoshBootstrap(MoshFlowFixture.laterBootstrap)
        let surface = entry.attach.terminalID

        entry.attach.didBecomeActive(afterPossibleSuspension: true)
        try await pollUntil("the silent session should be abandoned") { session.teardown == .abandoned }
        try await pollUntil("a replacement should take over") { entry.attach.terminalID != surface }
        entry.attach.viewDidResize(cols: 80, rows: 24)
        try await pollUntil("the replacement should start a new client") { flow.mosh.sessions.count == 2 }
        #expect(flow.mosh.sessions[1].bootstrap == MoshFlowFixture.laterBootstrap)
        await flow.tearDown()
    }

    /// The Agent's detail starts its attach when it is created, on the grid
    /// this layout last had; the view's own size then rides the session as a
    /// resize. A return finds that pipeline fresh and keeps it.
    @Test func anAttachStartsAtIntentOnTheRememberedGrid() async throws {
        let defaults = try #require(UserDefaults(suiteName: "grid-\(UUID().uuidString)"))
        let layout = TerminalGridSizeMemory.Layout(
            horizontalSizeClass: 1, verticalSizeClass: 2, width: 440, height: 956, fontSize: 13)
        let memory = TerminalGridSizeMemory(defaults: defaults)
        memory.record(cols: 100, rows: 30, for: layout)
        let transport = ScriptedTransport(snapshot: oneAgent)
        let flow = MoshFlowFixture(transports: [transport], gridSizes: memory)
        try await flow.start()

        let entry = flow.open(try flow.agent(), reportingSize: false, windowLayout: layout)
        try await pollUntil("the attach should start before any layout") {
            await transport.hasLiveAttachSession
        }
        let request = try #require(await transport.attachRequests.first)
        #expect(request.cols == 100 && request.rows == 30)
        #expect(await transport.emitAttachOutput(Data("$ ".utf8)))
        try await pollUntil("the terminal should go live") { entry.attach.terminalStatus == .live }

        let surface = entry.attach.terminalID
        entry.attach.didBecomeActive(afterPossibleSuspension: true)
        entry.attach.viewDidResize(cols: 80, rows: 24)
        try await pollUntil("the real layout should ride the session as a resize") {
            await transport.attachInputs.contains(.resize(cols: 80, rows: 24))
        }
        // A replacement stops the pipeline it replaces before attaching anew,
        // so the resize can land first; give one the time it would take.
        try await Task.sleep(for: .milliseconds(100))
        #expect(entry.attach.terminalID == surface, "the pipeline started at intent is kept")
        #expect(await transport.attachRequests.count == 1, "a resize, not a reattach")
        #expect(memory.size(for: layout) == .init(cols: 80, rows: 24))
        await flow.tearDown()
    }

    /// Two windows side by side (iPad Split View): each terminal starts on
    /// the grid its own window's layout last had, and its size report is
    /// kept for that layout alone — never the other window's.
    @Test func eachWindowStartsItsTerminalOnItsOwnGrid() async throws {
        let defaults = try #require(UserDefaults(suiteName: "grid-\(UUID().uuidString)"))
        let left = TerminalGridSizeMemory.Layout(
            horizontalSizeClass: 1, verticalSizeClass: 2, width: 507, height: 1024, fontSize: 13)
        let right = TerminalGridSizeMemory.Layout(
            horizontalSizeClass: 2, verticalSizeClass: 2, width: 853, height: 1024, fontSize: 13)
        let memory = TerminalGridSizeMemory(defaults: defaults)
        memory.record(cols: 60, rows: 50, for: left)
        memory.record(cols: 100, rows: 50, for: right)
        let transport = ScriptedTransport(snapshot: twoAgents)
        let flow = MoshFlowFixture(transports: [transport], gridSizes: memory)
        try await flow.start(expectingAgents: 2)

        let entry = flow.open(try flow.agent("w1:p1"), reportingSize: false, windowLayout: left)
        try await pollUntil("the attach should start before any layout") {
            await transport.hasLiveAttachSession
        }
        let request = try #require(await transport.attachRequests.first)
        #expect(request.cols == 60 && request.rows == 50, "the left window's grid, not the right's")

        entry.attach.viewDidResize(cols: 62, rows: 50)
        #expect(memory.size(for: left) == .init(cols: 62, rows: 50))
        #expect(memory.size(for: right) == .init(cols: 100, rows: 50), "the other window keeps its own")
        await flow.tearDown()
    }

    /// A live mosh terminal whose Host went quiet shows the Reconnecting
    /// pill over its frame until the Host answers again.
    @Test func aStalledMoshTerminalShowsStalledUntilTheHostAnswers() async throws {
        let flow = MoshFlowFixture(transports: [await moshTransport()])
        try await flow.startOnMosh()
        let entry = try await flow.openLiveMosh()
        let session = flow.mosh.sessions[0]
        #expect(!entry.attach.terminalIsStalled)

        session.setConnectivity(.stalled)
        try await pollUntil("the stall should show") { entry.attach.terminalIsStalled }
        #expect(entry.attach.terminalStatus == .live, "the frame stays under the pill")
        session.setConnectivity(.connected)
        try await pollUntil("the answer should clear it") { !entry.attach.terminalIsStalled }
        await flow.tearDown()
    }

    /// A tmux Agent on mosh gets the same: a standby made over its tmux
    /// connection, and a silent session on return replaced at that standby.
    @Test func aTmuxAgentGetsAStandbyAndCheckBeforeReplace() async throws {
        let snapshot = SessionSnapshot.fixture(
            agents: [.fixture(paneID: "tmux:%1", workspaceID: "tmux:$1")])
        let transport = await moshTransport(snapshot)
        let flow = MoshFlowFixture(
            transports: [transport], presence: HostBackendPresence(herdr: false, tmuxVersion: "3.4"))
        flow.console.setHosts([flow.host])
        await flow.console.resume()
        try await pollUntil("the tmux row should arrive") {
            flow.console.agents.first?.backend == .tmux
                && flow.console.moshProbe(for: flow.host.id)?.available == true
        }
        let entry = try await flow.openLiveMosh("tmux:%1")

        await transport.setMoshBootstrap(MoshFlowFixture.standbyBootstrap)
        await flow.console.prepareMoshStandbys(within: .seconds(3))
        let key = flow.key("tmux:%1", backend: .tmux)
        #expect(flow.fastPath.standbys.standby(for: key)?.bootstrap == MoshFlowFixture.standbyBootstrap)

        flow.mosh.sessions[0].setHeardOnReturn(false)
        let surface = entry.attach.terminalID
        entry.attach.didBecomeActive(afterPossibleSuspension: true)
        try await pollUntil("the silent session should be abandoned") {
            flow.mosh.sessions[0].teardown == .abandoned
        }
        try await pollUntil("a replacement should take over") { entry.attach.terminalID != surface }
        entry.attach.viewDidResize(cols: 80, rows: 24)
        try await pollUntil("the replacement should start at the standby") { flow.mosh.sessions.count == 2 }
        #expect(flow.mosh.sessions[1].bootstrap == MoshFlowFixture.standbyBootstrap)
        await flow.tearDown()
    }
}

/// A mosh attach belongs to the connection it bootstraps on, from the
/// moment its run holds that connection (#105).
@MainActor
@Suite("Mosh attach across connections", .timeLimit(.minutes(1)))
struct MoshAttachConnectionTests {
    /// A bootstrap whose connection is replaced while it runs starts again
    /// over the new connection: the old one's server may never be reported.
    @Test func aBootstrapOnAReplacedConnectionStartsAgainOverTheNewOne() async throws {
        let first = await moshTransport()
        let second = await moshTransport(bootstrap: MoshFlowFixture.laterBootstrap)
        let flow = MoshFlowFixture(transports: [first, second])
        try await flow.startOnMosh()
        let bootstrap = ScriptedTransportCallGate()
        await first.gateNextMoshBootstrap(on: bootstrap)
        let entry = flow.open(try flow.agent())
        await bootstrap.waitForEntry()
        let surface = entry.attach.terminalID

        await first.setConnectionAlive(false)
        await first.failEventStream(.channelFailed(detail: "dropped"))
        try await pollUntil("the new connection should be verified") {
            flow.console.hostConnectionGenerations[flow.host.id] == 1
                && flow.console.hostStatuses[flow.host.id] == .connected
                && !flow.console.hostsAwaitingSnapshot.contains(flow.host.id)
        }
        // The dead connection's exec never reports its server.
        await first.setMoshBootstrap(nil)
        await bootstrap.open()
        try await pollUntil("the attach should start again") { entry.attach.terminalID != surface }
        entry.attach.viewDidResize(cols: 80, rows: 24)
        try await pollUntil("the new connection should bootstrap") { flow.mosh.sessions.count == 1 }
        #expect(flow.mosh.sessions.first?.bootstrap == MoshFlowFixture.laterBootstrap)
        #expect(await second.moshBootstrapRequests.count == 1)
        await flow.tearDown()
    }
}

/// One standby per Host for the Agent last viewed or named, kept while the
/// Console is in front and the Host connected (#105).
@MainActor
@Suite("Speculative mosh standby", .timeLimit(.minutes(1)))
struct SpeculativeMoshStandbyTests {
    @Test func theStandbyFollowsTheLastNamedAgentOnly() async throws {
        let transport = await moshTransport(twoAgents, bootstrap: MoshFlowFixture.standbyBootstrap)
        let flow = MoshFlowFixture(
            transports: [transport], speculativeStandbyRefresh: .milliseconds(100))
        try await flow.startOnMosh(expectingAgents: 2)

        flow.console.noteAgentIntent(try flow.agent("w1:p1").id)
        try await pollUntil("the named Agent's standby should be made and renewed") {
            await transport.moshBootstrapPriorities.count >= 2
        }
        let priorities = await transport.moshBootstrapPriorities
        #expect(
            priorities.first == .interactive,
            "the attach a notification starts is about to wait on its standby")
        #expect(
            priorities.dropFirst().allSatisfy { $0 == .normal },
            "nobody waits on a renewal: it must not jump queued work")

        await transport.setMoshBootstrap(MoshFlowFixture.laterBootstrap)
        flow.console.noteAgentIntent(try flow.agent("w1:p2").id)
        try await pollUntil("the next Agent's standby should be made") {
            flow.fastPath.standbys.standby(for: flow.key("w1:p2")) != nil
        }
        #expect(flow.fastPath.standbys.standby(for: flow.key("w1:p1")) == nil, "one per Host")
        let targets = await transport.moshBootstrapRequests.map(\.target)
        #expect(targets.first == .agentPane("w1:p1"))
        #expect(targets.contains(.agentPane("w1:p2")))
        #expect(!targets.drop { $0 != .agentPane("w1:p2") }.contains(.agentPane("w1:p1")))
        await flow.tearDown()
    }

    /// The tap's attach takes the standby — one server, no bootstrap of its
    /// own — and an open terminal needs no renewal.
    @Test func aTapConsumesTheStandby() async throws {
        let transport = await moshTransport(bootstrap: MoshFlowFixture.standbyBootstrap)
        let flow = MoshFlowFixture(
            transports: [transport], speculativeStandbyRefresh: .milliseconds(100))
        try await flow.startOnMosh()
        flow.console.noteAgentIntent(try flow.agent().id)
        try await pollUntil("the standby should be made") {
            flow.fastPath.standbys.standby(for: flow.key()) != nil
        }

        let entry = flow.open(try flow.agent())
        try await pollUntil("the tap should start at the standby") { flow.mosh.sessions.count == 1 }
        #expect(flow.mosh.sessions[0].bootstrap == MoshFlowFixture.standbyBootstrap)
        #expect(flow.fastPath.standbys.standby(for: flow.key()) == nil)
        flow.mosh.sessions[0].emit("\u{1B}[H$ ready")
        try await pollUntil("the tapped terminal should go live") { entry.attach.terminalStatus == .live }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await transport.moshBootstrapRequests.count == 1)
        await flow.tearDown()
    }

    /// Renewed before mosh-server stops waiting for it.
    @Test func theStandbyIsRenewed() async throws {
        let transport = await moshTransport(bootstrap: MoshFlowFixture.standbyBootstrap)
        let flow = MoshFlowFixture(
            transports: [transport], speculativeStandbyRefresh: .milliseconds(100))
        try await flow.startOnMosh()
        flow.console.noteAgentIntent(try flow.agent().id)
        try await pollUntil("the standby should be renewed") {
            await transport.moshBootstrapRequests.count >= 3
        }
        await flow.tearDown()
    }

    /// None while the Host is not connected — it is made once it is, over
    /// the new connection — and none while the Console is suspended.
    @Test func noStandbyWithoutAConnectedHostOrWhileSuspended() async throws {
        let first = await moshTransport(bootstrap: MoshFlowFixture.standbyBootstrap)
        let second = await moshTransport(bootstrap: MoshFlowFixture.standbyBootstrap)
        let reconnect = ScriptedTransportCallGate()
        let flow = MoshFlowFixture(transports: [first, second], gating: [2: reconnect])
        try await flow.startOnMosh()
        // The connection dies, not only its events channel (which the
        // session would resubscribe over the same live link at once): the
        // Host stays down until the gated redial lands.
        await first.setConnectionAlive(false)
        await first.failEventStream(.channelFailed(detail: "dropped"))
        try await pollUntil("the Host should be redialling") { await flow.connections.attempts == 2 }

        flow.console.noteAgentIntent(try flow.agent().id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(flow.console.hostStatuses[flow.host.id] != .connected)
        #expect(!flow.fastPath.standbys.isPreparing(flow.key()))
        #expect(flow.fastPath.standbys.standby(for: flow.key()) == nil)
        #expect(await first.moshBootstrapRequests.isEmpty)
        await reconnect.open()
        try await pollUntil("the reconnected Host should get the standby") {
            flow.fastPath.standbys.standby(for: flow.key()) != nil
        }
        #expect(await second.moshBootstrapRequests.count == 1)

        await flow.console.suspend()
        flow.fastPath.standbys.discard(flow.key())
        flow.console.noteAgentIntent(try flow.agent().id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!flow.fastPath.standbys.isPreparing(flow.key()))
        #expect(flow.fastPath.standbys.standby(for: flow.key()) == nil)
        #expect(await second.moshBootstrapRequests.count == 1, "no bootstrap while suspended")
        await flow.tearDown()
    }
}

/// What mosh is known to do, per Host and network (#105).
@MainActor
@Suite("Mosh availability per network", .timeLimit(.minutes(1)))
struct MoshAvailabilityPerNetworkTests {
    /// A session whose server answers proves mosh on this network.
    @Test func anAnsweringSessionRecordsProofForTheNetwork() async throws {
        let availability = MoshAvailabilityStore()
        let flow = MoshFlowFixture(transports: [await moshTransport()], availability: availability)
        try await flow.startOnMosh()
        flow.path.read(ScriptedNetworkPathSource.home)
        #expect(availability.outcome(for: flow.host, network: homeNetwork) == nil)

        _ = try await flow.openLiveMosh()
        try await pollUntil("the first contact should be remembered") {
            availability.outcome(for: flow.host, network: homeNetwork) == .available
        }
        await flow.tearDown()
    }

    /// A fresh server that never answers means UDP does not get through
    /// here: the terminal falls back to SSH, and the next launch on this
    /// network goes straight to SSH — no probe, no bootstrap.
    @Test func aSilentServerSendsThisNetworkStraightToSSH() async throws {
        let availability = MoshAvailabilityStore()
        let host = Host.fixture()
        let first = await moshTransport()
        let blocked = MoshFlowFixture(host: host, transports: [first], availability: availability)
        blocked.path.read(ScriptedNetworkPathSource.home)
        try await blocked.startOnMosh()
        _ = blocked.open(try blocked.agent())
        try await pollUntil("the client should start") { blocked.mosh.sessions.count == 1 }
        blocked.mosh.sessions[0].timeOutFirstContact()
        try await pollUntil("UDP should be remembered blocked here") {
            availability.outcome(for: host, network: homeNetwork) == .unavailable
        }
        try await pollUntil("the terminal should fall back to SSH") { await first.attachRequests.count == 1 }
        // The app goes away with the Host still configured: what it learned
        // stays (removing the Host would forget it).
        await blocked.console.suspend()

        let next = await moshTransport()
        let relaunched = MoshFlowFixture(host: host, transports: [next], availability: availability)
        relaunched.path.read(ScriptedNetworkPathSource.home)
        try await relaunched.start()
        _ = relaunched.open(try relaunched.agent())
        try await pollUntil("the attach should go over SSH") { await next.attachRequests.count == 1 }
        #expect(await next.moshBootstrapRequests.isEmpty)
        #expect(await next.moshProbeCount == 0)
        await relaunched.tearDown()
    }

    /// A cold-restored Agent rides the remembered outcome: mosh from its
    /// first attach, known before the Host has even connected, no probe.
    @Test func aColdRestoreUsesTheRememberedOutcome() async throws {
        let availability = MoshAvailabilityStore()
        let host = Host.fixture()
        availability.record(.available, for: host, network: homeNetwork)
        let transport = ScriptedTransport(snapshot: oneAgent)
        await transport.setMoshBootstrap(MoshFlowFixture.attachBootstrap)
        let connect = ScriptedTransportCallGate()
        let flow = MoshFlowFixture(
            host: host, transports: [transport], gating: [1: connect], availability: availability)
        flow.path.read(ScriptedNetworkPathSource.home)
        flow.console.setHosts([host])
        await flow.console.resume()
        #expect(flow.console.moshAvailability(for: host.id, generation: 0))

        await connect.open()
        try await pollUntil("the Agent should arrive") { flow.console.agents.count == 1 }
        _ = try await flow.openLiveMosh()
        #expect(await transport.moshProbeCount == 0)
        #expect(await transport.moshBootstrapRequests.count == 1)
        await flow.tearDown()
    }

    /// With nothing remembered, the probe waits for the connection's first
    /// snapshot.
    @Test func theProbeWaitsForTheFirstSnapshot() async throws {
        let transport = await moshTransport()
        let snapshot = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: snapshot)
        let flow = MoshFlowFixture(transports: [transport])
        flow.console.setHosts([flow.host])
        await flow.console.resume()
        await snapshot.waitForEntry()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.moshProbeCount == 0)

        await snapshot.open()
        try await pollUntil("the probe should run after the snapshot") {
            await transport.moshProbeCount == 1
        }
        await flow.tearDown()
    }

    /// Never beside an attach's mosh bootstrap on the Host: it runs once the
    /// bootstrap settles.
    @Test func theProbeNeverRunsBesideAnAttachBootstrap() async throws {
        let transport = await moshTransport()
        let snapshot = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: snapshot)
        let flow = MoshFlowFixture(transports: [transport])
        flow.console.setHosts([flow.host])
        await flow.console.resume()
        await snapshot.waitForEntry()
        #expect(await flow.fastPath.standbys.claimAttachBootstrap(flow.key()) == nil)

        await snapshot.open()
        try await pollUntil("the Agent should arrive") { flow.console.agents.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.moshProbeCount == 0)
        flow.fastPath.standbys.finishAttachBootstrap(flow.key())
        try await pollUntil("the probe should run once the bootstrap settles") {
            await transport.moshProbeCount == 1
        }
        await flow.tearDown()
    }

    /// A probe proving mosh while an SSH attach is still opening restarts
    /// that attach on mosh.
    @Test func anAvailableProbeUpgradesAConnectingSSHAttach() async throws {
        let transport = await moshTransport()
        let probe = ScriptedTransportCallGate()
        await transport.gateNextMoshProbe(on: probe)
        let attach = ScriptedTransportCallGate()
        await transport.gateNextAttach(using: attach)
        let flow = MoshFlowFixture(transports: [transport])
        try await flow.start()
        await probe.waitForEntry()

        let entry = flow.open(try flow.agent())
        await attach.waitForEntry()
        #expect(entry.attach.terminalStatus == .connecting)
        await probe.open()
        try await pollUntil("the probe should prove mosh") {
            flow.console.moshProbe(for: flow.host.id)?.available == true
        }
        await attach.open()
        try await pollUntil("the opening SSH attach should restart on mosh") {
            flow.mosh.sessions.count == 1
        }
        flow.mosh.sessions[0].emit("\u{1B}[H$ ready")
        try await pollUntil("the mosh terminal should go live") { entry.attach.terminalStatus == .live }
        #expect(entry.attach.lastSessionFlavor == .mosh)
        #expect(await transport.attachRequests.count == 1)
        await flow.tearDown()
    }

    /// A new network gives mosh another chance after an automatic fallback,
    /// but a user's "Use SSH Instead" stands.
    @Test func aNetworkChangeClearsOnlyAutomaticInvalidations() async throws {
        for cause in [MoshInvalidationCause.automaticFallback, .userChoseSSH] {
            let transport = await moshTransport()
            let flow = MoshFlowFixture(transports: [transport])
            flow.path.read(ScriptedNetworkPathSource.home)
            try await flow.startOnMosh()
            flow.console.invalidateMosh(for: flow.host.id, cause: cause)
            let generation = flow.console.hostConnectionGenerations[flow.host.id] ?? 0
            #expect(!flow.console.moshAvailability(for: flow.host.id, generation: generation))

            flow.path.read(ScriptedNetworkPathSource.cafe)
            switch cause {
            case .automaticFallback:
                try await pollUntil("the new network should be probed again") {
                    await transport.moshProbeCount == 2
                }
                try await pollUntil("mosh should be back") {
                    flow.console.moshAvailability(for: flow.host.id, generation: generation)
                }
            case .userChoseSSH:
                try await Task.sleep(for: .milliseconds(150))
                #expect(await transport.moshProbeCount == 1)
                #expect(!flow.console.moshAvailability(for: flow.host.id, generation: generation))
            }
            await flow.tearDown()
        }
    }
}

/// The mosh-carried terminal pipeline (#105): live only on visible content,
/// and a lost link reattaches once per live stretch instead of falling back
/// to SSH.
@MainActor
@Suite("Mosh attach terminal", .timeLimit(.minutes(1)))
struct MoshAttachTerminalTests {
    private final class Invalidations: Sendable {
        private let state = Mutex<[MoshInvalidationCause]>([])
        var causes: [MoshInvalidationCause] { state.withLock { $0 } }
        func append(_ cause: MoshInvalidationCause) { state.withLock { $0.append(cause) } }
    }

    private func makeStore(
        _ mosh: ScriptedMoshSessions, flavor: TerminalSessionFlavor = .mosh,
        blankFrameGrace: Duration = .seconds(10), invalidations: Invalidations = Invalidations()
    ) -> AttachTerminalStore {
        AttachTerminalStore(
            target: .agentPane("w1:p1"), takeover: true,
            onMoshFailure: { cause in invalidations.append(cause) },
            blankFrameGrace: blankFrameGrace
        ) { request, handler in
            await handler.transportDidBecomeReady(1, flavor: flavor)
            let session = mosh.factory(
                ScriptedMoshSessions.bootstrap, request.cols, request.rows, .seconds(6))
            try await handler.runEndingSession(session)
        }
    }

    @Test func aBlankFirstMoshFrameKeepsTheTerminalConnecting() async throws {
        let mosh = ScriptedMoshSessions()
        let store = makeStore(mosh)
        store.viewDidResize(cols: 80, rows: 24)
        try await pollUntil("the session should start") { mosh.sessions.count == 1 }

        mosh.sessions[0].emit("\u{1B}[?1049h\u{1B}[H\u{1B}[2J")
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.status == .connecting, "mosh-server's blank screen must not flash")
        mosh.sessions[0].emit("\u{1B}[1;1H$ ready")
        try await pollUntil("the Agent's screen should go live") { store.status == .live }
        await store.stop()
    }

    @Test func aGenuinelyBlankMoshScreenGoesLiveAfterTheGrace() async throws {
        let mosh = ScriptedMoshSessions()
        let store = makeStore(mosh, blankFrameGrace: .milliseconds(200))
        store.viewDidResize(cols: 80, rows: 24)
        try await pollUntil("the session should start") { mosh.sessions.count == 1 }

        mosh.sessions[0].emit("\u{1B}[H\u{1B}[2J")
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.status == .connecting)
        try await pollUntil("a blank screen should still go live") { store.status == .live }
        await store.stop()
    }

    @Test func sshGoesLiveOnItsFirstBytes() async throws {
        let mosh = ScriptedMoshSessions()
        let store = makeStore(mosh, flavor: .ssh)
        store.viewDidResize(cols: 80, rows: 24)
        try await pollUntil("the session should start") { mosh.sessions.count == 1 }

        mosh.sessions[0].emit("\u{1B}[H\u{1B}[2J")
        try await pollUntil("SSH output is live at once", timeout: .seconds(1)) { store.status == .live }
        await store.stop()
    }

    @Test func aLostMoshLinkReattachesOncePerLiveStretch() async throws {
        let mosh = ScriptedMoshSessions()
        let invalidations = Invalidations()
        let store = makeStore(mosh, invalidations: invalidations)
        let lost = MoshLinkLost(timeoutMs: 15_000)
        store.viewDidResize(cols: 80, rows: 24)
        try await pollUntil("the session should start") { mosh.sessions.count == 1 }
        mosh.sessions[0].emit("$ one")
        try await pollUntil("the first session should go live") { store.status == .live }

        mosh.sessions[0].fail(lost)
        try await pollUntil("a lost link should reattach") { mosh.sessions.count == 2 }
        mosh.sessions[1].emit("$ two")
        try await pollUntil("the reattach should go live") { store.status == .live }

        mosh.sessions[1].fail(lost)
        try await pollUntil("a new live stretch earns another reattach") { mosh.sessions.count == 3 }
        mosh.sessions[2].fail(lost)
        try await pollUntil("a link lost before going live again should end") {
            store.status == .ended(MoshAttachSession.timeoutDetail(15_000))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(mosh.sessions.count == 3)
        #expect(invalidations.causes.isEmpty, "the link went, not mosh: no fallback to SSH")
    }
}

/// The review fixes to mosh's fast path (#105): link loss on an unverified
/// Host, the user's SSH choice, what is learned on which network, leaving
/// before a standby's client starts, and a re-targeted Host's history.
@MainActor
@Suite("Mosh fast path edges", .timeLimit(.minutes(1)))
struct MoshFastPathEdgeTests {
    private static let noPath = NetworkPathSnapshot(
        isSatisfied: false, interface: nil, interfaceName: nil, localAddress: nil)

    /// A live mosh session silent past the network timeout while its Host
    /// is reconnecting (unverified) reattaches visibly at once — Connecting,
    /// not a frozen live screen parked until the Host verifies again.
    @Test func aLostLinkOnAnUnverifiedHostReattachesVisibly() async throws {
        let first = await moshTransport()
        let redial = ScriptedTransportCallGate()
        let flow = MoshFlowFixture(
            transports: [first, await moshTransport()], gating: [2: redial])
        try await flow.startOnMosh()
        let entry = try await flow.openLiveMosh()

        await first.setConnectionAlive(false)
        await first.failEventStream(.channelFailed(detail: "dropped"))
        await redial.waitForEntry()
        #expect(flow.console.hostStatuses[flow.host.id] != .connected)
        flow.mosh.sessions[0].fail(MoshLinkLost(timeoutMs: MoshAttachSession.networkTimeoutMs))
        try await pollUntil("the lost link should show Connecting while the Host is unverified") {
            entry.attach.terminalStatus == .connecting
        }
        await redial.open()
        await flow.tearDown()
    }

    /// "Use SSH Instead" holds across a new connection and a new network,
    /// whatever is remembered for either, until the capsule asks again.
    @Test func useSSHInsteadHoldsAcrossConnectionsAndNetworks() async throws {
        let availability = MoshAvailabilityStore()
        let host = Host.fixture()
        availability.record(.available, for: host, network: homeNetwork)
        availability.record(.available, for: host, network: cafeNetwork)
        let first = await moshTransport()
        let second = await moshTransport()
        let flow = MoshFlowFixture(host: host, transports: [first, second], availability: availability)
        flow.path.read(ScriptedNetworkPathSource.home)
        try await flow.startOnMosh()
        flow.console.invalidateMosh(for: host.id, cause: .userChoseSSH)

        await first.setConnectionAlive(false)
        await first.failEventStream(.channelFailed(detail: "dropped"))
        try await pollUntil("the new connection should be verified") {
            flow.console.hostConnectionGenerations[host.id] == 1
                && flow.console.hostStatuses[host.id] == .connected
                && !flow.console.hostsAwaitingSnapshot.contains(host.id)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!flow.console.moshAvailability(for: host.id, generation: 1), "a new connection")

        flow.path.read(ScriptedNetworkPathSource.cafe)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!flow.console.moshAvailability(for: host.id, generation: 1), "a new network")
        #expect(await second.moshProbeCount == 0)

        await flow.console.forceMoshReprobe(for: host.id)
        try await pollUntil("the capsule's re-probe should bring mosh back") {
            flow.console.moshAvailability(for: host.id, generation: 1)
        }
        await flow.tearDown()
    }

    /// Another terminal's mosh run that began before "Use SSH Instead" may
    /// still fail on its own: its automatic fallback must not downgrade the
    /// user's choice, which still holds on the next network.
    @Test func anAutomaticFallbackNeverDowngradesTheUsersSSHChoice() async throws {
        let transport = await moshTransport()
        let flow = MoshFlowFixture(transports: [transport])
        flow.path.read(ScriptedNetworkPathSource.home)
        try await flow.startOnMosh()
        flow.console.invalidateMosh(for: flow.host.id, cause: .userChoseSSH)
        flow.console.invalidateMosh(for: flow.host.id, cause: .automaticFallback)
        #expect(flow.console.moshInvalidations[flow.host.id]?.cause == .userChoseSSH)

        flow.path.read(ScriptedNetworkPathSource.cafe)
        try await Task.sleep(for: .milliseconds(150))
        let generation = flow.console.hostConnectionGenerations[flow.host.id] ?? 0
        #expect(await transport.moshProbeCount == 1)
        #expect(!flow.console.moshAvailability(for: flow.host.id, generation: generation))
        await flow.tearDown()
    }

    /// A probe landing on another network's reading discards its answer.
    /// When that reading reverts inside the debounce no change is ever
    /// reported, so the generation's claim must be given back for the next
    /// reconcile to probe again.
    @Test func aDiscardedProbeLetsTheNextReconcileProbeAgain() async throws {
        let transport = await moshTransport()
        let probe = ScriptedTransportCallGate()
        await transport.gateNextMoshProbe(on: probe)
        let flow = MoshFlowFixture(transports: [transport], pathSettles: false)
        flow.path.read(ScriptedNetworkPathSource.home)
        try await flow.start()
        await probe.waitForEntry()

        flow.path.read(ScriptedNetworkPathSource.cafe)
        await probe.open()
        try await Task.sleep(for: .milliseconds(100))
        #expect(flow.console.moshProbe(for: flow.host.id) == nil, "the answer is discarded")
        flow.path.read(ScriptedNetworkPathSource.home)

        flow.console.reconcileMoshAvailability()
        try await pollUntil("the generation should be probed again") {
            await transport.moshProbeCount == 2
        }
        try await pollUntil("the second answer should count") {
            flow.console.moshProbe(for: flow.host.id)?.available == true
        }
        await flow.tearDown()
    }

    /// Losing the path is no new network: what is known stays, and nothing
    /// is probed over a connection with no network under it.
    @Test func losingThePathKeepsWhatIsKnownAndProbesNothing() async throws {
        let transport = await moshTransport()
        let flow = MoshFlowFixture(transports: [transport])
        flow.path.read(ScriptedNetworkPathSource.home)
        try await flow.startOnMosh()
        #expect(await transport.moshProbeCount == 1)

        flow.path.read(Self.noPath)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await transport.moshProbeCount == 1)
        #expect(flow.console.moshProbe(for: flow.host.id)?.available == true)
        await flow.tearDown()
    }

    /// A probe begun on one network and landing on another says nothing
    /// about either: the new network keeps what it remembered.
    @Test func aProbeLandingAfterANetworkChangeRecordsNothing() async throws {
        let availability = MoshAvailabilityStore()
        let host = Host.fixture()
        availability.record(.available, for: host, network: cafeNetwork)
        let transport = ScriptedTransport(snapshot: oneAgent)
        await transport.setMoshProbeFailure(TransportError.moshSessionFailed(detail: "no handshake"))
        let probe = ScriptedTransportCallGate()
        await transport.gateNextMoshProbe(on: probe)
        let flow = MoshFlowFixture(host: host, transports: [transport], availability: availability)
        flow.path.read(ScriptedNetworkPathSource.home)
        try await flow.start()
        await probe.waitForEntry()

        flow.path.read(ScriptedNetworkPathSource.cafe)
        try await pollUntil("the new network should answer from memory") {
            flow.console.moshProbe(for: host.id)?.available == true
        }
        await probe.open()
        try await Task.sleep(for: .milliseconds(150))
        #expect(availability.outcome(for: host, network: cafeNetwork) == .available)
        #expect(availability.outcome(for: host, network: homeNetwork) == nil)
        #expect(flow.console.moshProbe(for: host.id)?.available == true)
        await flow.tearDown()
    }

    /// A new network cancels a capsule re-probe, but the capsule shows
    /// testing until that re-probe ends, beside the new network's own
    /// probe; its answer is not recorded (MOSH-02).
    @Test func aNetworkChangeDuringAReprobeKeepsTestingUntilTheReprobeEnds() async throws {
        let transport = await moshTransport()
        let flow = MoshFlowFixture(transports: [transport])
        flow.path.read(ScriptedNetworkPathSource.home)
        try await flow.startOnMosh()
        let reprobe = ScriptedTransportCallGate()
        await transport.gateNextMoshProbe(on: reprobe)
        await flow.console.forceMoshReprobe(for: flow.host.id)
        await reprobe.waitForEntry()
        #expect(flow.console.moshCapsuleState(for: flow.host.id) == .testing)

        flow.path.read(ScriptedNetworkPathSource.cafe)
        try await pollUntil("the new network should be probed") {
            await transport.moshProbeCount == 3
                && flow.console.moshProbe(for: flow.host.id)?.available == true
        }
        #expect(flow.console.moshCapsuleState(for: flow.host.id) == .testing)

        await reprobe.open()
        try await pollUntil("the cancelled re-probe should end its testing state") {
            flow.console.moshCapsuleState(for: flow.host.id) == .available
        }
        #expect(await transport.moshProbeCount == 3)
        await flow.tearDown()
    }

    /// A session's proof that mosh works is remembered for the network, but
    /// does not lift this connection's automatic fallback (MOSH-02).
    @Test func aFirstContactProofDoesNotLiftAnInvalidation() async throws {
        let availability = MoshAvailabilityStore()
        let flow = MoshFlowFixture(transports: [await moshTransport()], availability: availability)
        flow.path.read(ScriptedNetworkPathSource.home)
        try await flow.startOnMosh()
        flow.console.invalidateMosh(for: flow.host.id, cause: .automaticFallback)
        availability.record(.unavailable, for: flow.host, network: homeNetwork)

        flow.console.recordMoshOutcome(.available, for: flow.host.id, on: flow.fastPath.currentNetwork)
        let generation = flow.console.hostConnectionGenerations[flow.host.id] ?? 0
        #expect(availability.outcome(for: flow.host, network: homeNetwork) == .available)
        #expect(!flow.console.moshAvailability(for: flow.host.id, generation: generation))
        #expect(flow.console.moshCapsuleState(for: flow.host.id) == .unavailable)

        flow.console.recordMoshOutcome(.unavailable, for: flow.host.id, on: flow.fastPath.currentNetwork)
        #expect(flow.console.moshProbe(for: flow.host.id)?.available == false)
        await flow.tearDown()
    }

    /// A session's first contact is learned for the network it started
    /// on; settling after a network change, it records nothing.
    @Test func aFirstContactAfterANetworkChangeRecordsNothing() async throws {
        let availability = MoshAvailabilityStore()
        let transport = await moshTransport()
        let flow = MoshFlowFixture(transports: [transport], availability: availability)
        flow.path.read(ScriptedNetworkPathSource.home)
        try await flow.startOnMosh()
        _ = flow.open(try flow.agent())
        try await pollUntil("the client should start") { flow.mosh.sessions.count == 1 }

        // The new network's own probe stays out of the way.
        await transport.gateNextMoshProbe(on: ScriptedTransportCallGate())
        flow.path.read(ScriptedNetworkPathSource.cafe)
        try await pollUntil("the new network should be probed") { await transport.moshProbeCount == 2 }
        flow.mosh.sessions[0].timeOutFirstContact()
        try await Task.sleep(for: .milliseconds(150))
        #expect(availability.outcome(for: flow.host, network: cafeNetwork) == nil)
        await flow.tearDown()
    }

    /// Leaving the detail while its attach waits for a standby still being
    /// made: the standby's client never starts, so its takeover never
    /// reaches the pane.
    @Test func leavingWhileAStandbyIsMadeStartsNoClient() async throws {
        let transport = await moshTransport(bootstrap: MoshFlowFixture.standbyBootstrap)
        let flow = MoshFlowFixture(transports: [transport])
        try await flow.startOnMosh()
        let bootstrap = ScriptedTransportCallGate()
        await transport.gateNextMoshBootstrap(on: bootstrap)
        flow.console.noteAgentIntent(try flow.agent().id)
        await bootstrap.waitForEntry()

        let entry = flow.open(try flow.agent())
        try await Task.sleep(for: .milliseconds(100))
        #expect(flow.fastPath.standbys.isPreparing(flow.key()), "the attach waits on the standby")
        let left = entry.attach.leave()
        await bootstrap.open()
        await left.value
        try await Task.sleep(for: .milliseconds(200))
        #expect(flow.mosh.sessions.isEmpty, "an attach already left must not start a client")
        await flow.tearDown()
    }

    /// A Host whose connection details change takes its mosh history off
    /// the device with it.
    @Test func aRetargetedHostForgetsItsMoshHistory() async throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "mosh-retarget-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "MoshAvailability.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let availability = MoshAvailabilityStore(fileURL: file)
        let host = Host.fixture(address: "old-target.example")
        // The re-targeted Host's connection stays pending: only the
        // re-target itself may drop the old coordinates.
        let redial = ScriptedTransportCallGate()
        let flow = MoshFlowFixture(
            host: host, transports: [await moshTransport()], gating: [2: redial],
            availability: availability)
        flow.path.read(ScriptedNetworkPathSource.home)
        try await flow.startOnMosh()
        try await pollUntil("the probe's outcome should be written") {
            (try? String(contentsOf: file, encoding: .utf8))?.contains("old-target.example") ?? false
        }

        var moved = host
        moved.address = "new-target.example"
        flow.console.setHosts([moved])
        try await pollUntil("the old target should leave the device") {
            (try? String(contentsOf: file, encoding: .utf8)).map { !$0.contains("old-target.example") }
                ?? false
        }
        await redial.open()
        await flow.tearDown()
    }
}

/// A mosh server heard again after a stall proves the link is back (#105):
/// a silent outage moves no network path, so without this the Host's SSH
/// sleeps out its backoff long after the Agent's terminal recovered.
@MainActor
@Suite("Mosh stall recovery", .timeLimit(.minutes(1)))
struct MoshStallRecoveryTests {
    private nonisolated static let longBackoff = ReconnectPolicy(
        initialDelay: .seconds(60), multiplier: 2, maxDelay: .seconds(60))

    /// A Host on mosh whose live session has been heard from.
    private func liveMosh() async throws -> (
        MoshFlowFixture, ScriptedTransport, AgentTerminalCache.Entry, ScriptedMoshSessions.Session
    ) {
        let first = await moshTransport()
        let flow = MoshFlowFixture(
            transports: [first, await moshTransport()], reconnectPolicy: Self.longBackoff)
        try await flow.startOnMosh()
        let entry = try await flow.openLiveMosh()
        let session = flow.mosh.sessions[0]
        session.setConnectivity(.connected)
        return (flow, first, entry, session)
    }

    /// The Host's SSH lost with no route back: it waits out a long backoff
    /// while the mosh session lives on.
    private func loseSSH(_ flow: MoshFlowFixture, _ transport: ScriptedTransport) async throws {
        await flow.connections.setUnreachable(true)
        await transport.setConnectionAlive(false)
        await transport.failEventStream(.channelFailed(detail: "dropped"))
        try await pollUntil("the Host should wait out its backoff") {
            if case .reconnecting = flow.console.hostStatuses[flow.host.id] { true } else { false }
        }
    }

    private func stallAndRecover(_ session: ScriptedMoshSessions.Session) async {
        session.setConnectivity(.stalled)
        try? await Task.sleep(for: .milliseconds(20))
        session.setConnectivity(.connected)
    }

    @Test func aHostInBackoffRedialsWhenItsMoshServerAnswersAgain() async throws {
        let (flow, first, entry, session) = try await liveMosh()
        try await loseSSH(flow, first)
        let attempts = await flow.connections.attempts

        await flow.connections.setUnreachable(false)
        await stallAndRecover(session)
        try await pollUntil("the Host should redial at once, not after its backoff") {
            flow.console.hostStatuses[flow.host.id] == .connected
        }
        #expect(await flow.connections.attempts == attempts + 1)
        #expect(entry.attach.terminalRunsLiveMosh)
        await flow.tearDown()
    }

    @Test func aConnectedHostIsLeftAloneWhenItsMoshServerAnswersAgain() async throws {
        let (flow, _, _, session) = try await liveMosh()

        await stallAndRecover(session)
        try await Task.sleep(for: .milliseconds(200))
        #expect(flow.console.moshRecoveryRedials[flow.host.id] == nil)
        #expect(await flow.connections.attempts == 1)
        #expect(flow.console.hostStatuses[flow.host.id] == .connected)
        await flow.tearDown()
    }

    @Test func redialsAreDebouncedPerHost() async throws {
        let (flow, first, _, session) = try await liveMosh()
        flow.console.moshRecoveryRedialInterval = .seconds(1)
        try await loseSSH(flow, first)
        let attempts = await flow.connections.attempts

        let start = ContinuousClock.now
        await stallAndRecover(session)
        try await pollUntil("the first answer should redial") {
            await flow.connections.attempts == attempts + 1
        }
        await stallAndRecover(session)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await flow.connections.attempts == attempts + 1, "a second answer inside the interval waits")

        try await Task.sleep(until: start + .milliseconds(1_200), clock: .continuous)
        await stallAndRecover(session)
        try await pollUntil("an answer after the interval should redial again") {
            await flow.connections.attempts == attempts + 2
        }
        await flow.tearDown()
    }

    @Test func aSuspendedConsoleNeverRedials() async throws {
        let (flow, first, _, _) = try await liveMosh()
        try await loseSSH(flow, first)
        await flow.console.suspend()
        let attempts = await flow.connections.attempts

        flow.console.moshServerAnsweredAfterStall(on: flow.host.id)
        try await Task.sleep(for: .milliseconds(200))
        #expect(flow.console.moshRecoveryRedials[flow.host.id] == nil)
        #expect(await flow.connections.attempts == attempts)
        await flow.tearDown()
    }
}
