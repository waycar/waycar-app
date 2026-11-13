import Foundation

@testable import Waycar

/// The shared Live Activity content envelope v1 vectors from
/// `plugin/test-vectors/`, the single source of truth for the encrypted
/// per-Host agent details across the Node plugin and this app. The JSON
/// file is bundled into the test target as a resource so both suites
/// exercise the same cases.
///
/// Payloads that stand in for a herdr pane use the observed `w…:p…` family
/// (uppercase included). Pin-order inventory ids such as `w1:p-work` stay
/// deliberately fake: those cases only need distinct opaque strings.
struct LiveActivityVectorFile: Decodable, Sendable {
    let valid: [Valid]
    let invalid: [Invalid]
    let pushToStart: PushToStart
    let degrade: Degrade

    /// The ciphertext-cap degrade order as plaintexts: the full `payload`,
    /// then each step a producer falls back to, in order.
    struct Degrade: Decodable, Sendable {
        let payload: Payload
        let steps: [Payload]
    }

    /// The static attributes a push-to-start carries for `hostId`, exactly
    /// as the plugin sends them. `attributes` stays raw so a test can run it
    /// through ActivityKit's default decoder itself.
    struct PushToStart: Decodable, Sendable {
        let hostId: String
        let attributesType: String
        let attributes: [String: String]
    }

    struct Valid: Decodable, Sendable, CustomStringConvertible {
        let name: String
        let key: String
        let keyId: String
        let envelope: String
        let payload: Payload
        let decodeOnly: Bool
        /// Most-recently-pinned first. Present on pin-order vectors.
        let pinnedPaneIDs: [String]
        /// Full-inventory counts (eligible statuses plus idle) when the vector
        /// pins the sort rule.
        let counts: Counts?
        /// Herdr `agent list` shape used to drive the shared sort rule.
        let inventory: [InventoryAgent]
        /// Row inputs for inventory vectors that pin rendered `rows` (#190):
        /// the registration row layout, Workspace labels by id, and tabs.
        let rowLayout: AgentRowLayout?
        let workspaceLabels: [String: String]
        let tabs: [Tab]
        /// Summary-store records (C1) by pane id, for progress vectors (#189).
        let summaries: [String: SummaryRecord]
        var description: String { name }

        enum CodingKeys: String, CodingKey {
            case name, key, keyId, envelope, payload, decodeOnly
            case pinnedPaneIDs = "pinned_pane_ids"
            case counts, inventory, tabs, summaries
            case rowLayout = "row_layout"
            case workspaceLabels = "workspace_labels"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            key = try container.decode(String.self, forKey: .key)
            keyId = try container.decode(String.self, forKey: .keyId)
            envelope = try container.decode(String.self, forKey: .envelope)
            payload = try container.decode(Payload.self, forKey: .payload)
            decodeOnly = try container.decodeIfPresent(Bool.self, forKey: .decodeOnly) ?? false
            pinnedPaneIDs = try container.decodeIfPresent([String].self, forKey: .pinnedPaneIDs) ?? []
            counts = try container.decodeIfPresent(Counts.self, forKey: .counts)
            inventory = try container.decodeIfPresent([InventoryAgent].self, forKey: .inventory) ?? []
            rowLayout = try container.decodeIfPresent(AgentRowLayout.Lenient.self, forKey: .rowLayout)?.layout
            workspaceLabels = try container.decodeIfPresent([String: String].self, forKey: .workspaceLabels) ?? [:]
            tabs = try container.decodeIfPresent([Tab].self, forKey: .tabs) ?? []
            summaries = try container.decodeIfPresent(
                [String: SummaryRecord].self, forKey: .summaries) ?? [:]
        }
    }

    struct SummaryRecord: Decodable, Sendable {
        let status: String
        let summary: String?
        let ts: Int64
        let progress: Progress?

        /// The app-side summary, or nil for a tombstone (the app drops them).
        func agentSummary(paneID: String) -> AgentSummary? {
            guard let summary else { return nil }
            let steps = progress.flatMap { progress in
                progress.done.flatMap { done in
                    progress.total.map { AgentProgress.Steps(done: done, total: $0) }
                }
            }
            return AgentSummary(
                paneID: paneID, status: AgentStatus(rawValue: status), text: summary,
                timestamp: ts,
                progress: AgentProgress(
                    steps: steps,
                    phase: progress?.phase.flatMap(AgentProgress.Phase.init(rawValue:))))
        }
    }

    struct Counts: Decodable, Sendable {
        let working: Int
        let blocked: Int
        let done: Int
        let idle: Int
    }

    struct Tab: Decodable, Sendable {
        let tabID: String
        let workspaceID: String
        let label: String
        let position: Int
        let count: Int

        enum CodingKeys: String, CodingKey {
            case tabID = "tab_id"
            case workspaceID = "workspace_id"
            case label, position, count
        }
    }

    struct InventoryAgent: Decodable, Sendable {
        let paneID: String
        let agentStatus: String
        let agent: String?
        let name: String?
        let displayAgent: String?
        let terminalTitle: String?
        let terminalTitleStripped: String?
        let workspaceID: String?
        let tabID: String?
        let cwd: String?

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case agentStatus = "agent_status"
            case agent, name, cwd
            case displayAgent = "display_agent"
            case terminalTitle = "terminal_title"
            case terminalTitleStripped = "terminal_title_stripped"
            case workspaceID = "workspace_id"
            case tabID = "tab_id"
        }
    }

    struct Payload: Decodable, Sendable {
        let host: String
        let agents: [Agent]
    }

    struct Agent: Decodable, Sendable {
        let pane: String
        let kind: String
        let name: String?
        let status: String
        let title: String?
        let workspace: String?
        let rows: [[AgentActivityDetails.Field]]?
        /// The estimate a reader must yield: `expectProgress` when the
        /// vector sends a deliberately malformed raw `progress`, else the
        /// well-formed `progress` itself.
        let progress: Progress?

        enum CodingKeys: String, CodingKey {
            case pane, kind, name, status, title, workspace, rows, progress, expectProgress
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pane = try container.decode(String.self, forKey: .pane)
            kind = try container.decode(String.self, forKey: .kind)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            status = try container.decode(String.self, forKey: .status)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            workspace = try container.decodeIfPresent(String.self, forKey: .workspace)
            rows = try container.decodeIfPresent(
                [[AgentActivityDetails.Field]].self, forKey: .rows)
            progress = try container.contains(.expectProgress)
                ? container.decodeIfPresent(Progress.self, forKey: .expectProgress)
                : container.decodeIfPresent(Progress.self, forKey: .progress)
        }

        /// The app-side detail this wire agent stands for.
        var detail: AgentActivityDetails.AgentDetail {
            AgentActivityDetails.AgentDetail(
                paneID: pane, kind: kind, name: name, workspace: workspace, status: status,
                title: title, rows: rows, progress: agentProgress)
        }

        /// The app-side estimate, or nil when the vector expects none.
        var agentProgress: AgentProgress? {
            guard let progress else { return nil }
            let steps = progress.done.flatMap { done in
                progress.total.map { AgentProgress.Steps(done: done, total: $0) }
            }
            return AgentProgress(
                steps: steps, phase: progress.phase.flatMap(AgentProgress.Phase.init(rawValue:)))
        }
    }

    struct Progress: Decodable, Sendable {
        let done: Int?
        let total: Int?
        let phase: String?
    }

    struct Invalid: Decodable, Sendable, CustomStringConvertible {
        let name: String
        let key: String
        let envelope: String
        let error: String
        var description: String { name }
    }

    static let shared: LiveActivityVectorFile = {
        guard
            let url = Bundle(for: BundleLocator.self)
                .url(forResource: "live-activity-content-v1", withExtension: "json")
        else {
            fatalError("live-activity-content-v1.json is missing from the test bundle")
        }
        do {
            return try JSONDecoder().decode(
                LiveActivityVectorFile.self, from: Data(contentsOf: url))
        } catch {
            fatalError("shared live-activity vectors failed to load: \(error)")
        }
    }()

    private final class BundleLocator {}
}
