import Foundation
import Synchronization

/// The OpenCode 2 install detection found, and its shared server's
/// registration (`docs/design/opencode-backend.md`, O1, O2, O5). Detection
/// runs only `opencode --version`, `opencode service status` and a read of
/// the registration file's `url`, `pid` and `version`, which start nothing;
/// it never reads or keeps the password. OpenCode 1 (bare `1.x.y`) has no
/// presence at all: it stays a terminal agent.
struct OpenCodePresence: Sendable, Equatable, Codable {
    /// The binary's absolute path on the Host.
    var path: String
    /// The version after `opencode v` ("2.2.7").
    var version: String
    /// The URL `opencode service status` printed: its server answered. Nil
    /// when it printed `stopped`, and below the floor, where it is not asked.
    var serverURL: String?
    /// The registration file's `url`, `pid` and `version`, when it has them:
    /// where a stopped server ran last, which the stopped-server probe dials.
    var registeredURL: String?
    var registeredPID: Int?
    var registeredVersion: String?
    /// `$XDG_STATE_HOME/opencode/service.json`, by default
    /// `~/.local/state/opencode/service.json`; `~/` is the Host's home.
    var registrationPath: String

    init(
        path: String, version: String, serverURL: String? = nil, registeredURL: String? = nil,
        registeredPID: Int? = nil, registeredVersion: String? = nil,
        registrationPath: String = OpenCodePresence.defaultRegistrationPath
    ) {
        self.path = path
        self.version = version
        self.serverURL = serverURL
        self.registeredURL = registeredURL
        self.registeredPID = registeredPID
        self.registeredVersion = registeredVersion
        self.registrationPath = registrationPath
    }

    static let defaultRegistrationPath = "~/.local/state/opencode/service.json"

    /// The oldest OpenCode 2 Waycar drives (design: floor 2.2.0).
    static let minimumVersion = "2.2.0"

    /// OpenCode's default service port on Linux and macOS (O5).
    static let defaultPort: UInt16 = 49374

    /// At or above `minimumVersion`. A version that does not read as
    /// `major.minor.patch` cannot vouch for the API.
    var meetsFloor: Bool { Self.meetsFloor(version) }

    static func meetsFloor(_ version: String) -> Bool {
        guard let found = components(version), let floor = components(minimumVersion) else { return false }
        return !found.lexicographicallyPrecedes(floor)
    }

    private static func components(_ version: String) -> [Int]? {
        guard let match = version.firstMatch(of: /^([0-9]+)\.([0-9]+)\.([0-9]+)/),
              let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3)
        else { return nil }
        return [major, minor, patch]
    }

    /// `service status` printed a URL.
    var isRunning: Bool { serverURL != nil }

    /// Where Waycar's direct-tcpip channels go: the running server's URL,
    /// else the registered one (a stopped server's last address).
    var endpoint: OpenCodeEndpoint? {
        (serverURL ?? registeredURL).flatMap(OpenCodeEndpoint.init(url:))
    }
}

/// The address and port one OpenCode server URL names, as Waycar dials it
/// over direct-tcpip: a server bound to loopback or to every address is
/// dialed on `127.0.0.1`, any other at its registered address.
struct OpenCodeEndpoint: Sendable, Equatable {
    let host: String
    let port: UInt16

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    init?(url: String) {
        guard let components = URLComponents(string: url.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = components.host, !host.isEmpty
        else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        guard !host.isEmpty, let port = UInt16(exactly: port), port > 0 else { return nil }
        switch host.lowercased() {
        case "127.0.0.1", "localhost", "0.0.0.0", "::": self.host = "127.0.0.1"
        default: self.host = host
        }
        self.port = port
    }
}

/// OpenCode's own session id format (`packages/schema/src/identifier.ts`,
/// `session-id.ts` at v2.2.7): `ses_`, then 12 hex digits of the low 48 bits
/// of `~(milliseconds * 0x1000 + counter)` (newer ids sort first), then 14
/// random base62 characters. Waycar mints the id so a create whose answer was
/// lost is retried with the same id, which OpenCode treats as the same
/// session (O11).
struct OpenCodeSessionID: Sendable {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    private var lastTimestamp: Int64 = 0
    private var counter: Int64 = 0

    /// A process-wide minter, so two ids minted in one millisecond differ in
    /// their counter as OpenCode's own do.
    private static let shared = Mutex(OpenCodeSessionID())

    static func mint(now: Date = Date()) -> String {
        shared.withLock { $0.next(timestamp: Int64(now.timeIntervalSince1970 * 1000)) }
    }

    mutating func next(timestamp: Int64, random: [UInt8]? = nil) -> String {
        if timestamp != lastTimestamp {
            lastTimestamp = timestamp
            counter = 0
        }
        counter += 1
        let value = ~(UInt64(bitPattern: timestamp) &* 0x1000 &+ UInt64(bitPattern: counter))
        let time = (0..<6).map { index in
            let byte = UInt8(truncatingIfNeeded: value >> UInt64(40 - 8 * index))
            return String(byte, radix: 16).leftPadded(to: 2)
        }.joined()
        let bytes = random ?? (0..<14).map { _ in UInt8.random(in: .min ... .max) }
        return "ses_" + time + String(bytes.map { Self.alphabet[Int($0) % 62] })
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
