import Foundation

/// The first SSE system event identifies the project behind a reusable port.
/// The lock's PID belongs to the supervisor, not this child process.
struct UltimateIdentity: Decodable, Sendable {
    struct Project: Decodable, Sendable { let root: String }
    struct Persistence: Decodable, Sendable { let path: String }
    let project: Project
    let persistence: Persistence

    func validate(_ instance: UltimateInstance) throws {
        guard project.root == instance.project,
            persistence.path.hasPrefix(instance.home + "/")
        else { throw UltimateIdentityError.mismatch }
    }
}

enum UltimateIdentityError: Error { case mismatch, missingSystem }
