import Foundation

/// An Agent Summary (`CONTEXT.md`): one sentence of at most 100 characters
/// the Host's `waycar` plugin asks a cheap model for — what an Agent is
/// doing, or where it ended up. The plugin refreshes it about once a minute
/// while Waycar asks (`refreshCommand`), only for Agents whose screen
/// changed, and on every Done or Blocked push. It keeps the latest one per
/// pane in its config dir (`plugin/README.md`); the Console shows it under
/// the Agent's row, fresh while it still describes the Agent's status.
struct AgentSummary: Sendable, Equatable {
    let paneID: String
    /// The Agent Status the plugin read the screen in: Working, Idle, Done,
    /// or Blocked.
    let status: AgentStatus
    let text: String
    /// When the plugin wrote it, in Host unix milliseconds.
    let timestamp: Int64
    /// The turn's progress estimate the plugin stored with the summary
    /// (#189); nil when it had none or sent one this build cannot read.
    let progress: AgentProgress?
    /// When the plugin last refreshed `progress`, in Host unix milliseconds;
    /// the plugin moves it on plan-step pushes without touching `timestamp`.
    /// Nil when the record predates the key: `progressWrittenAt` falls back
    /// to `timestamp`.
    let progressTimestamp: Int64?
    /// Whether the record carried the `progress` key at all — an estimate,
    /// `null`, or a value this build cannot read. A plugin that tracks
    /// progress writes the key on every summary; an older one never does,
    /// so this is how the app learns the Host reports progress (#189).
    /// Fixtures default to a current plugin.
    let declaresProgress: Bool

    init(
        paneID: String, status: AgentStatus, text: String, timestamp: Int64,
        progress: AgentProgress? = nil, progressTimestamp: Int64? = nil,
        declaresProgress: Bool = true
    ) {
        self.paneID = paneID
        self.status = status
        self.text = text
        self.timestamp = timestamp
        self.progress = progress
        self.progressTimestamp = progressTimestamp
        self.declaresProgress = declaresProgress
    }

    /// When the progress estimate was last written: its own stamp, else the
    /// summary's.
    var progressWrittenAt: Int64 { progressTimestamp ?? timestamp }

    /// The plugin config dir's subdirectory holding one file per pane.
    static let directoryName = "summaries"

    /// The statuses a summary can describe; a line for any other is skipped.
    static let describedStatuses: Set<AgentStatus> = [.working, .idle, .done, .blocked]

    /// A Host is trusted to send short text (the plugin caps it at 100),
    /// but a row must not be asked to lay out whatever a broken file holds.
    static let maximumTextLength = 160

    /// A summary stops being fresh after this long, even while its Agent
    /// stays in the status it was written for.
    static let freshness: TimeInterval = 3 * 60

    /// The Agent Summary refresh action the `waycar` plugin registers.
    static let refreshActionID = "refresh-summaries"

    /// Asks the plugin to refresh every Agent's summary. herdr spawns the
    /// action and returns at once; the new summaries land in the store over
    /// the following seconds. The plugin holds its own lock and minimum
    /// interval, so an extra call costs nothing.
    static func refreshCommand(pluginID: String) -> String {
        "herdr plugin action invoke \(refreshActionID) --plugin '\(pluginID)'"
    }

    /// Classifies a failed `refreshCommand`: herdr prints
    /// `{"error":{"code":…}}` on stderr. A plugin without the action (one
    /// predating it) or a herdr without `plugin action invoke` (a usage
    /// error, exit 2) cannot refresh until something on the Host changes; a
    /// missing plugin is the same `pluginNotInstalled` the reads throw.
    static func refreshFailure(exitStatus: Int32, stderr: Data) -> any Error {
        struct Envelope: Decodable {
            struct Body: Decodable { let code: String? }
            let error: Body?
        }
        let code = stderr.split(separator: 0x0A).lazy
            .compactMap { try? JSONDecoder().decode(Envelope.self, from: Data($0)) }
            .compactMap { $0.error?.code }
            .first
        switch code {
        case "plugin_action_not_found":
            return AgentSummaryRefreshError.actionUnavailable
        case "plugin_not_found":
            return NotificationRegistrationError.pluginNotInstalled
        default:
            if exitStatus == 2 { return AgentSummaryRefreshError.actionUnavailable }
            return TransportError.channelFailed(detail: "The Agent Summary refresh failed.")
        }
    }

    /// One exec that prints every summary file in `directory/summaries` as
    /// NDJSON (one file per line); nothing when the directory is absent.
    /// `quotedConfigDirectory` is the plugin config dir already quoted for
    /// the Host shell; it travels as `$1` so the script body needs no
    /// escaping. Each file is capped so a corrupt one cannot flood the
    /// channel.
    static func readCommand(quotedConfigDirectory: String) -> String {
        "/bin/sh -c 'd=\"$1/\(directoryName)\"; [ -d \"$d\" ] || exit 0; "
            + "for f in \"$d\"/*.json; do [ -f \"$f\" ] || continue; "
            + "head -c 4096 \"$f\"; echo; done' waycar \(quotedConfigDirectory)"
    }

    /// Parses the command's NDJSON output leniently: blank, malformed,
    /// future-version, or incomplete lines are skipped, and when a pane
    /// appears more than once the newest record wins. A record without text
    /// is the plugin's tombstone for a turn that produced no summary: it
    /// labels nothing, and it retires every older summary for its pane.
    static func latestByPane(fromNDJSON output: Data) -> [String: AgentSummary] {
        var newest: [String: Record] = [:]
        for line in output.split(separator: 0x0A) {
            guard let record = parse(line: Data(line)) else { continue }
            if let existing = newest[record.paneID], existing.timestamp >= record.timestamp {
                continue
            }
            newest[record.paneID] = record
        }
        return newest.compactMapValues { record in
            record.text.map {
                AgentSummary(
                    paneID: record.paneID, status: record.status, text: $0,
                    timestamp: record.timestamp, progress: record.progress,
                    progressTimestamp: record.progressTimestamp,
                    declaresProgress: record.declaresProgress)
            }
        }
    }

    /// One accepted line; `text` is nil for a tombstone.
    private struct Record {
        let paneID: String
        let status: AgentStatus
        let text: String?
        let timestamp: Int64
        let progress: AgentProgress?
        let progressTimestamp: Int64?
        let declaresProgress: Bool
    }

    private static func parse(line: Data) -> Record? {
        guard let record = try? JSONDecoder().decode(WireRecord.self, from: line) else {
            return nil
        }
        if let version = record.v, version != 1 { return nil }
        guard
            let pane = record.pane, !pane.isEmpty,
            let rawStatus = record.status?.trimmingCharacters(in: .whitespaces).lowercased(),
            case let status = AgentStatus(rawValue: rawStatus),
            describedStatuses.contains(status)
        else { return nil }
        let text = record.summary.map(singleLine).flatMap { $0.isEmpty ? nil : $0 }
        let timestamp = record.ts.flatMap(milliseconds) ?? 0
        return Record(
            paneID: pane, status: status,
            text: text.map { String($0.prefix(maximumTextLength)) }, timestamp: timestamp,
            progress: record.progress,
            progressTimestamp: record.progress == nil ? nil : record.progressTS.flatMap(milliseconds),
            declaresProgress: record.declaresProgress)
    }

    private static func milliseconds(_ value: Double) -> Int64? {
        value.isFinite ? Int64(exactly: value.rounded()) : nil
    }

    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The on-Host file shape: `{"v":1,"pane","status","summary","ts",
    /// "progress","progress_ts"}` (plus the plugin-internal `hash`, ignored
    /// here), with `"summary":null` for a tombstone. Every field optional
    /// and loosely typed so one odd field skips only its own line; an odd
    /// `progress` or `progress_ts` costs only itself, though an odd
    /// `progress` still declares the key.
    private struct WireRecord: Decodable {
        var v: Int?
        var pane: String?
        var status: String?
        var summary: String?
        var ts: Double?
        var progress: AgentProgress?
        var progressTS: Double?
        var declaresProgress: Bool

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            v = try? container.decodeIfPresent(Int.self, forKey: .v)
            pane = try? container.decodeIfPresent(String.self, forKey: .pane)
            status = try? container.decodeIfPresent(String.self, forKey: .status)
            summary = try? container.decodeIfPresent(String.self, forKey: .summary)
            ts = try? container.decodeIfPresent(Double.self, forKey: .ts)
            progress = (try? container.decodeIfPresent(WireProgress.self, forKey: .progress))?.progress
            progressTS = try? container.decodeIfPresent(Double.self, forKey: .progressTS)
            declaresProgress = container.contains(.progress)
        }

        private enum CodingKeys: String, CodingKey {
            case v, pane, status, summary, ts, progress
            case progressTS = "progress_ts"
        }
    }

    /// `{"done","total","phase"}`: steps need both integers, an unknown
    /// phase is ignored, and either half survives the other being invalid.
    private struct WireProgress: Decodable {
        var progress: AgentProgress?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let done = try? container.decodeIfPresent(Int.self, forKey: .done)
            let total = try? container.decodeIfPresent(Int.self, forKey: .total)
            let phase = (try? container.decodeIfPresent(String.self, forKey: .phase))
                .flatMap(AgentProgress.Phase.init(rawValue:))
            let steps = done.flatMap { done in
                total.flatMap { total in AgentProgress.Steps(done: done, total: total) }
            }
            progress = AgentProgress(steps: steps, phase: phase)
        }

        private enum CodingKeys: String, CodingKey {
            case done, total, phase
        }
    }
}

/// Why the Host could not refresh its Agent Summaries.
enum AgentSummaryRefreshError: Error, Equatable, Sendable {
    /// The plugin (or herdr) predates the refresh action. The Host keeps
    /// the summaries it has; asking again waits for the next connection.
    case actionUnavailable
}
