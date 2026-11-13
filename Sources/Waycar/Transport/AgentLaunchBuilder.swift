import Foundation

/// What every backend that starts an agent as a program (not by typing a
/// line into a shell) agrees on: which executable a kind runs, the
/// arguments it gets, and what the request's environment may hold. tmux
/// folds the result into one shell line; herdr-core hands it to
/// `terminal.run` as `argv` and `env`.
enum AgentLaunchBuilder {
    /// The executable a launch of `kind` runs: the supported kind's
    /// executable, else the kind itself. Throws `invalid_agent_kind` for a
    /// name that is not a plain word, which could not be one command.
    static func executable(forKind kind: String) throws -> String {
        let executable = SupportedAgentKind(rawValue: kind)?.executable ?? kind
        guard ShellWord.isBare(executable) else {
            throw HerdrAPIError(code: "invalid_agent_kind", message: "unknown agent kind: \(kind)")
        }
        return executable
    }

    /// A detected version at the server floor proves support, even on a
    /// replacement connection with a bare SSH PATH. Older versions may also
    /// support the flag, so only the capability probe can rule it out.
    static func codexSupportsNoDaemon(
        presence: CodexPresence?, probe: @Sendable () async throws -> Bool
    ) async -> Bool {
        if presence?.meetsFloor == true { return true }
        return (try? await probe()) ?? false
    }

    /// Missing executables are not negative capability evidence and must not
    /// populate a successful probe cache (login-shell PATHs can differ).
    static func codexNoDaemonProbe(stdout: String, stderr: String, exitCode: Int?) throws -> Bool {
        guard exitCode != nil, exitCode != 127, !(stdout + stderr).isEmpty else {
            throw TransportError.channelFailed(detail: "Could not probe Codex capabilities.")
        }
        return stdout.contains("--no-daemon") || stderr.contains("--no-daemon")
    }

    /// The program and its arguments, one word each: the kind's
    /// executable, `--no-daemon` for a codex that knows it (its shared
    /// daemon runs hooks with the environment of whichever pane started
    /// it) unless the request already has it, then the request's
    /// arguments. `codexSupportsNoDaemon` is only read for codex.
    static func argv(
        for request: AgentLaunchRequest,
        codexSupportsNoDaemon: @Sendable () async -> Bool
    ) async throws -> [String] {
        var words = [try executable(forKind: request.kind)]
        if request.kind == SupportedAgentKind.codex.rawValue, !request.joinsCodexServer,
            !request.arguments.contains("--no-daemon"), await codexSupportsNoDaemon()
        {
            words.append("--no-daemon")
        }
        return words + request.arguments
    }

    /// The request's environment after checking every name is one `env`
    /// (and `terminal.run`) can set, in name order.
    static func environment(of request: AgentLaunchRequest) throws -> [(name: String, value: String)]
    {
        guard request.environment.keys.allSatisfy(isEnvironmentName) else {
            throw HerdrAPIError(code: "invalid_env", message: "invalid environment variable name")
        }
        return request.environment.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// The one shell line tmux runs: the request's environment as an `env`
    /// prefix, so it reaches the agent alone (not the login shell left
    /// after it exits), then the ``argv(for:codexSupportsNoDaemon:)`` words.
    /// Plain words stay bare, anything else is single-quoted.
    static func shellLine(
        for request: AgentLaunchRequest,
        codexSupportsNoDaemon: @Sendable () async -> Bool
    ) async throws -> String {
        _ = try executable(forKind: request.kind)
        let variables = try environment(of: request)
        var words: [String] = []
        if !variables.isEmpty {
            words = ["env"] + variables.map { $0.name + "=" + $0.value }
        }
        words += try await argv(for: request, codexSupportsNoDaemon: codexSupportsNoDaemon)
        return words.map(ShellWord.quoted).joined(separator: " ")
    }

    /// `[A-Za-z_][A-Za-z0-9_]*`: a name `env` sets rather than runs.
    static func isEnvironmentName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !("0"..."9").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "_": true
            default: false
            }
        }
    }
}
