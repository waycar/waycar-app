import Foundation
import Observation
import Testing
import UIKit

@testable import Waycar

/// Owner pins for the keyboard inset (ATTACH-13): presentation coalescing,
/// the dismissal it owes across a responder handoff, the missed-frame
/// reconciliation, and what the window measurements and fallbacks see of
/// the inset while they run. Existing API only.
@MainActor
@Suite("Terminal keyboard inset lifecycle")
struct TerminalKeyboardInsetLifecycleTests {
    /// Counts every change of `inset.height`, re-arming after each one.
    @MainActor
    private final class HeightChanges {
        private(set) var count = 0
        private let inset: TerminalKeyboardInset

        init(_ inset: TerminalKeyboardInset) {
            self.inset = inset
            track()
        }

        private func track() {
            withObservationTracking {
                _ = inset.height
            } onChange: { [weak self] in
                Task { @MainActor in
                    self?.count += 1
                    self?.track()
                }
            }
        }
    }

    private static func frame(height: CGFloat) -> CGRect {
        CGRect(x: 0, y: 874 - height, width: 402, height: height)
    }

    private static func post(
        _ name: Notification.Name, height: CGFloat, on center: NotificationCenter
    ) {
        center.post(
            name: name, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: frame(height: height)])
    }

    /// The measurement is the frame's height in these tests, and a frame
    /// starting at the window's bottom edge (874) covers none of it.
    private static func makeInset(
        center: NotificationCenter,
        windowKeyboard: @escaping @MainActor () -> CGFloat? = { nil }
    ) -> TerminalKeyboardInset {
        let inset = TerminalKeyboardInset(
            notificationCenter: center, measure: { $0.minY >= 874 ? 0 : $0.height },
            measureWindowKeyboard: windowKeyboard)
        inset.dismissalConfirmationDelay = .seconds(60)
        inset.responderHandoffFallbackDelay = .seconds(60)
        inset.destinationResponderHandoffFallbackDelay = .seconds(60)
        return inset
    }

    @Test func aFollowUpFrameInsideTheCoalesceWindowReplacesThePendingHeight() async throws {
        let center = NotificationCenter()
        let inset = Self.makeInset(center: center)
        let changes = HeightChanges(inset)
        Self.post(UIResponder.keyboardWillShowNotification, height: 300, on: center)
        Self.post(UIResponder.keyboardWillChangeFrameNotification, height: 350, on: center)
        #expect(inset.height == 0)

        try await waitUntil { inset.height == 350 }
        #expect(inset.lastPresentedHeight == 350)
        try await waitUntil { changes.count == 1 }
        // A later frame is the positive signal that the first pending
        // height, armed earlier, would have landed by now.
        Self.post(UIResponder.keyboardWillChangeFrameNotification, height: 360, on: center)
        try await waitUntil { inset.height == 360 }
        try await waitUntil { changes.count == 2 }
        #expect(changes.count == 2)
    }

    /// A frame that covers none of the window does not cancel the pending
    /// presentation; a keyboard-sized one marks the presentation missed, so
    /// the did-show still settles against the window afterwards.
    @Test(arguments: [CGFloat(0), 403])
    func aFrameCoveringNothingLeavesThePendingPresentationArmed(
        droppedHeight: CGFloat
    ) async throws {
        let center = NotificationCenter()
        let inset = Self.makeInset(center: center, windowKeyboard: { 200 })
        Self.post(UIResponder.keyboardWillShowNotification, height: 300, on: center)
        center.post(
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 874, width: 402, height: droppedHeight)])
        try await waitUntil { inset.height == 300 }

        center.post(name: UIResponder.keyboardDidShowNotification, object: nil)
        #expect(inset.height == (droppedHeight > 0 ? 200 : 300))
        #expect(!inset.isConfirmingDismissal)
        // Reconciled once: a second did-show changes nothing.
        center.post(name: UIResponder.keyboardDidShowNotification, object: nil)
        #expect(inset.height == (droppedHeight > 0 ? 200 : 300))
    }

    /// Pausing capture drops a presentation still waiting to coalesce.
    @Test func pausingCaptureDropsThePendingPresentation() async throws {
        let center = NotificationCenter()
        let inset = Self.makeInset(center: center)
        let changes = HeightChanges(inset)
        Self.post(UIResponder.keyboardWillShowNotification, height: 300, on: center)
        inset.pauseHeightCapture()
        Self.post(UIResponder.keyboardWillChangeFrameNotification, height: 310, on: center)
        inset.resumeHeightCapture()
        Self.post(UIResponder.keyboardWillChangeFrameNotification, height: 350, on: center)

        try await waitUntil { inset.height == 350 }
        try await waitUntil { changes.count == 1 }
        #expect(inset.lastPresentedHeight == 350)
    }

    /// A hide drops a pending presentation before it lands, and the
    /// confirmation it starts sees the zero height.
    @Test func aHideDropsThePendingPresentation() async throws {
        let center = NotificationCenter()
        let inset = Self.makeInset(center: center)
        inset.dismissalConfirmationDelay = .milliseconds(200)
        let changes = HeightChanges(inset)
        Self.post(UIResponder.keyboardWillShowNotification, height: 300, on: center)
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.isConfirmingDismissal)

        // The confirmation outlasts the coalesce delay and requires a zero
        // height: had the pending presentation landed, it never confirms.
        try await waitUntil { inset.isSoftwareKeyboardDismissed }
        #expect(inset.height == 0)
        #expect(inset.lastPresentedHeight == 0)
        #expect(changes.count == 0)
    }

    /// Beginning a handoff drops a pending presentation; frames inside the
    /// freeze are ignored, and the first one after it lands.
    @Test(arguments: ["owner", "destination"])
    func aHandoffDropsThePendingPresentation(kind: String) async throws {
        let center = NotificationCenter()
        let inset = Self.makeInset(center: center)
        let changes = HeightChanges(inset)
        Self.post(UIResponder.keyboardWillShowNotification, height: 300, on: center)
        let id = kind == "owner"
            ? inset.beginResponderHandoff()
            : inset.beginDestinationOwnedResponderHandoff()
        Self.post(UIResponder.keyboardWillChangeFrameNotification, height: 310, on: center)
        center.post(name: UIResponder.keyboardDidShowNotification, object: nil)
        inset.endResponderHandoff(id, currentHeight: { nil })
        #expect(!inset.isHoldingHandoffHeight)
        #expect(inset.height == 0)

        Self.post(UIResponder.keyboardWillChangeFrameNotification, height: 350, on: center)
        try await waitUntil { inset.height == 350 }
        try await waitUntil { changes.count == 1 }
        #expect(inset.lastPresentedHeight == 350)
    }

    /// Every exit measures the window only after the freeze is released, and
    /// the owner's fallback callback runs after the exit has reconciled.
    @Test(arguments: ["end", "cancel", "ownerFallback", "destinationFallback"])
    func handoffExitsMeasureAfterReleasingTheFreeze(exit: String) async throws {
        let center = NotificationCenter()
        let inset = Self.makeInset(center: center)
        Self.post(UIResponder.keyboardWillShowNotification, height: 300, on: center)
        try await waitUntil { inset.height == 300 }
        if exit == "ownerFallback" { inset.responderHandoffFallbackDelay = .milliseconds(20) }
        if exit == "destinationFallback" {
            inset.destinationResponderHandoffFallbackDelay = .milliseconds(20)
        }
        var heldWhileMeasuring: [Bool] = []
        var heightAtFallback: CGFloat?
        var heldAtFallback: Bool?
        let measure: @MainActor () -> CGFloat? = {
            heldWhileMeasuring.append(inset.isHoldingHandoffHeight)
            return 0
        }
        let fallback: @MainActor (UUID) -> Void = { _ in
            heightAtFallback = inset.height
            heldAtFallback = inset.isHoldingHandoffHeight
        }
        let id = exit == "destinationFallback" || exit == "end"
            ? inset.beginDestinationOwnedResponderHandoff(
                currentHeight: measure, onFallback: fallback)
            : inset.beginResponderHandoff(currentHeight: measure, onFallback: fallback)
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.height == 300)

        switch exit {
        case "end": inset.endResponderHandoff(id, currentHeight: measure)
        case "cancel": inset.cancelResponderHandoff(id, currentHeight: measure)
        default: try await waitUntil { heldAtFallback != nil }
        }

        #expect(heldWhileMeasuring == [false])
        #expect(!inset.isHoldingHandoffHeight)
        #expect(inset.height == 0)
        #expect(inset.isConfirmingDismissal)
        if exit.hasSuffix("Fallback") {
            #expect(heightAtFallback == 0)
            #expect(heldAtFallback == false)
        }
    }

    /// The owner-side fallback reads a missing measurement as a dismissed
    /// keyboard when a dismissal is owed; the destination watchdog keeps the
    /// frozen height instead.
    @Test(arguments: ["owner", "destination"])
    func anOwedDismissalWithoutAMeasurementDependsOnTheFallback(kind: String) async throws {
        let center = NotificationCenter()
        let inset = Self.makeInset(center: center)
        Self.post(UIResponder.keyboardWillShowNotification, height: 300, on: center)
        try await waitUntil { inset.height == 300 }
        inset.responderHandoffFallbackDelay = .milliseconds(20)
        inset.destinationResponderHandoffFallbackDelay = .milliseconds(20)
        var expired: UUID?
        let id = kind == "owner"
            ? inset.beginResponderHandoff(currentHeight: { nil }) { expired = $0 }
            : inset.beginDestinationOwnedResponderHandoff(currentHeight: { nil }) { expired = $0 }
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        try await waitUntil { expired == id }

        #expect(!inset.isHoldingHandoffHeight)
        if kind == "owner" {
            #expect(inset.height == 0)
            #expect(inset.isConfirmingDismissal)
        } else {
            #expect(inset.height == 300)
            #expect(!inset.isConfirmingDismissal)
            #expect(!inset.isSoftwareKeyboardDismissed)
        }
    }

    /// A did-show inside a freeze or with capture paused leaves a missed
    /// presentation for the next did-show to reconcile.
    @Test(arguments: ["handoff", "paused"])
    func aMissedPresentationSurvivesAnIgnoredDidShow(blocker: String) async throws {
        let center = NotificationCenter()
        let inset = Self.makeInset(center: center, windowKeyboard: { 280 })
        // Keyboard-sized yet measuring zero: dropped and marked missed.
        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 874, width: 402, height: 403)])
        #expect(inset.height == 0)

        var id: UUID?
        if blocker == "handoff" {
            id = inset.beginDestinationOwnedResponderHandoff()
        } else {
            inset.pauseHeightCapture()
        }
        center.post(name: UIResponder.keyboardDidShowNotification, object: nil)
        #expect(inset.height == 0)
        if let id {
            // Nothing owed and nothing measured: the exit changes nothing.
            inset.endResponderHandoff(id, currentHeight: { nil })
        } else {
            inset.resumeHeightCapture()
        }
        #expect(inset.height == 0)

        center.post(name: UIResponder.keyboardDidShowNotification, object: nil)
        #expect(inset.height == 280)
        #expect(inset.lastPresentedHeight == 280)
        #expect(!inset.isConfirmingDismissal)
        #expect(!inset.isSoftwareKeyboardDismissed)
    }

    /// A confirmation running out inside a freeze becomes debt the exit
    /// settles, never a dismissal on its own; one running out with the
    /// keyboard measured up confirms nothing.
    @Test func aConfirmationRunningOutInsideAFreezeIsOwedToItsExit() async throws {
        let center = NotificationCenter()
        let inset = Self.makeInset(center: center)
        inset.dismissalConfirmationDelay = .milliseconds(20)
        let id = inset.beginDestinationOwnedResponderHandoff()
        inset.expectSoftwareKeyboard()
        #expect(inset.isConfirmingDismissal)
        try await waitUntil { !inset.isConfirmingDismissal }
        #expect(!inset.isSoftwareKeyboardDismissed)

        inset.endResponderHandoff(id, currentHeight: { 0 })
        #expect(inset.isConfirmingDismissal)
        try await waitUntil { inset.isSoftwareKeyboardDismissed }

        Self.post(UIResponder.keyboardWillShowNotification, height: 300, on: center)
        #expect(!inset.isSoftwareKeyboardDismissed)
        try await waitUntil { inset.height == 300 }
        inset.expectSoftwareKeyboard()
        try await waitUntil { !inset.isConfirmingDismissal }
        #expect(!inset.isSoftwareKeyboardDismissed)
        #expect(inset.height == 300)
    }
}
