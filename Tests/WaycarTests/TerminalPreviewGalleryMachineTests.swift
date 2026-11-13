import Foundation
import Testing

@testable import Waycar

struct TerminalPreviewGalleryMachineTests {
    private func gallery(_ kinds: [TerminalFileKind] = [.image, .image, .image], limit: Int = 5)
        -> TerminalPreviewGalleryMachine {
        TerminalPreviewGalleryMachine(kinds: kinds, startIndex: 0, heldCopyLimit: limit)
    }

    private func copy(_ index: Int) -> URL { URL(fileURLWithPath: "/copies/\(index)") }

    @Test func firstPageReadsImmediatelyAndInvalidSelectionsDoNothing() {
        var machine = gallery()
        let initial = machine.state
        #expect(machine.handle(.show(-1)) == [])
        #expect(machine.handle(.show(3)) == [])
        #expect(machine.state == initial)
        #expect(machine.handle(.show(0)) == [.pageChanged(0), .read(index: 0, token: 1)])
        #expect(machine.handle(.show(0)) == [])
        #expect(machine.current == 0)
    }

    @Test func settledCurrentReadsNextImageBeforePreviousAndNeverPDFsAhead() {
        var machine = TerminalPreviewGalleryMachine(
            kinds: [.image, .pdf, .image], startIndex: 1, heldCopyLimit: 5)
        _ = machine.handle(.show(1))
        #expect(machine.handle(.readFinished(index: 1, token: 1, page: .ready(copy(1)))) == [
            .pageChanged(1), .pageChanged(2), .read(index: 2, token: 2),
        ])
        #expect(machine.handle(.readFinished(index: 2, token: 2, page: .failed(message: "no"))) == [
            .pageChanged(2), .pageChanged(0), .read(index: 0, token: 3),
        ])

        var pdf = gallery([.image, .pdf])
        _ = pdf.handle(.show(0))
        #expect(pdf.handle(.readFinished(index: 0, token: 1, page: .failed(message: "no"))) == [.pageChanged(0)])
        #expect(pdf.pages[1] == .waiting)
    }

    @Test func dwellReplacesWaitAndStaleWaitCannotReadANewSelection() {
        var machine = gallery([.pdf, .pdf, .pdf])
        _ = machine.handle(.show(0))
        #expect(machine.handle(.show(1)) == [.cancelRead(1), .pageChanged(0), .armDwell(2)])
        #expect(machine.handle(.show(1)) == [])
        #expect(machine.handle(.show(2)) == [.cancelDwell(2), .armDwell(3)])
        #expect(machine.handle(.dwellElapsed(2)) == [])
        #expect(machine.handle(.dwellElapsed(3)) == [.pageChanged(2), .read(index: 2, token: 4)])
        #expect(machine.handle(.dwellElapsed(3)) == [])
    }

    @Test func adjacentImageReadCarriesOnThroughArrivalAndDeparture() {
        var machine = gallery()
        _ = machine.handle(.show(0))
        _ = machine.handle(.readFinished(index: 0, token: 1, page: .ready(copy(0))))
        #expect(machine.handle(.show(1)) == [])
        #expect(machine.handle(.show(0)) == [])
        #expect(machine.handle(.show(1)) == [])
        #expect(machine.handle(.readFinished(index: 1, token: 2, page: .ready(copy(1)))) == [
            .pageChanged(1), .pageChanged(2), .read(index: 2, token: 3),
        ])
    }

    @Test func twoReadsMayOverlapButNoThirdReadStarts() {
        var machine = gallery([.image, .image, .image, .image, .image])
        _ = machine.handle(.show(0))
        _ = machine.handle(.readFinished(index: 0, token: 1, page: .ready(copy(0))))
        #expect(machine.handle(.show(2)) == [.armDwell(3)])
        #expect(machine.handle(.dwellElapsed(3)) == [.pageChanged(2), .read(index: 2, token: 4)])
        #expect(machine.handle(.readFinished(index: 2, token: 4, page: .ready(copy(2)))) == [.pageChanged(2)])
        #expect(machine.handle(.readFinished(index: 1, token: 2, page: .ready(copy(1)))) == [
            .pageChanged(1), .pageChanged(3), .read(index: 3, token: 5),
        ])
    }

    @Test func staleReadCannotReplaceANewerReadOfTheSamePage() {
        var machine = gallery([.pdf, .pdf])
        _ = machine.handle(.show(0))
        _ = machine.handle(.show(1))
        _ = machine.handle(.show(0))
        _ = machine.handle(.dwellElapsed(3))
        let state = machine.state
        #expect(machine.handle(.readFinished(index: 0, token: 1, page: .ready(copy(0)))) == [.removeCopy(copy(0))])
        #expect(machine.handle(.readFinished(index: 0, token: 1, page: .failed(message: "old"))) == [])
        #expect(machine.state == state)
        #expect(machine.handle(.readFinished(index: 0, token: 4, page: .failed(message: "current"))) == [.pageChanged(0)])
    }

    @Test func evictionRemovesFarthestCopyAndMakesItReadableAgain() {
        var machine = gallery([.pdf, .pdf], limit: 1)
        _ = machine.handle(.show(0))
        _ = machine.handle(.readFinished(index: 0, token: 1, page: .ready(copy(0))))
        _ = machine.handle(.show(1))
        _ = machine.handle(.dwellElapsed(2))
        #expect(machine.handle(.readFinished(index: 1, token: 3, page: .ready(copy(1)))) == [
            .pageChanged(1), .removeCopy(copy(0)), .pageChanged(0),
        ])
        #expect(machine.pages == [.waiting, .ready(copy(1))])
        #expect(machine.handle(.show(0)) == [.armDwell(4)])
    }

    @Test func closeCancelsOwnershipOnceAndDiscardsLateCopies() {
        var machine = gallery()
        _ = machine.handle(.show(0))
        _ = machine.handle(.show(1))
        let pages = machine.pages
        #expect(machine.handle(.close) == [.cancelDwell(2), .cancelRead(1), .removeAllCopies])
        #expect(machine.state == .closed(pages: pages, current: 1))
        #expect(machine.handle([.show(0), .dwellElapsed(2), .close]) == [])
        #expect(machine.handle(.readFinished(index: 0, token: 1, page: .ready(copy(0)))) == [.removeCopy(copy(0))])
        #expect(machine.handle(.readFinished(index: 0, token: 1, page: .failed(message: "late"))) == [])
    }

    @Test func emptyGalleryIgnoresSelectionAndCloses() {
        var machine = gallery([])
        #expect(machine.handle([.show(0), .dwellElapsed(1)]) == [])
        #expect(machine.handle(.close) == [.removeAllCopies])
        #expect(machine.current == 0)
        #expect(machine.pages.isEmpty)
    }
}
