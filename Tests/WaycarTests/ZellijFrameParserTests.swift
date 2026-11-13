import Foundation
import Testing

@testable import Waycar

@Suite("Zellij frame parser")
struct ZellijFrameParserTests {
    @Test func capturedFrameByteByByte() throws {
        var parser = ZellijFrameParser()
        var frames: [ZellijFrame] = []
        let input =
            "login chatter café\r\n"
            + ZellijFixtures.capturedFrame.replacingOccurrences(of: "\n", with: "\r\n")
        for byte in input.utf8 { frames += parser.feed(Data([byte])).frames }
        let frame = try #require(frames.first)
        #expect(frames.count == 1)
        #expect(frame.sessions == [.init(name: "fixture", closed: false)])
        #expect(frame.panes["fixture"]?.count == 2)
        let pane = try #require(frame.panes["fixture"]?.first { $0.id == 0 })
        #expect(pane.rootStatus?.agentStatus == .working)
        #expect(pane.paneCommand == "sleep 600")
        #expect(pane.paneRows == 48)
        #expect(parser.feed(Data("\n".utf8)).heartbeat)
    }

    @Test func multipleFramesAndBadSessionJSON() throws {
        let frame = ZellijFixtures.frame(
            panes: "[broken", document: #"{"version":1,"pane":"zellij:fixture/terminal_0","status":"idle"}"#)
        #expect(frame.panes["fixture"] == [])
        #expect(frame.closedSessions == [.init(name: "closed", closed: true)])
        #expect(frame.documents["zellij:fixture/terminal_0"]?.status == .idle)
        var parser = ZellijFrameParser()
        #expect(
            parser.feed(Data((ZellijFixtures.capturedFrame + ZellijFixtures.capturedFrame).utf8)).frames.count
                == 2)
        let minimal = try JSONDecoder().decode(
            ZellijPaneRecord.self, from: Data(#"{"id":2,"tab_id":8,"future":true}"#.utf8))
        #expect(minimal.title == nil)
        #expect(minimal.isVisible)
        let tab = try JSONDecoder().decode(
            ZellijTabRecord.self, from: Data(#"{"tab_id":8,"future":true}"#.utf8))
        #expect(tab.position == nil)
    }

    @Test func listingMetadataIsParsedFromTheEnd() {
        #expect(ZellijSessionRecord.parse("work [Created] (current)") == .init(name: "work", closed: false))
        #expect(
            ZellijSessionRecord.parse("foo [Created] [Created] (current)")
                == .init(name: "foo [Created]", closed: false))
        #expect(
            ZellijSessionRecord.parse("work [Created] (EXITED - attach to resurrect)")
                == .init(name: "work", closed: true))
        #expect(
            ZellijSessionRecord.parse("my [Created yesterday] (current) [Created] ")
                == .init(name: "my [Created yesterday] (current)", closed: false))
        #expect(
            ZellijSessionRecord.parse("my (EXITED - attach to resurrect) [Created] ")
                == .init(name: "my (EXITED - attach to resurrect)", closed: false))
        #expect(ZellijSessionRecord.parse("continuation without metadata") == nil)
        #expect(ZellijSessionRecord.parse("-hidden [Created]") == nil)
        #expect(ZellijSessionRecord.parse("-hidden [Created] (EXITED - attach to resurrect)") == nil)
        #expect(ZellijSessionRecord.parse("bad\tname [Created]") == nil)
        #expect(ZellijPaneID("zellij:-hidden/terminal_0") == nil)
    }

    @Test func lineFeedNameIsInvisibleWhenItsFragmentCannotResolvePanes() {
        // Raw ls for a session named "bad\\nname" prints "bad\\nname [Created 0s ago] ".
        // The watcher's anchored sed drops "bad" and normalizes the final fragment.
        var parser = ZellijFrameParser()
        let text = "\u{1E}B\nbad\nname [Created] \n\u{1E}P\n\u{1E}Sname\n\u{1E}H\n\u{1E}E\n"
        let frame = parser.feed(Data(text.utf8)).frames.first ?? ZellijFrame()
        #expect(frame.sessions == [.init(name: "name", closed: false)])
        #expect(frame.panes["name"] == [])
        #expect(ZellijSnapshotBuilder.snapshot(frame: frame).workspaces.isEmpty)
    }

    @Test func recoversAfterOversizedChatterOrFrame() {
        var parser = ZellijFrameParser()
        _ = parser.feed(Data(repeating: 65, count: ZellijFrameParser.maximumBytes + 1))
        #expect(parser.feed(Data(("\n" + ZellijFixtures.capturedFrame).utf8)).frames.count == 1)
        _ = parser.feed(Data("\u{1E}B\n".utf8))
        let chunk = Data((String(repeating: "x", count: 1023) + "\n").utf8)
        for _ in 0..<(ZellijFrameParser.maximumBytes / chunk.count + 1) { _ = parser.feed(chunk) }
        #expect(parser.feed(Data("\u{1E}E\n".utf8)).frames.isEmpty)
        #expect(parser.feed(Data(ZellijFixtures.capturedFrame.utf8)).frames.count == 1)
    }
}
