import Foundation

/// Control-mode transcripts recorded from tmux 3.7c (Homebrew) on private
/// `-L` servers started with `-f /dev/null`, read from a `tmux -C attach`
/// child's stdout pipe. Each constant is one recording, line by line, LF
/// terminated; control bytes are escaped. Times, command numbers and ids are
/// whatever the server printed.
enum TmuxTranscripts {
    /// Attach with `-f no-output,no-detach-on-destroy -t alpha`: the attach
    /// command's own flags-0 block, then the notifications the attach and the
    /// shell's rc file (a transient tmux window) cause.
    static let attach = transcript([
        "%begin 1790879596 289 0",
        "%end 1790879596 289 0",
        "%session-changed $0 alpha",
        "%unlinked-window-add @2",
        "%sessions-changed",
        "%unlinked-window-renamed @2 tmux",
        "%unlinked-window-close @2",
        "%sessions-changed",
        "%unlinked-window-renamed @1 zsh",
    ])

    /// `display -p '#{version} #{client_flags}'` and the three list commands on
    /// one control line, records framed with ␞ (U+241E) and fields with ␟
    /// (U+241F), as Waycar's formats print them.
    static let startup = transcript([
        "%begin 1790879596 310 1",
        "3.7c attached,focused,control-mode,no-detach-on-destroy,no-output,UTF-8",
        "%end 1790879596 310 1",
        "%begin 1790879596 311 1",
        "\u{241E}$0\u{241F}\u{241F}alpha",
        "\u{241E}$1\u{241F}\u{241F}beta",
        "%end 1790879596 311 1",
        "%begin 1790879596 312 1",
        "\u{241E}@0\u{241F}$0\u{241F}zsh",
        "\u{241E}@1\u{241F}$1\u{241F}zsh",
        "%end 1790879596 312 1",
        "%begin 1790879596 313 1",
        "\u{241E}%0\u{241F}@0\u{241F}$0\u{241F}zsh",
        "\u{241E}%1\u{241F}@1\u{241F}$1\u{241F}zsh",
        "%end 1790879596 313 1",
    ])

    /// `kill-pane -t %999`, `display -p 'ok'`, then `kill-window -t @999 ;
    /// kill-session -t '$999'`: the failed first command of a line drops the
    /// rest of that line, so the last line answers with one block.
    static let errors = transcript([
        "%unlinked-window-renamed @1 zsh",
        "%begin 1790879633 324 1",
        "can't find pane: %999",
        "%error 1790879633 324 1",
        "%begin 1790879633 325 1",
        "ok",
        "%end 1790879633 325 1",
        "%begin 1790879634 326 1",
        "can't find window: @999",
        "%error 1790879634 326 1",
    ])

    /// `kill-pane -t %999 ; bogus-command`: a parse error rejects the whole
    /// line in one block.
    static let parseError = transcript([
        "%begin 1790879634 327 1",
        "parse error: unknown command: bogus-command",
        "%error 1790879634 327 1",
    ])

    /// `tmux -C attach` against a server with no sessions: the attach's own
    /// error block, then `%exit`.
    static let noSessions = transcript([
        "%begin 1790879877 280 0",
        "no sessions",
        "%error 1790879877 280 0",
        "%exit",
    ])

    /// `refresh-client -B 'wc-status::#{S:#{W:#{P:#{pane_id}␟#{@waycar_status}␟
    /// #{@waycar_agent}␞}}}'`, then `set -p @waycar_status working` and
    /// `@waycar_agent claude` from outside.
    static let subscription = transcript([
        "%begin 1790879598 315 1",
        "%end 1790879598 315 1",
        "%subscription-changed wc-status $0 - - - : %0\u{241F}\u{241F}\u{241E}%1\u{241F}\u{241F}\u{241E}",
        "%subscription-changed wc-status $0 - - - : %0\u{241F}working\u{241F}claude\u{241E}%1\u{241F}\u{241F}\u{241E}",
    ])

    /// new-window, rename-window, split-window and kill-window in the attached
    /// session, run from another client.
    static let attachedSessionWindows = transcript([
        "%window-add @3",
        "%window-renamed @3 build two",
        "%layout-change @0 4197,80x24,0,0[80x12,0,0,0,80x11,0,13,4] 4197,80x24,0,0[80x12,0,0,0,80x11,0,13,4] *",
        "%unlinked-window-close @3",
        "%unlinked-window-add @4",
        "%sessions-changed",
        "%unlinked-window-renamed @4 tmux",
        "%unlinked-window-close @4",
        "%sessions-changed",
        "%subscription-changed wc-status $0 - - - : %0\u{241F}working\u{241F}claude\u{241E}%4\u{241F}\u{241F}\u{241E}%1\u{241F}\u{241F}\u{241E}",
    ])

    /// new-window, rename-window and kill-window in a session the control
    /// client is not attached to.
    static let otherSessionWindows = transcript([
        "%unlinked-window-add @5",
        "%unlinked-window-renamed @5 logs two",
        "%unlinked-window-close @5",
    ])

    /// new-session, rename-session and kill-session from another client.
    static let sessions = transcript([
        "%unlinked-window-add @6",
        "%sessions-changed",
        "%unlinked-window-renamed @6 tmux",
        "%session-renamed $4 gamma two",
        "%sessions-changed",
        "%unlinked-window-close @6",
    ])

    /// select-window, split-window and select-pane in the attached session from
    /// another client.
    static let focus = transcript([
        "%session-window-changed $0 @2",
        "%layout-change @2 c19f,80x24,0,0[80x12,0,0,2,80x11,0,13,5] c19f,80x24,0,0[80x12,0,0,2,80x11,0,13,5] *",
        "%window-pane-changed @2 %5",
        "%unlinked-window-add @5",
        "%sessions-changed",
        "%unlinked-window-renamed @5 tmux",
        "%unlinked-window-close @5",
        "%sessions-changed",
    ])

    /// `switch-client -t beta` on the control client.
    static let switchClient = transcript([
        "%begin 1790879638 352 1",
        "%end 1790879638 352 1",
        "%session-changed $1 beta",
    ])

    /// set-buffer and delete-buffer from another client.
    static let pasteBuffers = transcript([
        "%paste-buffer-changed wcbuf",
        "%paste-buffer-deleted wcbuf",
    ])

    /// A second client switching session and detaching.
    static let otherClient = transcript([
        "%client-session-changed client-88691 $0 alpha",
        "%client-detached client-88691",
    ])

    /// A control client attached without `no-output`: a shell echoing a typed
    /// printf, then its output (tab, SGR escapes, UTF-8 and a backslash).
    static let output = transcript([
        "%output %1 p\\010printf 'tab\\134",
        "%output %1 th",
        "%output %1 er",
        "%output %1 e ",
        "%output %1 \\1340",
        "%output %1 3",
        "%output %1 3[",
        "%output %1 1",
        "%output %1 m",
        "%output %1 bo",
        "%output %1 l",
        "%output %1 d \\015\\033[K\\134",
        "%output %1 \\015\\1340",
        "%output %1 3",
        "%output %1 3",
        "%output %1 [",
        "%output %1 0",
        "%output %1 m ",
        "%output %1 caf",
        "%output %1 \\134",
        "%output %1 30",
        "%output %1 3\\134",
        "%output %1 25",
        "%output %1 1 ",
        "%output %1 ba",
        "%output %1 ck",
        "%output %1 \\134\\134",
        "%output %1 s",
        "%output %1 l",
        "%output %1 as",
        "%output %1 h",
        "%output %1 \\134",
        "%output %1 n",
        "%output %1 '",
        "%output %1 \\033[?2004l\\015\\015\\012",
        "%output %1 tab\\011here \\033[1mbold\\033[0m café back\\134slash\\015\\012",
    ])

    /// A control client attached with `-f pause-after=1`: output arrives as
    /// `%extended-output`.
    static let extendedOutput = transcript([
        "%extended-output %0 0 : s\\010sleep 1.5; ye",
        "%extended-output %0 0 : s ",
        "%extended-output %0 0 : | he",
        "%extended-output %0 0 : ad",
        "%extended-output %0 0 :  ",
        "%extended-output %0 0 : -",
        "%extended-output %0 0 : c",
        "%extended-output %0 0 :  ",
        "%extended-output %0 0 : 4",
        "%extended-output %0 0 : 0",
        "%extended-output %0 0 : 0",
        "%extended-output %0 0 : 0 \\015",
        "%extended-output %0 0 : \\033[",
        "%extended-output %0 0 : K0\\015000",
        "%extended-output %0 0 : \\033[?2004l\\015\\015\\012",
    ])

    /// `kill-server` from another client.
    static let killServer = transcript([
        "%sessions-changed",
        "%sessions-changed",
        "%exit",
    ])

    /// Attach to a server started with a config file holding an unknown command
    /// (pane output dropped).
    static let configError = transcript([
        "%begin 1790879613 283 0",
        "%config-error /tmp/wc-tmuxcore-5d94e5/bad.conf:2: unknown command: bogus-command",
        "%end 1790879613 283 0",
        "%session-changed $0 cfg",
        "%unlinked-window-add @1",
        "%sessions-changed",
        "%unlinked-window-renamed @1 tmux",
        "%unlinked-window-close @1",
        "%sessions-changed",
    ])

    /// The transcript as the bytes the control channel reads.
    static func data(_ transcript: String) -> Data {
        Data(transcript.utf8)
    }

    private static func transcript(_ lines: [String]) -> String {
        lines.map { $0 + "\n" }.joined()
    }
}
