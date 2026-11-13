import Foundation
@testable import GhosttyTerminal
import Testing
import UIKit

@testable import Waycar

/// Link taps and touch selection against the live Ghostty surface: what a tap
/// finds, and that neither reaches a program that captured the mouse.
@MainActor
@Suite(.serialized)
struct TerminalTouchInteractionTests {
    private static let longURL =
        "https://example.com/" + String(repeating: "abcdefghij", count: 6) + "/end"

    @Test func tapsOpenLinksWhoseTextIsTheirTarget() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        terminal.onPreviewFile = { _ in }
        terminal.onConfirmLink = { _ in }
        try await show(terminal)
        let grid = try geometry(terminal)

        // Row 0 wraps into row 1 (60 columns); the sentence's full stop is
        // not part of the URL.
        let url = try #require(URL(string: Self.longURL))
        #expect(terminal.tapLink(at: grid.point(column: 6, row: 0)) == .openLink(.web(url)))
        #expect(terminal.tapAction(at: grid.point(column: 3, row: 1)) == .openLink(.web(url)))
        // "see " before it is plain text.
        #expect(terminal.tapLink(at: grid.point(column: 1, row: 0)) == nil)

        #expect(
            terminal.tapLink(at: grid.point(column: 7, row: 2))
                == .openLink(.file(TerminalFileReference(path: "src/foo/bar.swift", line: 12, column: 3))))
        #expect(
            terminal.tapLink(at: grid.point(column: 36, row: 2))
                == .openLink(.file(TerminalFileReference(path: "~/pic.png"))))
        #expect(terminal.tapLink(at: grid.point(column: 30, row: 2)) == nil)

        // An OSC 8 link whose text is its target is as good as a match.
        let same = try #require(URL(string: "https://same.example/y"))
        #expect(terminal.tapLink(at: grid.point(column: 4, row: 6)) == .openLink(.web(same)))

        // Found, but not a link this app opens.
        #expect(terminal.tapLink(at: grid.point(column: 2, row: 4)) == nil)
    }

    /// Remote output chooses both an OSC 8 link's text and its target. When
    /// they differ, or the target is a `file:` URL, a tap asks first.
    @Test func hiddenTargetsAreConfirmedNotOpened() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        terminal.onPreviewFile = { _ in }
        try await show(terminal)
        let grid = try geometry(terminal)
        let osc8 = try #require(URL(string: "https://osc8.example/x"))

        // Without a way to ask, such a link is plain text.
        #expect(terminal.tapLink(at: grid.point(column: 2, row: 3)) == nil)
        #expect(terminal.tapLink(at: grid.point(column: 9, row: 9)) == nil)

        terminal.onConfirmLink = { _ in }
        #expect(terminal.tapLink(at: grid.point(column: 2, row: 3)) == .confirmLink(.web(osc8)))
        #expect(terminal.tapLink(at: grid.point(column: 8, row: 3)) == nil)
        #expect(
            terminal.tapLink(at: grid.point(column: 2, row: 7))
                == .confirmLink(.file(TerminalFileReference(path: "/etc/hosts"))))
        // A `file:` URL drawn in full is still where it leads, not a path
        // the user can read as one.
        #expect(
            terminal.tapLink(at: grid.point(column: 9, row: 9))
                == .confirmLink(.file(TerminalFileReference(path: "/etc/hosts"))))
        // A link drawn over blank cells is not a target at all.
        #expect(terminal.tapLink(at: grid.point(column: 1, row: 8)) == nil)
        #expect(terminal.tapLink(at: grid.point(column: 4, row: 8)) == .confirmLink(.web(osc8)))
    }

    @Test func pathsStayTextWithoutAPreviewer() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        try await show(terminal)
        let grid = try geometry(terminal)

        #expect(terminal.tapLink(at: grid.point(column: 7, row: 2)) == nil)
        #expect(terminal.tapAction(at: grid.point(column: 7, row: 2)) == .report(raisesKeyboard: true))
    }

    /// `herdr terminal attach` repaints a pane by cursor moves, and agent
    /// TUIs wrap their own text, so a path longer than the row reaches
    /// Ghostty as fragments on rows with no wrap flag: its matcher sees the
    /// head alone, and a tail with no slash not at all. A tap on either
    /// previews the whole path; the head's own match is the fallback, while
    /// a tail cut mid-word names nothing of its own. A path that only ends
    /// at the edge keeps its own reading as the fallback.
    @Test func pathsBrokenAcrossRowsPreviewWhole() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        terminal.onPreviewFile = { _ in }
        terminal.layoutIfNeeded()
        try await settle()
        let columns = try #require(terminal.measuredGrid?.columns)
        // A shell's soft wrap as herdr draws it: "saved " and the path's head
        // to the last column, the tail placed at the next row's first.
        let shell = "/Users/me/src/app/" + String(repeating: "d", count: columns - 26) + "/shot.png"
        let shellHead = String(shell.prefix(columns - 6))
        // A TUI's own wrap: indented, and a cell in from the right edge.
        let tui = "~/pics/" + String(repeating: "e", count: columns - 14) + "/diagram.png"
        let tuiHead = String(tui.prefix(columns - 3))
        var output = "\u{1B}[?1049h\u{1B}[2J"
        output += "\u{1B}[1;1Hsaved \(shellHead)\u{1B}[2;1H\(shell.dropFirst(columns - 6)) done"
        output += "\u{1B}[4;1H  \(tuiHead)\u{1B}[5;3H\(tui.dropFirst(columns - 3))"
        output += "\u{1B}[7;\(columns - 11)H~/ok/end.png\u{1B}[8;1Hnext line"
        output += "\u{1B}[10;1Hls: shot.png  notes.txt  *.png\u{1B}[12;1Hsee `~/b.png` now\u{1B}[20;1H"
        terminal.receive(Data(output.utf8))
        try await settle()
        let grid = try geometry(terminal)
        #expect(shellHead.hasSuffix("/s") && tuiHead.hasSuffix("dia"))

        #expect(
            terminal.tapLink(at: grid.point(column: 2, row: 1))
                == .openLink(.file(TerminalFileReference(path: shell))))
        #expect(
            terminal.tapLink(at: grid.point(column: 20, row: 0))
                == .openLink(.file(TerminalFileReference(path: shell, fallbackPaths: [shellHead]))))
        #expect(
            terminal.tapLink(at: grid.point(column: 4, row: 4))
                == .openLink(.file(TerminalFileReference(path: tui))))
        #expect(
            terminal.tapLink(at: grid.point(column: columns - 4, row: 6))
                == .openLink(.file(TerminalFileReference(
                    path: "~/ok/end.pngnext", fallbackPaths: ["~/ok/end.png"]))))
        // "done", "next" and "line" are words, not continuations of anything.
        #expect(terminal.tapLink(at: grid.point(column: 9, row: 1)) == nil)
        #expect(terminal.tapLink(at: grid.point(column: 1, row: 7)) == nil)
        #expect(terminal.tapLink(at: grid.point(column: 6, row: 7)) == nil)

        // A bare media name is a file in the pane's directory; other bare
        // names, and a glob, stay words.
        #expect(
            terminal.tapLink(at: grid.point(column: 6, row: 9))
                == .openLink(.file(TerminalFileReference(path: "shot.png"))))
        #expect(terminal.tapLink(at: grid.point(column: 16, row: 9)) == nil)
        #expect(terminal.tapLink(at: grid.point(column: 27, row: 9)) == nil)
        // A Markdown code span's backticks are prose around the path, so it
        // opens without asking.
        #expect(
            terminal.tapLink(at: grid.point(column: 7, row: 11))
                == .openLink(.file(TerminalFileReference(path: "~/b.png"))))
    }

    /// A row joins the next only when its text ends within two cells of the
    /// edge, and a joined reading only when the tapped fragment could be part
    /// of a path: a rule under a path is a rule. A `file:` URL joined across
    /// rows is still asked about, and a path over three rows is read whole
    /// from its middle.
    @Test func rowJoinsNeedAPathFragmentAndAnEdge() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        terminal.onPreviewFile = { _ in }
        terminal.onConfirmLink = { _ in }
        terminal.layoutIfNeeded()
        try await settle()
        let columns = try #require(terminal.measuredGrid?.columns)
        let fileURL = "file:///tmp/" + String(repeating: "f", count: columns - 18) + "/shot.png"
        // Two blank cells after the text still reads as the edge; three do not.
        let slackTwo = "~/two/" + String(repeating: "t", count: columns - 20)
        let slackThree = "~/three/" + String(repeating: "t", count: columns - 20)
        let middle = "/" + String(repeating: "b", count: columns - 1)
        let long = "/Users/me/" + String(repeating: "a", count: columns - 10) + middle + "/deep/shot.png"
        var output = "\u{1B}[?1049h\u{1B}[2J"
        output += "\u{1B}[1;\(columns - 10)H~/sep/x.png\u{1B}[2;1H" + String(repeating: "-", count: columns)
        output += "\u{1B}[4;1Hsee \(fileURL.prefix(columns - 4))\u{1B}[5;1H\(fileURL.dropFirst(columns - 4))"
        output += "\u{1B}[7;\(columns - 1 - slackTwo.count)H\(slackTwo)\u{1B}[8;1Hb.png"
        output += "\u{1B}[10;\(columns - 2 - slackThree.count)H\(slackThree)\u{1B}[11;1H3.png"
        output += "\u{1B}[13;1H\(long.prefix(columns))\u{1B}[14;1H\(middle)"
        output += "\u{1B}[15;1H\(long.dropFirst(2 * columns))\u{1B}[20;1H"
        terminal.receive(Data(output.utf8))
        try await settle()
        let grid = try geometry(terminal)
        #expect(fileURL.dropFirst(columns - 4) == "hot.png")
        #expect(long.dropFirst(columns).hasPrefix(middle))

        #expect(terminal.tapLink(at: grid.point(column: 5, row: 1)) == nil)
        #expect(
            terminal.tapLink(at: grid.point(column: 2, row: 4))
                == .confirmLink(.file(TerminalFileReference(path: String(fileURL.dropFirst("file://".count))))))
        #expect(
            terminal.tapLink(at: grid.point(column: 2, row: 7))
                == .openLink(.file(TerminalFileReference(path: slackTwo + "b.png"))))
        #expect(
            terminal.tapLink(at: grid.point(column: 2, row: 10))
                == .openLink(.file(TerminalFileReference(path: "3.png"))))
        #expect(
            terminal.tapLink(at: grid.point(column: 5, row: 13))
                == .openLink(.file(TerminalFileReference(path: long, fallbackPaths: [middle]))))
    }

    /// A path Ghostty soft-wraps is one reading with its position, tapped on
    /// either row, and gains no fallback from the row join.
    @Test func softWrappedPathsKeepTheirPosition() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        terminal.onPreviewFile = { _ in }
        terminal.layoutIfNeeded()
        try await settle()
        let columns = try #require(terminal.measuredGrid?.columns)
        let path = "src/" + String(repeating: "w", count: columns) + "/bar.swift"
        terminal.receive(Data("\u{1B}[2J\u{1B}[Hsee \(path):12:3 now\r\n".utf8))
        try await settle()
        let grid = try geometry(terminal)

        let expected = TerminalTapAction.openLink(.file(TerminalFileReference(path: path, line: 12, column: 3)))
        #expect(terminal.tapLink(at: grid.point(column: 10, row: 0)) == expected)
        #expect(terminal.tapLink(at: grid.point(column: 3, row: 1)) == expected)
    }

    /// Rows are read as text, so a wide character before a path broken at
    /// the edge does not shift the run, from either row.
    @Test func aWideCharacterBeforeABrokenPathDoesNotShiftIt() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        terminal.onPreviewFile = { _ in }
        terminal.layoutIfNeeded()
        try await settle()
        let columns = try #require(terminal.measuredGrid?.columns)
        // 📷 and 完 take two cells each.
        let path = "/Users/me/" + String(repeating: "c", count: columns - 16) + "/shot.png"
        let head = String(path.prefix(columns - 3))
        var output = "\u{1B}[?1049h\u{1B}[2J"
        output += "\u{1B}[1;1H📷 \(head)\u{1B}[2;1H\(path.dropFirst(columns - 3))"
        output += "\u{1B}[4;1H完成 ~/c.png"
        terminal.receive(Data(output.utf8))
        try await settle()
        let grid = try geometry(terminal)
        #expect(!path.dropFirst(columns - 3).contains("/"))

        #expect(terminal.pathRun(at: grid.point(column: 12, row: 0))?.text == path)
        #expect(
            terminal.tapLink(at: grid.point(column: 2, row: 1))
                == .openLink(.file(TerminalFileReference(path: path))))
        #expect(terminal.pathRun(at: grid.point(column: 7, row: 3))?.text == "~/c.png")
    }

    /// A run continues onto at most ``UITerminalView/pathRunRowLimit`` rows
    /// either way from the tapped one.
    @Test func runsStopAtTheRowLimit() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        terminal.onPreviewFile = { _ in }
        terminal.layoutIfNeeded()
        try await settle()
        let columns = try #require(terminal.measuredGrid?.columns)
        let limit = UITerminalView.pathRunRowLimit
        var output = "\u{1B}[?1049h\u{1B}[2J"
        for row in 0 ... limit + 1 {
            output += "\u{1B}[\(row + 1);1H" + String(repeating: "\(row % 10)", count: columns)
        }
        terminal.receive(Data(output.utf8))
        try await settle()
        let grid = try geometry(terminal)
        let rows = (0 ... limit + 1).map { String(repeating: "\($0 % 10)", count: columns) }

        #expect(terminal.pathRun(at: grid.point(column: 3, row: 0))?.text == rows[0 ... limit].joined())
        #expect(
            terminal.pathRun(at: grid.point(column: 3, row: limit + 1))?.text
                == rows[1 ... limit + 1].joined())
    }

    /// A path in a bordered box, broken inside its borders, joins inside
    /// them, tapped or selected; a box row whose text stops short of the
    /// border joins neither the row below it nor, from below, that row.
    @Test func pathsInABorderedBoxJoinInsideItsBorders() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        terminal.onPreviewFile = { _ in }
        terminal.onConfirmLink = { _ in }
        terminal.layoutIfNeeded()
        try await settle()
        let columns = try #require(terminal.measuredGrid?.columns)
        let head = "/Users/me/" + String(repeating: "q", count: columns - 14)
        func padded(_ text: String) -> String {
            "│ " + text + String(repeating: " ", count: columns - 3 - text.count) + "│"
        }
        var output = "\u{1B}[?1049h\u{1B}[2J"
        output += "\u{1B}[1;1H│ \(head) │\u{1B}[2;1H\(padded("tail/shot.png"))"
        output += "\u{1B}[4;1H\(padded("~/a.png"))\u{1B}[5;1H\(padded("b.png"))"
        terminal.receive(Data(output.utf8))
        try await settle()
        let grid = try geometry(terminal)
        #expect(head.count + 4 == columns)

        // Ghostty matches each row's own text; the whole path comes first.
        let whole = head + "tail/shot.png"
        #expect(
            terminal.tapLink(at: grid.point(column: 12, row: 0))
                == .openLink(.file(TerminalFileReference(path: whole, fallbackPaths: [head]))))
        #expect(
            terminal.tapLink(at: grid.point(column: 4, row: 1))
                == .openLink(.file(TerminalFileReference(path: whole, fallbackPaths: ["tail/shot.png"]))))
        #expect(
            terminal.tapLink(at: grid.point(column: 4, row: 3))
                == .openLink(.file(TerminalFileReference(path: "~/a.png"))))
        #expect(
            terminal.tapLink(at: grid.point(column: 2, row: 4))
                == .openLink(.file(TerminalFileReference(path: "b.png"))))

        // Selected across the break, border and all, it offers Preview.
        terminal.beginTouchSelection(at: grid.point(column: 12, row: 0))
        terminal.moveTouchSelectionDrag(to: grid.point(column: 14, row: 1))
        terminal.finishTouchSelectionDrag(presentingMenu: false)
        let selected = try #require(terminal.surface?.readSelection())
        #expect(selected.contains("\n"))
        #expect(
            terminal.selectionLinkAction(forSelectedText: selected)
                == .openLink(.file(TerminalFileReference(path: whole))))
    }

    /// A box row joins the next only when its text ends at most two blanks
    /// before the border at the edge, and only onto a row framed by the
    /// same border in the same two columns: a plain row, another border
    /// character, or the box beside it on the next row is not its text.
    @Test func boxJoinsKeepToTheirOwnBorders() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        terminal.onPreviewFile = { _ in }
        terminal.layoutIfNeeded()
        try await settle()
        let columns = try #require(terminal.measuredGrid?.columns)
        // A full-width box row: its text, then blanks to the border.
        func box(_ text: String, border: String = "│") -> String {
            border + " " + text + String(repeating: " ", count: columns - 3 - text.count) + border
        }
        // A box row whose text ends `blanks` cells before the border.
        func boxed(_ text: String, blanks: Int) -> String {
            "│ " + text + String(repeating: " ", count: blanks) + "│"
        }
        // Two boxes side by side; the right one reaches the edge.
        let besideLeft = "│ ab │ "
        func beside(_ left: String, _ text: String) -> String {
            let blanks = columns - besideLeft.count - 3 - text.count
            return "│ \(left) │ │ " + text + String(repeating: " ", count: blanks) + "│"
        }
        let two = "~/two/" + String(repeating: "t", count: columns - 11)
        let three = "~/three/" + String(repeating: "t", count: columns - 14)
        let plain = "~/plain/" + String(repeating: "p", count: columns - 8)
        let heavy = "~/heavy/" + String(repeating: "h", count: columns - 12)
        let side = "~/side/" + String(repeating: "s", count: columns - besideLeft.count - 11)
        var output = "\u{1B}[?1049h\u{1B}[2J"
        output += "\u{1B}[1;1H\(boxed(two, blanks: 2))\u{1B}[2;1H\(box("x.png"))"
        output += "\u{1B}[4;1H\(boxed(three, blanks: 3))\u{1B}[5;1H\(box("y.png"))"
        output += "\u{1B}[7;1H\(plain)\u{1B}[8;1H\(box("th.png"))"
        output += "\u{1B}[10;1H\(boxed(heavy, blanks: 1))\u{1B}[11;1H\(box("z.png", border: "┃"))"
        output += "\u{1B}[13;1H\(beside("ab", side))\u{1B}[14;1H\(beside("cd", "q.png"))\u{1B}[20;1H"
        terminal.receive(Data(output.utf8))
        try await settle()
        let grid = try geometry(terminal)
        #expect([boxed(two, blanks: 2), boxed(three, blanks: 3), plain, boxed(heavy, blanks: 1)]
            .allSatisfy { $0.count == columns })
        #expect(beside("ab", side).count == columns && box("x.png").count == columns)

        #expect(
            terminal.tapLink(at: grid.point(column: 4, row: 0))
                == .openLink(.file(TerminalFileReference(path: two + "x.png", fallbackPaths: [two]))))
        #expect(
            terminal.tapLink(at: grid.point(column: 4, row: 3))
                == .openLink(.file(TerminalFileReference(path: three))))
        #expect(
            terminal.tapLink(at: grid.point(column: 2, row: 4))
                == .openLink(.file(TerminalFileReference(path: "y.png"))))
        #expect(
            terminal.tapLink(at: grid.point(column: 4, row: 6))
                == .openLink(.file(TerminalFileReference(path: plain))))
        #expect(
            terminal.tapLink(at: grid.point(column: 4, row: 9))
                == .openLink(.file(TerminalFileReference(path: heavy))))
        // The box beside it on the next row is not its continuation.
        let sideColumn = besideLeft.count + 4
        #expect(
            terminal.tapLink(at: grid.point(column: sideColumn, row: 12))
                == .openLink(.file(TerminalFileReference(path: side + "q.png", fallbackPaths: [side]))))
        #expect(
            terminal.tapLink(at: grid.point(column: besideLeft.count + 3, row: 13))
                == .openLink(.file(TerminalFileReference(path: side + "q.png"))))
    }

    /// A path that climbs back out of a name it draws with `..` is asked
    /// about, however it was put together: remote output could hang
    /// `/../../.ssh/id_ed25519` off a harmless name at the edge, glue a `..`
    /// to the row above's name so it no longer reads as one, or follow the
    /// name with it after a blank. Leading `..` only climbs from the pane's
    /// directory, so a path whose `..` all come first opens.
    @Test func aPathThatClimbsBackOutIsConfirmed() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        terminal.onPreviewFile = { _ in }
        terminal.onConfirmLink = { _ in }
        terminal.layoutIfNeeded()
        try await settle()
        let columns = try #require(terminal.measuredGrid?.columns)
        let relative = "../../" + String(repeating: "r", count: columns - 6) + "/shot.png"
        let saved = "Saved to ~/Pictures/export"
        let merged = "../../../shot.png"
        var output = "\u{1B}[?1049h\u{1B}[2J"
        output += "\u{1B}[1;\(columns - 12)H~/ok/shot.png\u{1B}[2;9H/../../../.ssh/id_ed25519"
        output += "\u{1B}[4;1H\(relative.prefix(columns))\u{1B}[5;1H\(relative.dropFirst(columns))"
        output += "\u{1B}[7;\(columns - saved.count + 1)H\(saved)"
        output += "\u{1B}[8;\(columns - merged.count + 1)H\(merged)\u{1B}[9;1H/../.ssh/id_ed25519"
        output += "\u{1B}[11;1H~/ok/shot. x/../../.ssh/id_ed25519.\u{1B}[13;1Hsee ~/ok/../.ssh/id_ed25519"
        // The same hung path with its rest in the next row's first cell.
        output += "\u{1B}[15;\(columns - 12)H~/ok/shot.png\u{1B}[16;1H/../../../.ssh/id_ed25519"
        output += "\u{1B}[20;1H"
        terminal.receive(Data(output.utf8))
        try await settle()
        let grid = try geometry(terminal)

        // Joined across the break, tapped on either row; no fallback is kept,
        // so the one path the confirmation names is the one read.
        let hung = TerminalTapAction.confirmLink(
            .file(TerminalFileReference(path: "~/ok/shot.png/../../../.ssh/id_ed25519")))
        #expect(terminal.tapLink(at: grid.point(column: columns - 4, row: 0)) == hung)
        #expect(terminal.tapLink(at: grid.point(column: 12, row: 1)) == hung)
        #expect(terminal.tapLink(at: grid.point(column: columns - 4, row: 14)) == hung)
        #expect(terminal.tapLink(at: grid.point(column: 4, row: 15)) == hung)
        // The tapped row's own `..` glued to `export` above it.
        #expect(
            terminal.tapLink(at: grid.point(column: columns - 3, row: 7))
                == .confirmLink(.file(TerminalFileReference(
                    path: "~/Pictures/export../../../shot.png/../.ssh/id_ed25519"))))
        // Ghostty's match runs on across a blank onto a word that ends in
        // `.` (dropped as the sentence's); a tap on `shot` would otherwise
        // read ~/.ssh/id_ed25519. Drawn in full on one row, it asks too.
        #expect(
            terminal.tapLink(at: grid.point(column: 6, row: 10))
                == .confirmLink(.file(TerminalFileReference(path: "~/ok/shot. x/../../.ssh/id_ed25519"))))
        #expect(
            terminal.tapLink(at: grid.point(column: 8, row: 12))
                == .confirmLink(.file(TerminalFileReference(path: "~/ok/../.ssh/id_ed25519"))))
        // Only leading `..`, tapped on either row.
        #expect(
            terminal.tapLink(at: grid.point(column: 8, row: 3))
                == .openLink(.file(TerminalFileReference(
                    path: relative, fallbackPaths: [String(relative.prefix(columns))]))))
        #expect(
            terminal.tapLink(at: grid.point(column: 3, row: 4))
                == .openLink(.file(TerminalFileReference(path: relative, fallbackPaths: ["/shot.png"]))))
    }

    /// `/tmp/a.png. Done.` previews `/tmp/a.png`, and `foo.png:12.` is a
    /// file and its line. A `file:` link naming another machine says why
    /// it does not open instead of seeming to do nothing.
    @Test func sentencesPositionsAndOtherMachinesAroundPaths() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        terminal.onPreviewFile = { _ in }
        terminal.onConfirmLink = { _ in }
        terminal.layoutIfNeeded()
        try await settle()
        var output = "\u{1B}[?1049h\u{1B}[2J"
        output += "\u{1B}[1;1HSaved /tmp/a.png. Done.\u{1B}[3;1Hopen foo.png:12. now"
        output += "\u{1B}[5;1Hfile://otherhost/etc/hosts"
        output += "\u{1B}[7;1H\u{1B}]8;;file://otherhost/etc/hosts\u{1B}\\hosts\u{1B}]8;;\u{1B}\\\u{1B}[20;1H"
        terminal.receive(Data(output.utf8))
        try await settle()
        let grid = try geometry(terminal)

        #expect(
            terminal.tapLink(at: grid.point(column: 8, row: 0))
                == .openLink(.file(TerminalFileReference(path: "/tmp/a.png"))))
        #expect(
            terminal.tapLink(at: grid.point(column: 7, row: 2))
                == .openLink(.file(TerminalFileReference(path: "foo.png", line: 12))))

        // Without a way to say so, such a link stays text.
        #expect(terminal.tapLink(at: grid.point(column: 3, row: 4)) == nil)
        var refused: [String] = []
        terminal.onRefusedFileLink = { refused.append($0) }
        #expect(terminal.tapLink(at: grid.point(column: 3, row: 4)) == .refuseFile(host: "otherhost"))
        #expect(terminal.tapLink(at: grid.point(column: 2, row: 6)) == .refuseFile(host: "otherhost"))
        #expect(refused.isEmpty)
        // A tap says so, for the text and the OSC 8 link alike.
        terminal.handleTap(at: grid.point(column: 3, row: 4))
        terminal.handleTap(at: grid.point(column: 2, row: 6))
        #expect(refused == ["otherhost", "otherhost"])
        // A screen that previews nothing has no file links to refuse.
        terminal.onPreviewFile = nil
        #expect(terminal.tapLink(at: grid.point(column: 3, row: 4)) == nil)
    }

    /// A shell's prompt often names its directory (`~/code/x$`), which
    /// Ghostty's matcher takes for a path. A tap on the input row still means
    /// "let me type" — on the alternate screen too, where `herdr terminal
    /// attach` keeps every pane.
    @Test func thePromptRowRaisesTheKeyboardOverItsPath() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        terminal.onPreviewFile = { _ in }
        terminal.onConfirmLink = { _ in }
        try await show(terminal)
        terminal.receive(Data("me@box ~/code/x$ ".utf8))
        try await settle()
        var grid = try geometry(terminal)

        var prompt = grid.point(column: 10, row: 10)
        #expect(terminal.tapLink(at: prompt) != nil, "the prompt's path must be a link to Ghostty")
        #expect(terminal.tapAction(at: prompt) == .report(raisesKeyboard: true))
        // Above the input row the same kind of path still previews.
        let pic = TerminalTapAction.openLink(.file(TerminalFileReference(path: "~/pic.png")))
        #expect(terminal.tapAction(at: grid.point(column: 36, row: 2)) == pic)

        // The same prompt under a path on every row above it, on the
        // alternate screen.
        var output = "\u{1B}[?1049h\u{1B}[2J\u{1B}[H"
        output += String(repeating: "see ~/pic.png\r\n", count: 10)
        output += "me@box ~/code/x$ "
        terminal.receive(Data(output.utf8))
        try await settle()
        #expect(terminal.isAlternateScreen)
        grid = try geometry(terminal)

        prompt = grid.point(column: 10, row: 10)
        #expect(terminal.tapLink(at: prompt) != nil, "the prompt's path must be a link to Ghostty")
        #expect(terminal.tapAction(at: prompt) == .report(raisesKeyboard: true))
        // Only the caret's own row yields: a link just above it still opens.
        let nearby = try #require(
            (0..<10).reversed().map { grid.point(column: 6, row: $0) }.first {
                !terminal.inputRowRegion.contains($0)
            })
        #expect(terminal.tapAction(at: nearby) == pic)
    }

    /// The selection menu decides as a tap on the same text would: what a
    /// tap confirms is confirmed, and prose with a slash is not a path.
    @Test func theSelectionMenuDecidesLikeATap() throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        // Without the app's hooks, a file is offered nothing.
        #expect(terminal.touchSelectionMenuElements(forSelectedText: "file:///etc/hosts").isEmpty)
        #expect(terminal.touchSelectionMenuElements(forSelectedText: "~/pic.png").isEmpty)

        terminal.onPreviewFile = { _ in }
        terminal.onConfirmLink = { _ in }
        #expect(
            terminal.selectionLinkAction(forSelectedText: "file:///etc/hosts")
                == .confirmLink(.file(TerminalFileReference(path: "/etc/hosts"))))
        #expect(terminal.touchSelectionMenuElements(forSelectedText: "file:///etc/hosts").count == 1)
        #expect(
            terminal.selectionLinkAction(forSelectedText: "~/pic.png")
                == .openLink(.file(TerminalFileReference(path: "~/pic.png"))))

        for prose in ["and/or", "I/O", "TCP/IP", "24/7", "2026/09/26"] {
            #expect(terminal.selectionLinkAction(forSelectedText: prose) == nil, "\(prose)")
            #expect(terminal.touchSelectionMenuElements(forSelectedText: prose).isEmpty, "\(prose)")
        }

        // A web link opens directly only when its text cannot pass for
        // another host: userinfo, or a non-ASCII authority, is confirmed.
        let plain = try #require(URL(string: "https://example.com/a@b"))
        #expect(
            terminal.selectionLinkAction(forSelectedText: "https://example.com/a@b")
                == .openLink(.web(plain)))
        let userinfo = try #require(URL(string: "https://paypal.com@evil.example/x"))
        #expect(
            terminal.selectionLinkAction(forSelectedText: "https://paypal.com@evil.example/x")
                == .confirmLink(.web(userinfo)))
        let password = try #require(URL(string: "https://user:pw@example.com/"))
        #expect(
            terminal.selectionLinkAction(forSelectedText: "https://user:pw@example.com/")
                == .confirmLink(.web(password)))
        // A look-alike host, or a look-alike slash hiding the `@`, never
        // opens without showing the real host first.
        for disguised in ["https://paypal.com\u{2215}signin@evil.example", "https://g\u{EF}thub.com/"] {
            let action = terminal.selectionLinkAction(forSelectedText: disguised)
            if case .openLink? = action {
                Issue.record("\(disguised) opens without asking")
            }
        }
    }

    /// A selection over more than one row is one path only where the rows
    /// join by the tap's own rules and the selection covers exactly that
    /// path: rows that merely sit one above another — a list of paths, a
    /// path over a word or a box's bottom rule — offer no Preview. A joined
    /// path that climbs back out with `..` is confirmed, as a tap would.
    @Test func aSelectionOverRowsIsOnePathOnlyWhereTheyJoin() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        terminal.onPreviewFile = { _ in }
        terminal.onConfirmLink = { _ in }
        terminal.layoutIfNeeded()
        try await settle()
        let columns = try #require(terminal.measuredGrid?.columns)
        let tui = "~/pics/" + String(repeating: "e", count: columns - 14) + "/diagram.png"
        let tuiHead = String(tui.prefix(columns - 3))
        let tail = String(tui.dropFirst(columns - 3))
        let head = "/Users/me/" + String(repeating: "q", count: columns - 14)
        var output = "\u{1B}[?1049h\u{1B}[2J"
        output += "\u{1B}[1;3H\(tuiHead)\u{1B}[2;3H\(tail)"
        output += "\u{1B}[4;1Hsrc/a.swift\u{1B}[5;1Hsrc/b.swift"
        output += "\u{1B}[7;1H/tmp/a.png\u{1B}[8;1H/tmp/b.png"
        output += "\u{1B}[10;1H│ \(head) │\u{1B}[11;1H╰" + String(repeating: "─", count: columns - 2) + "╯"
        output += "\u{1B}[13;\(columns - 12)H~/ok/shot.png\u{1B}[14;1H/../../.ssh/id_ed25519"
        output += "\u{1B}[16;1H~/pics/shot.png\u{1B}[17;1HDone\u{1B}[20;1H"
        terminal.receive(Data(output.utf8))
        try await settle()
        let grid = try geometry(terminal)
        func selecting(from start: (column: Int, row: Int), to end: (column: Int, row: Int)) throws -> String {
            terminal.beginTouchSelection(at: grid.point(column: start.column, row: start.row))
            terminal.moveTouchSelectionDrag(to: grid.point(column: end.column, row: end.row))
            terminal.finishTouchSelectionDrag(presentingMenu: false)
            let selected = try #require(terminal.surface?.readSelection())
            #expect(selected.contains("\n"))
            return selected
        }

        let broken = try selecting(from: (4, 0), to: (2 + tail.count - 1, 1))
        #expect(
            terminal.selectionLinkAction(forSelectedText: broken)
                == .openLink(.file(TerminalFileReference(path: tui))))

        let list = try selecting(from: (2, 3), to: (10, 4))
        #expect(terminal.selectionLinkAction(forSelectedText: list) == nil)
        #expect(terminal.touchSelectionMenuElements(forSelectedText: list).isEmpty)
        let rooted = try selecting(from: (2, 6), to: (9, 7))
        #expect(terminal.selectionLinkAction(forSelectedText: rooted) == nil)
        let ruled = try selecting(from: (4, 9), to: (columns - 1, 10))
        #expect(terminal.selectionLinkAction(forSelectedText: ruled) == nil)
        let worded = try selecting(from: (4, 15), to: (3, 16))
        #expect(terminal.selectionLinkAction(forSelectedText: worded) == nil)

        let climbing = try selecting(from: (columns - 4, 12), to: (21, 13))
        #expect(
            terminal.selectionLinkAction(forSelectedText: climbing)
                == .confirmLink(.file(TerminalFileReference(path: "~/ok/shot.png/../../.ssh/id_ed25519"))))
    }

    /// The back-swipe strip lies over the first columns and hands a tap
    /// that does not move on to the surface, in the surface's coordinates.
    /// It is taken as the surface's own tap would be: a path drawn from
    /// column 0 previews, and any other tap raises the keyboard on either
    /// buffer — but not one handed on from off the surface.
    @Test func aTapTheEdgeStripHandsOnActsAsTheSurfacesOwn() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        var previewed: [TerminalFileReference] = []
        terminal.onPreviewFile = { previewed.append($0) }
        terminal.layoutIfNeeded()
        try await settle()
        terminal.receive(Data("\u{1B}[2J\u{1B}[H/tmp/edge.png\r\nplain words\r\n\u{1B}[11;1H".utf8))
        try await settle()
        var grid = try geometry(terminal)
        #expect(!terminal.isAlternateScreen)

        terminal.handleForwardedTap(at: CGPoint(x: -2, y: grid.point(column: 0, row: 1).y))
        #expect(!terminal.isFirstResponder)
        terminal.handleForwardedTap(at: grid.point(column: 1, row: 0))
        #expect(previewed == [TerminalFileReference(path: "/tmp/edge.png")])
        #expect(!terminal.isFirstResponder)
        terminal.handleForwardedTap(at: grid.point(column: 1, row: 1))
        #expect(terminal.isFirstResponder)
        #expect(terminal.dismissKeyboard())

        terminal.receive(Data("\u{1B}[?1049h\u{1B}[2J\u{1B}[Hdrawn by a TUI".utf8))
        try await settle()
        grid = try geometry(terminal)
        #expect(terminal.isAlternateScreen)
        terminal.handleForwardedTap(at: CGPoint(x: -2, y: grid.point(column: 0, row: 5).y))
        #expect(!terminal.isFirstResponder)
        terminal.handleForwardedTap(at: grid.point(column: 1, row: 5))
        #expect(terminal.isFirstResponder)
    }

    /// Output scrolls a selection's start off the top: its handle goes, and
    /// the other end's drag cannot cut the hidden part off either.
    @Test func anEndScrolledOutOfViewHasNoHandle() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        try await show(terminal)
        let grid = try geometry(terminal)
        terminal.beginTouchSelection(at: grid.point(column: 1, row: 0))
        terminal.moveTouchSelectionDrag(to: grid.point(column: 3, row: 2))
        terminal.finishTouchSelectionDrag(presentingMenu: false)
        let selected = try #require(terminal.surface?.readSelection())
        #expect(selected.hasPrefix("see "))

        // The cursor sits on row 10: this many line feeds scroll one row.
        let rows = try #require(terminal.measuredGrid?.rows)
        terminal.receive(Data(String(repeating: "\n", count: rows - 10).utf8))
        try await settle()
        let range = try #require(terminal.touchSelectionRange())
        #expect(range.startIsClamped)
        #expect(!range.endIsClamped)
        terminal.layoutTouchSelection()
        #expect(terminal.touchSelectionHandles().0.isHidden)
        #expect(!terminal.touchSelectionHandles().1.isHidden)

        terminal.beginHandleDrag(.start, at: grid.point(column: 0, row: 0))
        terminal.finishTouchSelectionDrag(presentingMenu: false)
        #expect(terminal.surface?.readSelection() == selected)
    }

    /// Claude Code, codex and grok all track every motion (DECSET 1003).
    /// Asking Ghostty what is under a finger must not tell them anything.
    @Test func findingALinkSendsNothingToAProgramTrackingTheMouse() async throws {
        let (terminal, window, sent) = try await makeTerminal()
        defer { window.isHidden = true }
        terminal.onPreviewFile = { _ in }
        try await show(terminal, tracking: true)
        let grid = try geometry(terminal)
        sent.removeAll()

        let url = try #require(URL(string: Self.longURL))
        #expect(terminal.tapLink(at: grid.point(column: 6, row: 0)) == .openLink(.web(url)))
        #expect(terminal.tapLink(at: grid.point(column: 30, row: 2)) == nil)
        terminal.flashLink(at: grid.point(column: 6, row: 0))
        // A second tap while the first one's highlight is still up.
        #expect(terminal.tapLink(at: grid.point(column: 6, row: 0)) == .openLink(.web(url)))
        // Right after a selection gesture ended on a link's cell, the link is
        // still found (ghostty's per-cell hover cache is reset first).
        terminal.beginTouchSelection(at: grid.point(column: 9, row: 2))
        terminal.finishTouchSelectionDrag(presentingMenu: false)
        terminal.clearSelection()
        #expect(
            terminal.tapLink(at: grid.point(column: 9, row: 2))
                == .openLink(.file(TerminalFileReference(path: "src/foo/bar.swift", line: 12, column: 3))))
        terminal.flashLink(at: grid.point(column: 6, row: 0))
        try await Task.sleep(for: .milliseconds(500))

        #expect(sent.bytes.isEmpty, "\(String(decoding: sent.bytes, as: UTF8.self).debugDescription)")
    }

    /// A long press selects the word under the finger, or the whole link, with
    /// Ghostty's own selection — over a program that captured the mouse, and
    /// without a byte reaching it.
    @Test func longPressSelectsLocallyOverAProgramTrackingTheMouse() async throws {
        let (terminal, window, sent) = try await makeTerminal()
        defer { window.isHidden = true }
        try await show(terminal, tracking: true)
        let grid = try geometry(terminal)
        sent.removeAll()

        terminal.beginTouchSelection(at: grid.point(column: 9, row: 2))
        terminal.finishTouchSelectionDrag(presentingMenu: false)
        #expect(terminal.surface?.readSelection() == "src/foo/bar.swift:12:3")

        // A second long press replaces the selection instead of extending it.
        terminal.beginTouchSelection(at: grid.point(column: 1, row: 0))
        terminal.finishTouchSelectionDrag(presentingMenu: false)
        #expect(terminal.surface?.readSelection() == "see")

        try await Task.sleep(for: .milliseconds(100))
        #expect(sent.bytes.isEmpty, "\(String(decoding: sent.bytes, as: UTF8.self).debugDescription)")
    }

    /// Dragging a handle moves that end of Ghostty's selection cell by cell,
    /// and an end never crosses the other.
    @Test func handlesMoveTheirEndOfTheSelection() async throws {
        let (terminal, window, sent) = try await makeTerminal()
        defer { window.isHidden = true }
        try await show(terminal, tracking: true)
        let grid = try geometry(terminal)

        // Row 5 is "a beta gamma delta": gamma is columns 7–11.
        terminal.beginTouchSelection(at: grid.point(column: 9, row: 5))
        terminal.finishTouchSelectionDrag(presentingMenu: false)
        #expect(terminal.surface?.readSelection() == "gamma")
        sent.removeAll()

        // The end handle's knob hangs below the text; drag from where it is.
        terminal.beginHandleDrag(.end, at: grid.point(column: 11, row: 5, x: 0.9, y: 1.3))
        terminal.moveTouchSelectionDrag(to: grid.point(column: 17, row: 5, x: 0.9, y: 1.3))
        terminal.finishTouchSelectionDrag(presentingMenu: false)
        #expect(terminal.surface?.readSelection() == "gamma delta")

        terminal.beginHandleDrag(.start, at: grid.point(column: 7, row: 5, x: 0.1, y: -0.3))
        terminal.moveTouchSelectionDrag(to: grid.point(column: 2, row: 5, x: 0.1, y: -0.3))
        terminal.finishTouchSelectionDrag(presentingMenu: false)
        #expect(terminal.surface?.readSelection() == "beta gamma delta")

        // Past the other end, a handle stops on it.
        terminal.beginHandleDrag(.start, at: grid.point(column: 2, row: 5, x: 0.1, y: -0.3))
        terminal.moveTouchSelectionDrag(to: grid.point(column: 40, row: 5, x: 0.1, y: -0.3))
        terminal.finishTouchSelectionDrag(presentingMenu: false)
        #expect(terminal.surface?.readSelection() == "a")

        try await Task.sleep(for: .milliseconds(100))
        #expect(sent.bytes.isEmpty, "\(String(decoding: sent.bytes, as: UTF8.self).debugDescription)")
    }

    /// The back-swipe strip steps aside only where a handle takes touches:
    /// a selection keeps the rest of the leading edge swipeable, and leaving
    /// it gives the whole edge back.
    @Test func onlyAHandleAtTheLeadingEdgeTakesItFromTheBackSwipe() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        try await show(terminal, tracking: true)
        let grid = try geometry(terminal)
        let control = TerminalKeyboardControl()
        control.terminal = terminal
        let strip = CGRect(x: 0, y: 0, width: 24, height: terminal.bounds.height)

        // Row 5 is "a beta gamma delta": the start handle sits at column 0.
        terminal.beginTouchSelection(at: grid.point(column: 0, row: 5))
        terminal.finishTouchSelectionDrag(presentingMenu: false)
        #expect(terminal.surface?.readSelection() == "a")
        let inStrip = control.touchSelectionHandleAreas.filter { $0.intersects(strip) }
        #expect(inStrip.count >= 1)
        #expect(inStrip.allSatisfy { $0.contains(grid.point(column: 0, row: 5, x: 0.1, y: -0.3)) })
        #expect(!inStrip.contains { $0.contains(grid.point(column: 0, row: 0)) })
        // The strip keeps every point but the handle's.
        let shape = EdgeStripShape(holes: control.touchSelectionHandleAreas).path(in: strip)
        #expect(!shape.contains(grid.point(column: 0, row: 5, x: 0.1, y: -0.3)))
        #expect(shape.contains(CGPoint(x: 12, y: grid.point(column: 0, row: 0).y)))

        // Gamma's handles sit far from the edge.
        terminal.beginTouchSelection(at: grid.point(column: 9, row: 5))
        terminal.finishTouchSelectionDrag(presentingMenu: false)
        #expect(control.touchSelectionHandleAreas.count == 2)
        #expect(!control.touchSelectionHandleAreas.contains { $0.intersects(strip) })

        terminal.clearSelection()
        #expect(control.touchSelectionHandleAreas.isEmpty)
    }

    /// A tap on the selection keeps it; anywhere else clears it. Neither is
    /// a click or a keyboard raise.
    @Test func tapsDismissTheSelectionWithoutClicking() async throws {
        let (terminal, window, sent) = try await makeTerminal()
        defer { window.isHidden = true }
        try await show(terminal, tracking: true)
        let grid = try geometry(terminal)
        terminal.beginTouchSelection(at: grid.point(column: 9, row: 5))
        terminal.finishTouchSelectionDrag(presentingMenu: false)
        sent.removeAll()

        let tap = try #require(
            terminal.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }.first)
        #expect(!terminal.gestureRecognizerShouldBegin(tap))

        #expect(terminal.handleTapWithSelection(at: grid.point(column: 8, row: 5)))
        #expect(terminal.hasSelection)
        #expect(terminal.handleTapWithSelection(at: grid.point(column: 30, row: 8)))
        #expect(!terminal.hasSelection)
        #expect(!terminal.handleTapWithSelection(at: grid.point(column: 30, row: 8)))

        try await Task.sleep(for: .milliseconds(100))
        #expect(sent.bytes.isEmpty)
        #expect(!terminal.isFirstResponder)
    }

    /// herdr keeps mouse tracking on, so a trackpad or mouse click on a link
    /// Claude Code printed went to the program and nothing opened. A plain
    /// click on the link opens it and reaches no program; anywhere else, a
    /// click is reported as it always was.
    @Test func pointerClicksOpenLinksWithoutReachingTheProgram() async throws {
        let (terminal, window, sent) = try await makeTerminal()
        defer { window.isHidden = true }
        var opened: [URL] = []
        terminal.onOpenLink = { opened.append($0) }
        try await showHerdrLink(terminal)
        let grid = try geometry(terminal)
        let url = try #require(URL(string: Self.claudeURL))
        let link = grid.point(column: 10, row: 0)
        let plain = grid.point(column: 2, row: 3)
        sent.removeAll()

        #expect(terminal.tapAction(at: link, input: .pointer(modifiers: [])) == .openLink(.web(url)))
        #expect(terminal.tapAction(at: plain, input: .pointer(modifiers: [])) == .report(raisesKeyboard: false))
        // ⌘-click stays Ghostty's own.
        #expect(
            terminal.tapAction(at: link, input: .pointer(modifiers: .super_))
                == .report(raisesKeyboard: false))
        // Caps lock is no modifier.
        #expect(terminal.tapAction(at: link, input: .pointer(modifiers: .caps)) == .openLink(.web(url)))
        // The hook itself: ⌘ leaves the click to Ghostty, caps lock does not,
        // and a click off the link is never the host's.
        #expect(terminal.claimPointerClick(at: link, modifiers: .super_) == nil)
        #expect(terminal.claimPointerClick(at: link, modifiers: .caps) != nil)
        #expect(terminal.claimPointerClick(at: plain, modifiers: []) == nil)

        // A press, a jitter inside the tap slop, and the release.
        terminal.handleIndirectPointer(phase: .began, at: link, buttonMask: .primary)
        terminal.handleIndirectPointer(
            phase: .moved, at: CGPoint(x: link.x + 2, y: link.y + 1), buttonMask: .primary)
        terminal.handleIndirectPointer(phase: .ended, at: link, buttonMask: .primary)
        try await settle()
        #expect(opened == [url])
        #expect(sent.bytes.isEmpty, "\(String(decoding: sent.bytes, as: UTF8.self).debugDescription)")

        opened.removeAll()
        terminal.handleIndirectPointer(phase: .began, at: plain, buttonMask: .primary)
        terminal.handleIndirectPointer(phase: .ended, at: plain, buttonMask: .primary)
        try await settle()
        let reported = String(decoding: sent.bytes, as: UTF8.self)
        #expect(reported.contains("\u{1B}[<0;3;4M"), "\(reported.debugDescription)")
        #expect(reported.hasSuffix("\u{1B}[<0;3;4m"), "\(reported.debugDescription)")
        #expect(opened.isEmpty)
    }

    /// A drag that starts on a link is a drag: the program hears its press
    /// once, where it began, before any motion, then the motion and the
    /// release — and no link opens.
    @Test func pointerDragsFromALinkReachTheProgram() async throws {
        let (terminal, window, sent) = try await makeTerminal()
        defer { window.isHidden = true }
        var opened: [URL] = []
        terminal.onOpenLink = { opened.append($0) }
        try await showHerdrLink(terminal)
        let grid = try geometry(terminal)

        terminal.handleIndirectPointer(phase: .began, at: grid.point(column: 10, row: 0), buttonMask: .primary)
        terminal.handleIndirectPointer(phase: .moved, at: grid.point(column: 30, row: 3), buttonMask: .primary)
        terminal.handleIndirectPointer(phase: .ended, at: grid.point(column: 30, row: 3), buttonMask: .primary)
        try await settle()

        let reported = String(decoding: sent.bytes, as: UTF8.self)
        let press = "\u{1B}[<0;11;1M"
        #expect(reported.components(separatedBy: press).count == 2, "\(reported.debugDescription)")
        let pressed = try #require(reported.range(of: press), "\(reported.debugDescription)")
        // SGR motion with the left button held is code 32.
        let motion = try #require(reported.range(of: "\u{1B}[<32;"), "\(reported.debugDescription)")
        #expect(pressed.upperBound <= motion.lowerBound, "\(reported.debugDescription)")
        #expect(reported.hasSuffix("\u{1B}[<0;31;4m"), "\(reported.debugDescription)")
        #expect(opened.isEmpty)
    }

    /// A press on a link that UIKit cancels is dropped whole: no byte, no
    /// link. The next click elsewhere is reported as usual.
    @Test func aCancelledPointerPressOnALinkDoesNothing() async throws {
        let (terminal, window, sent) = try await makeTerminal()
        defer { window.isHidden = true }
        var opened: [URL] = []
        terminal.onOpenLink = { opened.append($0) }
        try await showHerdrLink(terminal)
        let grid = try geometry(terminal)
        let link = grid.point(column: 10, row: 0)
        let plain = grid.point(column: 2, row: 3)
        sent.removeAll()

        terminal.handleIndirectPointer(phase: .began, at: link, buttonMask: .primary)
        terminal.handleIndirectPointer(phase: .cancelled, at: link, buttonMask: .primary)
        try await settle()
        #expect(sent.bytes.isEmpty, "\(String(decoding: sent.bytes, as: UTF8.self).debugDescription)")
        #expect(opened.isEmpty)

        terminal.handleIndirectPointer(phase: .began, at: plain, buttonMask: .primary)
        terminal.handleIndirectPointer(phase: .ended, at: plain, buttonMask: .primary)
        try await settle()
        let reported = String(decoding: sent.bytes, as: UTF8.self)
        #expect(reported.contains("\u{1B}[<0;3;4M"), "\(reported.debugDescription)")
        #expect(reported.hasSuffix("\u{1B}[<0;3;4m"), "\(reported.debugDescription)")
        #expect(opened.isEmpty)
    }

    /// While a selection is up, a click on a link is Ghostty's: it reaches
    /// the program and opens nothing.
    @Test func aPointerClickOnALinkUnderASelectionIsReported() async throws {
        let (terminal, window, sent) = try await makeTerminal()
        defer { window.isHidden = true }
        var opened: [URL] = []
        terminal.onOpenLink = { opened.append($0) }
        try await showHerdrLink(terminal)
        let grid = try geometry(terminal)
        let link = grid.point(column: 10, row: 0)
        terminal.beginTouchSelection(at: grid.point(column: 2, row: 3))
        terminal.finishTouchSelectionDrag(presentingMenu: false)
        #expect(terminal.hasSelection)
        sent.removeAll()

        #expect(terminal.claimPointerClick(at: link, modifiers: []) == nil)
        terminal.handleIndirectPointer(phase: .began, at: link, buttonMask: .primary)
        terminal.handleIndirectPointer(phase: .ended, at: link, buttonMask: .primary)
        try await settle()
        let reported = String(decoding: sent.bytes, as: UTF8.self)
        #expect(reported.contains("\u{1B}[<0;11;1M"), "\(reported.debugDescription)")
        #expect(reported.hasSuffix("\u{1B}[<0;11;1m"), "\(reported.debugDescription)")
        #expect(opened.isEmpty)
    }

    /// Only a single click is the host's: the second click of a double
    /// click goes to Ghostty, so the link opens once.
    @Test func aDoubleClickOnALinkOpensItOnce() async throws {
        let (terminal, window, sent) = try await makeTerminal()
        defer { window.isHidden = true }
        var opened: [URL] = []
        terminal.onOpenLink = { opened.append($0) }
        try await showHerdrLink(terminal)
        let grid = try geometry(terminal)
        let url = try #require(URL(string: Self.claudeURL))
        let link = grid.point(column: 10, row: 0)
        sent.removeAll()

        terminal.handleIndirectPointer(phase: .began, at: link, buttonMask: .primary, tapCount: 1)
        terminal.handleIndirectPointer(phase: .ended, at: link, buttonMask: .primary, tapCount: 1)
        terminal.handleIndirectPointer(phase: .began, at: link, buttonMask: .primary, tapCount: 2)
        terminal.handleIndirectPointer(phase: .ended, at: link, buttonMask: .primary, tapCount: 2)
        try await settle()
        #expect(opened == [url])
        let reported = String(decoding: sent.bytes, as: UTF8.self)
        #expect(reported.components(separatedBy: "\u{1B}[<0;11;1M").count == 2, "\(reported.debugDescription)")
        #expect(reported.hasSuffix("\u{1B}[<0;11;1m"), "\(reported.debugDescription)")
    }

    /// herdr draws every row with a cursor move, so a URL an agent TUI
    /// wraps reaches Ghostty as fragments on rows with no wrap flag, and
    /// its matcher sees the head alone. A tap or click on either fragment
    /// opens the whole URL, past the next row's indentation, and an
    /// OpenCode-style row whose right edge is a scrollbar column (`█`)
    /// joins inside its `┃` border. A URL on one row opens unchanged.
    @Test func webLinksBrokenAcrossRowsOpenWhole() async throws {
        let (terminal, window, sent) = try await makeTerminal()
        defer { window.isHidden = true }
        var opened: [URL] = []
        terminal.onOpenLink = { opened.append($0) }
        terminal.layoutIfNeeded()
        try await settle()
        let columns = try #require(terminal.measuredGrid?.columns)
        // The head ends two cells in from the edge, as a 40-column grid
        // would draw it; the tail is indented two.
        let head = "go to https://example.com/waycar/harne"
        try #require(columns >= head.count + 2)
        let start = columns - 1 - head.count
        let scrolled = "┃  see https://example.com/"
        let fill = String(repeating: "o", count: columns - 3 - scrolled.count)
        var output = "\u{1B}[?1049h\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1003h\u{1B}[?1006h\u{1B}[2J"
        output += "\u{1B}[1;\(start)H\(head)\u{1B}[2;\(start)H  ss-audit/x."
        output += "\u{1B}[4;1Hsee https://example.com/one. done"
        output += "\u{1B}[6;1H\(scrolled)\(fill)  █"
        output += "\u{1B}[7;1H┃  pen/x.html\u{1B}[7;\(columns)H█\u{1B}[20;1H"
        terminal.receive(Data(output.utf8))
        try await settle()
        let grid = try geometry(terminal)
        let whole = try #require(URL(string: "https://example.com/waycar/harness-audit/x"))
        let one = try #require(URL(string: "https://example.com/one"))
        let framed = try #require(URL(string: "https://example.com/" + fill + "pen/x.html"))
        let onHead = grid.point(column: start - 1 + 30, row: 0)
        let onTail = grid.point(column: start - 1 + 6, row: 1)

        #expect(terminal.tapLink(at: onHead) == .openLink(.web(whole)))
        #expect(terminal.tapLink(at: onTail) == .openLink(.web(whole)))
        #expect(terminal.tapLink(at: grid.point(column: 8, row: 3)) == .openLink(.web(one)))
        #expect(terminal.tapLink(at: grid.point(column: 10, row: 5)) == .openLink(.web(framed)))
        #expect(terminal.tapLink(at: grid.point(column: 5, row: 6)) == .openLink(.web(framed)))

        // A finger tap on either fragment.
        terminal.handleTap(at: onHead)
        terminal.handleTap(at: onTail)
        #expect(opened == [whole, whole])

        // A mouse or trackpad click on either fragment, which the program
        // tracking the mouse never hears.
        opened.removeAll()
        sent.removeAll()
        for point in [onHead, onTail] {
            terminal.handleIndirectPointer(phase: .began, at: point, buttonMask: .primary)
            terminal.handleIndirectPointer(phase: .ended, at: point, buttonMask: .primary)
        }
        try await settle()
        #expect(opened == [whole, whole])
        #expect(sent.bytes.isEmpty, "\(String(decoding: sent.bytes, as: UTF8.self).debugDescription)")
    }

    /// A URL that only ends near the edge is whole: the next row's word
    /// does not carry it on unless the link scanner's rule says so. A
    /// plain word, a path, or another URL starting the next row keeps
    /// to itself, and a tap on the URL opens it as drawn.
    @Test func webLinksEndingNearTheEdgeStayWhole() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        terminal.onPreviewFile = { _ in }
        terminal.layoutIfNeeded()
        try await settle()
        let columns = try #require(terminal.measuredGrid?.columns)
        let session = "https://example.com/session_01ABC"
        let above = "https://example.com/b"
        let first = "https://example.com/a1"
        let second = "https://example.com/c2"
        try #require(columns > session.count + 1)
        // Each URL ends one cell in from the edge.
        func atEdge(_ text: String) -> Int { columns - text.count }
        var output = "\u{1B}[?1049h\u{1B}[2J"
        output += "\u{1B}[1;\(atEdge(session))H\(session)\u{1B}[2;1Hto see it"
        output += "\u{1B}[4;\(atEdge(above))H\(above)\u{1B}[5;1H/tmp/shot.png"
        output += "\u{1B}[7;\(atEdge(first))H\(first)\u{1B}[8;1H\(second)\u{1B}[20;1H"
        terminal.receive(Data(output.utf8))
        try await settle()
        let grid = try geometry(terminal)
        func url(_ text: String) throws -> TerminalTapAction {
            .openLink(.web(try #require(URL(string: text))))
        }

        #expect(try terminal.tapLink(at: grid.point(column: columns - 5, row: 0)) == url(session))
        #expect(try terminal.tapLink(at: grid.point(column: columns - 5, row: 3)) == url(above))
        #expect(
            terminal.tapLink(at: grid.point(column: 3, row: 4))
                == .openLink(.file(TerminalFileReference(path: "/tmp/shot.png"))))
        #expect(try terminal.tapLink(at: grid.point(column: columns - 5, row: 6)) == url(first))
        #expect(try terminal.tapLink(at: grid.point(column: 5, row: 7)) == url(second))
    }

    /// A link of another kind starting the next row is its own: an edge
    /// URL above `mailto:` opens as drawn, and a tap on the `mailto:` row
    /// opens nothing glued to it. A URL longer than the row, cut mid-word
    /// at the edge (Claude Code's routine links), opens whole from either
    /// row.
    @Test func webLinksJoinOnlyTheirOwnRest() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        var opened: [URL] = []
        terminal.onOpenLink = { opened.append($0) }
        terminal.onPreviewFile = { _ in }
        terminal.onConfirmLink = { _ in }
        terminal.layoutIfNeeded()
        try await settle()
        let columns = try #require(terminal.measuredGrid?.columns)
        let edge = "https://example.com/a"
        let prefix = "https://claude.ai/code/"
        let cut = "/trig_01Ur"
        try #require(columns > prefix.count + cut.count + 1)
        let long = prefix + String(repeating: "r", count: columns - prefix.count - cut.count)
            + cut + "4tPocEZW828mbGT8RmRC"
        var output = "\u{1B}[?1049h\u{1B}[2J"
        output += "\u{1B}[1;\(columns - edge.count)H\(edge)\u{1B}[2;1Hmailto:x@y.com"
        output += "\u{1B}[4;1H\(long.prefix(columns))\u{1B}[5;1H\(long.dropFirst(columns))\u{1B}[20;1H"
        terminal.receive(Data(output.utf8))
        try await settle()
        let grid = try geometry(terminal)
        #expect(long.count > columns && long.prefix(columns).hasSuffix(cut))
        let single = try #require(URL(string: edge))
        let whole = try #require(URL(string: long))

        #expect(terminal.tapLink(at: grid.point(column: columns - 4, row: 0)) == .openLink(.web(single)))
        #expect(terminal.tapLink(at: grid.point(column: 9, row: 1)) == nil)
        #expect(terminal.tapLink(at: grid.point(column: 10, row: 3)) == .openLink(.web(whole)))
        #expect(terminal.tapLink(at: grid.point(column: 5, row: 4)) == .openLink(.web(whole)))

        terminal.handleTap(at: grid.point(column: 9, row: 1))
        #expect(opened.isEmpty)
    }

    /// OpenCode wraps a URL at a `/` or `-` short of its scrollbar column
    /// (`█`), four to seven blanks before it, and Kilo, its fork, the same
    /// with no scrollbar. A tap or click on any of its rows opens the whole
    /// URL, as the Attach Links list reads it, and so does one in Kilo's
    /// `┃` prompt cell; the path after it keeps to itself, and prose a URL
    /// ended short of the edge above stays apart. Rows are OpenCode 1.19's
    /// and Kilo's answers at 60 columns through `herdr terminal attach`.
    @Test func webLinksWrappedShortOfTheEdgeOpenWhole() async throws {
        let (terminal, window, sent) = try await makeTerminal()
        defer { window.isHidden = true }
        var opened: [URL] = []
        terminal.onOpenLink = { opened.append($0) }
        terminal.onPreviewFile = { _ in }
        terminal.layoutIfNeeded()
        try await settle()
        let columns = try #require(terminal.measuredGrid?.columns)
        try #require(columns >= 60)
        let openCode = [
            "See https://github.com/manaflow-ai/waycar/pull/",
            "1234/files?diff=split&w=1#diff-abcdef0123456789-",
            "long-anchor-name and the file /private/tmp/",
            "OpenCodeTapBuilder/screenshots/some-long-name.png",
            "then done.",
        ]
        let kilo = [
            "     See https://example.com/waycar/untested/links-and-",
            "     paths-check-0123456789 and docs/plan.md and /tmp/",
            "     shot.png",
            "",
            "  ┃  Reply with exactly: See https://example.com/waycar/",
            "  ┃  untested/links-and-paths-check-0123456789 and docs/",
            "  ┃  plan.md and /tmp/shot.png",
            "",
            "     see https://example.com/",
            "     README.md for setup",
        ]
        var output = "\u{1B}[?1049h\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1003h\u{1B}[?1006h\u{1B}[2J"
        for (offset, text) in openCode.enumerated() {
            // OpenCode's answer, its scrollbar two cells in from the edge
            // (column 58 of 60).
            output += "\u{1B}[\(offset + 1);6H\(text)\u{1B}[\(offset + 1);\(columns - 2)H█"
        }
        for (offset, text) in kilo.enumerated() {
            output += "\u{1B}[\(offset + 7);1H\(text)"
        }
        output += "\u{1B}[20;1H"
        terminal.receive(Data(output.utf8))
        try await settle()
        let grid = try geometry(terminal)
        let whole = try #require(URL(string:
            "https://github.com/manaflow-ai/waycar/pull/1234/files?diff=split&w=1#diff-abcdef0123456789-long-anchor-name"))
        let onHead = grid.point(column: 20, row: 0)
        let onMiddle = grid.point(column: 10, row: 1)
        let onTail = grid.point(column: 8, row: 2)

        for point in [onHead, onMiddle, onTail] {
            #expect(terminal.tapLink(at: point) == .openLink(.web(whole)))
        }
        // The path after it on the tail row is no part of it.
        if case .openLink(.web)? = terminal.tapLink(at: grid.point(column: 40, row: 2)) {
            Issue.record("the path after the URL opened a web link")
        }
        // Kilo's answer and its prompt cell, head and tail.
        let kiloURL = try #require(URL(string:
            "https://example.com/waycar/untested/links-and-paths-check-0123456789"))
        for (column, row) in [(20, 6), (10, 7), (40, 10), (10, 11)] {
            #expect(
                terminal.tapLink(at: grid.point(column: column, row: row)) == .openLink(.web(kiloURL)),
                "row \(row)")
        }
        // Prose under a URL that ended short of the edge stays apart.
        let bare = try #require(URL(string: "https://example.com/"))
        #expect(terminal.tapLink(at: grid.point(column: 15, row: 14)) == .openLink(.web(bare)))
        // A finger tap on the head and the tail.
        terminal.handleTap(at: onHead)
        terminal.handleTap(at: onTail)
        #expect(opened == [whole, whole])

        // A mouse or trackpad click on either, which OpenCode never hears.
        opened.removeAll()
        sent.removeAll()
        for point in [onHead, onTail] {
            terminal.handleIndirectPointer(phase: .began, at: point, buttonMask: .primary)
            terminal.handleIndirectPointer(phase: .ended, at: point, buttonMask: .primary)
        }
        try await settle()
        #expect(opened == [whole, whole])
        #expect(sent.bytes.isEmpty, "\(String(decoding: sent.bytes, as: UTF8.self).debugDescription)")
    }

    /// A word wrapper moves a path that fits down to the next row whole, so
    /// a prose word ending the row above near the edge is no part of it: a
    /// tap on `/tmp/shot.png` previews `/tmp/shot.png`, as the Files list
    /// reads it, never `and/tmp/shot.png`. Rows are the right-hand end of
    /// Maki's and Kilo's 120-column prompt echoes, kept as far from the
    /// edge as drawn: Maki's `you>` row two cells short of it above the
    /// path unindented, Kilo's `┃` cell filling the row.
    @Test func aPathAWordWrapperMovedDownStaysApartFromTheWordAbove() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        terminal.onPreviewFile = { _ in }
        terminal.onConfirmLink = { _ in }
        terminal.layoutIfNeeded()
        try await settle()
        let columns = try #require(terminal.measuredGrid?.columns)
        let prompt = "Reply with exactly: See https://example.com/waycar/untested/"
            + "links-and-paths-check-0123456789 and docs/plan.md and"
        let maki = "you> " + prompt
        try #require(maki.count > columns && prompt.count > columns - 5)
        var output = "\u{1B}[?1049h\u{1B}[2J"
        output += "\u{1B}[1;1H\(maki.suffix(columns - 2))\u{1B}[2;1H/tmp/shot.png"
        output += "\u{1B}[4;1H  ┃  \(prompt.suffix(columns - 5))\u{1B}[5;1H  ┃  /tmp/shot.png\u{1B}[20;1H"
        terminal.receive(Data(output.utf8))
        try await settle()
        let grid = try geometry(terminal)
        let shot = TerminalTapAction.openLink(.file(TerminalFileReference(path: "/tmp/shot.png")))

        #expect(terminal.tapLink(at: grid.point(column: 6, row: 1)) == shot)
        #expect(terminal.tapLink(at: grid.point(column: 9, row: 4)) == shot)
        #expect(terminal.tapLink(at: grid.point(column: columns - 4, row: 0)) == nil)
    }

    /// OpenCode's user cell frames its rows with `┃` on the left and its
    /// scrollbar (`█`) two cells in from the right; a URL it wrapped after
    /// a `/` and a `-` there opens whole from each of its rows, as the
    /// Attach Links list reads it. A row ending in a bare `https://`, which
    /// Ghostty matches nothing on, opens the URL it starts. Rows are
    /// OpenCode 1.19's at 60 columns through `herdr terminal attach`.
    @Test func webLinksInOpenCodesPromptCellOpenWhole() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        terminal.onPreviewFile = { _ in }
        terminal.layoutIfNeeded()
        try await settle()
        let columns = try #require(terminal.measuredGrid?.columns)
        try #require(columns >= 60)
        let cell = [
            "  ┃",
            "  ┃  Reply with only this text, verbatim, no tools: See",
            "  ┃  https://github.com/manaflow-ai/waycar/pull/1234/",
            "  ┃  files?diff=split&w=1#diff-abcdef0123456789-long-",
            "  ┃  anchor-name and the file /private/tmp/",
            "  ┃  OpenCodeTapBuilder/screenshots/some-long-name.png",
            "  ┃  then done.",
            "  ┃",
        ]
        let scheme = [
            "     averyveryverylongsegmentname now. Also https://",
            "     example.com/a/b/c/d/e/f/g/h/i/j/kk/docs then",
        ]
        var output = "\u{1B}[?1049h\u{1B}[2J"
        for (offset, text) in cell.enumerated() {
            output += "\u{1B}[\(offset + 1);1H\(text)\u{1B}[\(offset + 1);\(columns - 2)H█"
        }
        for (offset, text) in scheme.enumerated() {
            output += "\u{1B}[\(offset + 10);1H\(text)"
        }
        output += "\u{1B}[20;1H"
        terminal.receive(Data(output.utf8))
        try await settle()
        let grid = try geometry(terminal)
        let whole = try #require(URL(string:
            "https://github.com/manaflow-ai/waycar/pull/1234/files?diff=split&w=1#diff-abcdef0123456789-long-anchor-name"))
        let docs = try #require(URL(string: "https://example.com/a/b/c/d/e/f/g/h/i/j/kk/docs"))

        for (column, row) in [(20, 2), (10, 3), (8, 4)] {
            #expect(
                terminal.tapLink(at: grid.point(column: column, row: row)) == .openLink(.web(whole)),
                "row \(row)")
        }
        #expect(terminal.tapLink(at: grid.point(column: 45, row: 9)) == .openLink(.web(docs)))
        #expect(terminal.tapLink(at: grid.point(column: 10, row: 10)) == .openLink(.web(docs)))
    }

    /// OpenCode draws its scrollbar's thumb on some rows only, so of two
    /// rows a URL wrapped across, one may end in it and the other in text.
    /// A tap on either opens the whole URL, in its answer and in its `┃`
    /// cell, the thumb on the head or on the tail.
    @Test func webLinksJoinWhereOpenCodesScrollbarThumbCoversOneRow() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        terminal.onPreviewFile = { _ in }
        terminal.layoutIfNeeded()
        try await settle()
        let columns = try #require(terminal.measuredGrid?.columns)
        try #require(columns >= 60)
        let answer = (
            head: "     See https://example.com/waycar/untested/links-and-",
            tail: "     paths-check-0123456789 and docs/plan.md and /tmp/")
        let cell = (
            head: "  ┃  Reply with exactly: See https://example.com/waycar/",
            tail: "  ┃  untested/links-and-paths-check-0123456789 and docs/")
        let pairs: [(head: String, tail: String, thumbOnHead: Bool)] = [
            (answer.head, answer.tail, true),
            (cell.head, cell.tail, true),
            (cell.head, cell.tail, false),
        ]
        var output = "\u{1B}[?1049h\u{1B}[2J"
        for (offset, pair) in pairs.enumerated() {
            let row = 3 * offset + 1
            output += "\u{1B}[\(row);1H\(pair.head)\u{1B}[\(row + 1);1H\(pair.tail)"
            output += "\u{1B}[\(pair.thumbOnHead ? row : row + 1);\(columns - 2)H█"
        }
        output += "\u{1B}[20;1H"
        terminal.receive(Data(output.utf8))
        try await settle()
        let grid = try geometry(terminal)
        let url = try #require(URL(string:
            "https://example.com/waycar/untested/links-and-paths-check-0123456789"))

        for offset in pairs.indices {
            let row = 3 * offset
            #expect(terminal.tapLink(at: grid.point(column: 40, row: row)) == .openLink(.web(url)), "row \(row)")
            #expect(
                terminal.tapLink(at: grid.point(column: 10, row: row + 1)) == .openLink(.web(url)),
                "row \(row + 1)")
        }
    }

    /// Kilo draws its answer's URL as an OSC 8 link to the whole URL and
    /// breaks its label with a cursor move. Its rows joined spell the
    /// target, so a tap on either opens it as drawn rather than asking;
    /// a link whose rows spell something else still asks. Bytes are Kilo's
    /// at 60 columns through `herdr terminal attach`.
    @Test func aSplitOSC8LabelSpellingItsTargetOpensIt() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        terminal.onPreviewFile = { _ in }
        terminal.onConfirmLink = { _ in }
        terminal.layoutIfNeeded()
        try await settle()
        let columns = try #require(terminal.measuredGrid?.columns)
        try #require(columns >= 60)
        let target = "https://example.com/waycar/untested/links-and-paths-check-0123456789"
        let other = "https://example.com/elsewhere"
        var output = "\u{1B}[?1049h\u{1B}[2J"
        output += "\u{1B}[8;1H     \u{1B}[0;38;2;250;250;249;48;2;12;10;9mSee \u{1B}]8;;\(target)\u{1B}\\"
            + "https://example.com/waycar/untested/links-and-\u{1B}[0;38;2;255;255;255;48;2;12;10;9m"
            + "\u{1B}]8;;\u{1B}\\     \u{1B}[9;1H     \u{1B}[0;38;2;250;250;249;48;2;12;10;9m"
            + "\u{1B}]8;;\(target)\u{1B}\\paths-check-0123456789\u{1B}]8;;\u{1B}\\ and docs/plan.md and /tmp/"
        output += "\u{1B}[12;6HSee \u{1B}]8;;\(other)\u{1B}\\https://example.com/waycar/untested/links-and-"
            + "\u{1B}[13;6Hpaths-check-0123456789\u{1B}]8;;\u{1B}\\ and more"
        output += "\u{1B}[20;1H"
        terminal.receive(Data(output.utf8))
        try await settle()
        let grid = try geometry(terminal)
        let url = try #require(URL(string: target))
        let elsewhere = try #require(URL(string: other))

        #expect(terminal.tapLink(at: grid.point(column: 20, row: 7)) == .openLink(.web(url)))
        #expect(terminal.tapLink(at: grid.point(column: 10, row: 8)) == .openLink(.web(url)))
        #expect(terminal.tapLink(at: grid.point(column: 20, row: 11)) == .confirmLink(.web(elsewhere)))
        #expect(terminal.tapLink(at: grid.point(column: 10, row: 12)) == .confirmLink(.web(elsewhere)))
    }

    /// Claude Code and Pi move a word that fits down whole, so a URL that
    /// only ended its row at the grid's edge opens as drawn, and a tap on
    /// the URL-ish word below it (`README.md`, `follow-up`, `e.g.`, `v1.2`,
    /// `10:30`) opens no URL glued to it — as the Attach Links list reads
    /// those rows. Claude indents its reply two cells, Pi one.
    @Test func webLinksEndingAtTheEdgeStayApartFromAURLishWordBelow() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        terminal.onPreviewFile = { _ in }
        terminal.onConfirmLink = { _ in }
        terminal.layoutIfNeeded()
        try await settle()
        let columns = try #require(terminal.measuredGrid?.columns)
        let replies: [(url: String, next: String)] = [
            (url: "https://example.com/docs", next: "README.md is the place to look."),
            (url: "https://example.com/plan", next: "follow-up items are listed."),
            (url: "https://example.com/guide", next: "e.g. the second section."),
            (url: "https://example.com/notes", next: "v1.2 shipped on Tuesday."),
            (url: "https://example.com/meet", next: "10:30 is when we start."),
        ]
        let prose = String(repeating: "Alpha bravo charlie delta echo ", count: 8)
        for reply in replies {
            let url = try #require(URL(string: reply.url))
            // Claude's rows, then Pi's; each URL fills the row's last cell.
            for indent in [2, 1] {
                let words = prose.prefix(columns - indent - 1 - reply.url.count)
                let head = String(repeating: " ", count: indent) + words + " " + reply.url
                try #require(head.count == columns)
                let output = "\u{1B}[?1049h\u{1B}[2J\u{1B}[1;1H\(head)\u{1B}[2;3H\(reply.next)\u{1B}[20;1H"
                terminal.receive(Data(output.utf8))
                try await settle()
                let grid = try geometry(terminal)

                #expect(
                    terminal.tapLink(at: grid.point(column: columns - 3, row: 0)) == .openLink(.web(url)),
                    "\(reply.url) above \(reply.next)")
                if case .openLink(.web(let glued))? = terminal.tapLink(at: grid.point(column: 3, row: 1)) {
                    Issue.record("\(reply.next) opened \(glued)")
                }
            }
        }
    }

    /// Where the screen alone cannot tell, the URLs the Agent's transcript
    /// and stream hold whole settle a tap as they settle the Attach Links
    /// list: OpenCode's `…/untested/` above a last segment with nothing of
    /// a URL in it opens whole once the stream printed it, and a URL as
    /// long as its row (Pi's, alone on it) opens as the transcript has it
    /// rather than glued to `README.md` below. Without them, the screen's
    /// own reading stands.
    @Test func knownTargetsSettleARowBreakForATap() async throws {
        let (terminal, window, _) = try await makeTerminal()
        defer { window.isHidden = true }
        terminal.onPreviewFile = { _ in }
        terminal.onConfirmLink = { _ in }
        terminal.layoutIfNeeded()
        try await settle()
        let columns = try #require(terminal.measuredGrid?.columns)
        try #require(columns >= 60)
        let head = "https://example.com/waycar/untested/"
        let segmented = head + "averyveryverylongsegmentname"
        // Pi's row: indented five cells, a cell short of the edge.
        let alone = "https://docs.example.com/guide/"
            + String(repeating: "abcdefghij", count: 12).prefix(columns - 6 - 31)
        var output = "\u{1B}[?1049h\u{1B}[2J"
        output += "\u{1B}[1;6HRead \(head)\u{1B}[2;6Haveryveryverylongsegmentname now."
        output += "\u{1B}[4;6H\(alone)\u{1B}[5;6HREADME.md has more.\u{1B}[20;1H"
        terminal.receive(Data(output.utf8))
        try await settle()
        let grid = try geometry(terminal)
        try #require(5 + alone.count == columns - 1)
        func web(_ text: String) throws -> TerminalTapAction {
            .openLink(.web(try #require(URL(string: text))))
        }

        #expect(try terminal.tapLink(at: grid.point(column: 20, row: 0)) == web(head))

        terminal.knownLinkTargets = {
            AttachKnownTargets(transcript: [alone], printed: [segmented])
        }
        #expect(try terminal.tapLink(at: grid.point(column: 20, row: 0)) == web(segmented))
        #expect(try terminal.tapLink(at: grid.point(column: 10, row: 1)) == web(segmented))
        #expect(try terminal.tapLink(at: grid.point(column: 20, row: 3)) == web(alone))
        if case .openLink(.web(let glued))? = terminal.tapLink(at: grid.point(column: 8, row: 4)) {
            Issue.record("README.md opened \(glued)")
        }
    }

    // MARK: - Fixture

    private static let claudeURL = "https://claude.ai/code/routines/trig_01Ur4tPocEZW828mbGT8RmRC"

    /// An Agent pane as `herdr terminal attach` shows it: the alternate
    /// screen with every mouse tracking mode on, and Claude Code's link
    /// wrapping into a second row.
    private func showHerdrLink(_ terminal: WaycarTerminalView) async throws {
        terminal.layoutIfNeeded()
        try await settle()
        var output = "\u{1B}[?1049h\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1003h\u{1B}[?1006h"
        output += "\u{1B}[2J\u{1B}[H"
        output += "go to \(Self.claudeURL).\r\n\r\n"
        output += "plain words here\r\n\r\n\r\n"
        terminal.receive(Data(output.utf8))
        try await settle()
    }

    private final class Sent {
        var bytes = Data()
        func removeAll() { bytes.removeAll() }
    }

    private struct Grid {
        let geometry: TerminalCellGeometry

        func point(column: Int, row: Int, x: CGFloat = 0.5, y: CGFloat = 0.5) -> CGPoint {
            geometry.point(in: TerminalCellPosition(column: column, row: row), x: x, y: y)
        }
    }

    private func makeTerminal() async throws -> (WaycarTerminalView, UIWindow, Sent) {
        let sent = Sent()
        let terminal = TerminalScreenView.makeConfiguredTerminal(onSend: { sent.bytes.append($0) })
        // 60 columns, the width the captured rows below were drawn at: 390
        // pt holds 60 of a 3x iPhone's cells. A 2x iPad's cells are wider in
        // points, so it is widened to 60 there. The geometry tests use is
        // read back rather than assumed.
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let controller = UIViewController()
        controller.view = terminal
        let window = try await makeTestWindow(frame: terminal.bounds, rootViewController: controller)
        terminal.layoutIfNeeded()
        if let cells = terminal.touchCellGeometry(), cells.columns < 60 {
            window.frame.size.width = 2 * cells.origin.x + 60.5 * cells.cellSize.width
            terminal.layoutIfNeeded()
        }
        return (terminal, window, sent)
    }

    private func show(_ terminal: WaycarTerminalView, tracking: Bool = false) async throws {
        terminal.layoutIfNeeded()
        try await settle()
        let columns = try #require(terminal.measuredGrid?.columns)
        let url = Self.longURL
        #expect(url.count + "see ".count > columns, "the URL must wrap")
        var output = "\u{1B}[2J\u{1B}[H"
        output += "see \(url). more\r\n"
        output += "file src/foo/bar.swift:12:3 and ~/pic.png\r\n"
        output += "\u{1B}]8;;https://osc8.example/x\u{1B}\\LABEL\u{1B}]8;;\u{1B}\\ tail\r\n"
        output += "mailto:someone@example.com\r\n"
        output += "a beta gamma delta\r\n"
        output += "see \u{1B}]8;;https://same.example/y\u{1B}\\https://same.example/y\u{1B}]8;;\u{1B}\\\r\n"
        output += "\u{1B}]8;;file:///etc/hosts\u{1B}\\hosts\u{1B}]8;;\u{1B}\\\r\n"
        output += "\u{1B}]8;;https://osc8.example/x\u{1B}\\   ab\u{1B}]8;;\u{1B}\\\r\n"
        output += "file:///etc/hosts\r\n"
        if tracking {
            output += "\u{1B}[?1000;1002;1003;1006h"
        }
        terminal.receive(Data(output.utf8))
        try await settle()
    }

    private func geometry(_ terminal: WaycarTerminalView) throws -> Grid {
        Grid(geometry: try #require(terminal.touchCellGeometry()))
    }

    private func settle() async throws {
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(50))
            await Task.yield()
        }
    }
}
