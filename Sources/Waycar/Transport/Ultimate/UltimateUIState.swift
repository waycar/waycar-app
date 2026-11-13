import Foundation

/// The shared `ultimate.ui` document is sent on every existing SSE stream as
/// `ui`, then Chord `uiOps`. Retain only the concluded ids, not tab-local UI.
struct UltimateUIState: Sendable {
    private static let key = "ext.conversations.concluded"
    private(set) var concluded: [Int] = []

    mutating func receive(_ event: UltimateServerEvent) throws {
        let data = try JSONDecoder().decode(JSONValue.self, from: Data(event.data.utf8))
        if event.name == "ui" {
            concluded = Self.ids(data["value"]?[Self.key])
            return
        }
        guard case .array(let ops) = data["ops"] else { return }
        for op in ops {
            guard case .array(let fields) = op, let kind = fields.first?.stringValue else { continue }
            if kind == "r", fields.count == 2 {
                concluded = Self.ids(fields[1][Self.key])
                continue
            }
            guard fields.count >= 2, case .array(let path) = fields[1] else { continue }
            guard path.first?.stringValue == Self.key else { continue }
            if path.count == 1 {
                switch kind {
                case "s" where fields.count == 3: concluded = Self.ids(fields[2])
                case "d": concluded = []
                case "p" where fields.count == 5:
                    guard let index = Self.integer(fields[2]), let remove = Self.integer(fields[3]),
                          index >= 0, remove >= 0, index <= concluded.count,
                          remove <= concluded.count - index else { throw Self.invalidPatch }
                    concluded.replaceSubrange(index..<(index + remove), with: Self.ids(fields[4]))
                case "m" where fields.count == 3:
                    let order = Self.ids(fields[2])
                    guard order.sorted() == Array(concluded.indices) else { throw Self.invalidPatch }
                    concluded = order.map { concluded[$0] }
                default: throw Self.invalidPatch
                }
            } else if path.count == 2, let index = Self.integer(path[1]), index >= 0 {
                switch kind {
                case "s" where fields.count == 3:
                    guard let id = Self.integer(fields[2]), index <= concluded.count else { throw Self.invalidPatch }
                    if index == concluded.count { concluded.append(id) } else { concluded[index] = id }
                case "d":
                    guard concluded.indices.contains(index) else { throw Self.invalidPatch }
                    concluded.remove(at: index)
                default: throw Self.invalidPatch
                }
            } else { throw Self.invalidPatch }
        }
    }

    private static var invalidPatch: TransportError {
        .channelFailed(detail: "Ultimate sent an invalid concluded-list update.")
    }

    private static func integer(_ value: JSONValue) -> Int? {
        guard case .number(let number) = value else { return nil }
        return Int(exactly: number)
    }

    private static func ids(_ value: JSONValue?) -> [Int] {
        guard case .array(let values) = value else { return [] }
        return values.compactMap(integer)
    }
}
