import Foundation

/// Ids Waycar and its host tools exchange for herdr-core objects (design §6).
///
/// - Pane: `hc:<address>`.
/// - Terminal: `hc:<core id prefix>:<address>`. A state wipe restarts the
///   addresses at `t1` and changes the core's id, so the prefix keeps a
///   terminal id unique per terminal lifetime.
/// - Tab: `hc:tab:<key>`; Workspace: `hc:ws:<key>`.
///
/// An address (`t7`, `t1b`, `box/t3`) is opaque: it is carried and compared,
/// never parsed or validated here.
enum CoreID {
    static let prefix = "hc:"

    /// The app-side Pane id of a terminal address.
    static func pane(_ address: String) -> String { prefix + address }

    /// The address inside a Pane id; nil for any other id, and for the
    /// bare prefix.
    static func address(ofPane id: String) -> String? {
        guard id.hasPrefix(prefix) else { return nil }
        let address = String(id.dropFirst(prefix.count))
        return address.isEmpty ? nil : address
    }

    /// Whether `id` is a Pane id of this backend.
    static func isCorePane(_ id: String) -> Bool { address(ofPane: id) != nil }

    /// The Terminal id: `corePrefix` is the first 8 characters of the core's
    /// id (``CoreSnapshotBuilder/corePrefix(of:)``).
    static func terminal(corePrefix: String, address: String) -> String {
        "\(prefix)\(corePrefix):\(address)"
    }

    /// The two parts of a Terminal id (`hc:<core prefix>:<address>`); nil
    /// unless it has exactly that shape: the `hc:` prefix, a non-empty core
    /// prefix without `:`, and a non-empty address without `:` (it may hold
    /// `/`). The address is not otherwise looked at.
    static func parts(ofTerminal id: String) -> (corePrefix: String, address: String)? {
        guard id.hasPrefix(prefix) else { return nil }
        let pieces = id.dropFirst(prefix.count).split(
            separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty else { return nil }
        return (corePrefix: String(pieces[0]), address: String(pieces[1]))
    }

    static func tab(key: String) -> String { "\(prefix)tab:\(key)" }

    static func workspace(key: String) -> String { "\(prefix)ws:\(key)" }
}
