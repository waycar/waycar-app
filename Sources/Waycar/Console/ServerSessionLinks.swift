import Foundation

/// Facts already read with an inventory. Command lines are live-only and
/// may contain secrets: never persist or log them.
struct ServerSessionLinkFacts: Sendable {
    /// A terminal pane's foreground command line, by pane id.
    var commandLines: [String: String] = [:]
    /// Where each server session came from, by session id, as its Backend
    /// reports it (Codex: `Thread.threadSource`, not the legacy `source`,
    /// which both clients send as vscode).
    var sessionOrigins: [String: String] = [:]
}

/// One card per server chat session (`ServerChatBackend`). Resolve strong
/// links before the conservative folder fallback; never change a terminal
/// projection's inventory.
@MainActor
enum ServerSessionLinks {
    /// The merged rows, and the terminal pane each linked session owns, by
    /// session row id: listed sessions and archived ones (`archived`), whose
    /// row is gone while their TUI may still run.
    struct Resolution {
        var rows: [ConsoleAgent]
        var terminals: [ConsoleAgent.ID: ConsoleAgent.TerminalLink]
        /// The sessions whose pane only the folder rule links: an archived
        /// session is never matched by folder, so Archive pins that pane
        /// first (`ConsoleStore.pinFolderLinkedTerminal(of:)`).
        var linkedByFolder: Set<ConsoleAgent.ID> = []
    }

    static func merge(
        _ rows: [ConsoleAgent], archived: [ConsoleScope: Set<String>] = [:],
        marker: (ConsoleAgent.ID) -> ChatModeMarker?
    ) -> [ConsoleAgent] {
        resolve(rows, archived: archived, marker: marker).rows
    }

    /// - Parameter archived: the session ids each server scope keeps
    ///   archived. A pane surely linked to one (its marker or command line)
    ///   stays hidden: Archive leaves the TUI running, and Resume brings the
    ///   session back to that same pane.
    static func resolve(
        _ rows: [ConsoleAgent], archived: [ConsoleScope: Set<String>] = [:],
        marker: (ConsoleAgent.ID) -> ChatModeMarker?
    ) -> Resolution {
        var links: [ConsoleAgent.ID: ConsoleAgent.TerminalLink] = [:]
        var hidden: Set<ConsoleAgent.ID> = []
        var linkedByFolder: Set<ConsoleAgent.ID> = []
        for (hostID, hostRows) in Dictionary(grouping: rows, by: \.hostID) {
            for server in ServerChatBackend.allCases {
                linkSessions(
                    hostRows, on: server,
                    archived: archived[ConsoleScope(hostID: hostID, backend: server.backend)] ?? [],
                    marker: marker, links: &links, hidden: &hidden, linkedByFolder: &linkedByFolder)
            }
        }
        let merged = rows.compactMap { row -> ConsoleAgent? in
            guard !hidden.contains(row.id) else { return nil }
            var row = row
            row.linkedTerminal = links[row.id]
            return row
        }
        return Resolution(rows: merged, terminals: links, linkedByFolder: linkedByFolder)
    }

    /// Links one Host's panes to `server`'s sessions: the pane's Chat
    /// Marker, else the session its command line names, else a one-to-one
    /// same-folder match between an unnamed, unpinned pane and a listed desk
    /// session.
    private static func linkSessions(
        _ hostRows: [ConsoleAgent], on server: ServerChatBackend, archived: Set<String>,
        marker: (ConsoleAgent.ID) -> ChatModeMarker?,
        links: inout [ConsoleAgent.ID: ConsoleAgent.TerminalLink],
        hidden: inout Set<ConsoleAgent.ID>,
        linkedByFolder: inout Set<ConsoleAgent.ID>
    ) {
        let kind = server.agentKind.rawValue
        let sessions = hostRows.filter { $0.backend == server.backend }
        let panes = hostRows.filter { $0.backend.hasTerminal && $0.agent.kind == kind }
        guard let hostID = hostRows.first?.hostID, !panes.isEmpty else { return }
        /// The row id of session `id`, listed or archived.
        func sessionNamed(_ id: String) -> ConsoleAgent.ID? {
            let sessionID = ConsoleAgent.ID(hostID: hostID, paneID: server.paneIDPrefix + id)
            return archived.contains(id) || sessions.contains { $0.id == sessionID } ? sessionID : nil
        }
        func link(_ pane: ConsoleAgent, to session: ConsoleAgent.ID) {
            hidden.insert(pane.id)
            // Several sure panes may show one session; any is a valid Attach.
            if links[session] == nil {
                links[session] = .init(id: pane.id, backend: pane.backend)
            }
        }
        let orderedPanes = panes.sorted { $0.agent.paneID < $1.agent.paneID }
        /// Panes whose marker names a session, listed or not: the folder
        /// rule never links them to another one.
        var pinned: Set<ConsoleAgent.ID> = []
        for pane in orderedPanes {
            guard let pin = marker(pane.id), pin.kind == kind, pin.applies(to: pane.agent),
                let reference = pin.session, reference.kind == "id", !reference.value.isEmpty
            else { continue }
            pinned.insert(pane.id)
            // A Chat Mode codex pane runs its own `--no-daemon` thread; an
            // OpenCode 2 pane always joins the shared server.
            guard !pin.chatMode || server == .opencode, let session = sessionNamed(reference.value)
            else { continue }
            link(pane, to: session)
        }
        for pane in orderedPanes where !hidden.contains(pane.id) {
            guard case .session(let id) = paneLink(pane.paneCommandLine, on: server),
                let session = sessionNamed(id)
            else { continue }
            link(pane, to: session)
        }
        let candidates = Dictionary(grouping: panes.filter {
            guard !hidden.contains($0.id), !pinned.contains($0.id), !$0.agent.cwd.isEmpty else { return false }
            return paneLink($0.paneCommandLine, on: server) == .unnamed
        }, by: { canonicalDirectory($0.agent.cwd) })
        let unmatchedSessions = Dictionary(grouping: sessions.filter {
            links[$0.id] == nil && joinsFolderFallback($0.serverSessionOrigin, on: server)
                && !$0.agent.cwd.isEmpty
        }, by: { canonicalDirectory($0.agent.cwd) })
        for (cwd, panes) in candidates {
            guard panes.count == 1, let pane = panes.first,
                let sessions = unmatchedSessions[cwd], sessions.count == 1, let session = sessions.first
            else { continue }
            link(pane, to: session.id)
            linkedByFolder.insert(session.id)
        }
    }

    /// What a pane's command line says about which session it shows.
    private enum PaneLink: Equatable {
        /// It shows no session of this server, or one it cannot name.
        case none
        /// It names this session.
        case session(String)
        /// It joins the server without naming a session: the folder
        /// fallback may link it.
        case unnamed
    }

    private static func paneLink(_ line: String?, on server: ServerChatBackend) -> PaneLink {
        switch server {
        case .codex:
            guard let line, AgentKindDetection.kind(commandLine: line) == "codex",
                case .success(let words) = StartAgentStore.parseArguments(line),
                !words.contains("--no-daemon")
            else { return .none }
            // An explicit resume names its thread, even when that thread
            // is not loaded. Unknown command lines prove no daemon link.
            guard let resume = words.firstIndex(of: "resume") else { return .unnamed }
            return words.indices.contains(resume + 1) ? .session(words[resume + 1]) : .none
        case .opencode:
            return openCodePaneLink(line)
        }
    }

    /// OpenCode 2.2.7's TUI flags (`opencode --help`): `--session <id>`,
    /// `-s <id>` or `--session=<id>` opens that session (O12). A private
    /// (`--standalone`) or other (`--server`) server, `--continue`'s unnamed
    /// last session, or a subcommand (`run`, `serve`, …) proves nothing;
    /// only a plain TUI, optionally on a folder, may link by folder.
    private static func openCodePaneLink(_ line: String?) -> PaneLink {
        guard let line, AgentKindDetection.kind(commandLine: line) == "opencode",
            case .success(let words) = StartAgentStore.parseArguments(line),
            let program = words.firstIndex(where: {
                ["opencode", "opencode2"].contains($0.split(separator: "/").last.map(String.init) ?? $0)
            })
        else { return .none }
        var arguments = words[(program + 1)...].makeIterator()
        var session: String?
        var proves = true
        var positionals: [String] = []
        while let word = arguments.next() {
            switch word {
            case "--session", "-s": session = arguments.next() ?? ""
            case "--standalone", "--server", "--continue", "-c": proves = false
            case "--prompt", "--log-level", "--completions": _ = arguments.next()
            default:
                if word.hasPrefix("--session=") {
                    session = String(word.dropFirst("--session=".count))
                } else if word.hasPrefix("--server=") {
                    proves = false
                } else if !word.hasPrefix("-") {
                    positionals.append(word)
                }
            }
        }
        guard proves else { return .none }
        if let session { return session.isEmpty ? .none : .session(session) }
        guard let first = positionals.first else { return .unnamed }
        return first.contains("/") || first == "." || first == "~" ? .unnamed : .none
    }

    /// Whether a session with this origin may be linked by folder alone:
    /// only one the user started at the desk, never one Waycar launched.
    private static func joinsFolderFallback(_ origin: String?, on server: ServerChatBackend) -> Bool {
        switch server {
        // OpenCode: a session without `metadata.waycar` (O9).
        case .codex, .opencode: origin == "user"
        }
    }

    private static func canonicalDirectory(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path == "/private/tmp" || path.hasPrefix("/private/tmp/")
            || path == "/private/var" || path.hasPrefix("/private/var/") {
            path.removeFirst("/private".count)
        }
        return path
    }
}
