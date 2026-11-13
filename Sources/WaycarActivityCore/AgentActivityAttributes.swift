#if canImport(ActivityKit)
import ActivityKit
#endif
import Foundation

/// Static Live Activity attributes for one Host (docs/agents/live-activity-contract.md).
/// The type name is shipped-forever: a push-to-start names it verbatim as
/// APNs `attributes-type`, and ActivityKit decodes `hostID` from the push's
/// `attributes` with its default `JSONDecoder`.
///
/// `ContentState` is a plain Codable value so non-UI targets can decode an
/// update without linking ActivityKit. The ActivityKit conformance is
/// compiled only when the framework is available.
struct AgentActivityAttributes: Codable, Hashable, Sendable {
    var hostID: String

    /// Dynamic Live Activity content. Every field is a primitive so
    /// ActivityKit's default `JSONDecoder` (no date/key strategies) can
    /// decode an APNs `content-state` without dropping the update.
    struct ContentState: Codable, Hashable, Sendable {
        var counts: Counts
        var envelope: Envelope?

        /// `idle` is additive: pushes from a plugin or relay that predates it
        /// omit the key, and ActivityKit's default decoder must still accept
        /// them, so a missing `idle` decodes as 0. Idle Agents are counted
        /// for display only — they never start or keep an activity alive.
        struct Counts: Codable, Hashable, Sendable {
            var working: Int
            var blocked: Int
            var done: Int
            var idle: Int

            init(working: Int, blocked: Int, done: Int, idle: Int = 0) {
                self.working = working
                self.blocked = blocked
                self.done = done
                self.idle = idle
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                working = try container.decode(Int.self, forKey: .working)
                blocked = try container.decode(Int.self, forKey: .blocked)
                done = try container.decode(Int.self, forKey: .done)
                idle = try container.decodeIfPresent(Int.self, forKey: .idle) ?? 0
            }
        }

        /// Cleartext `{v,kid,n,ct}` frame carried inside content-state.
        /// Opening it is `AgentActivityEnvelope`'s job; an absent or
        /// undecryptable envelope degrades rendering to counts-only.
        struct Envelope: Codable, Hashable, Sendable {
            var v: Int
            var kid: String
            var n: String
            var ct: String
        }
    }
}

#if canImport(ActivityKit)
extension AgentActivityAttributes: ActivityAttributes {}
#endif
