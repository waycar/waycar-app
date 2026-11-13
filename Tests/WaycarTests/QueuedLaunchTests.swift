import Foundation
import Testing
import UIKit

@testable import Waycar

/// Queued Launches: a New Agent Start with no verified connection sends
/// nothing and waits on the device; the Console replays it through the
/// sheet's own store once the Host is back.
@MainActor
@Suite("Queued Launches", .timeLimit(.minutes(1)))
struct QueuedLaunchTests {
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "queued-launches-\(UUID().uuidString)", directoryHint: .isDirectory)
    private let hostID = UUID()

    private var launchesDirectory: URL {
        directory.appending(path: "launches", directoryHint: .isDirectory)
    }

    private struct GatedImage: ImageSelection {
        let gate: ScriptedTransportCallGate
        let data: Data

        func loadData() async throws -> Data {
            await gate.waitUntilOpen()
            return data
        }
    }

    @Test func aLaunchPreparedAfterTheDrainStartsOnTheSameConnection() async throws {
        defer { cleanUp() }
        let fixture = makeFixture()
        defer { fixture.console.setHosts([]) }
        try fixture.console.enqueueLaunch(
            QueuedLaunch(draft: makeDraft(), state: .waiting, createdAt: Date()))
        let gate = ScriptedTransportCallGate()
        let data = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).jpegData(
            withCompressionQuality: 1) { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            }
        let store = fixture.console.makeStartAgentStore(hosts: [fixture.host])
        await store.discoverAgents()
        store.launchSelection.wrappedValue = .agent(.claude)
        store.chatMode = false
        #expect(store.addFirstMessageAttachments([.photo(GatedImage(gate: gate, data: data))]) == 1)
        let submit = Task { await store.submit() }
        await gate.waitForEntry()
        await fixture.console.resume()
        try await waitUntil("the first drain should finish") {
            let starts = await fixture.transport.agentStarts.count
            return fixture.console.queuedLaunches.isEmpty && starts == 1
        }
        let projection = try #require(fixture.console.projection(on: hostID, backend: .herdr))
        let generation = projection.transportGeneration
        await gate.open()
        await submit.value
        guard case .queued = store.state else {
            Issue.record("expected a queued launch, got \(store.state)")
            return
        }
        try await waitUntil("the late launch should start without reconnecting") {
            await fixture.transport.agentStarts.count == 2
        }
        #expect(await fixture.transport.agentStarts.count == 2)
        #expect(projection.transportGeneration == generation)
    }

    @Test func aHostDrainsOldestFirstAndPersistsStartingBeforeDispatch() async throws {
        defer { cleanUp() }
        let fixture = makeFixture()
        defer { fixture.console.setHosts([]) }
        let first = QueuedLaunch(
            draft: makeDraft(name: "first"), state: .waiting,
            createdAt: Date(timeIntervalSince1970: 1))
        let second = QueuedLaunch(
            draft: makeDraft(name: "second"), state: .waiting,
            createdAt: Date(timeIntervalSince1970: 2))
        // Insertion order is not the drain order.
        try fixture.console.enqueueLaunch(second)
        try fixture.console.enqueueLaunch(first)
        let gate = ScriptedTransportCallGate()
        await fixture.transport.gateNextAgentStart(using: gate)

        await fixture.console.resume()
        await gate.waitForEntry()
        #expect(fixture.console.queuedLaunches.first { $0.id == first.id }?.state == .starting)
        #expect(fixture.launches.launches(on: hostID).map(\.state) == [.starting, .waiting])
        #expect(await fixture.transport.agentStarts.map(\.launchID) == [first.id])
        fixture.console.cancelQueuedLaunch(first.id)
        #expect(fixture.console.queuedLaunches.contains { $0.id == first.id })
        // A foreground wake while a drain awaits an answer must not overlap it.
        await fixture.console.resume()
        #expect(await fixture.transport.agentStarts.map(\.launchID) == [first.id])

        await gate.open()
        try await waitUntil("both launches should finish serially") {
            await fixture.transport.agentStarts.count == 2
                && fixture.console.queuedLaunches.isEmpty
        }
        #expect(await fixture.transport.agentStarts.map(\.launchID) == [first.id, second.id])
        #expect(fixture.launches.launches(on: hostID).isEmpty)
    }

    @Test func recordedStartsRestoreWithoutDispatchingAnotherLaunch() throws {
        defer { cleanUp() }
        var launch = QueuedLaunch(draft: makeDraft(), state: .starting, createdAt: Date())
        launch.startedPaneID = "w1:palready"
        launch.joinedRunningAgent = true
        launch.mayHaveStarted = false
        let launches = QueuedLaunchStore(directory: launchesDirectory)
        try launches.save(launch)
        // These fields remain the persistence boundary, including false
        // versus absent. A recorded pane is a handover, not another start.
        #expect(launches.launches(on: hostID) == [launch])
        let fixture = makeFixture()
        defer { fixture.console.setHosts([]) }
        #expect(fixture.console.queuedLaunches.isEmpty)
        #expect(fixture.console.startedAgentsByQueuedLaunch[launch.id] == launch.startedAgentID)
        #expect(launches.launches(on: hostID).isEmpty)
    }

    @Test func anOfflineStartIsKeptOnTheDeviceWithoutARequest() async throws {
        defer { cleanUp() }
        let fixture = makeFixture()
        defer { fixture.console.setHosts([]) }
        let store = fixture.console.makeStartAgentStore(hosts: [fixture.host])
        await store.discoverAgents()
        #expect(store.agentKindsAreCached)
        #expect(store.selectedWorkspaceID == "w1")
        store.launchSelection.wrappedValue = .agent(.claude)
        store.chatMode = false
        store.firstMessageText = "hello"
        #expect(store.canSubmit)

        await store.submit()

        let queued = try #require(fixture.console.queuedLaunches.first)
        #expect(store.state == .queued(queued.id))
        #expect(queued.state == .waiting)
        // Resolve against live inventory on its first try, not while offline.
        #expect(queued.draft.launchName == nil)
        #expect(queued.draft.sessionPin == nil)
        // The runtime the sheet showed rides along, so the replay lands there.
        #expect(
            queued.draft.dispatch
                == StartAgentStore.Dispatch(
                    destination: .existingWorkspace, launch: .agent(.claude), backend: .herdr))
        #expect(queued.draft.firstMessage == nil)
        #expect(fixture.console.pendingComposer(for: queued.id)?.messages.map(\.draftText) == ["hello"])
        let saved = fixture.launches.launches(on: hostID)
        #expect(saved.map(\.draft) == [queued.draft])
        #expect(saved.map(\.state) == [.waiting])
        #expect(await fixture.transport.agentStarts.isEmpty)
        #expect(await fixture.transport.agentDiscoveryCount == 0)
        #expect(await fixture.transport.snapshotFetchCount == 0)
    }

    /// The phone lost its network while the Host still reads Connected: its
    /// keepalive has not noticed the dead link yet. Start keeps the launch
    /// and sends nothing; it starts on that connection once the network is
    /// back.
    @Test func aStartWithNoNetworkWaitsWhileTheHostStillReadsConnected() async throws {
        defer { cleanUp() }
        let fixture = makeFixture()
        defer { fixture.console.setHosts([]) }
        let path = ScriptedNetworkPathSource()
        let monitor = path.monitor()
        fixture.console.followNetworkPath(monitor)
        path.read(ScriptedNetworkPathSource.home)
        let store = fixture.console.makeStartAgentStore(hosts: [fixture.host])
        await store.discoverAgents()
        store.launchSelection.wrappedValue = .agent(.claude)
        store.chatMode = false
        store.firstMessageText = "hello"
        await fixture.console.resume()
        try await waitUntil("the Host's rows should verify") {
            fixture.console.hasLiveSnapshots(on: hostID)
        }
        #expect(!store.startsWhenHostConnects)

        path.read(
            NetworkPathSnapshot(
                isSatisfied: false, interface: nil, interfaceName: nil, localAddress: nil))
        try await waitUntil("the device should read offline") { !fixture.console.hasNetwork }
        #expect(fixture.console.hostStatuses[hostID] == .connected)
        #expect(store.startsWhenHostConnects)
        await store.submit()

        let queued = try #require(fixture.console.queuedLaunches.first)
        #expect(store.state == .queued(queued.id))
        #expect(store.startKeepsLaunch)
        #expect(queued.state == .waiting)
        #expect(queued.draft.firstMessage == nil)
        #expect(fixture.console.pendingComposer(for: queued.id)?.messages.map(\.draftText) == ["hello"])
        #expect(await fixture.transport.agentStarts.isEmpty)

        path.read(ScriptedNetworkPathSource.home)
        try await waitUntil("the launch should start once the network is back") {
            await fixture.transport.agentStarts.count == 1
                && fixture.console.queuedLaunches.isEmpty
        }
        withExtendedLifetime(monitor) {}
    }

    /// A Start nothing of which reached the Host, which dropped meanwhile:
    /// the start was refused unsent, or a name-only New Workspace's home
    /// probe failed on the link. It waits for the Host like an offline
    /// Start, with its first message and runtime.
    @Test(arguments: [false, true])
    func aStartThatReachedNothingWaitsForTheHost(inNewWorkspace: Bool) async throws {
        defer { cleanUp() }
        let launches = QueuedLaunchStore(directory: launchesDirectory)
        let starts = StartCount()
        let unreachable = TransportError.sshUnreachable(detail: "The link dropped.")
        let store = StartAgentStore(
            hosts: [Host.fixture(id: hostID)],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            existingAgentNames: { _ in [] },
            discoverAgentKinds: { _ in [.claude] },
            remoteHome: { _ in throw unreachable },
            start: { _, _, _, _ in
                try await starts.refuse(RequestNotSentError(cause: unreachable))
            },
            awaitAgentVisible: { _ in },
            launchQueue: StartAgentStore.LaunchQueue(
                store: launches, enqueue: { try launches.save($0) }))
        await store.discoverAgents()
        store.launchSelection.wrappedValue = .agent(.claude)
        store.chatMode = false
        store.firstMessageText = "hello"
        if inNewWorkspace { store.selectNewWorkspace() }
        #expect(!store.startsWhenHostConnects)

        await store.submit()

        let kept = try #require(launches.launches(on: hostID).first)
        #expect(store.state == .queued(kept.id))
        #expect(store.startKeepsLaunch)
        #expect(kept.state == .waiting)
        #expect(kept.draft.firstMessage?.text == "hello")
        #expect(
            kept.draft.dispatch
                == StartAgentStore.Dispatch(
                    destination: inNewWorkspace
                        ? .newWorkspace(NewWorkspaceSpec(directory: "", label: nil))
                        : .existingWorkspace,
                    launch: .agent(.claude), backend: .herdr))
        #expect(starts.count == (inNewWorkspace ? 0 : 1))
    }

    @Test func aVerifiedConnectionStartsItOnceAndHandsOverItsFirstMessage() async throws {
        defer { cleanUp() }
        let fixture = makeFixture()
        defer { fixture.console.setHosts([]) }
        let source = directory.appending(path: "picked/report.txt", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("report".utf8).write(to: source)
        await fixture.transport.configureFileStaging(
            outcomes: [.success(try StagedFile(path: "/host/staged/report.txt"))])

        let store = fixture.console.makeStartAgentStore(hosts: [fixture.host])
        await store.discoverAgents()
        store.launchSelection.wrappedValue = .agent(.claude)
        store.chatMode = false
        store.firstMessageText = "see attached"
        #expect(store.addFirstMessageAttachments([.file(source)]) == 1)
        await store.submit()

        let queued = try #require(fixture.console.queuedLaunches.first)
        let pending = try #require(fixture.console.pendingComposer(for: queued.id))
        let record = try #require(pending.messages.first?.queued)
        let attachment = try #require(record.attachments.first)
        #expect(fixture.console.queuedMessageStore.fileURL(of: attachment, in: record) != nil)
        let launchDirectory = fixture.launches.launchDirectory(hostID: hostID, launchID: queued.id)

        await fixture.console.resume()
        try await waitUntil("the launch should start and its first message go out") {
            await fixture.transport.agentPromptParams.count == 1
                && fixture.console.queuedLaunches.isEmpty
        }

        #expect(await fixture.transport.agentStarts.count == 1)
        #expect(await fixture.transport.fileStageRequests.count == 1)
        #expect(
            await fixture.transport.agentPromptParams == [
                AgentPromptParams(target: "w1:pnew", text: "see attached /host/staged/report.txt")
            ])
        #expect(fixture.launches.launches(on: hostID).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: launchDirectory.path))
    }

    @Test func aLaunchTheAppEndedInReplaysAutomaticallyAndHandsOverMessagesOnce() async throws {
        defer { cleanUp() }
        let draft = makeDraft(
            name: "claude", firstMessage: .init(text: "hello", attachments: []))
        try QueuedLaunchStore(directory: launchesDirectory)
            .save(QueuedLaunch(draft: draft, state: .starting, createdAt: Date()))

        let fixture = makeFixture()
        defer { fixture.console.setHosts([]) }
        #expect(fixture.console.queuedLaunches.map(\.state) == [.waiting])
        #expect(fixture.launches.launches(on: hostID).map(\.state) == [.waiting])
        #expect(fixture.console.queuedLaunches.first?.mayHaveStarted == true)
        #expect(fixture.launches.launches(on: hostID).first?.mayHaveStarted == true)

        await fixture.console.resume()
        try await waitUntil("the launch and its message should replay automatically") {
            await fixture.transport.agentPromptParams.count == 1
                && fixture.console.queuedLaunches.isEmpty
        }
        let request = try #require(await fixture.transport.agentStarts.first)
        #expect(request.mayHaveStarted)
        #expect(request.launchID == draft.id)
        #expect(request.name == "claude")
        #expect(await fixture.transport.agentPromptParams.map(\.text) == ["hello"])
        await fixture.console.resume()
        #expect(await fixture.transport.agentStarts.count == 1)
        #expect(await fixture.transport.agentPromptParams.count == 1)
    }

    @Test func aReplayWhoseAnswerIsLostChecksTheSameLaunchOnReconnect() async throws {
        defer { cleanUp() }
        let draft = makeDraft()
        try QueuedLaunchStore(directory: launchesDirectory)
            .save(QueuedLaunch(draft: draft, state: .waiting, createdAt: Date()))
        let reconnect = ScriptedTransportCallGate()
        let fixture = makeFixture(reconnectGate: reconnect)
        defer { fixture.console.setHosts([]) }
        await fixture.transport.setStartFailure(.sshUnreachable(detail: "The link dropped."))

        await fixture.console.resume()
        await reconnect.waitForEntry()
        try await waitUntil("the lost answer should return the launch to waiting") {
            fixture.console.queuedLaunches.map(\.state) == [.waiting]
        }
        #expect(fixture.launches.launches(on: hostID).map(\.state) == [.waiting])
        #expect(fixture.launches.launches(on: hostID).first?.mayHaveStarted == true)
        #expect(await fixture.transport.agentStarts.count == 1)

        await fixture.transport.setStartFailure(nil)
        await reconnect.open()
        try await waitUntil("the next connection should replay it automatically") {
            await fixture.transport.agentStarts.count == 2
                && fixture.console.queuedLaunches.isEmpty
        }
        let requests = await fixture.transport.agentStarts
        #expect(requests.count == 2)
        #expect(requests.first?.mayHaveStarted == false)
        #expect(requests.last?.mayHaveStarted == true)
        #expect(requests.map(\.launchID) == [draft.id, draft.id])
        #expect(requests.first?.name == requests.last?.name)
    }

    @Test(arguments: [false, true])
    func aHerdrLaunchTagAvoidsExistingTabLabels(explicitName: Bool) async throws {
        defer { cleanUp() }
        let base = explicitName ? "reviewer" : "claude"
        let reconnect = ScriptedTransportCallGate()
        let fixture = makeFixture(reconnectGate: reconnect, tabLabels: [base])
        defer { fixture.console.setHosts([]) }
        let store = fixture.console.makeStartAgentStore(hosts: [fixture.host])
        await store.discoverAgents()
        store.launchSelection.wrappedValue = .agent(.claude)
        store.chatMode = false
        if explicitName { store.name = base }
        await store.submit()
        let queued = try #require(fixture.console.queuedLaunches.first)
        #expect(queued.draft.launchName == nil)
        await fixture.transport.setStartFailure(.sshUnreachable(detail: "The answer was lost."))

        await fixture.console.resume()
        await reconnect.waitForEntry()
        try await waitUntil("the lost answer should keep the minted name") {
            fixture.console.queuedLaunches.first?.state == .waiting
        }
        let request = try #require(await fixture.transport.agentStarts.first)
        let persisted = try #require(fixture.launches.launches(on: hostID).first)
        #expect(request.name == base + "-2")
        #expect(persisted.draft.launchName == request.name)
        #expect(persisted.draft.id == queued.id)
        fixture.console.cancelQueuedLaunch(queued.id)
        await reconnect.open()
    }

    @Test func aReconnectVerifiedBeforeTheLostAnswerStillReplaysOnThatConnection() async throws {
        defer { cleanUp() }
        let workspace = WorkspaceInfo.fixture(workspaceID: "w1", label: "Proj")
        let empty = SessionSnapshot.fixture(workspaces: [workspace])
        let replacement = ScriptedTransport(snapshot: empty)
        let fixture = makeFixture(replacementTransport: replacement)
        defer { fixture.console.setHosts([]) }
        await fixture.transport.setSnapshot(empty)
        let answer = ScriptedTransportCallGate()
        await fixture.transport.gateNextAgentStart(using: answer)
        await fixture.transport.setStartFailure(.sshUnreachable(detail: "The old answer was lost."))
        let draft = makeDraft()
        try fixture.console.enqueueLaunch(.init(draft: draft, state: .waiting, createdAt: Date()))
        await fixture.console.resume()
        await answer.waitForEntry()
        let projection = try #require(fixture.console.projection(on: hostID, backend: .herdr))
        let firstGeneration = projection.transportGeneration
        try await fixture.transport.close()
        try await waitUntil("the replacement should verify while the old start is outstanding") {
            fixture.console.hasLiveSnapshots(on: hostID)
                && projection.transportGeneration > firstGeneration
        }
        #expect(fixture.console.queuedLaunches.first?.state == .starting)
        #expect(await replacement.agentStarts.isEmpty)
        let replacementGeneration = projection.transportGeneration
        // No event follows this snapshot change: only the drain's completion
        // can notice the connection that verified while it was still running.
        await replacement.setSnapshot(.fixture(
            agents: [.fixture(paneID: "w1:pnew")], workspaces: [workspace]))
        await answer.open()

        try await waitUntil("the already-verified replacement should replay exactly once") {
            await replacement.agentStarts.count == 1 && fixture.console.queuedLaunches.isEmpty
        }
        let first = try #require(await fixture.transport.agentStarts.first)
        let retried = try #require(await replacement.agentStarts.first)
        #expect(await fixture.transport.agentStarts.count == 1)
        #expect(await replacement.agentStarts.count == 1)
        #expect(retried.mayHaveStarted)
        #expect(retried.launchID == draft.id)
        #expect(retried.name == first.name)
        #expect(projection.transportGeneration == replacementGeneration)
    }

    @Test func aLiveStartWhoseAnswerIsLostKeepsItsFirstMessageAndBanner() async throws {
        defer { cleanUp() }
        let launches = QueuedLaunchStore(directory: launchesDirectory)
        let store = StartAgentStore(
            hosts: [Host.fixture(id: hostID)],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            existingAgentNames: { _ in [] },
            discoverAgentKinds: { _ in [.claude] },
            remoteHome: { _ in "/home/dev" },
            start: { _, _, _, _ in
                throw TransportError.sshUnreachable(detail: "The answer was lost.")
            },
            awaitAgentVisible: { _ in },
            launchQueue: StartAgentStore.LaunchQueue(
                store: launches, enqueue: { try launches.save($0) }))
        await store.discoverAgents()
        store.launchSelection.wrappedValue = .agent(.claude)
        store.chatMode = false
        store.firstMessageText = "hello"

        await store.submit()

        let kept = try #require(launches.launches(on: hostID).first)
        #expect(store.state == .queued(kept.id))
        #expect(store.startKeepsLaunch)
        #expect(kept.state == .waiting)
        #expect(kept.mayHaveStarted == true)
        #expect(kept.draft.launchName == "claude")
        #expect(kept.draft.firstMessage?.text == "hello")
    }

    @Test(arguments: [false, true])
    func followUpsWaitForTheirLaunchAndSurviveRelaunch(relaunch: Bool) async throws {
        defer { cleanUp() }
        let offline = makeFixture()
        defer { offline.console.setHosts([]) }
        let launch = try await queueConversation(in: offline)
        let fixture = relaunch ? makeFixture() : offline
        defer { fixture.console.setHosts([]) }
        let pending = try #require(fixture.console.pendingComposer(for: launch.id))
        #expect(pending.messages.map(\.draftText) == ["hello", "second", "third"])
        #expect(pending.messages.allSatisfy { $0.isWaiting })
        #expect(fixture.console.queuedLaunch(forPendingAgent: launch.pendingAgentID)?.id == launch.id)
        #expect(QueuedLaunch.launchID(forPendingAgent: launch.pendingAgentID) == launch.id)
        let records = fixture.console.queuedMessageStore.messages(on: hostID)
        #expect(records.count == 3)
        #expect(records.allSatisfy { $0.agent == launch.pendingIdentity })
        pending.drainQueue()
        await fixture.transport.configureImageStaging(
            outcomes: [.success(try StagedImage(path: "/host/staged/image.jpeg"))])
        #expect(await fixture.transport.agentStarts.isEmpty)
        #expect(await fixture.transport.agentPromptParams.isEmpty)
        #expect(await fixture.transport.stageRequests.isEmpty)

        await fixture.console.resume()
        try await waitUntil("all three messages should follow the launch") {
            await fixture.transport.agentPromptParams.count == 3
        }
        #expect(await fixture.transport.agentStarts.count == 1)
        #expect(await fixture.transport.agentPromptParams == [
            AgentPromptParams(target: "w1:pnew", text: "hello"),
            AgentPromptParams(target: "w1:pnew", text: "second"),
            AgentPromptParams(target: "w1:pnew", text: "third /host/staged/image.jpeg"),
        ])
        #expect(await fixture.transport.stageRequests.count == 1)
        #expect(fixture.console.queuedMessageStore.messages(on: hostID).isEmpty)
        #expect(fixture.launches.launches(on: hostID).isEmpty)
        #expect(fixture.console.queuedLaunches.isEmpty)
        #expect(fixture.console.pendingComposer(for: launch.id) == nil)
        #expect(fixture.console.startedAgentsByQueuedLaunch[launch.id]
            == ConsoleAgent.ID(hostID: hostID, paneID: "w1:pnew"))
        for record in records {
            #expect(!FileManager.default.fileExists(
                atPath: fixture.console.queuedMessageStore.messageDirectory(for: record).path))
        }
        // Explicit drains and another foreground pass cannot send them again.
        await fixture.console.resume()
        #expect(await fixture.transport.agentStarts.count == 1)
        #expect(await fixture.transport.agentPromptParams.count == 3)
    }

    @Test func anInterruptedReplayKeepsItsMessagesUntilCancelDeletesTheirCopies() async throws {
        defer { cleanUp() }
        let reconnect = ScriptedTransportCallGate()
        let fixture = makeFixture(reconnectGate: reconnect)
        defer { fixture.console.setHosts([]) }
        let launch = try await queueConversation(in: fixture)
        let records = fixture.console.queuedMessageStore.messages(on: hostID)
        await fixture.transport.setStartFailure(.sshUnreachable(detail: "The link dropped."))
        await fixture.console.resume()
        await reconnect.waitForEntry()
        try await waitUntil("the lost answer should return the launch to waiting") {
            fixture.console.queuedLaunches.map(\.state) == [.waiting]
        }
        #expect(await fixture.transport.agentStarts.count == 1)
        #expect(await fixture.transport.agentPromptParams.isEmpty)
        #expect(await fixture.transport.stageRequests.isEmpty)
        #expect(fixture.console.queuedMessageStore.messages(on: hostID) == records)
        #expect(fixture.console.pendingComposer(for: launch.id)?.waitingCount == 3)
        fixture.console.cancelQueuedLaunch(launch.id)
        await reconnect.open()
        #expect(fixture.console.pendingComposer(for: launch.id) == nil)
        #expect(fixture.console.queuedMessageStore.messages(on: hostID).isEmpty)
        #expect(fixture.launches.launches(on: hostID).isEmpty)
        for record in records {
            #expect(!FileManager.default.fileExists(
                atPath: fixture.console.queuedMessageStore.messageDirectory(for: record).path))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.launches.launchDirectory(
            hostID: hostID, launchID: launch.id).path))
    }

    @Test func legacyFirstMessagesMigrateOnceBeforeFollowUps() async throws {
        defer { cleanUp() }
        let launch = QueuedLaunch(
            draft: makeDraft(firstMessage: LaunchDraft.FirstMessage(text: "hello", attachments: [])),
            state: .waiting, createdAt: Date())
        let launches = QueuedLaunchStore(directory: launchesDirectory)
        try launches.save(launch)
        let first = makeFixture()
        defer { first.console.setHosts([]) }
        let pending = try #require(first.console.pendingComposer(for: launch.id))
        #expect(pending.messages.map(\.draftText) == ["hello"])
        #expect(pending.messages.map(\.id) == [launch.id])
        #expect(try #require(launches.launches(on: hostID).first).draft.firstMessage == nil)
        // Simulate a kill between the deterministic message save and the
        // launch rewrite: the old field is still present alongside its record.
        try launches.save(launch)
        let second = makeFixture()
        defer { second.console.setHosts([]) }
        let restored = try #require(second.console.pendingComposer(for: launch.id))
        #expect(restored.messages.map(\.draftText) == ["hello"])
        #expect(restored.messages.map(\.id) == [launch.id])
        #expect(second.console.queuedMessageStore.messages(on: hostID).count == 1)
        let saved = try #require(launches.launches(on: hostID).first)
        let json = try Data(contentsOf: launches.launchDirectory(hostID: hostID, launchID: launch.id)
            .appending(path: "launch.json"))
        #expect(saved.draft.firstMessage == nil)
        #expect(!String(decoding: json, as: UTF8.self).contains("firstMessage"))
    }

    @Test func aNonFlagPresetPrecedesTheFirstMessageAndFollowUpOnceAfterRestore() async throws {
        defer { cleanUp() }
        let offline = makeFixture(kind: .copilot)
        defer { offline.console.setHosts([]) }
        let launch = QueuedLaunch(
            draft: makeDraft(
                kind: .copilot, presetFirstMessage: "preset",
                firstMessage: .init(text: "first", attachments: [])),
            state: .waiting, createdAt: Date())
        try offline.console.enqueueLaunch(launch)
        let pending = try #require(offline.console.pendingComposer(for: launch.id))
        #expect(await pending.send("follow-up") == .queued)
        #expect(pending.messages.map(\.draftText) == ["preset", "first", "follow-up"])
        let preset = try #require(pending.messages.first)
        let first = try #require(pending.messages.first { $0.id == launch.id })
        #expect(preset.id == launch.presetMessageID)
        #expect(launch.presetMessageID != launch.id)
        #expect(preset.sentAt < first.sentAt)
        let saved = try #require(offline.launches.launches(on: hostID).first)
        #expect(saved.draft.presetFirstMessage == nil)
        #expect(saved.draft.firstMessage == nil)
        #expect(await offline.transport.agentStarts.isEmpty)
        #expect(await offline.transport.agentPromptParams.isEmpty)
        // The records reached disk, but the old fields still ride the
        // launch: replaying that migration must not duplicate either one.
        try offline.launches.save(launch)
        let restored = makeFixture(kind: .copilot)
        defer { restored.console.setHosts([]) }
        let restoredPending = try #require(restored.console.pendingComposer(for: launch.id))
        #expect(restoredPending.messages.map(\.draftText) == ["preset", "first", "follow-up"])
        #expect(restoredPending.messages.map(\.id) == pending.messages.map(\.id))

        await restored.console.resume()
        try await waitUntil("the preset should precede the First Message and follow-up") {
            await restored.transport.agentPromptParams.count == 3
        }
        #expect(await restored.transport.agentStarts.count == 1)
        #expect(await restored.transport.agentPromptParams.map(\.text) == [
            "preset", "first", "follow-up",
        ])
        #expect(restored.console.queuedLaunches.isEmpty)
        #expect(restored.console.queuedMessageStore.messages(on: hostID).isEmpty)
        await restored.console.resume()
        #expect(await restored.transport.agentStarts.count == 1)
        #expect(await restored.transport.agentPromptParams.count == 3)
    }

    @Test func aPartiallyMovedJoinedQueueRestoresInOrderAndWaitsForSendAnyway() async throws {
        defer { cleanUp() }
        let offline = makeFixture(kind: .copilot)
        defer { offline.console.setHosts([]) }
        let launch = QueuedLaunch(
            draft: makeDraft(
                kind: .copilot, presetFirstMessage: "preset",
                firstMessage: .init(text: "first", attachments: [])),
            state: .waiting, createdAt: Date())
        try offline.console.enqueueLaunch(launch)
        let pending = try #require(offline.console.pendingComposer(for: launch.id))
        #expect(await pending.send("follow-up") == .queued)
        let records = offline.console.queuedMessageStore.messages(on: hostID)
        let prefix = try #require(records.first)
        let agentID = ConsoleAgent.ID(hostID: hostID, paneID: "w1:pnew")
        let recipient = QueuedMessage.AgentIdentity(
            paneID: agentID.paneID, kind: nil, session: nil)
        // Simulate a kill after moving just the prefix. A joined Agent must
        // not receive any part of that queue without the user's Send Anyway.
        _ = try offline.console.queuedMessageStore.rekey(prefix, to: recipient, from: launch.id)
        var saved = try #require(offline.launches.launches(on: hostID).first)
        saved.state = .starting
        saved.startedPaneID = agentID.paneID
        saved.joinedRunningAgent = true
        try offline.launches.save(saved)

        let restored = makeFixture(kind: .copilot)
        defer { restored.console.setHosts([]) }
        #expect(restored.console.queuedLaunches.isEmpty)
        #expect(restored.console.startedAgentsByQueuedLaunch[launch.id] == agentID)
        let moved = restored.console.queuedMessageStore.messages(on: hostID)
        #expect(moved.map(\.id) == records.map(\.id))
        #expect(moved.allSatisfy { $0.agent == recipient && $0.originLaunchID == launch.id })
        #expect(!restored.console.queuedMessageStore.hasMessages(for: launch.pendingAgentID))
        await restored.console.resume()
        try await waitUntil("the joined Agent's row should load") {
            restored.console.agents.contains { $0.id == agentID }
        }
        let agent = try #require(restored.console.agents.first { $0.id == agentID })
        let composer = restored.console.composerStore(for: agent)
        try await waitUntil("every joined-launch message should be held") {
            composer.messages.count == 3 && composer.messages.allSatisfy(\.isHeld)
        }
        #expect(await restored.transport.agentStarts.isEmpty)
        #expect(await restored.transport.agentPromptParams.isEmpty)
        for record in records { composer.sendAnyway(record.id) }
        try await waitUntil("Send Anyway should deliver the restored queue in order") {
            await restored.transport.agentPromptParams.count == 3
        }
        #expect(await restored.transport.agentPromptParams.map(\.text) == [
            "preset", "first", "follow-up",
        ])
        #expect(await restored.transport.agentStarts.isEmpty)
    }

    @Test func aRealPaneSendWaitsBehindItsLaunchMessagesDuringTheMarkerWrite() async throws {
        defer { cleanUp() }
        let fixture = makeFixture()
        defer { fixture.console.setHosts([]) }
        let launch = try await queueConversation(in: fixture)
        let pending = try #require(fixture.console.pendingComposer(for: launch.id))
        await fixture.transport.configureImageStaging(
            outcomes: [.success(try StagedImage(path: "/host/staged/image.jpeg"))])
        let gate = ScriptedTransportCallGate()
        await fixture.transport.gateNextChatModeMarkerWrite(using: gate)

        await fixture.console.resume()
        await gate.waitForEntry()
        #expect(await fixture.transport.agentStarts.count == 1)
        #expect(pending.isLaunchStarting)
        #expect(await pending.send("too late") == .ignored)
        let agentID = ConsoleAgent.ID(hostID: hostID, paneID: "w1:pnew")
        let agent = try #require(fixture.console.agents.first { $0.id == agentID })
        let composer = fixture.console.composerStore(for: agent)
        #expect(composer.holdingForLaunch != nil)
        #expect(await composer.send("fourth") == .queued)
        composer.drainQueue()
        #expect(await fixture.transport.agentPromptParams.isEmpty)

        await gate.open()
        try await waitUntil("the real-pane Send should follow every pending message") {
            await fixture.transport.agentPromptParams.count == 4
        }
        #expect(await fixture.transport.agentStarts.count == 1)
        #expect(await fixture.transport.agentPromptParams.map(\.text) == [
            "hello", "second", "third /host/staged/image.jpeg", "fourth",
        ])
        #expect(composer.holdingForLaunch == nil)
        #expect(fixture.console.queuedMessageStore.messages(on: hostID).isEmpty)
        #expect(fixture.console.queuedLaunches.isEmpty)
    }

    /// A Host re-targeted after the replay's Agent or shell started (while
    /// the Agent's Chat Marker is written, or the shell's start is still
    /// answering) gets nothing from it: no first message.
    @Test(arguments: [StartAgentStore.LaunchSelection.agent(.claude), .shell])
    func aReplayRetargetedAfterItStartedHandsTheReplacementNothing(
        _ launch: StartAgentStore.LaunchSelection
    ) async throws {
        defer { cleanUp() }
        let isShell = launch == .shell
        try QueuedLaunchStore(directory: launchesDirectory).save(
            QueuedLaunch(
                draft: makeDraft(
                    launch: launch,
                    firstMessage: isShell
                        ? nil : LaunchDraft.FirstMessage(text: "hello", attachments: [])),
                state: .waiting, createdAt: Date()))
        let fixture = makeFixture()
        defer { fixture.console.setHosts([]) }
        let gate = ScriptedTransportCallGate()
        if isShell {
            await fixture.transport.gateNextShellStart(using: gate)
        } else {
            // claude's launch pins its session, so it writes a Chat Marker.
            await fixture.transport.gateNextChatModeMarkerWrite(using: gate)
        }

        await fixture.console.resume()
        await gate.waitForEntry()
        fixture.console.setHosts([Host.fixture(id: hostID, address: "other.example")])
        try await waitUntil("the replacement Host's rows should verify") {
            fixture.console.hasLiveSnapshots(on: hostID)
        }
        await gate.open()
        try await Task.sleep(for: .milliseconds(300))

        #expect(fixture.console.queuedLaunches.isEmpty)
        #expect(await fixture.transport.agentPromptParams.isEmpty)
        let messages = QueuedMessageStore(
            directory: directory.appending(path: "messages", directoryHint: .isDirectory))
        #expect(messages.messages(on: hostID).isEmpty)
    }

    // MARK: Lifecycle pins (LAUNCH-06, LAUNCH-08)

    /// Records exactly as the app writes them today: decoding and saving
    /// one again leaves its JSON as it was, nil versus false included.
    @Test func aRecordWrittenByTheAppDecodesAndSavesUnchanged() throws {
        defer { cleanUp() }
        let launches = QueuedLaunchStore(directory: launchesDirectory)
        for (json, expected) in Self.writtenRecords(hostID: hostID) {
            let id = expected.id
            let folder = try launches.preparedDirectory(hostID: hostID, launchID: id)
            let file = folder.appending(path: "launch.json", directoryHint: .notDirectory)
            try Data(json.utf8).write(to: file)
            let decoded = try #require(launches.launches(on: hostID).first { $0.id == id })
            #expect(decoded == expected)
            try launches.save(decoded)
            let written = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? NSDictionary
            let original = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary
            #expect(written == original, "\(json)")
        }
    }

    @Test func aLegacyUncertainRecordRestoresWaitingAndChecksItsTagOnReplay() async throws {
        defer { cleanUp() }
        let draft = makeDraft(name: "claude")
        try QueuedLaunchStore(directory: launchesDirectory)
            .save(QueuedLaunch(draft: draft, state: .uncertain, createdAt: Date()))
        let fixture = makeFixture()
        defer { fixture.console.setHosts([]) }
        #expect(fixture.console.queuedLaunches.map(\.state) == [.waiting])
        #expect(fixture.console.queuedLaunches.first?.mayHaveStarted == true)
        #expect(fixture.launches.launches(on: hostID).map(\.state) == [.waiting])
        #expect(fixture.launches.launches(on: hostID).first?.mayHaveStarted == true)

        await fixture.console.resume()
        try await waitUntil("the restored launch should replay") {
            await fixture.transport.agentStarts.count == 1 && fixture.console.queuedLaunches.isEmpty
        }
        let request = try #require(await fixture.transport.agentStarts.first)
        #expect(request.mayHaveStarted)
        #expect(request.launchID == draft.id)
    }

    /// A failed launch waits for the user: a connection does not replay it,
    /// Retry on a waiting one does nothing, and Retry replays a failed one
    /// once with the identity it had.
    @Test func onlyRetryReplaysAFailedLaunchAndOnlyOnce() async throws {
        defer { cleanUp() }
        let draft = makeDraft(name: "claude")
        var failed = QueuedLaunch(draft: draft, state: .failed("No start"), createdAt: Date())
        failed.mayHaveStarted = true
        try QueuedLaunchStore(directory: launchesDirectory).save(failed)
        let fixture = makeFixture()
        defer { fixture.console.setHosts([]) }
        #expect(fixture.console.queuedLaunches == [failed])

        await fixture.console.resume()
        try await waitUntil("the Host's rows should verify") {
            fixture.console.hasLiveSnapshots(on: hostID)
        }
        #expect(await fixture.transport.agentStarts.isEmpty)
        #expect(fixture.console.queuedLaunches == [failed])

        fixture.console.retryQueuedLaunch(draft.id)
        try await waitUntil("Retry should replay it") {
            await fixture.transport.agentStarts.count == 1 && fixture.console.queuedLaunches.isEmpty
        }
        let request = try #require(await fixture.transport.agentStarts.first)
        #expect(request.mayHaveStarted)
        #expect(request.launchID == draft.id)
        #expect(request.name == "claude")
        fixture.console.retryQueuedLaunch(draft.id)
        await fixture.console.resume()
        #expect(await fixture.transport.agentStarts.count == 1)
    }

    /// The app ended after a replay recorded its started pane. Restore hands
    /// the messages to that pane without the network; when a record cannot
    /// be read yet, the launch waits with its pane, and the next connection
    /// finishes the handover. Neither starts the Agent again.
    @Test(arguments: [false, true])
    func aRecordedStartHandsItsMessagesToThatPaneWithoutAnotherStart(interrupted: Bool) async throws {
        defer { cleanUp() }
        let offline = makeFixture()
        defer { offline.console.setHosts([]) }
        let launch = try await queueConversation(in: offline)
        let records = offline.console.queuedMessageStore.messages(on: hostID)
        #expect(records.count == 3)
        var saved = try #require(offline.launches.launches(on: hostID).first)
        saved.state = .starting
        saved.startedPaneID = "w1:pnew"
        saved.joinedRunningAgent = false
        try offline.launches.save(saved)
        var repair: (() throws -> Void)?
        if interrupted { repair = try makeUnreadable(try #require(records.last), in: offline) }

        let restored = makeFixture()
        defer { restored.console.setHosts([]) }
        let agentID = ConsoleAgent.ID(hostID: hostID, paneID: "w1:pnew")
        if interrupted {
            let waiting = try #require(restored.console.queuedLaunches.first)
            #expect(waiting.state == .waiting)
            #expect(waiting.mayHaveStarted == true)
            #expect(waiting.startedPaneID == "w1:pnew")
            #expect(waiting.joinedRunningAgent == false)
            #expect(restored.launches.launches(on: hostID) == [waiting])
            #expect(restored.console.queuedMessageStore.messages(on: hostID).map(\.agentID)
                == [agentID, agentID])
            try repair?()
        } else {
            #expect(restored.console.queuedLaunches.isEmpty)
            #expect(restored.launches.launches(on: hostID).isEmpty)
            #expect(restored.console.queuedMessageStore.messages(on: hostID).map(\.agentID)
                == [agentID, agentID, agentID])
        }
        #expect(restored.console.startedAgentsByQueuedLaunch[launch.id] == agentID)
        await restored.transport.configureImageStaging(
            outcomes: [.success(try StagedImage(path: "/host/staged/image.jpeg"))])

        await restored.console.resume()
        try await waitUntil("every message should reach the recorded pane") {
            await restored.transport.agentPromptParams.count == 3
        }
        #expect(await restored.transport.agentStarts.isEmpty)
        #expect(await restored.transport.agentPromptParams.map(\.text) == [
            "hello", "second", "third /host/staged/image.jpeg",
        ])
        #expect(await restored.transport.agentPromptParams.allSatisfy { $0.target == "w1:pnew" })
        #expect(restored.console.queuedLaunches.isEmpty)
        #expect(restored.launches.launches(on: hostID).isEmpty)
        await restored.console.resume()
        #expect(await restored.transport.agentPromptParams.count == 3)
    }

    /// The replay's Agent started, but one of its messages could not move:
    /// the launch fails with its pane recorded, the real pane holds the
    /// moved prefix, nothing is sent, and Retry finishes the handover
    /// without starting the Agent again.
    @Test func aHandoverThatCannotFinishHoldsThePaneUntilRetryFinishesIt() async throws {
        defer { cleanUp() }
        let fixture = makeFixture()
        defer { fixture.console.setHosts([]) }
        let launch = try await queueConversation(in: fixture)
        let records = fixture.console.queuedMessageStore.messages(on: hostID)
        let repair = try makeUnreadable(try #require(records.last), in: fixture)
        await fixture.transport.configureImageStaging(
            outcomes: [.success(try StagedImage(path: "/host/staged/image.jpeg"))])

        await fixture.console.resume()
        let message = "The Agent started, but its messages couldn't be moved. Retry to finish sending them."
        try await waitUntil("the handover should fail") {
            fixture.console.queuedLaunches.first?.state == .failed(message)
        }
        let failed = try #require(fixture.console.queuedLaunches.first)
        #expect(failed.startedPaneID == "w1:pnew")
        #expect(fixture.launches.launches(on: hostID) == [failed])
        let agentID = ConsoleAgent.ID(hostID: hostID, paneID: "w1:pnew")
        let agent = try #require(fixture.console.agents.first { $0.id == agentID })
        let composer = fixture.console.composerStore(for: agent)
        #expect(composer.holdingForLaunch != nil)
        #expect(composer.messages.map(\.draftText) == ["hello", "second"])
        #expect(fixture.console.pendingComposer(for: launch.id)?.messages.map(\.draftText) == ["third"])
        #expect(await fixture.transport.agentPromptParams.isEmpty)
        // A failed launch is the user's: another connection does not retry it.
        await fixture.console.resume()
        #expect(await fixture.transport.agentPromptParams.isEmpty)

        try repair()
        fixture.console.retryQueuedLaunch(launch.id)
        try await waitUntil("Retry should finish the handover in order") {
            await fixture.transport.agentPromptParams.count == 3
        }
        #expect(await fixture.transport.agentStarts.count == 1)
        #expect(await fixture.transport.agentPromptParams.map(\.text) == [
            "hello", "second", "third /host/staged/image.jpeg",
        ])
        #expect(composer.holdingForLaunch == nil)
        #expect(fixture.console.queuedLaunches.isEmpty)
        #expect(fixture.launches.launches(on: hostID).isEmpty)
    }

    /// Deleting a launch whose handover stopped half-way deletes its moved
    /// and unmoved messages, releases the real pane, and leaves that pane's
    /// own Send to go out.
    @Test func deletingAPartlyHandedOverLaunchReleasesThePaneForItsOwnSends() async throws {
        defer { cleanUp() }
        let fixture = makeFixture()
        defer { fixture.console.setHosts([]) }
        let launch = try await queueConversation(in: fixture)
        let records = fixture.console.queuedMessageStore.messages(on: hostID)
        _ = try makeUnreadable(try #require(records.last), in: fixture)

        await fixture.console.resume()
        try await waitUntil("the handover should fail") {
            if case .failed = fixture.console.queuedLaunches.first?.state { return true }
            return false
        }
        let agentID = ConsoleAgent.ID(hostID: hostID, paneID: "w1:pnew")
        let agent = try #require(fixture.console.agents.first { $0.id == agentID })
        let composer = fixture.console.composerStore(for: agent)
        #expect(await composer.send("mine") == .queued)
        composer.drainQueue()
        #expect(await fixture.transport.agentPromptParams.isEmpty)

        fixture.console.cancelQueuedLaunch(launch.id)
        try await waitUntil("the pane's own Send should go out") {
            await fixture.transport.agentPromptParams.count == 1
        }
        #expect(await fixture.transport.agentPromptParams.map(\.text) == ["mine"])
        #expect(composer.holdingForLaunch == nil)
        #expect(fixture.console.queuedLaunches.isEmpty)
        #expect(fixture.launches.launches(on: hostID).isEmpty)
        #expect(fixture.console.pendingComposer(for: launch.id) == nil)
        try await waitUntil("no launch message should be left on the device") {
            fixture.console.queuedMessageStore.messages(on: hostID).isEmpty
        }
        #expect(!fixture.console.queuedMessageStore.hasMessages(for: launch.pendingAgentID))
        #expect(await fixture.transport.agentStarts.count == 1)
    }

    @Test func theSheetSaysAStartWaitsOnlyWhileTheHostHasNoVerifiedConnection() async throws {
        defer { cleanUp() }
        let fixture = makeFixture()
        defer { fixture.console.setHosts([]) }
        let store = fixture.console.makeStartAgentStore(hosts: [fixture.host])
        await store.discoverAgents()
        #expect(store.startsWhenHostConnects)

        await fixture.console.resume()
        try await waitUntil("the Host's rows should verify") {
            fixture.console.hasLiveSnapshots(on: hostID)
        }
        #expect(!store.startsWhenHostConnects)
    }

    // MARK: Console card

    @Test func aWaitingCardSaysItStartsWhenItsHostConnects() async throws {
        defer { cleanUp() }
        let fixture = makeFixture()
        defer { fixture.console.setHosts([]) }
        let attachments = [
            QueuedMessage.Attachment(
                id: UUID(), kind: .image, fileName: nil, localFileName: nil,
                fileExtension: "jpeg", pixelWidth: 4, pixelHeight: 4, byteCount: 10, hostPath: "/a.jpeg"),
            QueuedMessage.Attachment(
                id: UUID(), kind: .file, fileName: "log.txt", localFileName: nil,
                fileExtension: "txt", pixelWidth: nil, pixelHeight: nil, byteCount: 10,
                hostPath: "/log.txt"),
        ]
        let launch = QueuedLaunch(
            draft: makeDraft(
                firstMessage: LaunchDraft.FirstMessage(
                    text: "fix\n the  crash", attachments: attachments)),
            state: .waiting, createdAt: Date())
        try fixture.console.enqueueLaunch(launch)
        let pending = try #require(fixture.console.pendingComposer(for: launch.id))
        #expect(await pending.send("next") == .queued)
        #expect(await pending.send("last") == .queued)
        let card = QueuedLaunchPresentation(
            launch, hostName: "Build Server", hostUsername: "builder",
            workspaces: [ConsoleWorkspace(id: "w1", label: "Proj")],
            pendingMessages: pending.messages)
        #expect(card.caption == "claude · Build Server")
        #expect(card.headline == "Claude Code")
        #expect(card.location == "Proj")
        #expect(card.statusTitle == "Waiting")
        #expect(card.detail == "Starts when Build Server connects.")
        #expect(
            card.firstMessage
                == QueuedLaunchPresentation.FirstMessage(
                    text: "fix the crash", attachments: "2 items", furtherMessageCount: 2))
        #expect(card.firstMessage?.summary == "2 items · +2 more")
        #expect(launch.state.deliveryState == .queued)
        #expect(!launch.state.awaitsUser)
    }

    @Test func aCardNamesANewWorkspaceFolderAndAFailure() {
        let home = QueuedLaunch(
            draft: makeDraft(
                name: "fix-login",
                destination: .newWorkspace(NewWorkspaceSpec(directory: "", label: nil))),
            state: .failed("The Host did not answer in time."), createdAt: Date())
        let homeCard = QueuedLaunchPresentation(
            home, hostName: "Build Server", hostUsername: "builder", workspaces: [])
        #expect(homeCard.headline == "fix-login")
        #expect(homeCard.location == "New Workspace · Home")
        #expect(homeCard.statusTitle == "Failed")
        #expect(homeCard.detail == "The Host did not answer in time.")
        #expect(homeCard.firstMessage == nil)
        #expect(home.state.awaitsUser)

        let folder = QueuedLaunch(
            draft: makeDraft(
                destination: .newWorkspace(
                    NewWorkspaceSpec(directory: "/home/builder/src/api", label: nil))),
            state: .uncertain, createdAt: Date())
        let folderCard = QueuedLaunchPresentation(
            folder, hostName: "Build Server", hostUsername: "builder", workspaces: [])
        #expect(folderCard.location == "New Workspace · ~/src/api")
        #expect(folderCard.statusTitle == "Waiting")
        #expect(folderCard.detail == "Starts when Build Server connects.")
        #expect(!folder.state.awaitsUser)
    }

    @Test func theConsoleListsQueuedLaunchesUnderAllBesideTheirHost() {
        let otherHost = Host.fixture(id: UUID())
        let waiting = QueuedLaunch(
            draft: makeDraft(name: "fix-login"), state: .waiting, createdAt: Date())
        let failed = QueuedLaunch(
            draft: makeDraft(
                hostID: otherHost.id, kind: .codex,
                destination: .newWorkspace(NewWorkspaceSpec(directory: "", label: nil))),
            state: .failed("x"), createdAt: Date())
        let launches = [waiting, failed]
        func visible(
            hostID: Host.ID? = nil, workspace: ConsoleWorkspaceOption.ID = .all,
            status: ConsoleStatusFilter = .all, search: String = "",
            listed: Set<Host.ID>? = nil
        ) -> [QueuedLaunch] {
            ConsoleListProjection.visibleQueuedLaunches(
                launches, listedHostIDs: listed ?? [self.hostID, otherHost.id], hostID: hostID,
                workspace: workspace,
                workspacesByHost: [self.hostID: [ConsoleWorkspace(id: "w1", label: "Proj")]],
                status: status, searchQuery: search, hostNames: [otherHost.id: "Mac mini"])
        }
        #expect(visible() == launches)
        #expect(visible(status: .working).isEmpty)
        #expect(visible(status: .working, search: "mini") == [failed])
        #expect(visible(search: "login") == [waiting])
        #expect(visible(hostID: otherHost.id) == [failed])
        #expect(visible(workspace: .group(self.hostID, .workspace("w1"))) == [waiting])
        #expect(visible(listed: [self.hostID]) == [waiting])

        let issue = ConsoleHostStatusPresentation(
            host: otherHost, failedScope: ConsoleScope(hostID: otherHost.id, backend: .tmux),
            failure: .sshUnreachable(detail: "offline"))
        #expect(
            ConsoleLeadRow.ordered(issues: [issue], launches: launches)
                == [.issue(issue), .launch(failed), .launch(waiting)])
        // With no Host row they stay together by Host, in first-seen order.
        let later = QueuedLaunch(draft: makeDraft(), state: .waiting, createdAt: Date())
        #expect(
            ConsoleLeadRow.ordered(issues: [], launches: launches + [later])
                == [.launch(waiting), .launch(later), .launch(failed)])
    }

    // MARK: Support

    @MainActor
    private final class StartCount {
        private(set) var count = 0

        func refuse(_ error: RequestNotSentError) async throws -> Agent {
            count += 1
            throw error
        }
    }

    private func makeDraft(
        hostID: Host.ID? = nil, kind: SupportedAgentKind = .claude,
        launch: StartAgentStore.LaunchSelection? = nil, name: String? = nil,
        destination: StartAgentStore.LaunchDestination = .existingWorkspace,
        presetFirstMessage: String? = nil, firstMessage: LaunchDraft.FirstMessage? = nil
    ) -> LaunchDraft {
        let isNewWorkspace = if case .newWorkspace = destination { true } else { false }
        return LaunchDraft(
            id: UUID(), hostID: hostID ?? self.hostID,
            dispatch: StartAgentStore.Dispatch(
                destination: destination, launch: launch ?? .agent(kind), backend: .herdr),
            workspaceID: isNewWorkspace ? nil : "w1", originCwd: nil, name: name,
            suggestedName: nil, userArguments: [], chatMode: false,
            presetFirstMessage: presetFirstMessage,
            firstMessage: firstMessage, remembersLaunch: true, isQuickChat: false)
    }

    private func queueConversation(in fixture: Fixture) async throws -> QueuedLaunch {
        let store = fixture.console.makeStartAgentStore(hosts: [fixture.host])
        await store.discoverAgents()
        store.launchSelection.wrappedValue = .agent(.claude)
        store.chatMode = false
        store.firstMessageText = "hello"
        await store.submit()
        let launch = try #require(fixture.console.queuedLaunches.first)
        let pending = try #require(fixture.console.pendingComposer(for: launch.id))
        #expect(await pending.send("second") == .queued)
        let data = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).jpegData(
            withCompressionQuality: 1) { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            }
        #expect(pending.tray.add([.photo(DataImageSelection(data: data))]) == 1)
        pending.applyEditorDraft("third", selection: NSRange(location: 5, length: 0))
        #expect(await pending.send() == .queued)
        #expect(pending.tray.isEmpty)
        return launch
    }

    private struct Fixture {
        let host: Host
        let transport: ScriptedTransport
        let console: ConsoleStore
        let launches: QueuedLaunchStore
    }

    /// A Console that knows the Host's Workspace and Agent kinds from an
    /// earlier connection and is not connected until `resume()`. Once it is,
    /// the Host lists the Agent a replay starts (the scripted start's pane).
    private func makeFixture(
        kind: SupportedAgentKind = .claude, reconnectGate: ScriptedTransportCallGate? = nil,
        tabLabels: [String] = [], replacementTransport: ScriptedTransport? = nil
    ) -> Fixture {
        let host = Host.fixture(id: hostID)
        let workspace = WorkspaceInfo.fixture(workspaceID: "w1", label: "Proj")
        let tabs = tabLabels.enumerated().map { index, label in
            TabInfo(
                agentStatus: .unknown, focused: false, label: label, number: index + 1,
                paneCount: 1, tabID: "w1:t-label-\(index)", workspaceID: "w1")
        }
        let cache = ConsoleInventoryCache(
            directory: directory.appending(path: "inventory", directoryHint: .isDirectory))
        cache.save(
            ConsoleInventoryCache.Entry(
                snapshot: .fixture(workspaces: [workspace], tabs: tabs), sidebarLayout: nil),
            for: host)
        cache.saveAgentKinds(CachedAgentKinds(kinds: [kind], verifiedAt: Date()), for: host)
        cache.flush()
        let transport = ScriptedTransport(
            snapshot: .fixture(
                agents: [.fixture(paneID: "w1:pnew", kind: kind.rawValue)],
                workspaces: [workspace], tabs: tabs))
        let launches = QueuedLaunchStore(directory: launchesDirectory)
        let console = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            pins: PinnedAgentsStore(
                defaults: UserDefaults(suiteName: "queued-launch-pins-\(UUID().uuidString)")
                    ?? .standard),
            inventoryCache: cache,
            queuedMessages: QueuedMessageStore(
                directory: directory.appending(path: "messages", directoryHint: .isDirectory)),
            queuedLaunches: launches
        ) { _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: {
                    if await !transport.agentStarts.isEmpty {
                        await reconnectGate?.waitUntilOpen()
                        return replacementTransport ?? transport
                    }
                    return transport
                }, keepalive: nil)
        }
        console.setHosts([host])
        return Fixture(host: host, transport: transport, console: console, launches: launches)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Replaces a Queued Message's record with an unreadable entry, as a
    /// file protection or I/O failure would leave it: kept, never decoded,
    /// still counted. The returned closure puts the record back.
    private func makeUnreadable(_ record: QueuedMessage, in fixture: Fixture) throws -> () throws -> Void {
        let file = fixture.console.queuedMessageStore.messageDirectory(for: record)
            .appending(path: "message.json", directoryHint: .notDirectory)
        let data = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        return {
            try FileManager.default.removeItem(at: file)
            try data.write(to: file)
        }
    }

    /// `launch.json` exactly as the app writes it, with the record it holds.
    private static func writtenRecords(hostID: Host.ID) -> [(String, QueuedLaunch)] {
        let host = hostID.uuidString
        let created = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let pin = UUID(uuidString: "5E1A7C3D-0B2E-4F6A-9C8D-1E2F3A4B5C6D")!
        let ids = [
            "0A1B2C3D-4E5F-4061-8728-394A5B6C7D80", "1A1B2C3D-4E5F-4061-8728-394A5B6C7D81",
            "2A1B2C3D-4E5F-4061-8728-394A5B6C7D82", "3A1B2C3D-4E5F-4061-8728-394A5B6C7D83",
            "4A1B2C3D-4E5F-4061-8728-394A5B6C7D84",
        ].map { UUID(uuidString: $0)! }
        func draft(
            _ id: UUID, destination: StartAgentStore.LaunchDestination = .existingWorkspace,
            launch: StartAgentStore.LaunchSelection = .agent(.claude), name: String? = nil,
            launchName: String? = nil, worktreeBranch: String? = nil, sessionPin: UUID? = nil
        ) -> LaunchDraft {
            var draft = LaunchDraft(
                id: id, hostID: hostID,
                dispatch: .init(destination: destination, launch: launch, backend: .herdr),
                workspaceID: destination == .existingWorkspace ? "w1" : nil, originCwd: nil,
                name: name, suggestedName: nil, userArguments: [], chatMode: false,
                presetFirstMessage: nil, firstMessage: nil, remembersLaunch: true,
                isQuickChat: false)
            draft.launchName = launchName
            draft.worktreeBranch = worktreeBranch
            draft.sessionPin = sessionPin
            return draft
        }
        let branch = "worktree/brave-otter-1a2b"
        let worktree = WorktreeSpec(branch: branch, base: .latestDefaultBranch, branchIsGenerated: true)
        var waiting = QueuedLaunch(
            draft: draft(
                ids[0], destination: .newWorktree(worktree), launchName: "claude",
                worktreeBranch: branch, sessionPin: pin),
            state: .waiting, createdAt: created)
        waiting.mayHaveStarted = false
        var starting = QueuedLaunch(
            draft: draft(ids[1], name: "reviewer", launchName: "reviewer", sessionPin: pin),
            state: .starting, createdAt: created)
        starting.startedPaneID = "w1:pnew"
        starting.joinedRunningAgent = true
        starting.mayHaveStarted = false
        let message = "The Agent started, but its messages couldn't be moved. Retry to finish sending them."
        var failed = QueuedLaunch(
            draft: draft(ids[2], launchName: "claude", sessionPin: pin),
            state: .failed(message), createdAt: created)
        failed.startedPaneID = "w1:pnew"
        failed.joinedRunningAgent = false
        failed.mayHaveStarted = true
        let uncertain = QueuedLaunch(draft: draft(ids[3]), state: .uncertain, createdAt: created)
        let shell = QueuedLaunch(
            draft: draft(
                ids[4], destination: .newWorkspace(NewWorkspaceSpec(directory: "")), launch: .shell),
            state: .failed("No start"), createdAt: created)
        func json(_ id: UUID, _ dispatch: String, _ fields: String, _ tail: String) -> String {
            #"{"draft":{"id":"\#(id.uuidString)","hostID":"\#(host)","dispatch":\#(dispatch),"#
                + fields
                + #""userArguments":[],"chatMode":false,"remembersLaunch":true,"isQuickChat":false},"#
                + #""createdAt":800000000,"# + tail + "}"
        }
        let claude = #""launch":{"agent":{"_0":"claude"}},"backend":"herdr"}"#
        let existing = #"{"destination":{"existingWorkspace":{}},"# + claude
        let pinField = #""sessionPin":"\#(pin.uuidString)","#
        return [
            (json(
                ids[0],
                #"{"destination":{"newWorktree":{"_0":{"branch":"\#(branch)","#
                    + #""base":{"latestDefaultBranch":{}},"branchIsGenerated":true}}},"# + claude,
                #""launchName":"claude","worktreeBranch":"\#(branch)","# + pinField,
                #""state":{"waiting":{}},"mayHaveStarted":false"#), waiting),
            (json(
                ids[1], existing,
                #""workspaceID":"w1","name":"reviewer","launchName":"reviewer","# + pinField,
                #""state":{"starting":{}},"startedPaneID":"w1:pnew","#
                    + #""joinedRunningAgent":true,"mayHaveStarted":false"#), starting),
            (json(
                ids[2], existing, #""workspaceID":"w1","launchName":"claude","# + pinField,
                #""state":{"failed":{"_0":"\#(message)"}},"startedPaneID":"w1:pnew","#
                    + #""joinedRunningAgent":false,"mayHaveStarted":true"#), failed),
            (json(ids[3], existing, #""workspaceID":"w1","#, #""state":{"uncertain":{}}"#),
                uncertain),
            (json(
                ids[4],
                #"{"destination":{"newWorkspace":{"_0":{"directory":""}}},"#
                    + #""launch":{"shell":{}},"backend":"herdr"}"#,
                "", #""state":{"failed":{"_0":"No start"}}"#), shell),
        ]
    }
}
