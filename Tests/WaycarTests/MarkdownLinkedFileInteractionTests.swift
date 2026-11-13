import Foundation
import Testing

@testable import Waycar

/// Through the sheet's interaction owner, before and after its conversion.
/// Gates intentionally ignore cancellation, like a slow remote operation.
@MainActor
struct MarkdownLinkedFileInteractionTests {
    private func page(_ path: String) -> MarkdownFilePreview {
        MarkdownFilePreview(id: UUID(), remotePath: path, text: "# File", localURL: URL(fileURLWithPath: path))
    }

    private func file(_ path: String) -> TerminalLinkTarget { .file(TerminalFileReference(path: path)) }

    @Test func aResolvedLinkReadsOnlyAfterConsentAndUsesTheDisplayedPath() async throws {
        var reads: [String] = []
        let linked = page("/resolved/next.md")
        let owner = MarkdownLinkedFileInteraction(
            loadLinkedFile: { file, directory in
                reads.append("\(directory):\(file.path)")
                return .markdown(linked)
            },
            confirmationDetail: { _, _ in "/resolved/next.md" }, failureMessage: { _ in "failure" })
        defer { owner.disappear() }
        owner.confirm(file("next.md"), from: page("/source/README.md"))
        try await waitUntil { owner.pendingLink != nil }
        #expect(reads.isEmpty)
        #expect(owner.loadingName == nil)
        let confirmation = try #require(owner.pendingLink)
        // The alert writes nil BEFORE invoking its Open closure.
        owner.pendingLink = nil
        owner.open(confirmation.confirmedTarget, openWeb: { _ in Issue.record("not a web link") })
        owner.confirmationDidEnd()
        #expect(owner.loadingName == "next.md")
        try await waitUntil { owner.path == [linked.id] }
        #expect(owner.linkedPages[linked.id] == linked)
        #expect(reads == ["/source:/resolved/next.md"])
        #expect(owner.loadingName == nil)
    }

    @Test func anUnconfirmedFileCannotReadAndAConfirmedWebLinkDoesNotRead() async throws {
        var reads = 0
        var opened: [URL] = []
        let url = URL(string: "https://example.com/docs")!
        let owner = MarkdownLinkedFileInteraction(
            loadLinkedFile: { _, _ in reads += 1; throw CancellationError() },
            confirmationDetail: { _, _ in url.absoluteString }, failureMessage: { _ in "failure" })
        defer { owner.disappear() }
        owner.open(file("no.md"), openWeb: { opened.append($0) })
        #expect(owner.loadingName == nil)
        owner.confirm(.web(url), from: page("/source/README.md"))
        try await waitUntil { owner.pendingLink != nil }
        owner.pendingLink = nil
        owner.open(.web(url), openWeb: { opened.append($0) })
        owner.confirmationDidEnd()
        #expect(opened == [url])
        #expect(reads == 0)
    }

    @Test func replacedAndDisappearedResolutionsCannotPresentTheirAnswers() async throws {
        let gate = MarkdownInteractionGate<String>()
        let owner = MarkdownLinkedFileInteraction(
            loadLinkedFile: { _, _ in throw CancellationError() },
            confirmationDetail: { target, _ in await gate.wait(target.copyableText) },
            failureMessage: { _ in "failure" })
        defer { owner.disappear() }
        owner.confirm(file("first.md"), from: page("/source/README.md"))
        try await waitUntil { gate.started == ["first.md"] }
        owner.confirm(file("next.md"), from: page("/source/README.md"))
        try await waitUntil { gate.started == ["first.md", "next.md"] }
        gate.answer("first.md", with: "/old/first.md")
        try await waitUntil { gate.returned.contains("first.md") }
        #expect(owner.pendingLink == nil)
        owner.disappear()
        gate.answer("next.md", with: "/new/next.md")
        try await waitUntil { gate.returned.contains("next.md") }
        #expect(owner.pendingLink == nil)
    }

    @Test func resolvingAnotherLinkDoesNotCancelAConsentedRead() async throws {
        let reads = MarkdownInteractionGate<LinkedFilePreview>()
        let owner = MarkdownLinkedFileInteraction(
            loadLinkedFile: { file, _ in await reads.wait(file.path) },
            confirmationDetail: { target, _ in target.copyableText }, failureMessage: { _ in "failure" })
        defer { owner.disappear() }
        try await consent(file("first.png"), owner: owner)
        try await waitUntil { reads.started == ["first.png"] }
        owner.confirm(file("next.md"), from: page("/source/README.md"))
        try await waitUntil { owner.pendingLink?.target == file("next.md") }
        #expect(owner.loadingName == "first.png")
        let copy = URL(fileURLWithPath: "/copy/first.png")
        reads.answer("first.png", with: .quickLook(copy))
        try await waitUntil { owner.quickLookURL == copy }
        #expect(owner.pendingLink?.target == file("next.md"))
        #expect(owner.loadingName == nil)
    }

    @Test func cancellationAndDisappearanceRejectLateReadSuccess() async throws {
        for disappear in [false, true] {
            let gate = MarkdownInteractionGate<LinkedFilePreview>()
            let owner = MarkdownLinkedFileInteraction(
                loadLinkedFile: { file, _ in await gate.wait(file.path) },
                confirmationDetail: { target, _ in target.copyableText }, failureMessage: { _ in "failure" })
            try await consent(file("first.md"), owner: owner)
            try await waitUntil { gate.started == ["first.md"] }
            if disappear { owner.disappear() } else { owner.cancelLinkedFileLoad() }
            #expect(owner.loadingName == nil)
            gate.answer("first.md", with: .markdown(page("/source/first.md")))
            try await waitUntil { gate.returned == ["first.md"] }
            #expect(owner.path.isEmpty)
            #expect(owner.quickLookURL == nil)
            #expect(owner.loadFailureMessage == nil)
            owner.disappear()
        }
    }

    @Test func replacingAReadIgnoresItsLateFailureAndShowsTheNewFailure() async throws {
        let gate = MarkdownInteractionGate<Result<LinkedFilePreview, CancellationError>>()
        let owner = MarkdownLinkedFileInteraction(
            loadLinkedFile: { file, _ in try await gate.wait(file.path).get() },
            confirmationDetail: { target, _ in target.copyableText }, failureMessage: { _ in "shown failure" })
        defer { owner.disappear() }
        try await consent(file("first.md"), owner: owner)
        try await waitUntil { gate.started == ["first.md"] }
        try await consent(file("next.md"), owner: owner)
        try await waitUntil { gate.started == ["first.md", "next.md"] }
        gate.answer("first.md", with: .failure(CancellationError()))
        try await waitUntil { gate.returned.contains("first.md") }
        #expect(owner.loadingName == "next.md")
        #expect(owner.loadFailureMessage == nil)
        gate.answer("next.md", with: .failure(CancellationError()))
        try await waitUntil { owner.loadFailureMessage != nil }
        #expect(owner.loadFailureMessage == "shown failure")
        #expect(owner.loadingName == nil)
    }

    @Test func theNextPushPrunesOnlyPagesAlreadyPopped() async throws {
        let first = page("/source/first.md")
        let next = page("/source/next.md")
        let owner = MarkdownLinkedFileInteraction(
            loadLinkedFile: { file, _ in .markdown(file.path == "first.md" ? first : next) },
            confirmationDetail: { target, _ in target.copyableText }, failureMessage: { _ in "failure" })
        defer { owner.disappear() }
        try await consent(file("first.md"), owner: owner)
        try await waitUntil { owner.path == [first.id] }
        owner.path = []
        #expect(owner.linkedPages[first.id] == first)
        try await consent(file("next.md"), owner: owner)
        try await waitUntil { owner.path == [next.id] }
        #expect(owner.linkedPages[first.id] == nil)
        #expect(owner.linkedPages[next.id] == next)
    }

    private func consent(_ target: TerminalLinkTarget, owner: MarkdownLinkedFileInteraction) async throws {
        owner.confirm(target, from: page("/source/README.md"))
        try await waitUntil { owner.pendingLink?.target == target }
        let confirmation = try #require(owner.pendingLink)
        owner.pendingLink = nil
        owner.open(confirmation.confirmedTarget, openWeb: { _ in Issue.record("not a web link") })
        owner.confirmationDidEnd()
    }
}

@MainActor
private final class MarkdownInteractionGate<Value: Sendable> {
    private(set) var started: [String] = []
    private(set) var returned: [String] = []
    private var waiting: [String: CheckedContinuation<Value, Never>] = [:]

    func wait(_ key: String) async -> Value {
        started.append(key)
        let value = await withCheckedContinuation { waiting[key] = $0 }
        returned.append(key)
        return value
    }

    func answer(_ key: String, with value: Value) {
        waiting.removeValue(forKey: key)?.resume(returning: value)
    }
}
