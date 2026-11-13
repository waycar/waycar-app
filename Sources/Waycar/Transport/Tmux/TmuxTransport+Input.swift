import Foundation

extension TmuxTransport {
    // MARK: Input

    /// One control line: the draft into a fresh named buffer, any pane mode
    /// left, a bracketed paste that deletes the buffer, then Enter (T15,
    /// ``runPasting(text:pane:then:over:)``); an empty draft is Enter
    /// alone. A kind whose TUI drops an Enter that arrives with the paste
    /// (gemini, hermes, cline: `AgentScreen.InputReadiness.submitDelay`) gets a
    /// raw CR (`send-keys -H 0d`) on a second line after that delay
    /// (``readBeforeEnter(_:kind:in:over:)``): the bytes a terminal's Enter
    /// sends, which tmux's `Enter` key name may encode otherwise under
    /// `extended-keys`. Never retried (ADR 0018). A
    /// Blocked Agent is refused with herdr's `agent_blocked`: Enter would
    /// answer its question or dialog. An Agent on its sign-in screen is
    /// refused with `AgentSignInRequiredError`: the text and Enter would
    /// drive the login. An Agent of a kind whose folder-trust dialog its
    /// hooks report as idle (`AgentScreen.InputReadiness.hasTrustDialog`)
    /// is refused with `AgentFolderTrustRequiredError` while the dialog
    /// shows, before the launch gate, which would only hold it. A link
    /// failure before the line is queued for
    /// writing (the launch check, getting the control channel) fails
    /// `RequestNotSentError`. Prompts to one pane go one at a time, each
    /// through its Enter (``takePromptTurn(_:)``): a second paste inside a
    /// delayed Enter's gap would land in the first draft and go with it.
    /// `TmuxPromptDeliveryMachine` says who hands the turn on.
    func promptAgent(_ params: AgentPromptParams) async throws -> Agent {
        let pane = try Self.rawPane(params.target)
        let turn: UUID
        do {
            turn = try await takePromptTurn(pane)
        } catch {
            throw RequestNotSentError.wrapping(error)
        }
        var delivery = TmuxPromptDeliveryMachine()
        let kind = agent(forPane: pane).kind
        let readiness = AgentScreen.readiness(kind: kind)
        let entersAfterGap = TmuxPromptDeliveryMachine.entersAfterGap(
            hasDraft: !params.text.isEmpty, submitDelay: readiness.submitDelay)
        let control: TmuxControlChannel?
        do {
            do {
                // `kind` is the Agent the last snapshot detected in the pane,
                // else a launch's not yet detected (its gate's kind): a gate
                // that outlived its Agent never names the one running now.
                // A sign-in screen is a refusal, not a start still underway:
                // checked before the launch gate, which would only hold it.
                try await refuseInputScreen(pane, kind: kind)
                try await checkLaunchReadiness(pane)
                guard reportedStatus(ofPane: pane) != .blocked else {
                    throw HerdrAPIError(
                        code: "agent_blocked", message: "the agent in \(TmuxID.app(pane)) is blocked")
                }
                control = params.text.isEmpty
                    ? nil : try await requireControl(missing: "pane_not_found")
            } catch {
                throw RequestNotSentError.wrapping(error)
            }
            let enter: [String] =
                entersAfterGap ? [] : [TmuxCommand.sendKeys(target: pane, keys: ["Enter"])]
            try await runPasting(text: params.text, pane: pane, then: enter, over: control)
        } catch {
            _ = try? performDelivery(delivery.handle(.failed), turn: turn, pane: pane)
            throw error
        }
        guard try performDelivery(
            delivery.handle(.typed(entersAfterGap: entersAfterGap)), turn: turn, pane: pane),
            let control
        else { return agent(forPane: pane) }
        // The paste is in: the Enter goes whatever happens to the caller, so
        // it runs where the caller's cancellation never reaches, still waits
        // out the kind's gap, and holds the turn until it is done.
        let handed = delivery
        let submit = Task {
            var delayedEnter = handed
            do {
                try? await Task.sleep(for: readiness.submitDelay)
                let read = try await self.readBeforeEnter(
                    params.text, kind: kind, in: pane, over: control)
                guard
                    try self.performDelivery(
                        delayedEnter.handle(.read(read)), turn: turn, pane: pane)
                else { return }
                _ = try await self.send(
                    control,
                    Self.inputLine([TmuxCommand.sendKeysHex(target: pane, bytes: [0x0D])], pane: pane))
                try self.performDelivery(delayedEnter.handle(.entered), turn: turn, pane: pane)
            } catch {
                _ = try? self.performDelivery(delayedEnter.handle(.failed), turn: turn, pane: pane)
                throw error
            }
        }
        try await submit.value
        return agent(forPane: pane)
    }

    /// Performs a delivery's effects for the prompt `turn` names on `pane`:
    /// hands the turn on, or fails `prompt_not_submitted`. True when the
    /// delivery goes on (`awaitEnter`, `sendEnter`).
    @discardableResult
    private func performDelivery(
        _ effects: [TmuxPromptDeliveryMachine.Effect], turn: UUID, pane: String
    ) throws -> Bool {
        var proceeds = false
        for effect in effects {
            switch effect {
            case .awaitEnter, .sendEnter:
                proceeds = true
            case .releaseTurn:
                releasePromptTurn(turn, of: pane)
            case .refuseUnsubmitted:
                throw HerdrAPIError(
                    code: "prompt_not_submitted",
                    message: "the agent in \(TmuxID.app(pane)) no longer shows the prompt in its "
                        + "input, so the prompt is typed there but not submitted")
            }
        }
        return proceeds
    }

    /// Returns once no earlier prompt to `pane` is still delivering. A
    /// cancelled wait gives its place up and throws: nothing was sent.
    private func takePromptTurn(_ pane: String) async throws -> UUID {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    promptTurnWaiters[id] = continuation
                    performPromptTurns(promptTurns.handle(.request(id, pane: pane)))
                }
            }
        } onCancel: {
            Task { await self.withdrawPromptTurn(id, of: pane) }
        }
        return id
    }

    private func withdrawPromptTurn(_ id: UUID, of pane: String) {
        performPromptTurns(promptTurns.handle(.withdraw(id, pane: pane)))
    }

    /// Hands `pane`'s turn to the next prompt waiting, if any.
    private func releasePromptTurn(_ id: UUID, of pane: String) {
        performPromptTurns(promptTurns.handle(.release(id, pane: pane)))
    }

    private func performPromptTurns(_ effects: [TmuxPromptTurnMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .grant(let id):
                promptTurnWaiters.removeValue(forKey: id)?.resume()
            case .cancel(let id):
                promptTurnWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    /// The one read before a delayed Enter's CR, after the gap: the pane's
    /// `@waycar_status`, visible screen and title on one line, with the
    /// status last reported and the kind's screen rules
    /// (`TmuxScreenDetector.classify`). The CR (a raw `0d` on a line of its
    /// own, any pane mode left first) goes only while none reads Blocked
    /// and the screen still shows the draft in the Agent's input with no
    /// approval dialog (`AgentScreen.draftAwaitsEnter`). A dialog that
    /// opened during the gap would take the CR as its answer (a tool
    /// approval's highlighted option, cline's question), and a hook's
    /// `blocked` can land after it. A skipped CR leaves the draft typed in
    /// the Agent's input, unsubmitted, and fails `prompt_not_submitted`,
    /// not `agent_blocked`: a sender requeues on that and would type the
    /// draft twice.
    private func readBeforeEnter(
        _ draft: String, kind: String, in pane: String, over control: TmuxControlChannel
    ) async throws -> TmuxPromptDeliveryMachine.EnterRead {
        let replies = try await send(
            control,
            [
                TmuxCommand.display(format: "#{@waycar_status}", target: pane),
                TmuxCommand.capturePane(target: pane, lines: 0),
                TmuxCommand.display(format: "#{pane_title}", target: pane),
            ])
        let screen = replies[1].lines.joined(separator: "\n")
        let title = replies[2].lines.joined(separator: " ")
        return TmuxPromptDeliveryMachine.EnterRead(
            hookStatus: TmuxAgentDetection.waycarStatus(replies[0].lines.first ?? ""),
            reportedStatus: reportedStatus(ofPane: pane),
            screenStatus: TmuxScreenDetector.classify(kind: kind, screen: screen, title: title),
            draftAwaitsEnter: AgentScreen.draftAwaitsEnter(kind: kind, draft: draft, screen: screen))
    }

    /// Key names checked against `TmuxKeys` before anything is sent; any
    /// pane mode is left first, on the same line
    /// (``inputLine(_:pane:)``).
    func sendAgentKeys(_ params: AgentSendKeysParams) async throws {
        let pane = try Self.rawPane(params.target)
        let commands = try TmuxKeys.commands(target: pane, keys: params.keys)
        guard !commands.isEmpty else { return }
        _ = try await run(Self.inputLine(commands, pane: pane))
    }

    /// Text as a paste (submitted only when `keys` carries Enter), then the
    /// keys, on one line.
    func sendPaneInput(_ params: PaneSendInputParams) async throws {
        let pane = try Self.rawPane(params.paneID)
        let keys = try TmuxKeys.commands(target: pane, keys: params.keys ?? [])
        try await runPasting(text: params.text ?? "", pane: pane, then: keys)
    }

    // MARK: Pane history

    /// `#{alternate_on}`, `#{pane_mode}` as ``TmuxInventory/fields(_:)``.
    static var paneHistoryFormat: String {
        TmuxInventory.fields(["alternate_on", "pane_mode"])
    }

    /// One read of where the pane's view is, then, for `rows` > 0, one line
    /// that scrolls it and reads it again: `copy-mode -e` first when the
    /// pane is not in copy mode yet, `send-keys -X -N <rows> scroll-up` or
    /// `scroll-down`, then `#{pane_in_mode}` (`-e` leaves copy mode at the
    /// bottom). Copy mode has nothing to show over an alternate screen, and
    /// another mode (a desk client's `choose-tree`, say) is not this one's
    /// to scroll: both are `unavailable`. Live already, newer is a no-op.
    /// Nothing is remembered here: input leaves any mode on its own line
    /// (``inputLine(_:pane:)``), whoever entered it. The answer says
    /// whether this call's `copy-mode -e` entered copy mode, as opposed to
    /// scrolling one already there.
    func scrollPaneHistory(
        paneID: String, towardOlderContent: Bool, rows: Int
    ) async throws -> PaneHistoryScroll {
        let pane = try Self.rawPane(paneID)
        let target = TmuxCommand.target(pane)
        let state = try await run([TmuxCommand.display(format: Self.paneHistoryFormat, target: pane)])
        let fields = TmuxInventory.split(
            state[0].lines.first ?? "", at: TmuxInventory.fieldSeparator, maxSplits: 1)
        guard fields.count == 2 else {
            throw TransportError.malformedResponse("tmux pane history: \(fields)")
        }
        let inCopyMode = fields[1] == "copy-mode"
        guard inCopyMode || fields[1].isEmpty else { return PaneHistoryScroll(position: .unavailable) }
        guard rows > 0, inCopyMode || towardOlderContent else {
            if inCopyMode { return PaneHistoryScroll(position: .inHistory) }
            return PaneHistoryScroll(position: fields[0] == "1" ? .unavailable : .live)
        }
        guard inCopyMode || fields[0] != "1" else { return PaneHistoryScroll(position: .unavailable) }
        let scroll = towardOlderContent ? "scroll-up" : "scroll-down"
        let replies = try await run(
            (inCopyMode ? [] : ["copy-mode -e -t \(target)"]) + [
                "send-keys -X -N \(rows) -t \(target) \(scroll)",
                TmuxCommand.display(format: "#{pane_in_mode}", target: pane),
            ])
        let inHistory = replies.last?.lines.first == "1"
        return PaneHistoryScroll(
            position: inHistory ? .inHistory : .live, enteredHistory: inHistory && !inCopyMode)
    }

    /// `copy-mode -q`, which ends any mode and is a no-op out of one (tmux
    /// 3.2a, 3.4, live).
    func leavePaneHistory(paneID: String) async throws {
        try await run([Self.leaveCopyModeCommand(try Self.rawPane(paneID))])
    }

    static func leaveCopyModeCommand(_ pane: String) -> String {
        "copy-mode -q -t \(TmuxCommand.target(pane))"
    }

    /// `input` (paste and keys) behind `copy-mode -q` on the same line. tmux
    /// hands keys sent to a pane in a mode to that mode, which consumes them
    /// (copy mode's Enter copies and leaves; `choose-tree`'s Enter switches
    /// the desk client), and pastes into it unbracketed. The pane may be in
    /// one whoever entered it: another device's scroll, a transport since
    /// replaced, a desk client. Out of a mode the leave is a no-op that
    /// sends no notification (tmux 3.4 and 3.8, live 2026-10-12).
    static func inputLine(_ input: [String], pane: String) -> [String] {
        [leaveCopyModeCommand(pane)] + input
    }

    /// `set-buffer` + `paste-buffer -p -d` under a fresh `waycar-<uuid>`
    /// buffer, then `commands`, on one control line behind any pane mode's
    /// leave (``inputLine(_:pane:)``); no paste for empty text (tmux stores
    /// no empty buffer). `-d` deletes the buffer only
    /// after a paste, so a line that fails is followed by a best-effort
    /// `delete-buffer` on the same channel, detached so the error (or the
    /// cancellation) returns at once. A channel that has ended takes none:
    /// the cleanup never connects. The line itself is never retried.
    /// `control` is the channel a caller already took, if any.
    private func runPasting(
        text: String, pane: String, then commands: [String],
        over control: TmuxControlChannel? = nil
    ) async throws {
        guard !text.isEmpty else {
            if !commands.isEmpty { _ = try await run(Self.inputLine(commands, pane: pane)) }
            return
        }
        let channel: TmuxControlChannel
        if let control {
            channel = control
        } else {
            channel = try await requireControl(missing: "pane_not_found")
        }
        let buffer = "waycar-" + UUID().uuidString.lowercased()
        do {
            _ = try await send(
                channel,
                [TmuxCommand.setBuffer(name: buffer, text: text)]
                    + Self.inputLine(
                        [TmuxCommand.pasteBuffer(name: buffer, target: pane)] + commands, pane: pane))
        } catch {
            let delete = Self.deleteBufferCommand(buffer)
            // Unstructured, so a cancelled send still clears the buffer.
            Task { _ = try? await channel.send([delete]) }
            throw error
        }
    }

    static func deleteBufferCommand(_ name: String) -> String {
        "delete-buffer -b \(TmuxCommand.word(name))"
    }

    /// `#{pane_id}`, `#{pane_dead}`, `#{pane_pid}`, `#{pane_tty}`,
    /// `#{pane_current_command}`, `#{@waycar_agent}`, `#{@waycar_session}`,
    /// `#{@waycar_status}`, `#{alternate_on}` as
    /// ``TmuxInventory/fields(_:)``, so an option holding a separator cannot
    /// shift a field.
    static var readinessFormat: String {
        TmuxInventory.fields([
            "pane_id", "pane_dead", "pane_pid", "pane_tty", "pane_current_command",
            "@waycar_agent", "@waycar_session", "@waycar_status", "alternate_on",
        ])
    }

    /// Throws `agent_not_ready` while a launch gate holds; panes this
    /// transport did not launch are always ready. A claude gate past
    /// `claudeLaunchReadyTimeout` holds only while the screen shows a
    /// dialog (folder trust): Enter would accept it; so does any other kind
    /// with screen rules once its delay is out. A gate on an input
    /// marker past `inputReadyTimeout` opens unread
    /// (``TmuxLaunchGateMachine``).
    func checkLaunchReadiness(_ pane: String) async throws {
        let timing = TmuxLaunchGateMachine.Timing(
            launchReadyDelay: configuration.launchReadyDelay,
            claudeLaunchReadyTimeout: configuration.claudeLaunchReadyTimeout,
            inputReadyTimeout: configuration.inputReadyTimeout)
        var effects = launchGates.handle(.check(pane: pane, now: .now, timing: timing))
        while let effect = effects.first {
            switch effect {
            case .admit:
                return
            case .hold(let gate):
                throw Self.agentNotReady(gate, pane: pane)
            case .readPane(let check):
                let facts = try await readinessFacts(pane)
                effects = launchGates.handle(.paneRead(check, facts, now: .now))
            case .readMarker(let check, let marker):
                let onScreen = try await inputIsOnScreen(pane, marker: marker)
                effects = launchGates.handle(.markerRead(check, onScreen: onScreen))
            case .readDialog(let check):
                let blocked = try await screenStatus(ofPane: pane, kind: check.gate.kind) == .blocked
                effects = launchGates.handle(.dialogRead(check, blocked: blocked))
            }
        }
    }

    /// One read of the pane's ``readinessFormat``, its foreground kind
    /// resolved over `ps` when the command does not tell (never for a dead
    /// pane).
    private func readinessFacts(_ pane: String) async throws -> TmuxLaunchGateMachine.PaneFacts {
        let replies = try await run([TmuxCommand.display(format: Self.readinessFormat, target: pane)])
        let fields = TmuxInventory.split(
            replies[0].lines.first ?? "", at: TmuxInventory.fieldSeparator, maxSplits: 8)
        guard fields.count == 9, TmuxInventory.isID(fields[0], prefix: "%") else {
            throw TransportError.malformedResponse("tmux pane readiness: \(fields)")
        }
        let record = TmuxPaneRecord(
            id: pane, sessionID: "", windowID: "", dead: fields[1] == "1", pid: Int(fields[2]),
            tty: fields[3], currentCommand: fields[4], waycarStatus: fields[7],
            waycarAgent: fields[5], waycarSession: fields[6])
        guard !record.dead else {
            return TmuxLaunchGateMachine.PaneFacts(
                dead: true, agentDetected: false, hookSessionSet: false, hookStatusSet: false,
                alternateScreen: false)
        }
        var resolved: String?
        if TmuxAgentDetection.needsForegroundResolution(record) {
            resolved = await resolveForeground([record])[pane]?.kind
        }
        return TmuxLaunchGateMachine.PaneFacts(
            dead: false,
            agentDetected: TmuxAgentDetection.kind(for: record, resolvedKind: resolved) != nil,
            hookSessionSet: !record.waycarSession.isEmpty,
            hookStatusSet: TmuxAgentDetection.waycarStatus(record.waycarStatus) != nil,
            alternateScreen: fields[8] == "1")
    }

    private static func agentNotReady(_ gate: TmuxLaunchGate, pane: String) -> HerdrAPIError {
        HerdrAPIError(
            code: "agent_not_ready",
            message: "the \(gate.kind) agent in \(TmuxID.app(pane)) is still starting")
    }

    /// One read of the pane's visible screen for `marker`
    /// (`AgentScreen.inputIsOnScreen`).
    private func inputIsOnScreen(_ pane: String, marker: AgentScreen.InputMarker) async throws
        -> Bool
    {
        let replies = try await run([TmuxCommand.capturePane(target: pane, lines: 0)])
        return AgentScreen.inputIsOnScreen(marker, screen: replies[0].lines.joined(separator: "\n"))
    }

    /// The screen check `promptAgent` runs first, for the Agent the last
    /// snapshot detected in `target`.
    func checkAgentInputScreen(target: String) async throws {
        let pane = try Self.rawPane(target)
        try await refuseInputScreen(pane, kind: agent(forPane: pane).kind)
    }

    /// Fails `AgentSignInRequiredError` while `pane` shows `kind`'s sign-in
    /// screen, `AgentFolderTrustRequiredError` while it shows its
    /// folder-trust dialog; reads nothing for a kind with neither.
    private func refuseInputScreen(_ pane: String, kind: String) async throws {
        let readiness = AgentScreen.readiness(kind: kind)
        if readiness.hasSignInScreen, try await signInIsOnScreen(pane, kind: kind) {
            throw AgentSignInRequiredError(kind: kind, target: TmuxID.app(pane))
        }
        if readiness.hasTrustDialog, try await trustDialogIsOnScreen(pane, kind: kind) {
            throw AgentFolderTrustRequiredError(kind: kind, target: TmuxID.app(pane))
        }
    }

    /// One read of the pane's visible screen for its sign-in screen
    /// (`AgentScreen.signInRequired`).
    private func signInIsOnScreen(_ pane: String, kind: String) async throws -> Bool {
        let replies = try await run([TmuxCommand.capturePane(target: pane, lines: 0)])
        return AgentScreen.signInRequired(
            kind: kind, screen: replies[0].lines.joined(separator: "\n"))
    }

    /// One read of the pane's visible screen for its folder-trust dialog
    /// (`AgentScreen.trustDialogShown`).
    private func trustDialogIsOnScreen(_ pane: String, kind: String) async throws -> Bool {
        let replies = try await run([TmuxCommand.capturePane(target: pane, lines: 0)])
        return AgentScreen.trustDialogShown(
            kind: kind, screen: replies[0].lines.joined(separator: "\n"))
    }

    /// One screen read of the pane, classified as the screen watch does.
    private func screenStatus(ofPane pane: String, kind: String) async throws -> AgentStatus? {
        let replies = try await run([
            TmuxCommand.capturePane(target: pane, lines: TmuxScreenDetector.historyLines),
            TmuxCommand.display(format: "#{pane_title}", target: pane),
        ])
        return TmuxScreenDetector.classify(
            kind: kind, screen: replies[0].lines.joined(separator: "\n"),
            title: replies[1].lines.joined(separator: " "))
    }

    /// The pane's Agent Status as last reported: for a kind with screen
    /// rules the screen's verdict in force, else the hook's or a plugin's
    /// status (``screenWatchPanes()``); for any other kind the latest
    /// `wc-status` push, else the last snapshot. Nil when the last snapshot
    /// shows no Agent there.
    func reportedStatus(ofPane pane: String) -> AgentStatus? {
        if let watched = screenWatchPanes().first(where: { $0.id == pane }) {
            return screenWatch.screenStatus(
                paneID: pane, hookStatus: watched.hookStatus, hookSeq: watched.hookSeq,
                kind: watched.kind, session: watched.session)
                ?? watched.baseStatus
        }
        guard let info = lastSnapshot?.agents.first(where: { $0.paneID == TmuxID.app(pane) })
        else { return nil }
        if let value = subscriptionBaseline.value(of: TmuxEvents.statusName),
            let statusAt = TmuxEvents.statusFields.firstIndex(of: "@waycar_status"),
            let row = TmuxEvents.rows(value, fieldCount: TmuxEvents.statusFields.count)
                .first(where: { $0[0] == pane }),
            let pushed = TmuxAgentDetection.waycarStatus(row[statusAt])
        {
            return pushed
        }
        return info.agentStatus
    }

    // MARK: Reading

    /// Lines of history a `recent` read takes when the request names none.
    static let defaultReadLines = 200

    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult {
        try await capture(paneID: params.paneID, source: params.source, lines: params.lines)
    }

    func readAgent(_ params: AgentReadParams) async throws -> PaneReadResult {
        try await capture(paneID: params.target, source: params.source, lines: params.lines)
    }

    /// `capture-pane -p -J`: the visible screen for `visible`, else that plus
    /// up to `lines` of history, trailing blank rows dropped and the last
    /// `lines` kept. An alternate-screen app gives only its screen, as on
    /// herdr. Always plain text.
    private func capture(paneID appID: String, source: ReadSource, lines: Int?) async throws
        -> PaneReadResult
    {
        let pane = try Self.rawPane(appID)
        let history = source == .visible ? 0 : max(0, lines ?? Self.defaultReadLines)
        let replies = try await run([TmuxCommand.capturePane(target: pane, lines: history)])
        var captured = replies[0].lines
        while let last = captured.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            captured.removeLast()
        }
        var truncated = false
        if let lines, lines >= 0, captured.count > lines {
            captured = Array(captured.suffix(lines))
            truncated = true
        }
        let location = records.pane(pane)
        return PaneReadResult(
            format: .text, paneID: TmuxID.app(pane), revision: 0, source: source,
            tabID: location.map { TmuxID.app($0.windowID) } ?? "",
            text: captured.joined(separator: "\n"), truncated: truncated,
            workspaceID: location.map { TmuxID.app($0.sessionID) } ?? "")
    }

    // MARK: Management

    /// tmux has no worktree groups, so `closesWorktreeGroup` changes nothing.
    func closePane(_ params: PaneTarget, closesWorktreeGroup: Bool) async throws {
        try await run([TmuxCommand.killPane(target: try Self.rawPane(params.paneID))])
    }

    /// An emptied session closes itself (T23).
    func closeTab(_ params: TabTarget) async throws {
        try await run(
            [TmuxCommand.killWindow(target: try Self.rawWindow(params.tabID))],
            missing: "tab_not_found")
    }

    /// The Agent's name is its window's name; nil hands the name back to
    /// tmux's automatic rename.
    func renameAgent(_ params: AgentRenameParams) async throws {
        let pane = try Self.rawPane(params.target)
        let window = try await paneLocation(pane).windowID
        let command =
            params.name.map { TmuxCommand.renameWindow(target: window, name: $0) }
            ?? "set-option -w -t \(TmuxCommand.target(window)) automatic-rename on"
        try await run([command])
    }

    func renameWorkspace(_ params: WorkspaceRenameParams) async throws {
        try await run(
            [TmuxCommand.renameSession(
                target: try Self.rawSession(params.workspaceID), name: params.label)],
            missing: "workspace_not_found")
    }

    func renameShellTab(tabID: String, label: String) async throws {
        try await run(
            [TmuxCommand.renameWindow(target: try Self.rawWindow(tabID), name: label)],
            missing: "tab_not_found")
    }

    /// herdr's "seen": a `done` pane becomes `idle`. Read first so a pane
    /// without `@waycar_status` keeps it unset (the plugin's hook tells unset
    /// from empty); the write itself re-checks `done` on the server.
    func focusAgent(_ target: AgentTarget) async throws {
        let pane = try Self.rawPane(target.target)
        let replies = try await run([TmuxCommand.display(format: "#{@waycar_status}", target: pane)])
        guard replies.first?.lines.first?.trimmingCharacters(in: .whitespaces) == "done" else {
            return
        }
        try await run([TmuxCommand.focusDoneToIdle(paneTarget: pane)])
    }
}
