import CoreGraphics
import Foundation

/// One field the Agent Footer can show: an Agent List field, or one only the
/// Agent screen knows (branch, usage figures, backend, connection).
enum AgentFooterField: RawRepresentable, Codable, Hashable, Sendable {
    /// Agent List Fields vocabulary. Never `.stateIcon` / `.stateText`: the
    /// footer has no status column to defer to, and decoding drops them.
    case row(AgentRowToken)
    case branch, model, context, cost, rate, backend, transport, progress

    /// Built-in fields the editor offers, in picker order.
    static let offered: [AgentFooterField] = [
        .row(.agent), .row(.directory), .branch, .row(.workspace), .row(.tab), .row(.pane),
        .row(.host), .row(.status), .row(.terminalTitleStripped), .row(.terminalTitle),
        .model, .context, .cost, .rate, .backend, .transport, .progress,
    ]

    init?(rawValue: String) {
        switch rawValue {
        case "branch": self = .branch
        case "model": self = .model
        case "context": self = .context
        case "cost": self = .cost
        case "rate": self = .rate
        case "backend": self = .backend
        case "transport": self = .transport
        case "progress": self = .progress
        default:
            guard let token = AgentRowToken(rawValue: rawValue), token != .stateIcon, token != .stateText
            else { return nil }
            self = .row(token)
        }
    }

    var rawValue: String {
        switch self {
        case .row(let token): token.rawValue
        case .branch: "branch"
        case .model: "model"
        case .context: "context"
        case .cost: "cost"
        case .rate: "rate"
        case .backend: "backend"
        case .transport: "transport"
        case .progress: "progress"
        }
    }

    var title: String {
        switch self {
        case .row(let token):
            switch token {
            case .agent: "Agent"
            case .directory: "Directory"
            case .workspace: "Workspace"
            case .tab: "Tab"
            case .pane: "Pane"
            case .host: "Host"
            case .status: "Status"
            case .terminalTitle: "Terminal Title (Raw)"
            case .terminalTitleStripped: "Terminal Title"
            case .stateIcon: "State Icon"
            case .stateText: "State"
            case .runtime: "Runtime"
            case .custom(let name): "$\(name)"
            }
        case .branch: "Branch"
        case .model: "Model"
        case .context: "Context"
        case .cost: "Cost"
        case .rate: "Tokens/s"
        case .backend: "Backend"
        case .transport: "Connection"
        case .progress: "Progress"
        }
    }

    var systemImage: String {
        switch self {
        case .row(let token):
            switch token {
            case .agent: "person.crop.circle"
            case .directory: "folder"
            case .workspace: "square.stack.3d.up"
            case .tab: "rectangle.on.rectangle"
            case .pane: "rectangle.split.2x1"
            case .host: "server.rack"
            case .status: "circle.dashed"
            case .terminalTitle, .terminalTitleStripped: "textformat"
            case .stateIcon, .stateText: "circle.fill"
            case .runtime: "square.grid.2x2"
            case .custom: "puzzlepiece"
            }
        case .branch: "arrow.triangle.branch"
        case .model: "cpu"
        case .context: "gauge.with.dots.needle.33percent"
        case .cost: "dollarsign.circle"
        case .rate: "speedometer"
        case .backend: "square.grid.2x2"
        case .transport: "network"
        case .progress: "chart.bar.fill"
        }
    }

    var isUsage: Bool {
        switch self {
        case .model, .context, .cost, .rate: true
        default: false
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let name = try container.decode(String.self)
        guard let field = Self(rawValue: name) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown footer field")
        }
        self = field
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum AgentFooterTextSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

/// What the Agent Footer shows below the Toolbar: 1–3 lines of fields.
/// Decoding is lenient (#320): an unknown field or size from another build
/// is dropped or defaulted so one unfamiliar value never discards the layout.
struct AgentFooterLayout: Codable, Equatable, Sendable {
    static let maximumLines = 3
    static let maximumFieldsPerLine = 8

    var isEnabled: Bool
    /// 1...3 lines. A line may be empty while editing (renders nothing).
    var lines: [[AgentFooterField]]
    var textSize: AgentFooterTextSize

    static let `default` = AgentFooterLayout(
        isEnabled: true, lines: [[.row(.agent), .row(.directory), .progress]], textSize: .medium)

    init(isEnabled: Bool, lines: [[AgentFooterField]], textSize: AgentFooterTextSize) {
        self.isEnabled = isEnabled
        self.lines = lines
        self.textSize = textSize
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, lines, textSize
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        lines = try (container.decodeIfPresent([[String]].self, forKey: .lines) ?? Self.default.lines.map {
            $0.map(\.rawValue)
        }).map { $0.compactMap(AgentFooterField.init(rawValue:)) }
        textSize = try container.decodeIfPresent(String.self, forKey: .textSize)
            .flatMap(AgentFooterTextSize.init(rawValue:)) ?? .medium
    }

    var lineCount: Int { lines.count }

    /// Clamps to 1...3; growing appends empty lines, shrinking drops trailing lines.
    mutating func setLineCount(_ count: Int) {
        let target = min(max(count, 1), Self.maximumLines)
        if lines.count > target {
            lines.removeLast(lines.count - target)
        } else {
            lines.append(contentsOf: Array(repeating: [], count: target - lines.count))
        }
    }

    /// Clamps line count to 1...3 (0 lines → one empty line), fields per line
    /// to 8, keeps only a field's first use, drops the status-column tokens.
    func normalized() -> AgentFooterLayout {
        var seen = Set<AgentFooterField>()
        var result = self
        result.lines = lines.prefix(Self.maximumLines).map { line in
            Array(line.filter { field in
                field != .row(.stateIcon) && field != .row(.stateText) && seen.insert(field).inserted
            }.prefix(Self.maximumFieldsPerLine))
        }
        if result.lines.isEmpty { result.lines = [[]] }
        return result
    }

    func contains(_ field: AgentFooterField) -> Bool {
        lines.contains { $0.contains(field) }
    }

    /// The configured lines the footer draws: lines with at least one field,
    /// the first `maximumLines` of them. By configuration, so sizing and the
    /// top strip never change as values arrive.
    func shownLines(maximumLines: Int) -> [[AgentFooterField]] {
        Array(lines.filter { !$0.isEmpty }.prefix(max(0, maximumLines)))
    }

    /// Nominal size in points; fewer lines get more of the band each.
    static func pointSize(_ size: AgentFooterTextSize, lineCount: Int) -> CGFloat {
        switch (min(max(lineCount, 1), maximumLines), size) {
        case (1, .small): 13
        case (1, .medium): 15
        case (1, .large): 18
        case (2, .small): 10.5
        case (2, .medium): 12
        case (2, .large): 14
        case (_, .small): 8.5
        case (_, .medium): 10
        case (_, .large): 11
        }
    }

    /// Shrinks `nominal` so `lineCount` lines fit the band, never below 7 pt.
    static func fittedPointSize(nominal: CGFloat, lineCount: Int, availableHeight: CGFloat) -> CGFloat {
        let fitting = availableHeight / (CGFloat(max(lineCount, 1)) * 1.2)
        return max(7, min(nominal, fitting))
    }

    /// How many lines fit the band at the 7 pt floor.
    static func fittingLineCount(_ lineCount: Int, availableHeight: CGFloat) -> Int {
        max(0, min(lineCount, Int(availableHeight / (7 * 1.2))))
    }
}
