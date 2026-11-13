import Foundation

// herdr-core's wire records (ADR 0031, design §5 and §6; research
// `docs/research/herdr-core/`). Everything decodes leniently: core's API
// "only grows", so a missing optional field is absent, an unknown field is
// ignored and an unknown string (a status word, a reason) stays a string.

/// The program's own OSC 7501 status record on a terminal (`status`).
struct CoreStatus: Equatable, Sendable, Decodable {
    /// `idle`, `working`, `done`, `blocked`, `error`; an open vocabulary.
    var state: String
    /// `permission`, `question` or `auth` while `blocked`.
    var kind: String?
    /// The program's own name for itself (`claude-code`, `zoo`).
    var app: String?
    var title: String?
    var msg: String?
    var progress: Int?

    init(
        state: String, kind: String? = nil, app: String? = nil, title: String? = nil,
        msg: String? = nil, progress: Int? = nil
    ) {
        self.state = state
        self.kind = kind
        self.app = app
        self.title = title
        self.msg = msg
        self.progress = progress
    }

    private enum CodingKeys: String, CodingKey { case state, kind, app, title, msg, progress }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
        kind = try? container.decodeIfPresent(String.self, forKey: .kind)
        app = try? container.decodeIfPresent(String.self, forKey: .app)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        msg = try? container.decodeIfPresent(String.self, forKey: .msg)
        progress = try? container.decodeIfPresent(Int.self, forKey: .progress)
    }
}

/// The process group leader now running in a terminal, refreshed about twice
/// a second; absent until the first refresh and after the terminal finished.
struct CoreForeground: Equatable, Sendable, Decodable {
    var pid: Int?
    var name: String?
    var argv: [String]
    var cwd: String?

    init(pid: Int? = nil, name: String? = nil, argv: [String] = [], cwd: String? = nil) {
        self.pid = pid
        self.name = name
        self.argv = argv
        self.cwd = cwd
    }

    private enum CodingKeys: String, CodingKey { case pid, name, argv, cwd }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = try? container.decodeIfPresent(Int.self, forKey: .pid)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        argv = (try? container.decodeIfPresent([String].self, forKey: .argv)) ?? []
        cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
    }
}

/// One terminal record, as `terminal.*` results, `events.subscribe`
/// snapshots and `created`/`restarted` events carry it. It has no `id`:
/// `address` (`t7`, `t1b`, `box/t3`) is the id, opaque and never reused.
struct CoreTerminal: Equatable, Sendable, Decodable {
    var address: String
    var name: String?
    var labels: [String: String]
    var argv: [String]
    /// The start directory as requested; the terminal's current one is
    /// `foreground.cwd`.
    var cwd: String
    /// `live` or `finished`; never read `pid` for this.
    var state: String
    var pid: Int?
    var exitCode: Int?
    var signal: Int?
    /// Why it finished or was lost: `exited`, `killed`, `server_stop`, ...
    var reason: String?
    var createdMs: Int64?
    var finishedMs: Int64?
    var status: CoreStatus?
    /// When the status word last changed (core 0.1.10+).
    var statusMs: Int64?
    /// Whether the program ever sent an OSC 7501 report.
    var reported: Bool
    /// Counts the times the status left `working`.
    var turn: Int
    /// The OSC 0/2 window title.
    var title: String
    var foreground: CoreForeground?
    var parent: String?
    var keep: Bool
    var cols: Int?
    var rows: Int?

    init(
        address: String, name: String? = nil, labels: [String: String] = [:],
        argv: [String] = [], cwd: String = "", state: String = "live", pid: Int? = nil,
        exitCode: Int? = nil, signal: Int? = nil, reason: String? = nil,
        createdMs: Int64? = nil, finishedMs: Int64? = nil, status: CoreStatus? = nil,
        statusMs: Int64? = nil, reported: Bool = false, turn: Int = 0, title: String = "",
        foreground: CoreForeground? = nil, parent: String? = nil, keep: Bool = false,
        cols: Int? = nil, rows: Int? = nil
    ) {
        self.address = address
        self.name = name
        self.labels = labels
        self.argv = argv
        self.cwd = cwd
        self.state = state
        self.pid = pid
        self.exitCode = exitCode
        self.signal = signal
        self.reason = reason
        self.createdMs = createdMs
        self.finishedMs = finishedMs
        self.status = status
        self.statusMs = statusMs
        self.reported = reported
        self.turn = turn
        self.title = title
        self.foreground = foreground
        self.parent = parent
        self.keep = keep
        self.cols = cols
        self.rows = rows
    }

    private enum CodingKeys: String, CodingKey {
        case address, name, labels, argv, cwd, state, pid, signal, reason, status, reported, turn
        case title, foreground, parent, keep, cols, rows
        case exitCode = "exit_code"
        case createdMs = "created_ms"
        case finishedMs = "finished_ms"
        case statusMs = "status_ms"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        address = try container.decode(String.self, forKey: .address)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        labels = (try? container.decodeIfPresent([String: String].self, forKey: .labels)) ?? [:]
        argv = (try? container.decodeIfPresent([String].self, forKey: .argv)) ?? []
        cwd = (try? container.decodeIfPresent(String.self, forKey: .cwd)) ?? ""
        state = (try? container.decodeIfPresent(String.self, forKey: .state)) ?? "live"
        pid = try? container.decodeIfPresent(Int.self, forKey: .pid)
        exitCode = try? container.decodeIfPresent(Int.self, forKey: .exitCode)
        signal = try? container.decodeIfPresent(Int.self, forKey: .signal)
        reason = try? container.decodeIfPresent(String.self, forKey: .reason)
        createdMs = try? container.decodeIfPresent(Int64.self, forKey: .createdMs)
        finishedMs = try? container.decodeIfPresent(Int64.self, forKey: .finishedMs)
        status = try? container.decodeIfPresent(CoreStatus.self, forKey: .status)
        statusMs = try? container.decodeIfPresent(Int64.self, forKey: .statusMs)
        reported = (try? container.decodeIfPresent(Bool.self, forKey: .reported)) ?? false
        turn = (try? container.decodeIfPresent(Int.self, forKey: .turn)) ?? 0
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
        foreground = try? container.decodeIfPresent(CoreForeground.self, forKey: .foreground)
        parent = try? container.decodeIfPresent(String.self, forKey: .parent)
        keep = (try? container.decodeIfPresent(Bool.self, forKey: .keep)) ?? false
        cols = try? container.decodeIfPresent(Int.self, forKey: .cols)
        rows = try? container.decodeIfPresent(Int.self, forKey: .rows)
    }

    var isFinished: Bool { state == "finished" }
}

/// `hello`'s result (design §5): what core this is and what it can do.
struct CoreHello: Equatable, Sendable, Decodable {
    /// The core's permanent random id (reset only if its state is wiped) and
    /// the host's short name.
    var coreID: String
    var coreName: String
    var version: String
    var generation: Int
    var features: [String]
    var methods: [String]
    var framed: Bool

    init(
        coreID: String = "", coreName: String = "", version: String, generation: Int = 1,
        features: [String] = [], methods: [String] = [], framed: Bool = true
    ) {
        self.coreID = coreID
        self.coreName = coreName
        self.version = version
        self.generation = generation
        self.features = features
        self.methods = methods
        self.framed = framed
    }

    private enum CodingKeys: String, CodingKey {
        case core, version, generation, features, methods, framed
    }

    private struct Core: Decodable {
        var id: String?
        var name: String?
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let core = try? container.decodeIfPresent(Core.self, forKey: .core)
        coreID = core?.id ?? ""
        coreName = core?.name ?? ""
        version = try container.decode(String.self, forKey: .version)
        generation = (try? container.decodeIfPresent(Int.self, forKey: .generation)) ?? 1
        features = (try? container.decodeIfPresent([String].self, forKey: .features)) ?? []
        methods = (try? container.decodeIfPresent([String].self, forKey: .methods)) ?? []
        framed = (try? container.decodeIfPresent(Bool.self, forKey: .framed)) ?? false
    }
}

/// `events.subscribe`'s result: the channel the lines follow on (nil in plain
/// mode), the stream's `seq` and every terminal, finished ones included.
struct CoreSubscription: Equatable, Sendable, Decodable {
    var channel: UInt32?
    var seq: Int
    var terminals: [CoreTerminal]

    init(channel: UInt32? = nil, seq: Int, terminals: [CoreTerminal]) {
        self.channel = channel
        self.seq = seq
        self.terminals = terminals
    }

    private enum CodingKeys: String, CodingKey { case channel, seq, terminals }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channel = try? container.decodeIfPresent(UInt32.self, forKey: .channel)
        seq = (try? container.decodeIfPresent(Int.self, forKey: .seq)) ?? 0
        terminals = (try? container.decode([CoreTerminal].self, forKey: .terminals)) ?? []
    }
}

/// One `event` notification on the events channel. `type` is one of
/// `created lost restarted keep finished removed status turn title labels
/// size foreground doc` (open vocabulary); `terminal` is absent on `doc`.
struct CoreEvent: Equatable, Sendable {
    var seq: Int
    var type: String
    var terminal: String?
    var data: JSONValue
}

/// A line on the events channel.
enum CoreNotification: Equatable, Sendable {
    case event(CoreEvent)
    /// Sent about every 15 s when nothing is queued; not an event.
    case heartbeat(seq: Int)
    /// The subscriber fell behind: replace all state with these terminals and
    /// ignore events at or below `seq`.
    case missed(seq: Int, terminals: [CoreTerminal])
}

/// An error object from core: `data.kind` is the discriminator (`code` is
/// -32000 for almost everything) and `hint` may be empty. The kind set is
/// open.
struct CoreRPCError: Error, Equatable, Sendable {
    var code: Int
    var kind: String
    var message: String
    var hint: String
}
