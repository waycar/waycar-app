import Foundation

extension TmuxTransport {
    // MARK: Moving panes

    /// `pane.move` (design §3): `break-pane` into a new window for a new Tab,
    /// the same into a fresh session for a new Workspace, `join-pane` into an
    /// existing Tab. tmux keeps a pane's id wherever it goes, so the reply
    /// names the pane the request did. Every move runs `-d`; `focus` then
    /// selects the pane's window and the pane. A window the move empties
    /// closes by itself, and a session left without windows with it; a
    /// single-pane window breaks out whole, keeping its id (verified on
    /// 3.7c). The reply's other fields come from a fresh snapshot.
    func movePane(_ params: PaneMoveParams) async throws -> PaneMoveResponse {
        let pane = try Self.rawPane(params.paneID)
        let before = try await sessionSnapshot()
        guard let source = before.panes.first(where: { $0.paneID == params.paneID }) else {
            throw HerdrAPIError(code: "pane_not_found", message: "no pane \(params.paneID)")
        }
        let sourcePaneCount = before.tabs.first { $0.tabID == source.tabID }?.paneCount ?? 1
        let focus = params.focus == true ? Self.focusCommands(pane: pane) : []
        switch params.destination {
        case .tab(let target):
            guard before.tabs.contains(where: { $0.tabID == target.tabID }) else {
                throw HerdrAPIError(code: "tab_not_found", message: "no tab \(target.tabID)")
            }
            var joinTarget = try Self.rawWindow(target.tabID)
            if let targetPaneID = target.targetPaneID {
                guard
                    before.panes.contains(where: {
                        $0.paneID == targetPaneID && $0.tabID == target.tabID
                    })
                else {
                    throw HerdrAPIError(
                        code: "invalid_target", message: "split target pane is not in the layout")
                }
                joinTarget = try Self.rawPane(targetPaneID)
            }
            let join = try Self.joinPaneCommand(
                pane: pane, target: joinTarget, split: target.split, ratio: target.ratio)
            guard target.tabID != source.tabID else { return try await unchangedMove(source) }
            try await runMove(
                [join] + focus, pane: pane, landed: { $0.tabID == target.tabID },
                leftovers: { _ in focus })
        case .newTab(let target):
            let sessionID = try Self.rawSession(target.workspaceID ?? source.workspaceID)
            guard before.workspaces.contains(where: { $0.workspaceID == TmuxID.app(sessionID) })
            else {
                throw HerdrAPIError(
                    code: "workspace_not_found", message: "no workspace \(TmuxID.app(sessionID))")
            }
            // Already alone in a window of that session: nothing to break out.
            if TmuxID.app(sessionID) == source.workspaceID, sourcePaneCount == 1 {
                return try await unchangedMove(source)
            }
            let workspaceID = TmuxID.app(sessionID)
            try await runMove(
                [Self.breakPaneCommand(
                    pane: pane, sessionTarget: sessionID, name: target.label.flatMap(Self.nonEmpty))]
                    + focus,
                pane: pane, missing: "workspace_not_found",
                landed: { moved in
                    // A lone pane's window moves whole and keeps its id.
                    moved.workspaceID == workspaceID
                        && (moved.tabID != source.tabID || moved.workspaceID != source.workspaceID)
                },
                leftovers: { _ in focus })
        case .newWorkspace(let target):
            let directory = try await moveDirectory(source)
            let placeholder = try await newSession(
                label: target.label, directory: directory, command: nil)
            let dropPlaceholder = TmuxCommand.killWindow(target: placeholder.windowID)
            do {
                // tmux stops a command list at its first error, which would
                // leave the placeholder session behind.
                try await runMove(
                    [
                        Self.breakPaneCommand(
                            pane: pane, sessionTarget: placeholder.sessionID,
                            name: target.tabLabel.flatMap(Self.nonEmpty)),
                        dropPlaceholder,
                    ] + focus,
                    pane: pane,
                    landed: { $0.workspaceID == TmuxID.app(placeholder.sessionID) },
                    leftovers: { snapshot in
                        let kept = snapshot.tabs.contains {
                            $0.tabID == TmuxID.app(placeholder.windowID)
                        }
                        return (kept ? [dropPlaceholder] : []) + focus
                    })
            } catch {
                // The placeholder window, never its session: a line whose
                // replies were lost may have moved the pane in already (and
                // killed the window itself). Without the move that window is
                // the session's only one, so the session goes with it.
                _ = try? await run([dropPlaceholder])
                throw error
            }
        }
        return try await movedReply(params, source: source)
    }

    /// A move's control line. When tmux's `%exit` left it unanswered (below
    /// 3.6 the control client's anchor session dies with its last pane,
    /// which this move or another of a bulk Move can take away, T24), it is
    /// no plain replay: break-pane and join-pane move the pane again. tmux
    /// keeps pane ids, so a snapshot from the replacement client on the same
    /// server shows whether the line ran: a pane that `landed` did move, and
    /// only `leftovers`, the idempotent rest of the line, go out; otherwise
    /// the line goes out again, the exited client running nothing further,
    /// and is checked the same way should the replacement's anchor die too.
    private func runMove(
        _ line: [String], pane: String, missing code: String = "pane_not_found",
        landed: (PaneInfo) -> Bool, leftovers: (SessionSnapshot) -> [String]
    ) async throws {
        guard var channel = try await activeControl(recheckIdle: true) else {
            throw HerdrAPIError(code: code, message: "tmux has no sessions")
        }
        let server = serverIdentity
        while true {
            do {
                _ = try await send(channel, line)
                return
            } catch {
                guard await Self.exitLeftUnanswered(error, on: channel) else { throw error }
                let snapshot = try await sessionSnapshot()
                guard serverIdentity == server else { throw error }
                if let moved = snapshot.panes.first(where: { $0.paneID == TmuxID.app(pane) }),
                    landed(moved)
                {
                    let rest = leftovers(snapshot)
                    if !rest.isEmpty { try await run(rest, missing: code) }
                    return
                }
                guard let next = try await activeControl(recheckIdle: true) else {
                    throw HerdrAPIError(code: code, message: "tmux has no sessions")
                }
                guard serverIdentity == server else { throw error }
                channel = next
            }
        }
    }

    /// The reply from a snapshot taken after the move, plus the geometry of
    /// the pane's new window and of the window it left when that remains.
    private func movedReply(
        _ params: PaneMoveParams, source: PaneInfo
    ) async throws -> PaneMoveResponse {
        let after = try await sessionSnapshot()
        guard let moved = after.panes.first(where: { $0.paneID == params.paneID }) else {
            throw TransportError.malformedResponse(
                "tmux no longer lists \(params.paneID) after moving it")
        }
        var windows = [(tabID: moved.tabID, workspaceID: moved.workspaceID)]
        let sourceRemains = after.tabs.first { $0.tabID == source.tabID }
        if let sourceRemains, sourceRemains.tabID != moved.tabID {
            windows.append((tabID: sourceRemains.tabID, workspaceID: sourceRemains.workspaceID))
        }
        let sourceWorkspaceRemains = after.workspaces.contains {
            $0.workspaceID == source.workspaceID
        }
        let layouts = try await paneLayouts(windows)
        let createdTab: TabInfo?
        let createdWorkspace: WorkspaceInfo?
        switch params.destination {
        case .tab:
            createdTab = nil
            createdWorkspace = nil
        case .newTab:
            createdTab = after.tabs.first { $0.tabID == moved.tabID }
            createdWorkspace = nil
        case .newWorkspace:
            createdTab = after.tabs.first { $0.tabID == moved.tabID }
            createdWorkspace = after.workspaces.first { $0.workspaceID == moved.workspaceID }
        }
        let targetLayout = layouts[0]
        return PaneMoveResponse(
            moveResult: PaneMoveResult(
                changed: moved.tabID != source.tabID || moved.workspaceID != source.workspaceID,
                focusedPaneID: targetLayout.focusedPaneID, pane: moved,
                previousPaneID: source.paneID, previousTabID: source.tabID,
                previousWorkspaceID: source.workspaceID, targetLayout: targetLayout,
                closedTabID: sourceRemains == nil ? source.tabID : nil,
                closedWorkspaceID: sourceWorkspaceRemains ? nil : source.workspaceID,
                createdTab: createdTab, createdWorkspace: createdWorkspace,
                sourceLayout: layouts.count > 1 ? layouts[1] : nil))
    }

    /// herdr's no-op answer for a move to where the pane already is.
    private func unchangedMove(_ source: PaneInfo) async throws -> PaneMoveResponse {
        let layout = try await paneLayouts(
            [(tabID: source.tabID, workspaceID: source.workspaceID)])[0]
        return PaneMoveResponse(
            moveResult: PaneMoveResult(
                changed: false, focusedPaneID: layout.focusedPaneID, pane: source,
                previousPaneID: source.paneID, previousTabID: source.tabID,
                previousWorkspaceID: source.workspaceID, targetLayout: layout,
                reason: .sameTab))
    }

    /// The new Workspace's directory: the pane's, else the Host's home.
    private func moveDirectory(_ source: PaneInfo) async throws -> String {
        if let cwd = source.cwd, !cwd.isEmpty { return cwd }
        return try await remoteHomeDirectory()
    }

    // MARK: Layout geometry

    static var windowGeometryFormat: String {
        TmuxInventory.fields(["window_width", "window_height", "window_zoomed_flag"])
    }

    static var paneGeometryFormat: String {
        TmuxInventory.fields([
            "pane_id", "pane_left", "pane_top", "pane_width", "pane_height", "pane_active",
        ])
    }

    /// Each window's size, zoom and pane rectangles, all on one control line.
    private func paneLayouts(
        _ windows: [(tabID: String, workspaceID: String)]
    ) async throws -> [PaneLayoutSnapshot] {
        let raw = try windows.map { try Self.rawWindow($0.tabID) }
        let replies = try await run(
            raw.flatMap { Self.layoutCommands(window: $0) }, missing: "tab_not_found")
        return try windows.enumerated().map { offset, window in
            try Self.paneLayout(
                window: replies[2 * offset], panes: replies[2 * offset + 1],
                tabID: window.tabID, workspaceID: window.workspaceID)
        }
    }

    /// `display -p -t @W '<size, zoom>'` and `list-panes -t @W -F '<rects>'`.
    static func layoutCommands(window: String) -> [String] {
        [
            TmuxCommand.display(format: windowGeometryFormat, target: window),
            "list-panes -t \(TmuxCommand.target(window)) -F \(TmuxCommand.argument(paneGeometryFormat))",
        ]
    }

    /// herdr's layout snapshot from the two geometry replies. tmux's layout
    /// tree is n-ary and has no split ids, so `splits` stays empty; the
    /// pane rectangles carry the arrangement.
    static func paneLayout(
        window: TmuxReply, panes: TmuxReply, tabID: String, workspaceID: String
    ) throws -> PaneLayoutSnapshot {
        let size = fields(window.lines.first ?? "")
        guard size.count == 3, let width = Int(size[0]), let height = Int(size[1]) else {
            throw TransportError.malformedResponse("tmux window geometry: \(size)")
        }
        var focusedPaneID = ""
        let rects = try panes.lines.filter { !$0.isEmpty }.map { line in
            let row = fields(line)
            guard row.count == 6, row[0].first == "%", let x = Int(row[1]), let y = Int(row[2]),
                let paneWidth = Int(row[3]), let paneHeight = Int(row[4])
            else {
                throw TransportError.malformedResponse("tmux pane geometry: \(row)")
            }
            let focused = row[5] == "1"
            if focused { focusedPaneID = TmuxID.app(row[0]) }
            return PaneLayoutPane(
                focused: focused, paneID: TmuxID.app(row[0]),
                rect: PaneLayoutRect(height: paneHeight, width: paneWidth, x: x, y: y))
        }
        return PaneLayoutSnapshot(
            area: PaneLayoutRect(height: height, width: width, x: 0, y: 0),
            focusedPaneID: focusedPaneID, panes: rects, splits: [], tabID: tabID,
            workspaceID: workspaceID, zoomed: size[2] == "1")
    }

    private static func fields(_ line: String) -> [String] {
        TmuxInventory.split(line, at: TmuxInventory.fieldSeparator)
    }

    // MARK: tmux commands

    /// `break-pane -d -s %P -t '$S:' [-n '<name>']`: the pane into a new
    /// window at the end of the session. `-n` is not format-expanded
    /// (verified on 3.7c), so the name is quoted as plain text.
    static func breakPaneCommand(pane: String, sessionTarget: String, name: String?) -> String {
        var words = [
            "break-pane -d -s", TmuxCommand.target(pane), "-t",
            TmuxCommand.target(sessionTarget + ":"),
        ]
        if let name { words += ["-n", TmuxCommand.argument(name)] }
        return words.joined(separator: " ")
    }

    /// `join-pane -d -h|-v [-l N%] -s %P -t <%Q|@W>`: `right` splits side
    /// by side, `down` stacks. herdr's `ratio` is the first child's share,
    /// the pane split; the moved pane is the second, so it gets the rest.
    static func joinPaneCommand(
        pane: String, target: String, split: SplitDirection, ratio: Double?
    ) throws -> String {
        let orientation: String
        switch split {
        case .right: orientation = "-h"
        case .down: orientation = "-v"
        default:
            throw HerdrAPIError(
                code: "invalid_params", message: "unknown split direction: \(split.rawValue)")
        }
        var words = ["join-pane -d", orientation]
        if let ratio {
            guard ratio.isFinite else {
                throw HerdrAPIError(code: "invalid_ratio", message: "split ratio must be finite")
            }
            let percent = min(99, max(1, Int(((1 - ratio) * 100).rounded())))
            words += ["-l", "\(percent)%"]
        }
        words += ["-s", TmuxCommand.target(pane), "-t", TmuxCommand.target(target)]
        return words.joined(separator: " ")
    }

    /// The pane's window made its session's current one, and the pane its
    /// window's active pane (a pane id names its window for `select-window`).
    static func focusCommands(pane: String) -> [String] {
        [TmuxCommand.selectWindow(target: pane), "select-pane -t \(TmuxCommand.target(pane))"]
    }
}
