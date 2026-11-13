import Foundation
import Testing

@testable import Waycar

@Suite("tmux command builders")
struct TmuxCommandTests {
    /// Text that would break out of naive quoting: separators, both quote
    /// kinds, expansions, backslashes, line breaks, formats, a leading
    /// dash, a leading tilde, emoji and CJK.
    static let hostile = [
        "a ; kill-server",
        ";",
        "it's \"quoted\"",
        "$HOME ${HOME} $(id)",
        "back\\slash\\",
        "line\nkill-server",
        "cr\rkill-server",
        "#{session_name} #(touch /tmp/x)",
        "-x",
        "~/notes",
        "🚀 emoji",
        "漢字かな",
        "'",
        "\\'",
        "",
    ]

    // MARK: Quoting

    @Test func singleQuotingWritesQuotesAsEscapedQuote() {
        #expect(TmuxCommand.singleQuoted("plain") == "'plain'")
        #expect(TmuxCommand.singleQuoted("it's") == "'it'\\''s'")
        #expect(TmuxCommand.singleQuoted("") == "''")
        #expect(TmuxCommand.singleQuoted("$HOME ~ ; #{x}") == "'$HOME ~ ; #{x}'")
    }

    @Test func draftQuotingEscapesEverythingTmuxExpands() {
        #expect(TmuxCommand.doubleQuotedDraft("a\\b\"c$d~e") == "\"a\\\\b\\\"c\\$d\\~e\"")
        #expect(TmuxCommand.doubleQuotedDraft("~/x and ~y") == "\"\\~/x and \\~y\"")
        // NUL would end tmux's C-string argument there; it is dropped.
        #expect(TmuxCommand.doubleQuotedDraft("one\ntwo\r\0three") == "\"one\\ntwo\\rthree\"")
        #expect(TmuxCommand.doubleQuotedDraft("; #{x} 'q' 漢🚀") == "\"; #{x} 'q' 漢🚀\"")
    }

    @Test func argumentsStayOneLineWhateverTheyHold() {
        for text in Self.hostile {
            let quoted = TmuxCommand.argument(text)
            #expect(!quoted.contains("\n") && !quoted.contains("\r"), "\(text)")
            #expect(Self.unquote(quoted) == text, "\(text)")
        }
        #expect(TmuxCommand.argument("x\ny") == "\"x\\ny\"")
        #expect(TmuxCommand.argument("it's") == "'it'\\''s'")
    }

    @Test func formatLiteralsDoubleEveryHash() {
        #expect(TmuxCommand.formatLiteral("#{session_name} #(id) ##") == "'##{session_name} ##(id) ####'")
        #expect(TmuxCommand.formatLiteral("a\n#b") == "\"a\\n##b\"")
    }

    @Test func targetsKeepPaneAndWindowIdsBareAndQuoteTheRest() {
        #expect(TmuxCommand.target("%3") == "%3")
        #expect(TmuxCommand.target("@12") == "@12")
        #expect(TmuxCommand.target("$1") == "'$1'")
        #expect(TmuxCommand.target("$1:") == "'$1:'")
        #expect(TmuxCommand.target("%if") == "'%if'")
        #expect(TmuxCommand.target("%3 ; kill-server") == "'%3 ; kill-server'")
    }

    // MARK: Builders

    @Test func draftDeliveryMatchesTheVerifiedLine() {
        let line = [
            TmuxCommand.setBuffer(name: "waycar-1f2e", text: "fix ~/x for $USER\n\"now\""),
            TmuxCommand.pasteBuffer(name: "waycar-1f2e", target: "%7"),
            TmuxCommand.sendKeys(target: "%7", keys: ["Enter"]),
        ].joined(separator: " ; ")
        #expect(line == "set-buffer -b waycar-1f2e -- \"fix \\~/x for \\$USER\\n\\\"now\\\"\" ; "
            + "paste-buffer -p -d -b waycar-1f2e -t %7 ; send-keys -t %7 Enter")
    }

    @Test func sendKeysVariants() {
        #expect(TmuxCommand.sendKeys(target: "%1", keys: ["C-c", "M-x", "F12"])
            == "send-keys -t %1 C-c M-x F12")
        #expect(TmuxCommand.sendKeys(target: "%1", keys: ["-X"]) == "send-keys -t %1 -- '-X'")
        #expect(TmuxCommand.sendKeys(target: "%1", keys: [";"]) == "send-keys -t %1 ';'")
        #expect(TmuxCommand.sendKeysHex(target: "%1", bytes: [0x1B, 0x5B, 0x41, 0x0A])
            == "send-keys -t %1 -H 1b 5b 41 0a")
        #expect(TmuxCommand.sendKeysLiteral(target: "%1", text: "it's ; fine")
            == "send-keys -l -t %1 -- 'it'\\''s ; fine'")
        #expect(TmuxCommand.sendKeysLiteral(target: "%1", text: "a\nb")
            == "send-keys -l -t %1 -- \"a\\nb\"")
    }

    @Test func paneWindowAndSessionCommands() {
        #expect(TmuxCommand.capturePane(target: "%4", lines: 200) == "capture-pane -p -J -S -200 -t %4")
        #expect(TmuxCommand.capturePane(target: "%4", lines: -5) == "capture-pane -p -J -S -0 -t %4")
        #expect(TmuxCommand.killPane(target: "%4") == "kill-pane -t %4")
        #expect(TmuxCommand.killWindow(target: "@2") == "kill-window -t @2")
        #expect(TmuxCommand.selectWindow(target: "@2") == "select-window -t @2")
        #expect(TmuxCommand.renameWindow(target: "@2", name: "build #1")
            == "rename-window -t @2 -- 'build ##1'")
        #expect(TmuxCommand.renameSession(target: "$3", name: "-proj; x")
            == "rename-session -t '$3' -- '-proj; x'")
    }

    @Test func paneOptions() {
        #expect(TmuxCommand.setPaneOption(target: "%2", name: "@waycar_status", value: "working")
            == "set -p -t %2 -- @waycar_status 'working'")
        #expect(TmuxCommand.setPaneOption(target: "%2", name: "@k", value: "-v\n#{x}")
            == "set -p -t %2 -- @k \"-v\\n#{x}\"")
        #expect(TmuxCommand.unsetPaneOption(target: "%2", name: "@waycar_status")
            == "set -p -u -t %2 -- @waycar_status")
    }

    @Test func displayAndSubscribe() {
        #expect(TmuxCommand.display(format: "#{version}") == "display -p '#{version}'")
        #expect(TmuxCommand.display(format: "#{@waycar_status}", target: "%1")
            == "display -p -t %1 '#{@waycar_status}'")
        #expect(TmuxCommand.subscribe(name: "wc-status", format: "#{S:#{pane_id}\u{241F}\u{241E}}")
            == "refresh-client -B 'wc-status::#{S:#{pane_id}\u{241F}\u{241E}}'")
    }

    @Test func newWindowQuotesEveryUserString() {
        let wrapper = TmuxCommand.loginShellWrapper(agentCommand: "claude")
        let command = TmuxCommand.newWindow(
            sessionTarget: "$1",
            cwd: "/srv/my #1 repo",
            name: "fix ; it's",
            environment: ["WAYCAR_SHELL": "1", "A": "$HOME"],
            command: wrapper,
            printFormat: "#{pane_id}\u{241F}#{window_id}")
        #expect(command == "new-window -d -t '$1:' -c '/srv/my ##1 repo' -n 'fix ; it'\\''s' "
            + "-e 'A=$HOME' -e 'WAYCAR_SHELL=1' -P -F '#{pane_id}\u{241F}#{window_id}' "
            + "-- 'exec \"$SHELL\" -lic '\\''claude; exec \"$SHELL\" -l'\\'''")
        #expect(TmuxCommand.newWindow(sessionTarget: "$1", printFormat: "#{pane_id}")
            == "new-window -d -t '$1:' -P -F '#{pane_id}'")
    }

    @Test func newSessionQuotesEveryUserString() {
        #expect(TmuxCommand.newSession(
            name: "~/proj #(id)", cwd: "~/proj", environment: ["WAYCAR_SHELL": "1"],
            printFormat: "#{session_id}")
            == "new-session -d -s '~/proj ##(id)' -c '~/proj' -e 'WAYCAR_SHELL=1' -P -F '#{session_id}'")
        #expect(TmuxCommand.newSession(name: "a", command: "codex", printFormat: "#{pane_id}")
            == "new-session -d -s 'a' -P -F '#{pane_id}' -- 'codex'")
    }

    @Test func loginShellWrapperQuotesTheAgentCommandForTheShell() {
        #expect(TmuxCommand.loginShellWrapper(agentCommand: "claude --resume abc")
            == "exec \"$SHELL\" -lic 'claude --resume abc; exec \"$SHELL\" -l'")
        #expect(TmuxCommand.loginShellWrapper(agentCommand: "echo 'hi'")
            == "exec \"$SHELL\" -lic 'echo '\\''hi'\\''; exec \"$SHELL\" -l'")
    }

    /// Each builder with every user-string slot fed the same text.
    static let builders: [@Sendable (String) -> String] = [
        { TmuxCommand.setBuffer(name: "b", text: $0) },
        { TmuxCommand.sendKeysLiteral(target: "%1", text: $0) },
        { TmuxCommand.renameWindow(target: "@1", name: $0) },
        { TmuxCommand.renameSession(target: "$1", name: $0) },
        { TmuxCommand.setPaneOption(target: "%1", name: "@k", value: $0) },
        { TmuxCommand.display(format: $0) },
        {
            TmuxCommand.newWindow(
                sessionTarget: "$1", cwd: $0, name: $0, environment: ["K": $0],
                command: $0, printFormat: "#{pane_id}")
        },
        { TmuxCommand.newSession(name: $0, cwd: $0, command: $0, printFormat: "#{session_id}") },
    ]

    @Test func hostileStringsNeverLeaveTheirWord() {
        for build in Self.builders {
            // Slots are the words that change with the text; a slot whose
            // `#` comes back doubled is format-expanded by tmux.
            let plain = Self.words(build("x"))
            let other = Self.words(build("y"))
            let hashed = Self.words(build("#"))
            for text in Self.hostile {
                let command = build(text)
                #expect(!command.contains("\n") && !command.contains("\r"), "\(command)")
                let words = Self.words(command)
                #expect(words.count == plain.count, "\(command)")
                guard words.count == plain.count else { continue }
                for index in plain.indices {
                    guard plain[index] != other[index] else {
                        #expect(words[index] == plain[index], "\(command)")
                        continue
                    }
                    let slotText = hashed[index].contains("##")
                        ? text.replacingOccurrences(of: "#", with: "##") : text
                    let expected = plain[index].replacingOccurrences(of: "x", with: slotText)
                    #expect(words[index] == expected, "\(command)")
                }
            }
        }
    }

    // MARK: Replay

    /// What may go out again after tmux's `%exit` left a line unanswered
    /// (T24): Waycar's reads, kills, renames, selects and option sets, never
    /// input, pastes, creation or pane moves (ADR 0018).
    @Test func onlyIdempotentCommandsMayGoOutAgain() throws {
        let idempotent =
            [
                TmuxInventory.listSessionsCommand, TmuxInventory.listWindowsCommand,
                TmuxInventory.listPanesCommand,
                TmuxCommand.capturePane(target: "%4", lines: 200),
                TmuxCommand.display(format: "#{version}", target: "%4"),
                TmuxCommand.killPane(target: "%4"),
                TmuxCommand.killWindow(target: "@2"),
                TmuxCommand.renameWindow(target: "@2", name: "build"),
                TmuxCommand.renameSession(target: "$1", name: "work"),
                TmuxCommand.focusDoneToIdle(paneTarget: "%4"),
            ] + TmuxTransport.layoutCommands(window: "@2")
            + TmuxTransport.focusCommands(pane: "%4")
        let never = [
            TmuxCommand.setBuffer(name: "waycar-1", text: "hi"),
            TmuxCommand.pasteBuffer(name: "waycar-1", target: "%4"),
            TmuxCommand.sendKeys(target: "%4", keys: ["Enter"]),
            TmuxCommand.sendKeysHex(target: "%4", bytes: [0x1b]),
            TmuxCommand.sendKeysLiteral(target: "%4", text: "ls"),
            TmuxCommand.newWindow(sessionTarget: "$1", printFormat: "#{pane_id}"),
            TmuxCommand.newSession(name: "work", printFormat: "#{session_id}"),
            TmuxTransport.breakPaneCommand(pane: "%4", sessionTarget: "$1", name: nil),
            try TmuxTransport.joinPaneCommand(pane: "%4", target: "@2", split: .right, ratio: nil),
            TmuxCommand.subscribe(name: "wc-topo", format: "#{session_id}"),
        ]
        for command in idempotent {
            #expect(TmuxCommand.isIdempotent(command), "\(command)")
        }
        for command in never {
            #expect(!TmuxCommand.isIdempotent(command), "\(command)")
        }
    }

    // MARK: A tmux-style tokenizer for the assertions

    /// Splits a control line into words the way tmux's parser does for the
    /// subset the builders emit: whitespace-separated, single quotes
    /// literal, double quotes with `\` escapes, `\'` outside quotes.
    static func words(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var iterator = Array(line).makeIterator()
        func escape(_ character: Character) -> String {
            switch character {
            case "n": "\n"
            case "r": "\r"
            default: String(character)
            }
        }
        while let character = iterator.next() {
            switch character {
            case " ":
                if inWord { words.append(current); current = ""; inWord = false }
            case "'":
                inWord = true
                while let next = iterator.next(), next != "'" { current.append(next) }
            case "\"":
                inWord = true
                while let next = iterator.next(), next != "\"" {
                    if next == "\\", let escaped = iterator.next() {
                        current += escape(escaped)
                    } else {
                        current.append(next)
                    }
                }
            case "\\":
                inWord = true
                if let next = iterator.next() { current.append(next) }
            default:
                inWord = true
                current.append(character)
            }
        }
        if inWord { words.append(current) }
        return words
    }

    static func unquote(_ word: String) -> String? {
        let parsed = words(word)
        return parsed.count == 1 ? parsed[0] : (word == "''" ? "" : nil)
    }
}
