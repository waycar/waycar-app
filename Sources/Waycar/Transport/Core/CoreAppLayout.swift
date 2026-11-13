import Foundation

/// Read-only names from the Herdr desktop app's unversioned document.
/// Membership comes only from terminal labels; the root tree is ignored.
struct CoreAppLayout: Sendable, Decodable {
    struct Tab: Sendable {
        var id: String
        var name: String?
    }

    struct Space: Sendable {
        var id: String
        var name: String?
        var folder: String?
        var tabs: [Tab]
    }

    var spaces: [Space]

    init(from decoder: any Decoder) throws {
        let json = try JSONValue(from: decoder)
        spaces = Self.array(json["spaces"]).compactMap { space in
            guard let id = space["id"]?.stringValue else { return nil }
            return Space(
                id: id, name: space["name"]?.stringValue,
                folder: space["folder"]?.stringValue,
                tabs: Self.array(space["tabs"]).compactMap { tab in
                    guard let id = tab["id"]?.stringValue else { return nil }
                    return Tab(id: id, name: tab["name"]?.stringValue)
                })
        }
    }

    private static func array(_ value: JSONValue?) -> [JSONValue] {
        guard let value, case .array(let items) = value else { return [] }
        return items
    }

    struct Request: Encodable, Sendable {
        let name = "herdr-app"
    }

    struct Result: Decodable, Sendable {
        var value: CoreAppLayout?
    }
}
