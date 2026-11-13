import Foundation

/// Pure: which Agent kind a program or command line runs. Shared by every
/// backend that finds Agents by their processes (tmux panes, herdr-core
/// terminals).
enum AgentKindDetection {
    /// Interpreters an agent CLI may run under; the script name follows.
    /// Python is matched by `isPython(_:)`.
    private static let interpreters: Set<String> = ["node", "bun", "deno", "env"]

    /// The name Muse's `muse` launcher execs its installed release under,
    /// `muse-bin-<version>`; truncated to 15 characters as tmux shows it
    /// (`muse-bin-1.4.4-`), it keeps this prefix.
    private static let museReleasePrefix = "muse-bin-"

    /// The kind whose executable is named `name` (a path is reduced to its
    /// last component).
    static func knownKind(executable name: String) -> String? {
        let base = basename(name)
        if base.hasPrefix(museReleasePrefix) { return SupportedAgentKind.muse.rawValue }
        return SupportedAgentKind.allCases.first { $0.executable == base }?.rawValue
    }

    /// The kind a foreground command line runs: its program, or the script
    /// an interpreter runs (`node …/bin/codex`). Two launchers need more
    /// (live, harness lab 2026-10-12):
    /// - Hermes Agent's installed `hermes` execs Python with its code inline
    ///   (`python3 -I -c 'import os, re, sys … /.hermes/hermes-agent …'`),
    ///   so `pane_current_command` reads `python3` and no script follows.
    /// - Cursor's `agent` alias runs as `…/bin/agent --use-system-ca
    ///   …/cursor-agent/versions/<v>/index.js`; `agent` alone is too common
    ///   a name to claim.
    /// Nil for anything else.
    static func kind(commandLine: String) -> String? {
        let words = commandLine.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let program = words.first else { return nil }
        if let kind = knownKind(executable: program) { return kind }
        let interpreter = basename(program)
        if interpreter == "agent", words.dropFirst().contains(where: { $0.contains("/cursor-agent/") }) {
            return SupportedAgentKind.cursor.rawValue
        }
        guard interpreters.contains(interpreter) || isPython(interpreter) else { return nil }
        if isPython(interpreter), words.contains("-c") {
            return commandLine.contains("/hermes-agent") ? SupportedAgentKind.hermes.rawValue : nil
        }
        guard let script = words.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
            return nil
        }
        return knownKind(executable: script)
    }

    /// Whether `name` is a Python interpreter: `python`, one carrying its
    /// version (`python3.12`), or macOS's framework build, which re-executes
    /// itself as `…/Python.app/Contents/MacOS/Python` (Homebrew's Python
    /// running Hermes Agent).
    private static func isPython(_ name: String) -> Bool {
        let lowered = name.lowercased()
        guard lowered.hasPrefix("python") else { return false }
        return lowered.dropFirst("python".count).allSatisfy { $0.isNumber || $0 == "." }
    }

    private static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
