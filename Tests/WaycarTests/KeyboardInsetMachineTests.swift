import CoreGraphics
import Foundation
import Testing

@testable import Waycar

@Suite("Keyboard inset machine")
struct KeyboardInsetMachineTests {
    typealias Machine = KeyboardInsetMachine
    private static let frame = CGRect(x: 0, y: 500, width: 400, height: 300)
    private static let handoff = UUID()

    /// A machine whose presentation of `height` has landed.
    private static func presented(_ height: CGFloat = 300) -> Machine {
        Machine().after([
            .willPresent(endFrame: frame),
            .presentationMeasured(frameHeight: 300, height: height),
            .coalesceElapsed(token: 1),
        ])
    }

    @Test func aPresentationIsMeasuredOnlyWhileItCanLand() {
        var machine = Machine()
        #expect(machine.handle(.willPresent(endFrame: nil)) == [])
        #expect(machine.handle(.willPresent(endFrame: Self.frame))
            == [.measurePresentation(endFrame: Self.frame)])
        _ = machine.handle(.pauseCapture)
        #expect(machine.handle(.willPresent(endFrame: Self.frame)) == [])
        _ = machine.handle(.resumeCapture)
        _ = machine.handle(.beginHandoff(id: Self.handoff, kind: .owner))
        #expect(machine.handle(.willPresent(endFrame: Self.frame)) == [])
    }

    @Test func aMeasuredPresentationCoalescesThenLands() {
        var machine = Machine()
        #expect(machine.handle(.presentationMeasured(frameHeight: 300, height: 280)) == [
            .cancelConfirmation, .publishSoftwareKeyboardDismissed(false),
            .cancelCoalesce, .armCoalesce(token: 1),
        ])
        #expect(machine.state.presentation == .coalescing(token: 1, height: 280))
        #expect(machine.handle(.presentationMeasured(frameHeight: 300, height: 290)).last
            == .armCoalesce(token: 2))
        #expect(machine.handle(.coalesceElapsed(token: 1)) == [])
        #expect(machine.handle(.coalesceElapsed(token: 2))
            == [.publishLastPresentedHeight(290), .publishHeight(290)])
        #expect(machine.state.presentation == .none)
        #expect(machine.handle(.coalesceElapsed(token: 2)) == [])
    }

    @Test func anUnchangedHeightRepublishesOnlyTheLastPresentedHeight() {
        var machine = Self.presented()
        _ = machine.handle(.presentationMeasured(frameHeight: 300, height: 300))
        #expect(machine.handle(.coalesceElapsed(token: 2)) == [.publishLastPresentedHeight(300)])
    }

    @Test func aFrameCoveringNothingMarksOnlyAKeyboardSizedOneMissed() {
        var machine = Machine().after([.presentationMeasured(frameHeight: 300, height: 280)])
        #expect(machine.handle(.presentationMeasured(frameHeight: 0, height: 0)) == [])
        #expect(!machine.state.missedPresentationFrame)
        #expect(machine.handle(.presentationMeasured(frameHeight: 403, height: 0)) == [])
        #expect(machine.state.missedPresentationFrame)
        #expect(machine.state.presentation == .coalescing(token: 1, height: 280))
        #expect(machine.handle(.presentationMeasured(frameHeight: 403, height: nil)) == [])
        #expect(machine.state.missedPresentationFrame)
    }

    @Test func aDidShowSettlesAMissedPresentationAgainstTheWindowOnce() {
        var machine = Machine().after([.presentationMeasured(frameHeight: 403, height: 0)])
        #expect(machine.handle(.didShow) == [.measureWindowKeyboard])
        #expect(!machine.state.missedPresentationFrame)
        #expect(machine.handle(.windowKeyboardMeasured(383)) == [
            .cancelCoalesce, .publishLastPresentedHeight(383), .publishHeight(383),
            .cancelConfirmation, .publishSoftwareKeyboardDismissed(false),
        ])
        #expect(machine.handle(.didShow) == [])
        // A zero or missing measurement settles nothing.
        var unmeasured = Machine().after([.presentationMeasured(frameHeight: 403, height: 0), .didShow])
        #expect(unmeasured.handle(.windowKeyboardMeasured(nil)) == [])
        #expect(unmeasured.handle(.windowKeyboardMeasured(0)) == [])
    }

    @Test func aDidShowInsideAFreezeOrPauseKeepsTheMiss() {
        var frozen = Machine().after([
            .presentationMeasured(frameHeight: 403, height: 0),
            .beginHandoff(id: Self.handoff, kind: .destination),
        ])
        #expect(frozen.handle(.didShow) == [])
        #expect(frozen.state.missedPresentationFrame)
        var paused = Machine().after([.presentationMeasured(frameHeight: 403, height: 0), .pauseCapture])
        #expect(paused.handle(.didShow) == [])
        #expect(paused.state.missedPresentationFrame)
    }

    @Test func aHideDropsThePresentationAndStartsAConfirmation() {
        var machine = Self.presented()
        #expect(machine.handle(.willDismiss) == [
            .cancelCoalesce, .publishHeight(0), .cancelConfirmation, .armConfirmation(token: 2),
        ])
        #expect(machine.isConfirmingDismissal)
        #expect(machine.state.lastPresentedHeight == 300)
        #expect(machine.handle(.confirmationElapsed(token: 1)) == [])
        #expect(machine.handle(.confirmationElapsed(token: 2)) == [.publishSoftwareKeyboardDismissed(true)])
        #expect(machine.state.isSoftwareKeyboardDismissed)
        #expect(!machine.isConfirmingDismissal)
    }

    @Test func aConfirmationWithTheKeyboardUpConfirmsNothing() {
        var machine = Self.presented().after([.expectSoftwareKeyboard])
        #expect(machine.isConfirmingDismissal)
        #expect(machine.handle(.confirmationElapsed(token: 2)) == [])
        #expect(!machine.isConfirmingDismissal)
        #expect(!machine.state.isSoftwareKeyboardDismissed)
    }

    @Test func expectingTheKeyboardClearsADismissalAndConfirmsAgain() {
        var machine = Machine().after([.willDismiss, .confirmationElapsed(token: 1)])
        #expect(machine.state.isSoftwareKeyboardDismissed)
        #expect(machine.handle(.expectSoftwareKeyboard) == [
            .publishSoftwareKeyboardDismissed(false), .cancelConfirmation, .armConfirmation(token: 2),
        ])
    }

    @Test func pausingDropsThePendingPresentation() {
        var machine = Machine().after([.presentationMeasured(frameHeight: 300, height: 280)])
        #expect(machine.handle(.pauseCapture) == [.cancelCoalesce])
        #expect(machine.state.presentation == .none)
        #expect(machine.handle(.coalesceElapsed(token: 1)) == [])
        #expect(machine.handle(.resumeCapture) == [])
        #expect(machine.state.capturesPresentedHeight)
    }

    @Test func aHandoffFreezesAndCarriesAnUnconfirmedHide() {
        var machine = Self.presented().after([.willDismiss])
        #expect(machine.handle(.beginHandoff(id: Self.handoff, kind: .owner)) == [
            .cancelCoalesce, .cancelHandoffFallback, .publishHandoffID(Self.handoff),
            .cancelConfirmation, .armHandoffFallback(token: 3, kind: .owner),
        ])
        #expect(machine.state.handoff == .holding(
            id: Self.handoff, fallback: 3, kind: .owner, owesDismissal: true))
        #expect(!machine.isConfirmingDismissal)
        #expect(machine.handoffID == Self.handoff)
    }

    @Test func aReplacingHandoffKeepsTheDebtItsPredecessorOwed() {
        let replacement = UUID()
        var machine = Self.presented().after([
            .beginHandoff(id: Self.handoff, kind: .owner), .willDismiss,
        ])
        _ = machine.handle(.beginHandoff(id: replacement, kind: .destination))
        #expect(machine.state.handoff == .holding(
            id: replacement, fallback: 3, kind: .destination, owesDismissal: true))
        var clean = Self.presented().after([.beginHandoff(id: Self.handoff, kind: .owner)])
        _ = clean.handle(.beginHandoff(id: replacement, kind: .owner))
        #expect(clean.state.handoff == .holding(
            id: replacement, fallback: 3, kind: .owner, owesDismissal: false))
    }

    @Test func hidesAndExpiringConfirmationsInsideAFreezeBecomeDebt() {
        var machine = Self.presented().after([.beginHandoff(id: Self.handoff, kind: .owner)])
        #expect(machine.handle(.willDismiss) == [])
        #expect(machine.state.height == 300)
        var expiring = Machine().after([
            .beginHandoff(id: Self.handoff, kind: .destination), .expectSoftwareKeyboard,
        ])
        #expect(expiring.handle(.confirmationElapsed(token: 2)) == [])
        #expect(expiring.state.handoff == .holding(
            id: Self.handoff, fallback: 1, kind: .destination, owesDismissal: true))
        #expect(!expiring.state.isSoftwareKeyboardDismissed)
    }

    @Test func endAndCancelReleaseBeforeMeasuringAndIgnoreOtherIDs() {
        var machine = Self.presented().after([.beginHandoff(id: Self.handoff, kind: .destination)])
        #expect(machine.handle(.endHandoff(UUID())) == [])
        #expect(machine.handle(.cancelHandoff(UUID())) == [])
        #expect(machine.handle(.endHandoff(Self.handoff)) == [
            .cancelHandoffFallback, .publishHandoffID(nil),
            .measureHandoffExit(id: Self.handoff, exit: .end, owesDismissal: false),
        ])
        #expect(machine.handoffID == nil)
        #expect(machine.handle(.endHandoff(Self.handoff)) == [])

        var cancelling = Self.presented().after([.beginHandoff(id: Self.handoff, kind: .owner)])
        #expect(cancelling.handle(.cancelHandoff(Self.handoff)).last
            == .measureHandoffExit(id: Self.handoff, exit: .cancel, owesDismissal: false))
    }

    @Test func onlyTheArmedFallbackReleases() {
        var machine = Self.presented().after([.beginHandoff(id: Self.handoff, kind: .owner)])
        #expect(machine.handle(.fallbackElapsed(token: 1)) == [])
        #expect(machine.handle(.fallbackElapsed(token: 2)) == [
            .forgetHandoffFallback, .publishHandoffID(nil),
            .measureHandoffExit(id: Self.handoff, exit: .fallback(.owner), owesDismissal: false),
        ])
        #expect(machine.handle(.fallbackElapsed(token: 2)) == [])
    }

    @Test func anEndKeepsAVisibleFrozenHeightButOtherExitsSettleTheDebt() {
        let owing = Self.presented().after([
            .beginHandoff(id: Self.handoff, kind: .destination), .willDismiss,
            .endHandoff(Self.handoff),
        ])
        var end = owing
        #expect(end.handle(.handoffExitMeasured(exit: .end, owesDismissal: true, height: 300)) == [])
        var cancel = owing
        #expect(cancel.handle(.handoffExitMeasured(exit: .cancel, owesDismissal: true, height: 280)) == [
            .publishLastPresentedHeight(280), .publishHeight(280),
            .cancelConfirmation, .publishSoftwareKeyboardDismissed(false),
        ])
        var gone = owing
        #expect(gone.handle(.handoffExitMeasured(exit: .end, owesDismissal: true, height: 0)) == [
            .publishHeight(0), .cancelConfirmation, .armConfirmation(token: 3),
        ])
    }

    @Test func aMissingMeasurementIsAZeroOnlyForTheOwnersFallback() {
        let owing = Self.presented().after([
            .beginHandoff(id: Self.handoff, kind: .owner), .willDismiss, .fallbackElapsed(token: 2),
        ])
        var owner = owing
        #expect(owner.handle(.handoffExitMeasured(
            exit: .fallback(.owner), owesDismissal: true, height: nil)) == [
            .publishHeight(0), .cancelConfirmation, .armConfirmation(token: 3),
        ])
        var destination = owing
        #expect(destination.handle(.handoffExitMeasured(
            exit: .fallback(.destination), owesDismissal: true, height: nil)) == [
            .cancelConfirmation, .publishSoftwareKeyboardDismissed(false),
        ])
        #expect(destination.state.height == 300)
        var unowed = owing
        #expect(unowed.handle(.handoffExitMeasured(
            exit: .fallback(.owner), owesDismissal: false, height: nil)) == [])
    }

    @Test func aZeroFrozenInsetAdoptsAKeyboardMeasuredUpAtExit() {
        var machine = Machine().after([
            .beginHandoff(id: Self.handoff, kind: .owner), .cancelHandoff(Self.handoff),
        ])
        #expect(machine.handle(.handoffExitMeasured(exit: .cancel, owesDismissal: false, height: 383)) == [
            .publishLastPresentedHeight(383), .publishHeight(383),
            .cancelConfirmation, .publishSoftwareKeyboardDismissed(false),
        ])
        var up = Self.presented()
        #expect(up.handle(.handoffExitMeasured(exit: .cancel, owesDismissal: false, height: 383)) == [])
        var nothing = Machine()
        #expect(nothing.handle(.handoffExitMeasured(exit: .end, owesDismissal: false, height: 0)) == [])
    }
}
