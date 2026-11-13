import Foundation
import Testing

@testable import Waycar

/// Every `paneCases` entry of the shared tmux pane option vectors, run
/// through the real inventory path: a `list-panes` record rendered from the
/// case's options, parsed by `TmuxInventory.parsePanes`, mapped by
/// `TmuxInventory.snapshot`.
@Suite("tmux pane option vectors")
struct TmuxPaneOptionsVectorTests {
    static let cases = TmuxPaneOptionsVectorFile.shared.paneCases

    /// A live pane whose foreground is neither a shell nor a known agent, so
    /// its kind and status come from the options alone.
    private static let foreground = "vector-agent"

    private static func snapshot(options: [String: String]) -> SessionSnapshot {
        let rs = String(TmuxInventory.recordSeparator)
        let us = String(TmuxInventory.fieldSeparator)
        let base: [String: String] = [
            "pane_id": "%3", "session_id": "$1", "window_id": "@2", "pane_index": "0",
            "pane_active": "1", "pane_dead": "0", "alternate_on": "0", "pane_pid": "4242",
            "pane_tty": "/dev/ttys004", "pane_width": "120", "pane_height": "40",
            "pane_current_command": foreground, "pane_current_path": "/home/u/proj",
            "pane_title": "host.local",
        ]
        let values = base.merging(options) { _, option in option }
        // Unset variables expand empty, as tmux renders them.
        let line = rs + TmuxInventory.paneFields.map { values[$0] ?? "" }.joined(separator: us)
        let panes = TmuxInventory.parsePanes(line.components(separatedBy: "\n"))
        let sessions = TmuxInventory.parseSessions([
            rs + ["$1", "0", "1", "proj", "", "/home/u/proj"].joined(separator: us)
        ])
        let windows = TmuxInventory.parseWindows([
            rs + ["@2", "$1", "0", "1", "0", "work"].joined(separator: us)
        ])
        return TmuxInventory.snapshot(
            sessions: sessions, windows: windows, panes: panes, kinds: [:], version: "3.6")
    }

    @Test func vectorFileHasPaneCases() {
        #expect(Self.cases.count >= 10)
    }

    @Test(arguments: cases)
    func paneOptionsDeriveExpectedState(_ vector: TmuxPaneOptionsVectorFile.PaneCase) throws {
        let expected = vector.expected
        let snapshot = Self.snapshot(options: vector.options)
        let pane = try #require(snapshot.panes.first)
        #expect(snapshot.panes.count == 1)

        #expect(pane.agentStatus.rawValue == expected.agentStatus)
        #expect(pane.agent == expected.agentKind)

        let agent = snapshot.agents.first
        #expect((agent != nil) == (expected.agentKind != nil))
        #expect(agent?.stateChangeSeq == expected.stateChangeSeq.flatMap { Int($0) })
        if let seq = expected.stateChangeSeq {
            #expect(agent?.stateChangeSeq.map(String.init) == seq)
        }

        // The session reference is `@waycar_session`, else the decoded
        // `@waycar_transcript`.
        #expect(pane.agentSession?.value == expected.sessionID ?? expected.transcriptPath)
        if let sessionID = expected.sessionID {
            #expect(pane.agentSession?.kind == (sessionID.hasPrefix("/") ? .path : .id))
        }
    }

    /// With `@waycar_session` withheld the transcript becomes the session
    /// reference, which pins the transcript decoding for every case.
    @Test(arguments: cases)
    func transcriptDecodesToExpectedPath(_ vector: TmuxPaneOptionsVectorFile.PaneCase) {
        var options = vector.options
        options["@waycar_session"] = nil
        let snapshot = Self.snapshot(options: options)
        let session = snapshot.panes.first?.agentSession

        guard vector.expected.agentKind != nil else {
            #expect(session?.value == nil)
            return
        }
        #expect(session?.value == vector.expected.transcriptPath)
        if vector.expected.transcriptPath != nil {
            #expect(session?.kind == .path)
        }
    }
}
