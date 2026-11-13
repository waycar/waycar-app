@testable import Waycar
import Foundation

extension AgentComposerStore {
    /// Test setup: replaces the whole draft with the caret at its end, as
    /// typing it would leave it.
    func replaceDraft(with text: String) {
        applyEditorDraft(text, selection: NSRange(location: (text as NSString).length, length: 0))
    }
}
