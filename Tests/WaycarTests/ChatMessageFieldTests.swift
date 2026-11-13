import SwiftUI
import Testing
import UIKit

@testable import Waycar

@MainActor
@Suite("Chat message field")
struct ChatMessageFieldTests {
    @Test func hardwareReturnSends() {
        let harness = Harness()
        #expect(!harness.shouldChange("\n"))
        #expect(harness.returns == 1)
    }

    @Test func hardwareShiftReturnInsertsTheNewline() {
        let harness = Harness()
        harness.isShiftHeld = true
        #expect(harness.shouldChange("\n"))
        #expect(harness.returns == 0)
    }

    /// Without a hardware keyboard the Return is the on-screen key's: it
    /// breaks the line, and the Send button is how the message leaves.
    @Test func onScreenReturnInsertsTheNewline() {
        let harness = Harness()
        harness.isKeyboardConnected = false
        #expect(harness.shouldChange("\n"))
        #expect(harness.returns == 0)
    }

    @Test(arguments: ["a\nb", "ls -la\n"])
    func multiLinePasteIsInserted(_ paste: String) {
        let harness = Harness()
        #expect(harness.shouldChange(paste))
        #expect(harness.returns == 0)
    }

    @Test func returnDuringCompositionStaysWithTheIME() throws {
        let harness = Harness()
        harness.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        try #require(harness.textView.markedTextRange != nil)
        #expect(harness.shouldChange("\n"))
        #expect(harness.returns == 0)
    }

    @MainActor
    private final class Harness {
        private final class Counter { var count = 0 }
        private let counter: Counter
        let textView = UITextView()
        let coordinator: ChatMessageField.Coordinator
        var isKeyboardConnected = true
        var isShiftHeld = false

        var returns: Int { counter.count }

        init() {
            let counter = Counter()
            self.counter = counter
            coordinator = ChatMessageField.Coordinator(
                onEdit: { _, _ in },
                onReturn: { counter.count += 1 },
                isFocused: .constant(false))
            textView.delegate = coordinator
            coordinator.isHardwareKeyboardConnected = { [unowned self] in isKeyboardConnected }
            coordinator.isHardwareShiftHeld = { [unowned self] in isShiftHeld }
        }

        func shouldChange(_ text: String) -> Bool {
            coordinator.textView(
                textView, shouldChangeTextIn: textView.selectedRange,
                replacementText: text)
        }
    }
}
