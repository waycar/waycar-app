import SwiftUI
import Testing
import UIKit

@testable import Waycar

/// What happens when SwiftUI replaces a terminal surface (#152).
///
/// Whole-screen replacement is the one path #143 could not disprove:
/// `AgentTerminalView` holds `@State private var attach`, so an Agent switch
/// releases one store and constructs another, in an order that is SwiftUI's
/// and unspecified. These tests drive that replacement through the real view
/// and observe what the feed does across it.
///
/// A hosted `ConsoleView` was tried first and abandoned: a hosted
/// `NavigationSplitView` builds its columns, separators and navigation bar but
/// never the SwiftUI content inside them, so nothing below it can be observed
/// (measured: 72 views, all chrome, identical with and without a selection).
/// `AgentTerminalView` is not subject to that — it is a plain view and its
/// terminal surface really is built.
@MainActor
@Suite("Agent surface replacement")
struct AgentSurfaceReplacementTests {
    /// The production detail combines a live Ghostty renderer with Composer.
    /// Ghostty must still own the PTY grid while the Composer draft goes out
    /// through the one-shot `agent.prompt` path. Local-input rejection while
    /// Message Agent is open is pinned by
    /// `openMessageAgentStillRejectsLocalGhosttyInput`.
    @Test func detailRendersAttachAndSendsComposerDraftThroughPrompt() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        let owner = Self.makeAttachStore(transport: transport, composer: composer)
        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                agent: Self.makeAgent(pane: "w1:p1"),
                activity: AppActivityCoordinator(),
                attachStore: owner,
                composer: composer))
        let window = Self.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually {
            controller.view.layoutIfNeeded()
            return await transport.attachRequests.count == 1
        })
        #expect(await transport.emitAttachOutput(Data("live-frame".utf8)))
        try #require(await Self.eventually { owner.terminalStatus == .live })

        let terminal = try #require(Self.terminals(in: controller.view).first)

        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1000;1006h".utf8))
        #expect(terminal.scrollTouch(translationY: 32) != 0)
        try #require(await Self.eventually {
            await transport.attachInputs.contains {
                if case .scroll = $0 { true } else { false }
            }
        })

        terminal.sendQuickKey(.enter)
        try #require(await Self.eventually {
            await transport.attachInputs.contains(.keystrokes(Data([0x0D])))
        })

        composer.replaceDraft(with: "Continue from the current output")
        await composer.send()
        #expect(
            await transport.agentPromptParams == [
                AgentPromptParams(
                    target: "w1:p1", text: "Continue from the current output")
            ])

        await owner.leave().value
    }

    /// A replacement surface must take over the feed, or output goes to a view
    /// the user cannot see.
    ///
    /// The released predecessor plus the new surface's parsed viewport make the
    /// replacement conclusive without inventing a renderer acknowledgement.
    @Test func aReplacementSurfaceTakesOverTheFeed() async throws {
        struct Harness: View {
            let feed: TerminalByteFeed
            let surface: Int

            var body: some View {
                TerminalScreenView(feed: feed)
                    .id(surface)
            }
        }

        let feed = TerminalByteFeed()
        let controller = UIHostingController(rootView: Harness(feed: feed, surface: 1))
        // This seam needs a UIKit hierarchy, not a connected app scene. A
        // scene is absent in some headless test-host launches, which made the
        // otherwise deterministic loop fail before it reached AgentTerminalView.
        let window = Self.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()

        // Deliberately not retained: the predecessor has to be free to go away,
        // or a stale sink would still look live.
        weak var predecessor: WaycarTerminalView?
        predecessor = Self.terminals(in: controller.view).first
        #expect(predecessor != nil, "the first surface should exist")
        feed.write(Data("first".utf8))

        controller.rootView = Harness(feed: feed, surface: 2)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await waitUntil("SwiftUI should replace and release the predecessor surface") {
            Self.terminals(in: controller.view).first != nil && predecessor == nil
        }

        let replacement = try #require(
            Self.terminals(in: controller.view).first,
            "SwiftUI should have built a replacement surface")
        feed.write(Data("second".utf8))
        try #require(await Self.eventually {
            replacement.terminalSession.readViewportText()?.contains("second") == true
        }, "output after a replacement must reach the replacement's terminal session")
        #expect(Self.terminals(in: controller.view).count == 1)
        _ = replacement
    }

    /// An Agent switch must build a surface for the store it just constructed.
    ///
    /// This is the regression #143's `TerminalSurfaceID` guards: an
    /// address-derived id can repeat across a release-then-construct, and a
    /// repeated id is one SwiftUI reads as "same surface, keep it" — leaving
    /// the new store's terminal with no surface at all. Measured on this tree,
    /// 200 stores built and dropped in a row produced only 2 distinct
    /// `ObjectIdentifier`s, so the collision is likely rather than exotic.
    ///
    /// It runs many rounds for that reason: one switch may or may not reuse an
    /// address, and the defect only shows on a round that does.
    ///
    /// Note what this does **not** add, both halves measured rather than
    /// argued. Reverting `AgentAttachStore.terminalID` to
    /// `ObjectIdentifier(terminal)` turns the `AgentAttachStoreTests` suite red
    /// on its own (36 tests, 2 failures, one of them reproducing the 200-to-2
    /// address collision directly) and leaves **this** test green. So it
    /// contributes no mutation coverage for that revert.
    ///
    /// What it does contribute is the end-to-end path: it is the only test in
    /// the suite that drives a real SwiftUI screen replacement, so it would
    /// catch a regression that stopped building a surface for the new store by
    /// some route the store-level tests do not model. That makes it a
    /// characterisation of what SwiftUI does today, not a guarantee it will
    /// keep doing it — if a future SwiftUI stops replacing the surface here,
    /// this test reports that change rather than a defect.
    @Test(.timeLimit(.minutes(1)))
    func anAgentSwitchBuildsASurfaceForTheNewStore() async throws {
        struct Harness: View {
            let agent: ConsoleAgent
            let make: (ConsoleAgent) -> AgentTerminalView

            var body: some View {
                // Mirrors what `ConsoleView` puts on its detail column: the
                // Agent's own id, which is what makes a switch a replacement
                // rather than an update.
                make(agent)
                    .id(agent.id)
            }
        }

        let host = UUID()
        let agents = (1...12).map { Self.makeAgent(pane: "w1:p\($0)", host: host) }
        let make = Self.detailViewFactory()
        let controller = UIHostingController(
            rootView: Harness(agent: agents[0], make: make))
        let window = Self.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))

        var surfaces: [ObjectIdentifier] = []
        var roundsWithoutASurface: [Int] = []
        for round in agents.indices {
            controller.rootView = Harness(agent: agents[round], make: make)
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            await Task.yield()
            try await Task.sleep(for: .milliseconds(50))

            guard let terminal = Self.terminals(in: controller.view).first else {
                roundsWithoutASurface.append(round)
                continue
            }
            surfaces.append(ObjectIdentifier(terminal))
        }

        #expect(
            roundsWithoutASurface.isEmpty,
            "an Agent switch left the screen with no terminal surface on rounds \(roundsWithoutASurface)")
        // Every switch is a fresh screen, so no two consecutive rounds may be
        // looking at the same surface object.
        let repeats = zip(surfaces, surfaces.dropFirst()).filter { $0 == $1 }.count
        #expect(
            repeats == 0,
            "\(repeats) of \(surfaces.count - 1) switches reused the previous surface")
    }

    /// The production call-site seam for #141. Recovery must replace every
    /// terminal-owned object while leaving the surrounding Attach interaction
    /// intact: links, a staging result, and a Paste awaiting confirmation all
    /// belong to this Attach until the user actually leaves it.
    @Test func aPossibleSuspensionRebuildsTheTerminalAndPreservesAttachState() async throws {
        var now = ContinuousClock.now
        let activity = AppActivityCoordinator(
            gracePeriod: .seconds(20),
            granter: SurfaceTestBackgroundGranter(),
            now: { now })
        let transport = ScriptedTransport()
        let composer = Self.makeComposer(transport: transport)
        let owner = Self.makeAttachStore(transport: transport, composer: composer)
        let agent = Self.makeAgent(pane: "w1:p1")
        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                agent: agent,
                activity: activity,
                attachStore: owner,
                composer: composer))
        let window = Self.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        controller.view.layoutIfNeeded()

        try #require(await Self.eventually {
            await transport.attachRequests.count == 1
        }, "the first PTY Attach should open")
        #expect(await transport.emitAttachOutput(Data("opening".utf8)))
        try #require(await Self.eventually {
            owner.terminalStatus == .live
        }, "the first Attach should become live")
        let firstTerminalID = owner.terminalID
        let firstFeed = owner.terminalFeed
        weak var predecessor: WaycarTerminalView?
        let firstSurfaceID: ObjectIdentifier
        do {
            let firstSurface = try #require(Self.terminals(in: controller.view).first)
            predecessor = firstSurface
            firstSurfaceID = ObjectIdentifier(firstSurface)
        }

        owner.viewportTextDidChange("https://before.example/recovery")
        owner.staging.begin(.photo(DataImageSelection(data: Data([0x01]))))
        try #require(await Self.eventually {
            if case .failed = owner.staging.state { true } else { false }
        }, "the image result should surface before recovery")
        let stagingResult = owner.staging.state
        owner.requestPaste("git status\ngit diff", bracketedPaste: true)
        let pendingPaste = try #require(owner.pendingPaste)

        activity.didEnterBackground(.phone)
        now = now.advanced(by: .seconds(5))
        activity.didBecomeActive(.phone)
        try await Task.sleep(for: .milliseconds(100))

        #expect(
            await transport.attachRequests.count == 1,
            "a short bounce must not open another PTY Attach")
        #expect(
            owner.terminalStatus == .live,
            "a short bounce must not show Connecting")
        #expect(
            Self.terminals(in: controller.view).first.map(ObjectIdentifier.init) == firstSurfaceID,
            "a short bounce must keep the terminal surface")
        #expect(owner.terminalID == firstTerminalID)
        #expect(owner.terminalFeed === firstFeed)

        activity.didEnterBackground(.phone)
        now = now.advanced(by: .seconds(20))
        activity.didBecomeActive(.phone)

        let didReplaceTerminal = try await Self.eventually {
            owner.terminalID != firstTerminalID
        }
        let didExecuteAnotherAttach = try await Self.eventually {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            return await transport.attachRequests.count == 2
        }
        try #require(didReplaceTerminal, "recovery should replace the terminal pipeline")
        try #require(didExecuteAnotherAttach, "the replacement should execute a new PTY Attach")
        try #require(await Self.eventually {
            predecessor == nil
        }, "the old terminal surface should detach")
        let replacement = try #require(
            Self.terminals(in: controller.view).first,
            "recovery should create and attach a new terminal surface")

        #expect(ObjectIdentifier(replacement) != firstSurfaceID)
        #expect(owner.terminalFeed !== firstFeed, "the replacement needs a new byte feed")
        #expect(owner.attachLinks.map(\.target) == ["https://before.example/recovery"])
        #expect(owner.staging.state == stagingResult)
        #expect(owner.pendingPaste == pendingPaste)

        #expect(await transport.emitAttachOutput(Data("recovered-frame".utf8)))
        try #require(await Self.eventually {
            owner.terminalStatus == .live
                && replacement.terminalSession.readViewportText()?.contains("recovered-frame") == true
        }, "new PTY output should reach the replacement Ghostty viewport")

        owner.confirmPaste()
        let expectedPaste =
            TerminalBracketedPaste.start + Data("git status\ngit diff".utf8)
            + TerminalBracketedPaste.end
        try #require(await Self.eventually {
            await transport.attachInputs.filter {
                if case .keystrokes = $0 { return true }
                return false
            } == [.keystrokes(expectedPaste)]
        }, "the reviewed Paste should submit once through the replacement writer")
        #expect(owner.pendingPaste == nil)

        await owner.leave().value
        window.isHidden = true
        window.rootViewController = nil
        await Task.yield()
    }

    /// The R3 device trace caught the foreground edge between Attach owners:
    /// the live predecessor ended while the app was away, activation 2 carried
    /// `possibleSuspension=true`, and only then did SwiftUI construct the
    /// visible replacement around a fresh terminal already stopped by its
    /// lifecycle churn. An `onChange` observer born after that edge never sees
    /// it, so the stopped terminal cannot open its first PTY Attach.
    @Test func aReplacementOwnerClaimsThePossibleSuspensionActivationItMissed()
        async throws
    {
        var now = ContinuousClock.now
        let activity = AppActivityCoordinator(
            gracePeriod: .seconds(20),
            granter: SurfaceTestBackgroundGranter(),
            now: { now })
        activity.didBecomeActive(.phone)

        let oldTransport = ScriptedTransport()
        let oldComposer = Self.makeComposer(transport: oldTransport)
        let oldOwner = Self.makeAttachStore(transport: oldTransport, composer: oldComposer)
        let agent = Self.makeAgent(pane: "w1:p1")
        let controller = UIHostingController(
            rootView: AnyView(
                Self.makeDetailView(
                    agent: agent,
                    activity: activity,
                    attachStore: oldOwner,
                    composer: oldComposer)))
        let window = Self.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        controller.view.layoutIfNeeded()

        try #require(await Self.eventually { await oldTransport.hasLiveAttachSession })
        #expect(await oldTransport.emitAttachOutput(Data("opening".utf8)))
        try #require(await Self.eventually { oldOwner.terminalStatus == .live })

        activity.didEnterBackground(.phone)
        // Not a channel failure: that earns one silent retry, and this
        // predecessor must end while the app is away.
        await oldTransport.failAttachStream(.sshUnreachable(detail: "app was away"))
        try #require(await Self.eventually {
            if case .ended = oldOwner.terminalStatus { return true }
            return false
        }, "the live predecessor should end while the app is away")

        controller.rootView = AnyView(Color.clear)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually { oldOwner.terminalStatus == .stopped })

        now = now.advanced(by: .seconds(20))
        activity.didBecomeActive(.phone)
        #expect(activity.activationCount == 2)
        #expect(activity.lastAbsenceMayHaveSuspended)

        let replacementTransport = ScriptedTransport()
        let replacementComposer = Self.makeComposer(transport: replacementTransport)
        let replacementOwner = Self.makeAttachStore(
            transport: replacementTransport,
            composer: replacementComposer)
        await replacementOwner.terminal.stop()
        let stoppedTerminalID = replacementOwner.terminalID

        controller.rootView = AnyView(
            Self.makeDetailView(
                agent: agent,
                activity: activity,
                attachStore: replacementOwner,
                composer: replacementComposer))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        try #require(await Self.eventually {
            replacementOwner.terminalID != stoppedTerminalID
        }, "the current owner should claim the missed possible-suspension activation")
        try #require(await Self.eventually {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            return await replacementTransport.attachRequests.count == 1
        }, "the recovered current owner should open a PTY Attach")
        #expect(await replacementTransport.emitAttachOutput(Data("recovered".utf8)))
        try #require(await Self.eventually { replacementOwner.terminalStatus == .live })
        for _ in 0..<10 { await Task.yield() }
        #expect(
            await replacementTransport.attachRequests.count == 1,
            "the replacement owner must claim one activation exactly once")

        await replacementOwner.leave().value
        window.isHidden = true
        window.rootViewController = nil
        await Task.yield()
    }

    @Test func transportReplacementPreservesActivationAcrossSwiftUIMountChurn()
        async throws
    {
        struct Harness: View {
            let detail: AgentTerminalView
            let mounts: [Int]

            var body: some View {
                ZStack {
                    ForEach(mounts, id: \.self) { mount in
                        detail.id(mount)
                    }
                }
            }
        }

        var now = ContinuousClock.now
        let activity = AppActivityCoordinator(
            gracePeriod: .seconds(20),
            granter: SurfaceTestBackgroundGranter(),
            now: { now })
        activity.didBecomeActive(.phone)

        let transport = ScriptedTransport()
        let endGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: endGate)
        let composer = Self.makeComposer(transport: transport)
        let owner = Self.makeAttachStore(transport: transport, composer: composer)
        let detail = Self.makeDetailView(
            agent: Self.makeAgent(pane: "w1:p1"),
            activity: activity,
            attachStore: owner,
            composer: composer)
        let controller = UIHostingController(
            rootView: Harness(detail: detail, mounts: [0]))
        let window = Self.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.view.layoutIfNeeded()

        try #require(await Self.eventually { await transport.hasLiveAttachSession })
        #expect(await transport.emitAttachOutput(Data("opening".utf8)))
        try #require(await Self.eventually { owner.terminalStatus == .live })

        activity.didEnterBackground(.phone)
        now = now.advanced(by: .seconds(20))
        activity.didBecomeActive(.phone)
        try #require(await Self.eventually { await endGate.entryCount == 1 })

        controller.rootView = Harness(detail: detail, mounts: [0, 1])
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually {
            Self.terminals(in: controller.view).count == 2
        }, "the replacement mount should be visible before the predecessor disappears")

        owner.transportGenerationDidChange(2)
        controller.rootView = Harness(detail: detail, mounts: [1])
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()

        await endGate.open()
        try #require(await Self.eventually {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            return await transport.attachRequests.count == 2
        }, "the visible on-stage Attach must survive the predecessor's real onDisappear")
        #expect(await transport.emitAttachOutput(Data("recovered".utf8)))
        try #require(await Self.eventually { owner.terminalStatus == .live })
        #expect(Self.terminals(in: controller.view).count == 1)

        await owner.leave().value
    }

    /// The production View -> owner path must honor an actual suspension even
    /// when the measured absence is well below the injected Background Grace
    /// Period. Duration is only the fallback for a process frozen before the
    /// coordinator can publish `.suspended`.
    @Test func anObservedSuspensionBelowTheGracePeriodRebuildsTheProductionAttach()
        async throws
    {
        var now = ContinuousClock.now
        let activity = AppActivityCoordinator(
            gracePeriod: .seconds(20),
            granter: RefusingSurfaceTestBackgroundGranter(),
            now: { now })
        let transport = ScriptedTransport()
        let composer = Self.makeComposer(transport: transport)
        let owner = Self.makeAttachStore(transport: transport, composer: composer)
        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                agent: Self.makeAgent(pane: "w1:p1"),
                activity: activity,
                attachStore: owner,
                composer: composer))
        let window = Self.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        controller.view.layoutIfNeeded()

        try #require(await Self.eventually {
            await transport.attachRequests.count == 1
        }, "the first PTY Attach should open")
        #expect(await transport.emitAttachOutput(Data("opening".utf8)))
        try #require(await Self.eventually {
            owner.terminalStatus == .live
        }, "the first Attach should become live")
        let firstTerminalID = owner.terminalID

        activity.didEnterBackground(.phone)
        #expect(activity.phase == .suspended)
        now = now.advanced(by: .seconds(5))
        activity.didBecomeActive(.phone)

        try #require(await Self.eventually {
            owner.terminalID != firstTerminalID
        }, "an observed suspension should replace the terminal below the time boundary")
        try #require(await Self.eventually {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            return await transport.attachRequests.count == 2
        }, "the production view should open a new PTY Attach")

        await owner.leave().value
        window.isHidden = true
        window.rootViewController = nil
        await Task.yield()
    }

    /// Recovery is visible at the same production presentation seam the hosted
    /// screen's `statusOverlay` consumes, before stopping the predecessor can
    /// finish. A blocked close must never leave the user looking at `.live` and
    /// therefore `EmptyView`.
    @Test func recoveryShowsConnectingWhileThePreviousPTYIsStillStopping() async throws {
        var now = ContinuousClock.now
        let activity = AppActivityCoordinator(
            gracePeriod: .seconds(20),
            granter: RefusingSurfaceTestBackgroundGranter(),
            now: { now })
        let transport = ScriptedTransport()
        let endGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: endGate)
        let composer = Self.makeComposer(transport: transport)
        let owner = Self.makeAttachStore(transport: transport, composer: composer)
        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                agent: Self.makeAgent(pane: "w1:p1"),
                activity: activity,
                attachStore: owner,
                composer: composer))
        let window = Self.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        controller.view.layoutIfNeeded()

        try #require(await Self.eventually { await transport.hasLiveAttachSession })
        #expect(await transport.emitAttachOutput(Data("opening".utf8)))
        try #require(await Self.eventually { owner.terminalStatus == .live })
        #expect(
            TerminalStatusPresentation(status: owner.terminalStatus) == nil,
            "the live hosted screen must not show a status dialog")

        activity.didEnterBackground(.phone)
        #expect(activity.phase == .suspended)
        now = now.advanced(by: .seconds(5))
        activity.didBecomeActive(.phone)
        try #require(await Self.eventually { await endGate.entryCount == 1 })
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()

        #expect(
            owner.terminalStatus == .connecting,
            "the hosted screen must show Connecting while the old PTY stop is pending")
        #expect(
            TerminalStatusPresentation(status: owner.terminalStatus) == .connecting,
            "the hosted screen must present its Connecting state over the live terminal")

        await endGate.open()
        try #require(await Self.eventually {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            return await transport.attachRequests.count == 2
        })
        await owner.leave().value
        window.isHidden = true
        window.rootViewController = nil
        await Task.yield()
    }

    /// A cold open has no frame to keep and says Connecting. A replacement
    /// after the terminal painted keeps a copy of that frame up — never the
    /// old Ghostty surface itself (#242) — under the Reconnecting loader
    /// until the replacement paints its own. An ended attach leaves no
    /// frame behind for its reattach (#21).
    @Test func aReplacementKeepsTheLastFrameUntilItPaints() async throws {
        var now = ContinuousClock.now
        let activity = AppActivityCoordinator(
            gracePeriod: .seconds(20),
            granter: SurfaceTestBackgroundGranter(),
            now: { now })
        let transport = ScriptedTransport()
        let composer = Self.makeComposer(transport: transport)
        let owner = Self.makeAttachStore(transport: transport, composer: composer)
        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                agent: Self.makeAgent(pane: "w1:p1"),
                activity: activity,
                attachStore: owner,
                composer: composer))
        // A scene window: only a window on screen has a frame to copy.
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        func teardown() async {
            await owner.leave().value
            window.isHidden = true
            window.rootViewController = nil
        }
        func showsConnecting() -> Bool { Self.shows("Connecting…", in: controller) }
        func showsReconnecting() -> Bool { Self.showsReconnecting(in: controller) }
        func run() async throws {
            try #require(await Self.eventually {
                _ = showsReconnecting()
                return await transport.attachRequests.count == 1
            })
            try #require(await Self.eventually { showsConnecting() && !showsReconnecting() },
                "a cold open shows the Connecting loader and has no frame to keep")

            #expect(await transport.emitAttachOutput(Data("first-frame".utf8)))
            // The screen, not only the store, must have taken the paint: the
            // frame a replacement keeps is registered as the loader goes.
            try #require(await Self.eventually {
                owner.terminalStatus == .live && !showsConnecting()
            })
            let firstTerminalID = owner.terminalID
            weak var predecessor: WaycarTerminalView?
            do {
                let surface = try #require(Self.terminals(in: controller.view).first)
                predecessor = surface
            }

            activity.didEnterBackground(.phone)
            now = now.advanced(by: .seconds(20))
            activity.didBecomeActive(.phone)
            try #require(await Self.eventually {
                _ = showsReconnecting()
                return await transport.attachRequests.count == 2
            }, "recovery should open a replacement PTY Attach")
            #expect(owner.terminalID != firstTerminalID)
            try #require(await Self.eventually { showsReconnecting() && !showsConnecting() },
                "the replacement keeps the last frame up under the Reconnecting loader")
            #expect(owner.terminalStatus == .connecting)
            try #require(await Self.eventually { _ = showsReconnecting(); return predecessor == nil },
                "only a copy stands in for the old surface, which is released (#242)")
            #expect(showsReconnecting())

            #expect(await transport.emitAttachOutput(Data("second-frame".utf8)))
            try #require(await Self.eventually { owner.terminalStatus == .live && !showsReconnecting() },
                "the Reconnecting loader goes once the replacement paints")

            await transport.endAttachFromRemote()
            try #require(await Self.eventually {
                Self.shows("Terminal connection: Detached", in: controller) && !showsReconnecting()
            })
            try #require(await Self.eventually {
                owner.retryTerminal()
                _ = showsReconnecting()
                return await transport.attachRequests.count == 3
            })
            try #require(await Self.eventually { showsConnecting() && !showsReconnecting() },
                "an ended attach leaves no frame to reconnect over")
        }
        do { try await run() } catch {
            await teardown()
            throw error
        }
        await teardown()
    }

    enum LinkedTerminalDeparture: CaseIterable, Sendable {
        case showChat, linkReplacement, linkLoss, leaveThread
    }

    @Test(arguments: LinkedTerminalDeparture.allCases)
    func leavingALinkedTerminalReleasesItsRetainedPTY(_ departure: LinkedTerminalDeparture) async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", kind: "codex")]))
        let console = ConsoleStore { _, _, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
        }
        var window: UIWindow?
        defer {
            console.setHosts([])
            window?.isHidden = true
            window?.rootViewController = nil
        }
        console.setHosts([host])
        await console.resume()
        try #require(await Self.eventually { console.agents.count == 1 })
        let pane = try #require(console.agents.first)
        var visible = true
        var presented = true
        var current: ConsoleAgent? = pane
        let stage = AgentDetailStage(isVisible: { visible }, terminalAccess: { .holds })
            .linkedTerminal(pane, isPresented: { presented }, current: { current })
        let defaults = UserDefaults(suiteName: "linked-terminal-leave-\(UUID())") ?? .standard
        let controller = UIHostingController(rootView: AgentDetailView(
            agent: pane, console: console,
            terminal: TerminalSettings(
                themes: TerminalThemeSettings(defaults: defaults), zoom: TerminalZoomSettings(defaults: defaults),
                fonts: TerminalFontSettings(defaults: defaults), snippets: SnippetStore(defaults: defaults),
                toolbars: AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)),
            hosts: [host], activity: AppActivityCoordinator(), keyboardHandoff: TerminalKeyboardHandoff(),
            keyboardInset: TerminalKeyboardInset(), stage: stage, onSwitch: { _ in }, onClosed: {},
            isLinkedTerminal: true))
        window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller)
        try #require(await Self.eventually { await transport.hasLiveAttachSession })
        #expect(console.agentTerminals.entries[pane.id] != nil)
        switch departure {
        case .showChat: presented = false
        case .linkReplacement: current = CodexSessionLinksTests.pane("w1:p2", backend: .herdr)
        case .linkLoss: current = nil
        case .leaveThread: visible = false
        }
        // Removing the child's presentation delivers the same disappear as
        // Show Chat or a changed link, while the parent may stay selected.
        window?.rootViewController = nil
        try #require(await Self.eventually { !(await transport.hasLiveAttachSession) },
            "a linked terminal must release its PTY before the retention timeout")
        await console.agentTerminals.suspend()
    }

    /// A return past the grace period suspends the Console, which evicts the
    /// retained Attach store; the Agent detail then rebuilds its terminal
    /// screen around a new one. The frame the old screen painted must outlive
    /// that screen too, as a copy (#21).
    @Test func aReturnFromSuspensionKeepsTheLastFrameAcrossTheNewAttachStore()
        async throws
    {
        let host = Host.fixture()
        let first = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let second = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let connections = SurfaceTestConnections([first, second])
        let console = ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { try await connections.next() },
                reconnectPolicy: ReconnectPolicy(
                    initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
                keepalive: nil)
        }
        let activity = AppActivityCoordinator(
            gracePeriod: .milliseconds(50), granter: SurfaceTestBackgroundGranter())
        let driver = Task { await ConsoleActivityDriver(activity: activity, console: console).run() }
        var window: UIWindow?
        func teardown() async {
            driver.cancel()
            await driver.value
            console.setHosts([])
            await console.agentTerminals.suspend()
            window?.isHidden = true
            window?.rootViewController = nil
        }
        func run() async throws {
            console.setHosts([host])
            await console.resume()
            try #require(await Self.eventually { console.agents.count == 1 })
            let agent = try #require(console.agents.first)
            let defaults = UserDefaults(suiteName: "last-frame-\(UUID())") ?? .standard
            let controller = UIHostingController(
                rootView: AgentDetailView(
                    agent: agent,
                    console: console,
                    terminal: TerminalSettings(
                        themes: TerminalThemeSettings(defaults: defaults),
                        zoom: TerminalZoomSettings(defaults: defaults),
                        fonts: TerminalFontSettings(defaults: defaults),
                        snippets: SnippetStore(defaults: defaults),
                        toolbars: AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)),
                    hosts: [host],
                    activity: activity,
                    keyboardHandoff: TerminalKeyboardHandoff(),
                    keyboardInset: TerminalKeyboardInset(),
                    stage: AgentDetailStage(isVisible: { true }, terminalAccess: { .holds }),
                    onSwitch: { _ in },
                    onClosed: {}))
            window = try await makeTestWindow(
                frame: CGRect(x: 0, y: 0, width: 402, height: 874),
                rootViewController: controller)
            func showsConnecting() -> Bool { Self.shows("Connecting…", in: controller) }
            func showsReconnecting() -> Bool { Self.showsReconnecting(in: controller) }

            try #require(await Self.eventually {
                showsConnecting() && !showsReconnecting()
            }, "a cold open shows the Connecting loader")
            try #require(await Self.eventually {
                _ = showsReconnecting()
                return await first.hasLiveAttachSession
            }, "the retained Attach should open")
            #expect(await first.emitAttachOutput(Data("first-frame".utf8)))
            try #require(await Self.eventually {
                console.agentTerminals.entries.values.first?.attach.terminalStatus == .live
                    && !showsConnecting()
            }, "the retained Attach should paint")
            weak var predecessor: WaycarTerminalView?
            do {
                let surface = try #require(Self.terminals(in: controller.view).first)
                predecessor = surface
            }

            activity.didEnterBackground(.phone)
            try #require(await Self.eventually { console.agentTerminals.entries.isEmpty },
                "the suspension should evict the retained Attach")
            activity.didBecomeActive(.phone)
            try #require(await Self.eventually {
                _ = showsReconnecting()
                return await second.hasLiveAttachSession
            }, "the new Attach store should open on the new connection")
            try #require(await Self.eventually { showsReconnecting() && !showsConnecting() },
                "the new screen keeps the old frame up under the Reconnecting loader")
            try #require(await Self.eventually { _ = showsReconnecting(); return predecessor == nil },
                "only a copy stands in for the old surface, which is released (#242)")
            #expect(showsReconnecting())

            #expect(await second.emitAttachOutput(Data("second-frame".utf8)))
            try #require(await Self.eventually { !showsReconnecting() },
                "the Reconnecting loader goes once the new Attach paints")
        }
        do { try await run() } catch {
            await teardown()
            throw error
        }
        await teardown()
    }

    // MARK: Fixtures

    static func shows(_ label: String, in controller: UIViewController) -> Bool {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return accessibilityLabels(in: controller.view).contains(label)
    }

    static func showsReconnecting(in controller: UIViewController) -> Bool {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        // SwiftUI's accessibility nodes answer the selector without declaring
        // `UIAccessibilityIdentification`, so ask for it by selector.
        let identifier = NSSelectorFromString("accessibilityIdentifier")
        return accessibilityStrings(in: controller.view) { node in
            guard node.responds(to: identifier) else { return nil }
            return node.perform(identifier)?.takeUnretainedValue() as? String
        }.contains("terminal.reconnecting")
    }

    /// Every accessibility label reachable from `root`, through both the view
    /// tree and the accessibility element tree that SwiftUI hosts publish.
    static func accessibilityLabels(in root: UIView) -> Set<String> {
        accessibilityStrings(in: root) { $0.accessibilityLabel }
    }

    private static func accessibilityStrings(
        in root: UIView, _ value: (NSObject) -> String?
    ) -> Set<String> {
        var visited = Set<ObjectIdentifier>()
        var strings = Set<String>()
        func visit(_ node: NSObject) {
            guard visited.insert(ObjectIdentifier(node)).inserted,
                  !node.accessibilityElementsHidden else { return }
            if let string = value(node) { strings.insert(string) }
            for object in node.accessibilityElements ?? [] {
                if let object = object as? NSObject { visit(object) }
            }
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let object = node.accessibilityElement(at: index) as? NSObject { visit(object) }
                }
            }
            if let view = node as? UIView { view.subviews.forEach(visit) }
        }
        visit(root)
        return strings
    }

    static func terminals(in root: UIView) -> [WaycarTerminalView] {
        var found: [WaycarTerminalView] = []
        func walk(_ view: UIView) {
            if let terminal = view as? WaycarTerminalView { found.append(terminal) }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        return found
    }

    /// A SwiftUI/UIKit hierarchy is sufficient for these replacement tests.
    /// Requiring `UIApplication.connectedScenes` made the test precondition
    /// depend on how the headless runner launched its host, before any product
    /// code ran.
    static func makeLocalTestWindow(
        frame: CGRect,
        rootViewController: UIViewController
    ) -> UIWindow {
        let window = UIWindow(frame: frame)
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        return window
    }

    static func makeAgent(pane: String, host: UUID = UUID()) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host,
            hostName: "devbox",
            agent: Agent(
                terminalID: "term_\(pane)", kind: "claude", title: "",
                status: .idle, workspaceID: "w", tabID: "w:t", paneID: pane,
                cwd: "/work", revision: 1, name: nil),
            workspaceLabel: nil,
            repositoryCheckout: nil)
    }

    /// Mirrors what `ConsoleView` hands its detail column rather than importing
    /// a fixture: `DemoScreenshotFixture` is
    /// `#if DEBUG && targetEnvironment(simulator)`, so depending on it would bar
    /// these tests from ever running on a device.
    ///
    /// The stores are built once and shared across switches because that is
    /// what the Console does — only the Agent changes.
    static func detailViewFactory() -> (ConsoleAgent) -> AgentTerminalView {
        let defaults = UserDefaults(suiteName: "agent-surface-\(UUID())") ?? .standard
        let console = ConsoleStore(snapshotRetryDelay: .seconds(30)) { _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: {
                    throw TransportError.streamLocalOpenFailed(path: "/tmp/herdr.sock")
                },
                reconnectPolicy: ReconnectPolicy(
                    initialDelay: .milliseconds(10), multiplier: 2,
                    maxDelay: .milliseconds(50)),
                keepalive: .default)
        }
        let terminal = TerminalSettings(
            themes: TerminalThemeSettings(defaults: defaults),
            zoom: TerminalZoomSettings(defaults: defaults),
            fonts: TerminalFontSettings(defaults: defaults),
            snippets: SnippetStore(defaults: defaults),
            toolbars: AgentToolbarLayoutStore(defaults: defaults, idiom: .phone))
        let handoff = TerminalKeyboardHandoff()
        let inset = TerminalKeyboardInset()
        let activity = AppActivityCoordinator()
        return { agent in
            let composer = console.composerStore(for: agent)
            return AgentTerminalView(
                agent: agent,
                console: console,
                terminal: terminal,
                hosts: [],
                activity: activity,
                keyboardHandoff: handoff,
                keyboardInset: inset,
                isOnStage: { true },
                onSwitch: { _ in },
                onClosed: {},
                composer: composer)
        }
    }

    private static func makeDetailView(
        agent: ConsoleAgent,
        activity: AppActivityCoordinator,
        attachStore: AgentAttachStore,
        composer: AgentComposerStore
    ) -> AgentTerminalView {
        let defaults = UserDefaults(suiteName: "attach-recovery-\(UUID())") ?? .standard
        let console = ConsoleStore(snapshotRetryDelay: .seconds(30)) { _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { throw TransportError.sshUnreachable(detail: "fixture") },
                reconnectPolicy: .default,
                keepalive: .default)
        }
        let terminal = TerminalSettings(
            themes: TerminalThemeSettings(defaults: defaults),
            zoom: TerminalZoomSettings(defaults: defaults),
            fonts: TerminalFontSettings(defaults: defaults),
            snippets: SnippetStore(defaults: defaults),
            toolbars: AgentToolbarLayoutStore(defaults: defaults, idiom: .phone))
        return AgentTerminalView(
            agent: agent,
            console: console,
            terminal: terminal,
            hosts: [],
            activity: activity,
            keyboardHandoff: TerminalKeyboardHandoff(),
            keyboardInset: TerminalKeyboardInset(),
            isOnStage: { true },
            onSwitch: { _ in },
            onClosed: {},
            composer: composer,
            attachStore: attachStore)
    }

    private static func makeComposer(transport: ScriptedTransport) -> AgentComposerStore {
        AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
    }

    private static func makeAttachStore(
        transport: ScriptedTransport,
        composer: AgentComposerStore
    ) -> AgentAttachStore {
        AgentAttachStore(
            target: .agentPane("w1:p1"),
            transportGeneration: 1,
            recordsNetworkTelemetry: true,
            isOnStage: { true },
            runTerminal: { request, handler in
                let session = try await transport.attachTerminal(request)
                try await handler.runEndingSession(session)
            },
            stageImage: { _, _ in throw TransportError.cancelled },
            stageFile: { _, _ in throw TransportError.cancelled },
            composer: composer,
            closePane: {})
    }

    private static func eventually(
        timeout: Duration = .waitCeiling,
        condition: () async -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

@MainActor
private final class SurfaceTestBackgroundGranter: BackgroundExecutionGranting {
    private var nextRawValue = 1

    func begin(
        onExpiration _: @escaping @MainActor @Sendable () -> Void
    ) -> BackgroundExecutionToken? {
        defer { nextRawValue += 1 }
        return BackgroundExecutionToken(rawValue: nextRawValue)
    }

    func end(_: BackgroundExecutionToken) {}

    var backgroundTimeRemaining: Duration { .seconds(10) }
}

@MainActor
private final class RefusingSurfaceTestBackgroundGranter: BackgroundExecutionGranting {
    func begin(
        onExpiration _: @escaping @MainActor @Sendable () -> Void
    ) -> BackgroundExecutionToken? {
        nil
    }

    func end(_: BackgroundExecutionToken) {}

    var backgroundTimeRemaining: Duration { .zero }
}

/// Hands out the scripted connections a Host makes, in order.
private actor SurfaceTestConnections {
    private var remaining: [ScriptedTransport]

    init(_ transports: [ScriptedTransport]) {
        remaining = transports
    }

    func next() throws -> ScriptedTransport {
        guard !remaining.isEmpty else {
            throw TransportError.sshUnreachable(detail: "no scripted connection left")
        }
        return remaining.removeFirst()
    }
}
