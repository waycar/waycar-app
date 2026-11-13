import Foundation
import GhosttyTerminal
import Observation
import Testing
import SwiftUI
import UIKit

@testable import Waycar

/// The keyboard handoff: a one-shot claim that carries the keyboard across a
/// screen change so the terminal takes it over without letting it drop.
@Suite("Terminal keyboard handoff")
struct TerminalKeyboardHandoffTests {
    @MainActor
    @Test func anOlderShellCreationCannotCancelTheReplacementHandoff() {
        let handoff = TerminalKeyboardHandoff()
        let first = handoff.armShellTerminal(mode: .text)
        let second = handoff.armShellTerminal(mode: .controls)
        // Detail A completes after Detail B has armed its own handoff.
        handoff.cancelShellTerminal(ifOwnedBy: first)
        #expect(handoff.consumeShellTerminal(ifOwnedBy: first) == nil)
        #expect(handoff.consumeShellTerminal(ifOwnedBy: second) == .controls)
    }

    private static func makeAgent(
        pane: String,
        workspace: String? = nil,
        repo: String? = nil,
        name: String? = nil,
        status: AgentStatus = .idle,
        host: UUID = UUID()
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host,
            hostName: "devbox",
            agent: Agent(
                terminalID: "term_\(pane)", kind: "claude", title: "",
                status: status, workspaceID: "w", tabID: "w:t", paneID: pane,
                cwd: "/work", revision: 1, name: name),
            workspaceLabel: workspace,
            repositoryCheckout: repo.map {
                RepositoryCheckout(
                    repoKey: "/work/\($0)/.git",
                    repoName: $0,
                    repoRoot: "/work/\($0)",
                    checkoutPath: "/work/\($0)",
                    isLinkedWorktree: false)
            })
    }

    @MainActor
    private static func waitForMainQueueTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    @Test func theKeyboardHandoffIsGoodForExactlyOneScreen() {
        let host = UUID()
        let first = Self.makeAgent(pane: "p1", host: host).id
        let second = Self.makeAgent(pane: "p2", host: host).id
        let handoff = TerminalKeyboardHandoff()

        #expect(!handoff.consume(second))

        handoff.arm(for: second)
        // Only the Agent that was switched to inherits the keyboard.
        #expect(!handoff.consume(first))
        #expect(handoff.consume(second))
        #expect(!handoff.consume(second))
    }

    @MainActor
    @Test func keyboardHandoffCancellationOnlyClearsTheMatchingAgent() {
        let handoff = TerminalKeyboardHandoff()
        let first = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1")
        let second = ConsoleAgent.ID(hostID: UUID(), paneID: "w2:p2")

        handoff.arm(for: first)
        handoff.cancel(for: second)
        #expect(handoff.consume(first))

        handoff.arm(for: second)
        handoff.cancel(for: second)
        #expect(!handoff.consume(second))
    }

    /// A Shell Terminal's identity is often unknown when the keyboard state
    /// is captured, so its handoff is unkeyed, one-shot, and cancellable.
    @MainActor
    @Test func theShellTerminalHandoffIsUnkeyedOneShotAndCancellable() {
        let handoff = TerminalKeyboardHandoff()
        #expect(handoff.consumeShellTerminal(ifOwnedBy: nil) == nil)

        let first = handoff.armShellTerminal()
        #expect(handoff.consumeShellTerminal(ifOwnedBy: first) == .text)
        #expect(handoff.consumeShellTerminal(ifOwnedBy: first) == nil, "spent on the first screen")

        let second = handoff.armShellTerminal()
        handoff.cancelShellTerminal(ifOwnedBy: second)
        #expect(handoff.consumeShellTerminal(ifOwnedBy: second) == nil, "a failed creation must not raise a later open")

        // Independent of the Agent-keyed intent.
        let agent = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:pA")
        handoff.arm(for: agent)
        #expect(handoff.consumeShellTerminal(ifOwnedBy: nil) == nil)
        #expect(handoff.consume(agent))
    }

    /// Open Terminal / New Terminal from Direct Input's tools dock must hand
    /// the shell the tools dock, exactly like an Agent switch, not raise the
    /// iOS keyboard in its place.
    @MainActor
    @Test func theShellTerminalHandoffCarriesItsKeyboardMode() {
        let handoff = TerminalKeyboardHandoff()
        let token = handoff.armShellTerminal(mode: .controls)
        #expect(handoff.consumeShellTerminal(ifOwnedBy: token) == .controls)
    }

    /// The screen being left reads `isArmed` to keep first responder until
    /// the destination claims the keyboard.
    @MainActor
    @Test func anArmedHandoffIsVisibleUntilItIsConsumedOrCancelled() {
        let handoff = TerminalKeyboardHandoff()
        let agent = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:pA")
        #expect(!handoff.isArmed)

        handoff.arm(for: agent)
        #expect(handoff.isArmed)
        _ = handoff.consume(agent)
        #expect(!handoff.isArmed)

        handoff.arm(for: agent)
        handoff.cancel(for: agent)
        #expect(!handoff.isArmed)

        let first = handoff.armShellTerminal()
        #expect(handoff.isArmed)
        _ = handoff.consumeShellTerminal(ifOwnedBy: first)
        #expect(!handoff.isArmed)

        let second = handoff.armShellTerminal()
        handoff.cancelShellTerminal(ifOwnedBy: second)
        #expect(!handoff.isArmed)
    }

    /// The keyboard may not dip between the two terminals: a dip flashes the
    /// keyboard and its accessory row away mid-switch. The replacement
    /// takes first responder in the same pass it reaches the window.
    @MainActor
    @Test func aClaimedHandoffTakesTheKeyboardOverWithoutLettingItDrop() async throws {
        let center = NotificationCenter()
        let host = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: host)
        defer { window.isHidden = true }

        let plain = TerminalScreenView.makeConfiguredTerminal(
            notificationCenter: center)
        plain.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        host.view.addSubview(plain)
        #expect(!plain.isFirstResponder)

        let claimed = TerminalScreenView.makeConfiguredTerminal(
            notificationCenter: center)
        claimed.raisesKeyboardWhenReady = true
        claimed.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        host.view.addSubview(claimed)
        #expect(claimed.isFirstResponder)

        // One shot: coming back on screen later starts with the keyboard down.
        claimed.dismissKeyboard()
        claimed.removeFromSuperview()
        host.view.addSubview(claimed)
        #expect(!claimed.isFirstResponder)
    }

    /// A grid Ghostty measured a surface against, as the Host is told about it.
    private struct TerminalGrid: Hashable, CustomStringConvertible {
        let columns: Int
        let rows: Int

        var description: String { "\(columns)x\(rows)" }
    }

    /// Ghostty's first viewport report on a fresh surface carries a zero cell
    /// size. Measuring the surface against that half-built grid — which is
    /// what happens when the view shrinks for the keyboard right after the
    /// handoff — leaves it drawing a band shorter than the view, showing as an
    /// unpainted strip above the toolbar. So the grid stays frozen until the
    /// keyboard has settled, and the only grid that reaches the Host is the
    /// settled one.
    @MainActor
    @Test func aClaimedHandoffFreezesTheGridUntilTheKeyboardSettles() async throws {
        var reportedGrids: [TerminalGrid] = []
        // The terminal's own center, so a keyboard settling anywhere else in
        // the process — another test's terminal, say — cannot end this
        // handoff (#157).
        let center = NotificationCenter()
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSizeChanged: { columns, rows in
                reportedGrids.append(TerminalGrid(columns: columns, rows: rows))
            },
            notificationCenter: center)
        // The freeze's own transitions, so each step below waits on the fact
        // it is about to assert rather than on how quickly this runner gets
        // Ghostty to answer. Polling for reports to appear and go quiet timed
        // out here for thirteen seconds on merge CI, and could not say whether
        // the freeze was still holding or had thawed with nothing to forward
        // (#263).
        let phases = TerminalGridReportPhaseRecorder(observing: terminal)
        let host = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: host)
        defer {
            terminal.removeFromSuperview()
            window.isHidden = true
        }

        // This test thaws the freeze explicitly below, so the wall-clock
        // fallback must stay out of it: the sleeps inside the handoff window
        // can stretch past its 500ms on a loaded runner (#225).
        terminal.keyboardTransitionFallbackDelay = 60
        let localKeyboardFrame = CGRect(x: 0, y: 400, width: 390, height: 300)
        terminal.keyboardLayoutFrameProvider = { _ in localKeyboardFrame }
        terminal.raisesKeyboardWhenReady = true
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        host.view.addSubview(terminal)
        window.layoutIfNeeded()
        // Only a first responder is handed the settle signal that ends this
        // freeze, so a refused claim is a different failure from a freeze that
        // would not thaw — and has to be told apart from one.
        #expect(terminal.isFirstResponder)
        #expect(terminal.gridReportPhase == .deferring)
        let ownKeyboardEndFrame = window.convert(
            localKeyboardFrame, to: window.screen.coordinateSpace)

        // A foreign settle, posted to the process-wide center inside the
        // handoff window. Before the isolation above, exactly this thawed the
        // freeze early — that was #145's second failure — so the window below
        // doubles as the proof that it no longer can.
        NotificationCenter.default.post(
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil)

        // The keyboard is arriving: every bounds UIKit animates through here
        // is a half-built grid Ghostty must not be measured against. The pause
        // gives the engine's own callbacks a chance to escape the freeze; it
        // proves nothing on its own, which is what the phase assertions are
        // for.
        for height: CGFloat in [520, 440, 360] {
            terminal.frame.size.height = height
            terminal.setNeedsLayout()
            terminal.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(reportedGrids.isEmpty)
        #expect(terminal.gridReportPhase == .deferring)

        // The first owned frame still includes both responders' accessories.
        // It rebuilds the input views but must leave the grid frozen until
        // UIKit republishes the destination-only frame.
        let rebuildsBeforeOwnedFrame = terminal.inputViewRebuildCount
        center.post(
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: ownKeyboardEndFrame])
        #expect(reportedGrids.isEmpty)
        #expect(terminal.gridReportPhase == .deferring)
        await Self.waitForMainQueueTurn()
        #expect(terminal.inputViewRebuildCount > rebuildsBeforeOwnedFrame)
        #expect(terminal.gridReportPhase == .deferring)

        // Ghostty measures the surface through this delegate call, and the
        // thaw forwards whatever it measured last — the settled layout's own
        // measurement, taken inside the thaw, when the surface is answering.
        // Standing in for it here is what keeps this off the engine's
        // schedule: a runner whose surface has not answered at all would
        // otherwise leave the freeze with nothing to forward, and the
        // assertions below with nothing to hold it to.
        terminal.terminalDidResize(
            TerminalGridMetrics(
                columns: 39, rows: 22,
                widthPixels: 1_170, heightPixels: 1_080,
                cellWidthPixels: 30, cellHeightPixels: 49))

        // The rebuilt input views republish the settled destination frame.
        center.post(
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: ownKeyboardEndFrame])
        let forwarded = try await phases.thawedGrid()
        let escaped = reportedGrids
        let settled = try #require(
            forwarded, "the freeze ended without telling the Host any grid")

        #expect(
            settled == terminal.measuredGrid,
            "the thaw forwarded \(settled), not the grid the surface settled on")
        // Whatever escaped has to be that one grid — never a taller or
        // half-built one from inside the freeze, and never nothing at all.
        #expect(
            escaped == [TerminalGrid(columns: settled.columns, rows: settled.rows)],
            "the freeze let a grid other than the settled \(settled) out: \(escaped)")
    }

    /// The freeze suppresses `layoutSubviews` outright, so entering it commits
    /// the terminal to a settle signal only a first responder is sent. A claim
    /// UIKit refuses leaves nothing that can end it — the grid would stay
    /// frozen, and the surface unlaid, until the wall-clock leash.
    @MainActor
    @Test func aRefusedKeyboardClaimThawsTheGridWithoutTheLeash() async throws {
        let center = NotificationCenter()
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            notificationCenter: center)
        let phases = TerminalGridReportPhaseRecorder(observing: terminal)
        let host = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: host)
        defer {
            terminal.removeFromSuperview()
            window.isHidden = true
        }

        // Local input is what UIKit asks about in `canBecomeFirstResponder`,
        // so this is a claim that cannot be granted. The leash is stretched
        // past any plausible test: only the refusal itself can thaw this.
        terminal.setLocalInputEnabled(false)
        terminal.keyboardTransitionFallbackDelay = 60
        terminal.raisesKeyboardWhenReady = true
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        host.view.addSubview(terminal)
        window.layoutIfNeeded()

        #expect(!terminal.isFirstResponder)
        try await phases.thawedGrid()
        #expect(terminal.gridReportPhase == .live)
    }

    /// `becomeFirstResponder()` and `reloadInputViews()` may synchronously
    /// publish keyboard frames. An explicit Composer-to-terminal handoff must
    /// return to its owner before rebuilding input views, or the terminal can
    /// report settlement before the owner has entered its settling state and
    /// that one-shot callback is lost.
    @MainActor
    @Test func anExplicitHandoffCannotSettleBeforeItsOwnerAcceptsIt() async throws {
        let center = NotificationCenter()
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            notificationCenter: center)
        let host = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: host)
        defer {
            terminal.removeFromSuperview()
            window.isHidden = true
        }

        terminal.keyboardTransitionFallbackDelay = 60
        let localKeyboardFrame = CGRect(x: 0, y: 400, width: 390, height: 300)
        terminal.keyboardLayoutFrameProvider = { _ in localKeyboardFrame }
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        host.view.addSubview(terminal)
        window.layoutIfNeeded()

        let handoffID = UUID()
        var ownerAccepted = false
        var settledOwnerStates: [Bool] = []
        terminal.onKeyboardHandoffEnded = { settledID, outcome in
            guard settledID == handoffID else { return }
            guard outcome == .settled else { return }
            settledOwnerStates.append(ownerAccepted)
        }
        #expect(terminal.requestKeyboardHandoff(id: handoffID))
        terminal.requestKeyboard()
        #expect(
            settledOwnerStates.isEmpty,
            "a duplicate request must not cancel the accepted handoff")

        let rebuildsBeforeOwnedFrame = terminal.inputViewRebuildCount
        let ownKeyboardEndFrame = window.convert(
            localKeyboardFrame, to: window.screen.coordinateSpace)
        center.post(
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: ownKeyboardEndFrame])

        #expect(
            terminal.inputViewRebuildCount == rebuildsBeforeOwnedFrame,
            "the destination rebuilt input views before its owner accepted the handoff")
        #expect(settledOwnerStates.isEmpty)

        ownerAccepted = true
        await Self.waitForMainQueueTurn()
        #expect(terminal.inputViewRebuildCount > rebuildsBeforeOwnedFrame)
        #expect(settledOwnerStates.isEmpty)

        center.post(
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: ownKeyboardEndFrame])
        #expect(settledOwnerStates == [true])
    }

    /// The terminal owns the only safety leash for Composer-to-Direct. If no
    /// destination frame ever arrives, timing out must release the hold
    /// without treating a transient hide as proof that the keyboard left.
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func aTerminalTimeoutPreservesItsDestinationOwnedInset() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 402 }
        let presentation = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { presentation.continuation.finish() }
        withObservationTracking {
            _ = inset.height
        } onChange: {
            presentation.continuation.yield(())
        }
        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 554, width: 440, height: 436)])
        var presentationEvents = presentation.stream.makeAsyncIterator()
        _ = await presentationEvents.next()
        try #require(inset.height == 402)

        let terminal = TerminalScreenView.makeConfiguredTerminal(
            notificationCenter: center)
        let host = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: host)
        defer {
            terminal.removeFromSuperview()
            window.isHidden = true
        }
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        terminal.keyboardTransitionFallbackDelay = 0.05
        host.view.addSubview(terminal)
        window.layoutIfNeeded()

        let handoffID = inset.beginDestinationOwnedResponderHandoff()
        let ended = AsyncStream<TerminalKeyboardHandoffOutcome>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        defer { ended.continuation.finish() }
        terminal.onKeyboardHandoffEnded = { endedID, outcome in
            guard endedID == handoffID else { return }
            switch outcome {
            case .settled, .timedOut:
                inset.endResponderHandoff(endedID)
            case .cancelled:
                inset.cancelResponderHandoff(endedID, currentHeight: { 0 })
            }
            ended.continuation.yield(outcome)
        }
        try #require(terminal.requestKeyboardHandoff(id: handoffID))
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        var handoffEvents = ended.stream.makeAsyncIterator()
        let endedOutcome = await handoffEvents.next()

        #expect(endedOutcome == .timedOut)
        #expect(!inset.isHoldingHandoffHeight)
        #expect(inset.height == 402)
    }

    /// SwiftUI can temporarily detach a live terminal while presenting new
    /// chrome. That must not cancel a handoff which the same terminal resumes
    /// after reattachment.
    @MainActor
    @Test func aTemporaryDetachKeepsItsDestinationOwnedHandoff() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 402 }
        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 554, width: 440, height: 436)])
        try await waitUntil("the keyboard inset should reach its presented height") { inset.height == 402 }

        let terminal = TerminalScreenView.makeConfiguredTerminal(
            notificationCenter: center)
        let host = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: host)
        defer {
            terminal.removeFromSuperview()
            window.isHidden = true
        }
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        terminal.keyboardTransitionFallbackDelay = 60
        let localKeyboardFrame = CGRect(x: 0, y: 400, width: 390, height: 300)
        terminal.keyboardLayoutFrameProvider = { _ in localKeyboardFrame }
        host.view.addSubview(terminal)
        window.layoutIfNeeded()

        let handoffID = inset.beginDestinationOwnedResponderHandoff()
        var endedOutcome: TerminalKeyboardHandoffOutcome?
        terminal.onKeyboardHandoffEnded = { endedID, outcome in
            guard endedID == handoffID else { return }
            endedOutcome = outcome
            switch outcome {
            case .settled, .timedOut:
                inset.endResponderHandoff(endedID)
            case .cancelled:
                inset.cancelResponderHandoff(endedID, currentHeight: { nil })
            }
        }
        #expect(terminal.requestKeyboardHandoff(id: handoffID))
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        terminal.removeFromSuperview()
        await Task.yield()

        #expect(endedOutcome == nil)
        #expect(inset.isHoldingHandoffHeight)

        host.view.addSubview(terminal)
        terminal.requestKeyboard()
        let ownKeyboardEndFrame = window.convert(
            localKeyboardFrame, to: window.screen.coordinateSpace)
        center.post(
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: ownKeyboardEndFrame])
        await Self.waitForMainQueueTurn()
        center.post(
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: ownKeyboardEndFrame])

        #expect(endedOutcome == .settled)
        #expect(!inset.isHoldingHandoffHeight)
        #expect(inset.height == 402)
    }

    /// Both terminals' accessories ride the keyboard while it changes hands,
    /// and that is the frame the keyboard publishes: one accessory too tall.
    /// UIKit publishes no other when the outgoing one leaves, so the layout
    /// keeps reserving room for a toolbar that is gone — measured on device,
    /// the terminal came back 88pt short and the agent lost five rows. The
    /// rebuild at the end of the handoff is what republishes the settled
    /// frame; a dismissal has no stale accessory and must not pay for one.
    @MainActor
    @Test func aClaimedHandoffRebuildsInputViewsToRepublishTheKeyboardFrame() async throws {
        let host = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: host)
        defer { window.isHidden = true }

        // Both terminals observe the test's own center: with every terminal
        // in the process on the shared one, any keyboard settling anywhere
        // could end the handoff before the explicit call below (#157).
        let center = NotificationCenter()
        let inherited = TerminalScreenView.makeConfiguredTerminal(
            notificationCenter: center)
        inherited.raisesKeyboardWhenReady = true
        inherited.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        host.view.addSubview(inherited)
        // A foreign settle inside the handoff window must leave the handoff
        // standing, so the call below is necessarily what ends it — and the
        // republish lands exactly there, not whenever a neighbour's keyboard
        // happened to settle.
        NotificationCenter.default.post(
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        let rebuildsBeforeHandoffEnds = inherited.inputViewRebuildCount
        inherited.finishKeyboardTransitionLayout()
        #expect(inherited.inputViewRebuildCount > rebuildsBeforeHandoffEnds)

        // A terminal that raised its own keyboard has no outgoing accessory to
        // account for, so the same call must leave its input views alone. That
        // makes it the yardstick as well: same surface, same window, same
        // keyboard, differing only in having no handoff to pay for.
        let dismissing = TerminalScreenView.makeConfiguredTerminal(
            notificationCenter: center)
        dismissing.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        host.view.addSubview(dismissing)
        dismissing.requestKeyboard()
        let rebuildsBeforeDismissalEnds = dismissing.inputViewRebuildCount
        dismissing.finishKeyboardTransitionLayout()
        #expect(dismissing.inputViewRebuildCount == rebuildsBeforeDismissalEnds)

        #expect(
            inherited.inputViewRebuildCount > dismissing.inputViewRebuildCount,
            """
            the handoff rebuilt the input views \(inherited.inputViewRebuildCount) times, \
            the dismissal \(dismissing.inputViewRebuildCount)
            """)
    }

    /// Keyboard notifications are process-wide, and on iPad two of the app's
    /// windows can each hold a live terminal (#157). Both of these terminals
    /// share one center, the shape production gets from `.default`; a private
    /// one keeps the CI simulator's real software keyboard (raised by the
    /// first-responder claim below, with settle frames that cover this
    /// window) from thawing the handoff before the assertions sample it.
    /// Generic show/hide events, a frame without ownership evidence, and a
    /// frame leaving the other window must all leave this terminal's handoff
    /// alone. Only a frame that leaves the keyboard covering this terminal's
    /// own window may thaw it.
    @MainActor
    @Test func anotherWindowsKeyboardEventsDoNotEndTheHandoff() async throws {
        var reportedGrids: [TerminalGrid] = []
        let center = NotificationCenter()
        let foreign = TerminalScreenView.makeConfiguredTerminal(notificationCenter: center)
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSizeChanged: { columns, rows in
                reportedGrids.append(TerminalGrid(columns: columns, rows: rows))
            },
            notificationCenter: center)
        let phases = TerminalGridReportPhaseRecorder(observing: terminal)
        let localKeyboardFrame = CGRect(x: 0, y: 400, width: 390, height: 300)
        terminal.keyboardLayoutFrameProvider = { _ in localKeyboardFrame }
        let foreignHost = UIViewController()
        let foreignWindow = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: foreignHost)
        let host = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: host)
        defer {
            terminal.removeFromSuperview()
            foreign.removeFromSuperview()
            window.isHidden = true
            foreignWindow.isHidden = true
        }

        foreign.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        foreignHost.view.addSubview(foreign)

        // The handoff itself: the terminal claims the keyboard as it reaches
        // its window and freezes its grid until that keyboard settles. This
        // test drives that settle explicitly, so the wall-clock fallback stays
        // out of it — a loaded runner must not thaw the freeze the foreign
        // events below are supposed to leave alone (#225).
        terminal.keyboardTransitionFallbackDelay = 60
        terminal.raisesKeyboardWhenReady = true
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        host.view.addSubview(terminal)
        window.layoutIfNeeded()
        #expect(terminal.isFirstResponder)
        let ownKeyboardEndFrame = window.convert(
            localKeyboardFrame, to: window.screen.coordinateSpace)

        // The other window's keyboard notifications provide no usable scene
        // identity. Its end frame leaves nothing covering this terminal's
        // window. A thaw rebuilds the input views on the spot, so an unchanged
        // rebuild count proves the freeze survived synchronously.
        let rebuildsBeforeForeignEvent = terminal.inputViewRebuildCount
        center.post(
            name: UIResponder.keyboardDidShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 400, width: 390, height: 300)])
        center.post(
            name: UIResponder.keyboardDidHideNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 700, width: 390, height: 300)])
        center.post(
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        center.post(
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 700, width: 390, height: 300)])
        // Same top edge as this window's keyboard, but a different floating
        // footprint. Comparing only minY would incorrectly thaw the handoff.
        center.post(
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 50, y: 400, width: 290, height: 300)])
        #expect(terminal.inputViewRebuildCount == rebuildsBeforeForeignEvent)

        for height: CGFloat in [520, 440, 360] {
            terminal.frame.size.height = height
            terminal.setNeedsLayout()
            terminal.layoutIfNeeded()
        }
        #expect(terminal.inputViewRebuildCount == rebuildsBeforeForeignEvent)
        #expect(reportedGrids.isEmpty)
        #expect(terminal.gridReportPhase == .deferring)

        // The first owned frame rebuilds the destination input views while
        // retaining the freeze; their republished frame then thaws it.
        center.post(
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: ownKeyboardEndFrame])
        await Self.waitForMainQueueTurn()
        #expect(terminal.inputViewRebuildCount > rebuildsBeforeForeignEvent)
        #expect(reportedGrids.isEmpty)
        #expect(terminal.gridReportPhase == .deferring)
        // Stands in for Ghostty measuring the settled layout, so the thaw has
        // a grid to forward whatever the engine's schedule is here.
        terminal.terminalDidResize(
            TerminalGridMetrics(
                columns: 39, rows: 22,
                widthPixels: 1_170, heightPixels: 1_080,
                cellWidthPixels: 30, cellHeightPixels: 49))
        center.post(
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: ownKeyboardEndFrame])
        let forwarded = try await phases.thawedGrid()
        #expect(
            forwarded != nil,
            "the terminal's own settle never made it past the freeze")
    }

}
