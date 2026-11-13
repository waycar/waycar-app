import CryptoKit
import Foundation
import Testing
import WaycarSSH

@testable import Waycar

/// The harness lab Host (`scripts/harness-lab`) as `scripts/harness-lab/run-e2e.sh`
/// describes it in `WAYCAR_HARNESS_LAB_CONFIG`: base64 JSON pushed into the
/// Simulator's launchd environment, like the tmux remote suite's fixture.
/// Absent everywhere else, so `make test` and the merge gate never run the
/// lab suite (deliberately not `RealSSHFixture.gate`: the gate's
/// `WAYCAR_SSH_E2E_REQUIRED` must not turn a missing lab into a failure).
struct HarnessLabEnvironment: Sendable {
    static let configVariable = "WAYCAR_HARNESS_LAB_CONFIG"
    /// Every workspace label and tmux session name the suite creates starts
    /// with it, and the lab reset closes exactly those.
    static let labelPrefix = "harnesse2e-"

    let host: String
    let port: UInt16
    let username: String
    let deviceKey: Curve25519.Signing.PrivateKey
    let homePath: String
    /// The pre-trusted git checkout every harness is configured for.
    let workDirectory: String
    /// The mock model server as the lab Host reaches it.
    let mockURL: String
    /// The host-side reset script the runner copied onto the Host.
    let resetScript: String
    let kinds: [SupportedAgentKind]
    let backends: [HostBackend]
    /// Kinds whose herdr integration `herdr integration status` reported
    /// installed when the run started: herdr reports `agent_session` only
    /// through an integration (docs/research/harnesses/herdr-backend.md,
    /// cross-kind finding 5).
    let herdrIntegrations: Set<SupportedAgentKind>
    /// `kinds` and `backends` entries that name no lab kind or no backend.
    /// The matrix cannot hold them, so the suite fails on them instead of
    /// running fewer cases.
    let unknownEntries: [String]

    static let current: HarnessLabEnvironment? = {
        guard
            let encoded = ProcessInfo.processInfo.environment[configVariable],
            let data = Data(base64Encoded: encoded),
            let config = try? JSONDecoder().decode(Config.self, from: data),
            let deviceKey = try? RealSSHFixture.deviceKey(seed: config.deviceKeySeed)
        else { return nil }
        let labKind = { (raw: String) in
            SupportedAgentKind(rawValue: raw).flatMap { HarnessLabProfile.labKinds.contains($0) ? $0 : nil }
        }
        let kinds = config.kinds.map { $0.compactMap(labKind) }
        let unknownKinds = (config.kinds ?? []).filter { labKind($0) == nil }
        let unknownBackends = (config.backends ?? []).filter { HostBackend(rawValue: $0) == nil }
        return HarnessLabEnvironment(
            host: config.host,
            port: config.port,
            username: config.username,
            deviceKey: deviceKey,
            homePath: config.homePath,
            workDirectory: config.workDirectory ?? "\(config.homePath)/work/demo",
            mockURL: config.mockURL ?? "http://mock:8080",
            resetScript: config.resetScript ?? "\(config.homePath)/.cache/harness-lab/e2e-reset.sh",
            kinds: kinds ?? HarnessLabProfile.labKinds,
            backends: config.backends.map { $0.compactMap(HostBackend.init(rawValue:)) }
                ?? [.herdr, .tmux],
            herdrIntegrations: Set(
                (config.herdrIntegrations ?? []).compactMap(SupportedAgentKind.init(rawValue:))),
            unknownEntries: unknownKinds.map { "kind \($0)" } + unknownBackends.map { "backend \($0)" })
    }()

    func settings() -> SSHTransportSettings {
        var settings = SSHTransportSettings(
            host: host,
            port: Int(port),
            username: username,
            credentials: .ed25519(deviceKey),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true },
            socket: .absolutePath("\(homePath)/.config/herdr/herdr.sock"))
        settings.requestTimeout = .seconds(30)
        return settings
    }

    /// The production connect path the Console takes for one backend.
    func connect(_ backend: HostBackend) async throws -> any Transport {
        try await SSHTransportConnector().connect(settings: settings(), backend: backend)
    }

    private struct Config: Decodable {
        let host: String
        let port: UInt16
        let username: String
        let deviceKeySeed: String
        let homePath: String
        let workDirectory: String?
        let mockURL: String?
        let resetScript: String?
        let kinds: [String]?
        let backends: [String]?
        let herdrIntegrations: [String]?
    }
}

/// A plain exec connection to the lab Host, beside the Transport under test:
/// the lab reset, the Host clock and the mock's request log.
final class HarnessLabHost: Sendable {
    private let connection: SSHConnection
    private let environment: HarnessLabEnvironment

    private init(connection: SSHConnection, environment: HarnessLabEnvironment) {
        self.connection = connection
        self.environment = environment
    }

    static func open(_ environment: HarnessLabEnvironment) async throws -> HarnessLabHost {
        let key = DeviceKey(privateKey: environment.deviceKey)
        let connection = try await SSHConnection.connect(
            to: SSHEndpoint(host: environment.host, port: environment.port), timeout: .seconds(10))
        do {
            try await connection.authenticate(
                username: environment.username,
                publicKey: key.publicKeyBlob,
                signer: { data in try key.privateKey.signature(for: data) },
                timeout: .seconds(10))
            return HarnessLabHost(connection: connection, environment: environment)
        } catch {
            try? await connection.close(timeout: .seconds(2))
            throw error
        }
    }

    func close() async {
        try? await connection.close(timeout: .seconds(2))
    }

    /// `command` under the account's login environment (the lab's
    /// `env.sh`); its stdout. A non-zero exit throws.
    @discardableResult
    func shell(_ command: String, timeout: Duration = .seconds(30)) async throws -> String {
        let result = try await connection.execute(
            "bash -lc \(HarnessLabShell.quoted(command))", timeout: timeout)
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        guard result.exitStatus == 0 else {
            throw HarnessLabError.commandFailed(
                command: command, exitStatus: result.exitStatus,
                output: stdout + String(decoding: result.stderr, as: UTF8.self))
        }
        return stdout
    }

    /// Closes every herdr workspace and kills every tmux session whose name
    /// starts with the suite's prefix (`scripts/harness-lab/e2e-reset.sh`).
    @discardableResult
    func reset() async throws -> String {
        try await shell(
            "sh \(HarnessLabShell.quoted(environment.resetScript)) "
                + HarnessLabShell.quoted(HarnessLabEnvironment.labelPrefix),
            timeout: .seconds(60))
    }

    /// The Host's clock in epoch milliseconds: the mock logs its own
    /// container's clock, which shares the lab VM's, not the Simulator's.
    func nowMilliseconds() async throws -> Int64 {
        let text = try await shell("date +%s%3N").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int64(text) else {
            throw HarnessLabError.unexpectedOutput(command: "date +%s%3N", output: text)
        }
        return value
    }

    /// The mock's request log from `since` (epoch ms), oldest first. The log
    /// is shared by every lab user, so the suite filters, never clears it.
    func mockRequests(since: Int64) async throws -> [MockRequest] {
        let url = "\(environment.mockURL)/_log?since=\(since)"
        let output = try await shell("curl -fsS \(HarnessLabShell.quoted(url))")
        let decoder = JSONDecoder()
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            try? decoder.decode(MockRequest.self, from: Data(line.utf8))
        }
    }
}

enum HarnessLabShell {
    /// POSIX single-quoting.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum HarnessLabError: Error, CustomStringConvertible {
    case commandFailed(command: String, exitStatus: Int32, output: String)
    case unexpectedOutput(command: String, output: String)
    case timedOut(String)

    var description: String {
        switch self {
        case .commandFailed(let command, let exitStatus, let output):
            "`\(command)` exited \(exitStatus): \(output)"
        case .unexpectedOutput(let command, let output):
            "`\(command)` printed \(output.debugDescription)"
        case .timedOut(let what):
            "timed out waiting for \(what)"
        }
    }
}

/// One record of the mock's `GET /_log` (scripts/harness-lab/mock/server.js):
/// generation records carry the normalized request, other records only the
/// base fields. Unknown fields are ignored.
struct MockRequest: Decodable, Sendable {
    struct Message: Decodable, Sendable {
        let role: String
        let text: String?
    }

    struct ToolCall: Decodable, Sendable {
        let name: String
    }

    let ts: Int64
    let api: String
    let method: String?
    let path: String?
    let userAgent: String?
    let model: String?
    /// Normalized by the mock: chat `reasoning_effort`, responses
    /// `reasoning.effort`, anthropic `output_config.effort`, gemini
    /// `thinkingLevel`, or `budget:<n>`.
    let effort: String?
    let system: String?
    let lastUser: String?
    let messages: [Message]?
    let tools: [String]?
    /// `text`, `tool`, `tool-xml`, `after-tool`, `bookkeeping` or `json`.
    let reply: String?
    let replyText: String?
    let toolCall: ToolCall?

    /// A request from the harness's agent loop, not a title or summary side
    /// request: it offers tools and is not answered as bookkeeping.
    var isAgentTurn: Bool {
        !(tools ?? []).isEmpty && reply != "bookkeeping" && reply != "json"
    }

    var transcriptText: String {
        (messages ?? []).compactMap(\.text).joined(separator: "\n")
    }
}

/// Follows one pane through `listAgents()`, the poll every Console resync
/// reads, about four times a second: every status it reports in order, the
/// last Agent of the expected kind, and the last session it carried (herdr
/// clears `agent_session` as the Agent leaves, so the Console keeps the last
/// one for its Closed Session; `ClosedSession.init(closing:session:)`).
/// Meanwhile it holds the event stream the Console's `EventsSession` holds
/// while a Host is connected: `TmuxTransport` reads screens for Status
/// Hooks' blind spots (the approvals of agy, cline and kiro) only while one
/// is open (`startScreenPoll`), and `listAgents()` shows their verdicts.
actor HarnessLabObserver {
    struct Sample: Sendable {
        let status: AgentStatus
        let at: ContinuousClock.Instant
    }

    let transport: any Transport
    let kind: SupportedAgentKind
    private(set) var paneID: String
    private(set) var timeline: [Sample] = []
    private(set) var latest: Agent?
    private(set) var latestOfKind: Agent?
    private(set) var lastSession: AgentSessionInfo?
    private(set) var kindsSeen: Set<String> = []
    /// True once the pane was listed and then no longer is.
    private(set) var gone = false
    private(set) var pollFailures = 0
    private var polling: Task<Void, Never>?
    private var events: HerdrEventStream?
    private var draining: Task<Void, Never>?

    init(transport: any Transport, kind: SupportedAgentKind, paneID: String) {
        self.transport = transport
        self.kind = kind
        self.paneID = paneID
    }

    func start() async {
        guard polling == nil else { return }
        let subscriptions = await HostConsoleProjection.subscriptions(paneIDs: [paneID])
        do {
            let stream = try await transport.subscribeToEvents(subscriptions)
            events = stream
            draining = Task {
                do {
                    for try await _ in stream.events {}
                } catch {}
            }
        } catch {
            Issue.record("the Console's event stream did not open: \(error)")
        }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stop() async {
        polling?.cancel()
        polling = nil
        await events?.end()
        events = nil
        draining?.cancel()
        draining = nil
    }

    /// Follows another pane from now on (a resumed Agent's).
    func follow(_ paneID: String) {
        self.paneID = paneID
        timeline = []
        latest = nil
        latestOfKind = nil
        gone = false
    }

    /// Where the next prompt's statuses start.
    func mark() -> Int { timeline.count }

    func statuses(since mark: Int) -> [AgentStatus] {
        timeline.dropFirst(mark).map(\.status)
    }

    private func poll() async {
        let agents: [Agent]
        do {
            agents = try await transport.listAgents()
        } catch {
            pollFailures += 1
            return
        }
        guard let agent = agents.first(where: { $0.paneID == paneID }) else {
            if latest != nil { gone = true }
            return
        }
        latest = agent
        kindsSeen.insert(agent.kind)
        if agent.kind == kind.rawValue { latestOfKind = agent }
        if let session = agent.agentSession, !session.value.isEmpty { lastSession = session }
        if timeline.last?.status != agent.status {
            timeline.append(Sample(status: agent.status, at: .now))
        }
    }

    /// Waits until `condition` holds for the statuses reported since `mark`.
    func wait(
        since mark: Int, timeout: Duration, _ condition: @Sendable ([AgentStatus]) -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition(statuses(since: mark)) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition(statuses(since: mark))
    }

    func waitUntilGone(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if gone { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return gone
    }

    var current: AgentStatus? { timeline.last?.status }
}

/// Polls until `body` returns a value or the timeout passes.
func harnessLabPoll<T: Sendable>(
    timeout: Duration, interval: Duration = .milliseconds(500),
    _ body: @Sendable () async throws -> T?
) async -> T? {
    let deadline = ContinuousClock.now + timeout
    repeat {
        if let value = try? await body() { return value }
        try? await Task.sleep(for: interval)
    } while ContinuousClock.now < deadline
    return nil
}
