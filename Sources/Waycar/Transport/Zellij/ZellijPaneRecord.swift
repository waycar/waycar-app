import Foundation

/// Unversioned list-panes/list-tabs JSON: unknown fields ignored, optional facts absent on older rows.
struct ZellijPaneRecord: Decodable, Sendable, Equatable {
    let id: Int
    var isPlugin: Bool? = nil
    var isSuppressed: Bool? = nil
    var isFocused: Bool? = nil
    var isFloating: Bool? = nil
    var exited: Bool? = nil
    var exitStatus: Int? = nil
    var title: String? = nil
    let tabID: Int
    var tabPosition: Int? = nil
    var tabName: String? = nil
    var paneCommand: String? = nil
    var paneCwd: String? = nil
    var terminalCommand: String? = nil
    var paneColumns: Int? = nil
    var paneRows: Int? = nil
    var programStatus: [ZellijProgramStatus]? = nil

    var isVisible: Bool { isPlugin != true && isSuppressed != true }
    var rootStatus: ZellijProgramStatus? { programStatus?.first { $0.id == nil } }

    enum CodingKeys: String, CodingKey {
        case id, exited, title
        case isPlugin = "is_plugin"
        case isSuppressed = "is_suppressed"
        case isFocused = "is_focused"
        case isFloating = "is_floating"
        case exitStatus = "exit_status"
        case tabID = "tab_id"
        case tabPosition = "tab_position"
        case tabName = "tab_name"
        case paneCommand = "pane_command"
        case paneCwd = "pane_cwd"
        case terminalCommand = "terminal_command"
        case paneColumns = "pane_columns"
        case paneRows = "pane_rows"
        case programStatus = "program_status"
    }
}

struct ZellijProgramStatus: Decodable, Sendable, Equatable {
    var id: String? = nil
    var state: String? = nil
    var kind: String? = nil
    var progress: Double? = nil
    var app: String? = nil
    var title: String? = nil
    var msg: String? = nil
    var updatedMs: Int64? = nil

    enum CodingKeys: String, CodingKey {
        case id, state, kind, progress, app, title, msg
        case updatedMs = "updated_ms"
    }

    var agentStatus: AgentStatus? {
        guard let state else { return nil }
        if state.lowercased() == "error" { return .blocked }
        return ZellijPaneState.status(state.lowercased())
    }
}

struct ZellijTabRecord: Decodable, Sendable, Equatable {
    let tabID: Int
    var position: Int? = nil
    var name: String? = nil
    var active: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case position, name, active
    }
}
