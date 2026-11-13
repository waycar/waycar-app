import SwiftUI
import Synchronization
import Testing
import UIKit

@testable import Waycar

@MainActor
@Suite("Agent request cards")
struct AgentRequestCardTests {
    @Test(arguments: [false, true])
    func fileChangesRequireReadablePaths(known: Bool) async throws {
        let paths = known ? (1...6).map { "Sources/File\($0).swift" } : []
        var answers: [AgentRequestAnswer] = []
        let controller = UIHostingController(rootView: AgentRequestCardView(
            request: .init(id: "patch", kind: .fileChange(reason: "Update the implementation", paths: paths)),
            canAnswer: true, answer: { answers.append($0) }))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 440, height: 880), rootViewController: controller)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await DisplayTickMonitor.shared.waitForTicks(20)
        let root = try #require(controller.view)
        #expect(find("Update the implementation", in: root) != nil)
        #expect((find("Allow", in: root) != nil) == known)
        if known {
            #expect(find(paths.prefix(4).joined(separator: "\n"), in: root) != nil)
            #expect(find("and 2 more", in: root) != nil)
            let allow = try #require(find("Allow", in: root))
            try #require(allow.accessibilityActivate())
            #expect(answers == [.allow])
        } else {
            #expect(find("Review this change on the Host.", in: root) != nil)
        }
        let cancel = try #require(find("Cancel", in: root))
        try #require(cancel.accessibilityActivate())
        #expect(answers.last == .cancel)
    }

    /// A `multi` question takes several picks, tap to toggle, and submits
    /// them all; a single-pick question beside it keeps one.
    @Test func multiselectQuestionsSubmitEveryPick() async throws {
        let card = ChatQuestionCard(body: "", questions: [
            ChatQuestion(ref: "q0", text: "Pick a color", kind: "choice", options: [
                ChatQuestionOption(key: "a", label: "Red", detail: nil, recommended: false),
                ChatQuestionOption(key: "b", label: "Blue", detail: nil, recommended: false)]),
            ChatQuestion(ref: "q1", text: "Sizes", kind: "multi", options: [
                ChatQuestionOption(key: "a", label: "Small", detail: nil, recommended: false),
                ChatQuestionOption(key: "b", label: "Medium", detail: nil, recommended: false),
                ChatQuestionOption(key: "c", label: "Large", detail: nil, recommended: false)])])
        let submitted = Mutex<[[String: [String]]]>([])
        let controller = UIHostingController(rootView: ChatQuestionCardView(
            card: card, submit: nil, submitAnswers: { answers in submitted.withLock { $0.append(answers) } }))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 440, height: 880), rootViewController: controller)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await DisplayTickMonitor.shared.waitForTicks(20)
        let root = try #require(controller.view)
        func tap(_ option: String, then label: String) async throws {
            let button = try #require(find(option, in: root), "\(option) should be on the card")
            try #require(button.accessibilityActivate())
            try await waitUntil("\(label) should show") {
                root.layoutIfNeeded()
                return find(label, in: root) != nil
            }
        }
        try await tap("Option a: Red", then: "Option a: Red. Selected")
        try await tap("Option b: Blue", then: "Option b: Blue. Selected")
        #expect(find("Option a: Red", in: root) != nil, "a single pick replaces the last")
        try await tap("Option a: Small", then: "Option a: Small. Selected")
        try await tap("Option c: Large", then: "Option c: Large. Selected")
        try await tap("Option b: Medium", then: "Option b: Medium. Selected")
        try await tap("Option b: Medium. Selected", then: "Option b: Medium")
        #expect(find("Option a: Small. Selected", in: root) != nil)
        let submit = try #require(find("Submit answers", in: root))
        try #require(submit.accessibilityActivate())
        #expect(submitted.withLock { $0 } == [["q0": ["Blue"], "q1": ["Small", "Large"]]])
    }

    /// B-20: a one-tap answer that failed to send leaves the card unanswered
    /// and tappable, never marked Sent; a retry that is delivered is.
    @Test func failedOneTapAnswerLeavesTheCardUnsent() async throws {
        let card = ChatQuestionCard(body: "", questions: [
            ChatQuestion(ref: "q0", text: "Pick a color", kind: "choice", options: [
                ChatQuestionOption(key: "a", label: "Red", detail: nil, recommended: false),
                ChatQuestionOption(key: "b", label: "Blue", detail: nil, recommended: false)])])
        let submitted = Mutex<[String]>([])
        let controller = UIHostingController(rootView: ChatQuestionCardView(
            card: card, submit: { reference in
                let count = submitted.withLock { $0.append(reference); return $0.count }
                return count == 1 ? .notSent : .sent
            }))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 440, height: 880), rootViewController: controller)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await DisplayTickMonitor.shared.waitForTicks(20)
        let root = try #require(controller.view)
        let red = try #require(find("Option a: Red", in: root))
        try #require(red.accessibilityActivate())
        try await waitUntil("the failed answer should leave the card tappable") {
            root.layoutIfNeeded()
            guard submitted.withLock({ $0 }) == ["q0a"], let option = find("Option a: Red", in: root) else {
                return false
            }
            return !option.accessibilityTraits.contains(.notEnabled)
        }
        try await DisplayTickMonitor.shared.waitForTicks(5)
        root.layoutIfNeeded()
        #expect(find("Option a: Red. Sent", in: root) == nil, "a failed send is not Sent")
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        Attachment.record(image, named: "question-card-failed", as: .png)
        let blue = try #require(find("Option b: Blue", in: root))
        try #require(blue.accessibilityActivate())
        try await waitUntil("the delivered retry should show Sent") {
            root.layoutIfNeeded()
            return find("Option b: Blue. Sent", in: root) != nil
        }
        #expect(submitted.withLock { $0 } == ["q0a", "q0b"])
    }

    private func find(_ label: String, in root: UIView) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func walk(_ node: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
            if node.accessibilityLabel == label { return node }
            for case let child as NSObject in node.accessibilityElements ?? [] {
                if let found = walk(child) { return found }
            }
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let child = node.accessibilityElement(at: index) as? NSObject,
                       let found = walk(child) { return found }
                }
            }
            if let view = node as? UIView {
                for child in view.subviews { if let found = walk(child) { return found } }
            }
            return nil
        }
        return walk(root)
    }
}
