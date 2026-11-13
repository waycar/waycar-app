import Foundation

/// The absolute executable found by detection; no session is started by discovery.
struct ZellijPresence: Sendable, Equatable, Codable {
    var version: String
    var path: String
    static let minimumVersion = "0.46.0"

    var meetsFloor: Bool {
        guard let match = version.firstMatch(of: /^([0-9]+)\.([0-9]+)\.([0-9]+)(?:[-+].*)?$/),
            let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3)
        else { return false }
        return ![major, minor, patch].lexicographicallyPrecedes([0, 46, 0])
    }
}
