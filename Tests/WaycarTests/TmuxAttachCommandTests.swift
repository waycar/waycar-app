import Foundation
import Testing

@testable import Waycar

@Suite("tmux attach command")
struct TmuxAttachCommandTests {
    private let target = TmuxAttachCommand.Target(sessionID: "$3", windowID: "@7", paneID: "%12")
    private let name = "waycar-0a1b2c3d"

    private static let chain = "tmux -u new-session -d -t '$3' -s 'waycar-0a1b2c3d' "
        + "\\; set-option -t 'waycar-0a1b2c3d' destroy-unattached on "
        + "\\; select-window -t 'waycar-0a1b2c3d:@7' "
        + "\\; select-pane -t '%12' "
        + "\\; attach -t 'waycar-0a1b2c3d'"

    /// `script` as `/bin/sh -c '…'` writes it, each `'` as `'\''`.
    private static func wrapped(_ script: String) -> String {
        "/bin/sh -c '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @Test func chainIsTheVerifiedGroupedSessionSequence() throws {
        #expect(try TmuxAttachCommand.chainShellCommand(target: target, attachSessionName: name)
            == Self.chain)
    }

    @Test func moshReceivesTheChainAsSeparateArguments() throws {
        #expect(try TmuxAttachCommand.chainArguments(target: target, attachSessionName: name) == [
            "tmux", "-u", "new-session", "-d", "-t", "$3", "-s", name, ";",
            "set-option", "-t", name, "destroy-unattached", "on", ";",
            "select-window", "-t", "\(name):@7", ";",
            "select-pane", "-t", "%12", ";",
            "attach", "-t", name,
        ])
    }

    @Test func ptyExecPrintsTheMarkerThenExecsTheChainWithTheHerdrPath() throws {
        let command = try TmuxAttachCommand.execCommand(target: target, attachSessionName: name)
        #expect(command == Self.wrapped(
            "\(HerdrHostPath.pathExport); "
                + "printf \"\(AttachBootstrapHandshake.markerPrintfFormat)\"; "
                + "exec \(Self.chain)"))
        // The account shell sees `$3` only inside single quotes.
        #expect(command.contains("-t '\\''$3'\\'' -s"))
        #expect(!command.contains(" -d -t $3"))
    }

    @Test func neverDetachesOtherClients() throws {
        let arguments = try TmuxAttachCommand.chainArguments(target: target, attachSessionName: name)
        let attach = try #require(arguments.lastIndex(of: "attach"))
        #expect(!arguments[attach...].contains("-d"))
    }

    @Test func fitToPhoneKeepsItsFullClient() throws {
        let command = try TmuxAttachCommand.chainShellCommand(
            target: target, attachSessionName: name)
        #expect(!command.contains("ignore-size"))
        #expect(!command.contains("read-only"))
        // Fit to phone keeps tmux's status line.
        #expect(!command.contains("status"))
        #expect(command.hasSuffix("\\; attach -t 'waycar-0a1b2c3d'"))
    }

    @Test func idsThatAreNotTmuxsOwnAreRejected() {
        let bad = [
            TmuxAttachCommand.Target(sessionID: "main", windowID: "@7", paneID: "%12"),
            TmuxAttachCommand.Target(sessionID: "$3'", windowID: "@7", paneID: "%12"),
            TmuxAttachCommand.Target(sessionID: "$3", windowID: "@7;x", paneID: "%12"),
            TmuxAttachCommand.Target(sessionID: "$3", windowID: "@7", paneID: "%"),
            TmuxAttachCommand.Target(sessionID: "$3", windowID: "7", paneID: "%12"),
        ]
        for target in bad {
            #expect(throws: TransportError.self) {
                try TmuxAttachCommand.execCommand(target: target, attachSessionName: name)
            }
        }
        for badName in ["waycar-0A1B2C3D", "waycar-0a1b2c3", "other-0a1b2c3d", "waycar-0a1b2c3d'"] {
            #expect(throws: TransportError.self) {
                try TmuxAttachCommand.execCommand(target: target, attachSessionName: badName)
            }
        }
    }

    @Test func attachSessionNamesAreWaycarPlusEightLowercaseHex() {
        for _ in 0..<50 {
            let generated = TmuxAttachCommand.makeAttachSessionName()
            #expect(generated.count == 15)
            #expect(TmuxAttachCommand.isAttachSessionName(generated), "\(generated)")
        }
        #expect(!TmuxAttachCommand.isAttachSessionName("waycar-main"))
        #expect(!TmuxAttachCommand.isAttachSessionName("main"))
    }
}
