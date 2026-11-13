import Foundation
import Testing

@testable import Waycar

@Suite("Zellij command builders")
struct ZellijCommandTests {
    @Test func commandsQuoteAllArgvData() throws {
        let command = try ZellijCommand(zellij: "/opt/my tools/zellij")
        let pane = try #require(ZellijPaneID(session: "my 'project $x", pane: 12))
        let prefix = "'/opt/my tools/zellij' " + ShellWord.quoted("-s=" + pane.session) + " action "
        #expect(command.listClients(session: pane.session) == prefix + "list-clients")
        #expect(command.listPanes(session: pane.session) == prefix + "list-panes -j")
        #expect(command.dumpScreen(pane, full: true) == prefix + "dump-screen --pane-id terminal_12 --full")
        let text = "-flag 'quoted' $HOME\nnew line"
        let paste = try command.paste(pane, text: text)
        let pasteScript = prefix + "paste --pane-id terminal_12 -- \"$(cat)\""
        #expect(paste.command == "/bin/sh -c " + ShellWord.quoted(pasteScript))
        #expect(paste.input == Data(text.utf8))
        #expect(!paste.command.contains(text))
        #expect(
            try command.sendKeys(pane, keys: ["ctrl+c", "+", "\""]) == prefix
                + "send-keys --pane-id terminal_12 -- 'Ctrl c' + " + ShellWord.quoted("\""))
        let submitted = try command.pasteAndEnter(pane, text: text)
        #expect(submitted.input == paste.input)
        let submitScript = pasteScript + " && " + (try command.sendKeys(pane, keys: ["enter"]))
        #expect(submitted.command == "/bin/sh -c " + ShellWord.quoted(submitScript))
        #expect(command.closePane(pane) == prefix + "close-pane --pane-id terminal_12")
        #expect(command.closeTab(session: pane.session, tabID: 7) == prefix + "close-tab --tab-id 7")
        #expect(
            command.renamePane(pane, name: "-name $'") == prefix + "rename-pane --pane-id terminal_12 -- "
                + ShellWord.quoted("-name $'"))
        #expect(
            command.renameTab(session: pane.session, tabID: 7, name: "-name") == prefix
                + "rename-tab-by-id 7 -- -name")
        #expect(command.deleteSession(name: "-name") == "'/opt/my tools/zellij' delete-session -- -name")
        #expect(command.listSessions() == "'/opt/my tools/zellij' ls -n")
        #expect(command.listSessions(namesOnly: true).hasSuffix("ls -s"))
    }

    @Test func creationAndAttach() throws {
        let command = try ZellijCommand(zellij: "/bin/zellij")
        let pane = try #require(ZellijPaneID(session: "work", pane: 1))
        let line = "env WAYCAR_LAUNCH=w-tag claude 'hello $world'"
        let newTab = command.newTab(session: "work", name: "-agent", cwd: "/my folder", line: line)
        #expect(
            newTab
                == "/bin/zellij -s=work action new-tab --no-focus --name=-agent '--cwd=/my folder' -- /bin/sh -c "
                + ShellWord.quoted(line) + " && /bin/zellij -s=work action list-panes -j")
        #expect(
            command.backgroundSession(name: "work", cwd: "/my folder", line: line)
                == "cd '/my folder' && /bin/zellij attach -b work -- /bin/sh -c " + ShellWord.quoted(line))
        #expect(ZellijCommand.uniqueSessionName("work", listing: "work\nwork-2\nwork-3\n") == "work-4")
        #expect(command.attach(session: "my work").contains("options --default-mode normal"))
        let customClaim = ZellijAttachMachine.Claim(mode: "session", bytes: [0x1B], settle: .seconds(1))
        #expect(
            command.attach(session: "my work", claim: customClaim).contains("options --default-mode session"))
        #expect(command.attach(session: "my work").contains(AttachBootstrapHandshake.markerPrintfFormat))
        #expect(command.attach(session: "work").contains("list-panes -j >/dev/null 2>&1"))
        #expect(command.attach(session: "work").contains("exit 125"))
        #expect(!command.resumeSession(name: "work").contains("list-panes"))
        let navigation = command.navigate(pane, tabID: 7)
        #expect(navigation.contains("list-clients; /bin/zellij -s=work action go-to-tab-by-id 7"))
        #expect(navigation.contains("focus-pane-id -- terminal_1"))
        #expect(navigation.contains("printf '\\036Cafter\\n'"))
        #expect(!navigation.contains("&&"))
        #expect(
            command.restore(session: "work", tabID: 2, rawPane: "plugin_4").hasSuffix(
                "focus-pane-id -- plugin_4"))
    }

    @Test func restorationChecksTabNavigationBeforeAcceptingAlreadyFocused() throws {
        let command = try ZellijCommand(zellij: "/bin/zellij")
        let script = "/bin/zellij -s=work action go-to-tab-by-id 7 || exit $?; "
            + "/bin/zellij -s=work action focus-pane-id -- terminal_1; "
            + "r=$?; [ \"$r\" = 0 ] || [ \"$r\" = 2 ]"
        #expect(command.restoreChecked(session: "work", tabID: 7, rawPane: "terminal_1")
            == "/bin/sh -c " + ShellWord.quoted(script))
    }

    @Test func launchUsesSharedBuilderAndLoginShell() async throws {
        let request = AgentLaunchRequest(
            kind: "codex", name: "test", arguments: ["hello $world"], environment: ["CONFIG": "my value"])
        let line = try await ZellijCommand.launchLine(
            request: request, tag: "w-tag", codexSupportsNoDaemon: { true })
        #expect(line.hasPrefix("env WAYCAR_LAUNCH=w-tag /bin/sh -c "))
        #expect(line.contains("--no-daemon"))
        #expect(line.contains("-lic"))
        #expect(line.contains("CONFIG=my value"))
        #expect(ZellijLaunchReconciliation.carries(tag: "w-tag", command: line))
        #expect(
            ZellijCommand.shellLaunchLine(tag: "w-tag")
                == "env WAYCAR_LAUNCH=w-tag WAYCAR_SHELL=1 \"$SHELL\" -l")
    }

    @Test func backgroundNamesAreSafeAndUnique() throws {
        #expect(ZellijCommand.backgroundSessionName("-agent\nname/one") == "agent-name-one")
        #expect(ZellijCommand.backgroundSessionName("---\t/") == "agent")
        #expect(ZellijCommand.uniqueSessionName("--agent", listing: "agent\nagent-2\n") == "agent-3")
        let command = try ZellijCommand(zellij: "/bin/zellij")
        #expect(
            command.backgroundSession(name: "--", cwd: "/tmp", line: "sleep 3").contains("attach -b agent --")
        )
    }

    @Test func draftLimitAndWatchContract() throws {
        let command = try ZellijCommand(zellij: "/bin/zellij")
        let pane = try #require(ZellijPaneID("zellij:work/terminal_0"))
        #expect(throws: ZellijCommand.InputError.self) {
            try command.paste(pane, text: String(repeating: "é", count: 51201))
        }
        #expect(try command.paste(pane, text: String(repeating: "a", count: 102400)).input.count == 102400)
        let quoted = try command.paste(pane, text: String(repeating: "'", count: 40 * 1024))
        #expect(quoted.input.count == 40 * 1024)
        #expect(quoted.command.utf8.count < 1024)
        let watch = ZellijWatchCommand.script(
            zellij: "/my 'tools/zellij", stateDirectory: "/home/my state/$x")
        #expect(watch.hasPrefix("/bin/sh -c "))
        #expect(watch.contains("cat >/dev/null"))
        #expect(watch.contains("delay=2"))
        #expect(watch.contains("grep -v"))
        #expect(!watch.contains("\\|"))
        #expect(!watch.contains("sed -E"))
        #expect(watch.contains("tr -d"))
        #expect(watch.contains("kill 0"))
        let normalization = #"s/^\(.*\) \[Created [^]][^]]* ago\] (current) *$/\1 [Created] (current)/p"#
        #expect(watch.contains(normalization))
        let liveName = #"sed 's/ \[Created\]\( (current)\)\{0,1\} *$//'"#
        #expect(watch.contains(liveName.replacingOccurrences(of: "'", with: #"'\''"#)))
    }
}
