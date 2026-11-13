import Foundation

/// A Blocked prompt as it was read out (or shown): the guard text the
/// answer must find on screen again, and what it was classified as.
struct BlockedPromptSnapshot: Equatable, Sendable {
    let kind: String
    /// `BlockedPromptAnswerer.screenText(from:)` of the screen read.
    let screen: String
    let prompt: BlockedPrompt

    /// Nil for a blank screen: there is no prompt on display to answer.
    init?(kind: String, fullScreen: String) {
        guard let screen = BlockedPromptAnswerer.screenText(from: fullScreen) else { return nil }
        self.kind = kind
        self.screen = screen
        prompt = BlockedPromptClassifier.classify(kind: kind, screen: fullScreen)
    }

    var approval: CarApproval { BlockedPromptClassifier.carApproval(for: prompt) }
}

/// An Allow or Deny taken while the Host could not be reached, kept to
/// replay once it can (CONTEXT.md **Queued Answer**). It carries the prompt
/// as the user saw it, so the replay sends only while that same prompt is
/// still on screen.
struct PendingBlockedAnswer: Equatable, Sendable {
    /// What the user pressed: "Allow", "Deny" or "Cancel".
    let label: String
    let keys: [String]
    /// The guard text the replay must find on screen again.
    let shown: String
    /// The classified prompt an Allow was verified against, so the replay
    /// also still classifies the same way (the car and Watch rules).
    let snapshot: BlockedPromptSnapshot?
}

/// Answers one Agent's Blocked prompt with keys, only while the prompt that
/// was shown or read aloud is still the one on screen (docs/design/carplay.md
/// §5 rule 2). Chat Mode's Allow/Cancel and the car share this guard.
///
/// The guard re-reads the screen and compares the same normalized last
/// `screenLineLimit` lines, cursor row included, so a cursor move or a second
/// prompt with the same command mismatches. Keys are never retried after a
/// failure: herdr may already have answered the prompt with them
/// (`ConsoleStore.sendKeys`).
///
/// On top of the guard, the car rules (§5 rules 1–7): Allow only for a
/// lossless, risk-free plain-Yes permission; Deny is Esc; a correction after
/// Deny waits for the Agent to leave Blocked before one prompt, else lands in
/// the draft; one car action in flight at a time.
@MainActor
final class BlockedPromptAnswerer {
    enum Outcome: Equatable, Sendable {
        case sent
        /// The screen no longer shows the prompt that was shown: nothing was
        /// sent. `current` is the guard text on screen now; nil when the
        /// read failed or found a blank screen.
        case promptChanged(current: String?)
        /// Sending failed; nothing is retried.
        case sendFailed
        /// The Host could not be reached to read the screen, so nothing was
        /// sent; the answer was handed to `queueAnswer` to replay later.
        case queued
        /// A replay could not reach the Host to read the screen: nothing
        /// was sent, and the answer stays queued.
        case unreachable
        /// The caller no longer wanted the answer once the screen was read
        /// (`stillWanted`): something else settled it.
        case abandoned
        case cancelled
        /// A car action on this Agent is still in flight.
        case busy
        /// The car rules forbid this answer for this prompt.
        case refused
    }

    enum CorrectionOutcome: Equatable, Sendable {
        /// Esc went through and the correction went out in one prompt.
        case prompted
        /// Esc went through but the Agent stayed Blocked (or refused the
        /// prompt as Blocked): the correction is in the draft.
        case drafted
        /// Esc did not go through; nothing was prompted or drafted.
        case denyFailed(Outcome)
        /// The prompt failed in a way that may have delivered it: never
        /// resent, never drafted.
        case promptFailed
    }

    /// The Blocked card and the car compare this many trailing lines.
    nonisolated static let screenLineLimit = 12

    private let readScreen: @MainActor () async throws -> String
    private let sendKeys: @MainActor ([String]) async throws -> Void
    /// Takes an answer the Host could not be reached for; nil never queues.
    private let queueAnswer: (@MainActor (PendingBlockedAnswer) -> Void)?
    /// A car action is between its first read and its last send.
    var isActing: Bool { car.machine.isActing }
    private let car = Execution()

    /// Reference storage avoids holding an inout machine across suspension.
    /// Generic answers/replays deliberately do not share the car's admission.
    private final class Execution {
        var machine = BlockedPromptAnswerMachine()
    }

    init(
        readScreen: @escaping @MainActor () async throws -> String,
        sendKeys: @escaping @MainActor ([String]) async throws -> Void,
        queueAnswer: (@MainActor (PendingBlockedAnswer) -> Void)? = nil
    ) {
        self.readScreen = readScreen
        self.sendKeys = sendKeys
        self.queueAnswer = queueAnswer
    }

    /// The last `screenLineLimit` lines with visible content, each without
    /// trailing whitespace; nil for a blank screen.
    nonisolated static func screenText(from screen: String) -> String? {
        let lines = screen.split(whereSeparator: \.isNewline)
            .map { line in
                var line = line
                while let last = line.last, last.isWhitespace { line.removeLast() }
                return line
            }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.suffix(screenLineLimit).joined(separator: "\n")
    }

    /// Re-reads the screen and sends `keys` only when its guard text equals
    /// `shown`. `stillWanted` runs after the read: false abandons the answer
    /// silently (a status change or a newer read already settled it). With
    /// the Host unreachable the answer is queued instead, when this answerer
    /// queues.
    func answer(
        keys: [String], shown: String, stillWanted: @MainActor () -> Bool = { true }
    ) async -> Outcome {
        await answer(
            PendingBlockedAnswer(
                label: keys == ["esc"] ? "Cancel" : "Allow", keys: keys, shown: shown,
                snapshot: nil),
            stillWanted: stillWanted, mode: .live(queuesOffline: true))
    }

    /// Sends a queued answer now, under the same guard it was taken with.
    /// `.unreachable` says the Host still cannot be reached; `stillWanted`
    /// false after the read (the answer was withdrawn) abandons it.
    /// `willSend` claims the entry only once the screen guard passes,
    /// immediately before the keys go out; false abandons it too.
    func replay(
        _ pending: PendingBlockedAnswer, stillWanted: @MainActor () -> Bool = { true },
        willSend: @MainActor () -> Bool = { true }
    ) async -> Outcome {
        await answer(
            pending, stillWanted: stillWanted, mode: .replay, willSend: willSend)
    }

    // MARK: Car

    /// Enter, only for a prompt the car rules allow, and only while the
    /// screen still shows it and still classifies the same way.
    /// - Parameter queuesOffline: false for a caller that reports a failure
    ///   at once instead (the Watch, whose answer has a deadline).
    func allow(_ snapshot: BlockedPromptSnapshot, queuesOffline: Bool = true) async -> Outcome {
        guard snapshot.approval == .allow else { return .refused }
        return await answer(
            PendingBlockedAnswer(
                label: "Allow", keys: ["enter"], shown: snapshot.screen, snapshot: snapshot),
            stillWanted: { true }, mode: .live(queuesOffline: queuesOffline), execution: car)
    }

    /// Esc through the same guard. Deny is available for any prompt the car
    /// offers buttons for; trust dialogs are never answered (rule 1).
    func deny(_ snapshot: BlockedPromptSnapshot, queuesOffline: Bool = true) async -> Outcome {
        guard snapshot.prompt != .trust else { return .refused }
        return await answer(
            PendingBlockedAnswer(
                label: "Deny", keys: ["esc"], shown: snapshot.screen, snapshot: nil),
            stillWanted: { true }, mode: .live(queuesOffline: queuesOffline), execution: car)
    }

    /// Deny, then the correction as its own prompt (S5): Esc through the
    /// guard, then at most `timeout` for a status other than Blocked —
    /// re-reading the screen once after `screenRecheckDelay` in case the
    /// status lags — then one `prompt`. Never types into a Blocked prompt
    /// (rule 5): on timeout, or when the prompt is refused unsent (Blocked,
    /// a sign-in screen, a folder-trust dialog), the text goes to the draft
    /// instead.
    /// - Parameter statusUpdates: subscribed before the call, so no change
    ///   after the Esc is missed.
    func denyAndInstruct(
        _ snapshot: BlockedPromptSnapshot,
        text: String,
        statusUpdates: AsyncStream<ConsoleStore.AgentStatusUpdate>,
        prompt: @MainActor (String) async throws -> Void,
        draft: @MainActor (String) -> Void,
        timeout: Duration = .seconds(8),
        screenRecheckDelay: Duration = .seconds(1)
    ) async -> CorrectionOutcome {
        guard snapshot.prompt != .trust else { return .denyFailed(.refused) }
        let request = BlockedPromptAnswerMachine.Request(
            pending: PendingBlockedAnswer(
                label: "Deny", keys: ["esc"], shown: snapshot.screen, snapshot: nil),
            mode: .live(queuesOffline: false), kind: .correction(text))
        switch await run(
            request, execution: car,
            waitForUnblock: {
                await self.waitUntilUnblocked(
                    kind: snapshot.kind, statusUpdates: statusUpdates, timeout: timeout,
                    screenRecheckDelay: screenRecheckDelay)
            }, prompt: prompt, draft: draft)
        {
        case .correction(let outcome): return outcome
        case .answer: preconditionFailure("Correction returned an answer outcome")
        }
    }

    // MARK: Guard

    private func answer(
        _ pending: PendingBlockedAnswer, stillWanted: @MainActor () -> Bool,
        mode: BlockedPromptAnswerMachine.Mode,
        willSend: @MainActor () -> Bool = { true }, execution: Execution = Execution()
    ) async -> Outcome {
        let effectiveMode: BlockedPromptAnswerMachine.Mode
        switch mode {
        case .live(let queuesOffline):
            effectiveMode = .live(queuesOffline: queuesOffline && queueAnswer != nil)
        case .replay:
            effectiveMode = .replay
        }
        let request = BlockedPromptAnswerMachine.Request(
            pending: pending, mode: effectiveMode, kind: .answer)
        switch await run(request, execution: execution, stillWanted: stillWanted, willSend: willSend) {
        case .answer(let outcome): return outcome
        case .correction: preconditionFailure("Answer returned a correction outcome")
        }
    }

    private func run(
        _ request: BlockedPromptAnswerMachine.Request, execution: Execution,
        stillWanted: @MainActor () -> Bool = { true },
        willSend: @MainActor () -> Bool = { true },
        waitForUnblock: @MainActor () async -> Bool = { preconditionFailure("Answer requested a correction wait") },
        prompt: @MainActor (String) async throws -> Void = { _ in preconditionFailure("Answer requested a correction prompt") },
        draft: @MainActor (String) -> Void = { _ in preconditionFailure("Answer requested a correction draft") }
    ) async -> BlockedPromptAnswerMachine.Result {
        var effects = execution.machine.handle(.begin(request))
        while !effects.isEmpty {
            let effect = effects.removeFirst()
            switch effect {
            case .read(let token):
                let full: String?
                var unreachable = false
                do {
                    full = try await readScreen()
                } catch {
                    full = nil
                    unreachable = RequestNotSentError.wrapping(error) is RequestNotSentError
                }
                effects += execution.machine.handle(.read(
                    token, full: full, unreachable: unreachable, stillWanted: stillWanted(),
                    cancelled: Task.isCancelled))
            case .claim(let token):
                effects += execution.machine.handle(.claimed(token, willSend()))
            case .sendKeys(let token, let keys):
                let succeeded: Bool
                do {
                    try await sendKeys(keys)
                    succeeded = true
                } catch {
                    succeeded = false
                }
                effects += execution.machine.handle(.keysSent(token, succeeded: succeeded))
            case .queue(let pending):
                queueAnswer?(pending)
            case .waitUnblocked(let token):
                let unblocked = await waitForUnblock()
                effects += execution.machine.handle(.unblocked(token, unblocked))
            case .prompt(let token, let text):
                let result: BlockedPromptAnswerMachine.PromptResult
                do {
                    try await prompt(text)
                    result = .sent
                } catch {
                    result = Self.refusedUnsent(error) ? .refusedUnsent : .failed
                }
                effects += execution.machine.handle(.prompted(token, result))
            case .draft(let token, let text):
                draft(text)
                effects += execution.machine.handle(.drafted(token))
            case .complete(let token, let result):
                _ = execution.machine.handle(.completed(token))
                return result
            case .busy(let result):
                return result
            }
        }
        preconditionFailure("Guarded answer ended without an outcome")
    }

    /// True once a status other than Blocked arrives, or the one screen
    /// re-read shows the Agent working or idle; false after `timeout`.
    private func waitUntilUnblocked(
        kind: String,
        statusUpdates: AsyncStream<ConsoleStore.AgentStatusUpdate>,
        timeout: Duration,
        screenRecheckDelay: Duration
    ) async -> Bool {
        let readScreen = self.readScreen
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await update in statusUpdates {
                    if let status = update.status, Self.isUnblocked(status) { return true }
                }
                // The stream ended (the Agent left the list): wait out the
                // timeout rather than prompt blind.
                try? await Task.sleep(for: timeout)
                return false
            }
            group.addTask {
                do { try await Task.sleep(for: screenRecheckDelay) } catch { return false }
                if await Self.screenShowsUnblocked(kind: kind, readScreen: readScreen) {
                    return true
                }
                try? await Task.sleep(for: timeout)
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// The one re-read: a screen TmuxScreenDetector reads as working or
    /// idle has left the prompt; a failed read says nothing.
    private nonisolated static func screenShowsUnblocked(
        kind: String, readScreen: @escaping @MainActor () async throws -> String
    ) async -> Bool {
        let screen: String
        do {
            screen = try await readScreen()
        } catch {
            return false
        }
        guard let status = TmuxScreenDetector.classify(kind: kind, screen: screen, title: "")
        else { return false }
        return isUnblocked(status)
    }

    /// Working, Idle or Done; Unknown says nothing about the prompt.
    private nonisolated static func isUnblocked(_ status: AgentStatus) -> Bool {
        status == .working || status == .idle || status == .done
    }

    /// herdr's and the tmux transport's refusal of a prompt to a Blocked
    /// Agent, or to one on its sign-in screen or folder-trust dialog:
    /// nothing was typed.
    private static func refusedUnsent(_ error: any Error) -> Bool {
        if error is AgentSignInRequiredError || error is AgentFolderTrustRequiredError {
            return true
        }
        if let apiError = error as? HerdrAPIError { return apiError.code == "agent_blocked" }
        if let transportError = error as? TransportError,
            case .apiRejected(let code, _) = transportError
        {
            return code == "agent_blocked"
        }
        return false
    }
}
