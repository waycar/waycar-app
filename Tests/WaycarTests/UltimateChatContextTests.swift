import Foundation
import Testing

@testable import Waycar

@Suite("Ultimate Hybrid chat context")
struct UltimateChatContextTests {
    @Test("Sibling pane ids swap only the conversation id")
    func siblingPaneID() {
        #expect(
            UltimateChatContext.paneID(sibling: 17176, of: "ultimate:mac-1:16968")
                == "ultimate:mac-1:17176")
    }

    @Test("A pane id without a separator stays as it is")
    func malformedPaneID() {
        #expect(UltimateChatContext.paneID(sibling: 2, of: "odd") == "odd")
    }

    @Test("A leader's children open by conversation id; a branch chat has none")
    func detailContextChildren() {
        let child = UltimateChildInfo(
            conversationId: 17176, paneID: "ultimate:mac-1:17176",
            name: "Mockups: session screen", busy: true, openQuestions: 1)
        #expect(child.needsUser)
        #expect(child.status == .working)
    }
}
