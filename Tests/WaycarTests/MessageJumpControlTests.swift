import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Waycar

/// Host that reports a stable intrinsic size so
/// `MessageJumpChromeContainer.layoutSubviews` does not collapse to zero.
private final class MessageJumpSizedHost: UIView {
    var fixedSize: CGSize = CGSize(width: 44, height: 72)

    override var intrinsicContentSize: CGSize { fixedSize }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(fixedSize.width, size.width > 0 ? size.width : fixedSize.width),
            height: fixedSize.height)
    }
}

struct MessageJumpControlTests {
    /// The user can slide the chrome along the edge; 1 is the position it
    /// always had, 0 the terminal's top, and the band still bounds it.
    @Test func placementFrameSlidesAlongTheEdge() throws {
        let terminalSize = CGSize(width: 390, height: 400)
        let chromeSize = CGSize(width: 44, height: 89)
        let lowest = try #require(MessageJumpPlacement.frame(
            terminalSize: terminalSize, chromeSize: chromeSize))
        let docked = try #require(MessageJumpPlacement.frame(
            terminalSize: terminalSize, chromeSize: chromeSize, edgeFraction: 1))
        #expect(docked == lowest)
        #expect(lowest.maxX == terminalSize.width, "An edge tab docks flush against the edge")
        let top = try #require(MessageJumpPlacement.frame(
            terminalSize: terminalSize, chromeSize: chromeSize, edgeFraction: 0))
        #expect(top.minY == 0)
        #expect(top.minX == lowest.minX)
        let halfway = try #require(MessageJumpPlacement.frame(
            terminalSize: terminalSize, chromeSize: chromeSize, edgeFraction: 0.5))
        #expect(halfway.minY == lowest.minY / 2)
        #expect(MessageJumpPlacement.edgeTravel(
            terminalHeight: terminalSize.height, chromeHeight: chromeSize.height) == lowest.minY)
        let overshoot = try #require(MessageJumpPlacement.frame(
            terminalSize: terminalSize, chromeSize: chromeSize, edgeFraction: 3))
        #expect(overshoot == lowest, "A fraction past the band is the band")
    }

    @MainActor
    @Test func containerLaysOutAtItsEdgeFraction() throws {
        let container = MessageJumpChromeContainer(
            frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        let host = MessageJumpSizedHost()
        host.fixedSize = CGSize(width: 44, height: 72)
        container.embed(host)
        container.layoutIfNeeded()
        let lowest = try #require(container.hostedFrame)
        #expect(container.edgeTravel == lowest.minY)
        container.edgeFraction = 0
        container.setNeedsLayout()
        container.layoutIfNeeded()
        #expect(container.hostedFrame?.minY == 0)
        #expect(container.hostedFrame?.minX == lowest.minX)
    }

    @Test func availabilityRequiresAlternateScreen() {
        #expect(
            MessageJumpControlAvailability.evaluate(
                isAlternateScreen: false,
                canScrollRemoteContent: true)
                == .hidden)
        // At live output only Up has somewhere to go.
        #expect(
            MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                canScrollRemoteContent: true)
                == MessageJumpControlAvailability(
                    showsOlder: true, showsNewer: false, isEnabled: true))
    }

    /// A direction with no valid destination is hidden, not disabled
    /// (issue #268): Down appears once the viewport has left live output and
    /// Up disappears once an older walk has run out of history. `refs #268`.
    @Test func availabilityOffersOnlyDirectionsWithSomewhereToGo() {
        var reach = MessageJumpReach()
        #expect(reach.canJumpOlder)
        #expect(!reach.canJumpNewer)

        reach.noteOlderJump(.found, movedViewport: true)
        #expect(
            MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                canScrollRemoteContent: true,
                reach: reach)
                == MessageJumpControlAvailability(
                    showsOlder: true, showsNewer: true, isEnabled: true))

        reach.noteOlderJump(.reachedEnd, movedViewport: true)
        #expect(
            MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                canScrollRemoteContent: true,
                reach: reach)
                == MessageJumpControlAvailability(
                    showsOlder: false, showsNewer: true, isEnabled: true))

        reach.noteNewerJump(.reachedEnd, movedViewport: true)
        #expect(
            MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                canScrollRemoteContent: true,
                reach: reach)
                == MessageJumpControlAvailability(
                    showsOlder: true, showsNewer: false, isEnabled: true))
    }

    /// A conversation that fits the screen: Up finds nothing and moves
    /// nothing, so the viewport is still live and *both* buttons go. A new
    /// turn re-offers Up; one that lands while the viewport sits at the
    /// oldest message does not, because it arrives below. `refs #268`.
    @Test func reachHidesEverythingWhenNothingScrollsAndReoffersUpOnGrowth() {
        var reach = MessageJumpReach()
        reach.noteOlderJump(.reachedEnd, movedViewport: false)
        #expect(!reach.canJumpOlder)
        #expect(!reach.canJumpNewer)
        #expect(
            !MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                canScrollRemoteContent: true,
                reach: reach).isVisible)

        reach.noteConversationGrew()
        #expect(reach.canJumpOlder)
        #expect(!reach.canJumpNewer)

        var displaced = MessageJumpReach()
        displaced.noteOlderJump(.reachedEnd, movedViewport: true)
        displaced.noteConversationGrew()
        #expect(!displaced.canJumpOlder)
        #expect(displaced.canJumpNewer)
    }

    @Test func reachFollowsTouchScrollsAndKeepsExhaustedWalksOpen() {
        var reach = MessageJumpReach()
        reach.noteTouchScroll(towardOlderContent: true)
        #expect(reach.canJumpNewer)
        #expect(reach.canJumpOlder)

        reach.noteOlderJump(.reachedEnd, movedViewport: true)
        #expect(!reach.canJumpOlder)
        reach.noteTouchScroll(towardOlderContent: false)
        #expect(reach.canJumpOlder)

        // Running out of step budget proves nothing about either end.
        reach.noteOlderJump(.exhausted, movedViewport: true)
        #expect(reach.canJumpOlder)
        #expect(reach.canJumpNewer)
        reach.noteNewerJump(.exhausted, movedViewport: true)
        #expect(reach.canJumpOlder)
        #expect(reach.canJumpNewer)

        // A cancelled walk leaves the verdicts alone.
        var untouched = MessageJumpReach()
        untouched.noteOlderJump(.cancelled, movedViewport: false)
        #expect(untouched == MessageJumpReach())
    }

    /// `herdr terminal attach` always enters the alternate screen, so that
    /// flag says nothing about the application inside it. An application that
    /// never asked for mouse reporting — a plain shell — cannot be scrolled,
    /// and the fallback would feed it cursor keys. Hide the control rather
    /// than offer a button that types into the user's line. `refs #268`.
    @Test func availabilityRequiresAScrollableRemoteApplication() {
        #expect(
            !MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                canScrollRemoteContent: false).isVisible)
        #expect(
            !MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                canScrollRemoteContent: false).isEnabled)
    }

    /// A button that cannot act is hidden, never greyed: a jump in flight
    /// keeps only its own direction, as a spinner that takes no hit, and a
    /// scroll jump in flight hides the tab altogether (#58). The agent's
    /// status plays no part — a working agent can still be walked, it only
    /// makes the end of history harder to detect.
    @Test func availabilityKeepsOnlyTheWalkingDirectionWhileAJumpRuns() {
        var displaced = MessageJumpReach()
        displaced.noteOlderJump(.found, movedViewport: true)
        #expect(
            MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                canScrollRemoteContent: true,
                reach: displaced,
                runningJump: AttachRunningJump(kind: .message, direction: .newer))
                == MessageJumpControlAvailability(
                    showsOlder: false, showsNewer: true, isEnabled: false))
        #expect(
            MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                canScrollRemoteContent: true,
                reach: displaced,
                runningJump: AttachRunningJump(kind: .message, direction: .older))
                == MessageJumpControlAvailability(
                    showsOlder: true, showsNewer: false, isEnabled: false))
        #expect(
            MessageJumpControlAvailability.evaluate(
                isAlternateScreen: true,
                canScrollRemoteContent: true,
                reach: displaced,
                runningJump: AttachRunningJump(kind: .scroll, direction: .older))
                == .hidden)
    }

    @Test func placementFrameHidesChromeThatCannotFitAboveTheBand() {
        // 80-pt terminal, 72-pt chrome: available above the band is 60.
        let short = CGSize(width: 390, height: 80)
        #expect(
            MessageJumpPlacement.frame(
                terminalSize: short,
                chromeSize: CGSize(width: 44, height: 72)) == nil)
        #expect(
            !MessageJumpPlacement.sitsAboveBottomBand(
                terminalHeight: 80,
                controlHeight: 72,
                bottomInset: MessageJumpPlacement.bottomInset(terminalHeight: 80)))

        let tallEnough = CGSize(width: 390, height: 160)
        let fitted = MessageJumpPlacement.frame(
            terminalSize: tallEnough,
            chromeSize: CGSize(width: 44, height: 72))
        #expect(fitted != nil)
        if let fitted {
            #expect(
                MessageJumpPlacement.sitsAboveBottomBand(
                    terminalHeight: tallEnough.height,
                    controlHeight: fitted.height,
                    bottomInset: MessageJumpPlacement.bottomInset(
                        terminalHeight: tallEnough.height)))
        }

        // Narrow surface: notice wider than the terminal cannot produce a
        // negative x origin — the frame is rejected instead.
        #expect(
            MessageJumpPlacement.frame(
                terminalSize: CGSize(width: 40, height: 400),
                chromeSize: CGSize(width: 120, height: 36))
                != nil)
        let narrowFrame = MessageJumpPlacement.frame(
            terminalSize: CGSize(width: 40, height: 400),
            chromeSize: CGSize(width: 120, height: 36))
        #expect(narrowFrame?.origin.x == 0)
        #expect(narrowFrame?.width == 40, "Clamped to the full width: an edge tab has no trailing inset")
    }

    @MainActor
    @Test func shortTerminalContainerHidesChromeThatCannotFit() throws {
        let container = MessageJumpChromeContainer(
            frame: CGRect(x: 0, y: 0, width: 390, height: 80))
        let host = MessageJumpSizedHost()
        host.fixedSize = CGSize(width: 44, height: 72)
        container.embed(host)
        container.layoutIfNeeded()
        #expect(host.isHidden)
        #expect(container.hostedFrame == nil)

        container.frame = CGRect(x: 0, y: 0, width: 390, height: 160)
        container.layoutIfNeeded()
        #expect(!host.isHidden)
        let frame = try #require(container.hostedFrame)
        #expect(
            MessageJumpPlacement.sitsAboveBottomBand(
                terminalHeight: 160,
                controlHeight: frame.height,
                bottomInset: MessageJumpPlacement.bottomInset(terminalHeight: 160)))
    }

    @MainActor
    @Test func downSequencerSkipsReturnToLiveAfterSessionEnds() async {
        var live = true
        var returnToLiveCalls = 0
        let outcome = await MessageJumpDownSequencer.run(
            jumpNewer: {
                live = false
                return .reachedEnd
            },
            returnToLive: {
                returnToLiveCalls += 1
                return .reachedEnd
            },
            isLive: { live })
        #expect(outcome == nil)
        #expect(returnToLiveCalls == 0)
    }

    @MainActor
    @Test func downSequencerReturnsFoundWithoutCallingReturnToLive() async {
        var live = true
        var returnToLiveCalls = 0
        let outcome = await MessageJumpDownSequencer.run(
            jumpNewer: { .found },
            returnToLive: {
                returnToLiveCalls += 1
                return .reachedEnd
            },
            isLive: { live })
        #expect(outcome == .found)
        #expect(returnToLiveCalls == 0)
    }

    @MainActor
    @Test func grokProfileWidensPromptRecognitionWithoutChangingOtherAgents() {
        let grok = AgentMessageJumpProfile.forAgentKind("grok")
        #expect(grok.policy == .stickyPromptOvershoot)
        #expect(grok.maximumPromptIndent == 5)
        let grokWiring = AgentMessageJumpWiring(profile: grok)
        #expect(
            grokWiring.messageIndex.visibleMessageKeys("     ❯ /handoff")
                == ["line:/handoff"])

        for kind in ["claude", "codex", "cursor", "", "unknown"] {
            let profile = AgentMessageJumpProfile.forAgentKind(kind)
            #expect(profile.policy == .neighborAppearance)
            #expect(
                profile.maximumPromptIndent
                    == AttachUserMessageIndex.maximumPromptIndent)
            let wiring = AgentMessageJumpWiring(profile: profile)
            #expect(wiring.messageIndex.visibleMessageKeys("     ❯ /handoff").isEmpty)
        }
    }

    @MainActor
    @Test func wiringForwardsTheJumpPolicy() {
        let sticky = AgentMessageJumpWiring(policy: .stickyPromptOvershoot)
        #expect(sticky.controller.policy == .stickyPromptOvershoot)
        let standard = AgentMessageJumpWiring()
        #expect(standard.controller.policy == .neighborAppearance)
    }

    @MainActor
    @Test func runJumpAbandonsBodyWhenResetBeforeStart() async {
        let wiring = AgentMessageJumpWiring()
        var bodyEntered = false
        wiring.runJump(.older) { _ in
            bodyEntered = true
        }
        // Reconnect wins the main-actor queue before the Task body runs.
        wiring.resetSession()
        await Task.yield()
        await Task.yield()
        #expect(!bodyEntered)
        #expect(wiring.jumpInvocationCount == 0)
        #expect(!wiring.isJumpRunning)
    }

    @MainActor
    @Test func runJumpInvokesBodyWhenSessionStaysLive() async throws {
        let wiring = AgentMessageJumpWiring()
        var bodyEntered = false
        wiring.runJump(.newer) { session in
            #expect(wiring.isLive(session))
            #expect(wiring.isJumpRunning)
            #expect(wiring.runningDirection == .newer)
            bodyEntered = true
        }
        try await waitUntil("the live jump should run and finish") {
            bodyEntered && wiring.jumpInvocationCount == 1
                && !wiring.isJumpRunning && wiring.runningDirection == nil
        }
    }

    /// The wiring's Down press folds movement from *both* legs into reach:
    /// a newer walk that finds nothing but does move, followed by a return
    /// to live, still counts as having moved. `refs #268`.
    @MainActor
    @Test func wiringReachFollowsJumpOutcomes() async {
        let wiring = AgentMessageJumpWiring()
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        wiring.scrollControl.terminal = terminal
        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1000;1006h".utf8))
        #expect(wiring.reach == MessageJumpReach())

        // Nothing ever repaints: an older walk reaches the end without moving.
        let session = wiring.liveGeneration
        let older = await wiring.jumpOlder(in: session)
        #expect(older == .reachedEnd)
        #expect(!wiring.reach.canJumpOlder)
        #expect(!wiring.reach.canJumpNewer)

        wiring.resetSession()
        #expect(wiring.reach == MessageJumpReach())
    }

    @MainActor
    @Test func wiringLearnsDisplacementFromTouchScrolls() {
        let wiring = AgentMessageJumpWiring()
        let terminal = TerminalScreenView.makeConfiguredTerminal(onScroll: { _, _ in })
        wiring.scrollControl.terminal = terminal

        // Primary screen: local scrollback, not a remote position change.
        _ = terminal.scrollTouch(translationY: 40)
        #expect(!wiring.reach.canJumpNewer)

        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1000;1006h".utf8))
        _ = terminal.scrollTouch(translationY: 40)
        #expect(wiring.reach.canJumpNewer)
    }

    /// A touch-driven row is fresh viewport intent. The production touch-scroll
    /// seam cancels the jump loop before it can emit another automatic step.
    /// `refs #268`.
    @MainActor
    @Test func touchScrollCancelsAnInFlightJump() async {
        let started = MessageJumpScrollProbe()
        let finished = MessageJumpScrollProbe()
        let wiring = AgentMessageJumpWiring()
        let terminal = TerminalScreenView.makeConfiguredTerminal(onScroll: { _, _ in
            started.record()
        })
        wiring.scrollControl.terminal = terminal
        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1000;1006h".utf8))

        var outcome: TerminalMessageJumpController.Outcome?
        wiring.runJump(.older) { session in
            outcome = await wiring.jumpOlder(in: session)
            finished.record()
        }
        await started.waitForFirstRecord()
        #expect(wiring.isJumpRunning)
        #expect(wiring.controller.isRunning)

        _ = terminal.scrollTouch(translationY: 40)
        await finished.waitForFirstRecord()

        #expect(outcome == .cancelled)
        #expect(!wiring.isJumpRunning)
        #expect(!wiring.controller.isRunning)
        #expect(wiring.runningDirection == nil)
    }

    @MainActor
    @Test func resetSessionAdvancesGeneration() {
        let wiring = AgentMessageJumpWiring()
        let first = wiring.liveGeneration
        wiring.resetSession()
        #expect(!wiring.isLive(first))
        #expect(wiring.isLive(wiring.liveGeneration))
    }

    @MainActor
    @Test func chromeContainerPassesThroughNonInteractiveAndDisabledHits() {
        let container = MessageJumpChromeContainer(
            frame: CGRect(x: 0, y: 0, width: 390, height: 720))
        let host = MessageJumpSizedHost()
        host.fixedSize = CGSize(width: 44, height: 80)
        let chrome = UIView(frame: CGRect(x: 0, y: 0, width: 44, height: 80))
        chrome.isUserInteractionEnabled = true
        let button = UIButton(type: .system)
        button.frame = CGRect(x: 0, y: 0, width: 44, height: 36)
        chrome.addSubview(button)
        host.addSubview(chrome)
        // Size the host so layoutSubviews does not collapse it.
        host.frame = CGRect(x: 0, y: 0, width: 44, height: 80)
        container.embed(host)
        container.layoutIfNeeded()

        #expect(!host.isHidden)
        #expect(container.hostedFrame != nil)

        let buttonPoint = container.convert(
            CGPoint(x: button.bounds.midX, y: button.bounds.midY),
            from: button)
        #expect(container.hitTest(buttonPoint, with: nil) === button)

        let paddingPoint = container.convert(CGPoint(x: 22, y: 60), from: chrome)
        #expect(container.hitTest(paddingPoint, with: nil) == nil)
        #expect(container.hitTest(CGPoint(x: 12, y: 12), with: nil) == nil)

        #expect(
            MessageJumpChromeContainer.isInteractive(button, stoppingAt: host))
        #expect(
            !MessageJumpChromeContainer.isInteractive(chrome, stoppingAt: host))

        // Disabled controls must not eat terminal drags.
        button.isEnabled = false
        #expect(container.hitTest(buttonPoint, with: nil) == nil)
        #expect(
            !MessageJumpChromeContainer.isInteractive(button, stoppingAt: host))
    }

    /// SwiftUI does not back a `Button` with its own `UIView`; a hosting view
    /// answers for its whole interactive area and its gesture recognizers run
    /// the action. Rejecting a hit that is the hosted root left the buttons
    /// reachable by VoiceOver but by no actual touch. `refs #268`.
    @MainActor
    @Test func aGestureBackedHostedRootIsInteractive() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 44, height: 80))

        // An inert container still passes terminal drags through.
        #expect(!MessageJumpChromeContainer.isInteractive(host, stoppingAt: host))

        host.addGestureRecognizer(UITapGestureRecognizer())
        #expect(MessageJumpChromeContainer.isInteractive(host, stoppingAt: host))
    }

    @Test func availabilityDisabledMeansOverlayShouldNotHitTest() {
        let walking = MessageJumpControlAvailability.evaluate(
            isAlternateScreen: true,
            canScrollRemoteContent: true,
            runningJump: AttachRunningJump(kind: .message, direction: .older))
        #expect(walking.isVisible)
        // AgentTerminalView gates `.allowsHitTesting` on isEnabled, not
        // isVisible — this pins the policy the overlay relies on.
        #expect(walking.isEnabled == false)
    }
}

/// Jump walks over captured harness screens (`HarnessJumpCaptures`), with
/// the user turns learned from the Agent's transcript.
@MainActor
struct MessageJumpTranscriptWalkTests {
    /// Pi draws no prompt glyph: its user turns, typed on the Host, are
    /// plain text on a background colour. Up from live passes the reply and
    /// lands on the earlier turn its transcript names.
    @Test func upStopsAtAPiTurnTypedOnTheHost() async throws {
        let wiring = AgentMessageJumpWiring(profile: .forAgentKind("pi")) {
            HarnessJumpCaptures.piTranscript
        }
        let rows = HarnessJumpCaptures.piRows
        let conversation = ScriptedConversation(
            wiring: wiring, history: rows, height: 20, top: rows.count - 20)
        wiring.refreshTranscript()
        try await waitUntil("the transcript should name the turn on screen") {
            wiring.messageIndex.visibleMessageKeys(conversation.frame) == ["transcript:2748e3ed"]
        }

        let outcome = await wiring.jumpOlder(in: wiring.liveGeneration)

        #expect(outcome == .found)
        #expect(conversation.top == 0)
        #expect(conversation.frame.hasPrefix(rows[0]))
    }

    /// omp sets its user turn at column 1 like its reply; the walk still
    /// stops only where a turn begins.
    @Test func upStopsAtAnOmpTurnTypedOnTheHost() async throws {
        let wiring = AgentMessageJumpWiring(profile: .forAgentKind("omp")) {
            HarnessJumpCaptures.ompTranscript
        }
        // The message area, banner and editor left out.
        let rows = Array(HarnessJumpCaptures.ompRows[9..<35])
        let conversation = ScriptedConversation(
            wiring: wiring, history: rows, height: 12, top: rows.count - 12)
        wiring.refreshTranscript()
        try await waitUntil("the transcript should name the turn on screen") {
            wiring.messageIndex.visibleMessageKeys(conversation.frame) == ["transcript:b7e5720f"]
        }

        let outcome = await wiring.jumpOlder(in: wiring.liveGeneration)

        #expect(outcome == .found)
        #expect(
            wiring.messageIndex.visibleMessageKeys(conversation.frame)
                .contains("transcript:512f6c9a"))
    }

    /// OpenCode's error panel is shaped like a user cell. With its
    /// transcript known, Down stops on the user cell and then passes the
    /// panel on to live.
    @Test func downPassesOpenCodesErrorPanel() async throws {
        let wiring = AgentMessageJumpWiring(profile: .forAgentKind("opencode")) {
            HarnessJumpCaptures.openCodeTranscript
        }
        let conversation = Self.openCodeConversation(wiring)
        wiring.refreshTranscript()
        try await waitUntil("the transcript should name the turn on screen") {
            wiring.messageIndex.visibleMessageKeys(conversation.frame)
                == ["transcript:msg_12c4194be001gLVjnlnf3ByT1T"]
        }

        #expect(await wiring.jumpNewerOrLive(in: wiring.liveGeneration) == .found)
        #expect(conversation.frame.contains("Give one fun fact about starfish"))
        #expect(!conversation.frame.contains("Unauthorized"))

        #expect(await wiring.jumpNewerOrLive(in: wiring.liveGeneration) == .reachedEnd)
        #expect(conversation.isAtBottom)
    }

    /// OpenCode's "message reverted" banner after `/undo` is shaped like a
    /// user cell too. Down stops on the next user cell, then passes the
    /// banner on to live.
    @Test func downPassesOpenCodesRevertBanner() async throws {
        let wiring = AgentMessageJumpWiring(profile: .forAgentKind("opencode")) {
            HarnessJumpCaptures.openCodeTranscript
        }
        let rows = HarnessJumpCaptures.openCodeRevertRows
        let conversation = ScriptedConversation(
            wiring: wiring, history: Array(rows[..<40]), pinned: Array(rows[40...]),
            height: 16, top: 0)
        wiring.refreshTranscript()
        try await waitUntil("the transcript should name the turn on screen") {
            wiring.messageIndex.visibleMessageKeys(conversation.frame)
                .contains("transcript:msg_12c40a78a001QUeVzI7qvHwRYn")
        }

        #expect(await wiring.jumpNewerOrLive(in: wiring.liveGeneration) == .found)
        #expect(conversation.frame.contains("Now list three facts about sea urchins"))

        #expect(await wiring.jumpNewerOrLive(in: wiring.liveGeneration) == .reachedEnd)
        #expect(conversation.isAtBottom)
        #expect(conversation.frame.contains("1 message reverted"))
    }

    enum ReadFailure: CaseIterable, Sendable {
        /// No plugin on the Host, or no transcript.
        case fails
        /// A read still out when the user presses.
        case hangs
    }

    /// Without a transcript the walk runs on what the screen shows, as it
    /// always did: the user cell is a stop, and so is the error panel. A
    /// read that never answers holds nothing up.
    @Test(arguments: ReadFailure.allCases)
    func withoutATranscriptOpenCodeCellsStopByTheirShape(_ failure: ReadFailure) async throws {
        let reads = ReadCount()
        let wiring = AgentMessageJumpWiring(profile: .forAgentKind("opencode")) {
            reads.value += 1
            switch failure {
            case .fails: throw ChatTranscriptError.readerUnavailable
            case .hangs: try await Task.sleep(for: .seconds(3600))
            }
            return HarnessJumpCaptures.openCodeTranscript
        }
        let conversation = Self.openCodeConversation(wiring)
        wiring.refreshTranscript()
        try await waitUntil("the read should have started") { reads.value == 1 }

        #expect(await wiring.jumpNewerOrLive(in: wiring.liveGeneration) == .found)
        #expect(conversation.frame.contains("Give one fun fact about starfish"))
        #expect(await wiring.jumpNewerOrLive(in: wiring.liveGeneration) == .found)
        #expect(conversation.frame.contains("Unauthorized"))

        wiring.resetSession()
    }

    /// Claude's transcript is read and handed on, but its walk stays the
    /// screen's: a user turn the transcript names on a row with no prompt
    /// glyph is no stop, and the walk lands on the glyph as before.
    @Test func claudeSharesItsTranscriptAndStillWalksByItsPromptGlyph() async throws {
        let transcript = HarnessJumpCaptures.transcript(
            kind: "claude", messages: [("c1", .user, "checked file 3 of the parser suite")])
        let wiring = AgentMessageJumpWiring(profile: .forAgentKind("claude")) { transcript }
        let delivered = TranscriptLog()
        wiring.onTranscript = { delivered.snapshots.append($0) }
        let filler = (1...12).map { "  ⎿  checked file \($0) of the parser suite" }
        let rows =
            ["> fix the failing parser tests please", "⏺ Fixed both failures."]
            + filler
            + ["> now add a regression test for it", "⏺ Added one."]
        let conversation = ScriptedConversation(
            wiring: wiring, history: rows, height: 6, top: rows.count - 6)
        wiring.refreshTranscript()
        try await waitUntil("the read should reach its subscriber") {
            delivered.snapshots == [transcript]
        }

        let outcome = await wiring.jumpOlder(in: wiring.liveGeneration)

        #expect(outcome == .found)
        #expect(conversation.frame.contains("> fix the failing parser tests please"))
    }

    /// After the Agent switched sessions, a complete transcript of the old
    /// conversation vetoes every OpenCode cell on screen; the read the
    /// session change asks for brings them back as stops.
    @Test func aReadOfTheNewSessionRestoresItsCells() async throws {
        let otherConversation = HarnessJumpCaptures.transcript(
            kind: "opencode", messages: [("old", .user, "Summarise the release notes for me")])
        let reads = TranscriptQueue([otherConversation, HarnessJumpCaptures.openCodeTranscript])
        let wiring = AgentMessageJumpWiring(profile: .forAgentKind("opencode")) { reads.next() }
        let frame = HarnessJumpCaptures.openCodeErrorRows.joined(separator: "\n")

        wiring.refreshTranscript()
        try await waitUntil("the old conversation's read should land") { reads.served == 1 }
        #expect(wiring.messageIndex.visibleMessageKeys(frame).isEmpty)

        wiring.refreshTranscript()
        try await waitUntil("the new session's read should name its cells") {
            wiring.messageIndex.visibleMessageKeys(frame) == [
                "transcript:msg_12c4194be001gLVjnlnf3ByT1T",
                "transcript:msg_12c426e39001Coup7CbHAQjydF",
            ]
        }
    }

    /// Two Pi turns, the older one the opening of the newer
    /// (`Run the tests please`, `… and then fix the failures`): Up from the
    /// newer turn stops at the older one.
    @Test func upStopsAtAnOlderPiTurnThatOpensTheNewerOne() async throws {
        let transcript = HarnessJumpCaptures.transcript(
            kind: "pi",
            messages: [
                ("u1", .user, "Run the tests please"),
                ("u2", .user, "Run the tests please and then fix the failures"),
            ])
        let wiring = AgentMessageJumpWiring(profile: .forAgentKind("pi")) { transcript }
        let reply = (1...10).map { " Ran suite \($0) of the parser tests; all passed." }
        let rows =
            ["     Run the tests please"] + reply
            + ["", "     Run the tests please and then fix the failures"] + reply
        let conversation = ScriptedConversation(
            wiring: wiring, history: rows, height: 8, top: rows.count - 8)
        wiring.refreshTranscript()
        try await waitUntil("the transcript should name the turn on screen") {
            wiring.messageIndex.visibleMessageKeys(
                Array(rows[12...]).joined(separator: "\n")) == ["transcript:u2"]
        }

        #expect(await wiring.jumpOlder(in: wiring.liveGeneration) == .found)
        #expect(conversation.frame.contains("Run the tests please and then fix"))
        #expect(await wiring.jumpOlder(in: wiring.liveGeneration) == .found)
        #expect(conversation.top == 0)
    }

    /// A kind the Host's reader does not understand costs no read.
    @Test(arguments: ["kimi", "devin", "cursor"])
    func kindsWithoutATranscriptReaderReadNothing(_ kind: String) async throws {
        let reads = ReadCount()
        let wiring = AgentMessageJumpWiring(profile: .forAgentKind(kind)) {
            reads.value += 1
            return HarnessJumpCaptures.piTranscript
        }
        wiring.refreshTranscript()
        try await Task.sleep(for: .milliseconds(50))
        #expect(reads.value == 0)
    }

    /// OpenCode's message list in a 16-row window above its input box,
    /// opening on the second user cell.
    private static func openCodeConversation(
        _ wiring: AgentMessageJumpWiring
    ) -> ScriptedConversation {
        let rows = HarnessJumpCaptures.openCodeErrorRows
        return ScriptedConversation(
            wiring: wiring, history: Array(rows[..<41]), pinned: Array(rows[41...]),
            height: 16, top: 0)
    }

    private func waitUntil(
        _ comment: Comment, timeout: Duration = .waitCeiling,
        condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition(), comment)
    }
}

@MainActor
private final class ReadCount {
    var value = 0
}

@MainActor
private final class TranscriptLog {
    var snapshots: [ChatTranscriptSnapshot] = []
}

/// Answers each transcript read with the next snapshot, repeating the last.
@MainActor
private final class TranscriptQueue {
    private let snapshots: [ChatTranscriptSnapshot]
    private(set) var served = 0

    init(_ snapshots: [ChatTranscriptSnapshot]) {
        self.snapshots = snapshots
    }

    func next() -> ChatTranscriptSnapshot {
        defer { served += 1 }
        return snapshots[min(served, snapshots.count - 1)]
    }
}

/// An agent TUI's history as the remote viewport shows it: a window of
/// `height` rows over `history` (oldest first), with `pinned` rows (an
/// input box) below every window. Each wheel report moves the window the
/// rows it asked for and repaints, as `herdr terminal attach` does.
@MainActor
private final class ScriptedConversation {
    private let wiring: AgentMessageJumpWiring
    private let history: [String]
    private let pinned: [String]
    private let height: Int
    private(set) var top: Int
    private var terminal: WaycarTerminalView?

    init(
        wiring: AgentMessageJumpWiring, history: [String], pinned: [String] = [],
        height: Int, top: Int
    ) {
        self.wiring = wiring
        self.history = history
        self.pinned = pinned
        self.height = height
        self.top = top
        let terminal = TerminalScreenView.makeConfiguredTerminal(onScroll: { [weak self] sequence, rows in
            self?.scroll(sequence, rows: rows)
        })
        wiring.scrollControl.terminal = terminal
        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1000;1006h".utf8))
        self.terminal = terminal
        wiring.deliverViewportText(frame)
    }

    var frame: String {
        (history[top..<(top + height)] + pinned).joined(separator: "\n")
    }

    var isAtBottom: Bool { top == history.count - height }

    private func scroll(_ sequence: Data, rows: Int) {
        // SGR wheel reports: button 64 scrolls back, 65 forward.
        if sequence.starts(with: Data("\u{1B}[<64;".utf8)) {
            top = max(0, top - rows)
        } else {
            top = min(history.count - height, top + rows)
        }
        wiring.deliverViewportText(frame)
    }
}

@MainActor
private final class MessageJumpScrollProbe {
    private var recordCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record() {
        recordCount += 1
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func waitForFirstRecord() async {
        if recordCount > 0 { return }
        await withCheckedContinuation { continuation in
            if self.recordCount > 0 {
                continuation.resume()
            } else {
                self.waiters.append(continuation)
            }
        }
    }
}

@MainActor
struct TerminalScrollControlTests {
    @Test func scrollRowsEmitsRemoteWheelOnAlternateScreenWithMouseTracking() {
        var scrolledSequence = Data()
        var scrolledRows = 0
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onScroll: { sequence, rows in
                scrolledSequence = sequence
                scrolledRows = rows
            })
        let control = TerminalScrollControl()
        control.terminal = terminal

        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1000;1006h".utf8))
        #expect(control.isAlternateScreen)

        control.scrollRows(towardOlderContent: true, rows: 6)
        #expect(scrolledSequence == Data("\u{1B}[<64;40;12M".utf8))
        #expect(scrolledRows == 6)

        scrolledSequence = Data()
        scrolledRows = 0
        control.scrollRows(towardOlderContent: false, rows: 3)
        #expect(scrolledSequence == Data("\u{1B}[<65;40;12M".utf8))
        #expect(scrolledRows == 3)
    }

    @Test func scrollRowsEmitsCursorKeysUnderAlternateScrollWithoutMouseTracking() {
        var scrolledSequence = Data()
        var scrolledRows = 0
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onScroll: { sequence, rows in
                scrolledSequence = sequence
                scrolledRows = rows
            })
        let control = TerminalScrollControl()
        control.terminal = terminal

        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1007h".utf8))
        control.scrollRows(towardOlderContent: true, rows: 2)
        #expect(scrolledSequence == Data([0x1B, 0x5B, 0x41]))
        #expect(scrolledRows == 2)
        // Keys are no proof the view moves (codex recalls history on them):
        // no chrome.
        #expect(!control.canScrollRemoteContent)

        scrolledSequence = Data()
        control.scrollRows(towardOlderContent: false, rows: 2)
        #expect(scrolledSequence == Data([0x1B, 0x5B, 0x42]))
    }

    /// An alternate-screen client with neither mouse reporting nor
    /// alternate scroll (a tmux attach to codex or to an inline agent): no
    /// key reaches the pane, where it would recall history.
    @Test func scrollRowsSendsNothingRemoteOnAlternateScreenWithoutMouseOrAlternateScroll() {
        var scrollCalls = 0
        var bindingActions: [String] = []
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onScroll: { _, _ in scrollCalls += 1 })
        terminal.didPerformBindingAction = { bindingActions.append($0) }
        let control = TerminalScrollControl()
        control.terminal = terminal

        terminal.receive(Data("\u{1B}[?1049h".utf8))
        control.scrollRows(towardOlderContent: true, rows: 2)
        #expect(scrollCalls == 0)
        #expect(bindingActions == ["scroll_page_lines:-2"])
    }

    @Test func scrollRowsTakesLocalBranchOnPrimaryScreen() {
        var scrollCalls = 0
        var bindingActions: [String] = []
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onScroll: { _, _ in scrollCalls += 1 })
        terminal.didPerformBindingAction = { bindingActions.append($0) }
        let control = TerminalScrollControl()
        control.terminal = terminal

        #expect(!control.isAlternateScreen)
        control.scrollRows(towardOlderContent: true, rows: 4)
        #expect(scrollCalls == 0)
        #expect(bindingActions == ["scroll_page_lines:-4"])

        bindingActions.removeAll()
        control.scrollRows(towardOlderContent: false, rows: 2)
        #expect(bindingActions == ["scroll_page_lines:2"])
    }

    @Test func scrollRowsLeavesTheTouchAccumulatorAlone() {
        var scrolledRows = 0
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onScroll: { _, rows in scrolledRows += rows })
        let control = TerminalScrollControl()
        control.terminal = terminal
        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1000;1006h".utf8))

        #expect(terminal.scrollTouch(translationY: 8) == 0)
        control.scrollRows(towardOlderContent: true, rows: 2)
        #expect(scrolledRows == 2)
        scrolledRows = 0
        #expect(terminal.scrollTouch(translationY: 8) == 1)
        #expect(scrolledRows == 1)
    }

    @Test func isAlternateScreenSyncsFromTheSurfaceAndClearsOnRelease() {
        let control = TerminalScrollControl()
        #expect(!control.isAlternateScreen)

        let terminal = TerminalScreenView.makeConfiguredTerminal()
        control.terminal = terminal
        #expect(!control.isAlternateScreen)

        terminal.receive(Data("\u{1B}[?1049h".utf8))
        #expect(control.isAlternateScreen)

        terminal.receive(Data("\u{1B}[?1049l".utf8))
        #expect(!control.isAlternateScreen)

        terminal.receive(Data("\u{1B}[?1049h".utf8))
        #expect(control.isAlternateScreen)
        control.terminal = nil
        #expect(!control.isAlternateScreen)
    }
}

@MainActor
struct MessageJumpAgentTerminalWiringTests {
    @Test func agentTerminalViewportFeedsTheJumpController() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            throw TransportError.cancelled
        }
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let interactions = AgentTerminalInteractionProbe()

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner,
                composer: composer,
                interactionProbe: interactions))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
                && interactions.isConnected
        })

        let terminal = try #require(Self.terminals(in: controller.view).first)
        terminal.receive(
            Data("\u{001B}[2J\u{001B}[Hhttps://msgnav.example/viewport\n".utf8))
        terminal.layoutIfNeeded()

        try #require(await Self.eventually {
            interactions.messageJumpViewportFrames.contains {
                $0.contains("https://msgnav.example/viewport")
            }
                && interactions.lastMessageJumpViewportFrame?
                .contains("https://msgnav.example/viewport") == true
        })
    }

    @Test func interactionProbeJumpActionsAreConnectedOnAppear() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            throw TransportError.cancelled
        }
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let interactions = AgentTerminalInteractionProbe()

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner,
                composer: composer,
                interactionProbe: interactions))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually { interactions.isConnected })

        // Probe closures are wired on appear. Without alternate-screen /
        // enabled chrome the actions no-op at the availability guard — the
        // probe still reports the closures were reached.
        #expect(interactions.jumpOlderMessage())
        #expect(interactions.jumpNewerMessage())
    }

    /// SwiftUI runs the Agent view's init again on every parent re-render
    /// (each status change) and keeps the first one's state. The pane
    /// history the surface scrolls must stay the one typed input waits on
    /// and the one the departure leaves: the Attach's own.
    @Test func tmuxPaneHistoryStaysTheAttachsAcrossViewRebuilds() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "tmux:%3") { _ in
            throw TransportError.cancelled
        }
        let host = TmuxPaneHistoryTests.Host()
        let owner = try await Self.makeLiveAttach(
            transport: transport, composer: composer, paneHistory: host.history())
        let history = try #require(owner.paneHistory)
        let console = Self.makeConsole()
        let interactions = AgentTerminalInteractionProbe()
        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner, composer: composer, interactionProbe: interactions,
                console: console, backend: .tmux))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually {
            interactions.isConnected && history.position == .live
        })
        // A parent re-render: the same Attach, a new view value, twice.
        for _ in 0..<2 {
            controller.rootView = Self.makeDetailView(
                attachStore: owner, composer: composer, interactionProbe: interactions,
                console: console, backend: .tmux)
            controller.view.layoutIfNeeded()
        }

        let surface = try #require(Self.terminals(in: controller.view).first)
        #expect(surface.paneHistory === history)
        surface.scrollRows(towardOlderContent: true, rows: 4)
        try #require(await Self.eventually { history.position == .inHistory && !history.isMoving })
        #expect(host.scrolls.last?.rows == 4)

        // Typed input waits for copy mode to end.
        #expect(owner.input.send(Data("a".utf8)))
        try #require(await Self.eventually {
            await transport.attachInputs.contains(.keystrokes(Data("a".utf8)))
        })
        #expect(host.leaves == 1)

        // Leaving the Attach leaves the copy mode its scroll entered.
        surface.scrollRows(towardOlderContent: true, rows: 4)
        try #require(await Self.eventually { history.position == .inHistory && !history.isMoving })
        await owner.leave().value
        #expect(try await Self.eventually { host.leaves == 2 })
    }

    private static func makeLiveAttach(
        transport: ScriptedTransport,
        composer: AgentComposerStore,
        paneHistory: TmuxPaneHistory? = nil
    ) async throws -> AgentAttachStore {
        let owner = AgentAttachStore(
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
            paneHistory: paneHistory,
            closePane: {})
        owner.viewDidResize(cols: 80, rows: 24)
        try #require(await Self.eventually {
            await transport.attachRequests.count == 1
        })
        #expect(await transport.emitAttachOutput(Data("live".utf8)))
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })
        return owner
    }

    private static func makeConsole() -> ConsoleStore {
        ConsoleStore(snapshotRetryDelay: .seconds(30)) { _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { throw TransportError.sshUnreachable(detail: "fixture") },
                reconnectPolicy: .default,
                keepalive: .default)
        }
    }

    private static func makeDetailView(
        attachStore: AgentAttachStore,
        composer: AgentComposerStore,
        interactionProbe: AgentTerminalInteractionProbe,
        console: ConsoleStore? = nil,
        backend: HostBackend = .herdr
    ) -> AgentTerminalView {
        let console = console ?? makeConsole()
        let defaults = UserDefaults(suiteName: "msgnav-detail-\(UUID())") ?? .standard
        let terminal = TerminalSettings(
            themes: TerminalThemeSettings(defaults: defaults),
            zoom: TerminalZoomSettings(defaults: defaults),
            fonts: TerminalFontSettings(defaults: defaults),
            snippets: SnippetStore(defaults: defaults),
            toolbars: AgentToolbarLayoutStore(defaults: defaults, idiom: .phone))
        return AgentTerminalView(
            agent: ConsoleAgent(
                hostID: UUID(),
                hostName: "devbox",
                agent: Agent(
                    terminalID: "term_w1:p1", kind: "claude", title: "",
                    status: .idle, workspaceID: "w", tabID: "w:t", paneID: "w1:p1",
                    cwd: "/work", revision: 1, name: nil),
                workspaceLabel: nil,
                repositoryCheckout: nil,
                backend: backend),
            console: console,
            terminal: terminal,
            hosts: [],
            activity: AppActivityCoordinator(),
            keyboardHandoff: TerminalKeyboardHandoff(),
            keyboardInset: TerminalKeyboardInset(),
            isOnStage: { true },
            onSwitch: { _ in },
            onClosed: {},
            composer: composer,
            attachStore: attachStore,
            interactionProbe: interactionProbe)
    }

    private static func terminals(in root: UIView) -> [WaycarTerminalView] {
        var found: [WaycarTerminalView] = []
        func walk(_ view: UIView) {
            if let terminal = view as? WaycarTerminalView {
                found.append(terminal)
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    private static func eventually(
        timeout: Duration = .waitCeiling,
        _ condition: @escaping () async -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}
