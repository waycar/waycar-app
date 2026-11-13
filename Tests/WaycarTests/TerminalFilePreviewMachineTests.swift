import Foundation
import Testing

@testable import Waycar

struct TerminalFilePreviewMachineTests {
    @Test func cancellationAndStaleCompletionsCannotReplaceTheCurrentViewer() {
        var machine = TerminalFilePreviewMachine()
        #expect(machine.handle(.request(name: "first")) == [.startRead(1)])
        #expect(machine.handle(.cancel) == [.cancelRead])
        #expect(machine.handle(.request(name: "second")) == [.startRead(2)])
        let current = machine.state
        #expect(machine.handle(.presented(1, .quickLook(Self.url("old/a.txt")))).isEmpty)
        #expect(machine.handle(.failed(1, message: "old failure")).isEmpty)
        #expect(machine.state == current)
        #expect(machine.handle(.presented(2, .quickLook(Self.url("new/b.txt")))).isEmpty)
        #expect(machine.previewURL == Self.url("new/b.txt"))
        #expect(machine.loadingToken == nil)
        let settled = machine.state
        #expect(machine.handle(.presented(2, .quickLook(Self.url("old/a.txt")))).isEmpty)
        #expect(machine.handle(.failed(2, message: "late failure")).isEmpty)
        #expect(machine.state == settled)
    }

    @Test func replacingAReadCancelsItAndMintsANewToken() {
        var machine = TerminalFilePreviewMachine().after([.request(name: "one")])
        #expect(machine.handle(.request(name: "two")) == [.cancelRead, .startRead(2)])
        #expect(machine.state == .loading(2, name: "two", .init()))
    }

    @Test func loadingFailureAndCancellationRetainThePreviousViewer() {
        let markdown = Self.markdown()
        var machine = TerminalFilePreviewMachine().after([
            .request(name: "visible"), .presented(1, .markdown(markdown)),
            .linkedCopyWritten(Self.url("linked")), .request(name: "replacement"),
        ])
        #expect(machine.markdownPreview == markdown)
        #expect(machine.acceptsLinkedRead(from: markdown.id))
        #expect(machine.handle(.failed(2, message: "read failed")).isEmpty)
        #expect(machine.markdownPreview == markdown)
        #expect(machine.handle(.cancel) == [.cancelRead])
        guard case .failed = machine.state else {
            Issue.record("cancel must not dismiss a failure")
            return
        }
        _ = machine.handle(.dismissFailure)
        #expect(machine.state == .ready(machine.contents))
        _ = machine.handle(.request(name: "another"))
        _ = machine.handle(.cancel)
        #expect(machine.markdownPreview == markdown)
        #expect(machine.contents.linkedCopies == [Self.url("linked")])
    }

    @Test func aNewViewerRemovesTheOldMarkdownAndItsLinksButNotGalleryFiles() {
        let markdown = Self.markdown()
        var machine = TerminalFilePreviewMachine().after([
            .request(name: "visible"), .presented(1, .markdown(markdown)),
            .linkedCopyWritten(Self.url("link-1")), .linkedCopyWritten(Self.url("link-2")),
            .galleryFileWritten(Self.url("gallery")), .request(name: "image"),
        ])
        #expect(machine.handle(.presented(2, .quickLook(Self.url("picture/a.png")))) == [
            .removeDirectory(markdown.localURL.deletingLastPathComponent()),
            .removeDirectory(Self.url("link-1")), .removeDirectory(Self.url("link-2")),
        ])
        #expect(machine.markdownPreview == nil)
        #expect(machine.previewURL == Self.url("picture/a.png"))
        #expect(machine.contents.linkedCopies.isEmpty)
        #expect(machine.contents.galleryFiles == [Self.url("gallery")])
        #expect(!machine.acceptsLinkedRead(from: markdown.id))
        _ = machine.handle(.request(name: "next"))
        #expect(machine.handle(.presented(3, .markdown(Self.markdown()))) == [
            .removeDirectory(Self.url("picture/a.png").deletingLastPathComponent()),
        ])
    }

    @Test func closingAViewerDoesNotCancelAReplacementRead() {
        let markdown = Self.markdown()
        var machine = TerminalFilePreviewMachine().after([
            .request(name: "visible"), .presented(1, .markdown(markdown)), .request(name: "pending"),
        ])
        #expect(machine.handle(.closeQuickLook).isEmpty)
        #expect(machine.markdownPreview == markdown)
        #expect(machine.handle(.closeMarkdown) == [.removeDirectory(markdown.localURL.deletingLastPathComponent())])
        #expect(machine.loadingToken == 2)
        #expect(!machine.acceptsLinkedRead(from: markdown.id))
        #expect(machine.handle(.dismissFailure).isEmpty)
        _ = machine.handle(.presented(2, .quickLook(Self.url("text/a.txt"))))
        #expect(machine.handle(.closeQuickLook) == [
            .removeDirectory(Self.url("text/a.txt").deletingLastPathComponent()),
        ])
        #expect(machine.handle(.closeQuickLook).isEmpty)
        #expect(machine.previewURL == nil)
    }

    @Test func galleryCleanupIsScopedAndFencesOnlyGalleryReads() {
        let markdown = Self.markdown()
        var machine = TerminalFilePreviewMachine().after([
            .request(name: "visible"), .presented(1, .markdown(markdown)),
            .galleryFileWritten(Self.url("gallery-a")), .galleryFileWritten(Self.url("gallery-b")),
        ])
        let generation = machine.contents.galleryGeneration
        #expect(machine.handle(.removeGalleryFile(Self.url("unowned"))).isEmpty)
        #expect(machine.handle(.removeGalleryFile(Self.url("gallery-a"))) == [.removeDirectory(Self.url("gallery-a"))])
        #expect(machine.acceptsGalleryRead(from: generation))
        #expect(machine.handle(.removeGalleryFiles) == [.removeDirectory(Self.url("gallery-b"))])
        #expect(!machine.acceptsGalleryRead(from: generation))
        #expect(machine.acceptsGalleryRead(from: generation + 1))
        #expect(machine.markdownPreview == markdown)
        #expect(machine.handle(.removeGalleryFiles).isEmpty)
        #expect(machine.contents.galleryGeneration == generation + 2)
    }

    @Test func aSynchronousRefusalAndLinkedCopiesWithoutAMarkdownKeepTheirExistingSemantics() {
        var machine = TerminalFilePreviewMachine()
        #expect(machine.acceptsLinkedRead(from: nil), "the old nil identity guard admits this call")
        _ = machine.handle(.linkedCopyWritten(Self.url("link")))
        _ = machine.handle(.failed(nil, message: "refused"))
        #expect(machine.state == .failed(message: "refused", machine.contents))
        #expect(machine.handle(.closeMarkdown) == [.removeDirectory(Self.url("link"))])
        _ = machine.handle(.dismissFailure)
        #expect(machine.handle(.dismissFailure).isEmpty)
    }

    private static func url(_ path: String) -> URL { URL(fileURLWithPath: "/preview/" + path) }
    private static func markdown() -> MarkdownFilePreview {
        MarkdownFilePreview(id: UUID(), remotePath: "/README.md", text: "# Readme", localURL: url("markdown/README.md"))
    }
}
