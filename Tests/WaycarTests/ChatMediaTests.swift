import Foundation
import Testing

@testable import Waycar

/// Chat media as the transcript reader sends it, and the local file a
/// fetched item becomes.
@Suite("Chat media")
struct ChatMediaTests {
    private let header =
        #"{"type":"header","v":1,"kind":"omp","status":"ok","transcript":null,"activity":null,"turn_open":false,"truncated":false,"after_found":true,"error":null}"#

    /// `mediaJSON` may span lines for readability; NDJSON needs one line.
    private func decodeMedia(_ mediaJSON: String) throws -> [ChatMedia] {
        let message =
            #"{"type":"message","id":"a1","role":"assistant","text":"Here.","ts":"2026-09-30T12:00:01.000Z","media":"#
            + mediaJSON.replacingOccurrences(of: "\n", with: " ") + "}"
        let snapshot = try ChatTranscriptDecoding.decode(Data((header + "\n" + message).utf8))
        let reply = try #require(snapshot.messages.first, "a bad media field never costs its message")
        #expect(reply.text == "Here.")
        return reply.media
    }

    @Test func blobAndInlineItemsDecodeInOrder() throws {
        let media = try decodeMedia(
            #"""
            [{"id":"blob:sha256:ab","kind":"image","mime":"image/webp","path":"/Users/x/.omp/agent/blobs/ab"},
             {"id":"inline:9:/p","kind":"image","mime":null,"inline":{"transcript":"/t/s.jsonl","offset":9,"pointer":"/message/content/0/data"}}]
            """#)
        #expect(
            media == [
                ChatMedia(
                    id: "blob:sha256:ab", kind: .image, mime: "image/webp",
                    source: .hostFile(path: "/Users/x/.omp/agent/blobs/ab")),
                ChatMedia(
                    id: "inline:9:/p", kind: .image, mime: nil,
                    source: .inline(transcript: "/t/s.jsonl", offset: 9, pointer: "/message/content/0/data")),
            ])
    }

    /// The opencode shapes: a `file` attachment (a Host path) and a
    /// session-inline attachment (base64 in the opencode export document);
    /// a Kilo export item names its harness in `kind`.
    @Test func fileAndSessionInlineItemsDecode() throws {
        let media = try decodeMedia(
            #"""
            [{"id":"file:/Users/me/demo/shot.png","kind":"file","mime":"image/png","path":"/Users/me/demo/shot.png"},
             {"id":"inline:/messages/0/parts/1/url","kind":"image","mime":"image/png","inline":{"session":"ses_demo","pointer":"/messages/0/parts/1/url"}},
             {"id":"inline:/messages/0/parts/2/url","kind":"video","mime":null,"inline":{"session":"ses_demo","pointer":"/messages/0/parts/2/url"}},
             {"id":"inline:/messages/1/parts/0/url","kind":"image","mime":"image/png","inline":{"session":"ses_kilo","pointer":"/messages/1/parts/0/url","kind":"kilo"}}]
            """#)
        #expect(
            media == [
                ChatMedia(
                    id: "file:/Users/me/demo/shot.png", kind: .file, mime: "image/png",
                    source: .hostFile(path: "/Users/me/demo/shot.png")),
                ChatMedia(
                    id: "inline:/messages/0/parts/1/url", kind: .image, mime: "image/png",
                    source: .sessionInline(
                        session: "ses_demo", pointer: "/messages/0/parts/1/url", agentKind: nil)),
                ChatMedia(
                    id: "inline:/messages/0/parts/2/url", kind: .video, mime: nil,
                    source: .sessionInline(
                        session: "ses_demo", pointer: "/messages/0/parts/2/url", agentKind: nil)),
                ChatMedia(
                    id: "inline:/messages/1/parts/0/url", kind: .image, mime: "image/png",
                    source: .sessionInline(
                        session: "ses_kilo", pointer: "/messages/1/parts/0/url", agentKind: "kilo")),
            ])
    }

    @Test func itemsWithNoOrBothSourcesAnUnknownKindOrBadFieldsAreSkipped() throws {
        let media = try decodeMedia(
            #"""
            [{"id":"none","kind":"image","mime":"image/png"},
             {"id":"both","kind":"image","mime":"image/png","path":"/a.png","inline":{"transcript":"/t","offset":1,"pointer":"/x"}},
             {"id":"audio","kind":"audio","mime":"audio/mp3","path":"/a.mp3"},
             {"id":"bad-offset","kind":"image","mime":"image/png","inline":{"transcript":"/t","offset":"9","pointer":"/x"}},
             {"id":"negative","kind":"image","mime":"image/png","inline":{"transcript":"/t","offset":-1,"pointer":"/x"}},
             {"id":"empty-path","kind":"image","mime":"image/png","path":""},
             {"id":"no-path","kind":"file","mime":null},
             {"id":"both-forms","kind":"image","mime":"image/png","inline":{"session":"ses","transcript":"/t","offset":1,"pointer":"/x"}},
             {"id":"empty-session","kind":"image","mime":"image/png","inline":{"session":"","pointer":"/x"}},
             {"id":"no-pointer","kind":"image","mime":"image/png","inline":{"session":"ses"}},
             {"id":"transcript-no-offset","kind":"image","mime":"image/png","inline":{"transcript":"/t","pointer":"/x"}},
             {"kind":"image","mime":"image/png","path":"/no-id.png"},
             7,
             {"id":"kept","kind":"video","mime":"video/mp4","path":"/clip.mp4","extra":true}]
            """#)
        #expect(media.map(\.id) == ["kept"])
        #expect(media.first?.kind == .video)
    }

    /// A `file` attachment's type is unknown, so it gets the larger cap and
    /// waits for a tap like a video.
    @Test func aFileAttachmentUsesTheVideoCapAndLoadsOnTap() {
        let media = ChatMedia(
            id: "file:/Users/me/demo/report.bin", kind: .file, mime: nil,
            source: .hostFile(path: "/Users/me/demo/report.bin"))
        #expect(media.maximumBytes == ChatMedia.maximumVideoBytes)
        #expect(media.loadsOnTap)
    }

    @Test(arguments: [#""none""#, "{}", "null", "3"])
    func aMediaFieldThatIsNoArrayReadsAsNoMedia(json: String) throws {
        #expect(try decodeMedia(json).isEmpty)
    }

    @Test func aMessageWithoutMediaHasNone() throws {
        let line =
            #"{"type":"message","id":"u1","role":"user","text":"Hi","ts":"2026-09-30T12:00:00.000Z"}"#
        let snapshot = try ChatTranscriptDecoding.decode(Data((header + "\n" + line).utf8))
        #expect(snapshot.messages.map(\.media) == [[]])
    }

    @Test func kindFollowsTheExtensionInAnyCase() {
        for ext in ["png", "JPG", "jpeg", "gif", "WebP", "heic", "heif"] {
            #expect(ChatMedia.kind(forPathExtension: ext) == .image, "\(ext)")
        }
        for ext in ["mp4", "MOV", "m4v"] {
            #expect(ChatMedia.kind(forPathExtension: ext) == .video, "\(ext)")
        }
        for ext in ["", "pdf", "svg", "mp3", "txt"] {
            #expect(ChatMedia.kind(forPathExtension: ext) == nil, "\(ext)")
        }
    }

    @Test func aLocalCopysExtensionComesFromThePathThenTheMimeThenTheBytes() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])
        #expect(ChatMedia.fileExtension(path: "/shots/A.JPEG", mime: "image/png", data: png) == "jpeg")
        // A blob path has no extension; its mime names the type.
        #expect(ChatMedia.fileExtension(path: "/blobs/ab12", mime: "image/webp", data: png) == "webp")
        #expect(ChatMedia.fileExtension(path: nil, mime: "video/quicktime", data: Data()) == "mov")
        #expect(ChatMedia.fileExtension(path: nil, mime: nil, data: png) == "png")
        #expect(ChatMedia.fileExtension(path: "/notes.txt", mime: "text/plain", data: Data("hi".utf8)) == nil)
    }

    /// A `.file` attachment keeps its own extension when Quick Look shows
    /// that type in a contained viewer, so it opens as itself; with no
    /// extension anywhere the copy still fails as unsupported.
    @Test func aFileAttachmentKeepsAPreviewableExtension() {
        let pdf = Data("%PDF-1.7 just to be no signature the sniffer knows".utf8)
        #expect(ChatMedia.fileExtension(path: "/docs/report.PDF", mime: nil, data: pdf, kind: .file) == "pdf")
        // A blob path has no extension; the mime's UTType suggestion names it.
        #expect(ChatMedia.fileExtension(path: "/blobs/ab12", mime: "application/pdf", data: pdf, kind: .file) == "pdf")
        // Media types behave as ever, and no extension at all stays unsupported.
        #expect(ChatMedia.fileExtension(path: "/shots/shot.png", mime: nil, data: Data(), kind: .file) == "png")
        #expect(ChatMedia.fileExtension(path: "/clips/demo.mov", mime: nil, data: Data(), kind: .file) == "mov")
        #expect(ChatMedia.fileExtension(path: "/clips/demo.m4v", mime: nil, data: Data(), kind: .file) == "m4v")
        #expect(ChatMedia.fileExtension(path: "/blobs/ab12", mime: nil, data: pdf, kind: .file) == nil)
    }

    /// An Agent-written web page or SVG never renders as a web page in the
    /// app (App Review guideline 2.5.2): a `.file` attachment goes through
    /// the terminal preview's rule, so anything Quick Look would not show in
    /// a contained viewer becomes text.
    @Test func aFileAttachmentOfAnyOtherTypeOpensAsText() {
        let page = Data("<html><body>hi</body></html>".utf8)
        for path in ["/site/index.html", "/site/INDEX.HTM", "/site/page.xhtml", "/art/logo.svg",
                     "/saved/a.webarchive", "/docs/deck.key", "/docs/report.docx"] {
            #expect(ChatMedia.fileExtension(path: path, mime: nil, data: page, kind: .file) == "txt", "\(path)")
        }
        // A blob named only by its mime gets the same rule.
        #expect(ChatMedia.fileExtension(path: "/blobs/ab12", mime: "text/html", data: page, kind: .file) == "txt")
        #expect(ChatMedia.fileExtension(path: "/blobs/ab12", mime: "image/svg+xml", data: page, kind: .file) == "txt")
    }

    @Test func signaturesNameTheirFormats() {
        func ftyp(_ brand: String) -> Data { Data([0, 0, 0, 0x18]) + Data("ftyp\(brand)".utf8) }
        #expect(ChatMedia.sniffedFileExtension(Data([0xFF, 0xD8, 0xFF, 0xE0])) == "jpg")
        #expect(ChatMedia.sniffedFileExtension(Data("GIF89a".utf8)) == "gif")
        #expect(ChatMedia.sniffedFileExtension(Data("RIFF\0\0\0\0WEBP".utf8)) == "webp")
        #expect(ChatMedia.sniffedFileExtension(Data("RIFF\0\0\0\0WAVE".utf8)) == nil)
        #expect(ChatMedia.sniffedFileExtension(ftyp("heic")) == "heic")
        #expect(ChatMedia.sniffedFileExtension(ftyp("qt  ")) == "mov")
        #expect(ChatMedia.sniffedFileExtension(ftyp("isom")) == "mp4")
        #expect(ChatMedia.sniffedFileExtension(Data()) == nil)
    }

    @Test func theMediaReadersExitStatusesMapToTheirErrors() {
        let stderr = Data("boom".utf8)
        #expect(WaycarSSHTransport.chatMediaFailure(exitStatus: 0, stderr: stderr) == nil)
        #expect(
            WaycarSSHTransport.chatMediaFailure(exitStatus: 64, stderr: stderr) as? ChatMediaError
                == .pluginOutdated)
        #expect(
            WaycarSSHTransport.chatMediaFailure(exitStatus: 65, stderr: stderr) as? ChatMediaError
                == .unavailable)
        #expect(
            WaycarSSHTransport.chatMediaFailure(exitStatus: 66, stderr: stderr) as? ChatMediaError
                == .tooLarge)
        #expect(Self.isChannelFailure(WaycarSSHTransport.chatMediaFailure(exitStatus: 1, stderr: stderr)))
        #expect(
            Self.isChannelFailure(
                WaycarSSHTransport.chatMediaFailure(exitStatus: HostWatchdog.stoppedStatus, stderr: stderr)))
    }

    private static func isChannelFailure(_ error: (any Error)?) -> Bool {
        guard case .channelFailed = error as? TransportError else { return false }
        return true
    }

    @Test func theMediaRequestEncodesThePluginsKeys() throws {
        let request = ChatMediaRequest.line(
            transcript: "/t/it's a $(trap).jsonl", offset: 42, pointer: "/message/content/1",
            maxBytes: 99)
        let body = try WaycarSSHTransport.chatMediaRequestJSON(request)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["transcript"] as? String == "/t/it's a $(trap).jsonl")
        #expect(object["offset"] as? Int == 42)
        #expect(object["pointer"] as? String == "/message/content/1")
        #expect(object["max_bytes"] as? Int == 99)
        #expect(object["session"] == nil)
    }

    /// The session form of the reader's request: the export to re-run, the
    /// media item's id (its `#prt_…` tail must still name the part under
    /// the pointer), the pointer into it, and the cap; no transcript
    /// fields, and no `kind` for opencode, the reader's default.
    @Test func theSessionMediaRequestEncodesThePluginsKeys() throws {
        let request = ChatMediaRequest.sessionInline(
            session: "ses_it's a $(trap)", id: "inline:/messages/0/parts/1/url#prt_1",
            pointer: "/messages/0/parts/1/url", agentKind: nil, maxBytes: 99)
        let body = try WaycarSSHTransport.chatMediaRequestJSON(request)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["session"] as? String == "ses_it's a $(trap)")
        #expect(object["id"] as? String == "inline:/messages/0/parts/1/url#prt_1")
        #expect(object["pointer"] as? String == "/messages/0/parts/1/url")
        #expect(object["max_bytes"] as? Int == 99)
        #expect(object["transcript"] == nil)
        #expect(object["offset"] == nil)
        #expect(object["kind"] == nil)
    }

    /// A Kilo export item tells the reader which CLI's export to re-run.
    @Test func aKiloSessionMediaRequestNamesItsHarness() throws {
        let request = ChatMediaRequest.sessionInline(
            session: "ses_ecf088b69ffeFiAu1FQKHe4843", id: "inline:/messages/1/parts/0/url#prt_2",
            pointer: "/messages/1/parts/0/url", agentKind: "kilo", maxBytes: 99)
        let body = try WaycarSSHTransport.chatMediaRequestJSON(request)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["kind"] as? String == "kilo")
        #expect(object["session"] as? String == "ses_ecf088b69ffeFiAu1FQKHe4843")
    }

    /// A chat full of images keeps SSH channels free for its transcript
    /// reads: a Host runs at most `limit` media transfers at once, and the
    /// rest wait their turn rather than fail.
    @Test(.timeLimit(.minutes(1)))
    func aHostRunsAtMostTheLimitOfMediaTransfersAtOnce() async throws {
        let transfers = ChatMediaTransfers()
        let gate = TransferGate()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<5 {
                group.addTask { try await transfers.run { await gate.hold("\(index)") } }
            }
            // Each release lets exactly one waiter in.
            for started in ChatMediaTransfers.limit...5 {
                await gate.waitForStarts(started)
                await gate.release(await gate.started[started - ChatMediaTransfers.limit])
            }
            for id in await gate.started { await gate.release(id) }
            try await group.waitForAll()
        }
        #expect(await gate.maximum == ChatMediaTransfers.limit)
        #expect(await gate.started.count == 5)
    }

    @Test(.timeLimit(.minutes(1)))
    func aThrowingTransferFreesItsSlot() async throws {
        let transfers = ChatMediaTransfers()
        for _ in 0..<ChatMediaTransfers.limit + 1 {
            await #expect(throws: ChatMediaError.unavailable) {
                try await transfers.run { () async throws -> Void in throw ChatMediaError.unavailable }
            }
        }
        let gate = TransferGate()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<ChatMediaTransfers.limit {
                group.addTask { try await transfers.run { await gate.hold("\(index)") } }
            }
            // Hangs (and hits the time limit) if a throw kept its slot.
            await gate.waitForStarts(ChatMediaTransfers.limit)
            for id in await gate.started { await gate.release(id) }
            try await group.waitForAll()
        }
    }

    /// A chat opens at its bottom, whose media ask last.
    @Test(.timeLimit(.minutes(1)))
    func aFreedSlotGoesToTheNewestWaiter() async throws {
        let transfers = ChatMediaTransfers()
        let gate = TransferGate()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<ChatMediaTransfers.limit {
                group.addTask { try await transfers.run { await gate.hold("running \(index)") } }
            }
            await gate.waitForStarts(ChatMediaTransfers.limit)
            group.addTask { try await transfers.run { await gate.hold("older") } }
            try await transfers.waitForWaiters(1)
            group.addTask { try await transfers.run { await gate.hold("newer") } }
            try await transfers.waitForWaiters(2)

            await gate.release(await gate.started[0])
            await gate.waitForStarts(ChatMediaTransfers.limit + 1)
            #expect(await gate.started.last == "newer")

            await gate.release(await gate.started[1])
            await gate.waitForStarts(ChatMediaTransfers.limit + 2)
            #expect(await gate.started.last == "older")
            for id in await gate.started { await gate.release(id) }
            try await group.waitForAll()
        }
    }
}

extension ChatMediaTransfers {
    /// Waits until `count` transfers wait for a slot. The queue is private,
    /// so this reads it by reflection.
    fileprivate func waitForWaiters(_ count: Int) async throws {
        try await waitUntil("transfers should queue for a slot") { self.waiterCount >= count }
    }

    private var waiterCount: Int {
        let waiting = Mirror(reflecting: self).descendant("waiting") as? [CheckedContinuation<Void, Never>]
        return waiting?.count ?? 0
    }
}

/// Transfers that start when run and finish only when released, so the
/// tests step them without sleeping.
private actor TransferGate {
    private(set) var started: [String] = []
    private(set) var maximum = 0
    private var current = 0
    private var held: [String: CheckedContinuation<Void, Never>] = [:]
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func hold(_ id: String) async {
        started.append(id)
        current += 1
        maximum = max(maximum, current)
        let ready = startWaiters.filter { $0.count <= started.count }
        startWaiters.removeAll { $0.count <= started.count }
        for waiter in ready { waiter.continuation.resume() }
        // Isolated to this actor, so `held` has the id before any release
        // can look for it.
        await withCheckedContinuation { held[id] = $0 }
        current -= 1
    }

    /// Lets a holding `id` finish; one already released stays released.
    func release(_ id: String) {
        held.removeValue(forKey: id)?.resume()
    }

    func waitForStarts(_ count: Int) async {
        guard started.count < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }
}
