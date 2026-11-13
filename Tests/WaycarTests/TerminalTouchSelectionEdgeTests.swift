import Foundation
@testable import GhosttyTerminal
import Testing
import UIKit

@testable import Waycar

/// The edges of link taps and touch selection against the live Ghostty
/// surface: link text that only starts with its target, handles whose touch
/// areas overlap or meet the view's edge, and a selection partly scrolled away.
@MainActor
@Suite(.serialized)
struct TerminalTouchSelectionEdgeTests {
    /// An OSC 8 target that is only the start of the text drawn over it is not
    /// what the text reads as: the tap asks before opening it.
    @Test func linksDrawnOverLongerTextAreConfirmed() async throws {
        let (terminal, window) = try await makeTerminal()
        defer { window.isHidden = true }
        terminal.onPreviewFile = { _ in }
        terminal.onConfirmLink = { _ in }
        try await show(terminal)
        let grid = try geometry(terminal)

        // `https://a.example` over `https://a.example.b.example/`, tapped on
        // a cell the target's text covers and on one past it.
        let short = try #require(URL(string: "https://a.example"))
        #expect(terminal.tapLink(at: grid.point(column: 3, row: 0)) == .confirmLink(.web(short)))
        #expect(terminal.tapLink(at: grid.point(column: 20, row: 0)) == .confirmLink(.web(short)))
        // `~/k` over `~/k.pub`.
        #expect(
            terminal.tapLink(at: grid.point(column: 5, row: 1))
                == .confirmLink(.file(TerminalFileReference(path: "~/k"))))
    }

    /// A target that is exactly its text still opens at once, with prose
    /// brackets, punctuation and blanks around it.
    @Test func linksWhoseTextIsTheirTargetStillOpen() async throws {
        let (terminal, window) = try await makeTerminal()
        defer { window.isHidden = true }
        terminal.onPreviewFile = { _ in }
        terminal.onConfirmLink = { _ in }
        try await show(terminal)
        let grid = try geometry(terminal)

        let bracketed = try #require(URL(string: "https://c.example/p"))
        #expect(terminal.tapLink(at: grid.point(column: 5, row: 2)) == .openLink(.web(bracketed)))
        let spaced = try #require(URL(string: "https://d.example"))
        #expect(terminal.tapLink(at: grid.point(column: 8, row: 3)) == .openLink(.web(spaced)))
    }

    /// Output scrolls a selection's start off the top. Dragging the end handle,
    /// which is still on screen, must not re-anchor the selection at the top
    /// of the viewport and lose the part scrolled away.
    @Test func theVisibleEndDoesNotDragWhileTheOtherIsScrolledAway() async throws {
        let (terminal, window) = try await makeTerminal()
        defer { window.isHidden = true }
        try await show(terminal)
        let grid = try geometry(terminal)
        terminal.beginTouchSelection(at: grid.point(column: 30, row: 0))
        terminal.moveTouchSelectionDrag(to: grid.point(column: 3, row: 2))
        terminal.finishTouchSelectionDrag(presentingMenu: false)
        let selected = try #require(terminal.surface?.readSelection())
        #expect(selected.hasPrefix("tail"))

        // The cursor sits on row 5: this many line feeds scroll one row.
        let rows = try #require(terminal.measuredGrid?.rows)
        terminal.receive(Data(String(repeating: "\n", count: rows - 5).utf8))
        try await settle()
        let range = try #require(terminal.touchSelectionRange())
        #expect(range.startIsClamped)
        #expect(!range.endIsClamped)

        terminal.beginHandleDrag(.end, at: grid.point(column: range.end.column, row: range.end.row, x: 0.9, y: 1.3))
        terminal.moveTouchSelectionDrag(to: grid.point(column: 10, row: 3, x: 0.9, y: 1.3))
        terminal.finishTouchSelectionDrag(presentingMenu: false)
        #expect(terminal.surface?.readSelection() == selected)
    }

    /// On a one-cell selection the two handles' touch areas overlap; a finger
    /// on either knob takes that handle.
    @Test func eachKnobOfAShortSelectionTakesItsOwnHandle() async throws {
        let (terminal, window) = try await makeTerminal()
        defer { window.isHidden = true }
        try await show(terminal)
        let grid = try geometry(terminal)
        terminal.beginTouchSelection(at: grid.point(column: 2, row: 4))
        terminal.finishTouchSelectionDrag(presentingMenu: false)
        #expect(terminal.surface?.readSelection() == "x")

        let (start, end) = terminal.touchSelectionHandles()
        #expect(!start.isHidden)
        #expect(!end.isHidden)
        #expect(terminal.hitTest(start.convert(start.knobCenter, to: terminal), with: nil) === start)
        #expect(terminal.hitTest(end.convert(end.knobCenter, to: terminal), with: nil) === end)
    }

    /// The terminal clips its handles and takes no touch outside its bounds:
    /// on the top and bottom rows a knob stays inside, where it can be seen and
    /// grabbed.
    @Test func knobsOnTheEdgeRowsStayInsideTheView() async throws {
        let (terminal, window) = try await makeTerminal()
        defer { window.isHidden = true }
        try await show(terminal)
        let grid = try geometry(terminal)
        let rows = try #require(terminal.measuredGrid?.rows)

        // "tail" on the top row.
        terminal.beginTouchSelection(at: grid.point(column: 30, row: 0))
        terminal.finishTouchSelectionDrag(presentingMenu: false)
        let top = terminal.touchSelectionHandles().0
        let topKnob = top.convert(top.knobCenter, to: terminal)
        #expect(terminal.bounds.contains(topKnob))
        #expect(terminal.hitTest(topKnob, with: nil) === top)
        terminal.clearSelection()

        terminal.receive(Data("\u{1B}[\(rows);1Hbottom".utf8))
        try await settle()
        terminal.beginTouchSelection(at: grid.point(column: 2, row: rows - 1))
        terminal.finishTouchSelectionDrag(presentingMenu: false)
        #expect(terminal.surface?.readSelection() == "bottom")
        let bottom = terminal.touchSelectionHandles().1
        let bottomKnob = bottom.convert(bottom.knobCenter, to: terminal)
        #expect(terminal.bounds.contains(bottomKnob))
        #expect(terminal.hitTest(bottomKnob, with: nil) === bottom)
    }

    // MARK: - Fixture

    private struct Grid {
        let geometry: TerminalCellGeometry

        func point(column: Int, row: Int, x: CGFloat = 0.5, y: CGFloat = 0.5) -> CGPoint {
            geometry.point(in: TerminalCellPosition(column: column, row: row), x: x, y: y)
        }
    }

    private func makeTerminal() async throws -> (WaycarTerminalView, UIWindow) {
        let terminal = TerminalScreenView.makeConfiguredTerminal(onSend: { _ in })
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let controller = UIViewController()
        controller.view = terminal
        let window = try await makeTestWindow(frame: terminal.bounds, rootViewController: controller)
        return (terminal, window)
    }

    private func show(_ terminal: WaycarTerminalView) async throws {
        terminal.layoutIfNeeded()
        try await settle()
        func link(_ target: String, _ text: String) -> String {
            "\u{1B}]8;;\(target)\u{1B}\\\(text)\u{1B}]8;;\u{1B}\\"
        }
        var output = "\u{1B}[2J\u{1B}[H"
        output += link("https://a.example", "https://a.example.b.example/") + " tail\r\n"
        output += "see " + link("~/k", "~/k.pub") + "\r\n"
        output += "(" + link("https://c.example/p", "https://c.example/p") + ").\r\n"
        output += "go " + link("https://d.example", "https://d.example") + " now\r\n"
        output += "a x b\r\n"
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
