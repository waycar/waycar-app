import Foundation
import Testing

@testable import Waycar

struct MarkdownLinkedFileMachineTests {
    private let reference = TerminalFileReference(path: "next.md")
    private var target: TerminalLinkTarget { .file(reference) }
    private let directory = "/source"
    private let destination = "/source/next.md"
    private var consent: MarkdownLinkedFileMachine.Consent {
        .init(target: target, destination: destination, directory: directory)
    }

    private func confirming() -> MarkdownLinkedFileMachine {
        MarkdownLinkedFileMachine().after([
            .resolve(target, directory: directory), .resolved(1, destination: destination),
        ])
    }

    private func loading() -> MarkdownLinkedFileMachine {
        confirming().after([.dismissConfirmation, .confirmed(target), .confirmationEnded])
    }

    @Test func resolvingNeverStartsAReadAndCompletionPairsConsentWithDirectory() {
        var machine = MarkdownLinkedFileMachine()
        #expect(machine.handle(.resolve(target, directory: directory)) == [.resolve(1, target, directory: directory)])
        #expect(machine.state.resolution == .resolving(token: 1, target: target, directory: directory))
        #expect(machine.state.confirmation == .idle)
        #expect(machine.state.read == .idle)
        #expect(machine.handle(.resolved(1, destination: destination)) == [])
        #expect(machine.state.resolution == .idle)
        #expect(machine.state.confirmation == .confirming(consent))
    }

    @Test func newerResolutionRejectsOldCompletionWithoutDroppingNewDemand() {
        var machine = MarkdownLinkedFileMachine().after([.resolve(target, directory: directory)])
        let next = TerminalLinkTarget.file(TerminalFileReference(path: "other.md"))
        #expect(machine.handle(.resolve(next, directory: "/other")) == [
            .cancelResolution(1), .resolve(2, next, directory: "/other"),
        ])
        let state = machine.state
        #expect(machine.handle(.resolved(1, destination: "/stale")) == [])
        #expect(machine.state == state)
        _ = machine.handle(.resolved(2, destination: "/other/other.md"))
        #expect(machine.state.confirmation == .confirming(.init(
            target: next, destination: "/other/other.md", directory: "/other")))
    }

    @Test func nilBeforeOpenRetainsDirectoryUntilTheAlertEnds() {
        var machine = confirming()
        #expect(machine.handle(.dismissConfirmation) == [])
        #expect(machine.state.confirmation == .ending(directory: directory))
        #expect(machine.handle(.confirmed(target)) == [.load(2, reference, directory: directory)])
        #expect(machine.loadingName == "next.md")
        #expect(machine.handle(.confirmationEnded) == [])
        #expect(machine.state.confirmation == .idle)
        #expect(machine.state.read == .loading(token: 2, name: "next.md"))
    }

    @Test func confirmationMayAlsoOpenBeforeItsNilWrite() {
        var machine = confirming()
        #expect(machine.handle(.confirmed(target)) == [.load(2, reference, directory: directory)])
        #expect(machine.state.confirmation == .confirming(consent))
        _ = machine.handle([.dismissConfirmation, .confirmationEnded])
        #expect(machine.state.confirmation == .idle)
    }

    @Test func cancellingConsentAndUnownedCompletionsAreNoOpsForReads() {
        var machine = confirming()
        _ = machine.handle([.dismissConfirmation, .confirmationEnded])
        #expect(machine.handle(.confirmed(target)) == [])
        #expect(machine.handle(.cancelRead) == [])
        #expect(machine.handle(.readFinished(99, .failed("stale"))) == [])
        #expect(machine.handle(.resolved(1, destination: "stale")) == [])
        #expect(machine.state.read == .idle)
        #expect(machine.loadingName == nil)
    }

    @Test func aNewResolutionKeepsExistingConsentAndConsentedRead() {
        var machine = confirming()
        _ = machine.handle(.confirmed(target))
        let next = TerminalLinkTarget.file(TerminalFileReference(path: "another.md"))
        #expect(machine.handle(.resolve(next, directory: "/next")) == [.resolve(3, next, directory: "/next")])
        #expect(machine.state.confirmation == .confirming(consent))
        #expect(machine.state.read == .loading(token: 2, name: "next.md"))
        _ = machine.handle(.resolved(3, destination: "/next/another.md"))
        #expect(machine.state.read == .loading(token: 2, name: "next.md"))
    }

    @Test func confirmingAnotherFileCancelsOnlyTheOldReadAndRejectsItsAnswer() {
        var machine = confirming()
        _ = machine.handle(.confirmed(target))
        #expect(machine.handle(.confirmed(target)) == [.cancelRead(2), .load(3, reference, directory: directory)])
        #expect(machine.handle(.readFinished(2, .failed("old"))) == [])
        #expect(machine.loadingName == "next.md")
        #expect(machine.handle(.readFinished(3, .failed("current"))) == [])
        #expect(machine.state.failure == "current")
        #expect(machine.state.read == .idle)
    }

    @Test func successfulMarkdownPushesAndQuickLookPresents() {
        let page = MarkdownFilePreview(
            id: UUID(), remotePath: destination, text: "# Next", localURL: URL(fileURLWithPath: destination))
        var markdown = loading()
        #expect(markdown.handle(.readFinished(2, .preview(.markdown(page)))) == [.push(page)])
        #expect(markdown.loadingName == nil)
        #expect(markdown.handle(.readFinished(2, .preview(.markdown(page)))) == [])
        var quickLook = loading()
        #expect(quickLook.handle(.readFinished(2, .preview(.quickLook(page.localURL)))) == [])
        #expect(quickLook.state.preview == page.localURL)
        #expect(quickLook.state.read == .idle)
    }

    @Test func explicitWebConsentOpensWithoutCancellingAnExistingRead() {
        let url = URL(string: "https://example.com")!
        var machine = loading()
        _ = machine.handle([.resolve(.web(url), directory: directory), .resolved(3, destination: url.absoluteString)])
        _ = machine.handle(.dismissConfirmation)
        #expect(machine.handle(.confirmed(.web(url))) == [.openWeb(url)])
        #expect(machine.state.read == .loading(token: 2, name: "next.md"))
    }

    @Test func cancelAndDisappearDropOwnershipBeforeLateCompletions() {
        var machine = loading()
        #expect(machine.handle(.cancelRead) == [.cancelRead(2)])
        #expect(machine.handle(.readFinished(2, .failed("late"))) == [])
        #expect(machine.state.failure == nil)
        #expect(machine.handle(.cancelRead) == [])

        var overlapping = confirming()
        _ = overlapping.handle([.confirmed(target), .resolve(target, directory: directory)])
        #expect(overlapping.handle(.disappear) == [.cancelResolution(3), .cancelRead(2)])
        #expect(overlapping.handle([.resolved(3, destination: "late"), .readFinished(2, .failed("late")), .disappear]) == [])
        // Teardown did not dismiss the sheet's stored presentation.
        #expect(overlapping.state.confirmation == .confirming(consent))
    }

    @Test func alertsAndPreviewRemainIndependentOfNewWorkUntilDismissed() {
        let url = URL(fileURLWithPath: "/copy/file.pdf")
        var machine = confirming()
        #expect(machine.handle([.refusalChanged(url), .failureChanged("previous"), .previewChanged(url)]) == [])
        _ = machine.handle(.confirmed(target))
        #expect(machine.state.refusedLink == url)
        #expect(machine.state.failure == "previous")
        #expect(machine.state.preview == url)
        #expect(machine.handle([.refusalChanged(nil), .failureChanged(nil), .previewChanged(nil)]) == [])
        #expect(machine.state.refusedLink == nil)
        #expect(machine.state.failure == nil)
        #expect(machine.state.preview == nil)
    }

    @Test func idleCancellationAndUnownedCompletionsDoNothing() {
        var machine = MarkdownLinkedFileMachine()
        let initial = machine.state
        #expect(machine.handle([
            .resolved(1, destination: "stale"), .dismissConfirmation, .confirmationEnded,
            .confirmed(target), .cancelRead, .readFinished(1, .failed("stale")), .disappear,
        ]) == [])
        #expect(machine.state == initial)
    }
}
