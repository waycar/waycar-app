import Foundation

@testable import Waycar

/// First watch frame captured on Linux, Zellij 0.46.0, scratch HOME/socket, 2026-11-12.
/// JSON whitespace compacted; all fields retained, including unknown attention/geometry.
/// Session age normalized to the feed's fixed [Created] placeholder.
enum ZellijFixtures {
    static let capturedPanes = #"""
        [{"id":4,"is_plugin":true,"is_focused":true,"is_fullscreen":false,"is_floating":true,"is_suppressed":false,"is_collapsed":false,"title":"About Zellij","exited":false,"exit_status":null,"is_held":false,"pane_x":13,"pane_content_x":14,"pane_y":13,"pane_content_y":14,"pane_rows":24,"pane_content_rows":22,"pane_columns":25,"pane_content_columns":23,"terminal_command":null,"plugin_url":"about","is_selectable":true,"index_in_pane_group":{},"default_fg":null,"default_bg":null,"nested_session_name":null,"attention":{"status":"Idle","source":null,"text":"","detail":{"kind":null,"progress":null,"app":null,"title":null,"body":null,"exit_code":null,"duration_ms":null,"command":null},"since_ms":0,"changed_ms":0,"seen":false,"muted":null,"ignore_output":false,"watched":false,"from_watch":false,"remembered":null},"command_state":{"phase":"Unknown","running":null,"last":null,"cwd":null,"reports_markers":false},"program_status":[],"tab_id":0,"tab_position":0,"tab_name":"Tab #1"},
        {"id":0,"is_plugin":false,"is_focused":true,"is_fullscreen":false,"is_floating":false,"is_suppressed":false,"is_collapsed":false,"title":"/bin/sh -c printf '\u001b]7501;state=working:app=claude-code\u001b\\'; exec sleep 600","exited":false,"exit_status":null,"is_held":false,"pane_x":0,"pane_content_x":0,"pane_y":1,"pane_content_y":1,"pane_rows":48,"pane_content_rows":48,"pane_columns":50,"pane_content_columns":50,"terminal_command":"/bin/sh -c printf '\u001b]7501;state=working:app=claude-code\u001b\\'; exec sleep 600","plugin_url":null,"is_selectable":true,"index_in_pane_group":{},"default_fg":null,"default_bg":null,"nested_session_name":null,"attention":{"status":"Working","source":"ProgramStatus","text":"working","detail":{"kind":null,"progress":null,"app":"claude-code","title":null,"body":null,"exit_code":null,"duration_ms":null,"command":null},"since_ms":1794484886663,"changed_ms":1794484886663,"seen":false,"muted":null,"ignore_output":false,"watched":false,"from_watch":false,"remembered":{"status":"Working","text":"working","since_ms":1794484886663}},"command_state":{"phase":"Unknown","running":null,"last":null,"cwd":null,"reports_markers":false},"program_status":[{"id":null,"state":"Working","kind":null,"progress":null,"app":"claude-code","title":null,"msg":null,"updated_ms":1794484886663}],"tab_id":0,"tab_position":0,"tab_name":"Tab #1","pane_command":"sleep 600","pane_cwd":"/tmp/zjsw-156750"}]
        """#

    static let capturedFrame =
        "\u{1E}B\nfixture [Created] \n\u{1E}P\n\u{1E}Sfixture\n" + capturedPanes + "\n\u{1E}H\n\u{1E}E\n"

    static func frame(panes: String = capturedPanes, document: String? = nil) -> ZellijFrame {
        var parser = ZellijFrameParser()
        let text =
            "\u{1E}B\nfixture [Created] \nclosed [Created] (EXITED - attach to resurrect)\n\u{1E}P\n\u{1E}Sfixture\n"
            + panes + "\n\u{1E}H\n" + (document.map { $0 + "\n" } ?? "") + "\u{1E}E\n"
        return parser.feed(Data(text.utf8)).frames.first ?? ZellijFrame()
    }

    static func document(status: String = "working", kind: String = "codex", updated: Int64 = 100)
        -> ZellijPaneState?
    {
        ZellijPaneState.decode(
            Data(
                """
                {"version":1,"pane":"zellij:fixture/terminal_0","kind":"\(kind)","status":"\(status)","seq":3,"session":"/tmp/agent.jsonl","launch":"w-exact","updated_ms":\(updated)}
                """.utf8))
    }
}
