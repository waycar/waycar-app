import Foundation
import Synchronization
import WaycarSSH

@testable import Waycar

/// One reply block a fake tmux sends for one command.
enum FakeTmuxBlock: Sendable, Equatable {
    case ok([String])
    case error([String])
}

/// A `HostControlChannel` that behaves like a `tmux -C attach` client: it
/// answers its own attach with a flags-0 block, and every line written to it
/// with the blocks `responder` returns. Tests push notifications, `%exit`
/// and failures, and can hold lines unread to script tmux below 3.6 losing
/// the client's session (`holdLines(from:)`, `exitAnswering(_:)`). Reads
/// park until output is queued; `close()` fails a parked read and every
/// later read or write.
final class RespondingControlChannel: HostControlChannel {
    typealias Responder = @Sendable (String) -> [FakeTmuxBlock]

    private enum ReadItem: Sendable {
        case data(Data)
        case eof
        case failure(TransportError)
    }

    private struct State {
        var output: [ReadItem] = []
        var reader: CheckedContinuation<ReadItem, Never>?
        var lines: [String] = []
        var closed = false
        var commandNumber = 100
        /// Set by `holdLines(from:)`: the first line starting with it, and
        /// every line after, is held.
        var holdPrefix: String?
        var held: [String] = []
        /// Set by `exitAnswering(_:)`: later lines are recorded and dropped.
        var exited = false
        var heldReply: (
            prefix: String, entered: AsyncStream<Void>.Continuation, release: AsyncStream<Void>
        )?
    }

    static let closedError = TransportError.channelFailed(detail: "fake control channel closed")

    let command: String
    private let responder: Responder
    private let state = Mutex(State())

    init(command: String, responder: @escaping Responder) {
        self.command = command
        self.responder = responder
        enqueue(.data(Data("%begin 1700000000 1 0\n%end 1700000000 1 0\n".utf8)))
    }

    // MARK: Scripting

    /// Notification lines, LF-terminated, in one read.
    func push(_ lines: [String]) {
        enqueue(.data(Data(lines.map { $0 + "\n" }.joined().utf8)))
    }

    /// `%exit`, then stdout closes: tmux leaving in order.
    func exit(reason: String? = nil) {
        push([reason.map { "%exit \($0)" } ?? "%exit"])
        enqueue(.eof)
    }

    /// The SSH channel failing under the client.
    func lose() {
        enqueue(.failure(.channelFailed(detail: "fake link dropped")))
    }

    /// From the first line starting with `prefix` on (every line for ""),
    /// lines are only recorded: none reaches the responder or gets a reply
    /// yet, as tmux has not read them. Nothing after a held line is answered
    /// early, so replies stay in send order.
    func holdLines(from prefix: String = "") {
        state.withLock { $0.holdPrefix = prefix }
    }

    /// tmux below 3.6 losing the client's session (T24): the first
    /// `answered` held lines run (reach the responder) and are answered,
    /// then `%sessions-changed`, `%exit` and EOF; the other held lines never
    /// run. Lines written afterwards are recorded and dropped.
    func exitAnswering(_ answered: Int) {
        let held: [String] = state.withLock { state in
            let held = state.held
            state.held = []
            state.holdPrefix = nil
            state.exited = true
            return held
        }
        let framed = held.prefix(answered).map { frame(responder($0)) }.joined()
        if !framed.isEmpty { enqueue(.data(Data(framed.utf8))) }
        push(["%sessions-changed", "%exit"])
        enqueue(.eof)
    }

    /// Holds one reply without blocking writes; the test releases it before
    /// allowing any later command replies, preserving tmux's FIFO blocks.
    func holdNextReply(
        from prefix: String, entered: AsyncStream<Void>.Continuation, until release: AsyncStream<Void>
    ) {
        state.withLock { $0.heldReply = (prefix, entered, release) }
    }

    var writtenLines: [String] {
        state.withLock { $0.lines }
    }

    var isClosed: Bool {
        state.withLock { $0.closed }
    }

    private func enqueue(_ item: ReadItem) {
        let reader: CheckedContinuation<ReadItem, Never>? = state.withLock { state in
            if let reader = state.reader {
                state.reader = nil
                return reader
            }
            state.output.append(item)
            return nil
        }
        reader?.resume(returning: item)
    }

    // MARK: HostControlChannel

    func write(_ data: Data, timeout: Duration) async throws {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        for line in lines {
            // nil: closed; false: held or dropped unread.
            let answers: Bool? = state.withLock { state in
                guard !state.closed else { return nil }
                state.lines.append(line)
                if state.exited { return false }
                if let prefix = state.holdPrefix, !state.held.isEmpty || line.hasPrefix(prefix) {
                    state.held.append(line)
                    return false
                }
                return true
            }
            guard let answers else { throw Self.closedError }
            guard answers else { continue }
            let framed = frame(responder(line))
            let held = state.withLock { state in
                guard let held = state.heldReply, line.hasPrefix(held.prefix) else {
                    return Optional<AsyncStream<Void>>.none
                }
                state.heldReply = nil
                held.entered.yield(())
                return held.release
            }
            if let held {
                Task {
                    var release = held.makeAsyncIterator()
                    _ = await release.next()
                    if !framed.isEmpty { self.enqueue(.data(Data(framed.utf8))) }
                }
            } else if !framed.isEmpty {
                enqueue(.data(Data(framed.utf8)))
            }
        }
    }

    /// `blocks` as tmux frames a command's replies, numbered on.
    private func frame(_ blocks: [FakeTmuxBlock]) -> String {
        var framed = ""
        for block in blocks {
            let number = state.withLock { state in
                state.commandNumber += 1
                return state.commandNumber
            }
            let guardLine = "1700000000 \(number) 1"
            framed += "%begin \(guardLine)\n"
            switch block {
            case .ok(let body):
                framed += body.map { $0 + "\n" }.joined() + "%end \(guardLine)\n"
            case .error(let body):
                framed += body.map { $0 + "\n" }.joined() + "%error \(guardLine)\n"
            }
        }
        return framed
    }

    func read(maximumBytes: Int, timeout: Duration) async throws -> Data? {
        let item = await withCheckedContinuation { (continuation: CheckedContinuation<ReadItem, Never>) in
            let ready: ReadItem? = state.withLock { state in
                if state.closed { return .failure(Self.closedError) }
                if !state.output.isEmpty { return state.output.removeFirst() }
                state.reader = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
        switch item {
        case .data(let data): return data
        case .eof: return nil
        case .failure(let error): throw error
        }
    }

    /// tmux's control client has no exit status of its own to report.
    func exitStatus(timeout: Duration) async throws -> Int32 {
        throw TransportError.timedOut
    }

    func standardErrorTail() async -> String { "" }

    func close() async {
        let reader: CheckedContinuation<ReadItem, Never>? = state.withLock { state in
            state.closed = true
            let reader = state.reader
            state.reader = nil
            return reader
        }
        reader?.resume(returning: .failure(Self.closedError))
    }
}

/// `HostSSHServices` with scripted execs and responding control channels.
/// Execs, control commands, attach and mosh commands (an attach throws
/// `Unsupported` unless `serveAttach` gave it a session), config files and
/// releases are recorded; the home directory is `homeDirectory`; Launch
/// Prompt File routes read unsupported; everything else throws `Unsupported`.
actor FakeHostSSHServices: HostSSHServices {
    struct Unsupported: Error, Equatable {
        let operation: String
    }

    struct Exec: Sendable, Equatable {
        let command: String
        let input: String
        /// The timeout the caller gave `runExec`.
        var timeout: Duration? = nil
    }

    typealias ExecHandler = @Sendable (_ command: String, _ input: Data) -> SSHExecResult

    nonisolated let sshHost = "fake.example"
    nonisolated let requestTimeout: Duration = .seconds(5)

    private let execHandler: ExecHandler
    private let responder: RespondingControlChannel.Responder
    private(set) var connected = true
    private(set) var codexPresence: CodexPresence?
    func setCodexPresence(_ presence: CodexPresence?) { codexPresence = presence }
    private(set) var execs: [Exec] = []
    private(set) var controlChannels: [RespondingControlChannel] = []
    private(set) var attachCommands: [String] = []
    /// Channels `openCoreChannel` hands out, first in first out; the
    /// commands it was asked to run.
    private var coreChannelQueue: [any HostControlChannel] = []
    private var zellijChannelQueue: [any HostControlChannel] = []
    private(set) var zellijCommands: [String] = []
    private var ultimateChannelQueue: [any UltimateByteChannel] = []
    private var ultimateChannelsByPort: [UInt16: [any UltimateByteChannel]] = [:]
    private var ultimateChannelFactory: (@Sendable (UInt16) -> any UltimateByteChannel)?
    private(set) var coreCommands: [String] = []
    /// The PTY geometry each attach asked for, in order with `attachCommands`.
    private(set) var attachRequests: [TerminalAttachRequest] = []
    private var attachSession: TerminalAttachSession?
    private(set) var moshCommands: [String] = []
    private(set) var files: [String: Data] = [:]
    private var configReadsFail = false

    /// A missing config directory (or unavailable SFTP), unlike an absent file, throws.
    func failConfigFileReads() { configReadsFail = true }
    private(set) var releaseCount = 0
    /// Execs whose command contains this never answer; only cancellation
    /// ends them (a half-dead link).
    private var stalledExecMatch: String?
    private var heldExec: (
        match: String, entered: AsyncStream<Void>.Continuation, release: AsyncStream<Void>
    )?

    func holdNextExec(
        containing match: String, entered: AsyncStream<Void>.Continuation, until release: AsyncStream<Void>
    ) {
        heldExec = (match, entered, release)
    }
    /// Set by `holdLinesOnNextControlChannel(from:)`.
    private var nextChannelHoldPrefix: String?

    init(
        exec: @escaping ExecHandler,
        control responder: @escaping RespondingControlChannel.Responder = { _ in [] }
    ) {
        execHandler = exec
        self.responder = responder
    }

    static func result(
        stdout: String = "", stderr: String = "", exitStatus: Int32 = 0, reachedEOF: Bool = true
    ) -> SSHExecResult {
        SSHExecResult(
            stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), exitStatus: exitStatus,
            reachedEOF: reachedEOF)
    }

    var isConnected: Bool { connected }

    var controlCommands: [String] { controlChannels.map(\.command) }

    func execs(containing text: String) -> [Exec] {
        execs.filter { $0.command.contains(text) }
    }

    func setFile(_ path: String, _ contents: Data?) {
        files[path] = contents
    }

    func stallExecs(containing text: String) {
        stalledExecMatch = text
    }

    func runExec(_ command: String, input: Data, timeout: Duration?) async throws -> SSHExecResult {
        execs.append(Exec(
            command: command, input: String(decoding: input, as: UTF8.self), timeout: timeout))
        if let stalledExecMatch, command.contains(stalledExecMatch) {
            try await Task.sleep(for: .seconds(3_600))
            throw TransportError.timedOut
        }
        if let held = heldExec, command.contains(held.match) {
            heldExec = nil
            held.entered.yield(())
            var release = held.release.makeAsyncIterator()
            _ = await release.next()
        }
        return execHandler(command, input)
    }

    func openControlChannel(command: String) async throws -> any HostControlChannel {
        let channel = RespondingControlChannel(command: command, responder: responder)
        if let prefix = nextChannelHoldPrefix {
            nextChannelHoldPrefix = nil
            channel.holdLines(from: prefix)
        }
        controlChannels.append(channel)
        return channel
    }

    func serveUltimate(_ channel: any UltimateByteChannel, port: UInt16? = nil) {
        if let port { ultimateChannelsByPort[port, default: []].append(channel) }
        else { ultimateChannelQueue.append(channel) }
    }

    /// Once the queues are empty, every loopback open gets a fresh channel
    /// from `factory` (one per HTTP request, as a live server).
    func serveUltimate(factory: @escaping @Sendable (UInt16) -> any UltimateByteChannel) {
        ultimateChannelFactory = factory
    }

    func openUltimateChannel(port: UInt16) async throws -> any UltimateByteChannel {
        if var channels = ultimateChannelsByPort[port], !channels.isEmpty {
            let channel = channels.removeFirst()
            ultimateChannelsByPort[port] = channels
            return channel
        }
        if ultimateChannelQueue.isEmpty, let ultimateChannelFactory { return ultimateChannelFactory(port) }
        guard !ultimateChannelQueue.isEmpty else { throw Unsupported(operation: "openUltimateChannel") }
        return ultimateChannelQueue.removeFirst()
    }

    func openCodexChannel(socketPath: String) async throws -> any UltimateByteChannel {
        throw Unsupported(operation: "openCodexChannel")
    }

    /// Where each OpenCode channel was dialed (`host:port`), in order; the
    /// channel itself comes from the loopback queues and factory.
    private(set) var openCodeDials: [String] = []

    func openOpenCodeChannel(host: String, port: UInt16) async throws -> any UltimateByteChannel {
        openCodeDials.append("\(host):\(port)")
        return try await openUltimateChannel(port: port)
    }

    func openCoreChannel(command: String) async throws -> any HostControlChannel {
        coreCommands.append(command)
        guard !coreChannelQueue.isEmpty else { throw Unsupported(operation: "openCoreChannel") }
        return coreChannelQueue.removeFirst()
    }

    func openZellijChannel(command: String) async throws -> any HostControlChannel {
        zellijCommands.append(command)
        guard !zellijChannelQueue.isEmpty else { throw Unsupported(operation: "openZellijChannel") }
        return zellijChannelQueue.removeFirst()
    }

    func serveZellij(_ channel: any HostControlChannel) {
        zellijChannelQueue.append(channel)
    }

    /// Later `openCoreChannel` calls return `channel`, in the order queued,
    /// instead of throwing `Unsupported`.
    func serveCore(_ channel: any HostControlChannel) {
        coreChannelQueue.append(channel)
    }

    /// The next control channel opened holds its lines from the first one
    /// starting with `prefix` (``RespondingControlChannel/holdLines(from:)``),
    /// so a test can lose that client's session too before it answers.
    func holdLinesOnNextControlChannel(from prefix: String) {
        nextChannelHoldPrefix = prefix
    }

    func attachTerminal(
        command: String, request: TerminalAttachRequest
    ) async throws -> TerminalAttachSession {
        attachCommands.append(command)
        attachRequests.append(request)
        guard let attachSession else { throw Unsupported(operation: "attachTerminal") }
        return attachSession
    }

    /// Later attaches return `session` instead of throwing `Unsupported`.
    func serveAttach(_ session: TerminalAttachSession) {
        attachSession = session
    }

    func runMoshBootstrap(
        attachCommand: String, request: TerminalAttachRequest
    ) async throws -> MoshBootstrap {
        moshCommands.append(attachCommand)
        throw Unsupported(operation: "runMoshBootstrap")
    }

    func readConfigFile(named name: String, inDirectory directory: String) async throws -> Data? {
        if configReadsFail { throw Unsupported(operation: "readConfigFile: missing directory") }
        return files["\(directory)/\(name)"]
    }

    func replaceConfigFile(
        named name: String, inDirectory directory: String, subdirectory: String?,
        contents: Data
    ) async throws {
        let base = subdirectory.map { "\(directory)/\($0)" } ?? directory
        files["\(base)/\(name)"] = contents
    }

    func deleteConfigFile(
        named name: String, inDirectory directory: String, subdirectory: String?
    ) async throws {
        let base = subdirectory.map { "\(directory)/\($0)" } ?? directory
        files["\(base)/\(name)"] = nil
    }

    func release() async {
        releaseCount += 1
    }

    // MARK: Unscripted

    func probeMoshServer() async throws -> Bool {
        throw Unsupported(operation: "probeMoshServer")
    }

    static let homeDirectory = "/home/me"

    func remoteHomeDirectory() async throws -> String {
        Self.homeDirectory
    }

    func listDirectories(at path: String) async throws -> RemoteDirectoryListing {
        throw Unsupported(operation: "listDirectories")
    }

    func availableAgentKinds() async throws -> [SupportedAgentKind] {
        throw Unsupported(operation: "availableAgentKinds")
    }

    func listSkills(_ query: SkillListQuery) async throws -> [AgentSkill] {
        throw Unsupported(operation: "listSkills")
    }

    func readSkillFile(atPath path: String) async throws -> String {
        throw Unsupported(operation: "readSkillFile")
    }

    func readFileSlice(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
        throw Unsupported(operation: "readFileSlice")
    }

    func readPreviewFile(atPath path: String, maxBytes: Int) async throws -> Data {
        throw Unsupported(operation: "readPreviewFile")
    }

    func modelContextWindow(selector: String) async throws -> Int? {
        throw Unsupported(operation: "modelContextWindow")
    }

    func gitBranch(atPath path: String) async throws -> String? {
        throw Unsupported(operation: "gitBranch")
    }

    func locateCodexBar(customPath: String?) async throws -> String? {
        throw Unsupported(operation: "locateCodexBar")
    }

    func codexBarUsage(executablePath: String) async throws -> AIUsageReport {
        throw Unsupported(operation: "codexBarUsage")
    }

    func hostResourceUsage() async throws -> HostResourceUsage {
        throw Unsupported(operation: "hostResourceUsage")
    }

    func stageLaunchPromptFiles(
        _ files: [LaunchPromptFile]
    ) async throws -> [StagedLaunchPromptFile] {
        throw Unsupported(operation: "stageLaunchPromptFiles")
    }

    func launchPromptCapabilities() async -> LaunchPromptCapabilities {
        .none
    }

    func stageImage(
        _ image: PreparedImage,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedImage {
        throw Unsupported(operation: "stageImage")
    }

    func stageFile(
        _ file: PreparedFile,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedFile {
        throw Unsupported(operation: "stageFile")
    }
}
