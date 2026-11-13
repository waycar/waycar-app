import Foundation

/// Why a request never got a reply from the iPhone.
enum WatchLinkError: Error, Equatable, Sendable {
    case unreachable
    case noAnswer
}

/// The copy for a request the iPhone never answered (design §6.3).
enum WatchLinkCopy {
    static let unreachable = "iPhone not reachable"
    static let noAnswer = "Waycar on iPhone didn't answer — open it"
}

/// Independent, bounded phone requests carried across wrist-down and link
/// flaps. Readiness and request budgets live in pure machines; this owner
/// keeps only link work, timers and continuations. A success from an earlier
/// send remains authoritative until the request has an outcome.
@MainActor
final class WatchRequester {
    typealias Sleep = @MainActor @Sendable (Duration) async throws -> Void

    nonisolated static let deadline: Duration = .seconds(20)
    nonisolated static let debounce: Duration = .milliseconds(300)
    nonisolated static let maxSends = 2

    private let link: any WatchMessageLink
    private let deadline: Duration
    private let debounce: Duration
    private let sleep: Sleep
    private let now: @MainActor () -> ContinuousClock.Instant
    private let isReachableNow: @MainActor () -> Bool
    private var sent = 0
    private var readiness: WatchLinkMachine
    private var settling: Task<Void, Never>?
    private var requests: [Int: WatchRequestEntry] = [:]
    private(set) var droppedReplies = 0

    init(
        link: any WatchMessageLink,
        deadline: Duration = WatchRequester.deadline,
        debounce: Duration = WatchRequester.debounce,
        isActive: Bool = true,
        isReachable: Bool?,
        isReachableNow: @escaping @MainActor () -> Bool,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.link = link
        self.deadline = deadline
        self.debounce = debounce
        self.sleep = sleep
        self.now = now
        self.isReachableNow = isReachableNow
        readiness = WatchLinkMachine(active: isActive, reachable: isReachable)
        if !readiness.isReady { linkChanged(.evaluate(requestActivity)) }
    }

    func setActive(_ active: Bool) {
        guard active != readiness.state.active else { return }
        let live = active && readiness.state.reachable != nil ? isReachableNow() : false
        linkChanged(.active(active, liveReachable: live, requestActivity))
    }

    func setReachable(_ reachable: Bool) {
        linkChanged(.reachable(reachable, requestActivity))
    }

    func send(_ request: WatchRequest) async throws -> WatchReply {
        sent += 1
        let number = sent
        let outcome = await withCheckedContinuation {
            (continuation: CheckedContinuation<Result<WatchReply, any Error>, Never>) in
            let entry = WatchRequestEntry(
                number: number, request: request, budget: deadline, continuation: continuation)
            requests[number] = entry
            if readiness.isReady { transmit(entry) }
            else if readiness.isDown { requestChanged(.unreachable, entry) }
            else { log(entry, "waiting for the iPhone") }
        }
        return try outcome.get()
    }

    private var requestActivity: WatchLinkMachine.Requests {
        .init(inFlight: !inFlight().isEmpty, paused: !paused().isEmpty)
    }

    private func linkChanged(_ event: WatchLinkMachine.Event) {
        for effect in readiness.handle(event) {
            switch effect {
            case .cancelDebounce:
                settling?.cancel()
                settling = nil
            case .armDebounce(let token):
                let sleep = self.sleep
                let debounce = self.debounce
                settling = Task { [weak self] in
                    do { try await sleep(debounce) } catch { return }
                    guard let self, !Task.isCancelled else { return }
                    self.linkChanged(.elapsed(token, liveReachable: self.isReachableNow()))
                }
            case .pause:
                for entry in inFlight() { requestChanged(.pause(now: now()), entry) }
            case .resume:
                for entry in paused() { requestChanged(.resume(now: now()), entry) }
            case .transmitWaiting:
                for entry in waiting() { transmit(entry) }
            case .losePaused:
                for entry in paused() { requestChanged(.lose(now: now()), entry) }
            case .failWaiting:
                for entry in waiting() { requestChanged(.unreachable, entry) }
            }
        }
    }

    private func transmit(_ entry: WatchRequestEntry) {
        requestChanged(.transmit(now: now()), entry)
    }

    /// The machine consumes budget and invalidates work before effects run.
    /// `result` belongs only to the reply/error event being performed.
    private func requestChanged(
        _ event: WatchRequestMachine.Event, _ entry: WatchRequestEntry,
        result: Result<WatchReply, any Error>? = nil
    ) {
        for effect in entry.machine.handle(event) {
            switch effect {
            case .send(let attempt):
                log(entry, attempt == 1 ? "sent" : "resent")
                let link = self.link
                let request = entry.request
                entry.work = Task { [weak self] in
                    let result: Result<WatchReply, any Error>
                    do { result = .success(try await link.send(request)) }
                    catch { result = .failure(error) }
                    self?.linkReturned(entry, attempt: attempt, result)
                }
            case .arm(let token, let budget):
                let sleep = self.sleep
                entry.sentAt = now() // Log stamp only; budget clock is in the event.
                entry.timer = Task { [weak self] in
                    do { try await sleep(budget) } catch { return }
                    guard !Task.isCancelled else { return }
                    self?.requestChanged(.deadline(token), entry)
                }
            case .stopTimer:
                entry.timer?.cancel()
                entry.timer = nil
            case .cancelWork: entry.work?.cancel()
            case .forgetWork: entry.work = nil
            case .complete(let completion):
                switch completion {
                case .reply, .error:
                    if let result { finish(entry, result) }
                case .noAnswer: finish(entry, .failure(WatchLinkError.noAnswer))
                case .unreachable: finish(entry, .failure(WatchLinkError.unreachable))
                }
            case .doubtLink: linkChanged(.linkError(requestActivity))
            }
        }
    }

    private func linkReturned(
        _ entry: WatchRequestEntry, attempt: Int, _ result: Result<WatchReply, any Error>
    ) {
        // Identity protects a completed request even if a link ignores Task cancellation.
        guard requests[entry.number] === entry else {
            switch result {
            case .success(let reply):
                droppedReplies += 1
                log(entry, "answered late with \(reply.logType); dropped")
            case .failure(let error):
                log(entry, "answered late with error \(Self.describe(error)); dropped")
            }
            return
        }
        switch result {
        case .success: requestChanged(.reply, entry, result: result)
        case .failure(let error):
            requestChanged(.error(attempt: attempt, unreachable: error as? WatchLinkError == .unreachable, now: now()),
                           entry, result: result)
        }
    }

    private func finish(_ entry: WatchRequestEntry, _ result: Result<WatchReply, any Error>) {
        guard requests.removeValue(forKey: entry.number) != nil else { return }
        switch result {
        case .success(let reply):
            log(entry, "replied \(reply.logType) in \(WatchLog.milliseconds(since: entry.sentAt)) ms")
        case .failure(let error):
            WatchLog.logger.error(
                "request #\(entry.number, privacy: .public) \(entry.request.logType, privacy: .public) failed: \(Self.describe(error), privacy: .public)")
        }
        let continuation = entry.continuation
        entry.continuation = nil
        continuation?.resume(returning: result)
    }

    private func inFlight() -> [WatchRequestEntry] {
        requests.values.filter { $0.machine.isInFlight }.sorted { $0.number < $1.number }
    }
    private func paused() -> [WatchRequestEntry] {
        inFlight().filter { $0.machine.isPaused }
    }
    private func waiting() -> [WatchRequestEntry] {
        requests.values.filter { !$0.machine.isInFlight }.sorted { $0.number < $1.number }
    }
    private func log(_ entry: WatchRequestEntry, _ text: String) {
        WatchLog.logger.notice(
            "request #\(entry.number, privacy: .public) \(entry.request.logType, privacy: .public) \(text, privacy: .public), message \(entry.request.logMessageID, privacy: .public)")
    }
    private static func describe(_ error: any Error) -> String {
        if let link = error as? WatchLinkError { return "\(link)" }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }
}

/// Resources for one request; its machine owns attempts, budget and timers.
@MainActor
private final class WatchRequestEntry {
    let number: Int
    let request: WatchRequest
    var machine: WatchRequestMachine
    var continuation: CheckedContinuation<Result<WatchReply, any Error>, Never>?
    /// Used only for logging, never for lifecycle decisions.
    var sentAt = ContinuousClock.now
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?

    init(
        number: Int, request: WatchRequest, budget: Duration,
        continuation: CheckedContinuation<Result<WatchReply, any Error>, Never>
    ) {
        self.number = number
        self.request = request
        machine = WatchRequestMachine(budget: budget, maxSends: WatchRequester.maxSends)
        self.continuation = continuation
    }
}
