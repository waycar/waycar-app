import Foundation

/// Ultimate-only extras beyond the shared transcript and run controls:
/// the leader's branches and navigation into sibling chats.
struct UltimateChatContext {
    /// The display name of the chat on show ("@ultimate", a branch title).
    let name: String
    /// Whether the chat on show is running a turn right now (rail status).
    let busy: Bool
    /// The leader's active branches; empty on a branch's own chat.
    let children: [UltimateChildInfo]
    /// Opens another conversation of the same project by its id.
    let openConversation: @MainActor (Int) -> Void

    /// The pane id of a sibling conversation: the instance prefix of
    /// `paneID` ("ultimate:<instance>") with the sibling's id.
    static func paneID(sibling conversationId: Int, of paneID: String) -> String {
        guard let cut = paneID.lastIndex(of: ":") else { return paneID }
        return String(paneID[..<cut]) + ":\(conversationId)"
    }
}
