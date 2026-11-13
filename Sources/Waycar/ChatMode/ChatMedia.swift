import Foundation
import Synchronization
import UniformTypeIdentifiers

/// One image, video, or Host file a chat message shows: one the Agent
/// viewed with its tools during the turn (the plugin attaches those to the
/// turn's final reply), or one its reply text references. The bytes stay
/// on the Host or the web until the chat shows the item;
/// `ConsoleStore.chatMediaFile(for:agent:)` fetches them into a local file.
struct ChatMedia: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable { case image, video, file }

    enum Source: Equatable, Sendable {
        /// Absolute, `~/…` or relative (to the Agent's cwd) Host path; resolved at fetch.
        case hostFile(path: String)
        /// A base64 string inside one transcript line: the line starting at
        /// byte `offset` of `transcript`, at the RFC 6901 `pointer`.
        case inline(transcript: String, offset: Int, pointer: String)
        /// A base64 string inside a harness's session export document,
        /// for a harness that keeps no transcript file: the RFC 6901
        /// `pointer` into the export of `session`, which the media reader
        /// re-runs on the Host with `agentKind`'s CLI (nil: opencode, the
        /// wire's default; `kilo` names Kilo's).
        case sessionInline(session: String, pointer: String, agentKind: String?)
        case web(URL)  // https only
    }

    let id: String
    let kind: Kind
    let mime: String?
    let source: Source
    var alt: String? = nil

    static let maximumImageBytes = 25 * 1024 * 1024
    static let maximumVideoBytes = 100 * 1024 * 1024
    /// The id prefix of an omp/pi blob: its content's hash, so a cached
    /// copy never goes stale.
    static let blobIDPrefix = "blob:sha256:"

    /// Fetched only on a tap: every video (they are large) and every web
    /// item (the fetch shows the phone's IP to that address).
    var loadsOnTap: Bool {
        // A `file` attachment's type is unknown, so it may be a video or
        // another large file: it waits for a tap, like a video.
        if kind == .video || kind == .file { return true }
        if case .web = source { return true }
        return false
    }

    /// The host a web item loads from, for its tap-to-load placeholder.
    var webHost: String? {
        guard case .web(let url) = source else { return nil }
        return url.host()
    }

    /// Whether a web media URL may be fetched: `https` to a public DNS
    /// name. Refused: `localhost` and `*.localhost`, `*.local`, single-label
    /// names, and IP literals of either family (which covers the private
    /// and link-local ranges), including numeric forms like `127.1`.
    static func isFetchableWebURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", var host = url.host()?.lowercased() else {
            return false
        }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, !host.contains(":"), !host.hasPrefix("[") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, !labels.contains(where: \.isEmpty), let top = labels.last else { return false }
        // No top-level domain is numeric: such a name is an IPv4 literal.
        if top.allSatisfy(\.isNumber) || top.hasPrefix("0x") { return false }
        return top != "localhost" && top != "local"
    }

    /// Kind from a file extension (png…heif → image, mp4/mov/m4v → video), nil otherwise.
    static func kind(forPathExtension ext: String) -> Kind? {
        switch ext.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif": .image
        case "mp4", "mov", "m4v": .video
        default: nil
        }
    }

    /// The most a fetch of this item may transfer.
    var maximumBytes: Int {
        switch kind {
        case .image: Self.maximumImageBytes
        case .video, .file: Self.maximumVideoBytes
        }
    }

    /// The extension a local copy needs for Quick Look and the decoders:
    /// the source path's when it names a media type, else the mime's, else
    /// the one the bytes' signature shows. Nil when none does. A `.file`
    /// attachment can be any type, so its path's extension, or the mime's
    /// UTType one, goes through the terminal preview's rule
    /// (`TerminalFilePreviewStore.isNativelyPreviewable`): a type Quick Look
    /// shows in a contained viewer keeps its extension, and anything else
    /// (web pages, SVG, office documents) becomes `txt` and shows as text.
    static func fileExtension(path: String?, mime: String?, data: Data, kind: Kind? = nil) -> String? {
        guard let ext = sourceExtension(path: path, mime: mime, data: data, kind: kind) else { return nil }
        guard kind == .file else { return ext }
        return isPreviewableFile(extension: ext) ? ext : "txt"
    }

    /// Whether a `.file` attachment's local copy may keep `ext` for Quick Look.
    static func isPreviewableFile(extension ext: String) -> Bool {
        TerminalFilePreviewStore.isNativelyPreviewable(pathExtension: ext)
    }

    private static func sourceExtension(path: String?, mime: String?, data: Data, kind: Kind?) -> String? {
        if let path {
            let ext = (path as NSString).pathExtension.lowercased()
            if Self.kind(forPathExtension: ext) != nil || (kind == .file && !ext.isEmpty) { return ext }
        }
        if let mime, let ext = fileExtension(forMIME: mime, kind: kind) { return ext }
        return sniffedFileExtension(data)
    }

    static func fileExtension(forMIME mime: String, kind: Kind? = nil) -> String? {
        let essence = mime.split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        switch essence {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "video/x-m4v": return "m4v"
        default:
            guard let ext = UTType(mimeType: essence)?.preferredFilenameExtension?.lowercased(),
                !ext.isEmpty && (Self.kind(forPathExtension: ext) != nil || kind == .file)
            else { return nil }
            return ext
        }
    }

    /// The extension a file signature names: PNG, JPEG, GIF, WebP, and the
    /// ISO media brands (HEIC/HEIF, QuickTime, M4V, MP4).
    static func sniffedFileExtension(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + prefix.count
                && Array(bytes[offset..<(offset + prefix.count)]) == prefix
        }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "jpg" }
        if starts(Array("GIF8".utf8)) { return "gif" }
        if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) { return "webp" }
        guard starts(Array("ftyp".utf8), at: 4), bytes.count >= 12 else { return nil }
        switch String(decoding: bytes[8..<12], as: UTF8.self) {
        case "heic", "heix", "heim", "heis": return "heic"
        case "mif1", "msf1": return "heif"
        case "qt  ": return "mov"
        case "M4V ", "M4VH", "M4VP": return "m4v"
        default: return "mp4"
        }
    }
}

enum ChatMediaError: Error, Equatable, Sendable { case pluginOutdated, unavailable, tooLarge, unsupported }

/// Bounds how many chat media transfers one Host runs at once, so a chat
/// full of images never takes every SSH channel its transcript reads need.
/// Waiting is not cancellable, like the transfers themselves.
actor ChatMediaTransfers {
    static let limit = 2
    /// The one bucket every web media download shares.
    static let web = ChatMediaTransfers()

    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run<Value: Sendable>(_ transfer: @Sendable () async throws -> Value) async throws -> Value {
        if running < Self.limit {
            running += 1
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
        // A waiter takes the slot over, the newest first: a chat opens at its
        // bottom, whose media start last. Otherwise the slot frees.
        defer {
            if waiting.isEmpty { running -= 1 } else { waiting.removeLast().resume() }
        }
        return try await transfer()
    }
}

/// What one inline media read asks the Host's plugin for
/// (`plugin/src/chat-media.js`): the base64 string at the RFC 6901
/// `pointer`, decoded, at most `maxBytes` — either in the transcript line
/// starting at byte `offset` (``line``), or in the session export document
/// of `session` (opencode's, or `agentKind`'s), which the reader re-runs on
/// the Host (``sessionInline``). The session form also carries the media
/// item's `id`, whose `#prt_…` tail must still name the part under the
/// pointer.
enum ChatMediaRequest: Equatable, Sendable {
    case line(transcript: String, offset: Int, pointer: String, maxBytes: Int)
    case sessionInline(session: String, id: String, pointer: String, agentKind: String?, maxBytes: Int)

    var maxBytes: Int {
        switch self {
        case .line(_, _, _, let maxBytes), .sessionInline(_, _, _, _, let maxBytes): maxBytes
        }
    }
}

/// Downloads one `https` media URL on the phone, refusing redirects off
/// `https` or to a host `ChatMedia.isFetchableWebURL` refuses, and stopping
/// as soon as the body passes the cap, whether the server announced its
/// length or not. The default ephemeral session keeps no cookies or cache;
/// tests pass a configuration with a stub protocol.
enum ChatMediaWebDownload {
    static let resourceTimeout: TimeInterval = 120

    static func data(
        from url: URL, maxBytes: Int, configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw ChatMediaError.unsupported }
        guard ChatMedia.isFetchableWebURL(url) else { throw ChatMediaError.unavailable }
        configuration.timeoutIntervalForResource = resourceTimeout
        let receiver = Receiver(maxBytes: maxBytes)
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receiver.start(task, continuation: continuation)
            }
        } onCancel: {
            receiver.finish(.failure(CancellationError()))
            task.cancel()
        }
    }

    private final class Receiver: NSObject, URLSessionDataDelegate, Sendable {
        private struct State {
            var data = Data()
            var continuation: CheckedContinuation<Data, any Error>?
            var outcome: Result<Data, any Error>?
        }

        private let maxBytes: Int
        private let state = Mutex(State())

        init(maxBytes: Int) {
            self.maxBytes = maxBytes
        }

        func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<Data, any Error>) {
            let early: Result<Data, any Error>? = state.withLock { state in
                if let outcome = state.outcome { return outcome }
                state.continuation = continuation
                return nil
            }
            if let early {
                continuation.resume(with: early)
            } else {
                task.resume()
            }
        }

        /// Settles the download once; later outcomes are dropped.
        func finish(_ outcome: Result<Data, any Error>) {
            let continuation: CheckedContinuation<Data, any Error>? = state.withLock { state in
                guard state.outcome == nil else { return nil }
                state.outcome = outcome
                state.data = Data()
                let continuation = state.continuation
                state.continuation = nil
                return continuation
            }
            continuation?.resume(with: outcome)
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                finish(.failure(ChatMediaError.unavailable))
                completionHandler(.cancel)
                return
            }
            guard response.expectedContentLength <= Int64(maxBytes) else {
                finish(.failure(ChatMediaError.tooLarge))
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let over = state.withLock { state in
                guard state.outcome == nil else { return false }
                state.data.append(data)
                return state.data.count > maxBytes
            }
            if over {
                finish(.failure(ChatMediaError.tooLarge))
                dataTask.cancel()
            }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            guard let next = request.url, ChatMedia.isFetchableWebURL(next) else {
                finish(.failure(ChatMediaError.unavailable))
                completionHandler(nil)
                task.cancel()
                return
            }
            completionHandler(request)
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
        ) {
            if error != nil {
                finish(.failure(ChatMediaError.unavailable))
                return
            }
            let data = state.withLock { $0.data }
            // A redirect refused above completes without error and without a body.
            guard let http = task.response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else {
                finish(.failure(ChatMediaError.unavailable))
                return
            }
            finish(.success(data))
        }
    }
}
