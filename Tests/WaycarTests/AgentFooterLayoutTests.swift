import Foundation
import Testing

@testable import Waycar

@Suite("Agent footer layout")
struct AgentFooterLayoutTests {
    @Test func lenientDecodingDropsUnknownFieldsAndDefaultsTheRest() throws {
        let json = #"{"lines":[["agent","warp_drive","model"],["state_icon","branch"]],"textSize":"huge"}"#
        let layout = try JSONDecoder().decode(AgentFooterLayout.self, from: Data(json.utf8))
        #expect(layout.lines == [[.row(.agent), .model], [.branch]])
        #expect(layout.textSize == .medium)
        #expect(layout.isEnabled)
    }

    @Test func encodedLayoutRoundTrips() throws {
        let layout = AgentFooterLayout(
            isEnabled: false, lines: [[.row(.custom("ticket")), .cost], [.transport]], textSize: .large)
        let decoded = try JSONDecoder().decode(
            AgentFooterLayout.self, from: JSONEncoder().encode(layout))
        #expect(decoded == layout)
    }

    /// Progress is offered and closes the default first line; a saved
    /// layout names it "progress", which an older build drops on decode.
    @Test func progressIsOfferedAndEndsTheDefaultFirstLine() throws {
        #expect(AgentFooterField(rawValue: "progress") == .progress)
        #expect(AgentFooterField.progress.rawValue == "progress")
        #expect(AgentFooterField.offered.contains(.progress))
        #expect(AgentFooterLayout.default.lines.first?.last == .progress)
        let json = #"{"lines":[["progress","agent"]]}"#
        let layout = try JSONDecoder().decode(AgentFooterLayout.self, from: Data(json.utf8))
        #expect(layout.lines == [[.progress, .row(.agent)]])
    }

    @Test func normalizedDedupsAcrossLinesCapsCountsAndDropsStatusTokens() {
        let fields: [AgentFooterField] = [
            .row(.stateIcon), .row(.agent), .row(.directory), .row(.workspace), .row(.tab),
            .row(.pane), .row(.host), .row(.status), .branch, .model, .context,
        ]
        let layout = AgentFooterLayout(
            isEnabled: true,
            lines: [fields, [.row(.agent), .cost, .row(.stateText)], [.rate], [.backend]],
            textSize: .small
        ).normalized()
        #expect(layout.lines.count == 3)
        #expect(layout.lines[0] == Array(fields.dropFirst().prefix(AgentFooterLayout.maximumFieldsPerLine)))
        #expect(layout.lines[1] == [.cost])
        #expect(layout.lines[2] == [.rate])
        #expect(!layout.contains(.backend))

        let empty = AgentFooterLayout(isEnabled: true, lines: [], textSize: .medium).normalized()
        #expect(empty.lines == [[]])
    }

    @Test func setLineCountGrowsWithEmptyLinesAndShrinksFromTheEnd() {
        var layout = AgentFooterLayout(isEnabled: true, lines: [[.branch]], textSize: .medium)
        layout.setLineCount(5)
        #expect(layout.lines == [[.branch], [], []])
        layout.lines[1] = [.cost]
        layout.setLineCount(0)
        #expect(layout.lines == [[.branch]])
    }

    @Test func shownLinesSkipsEmptyLinesAndCaps() {
        let layout = AgentFooterLayout(isEnabled: true, lines: [[], [.branch], [], [.cost], [.model]], textSize: .medium)
        #expect(layout.shownLines(maximumLines: 3) == [[.branch], [.cost], [.model]])
        #expect(layout.shownLines(maximumLines: 1) == [[.branch]])
        #expect(layout.shownLines(maximumLines: 0).isEmpty)
    }

    @Test func pointSizesFollowTheTableAndShrinkWithMoreLines() {
        #expect(AgentFooterLayout.pointSize(.small, lineCount: 1) == 13)
        #expect(AgentFooterLayout.pointSize(.medium, lineCount: 1) == 15)
        #expect(AgentFooterLayout.pointSize(.large, lineCount: 1) == 18)
        #expect(AgentFooterLayout.pointSize(.small, lineCount: 2) == 10.5)
        #expect(AgentFooterLayout.pointSize(.medium, lineCount: 2) == 12)
        #expect(AgentFooterLayout.pointSize(.large, lineCount: 2) == 14)
        #expect(AgentFooterLayout.pointSize(.small, lineCount: 3) == 8.5)
        #expect(AgentFooterLayout.pointSize(.medium, lineCount: 3) == 10)
        #expect(AgentFooterLayout.pointSize(.large, lineCount: 3) == 11)
        for size in AgentFooterTextSize.allCases {
            #expect(AgentFooterLayout.pointSize(size, lineCount: 1)
                >= AgentFooterLayout.pointSize(size, lineCount: 2))
            #expect(AgentFooterLayout.pointSize(size, lineCount: 2)
                >= AgentFooterLayout.pointSize(size, lineCount: 3))
        }
    }

    @Test func fittedPointSizeClampsToTheBandWithASevenPointFloor() {
        #expect(AgentFooterLayout.fittedPointSize(nominal: 15, lineCount: 1, availableHeight: 40) == 15)
        #expect(AgentFooterLayout.fittingLineCount(3, availableHeight: 0) == 0)
        #expect(AgentFooterLayout.fittedPointSize(nominal: 11, lineCount: 3, availableHeight: 10) == 7)
        #expect(AgentFooterLayout.fittingLineCount(3, availableHeight: 17) == 2)
        #expect(abs(AgentFooterLayout.fittedPointSize(nominal: 14, lineCount: 2, availableHeight: 24) - 10) < 0.001)
    }
}
