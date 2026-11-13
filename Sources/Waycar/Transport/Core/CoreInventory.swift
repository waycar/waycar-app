import Foundation

/// The terminals of one herdr-core connection, kept current from the
/// `events.subscribe` snapshot and its notifications (design §5; research
/// `attach-facts.md` §4). A value type: the transport owns one per connection
/// and never merges across connections (`seq` restarts with each core
/// process), so a new subscription builds a new inventory.
///
/// Terminals keep core's list order; one that appears later (`created`,
/// `restarted`) goes last. Finished terminals stay until `removed`: core's
/// snapshot lists them and so does this.
struct CoreInventory: Equatable, Sendable {
    /// What a notification changed that the projection reads.
    enum Effect: Equatable, Sendable {
        /// The status word, or whether the program ever reported, changed.
        case status(address: String)
        /// A row detail changed (title, working folder).
        case paneUpdated(address: String)
        /// The set of rows or what groups them changed: take a new snapshot.
        case resync
    }

    /// The last `seq` applied, or the snapshot's.
    private(set) var seq: Int
    private var order: [String]
    private var records: [String: CoreTerminal]

    init() {
        seq = 0
        order = []
        records = [:]
    }

    init(_ subscription: CoreSubscription) {
        self.init()
        replace(with: subscription.terminals, seq: subscription.seq)
    }

    /// Every terminal in order, finished ones included.
    var terminals: [CoreTerminal] {
        order.compactMap { records[$0] }
    }

    func terminal(address: String) -> CoreTerminal? {
        records[address]
    }

    /// Replaces all state with a fresh snapshot (a new subscription).
    mutating func replace(with subscription: CoreSubscription) {
        replace(with: subscription.terminals, seq: subscription.seq)
    }

    private mutating func replace(with terminals: [CoreTerminal], seq: Int) {
        self.seq = seq
        order = []
        records = [:]
        for terminal in terminals {
            if records[terminal.address] == nil { order.append(terminal.address) }
            records[terminal.address] = terminal
        }
    }

    /// Applies one notification and says what changed.
    mutating func apply(_ notification: CoreNotification) -> [Effect] {
        switch notification {
        case .heartbeat:
            return []
        case .missed(let seq, let terminals):
            replace(with: terminals, seq: seq)
            return [.resync]
        case .event(let event):
            guard event.seq > seq else { return [] }
            seq = event.seq
            return apply(event)
        }
    }

    private mutating func apply(_ event: CoreEvent) -> [Effect] {
        switch event.type {
        case "created", "restarted":
            guard let terminal = CoreTerminal(json: event.data, fallbackAddress: event.terminal)
            else { return [] }
            if records[terminal.address] == nil { order.append(terminal.address) }
            records[terminal.address] = terminal
            return [.resync]
        case "removed":
            guard let address = event.terminal, records.removeValue(forKey: address) != nil
            else { return [] }
            order.removeAll { $0 == address }
            return [.resync]
        case "doc":
            return []
        default:
            break
        }
        guard let address = event.terminal, var terminal = records[address] else { return [] }
        let effects = Self.update(&terminal, with: event, address: address)
        records[address] = terminal
        return effects
    }

    private static func update(
        _ terminal: inout CoreTerminal, with event: CoreEvent, address: String
    ) -> [Effect] {
        let data = event.data
        switch event.type {
        case "status":
            let wordBefore = terminal.status?.state
            let reportedBefore = terminal.reported
            if let status = data["status"] {
                terminal.status = CoreStatus(json: status)
            }
            if let reported = data["reported"]?.coreBool { terminal.reported = reported }
            if let statusMs = data["status_ms"]?.coreInt { terminal.statusMs = Int64(statusMs) }
            let changed =
                wordBefore != terminal.status?.state || reportedBefore != terminal.reported
            return changed ? [.status(address: address)] : []
        case "turn":
            if let turn = data["turn"]?.coreInt { terminal.turn = turn }
            return []
        case "title":
            if let title = data["title"]?.stringValue { terminal.title = title }
            return [.paneUpdated(address: address)]
        case "foreground":
            let before = terminal.foreground
            let after = CoreForeground(json: data)
            terminal.foreground = after
            if before?.name != after.name || (before?.argv ?? []) != after.argv {
                return [.resync]
            }
            return before?.cwd != after.cwd ? [.paneUpdated(address: address)] : []
        case "labels":
            if let labels = data["labels"]?.coreStringMap { terminal.labels = labels }
            return [.resync]
        case "size":
            if let cols = data["cols"]?.coreInt { terminal.cols = cols }
            if let rows = data["rows"]?.coreInt { terminal.rows = rows }
            return []
        case "keep":
            if let keep = data["keep"]?.coreBool { terminal.keep = keep }
            return []
        case "lost":
            terminal.reason = data["reason"]?.stringValue
            terminal.status = nil
            return [.resync]
        case "finished":
            terminal.state = "finished"
            terminal.exitCode = data["exit_code"]?.coreInt
            terminal.finishedMs = data["finished_ms"]?.coreInt.map { Int64($0) }
            terminal.reason = data["reason"]?.stringValue
            terminal.signal = data["signal"]?.coreInt
            terminal.status = nil
            return [.resync]
        default:
            // An event type from a newer core.
            return []
        }
    }
}

// MARK: - Records from event data

// Event data is a `JSONValue`, whose numbers are doubles; these read it
// directly instead of round-tripping through `Codable`, so millisecond
// timestamps stay exact and a malformed field is skipped, as the lenient
// decoders in `CoreWire` do.

extension JSONValue {
    fileprivate var coreBool: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    fileprivate var coreInt: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(exactly: value)
    }

    fileprivate var coreStringArray: [String]? {
        guard case .array(let values) = self else { return nil }
        return values.compactMap(\.stringValue)
    }

    fileprivate var coreStringMap: [String: String]? {
        guard case .object(let fields) = self else { return nil }
        return fields.compactMapValues(\.stringValue)
    }
}

extension CoreStatus {
    /// nil for `null` (no status) and for anything that is not an object.
    fileprivate init?(json: JSONValue) {
        guard case .object = json else { return nil }
        self.init(
            state: json["state"]?.stringValue ?? "", kind: json["kind"]?.stringValue,
            app: json["app"]?.stringValue, title: json["title"]?.stringValue,
            msg: json["msg"]?.stringValue, progress: json["progress"]?.coreInt)
    }
}

extension CoreForeground {
    fileprivate init(json: JSONValue) {
        self.init(
            pid: json["pid"]?.coreInt, name: json["name"]?.stringValue,
            argv: json["argv"]?.coreStringArray ?? [], cwd: json["cwd"]?.stringValue)
    }
}

extension CoreTerminal {
    /// The record a `created` or `restarted` event carries. `fallbackAddress`
    /// is the event's own `terminal`, for a record without one.
    fileprivate init?(json: JSONValue, fallbackAddress: String?) {
        guard case .object = json,
            let address = json["address"]?.stringValue ?? fallbackAddress
        else { return nil }
        let foreground: CoreForeground?
        if let value = json["foreground"], case .object = value {
            foreground = CoreForeground(json: value)
        } else {
            foreground = nil
        }
        self.init(
            address: address, name: json["name"]?.stringValue,
            labels: json["labels"]?.coreStringMap ?? [:],
            argv: json["argv"]?.coreStringArray ?? [], cwd: json["cwd"]?.stringValue ?? "",
            state: json["state"]?.stringValue ?? "live", pid: json["pid"]?.coreInt,
            exitCode: json["exit_code"]?.coreInt, signal: json["signal"]?.coreInt,
            reason: json["reason"]?.stringValue,
            createdMs: json["created_ms"]?.coreInt.map { Int64($0) },
            finishedMs: json["finished_ms"]?.coreInt.map { Int64($0) },
            status: json["status"].flatMap { CoreStatus(json: $0) },
            statusMs: json["status_ms"]?.coreInt.map { Int64($0) },
            reported: json["reported"]?.coreBool ?? false, turn: json["turn"]?.coreInt ?? 0,
            title: json["title"]?.stringValue ?? "", foreground: foreground,
            parent: json["parent"]?.stringValue, keep: json["keep"]?.coreBool ?? false,
            cols: json["cols"]?.coreInt, rows: json["rows"]?.coreInt)
    }
}
