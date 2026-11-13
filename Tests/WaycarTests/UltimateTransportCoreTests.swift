import Foundation
import Testing

@testable import Waycar

@Suite("Ultimate HTTP, SSE, discovery and wire contracts")
struct UltimateTransportCoreTests {
    @Test("HTTP content-length and chunked framing survive every byte boundary")
    func httpFraming() throws {
        let responses = [
            "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2;ext=yes\r\nhe\r\n3\r\nllo\r\n0\r\nX-Trailer: yes\r\n\r\n",
            "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nConnection: close\r\n\r\nhello"
        ]
        for response in responses {
            var decoder = UltimateHTTPDecoder()
            var body = Data()
            for byte in response.utf8 { body.append(try decoder.append(Data([byte]))) }
            body.append(try decoder.append(Data(), eof: true))
            #expect(String(decoding: body, as: UTF8.self) == "hello")
            #expect(decoder.head?.status == 200)
            #expect(decoder.isComplete)
        }
    }

    @Test("HTTP rejects truncated and ambiguous framing")
    func malformedHTTP() throws {
        for response in [
            "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhi",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nhi",
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n"
        ] {
            #expect(throws: UltimateHTTPError.malformedResponse) {
                var decoder = UltimateHTTPDecoder()
                _ = try decoder.append(Data(response.utf8), eof: true)
            }
        }
    }

    @Test("HTTP requests use a loopback authority and close only their channel")
    func clientRoundTrip() async throws {
        let channel = UltimateScriptedChannel([
            Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)
        ])
        let client = UltimateHTTPClient(port: 4747, openChannel: { channel })
        let response = try await client.request(method: "POST", path: "/api/conversations/39/submit", body: Data("{}".utf8))
        #expect(response.head.status == 200)
        #expect(response.body == Data("{}".utf8))
        let writes = await channel.writes
        let text = String(decoding: try #require(writes.first), as: UTF8.self)
        #expect(text.contains("Host: 127.0.0.1:4747\r\nConnection: close\r\n"))
        #expect(text.contains("Content-Length: 2\r\n\r\n{}"))
        #expect(await channel.closed)
    }

    @Test("live Mac SSE fixture decodes stream id and conversations")
    func liveSSEFixture() throws {
        // Captured from Mac Ultimate /api/events, 2026-11-01. The stream UUID
        // and local cwd are normalized; event names, data shape and framing
        // are unchanged. system/ui/tasks events omitted.
        let fixture = "retry: 500\n\nevent: stream\ndata: {\"id\":\"fixture-stream\"}\n\nevent: conversations\ndata: [{\"id\":1,\"cwd\":\"/work/ultimate\",\"busy\":false},{\"id\":28,\"label\":\"lander\",\"title\":\"@lander\",\"cwd\":\"/work/ultimate/lander\",\"busy\":false},{\"id\":39,\"cwd\":\"/work/ultimate\",\"busy\":false}]\n\n: heartbeat\n\n"
        var parser = UltimateEventStream()
        var events: [UltimateServerEvent] = []
        for byte in fixture.utf8 { events += try parser.append(Data([byte])) }
        #expect(parser.retryMilliseconds == 500)
        #expect(events.map(\.name) == ["stream", "conversations"])
        let summaries = try UltimateConversationSummary.decodeList(Data(events[1].data.utf8))
        #expect(summaries.map(\.id) == [1, 28, 39])
        #expect(summaries[1].label == "lander")
    }

    @Test("SSE supports CRLF, multiline data, UTF-8 and ignores incomplete events")
    func sseBoundaries() throws {
        var parser = UltimateEventStream()
        let input = "\u{feff}: hello\r\nid: 5\revent: view\rdata: 39\r\ndata: {\"text\":\"👁\"}\r\n\r\ndata: incomplete"
        var events: [UltimateServerEvent] = []
        for byte in input.utf8 { events += try parser.append(Data([byte])) }
        #expect(events == [UltimateServerEvent(name: "view", data: "39\n{\"text\":\"👁\"}", id: "5")])
    }

    @Test("HTTP event streams dechunk SSE before dispatch")
    func clientEvents() async throws {
        let event = "event: conversations\ndata: []\n\n"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n\(String(event.utf8.count, radix: 16))\r\n\(event)\r\n0\r\n\r\n"
        let channel = UltimateScriptedChannel(response.utf8.map { Data([$0]) })
        let client = UltimateHTTPClient(port: 4747, openChannel: { channel })
        var events: [UltimateServerEvent] = []
        for try await event in client.events() { events.append(event) }
        #expect(events.map(\.name) == ["conversations"])
        #expect(events.first?.data == "[]")
        #expect(await channel.closed)
    }

    @Test("discovery parses every lock and ignores malformed candidates")
    func discovery() {
        let records = [
            "/home/user/.ultimate/projects/demo-hash", "{\"pid\":21,\"port\":4747,\"project\":\"/work/demo\"}", "{\"name\":\"Demo\",\"unknown\":true}",
            "/home/user/.ultimate/projects/next-hash", "{\"pid\":22,\"port\":4748,\"project\":\"/work/next\"}", "broken metadata",
            "/home/user/.ultimate/projects/dead-hash", "{\"pid\":0,\"port\":4749,\"project\":\"/work/dead\"}", "{}",
            "/home/user/.ultimate/projects/bad-hash", "not json", "{}"
        ]
        let data = Data((records.joined(separator: "\0") + "\0").utf8)
        let candidates = UltimateInstanceDiscovery.parse(data)
        #expect(candidates.map(\.port) == [4747, 4748])
        #expect(candidates.map(\.name) == ["Demo", "next"])
        #expect(candidates.first?.id == "demo-hash")
    }

    @Test("summary lists skip invalid records and accept unknown fields")
    func summaries() throws {
        let data = Data(#"[{"id":1,"busy":true,"future":42},{"id":"bad","busy":false},{"id":2,"busy":false,"parentConversationId":1,"concluded":true}]"#.utf8)
        let summaries = try UltimateConversationSummary.decodeList(data)
        #expect(summaries.map(\.id) == [1, 2])
        #expect(summaries[0].busy)
        #expect(summaries[1].parentConversationId == 1)
        #expect(summaries[1].concluded == true)
    }

    @Test("wire submits steering text and reads history text without tool internals")
    func wireText() throws {
        let request = UltimateSubmitRequest(text: "hello")
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
        #expect(json["whenBusy"]?.stringValue == "steer")
        let submitted = try JSONDecoder().decode(UltimateSubmitResponse.self, from: Data(#"{"submissionId":5,"future":true}"#.utf8))
        #expect(submitted.submissionId == 5)
        let history = try JSONDecoder().decode(UltimateHistoryResponse.self, from: Data(#"{"before":10,"entries":[{"id":13,"kind":"pi.assistant","model":[{"role":"assistant","content":[{"type":"text","text":"Answer"},{"type":"toolCall","name":"bash","arguments":{"secret":"hidden"}}]}]},{"id":12,"kind":"pi.user","model":[{"role":"user","content":"Question"}]},{"id":11,"kind":"future","data":{}},{"bad":true}]}"#.utf8))
        #expect(history.before == 10)
        #expect(history.entries.map(\.id) == [13, 12, 11])
        #expect(history.entries[0].extractedText?.text == "Answer\n\nTool: bash")
        #expect(history.entries[1].extractedText?.text == "Question")
        #expect(history.entries[2].extractedText == nil)
    }
}

private actor UltimateScriptedChannel: UltimateByteChannel {
    private var chunks: [Data]
    private(set) var writes: [Data] = []
    private(set) var closed = false
    init(_ chunks: [Data]) { self.chunks = chunks }
    func write(_ data: Data, timeout: Duration) { writes.append(data) }
    func read(maximumBytes: Int, timeout: Duration) -> Data? {
        chunks.isEmpty ? nil : chunks.removeFirst()
    }
    func close(timeout: Duration) { closed = true }
}
