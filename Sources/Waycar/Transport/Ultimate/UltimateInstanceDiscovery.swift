import Foundation

struct UltimateInstance: Codable, Sendable, Equatable {
    /// Stable project-home basename (including its hash), not the reusable port.
    let id: String
    let home: String
    let project: String
    let name: String
    let pid: Int
    let port: UInt16
}

enum UltimateInstanceDiscovery {
    /// No Ultimate CLI or Host-side JSON interpreter required. NUL separates
    /// fields so whitespace and newlines inside paths/JSON cannot forge records.
    /// A lock is a candidate only: callers must verify its port over HTTP.
    static let command = #"""
    for home in "$HOME"/.ultimate/projects/*; do
      [ -d "$home" ] && [ -r "$home/ultimate.lock" ] || continue
      lock=$(cat "$home/ultimate.lock") || continue
      project=$(cat "$home/project.json" 2>/dev/null) || project="{}"
      printf "%s\000%s\000%s\000" "$home" "$lock" "$project"
    done
    """#

    static func parse(_ data: Data) -> [UltimateInstance] {
        struct Lock: Decodable { let pid: Int; let port: Int; let project: String }
        struct Project: Decodable { let name: String? }
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        let decoder = JSONDecoder()
        var instances: [UltimateInstance] = []
        var seen: Set<String> = []
        var index = 0
        while index + 3 < fields.count {
            defer { index += 3 }
            guard let home = String(data: Data(fields[index]), encoding: .utf8), home.hasPrefix("/"),
                let lock = try? decoder.decode(Lock.self, from: Data(fields[index + 1])),
                lock.pid > 0, let port = UInt16(exactly: lock.port), port > 0,
                !lock.project.isEmpty, seen.insert(home).inserted
            else { continue }
            let metadata = try? decoder.decode(Project.self, from: Data(fields[index + 2]))
            instances.append(UltimateInstance(
                id: (home as NSString).lastPathComponent, home: home,
                project: lock.project,
                name: metadata?.name ?? (lock.project as NSString).lastPathComponent,
                pid: lock.pid, port: port))
        }
        return instances
    }
}
