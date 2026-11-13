import Foundation
import Observation

/// The Skills pane's load state. Fetching is lazy — the first time the pane
/// is selected, not on attach — and a manual refresh keeps the previous list
/// on screen instead of flashing back to a spinner.
///
/// Kept off the SSH types (standing repo rule): it talks to one injected
/// closure over the `ConsoleStore`, so it is testable against a script.
@MainActor
@Observable
final class SkillsPaneStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private var catalogue = SkillsCatalogueMachine()

    var phase: Phase {
        switch catalogue.state {
        case .idle: .idle
        case .loading: .loading
        case .loaded: .loaded
        case .failed(_, let message): .failed(message)
        }
    }

    var skills: [AgentSkill] { catalogue.skills }

    /// The invocation prefixes this agent's skill sources use, known before
    /// anything is fetched so typing one can open suggestions immediately.
    private let commandPrefixes: [String]
    private let fetch: (_ forceRefresh: Bool) async throws -> [AgentSkill]

    init(
        commandPrefixes: [String] = ["/"],
        fetch: @escaping (_ forceRefresh: Bool) async throws -> [AgentSkill]
    ) {
        self.commandPrefixes = commandPrefixes
        self.fetch = fetch
    }

    /// A refresh failure is still actionable while the previous catalogue stays visible.
    var refreshFailureMessage: String? {
        guard !skills.isEmpty, case .failed(let message) = phase else { return nil }
        return message
    }

    var projectSkills: [AgentSkill] { skills.filter { $0.scope == .project } }
    var globalSkills: [AgentSkill] { skills.filter { $0.scope == .global } }

    /// The prefixes that open inline suggestions: the catalog's plus any a
    /// loaded skill actually carries, longest first so `/skill:` is matched
    /// before `/`.
    var triggerPrefixes: [String] {
        var prefixes = Set(commandPrefixes)
        for skill in skills {
            prefixes.insert(skill.commandPrefix)
        }
        return prefixes.sorted { lhs, rhs in
            lhs.count != rhs.count ? lhs.count > rhs.count : lhs < rhs
        }
    }

    /// Case- and diacritic-insensitive match over the command and the
    /// description — the Snippets rule, plus the prefix so "$" finds Codex
    /// skills.
    func matching(_ query: String) -> [AgentSkill] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return skills }
        return skills.filter { skill in
            skill.command.localizedStandardContains(trimmed)
                || (skill.description?.localizedStandardContains(trimmed) ?? false)
        }
    }

    /// The pane's appearance hook: loads once, then reuses what is loaded
    /// (the ConsoleStore caches per connection underneath).
    func loadIfNeeded() async {
        await send(.loadIfNeeded)
    }

    func refresh() async {
        await send(.refresh)
    }

    private func send(_ event: SkillsCatalogueMachine.Event) async {
        for effect in catalogue.handle(event) {
            switch effect {
            case .fetch(let token, let forceRefresh):
                let outcome: SkillsCatalogueMachine.Outcome
                do {
                    outcome = .loaded(try await fetch(forceRefresh))
                } catch is CancellationError {
                    outcome = .cancelled
                } catch {
                    outcome = .failed(Self.message(for: error))
                }
                await send(.finished(token, outcome))
            }
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case TransportError.sshUnreachable:
            "The Host is not connected."
        case TransportError.timedOut:
            "The Host did not answer in time."
        default:
            "Loading skills failed: \(error)"
        }
    }
}
