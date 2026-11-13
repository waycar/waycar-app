import Foundation

/// Host-kept saved layouts are not closed Agents: no kind, transcript or app-side retention.
struct ZellijClosedSession: Sendable, Equatable, Identifiable {
    let name: String
    var age: String?
    var id: String { name }
    /// Reserved terminal identity, minted only by Closed Sessions' Resume action.
    var terminalID: String { "zellij-session:" + name }

    static func name(for target: TerminalAttachTarget) -> String? {
        guard case .terminal(let id) = target, id.hasPrefix("zellij-session:") else { return nil }
        let name = String(id.dropFirst("zellij-session:".count))
        return ZellijPaneID.isSessionName(name) ? name : nil
    }

    static func listing(_ text: String) -> [Self] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let session = ZellijSessionRecord.listing(String(line)).first, session.closed,
                let marker = line.range(of: " [Created ", options: .backwards),
                let end = line[marker.upperBound...].firstIndex(of: "]") else { return nil }
            return Self(name: session.name, age: String(line[marker.upperBound..<end]))
        }
    }
}
