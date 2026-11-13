import Foundation
import Observation

/// Throwaway diagnostic instrument (build 101): records every byte chunk
/// fed into a terminal surface, tagged with surface, transport generation,
/// timestamp, and resize events, so a garbled iPhone render can be replayed
/// and attributed on the Mac. Remove once the render regression is found.
#if DEBUG
final class TerminalStreamCapture: @unchecked Sendable {
    static let shared = TerminalStreamCapture()
    private let lock = NSLock()
    private var handle: FileHandle?
    private var written = 0
    private let cap = 24 * 1024 * 1024
    private static let stamp: String = {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        return f.string(from: Date())
    }()

    private var activeHandle: FileHandle? {
        lock.lock(); defer { lock.unlock() }
        if handle == nil, written < cap, let dir = FileManager
            .default
            .urls(for: .documentDirectory, in: .userDomainMask).first
        {
            let path = dir.appendingPathComponent("stream-\(Self.stamp).bin")
            FileManager.default.createFile(atPath: path.path, contents: nil)
            handle = try? FileHandle(forWritingTo: path)
        }
        return handle
    }

    func record(surfaceID: TerminalSurfaceID, generation: UInt64?, bytes: Data) {
        guard let h = activeHandle else { return }
        let sid = surfaceID.uuidValuePrefix
        let head = Data("[\(Self.stamp)] s=\(sid) g=\(generation.map(String.init) ?? "-") n=\(bytes.count)\n".utf8)
        lock.lock(); defer { lock.unlock() }
        guard written < cap else { return }
        try? h.write(contentsOf: head)
        try? h.write(contentsOf: bytes)
        written += head.count + bytes.count
    }

    func recordEvent(surfaceID: TerminalSurfaceID, kind: String) {
        guard let h = activeHandle else { return }
        let head = Data("[\(Self.stamp)] s=\(surfaceID.uuidValuePrefix) EVENT=\(kind)\n".utf8)
        lock.lock(); defer { lock.unlock() }
        try? h.write(contentsOf: head)
    }
}

extension TerminalSurfaceID {
    var uuidValuePrefix: String {
        String(value.uuidString.suffix(8))
    }
}
#endif
typealias TerminalSessionOperation =
    @MainActor @Sendable (TerminalAttachSession) async throws -> Void
typealias TerminalSessionRunner =
    @Sendable (TerminalAttachRequest, TerminalSessionHandler) async throws -> Void

/// How the attach channel was carried. Surfaces in the terminal chrome so
/// the user can see whether a session is riding mosh UDP or plain SSH.
enum TerminalSessionFlavor: String, Sendable {
    case mosh
    case ssh
}

/// Why mosh is set aside for a Host's current connection.
enum MoshInvalidationCause: Sendable, Equatable {
    /// A mosh session failed and the terminal fell back to SSH by itself.
    case automaticFallback
    /// The user chose SSH in the connection dot's popover ("Use SSH Instead"):
    /// a choice no network change undoes (#105).
    case userChoseSSH
}

/// Sets mosh aside for the terminal's Host, wired from the Console.
typealias MoshInvalidation = @MainActor @Sendable (MoshInvalidationCause) async -> Void

struct TerminalSessionHandler: Sendable {
    private let operation: TerminalSessionOperation
    private let transportReady: @MainActor @Sendable (UInt64, TerminalSessionFlavor) -> Void
    private let transportAcquired: @MainActor @Sendable (UInt64) -> Void
    private let routeResolved: @MainActor @Sendable (TerminalAttachRoute) -> Void
    #if DEBUG
    private let traceEvents: AttachRestorationTraceEvents?
    #endif


    init(
        transportReady: @escaping @MainActor @Sendable (UInt64, TerminalSessionFlavor) -> Void = { _, _ in },
        transportAcquired: @escaping @MainActor @Sendable (UInt64) -> Void = { _ in },
        routeResolved: @escaping @MainActor @Sendable (TerminalAttachRoute) -> Void = { _ in },
        _ operation: @escaping TerminalSessionOperation
    ) {
        self.transportReady = transportReady
        self.transportAcquired = transportAcquired
        self.routeResolved = routeResolved
        self.operation = operation
        #if DEBUG
        traceEvents = nil
        #endif
    }

    #if DEBUG
    init(
        transportReady: @escaping @MainActor @Sendable (UInt64, TerminalSessionFlavor) -> Void = { _, _ in },
        transportAcquired: @escaping @MainActor @Sendable (UInt64) -> Void = { _ in },
        routeResolved: @escaping @MainActor @Sendable (TerminalAttachRoute) -> Void = { _ in },
        traceEvents: AttachRestorationTraceEvents,
        _ operation: @escaping TerminalSessionOperation
    ) {
        self.transportReady = transportReady
        self.transportAcquired = transportAcquired
        self.routeResolved = routeResolved
        self.traceEvents = traceEvents
        self.operation = operation
    }
    #endif

    @MainActor
    func transportDidBecomeReady(_ generation: UInt64, flavor: TerminalSessionFlavor = .ssh) {
        transportReady(generation, flavor)
    }

    /// The connection generation this run rides, as soon as the runner
    /// holds it and before the session on it is up (#105): a mosh bootstrap
    /// can outlast the new connection's own proving, and its run must not
    /// then read as one left on an older connection.
    @MainActor
    func transportDidBecomeAcquired(_ generation: UInt64) {
        transportAcquired(generation)
    }

    /// How the attach reaches its terminal (#105), for its telemetry.
    @MainActor
    func attachRouteDidResolve(_ route: TerminalAttachRoute) {
        routeResolved(route)
    }

    #if DEBUG
    @MainActor
    func attachRequestDidStart() {
        traceEvents?.attachRequestDidStart()
    }

    @MainActor
    func attachChannelDidOpen() {
        traceEvents?.attachChannelDidOpen()
    }
    #endif

    @MainActor
    func run(_ session: TerminalAttachSession) async throws {
        try await operation(session)
    }

    /// One complete session lifetime with owned teardown: runs the handler,
    /// then ends the channel — on success and on every failure except a
    /// `terminalChannelAlreadyOpen` refusal. That refusal means this
    /// consumer never owned the session: another consumer holds the output,
    /// the transport has already refused only this reader, and `end()` here
    /// would reach through the shared channel and tear down the legitimate
    /// consumer's live terminal (#151). The refusal itself still propagates,
    /// so the offending surface shows it rather than swallowing it (#141).
    func runEndingSession(_ session: TerminalAttachSession) async throws {
        do {
            try await run(session)
        } catch TransportError.terminalChannelAlreadyOpen {
            throw TransportError.terminalChannelAlreadyOpen
        } catch {
            await session.end()
            throw error
        }
        await session.end()
    }
}

/// The identity of one terminal pipeline, and so of the SwiftUI surface built
/// on top of it.
///
/// Deliberately not `ObjectIdentifier(store)`. That is the store's *address*,
/// and the allocator hands a freed address straight back to the next
/// allocation of the same shape — 200 stores built and dropped in a row
/// produced two distinct `ObjectIdentifier`s between them. SwiftUI compares
/// against the identity it recorded at its *last render*, not against the
/// store that is currently live, so a store landing on an address any earlier
/// generation held presents an identity SwiftUI has already seen; it sees
/// nothing change, keeps the surface it already built, and never calls
/// `makeUIView` again. That call is the only place a feed acquires a sink, so
/// the replacement's bytes buffer forever behind a stale screen while the
/// session reads as live (#143).
struct TerminalSurfaceID: Hashable, Sendable {
    private let value = UUID()

    init() {}
}

/// Reconciles the two independently scheduled signals that identify a
/// foreground recovery's Transport. Readiness is projected before terminal
/// waiters resume, so either signal may arrive first. A decision is made only
/// after both belong to the same terminal pipeline.
struct TerminalRecoveryGenerationLatch {
    typealias Decision = TerminalRecoveryGenerationMachine.Decision

    private var machine = TerminalRecoveryGenerationMachine()

    var isActive: Bool { machine.isActive }

    mutating func begin(projectedGeneration: UInt64?) {
        _ = machine.handle(.begin(projected: projectedGeneration))
    }

    mutating func bind(to pipelineID: TerminalSurfaceID) {
        _ = machine.handle(.bind(pipelineID))
    }

    mutating func recordProjection(_ generation: UInt64) -> Decision? {
        decision(for: .project(generation))
    }

    mutating func recordAcquisition(
        _ generation: UInt64,
        by pipelineID: TerminalSurfaceID
    ) -> Decision? {
        decision(for: .acquire(generation, by: pipelineID))
    }

    mutating func clear(boundTo pipelineID: TerminalSurfaceID) {
        _ = machine.handle(.clearBound(pipelineID))
    }

    mutating func clear() {
        _ = machine.handle(.clear)
    }

    private mutating func decision(for event: TerminalRecoveryGenerationMachine.Event) -> Decision? {
        for case .decide(let decision) in machine.handle(event) {
            return decision
        }
        return nil
    }
}

/// The Agent detail screen's session pipeline: a full interactive terminal
/// over the Host's terminal channel — raw PTY bytes into the view through a
/// `TerminalByteFeed`, keystrokes back out, geometry changes as SSH
/// window-change on the live channel.
///
/// Nothing starts until the terminal view's first size report (the PTY opens
/// with real cols/rows). A later resize never
/// restarts anything: it rides in-band, which is the whole point of the PTY.
/// One session per run; the remote attach exiting (the user detached inside
/// the TUI, the pane closed) surfaces as `.ended` with reattach offered.
@MainActor
@Observable
final class AttachTerminalStore {
    enum Status: Equatable {
        /// Waiting for the terminal view's first layout to report cols/rows.
        case waitingForSize
        /// Opening the attach channel, and waiting for the remote attach to
        /// say something. Nothing is on the terminal yet.
        case connecting
        /// The new PTY Attach has produced output and owns the current input writer.
        case live
        /// The session ended remotely (clean detach or channel death); the
        /// message is user-facing and `retry()` reattaches.
        case ended(String)
        /// `stop()` was called; terminal.
        case stopped
    }

    private(set) var status: Status = .waitingForSize
    /// The byte pipe the terminal view consumes.
    let feed = TerminalByteFeed()
    /// What the screen identifies this pipeline's surface by. Owned by the
    /// store and unique for its lifetime, so a replacement is always a
    /// different surface to SwiftUI.
    let surfaceID = TerminalSurfaceID()

    private let target: TerminalAttachTarget
    private let takeover: Bool
    private let input: TerminalInputController
    private let observeOutput: @MainActor @Sendable (Data) -> Void
    private let finishOutput: @MainActor @Sendable () -> Void
    private let transportReady: @MainActor @Sendable (TerminalSurfaceID, UInt64, TerminalSessionFlavor) -> Void
    private let runDidFinish: @MainActor @Sendable (TerminalSurfaceID) -> Void
    /// Opens and owns exclusive Host terminal access for one complete run,
    /// including explicit channel teardown.
    private let runTerminal: TerminalSessionRunner

    private var cols: Int?
    private var rows: Int?
    private(set) var transportGeneration: UInt64?
    /// How the most recent attach session was carried (mosh UDP or SSH PTY).
    /// The source of truth for the mosh upgrade path: the host-level
    /// capsule upgrades only sessions still riding SSH.
    private(set) var lastSessionFlavor: TerminalSessionFlavor = .ssh
    /// The Transport generation this pipeline's run acquired from its
    /// runner; nil from each start until the runner reports one. Unlike
    /// `transportGeneration`, this is never seeded from a projection value.
    private(set) var acquiredTransportGeneration: UInt64?
    private var stopRequested = false
    private var preservesPendingPasteOnStop = false
    private var session: TerminalAttachSession?
    private var inputGeneration: TerminalInputController.SessionGeneration?
    private var runTask: Task<Void, Never>?
    /// Set once an automatic mosh→SSH fallback has run for this store.
    /// Never reset by the fallback's own restart, so a failed invalidation
    /// cannot loop mosh against the same dead handshake.
    private var moshAutoFallbackUsed = false
    /// Set once a transient failure has reattached this store silently;
    /// cleared when a session goes live again, so each ended episode gets
    /// one retry before `.ended` shows. A user `retry()` leaves it alone.
    private var transientRetryUsed = false
    /// Whether this pipeline has ever gone live: its surface holds content
    /// to read, and keeps it through a later `.ended`.
    private(set) var hasBeenLive = false
    /// True only while the current `.ended` status was produced by
    /// ``TransportError/moshSessionFailed(detail:)`` — the connection dot's
    /// popover uses it to offer "Use SSH Instead".
    private(set) var endedWithMoshFailure = false
    private let onMoshFailure: MoshInvalidation?
    /// How the running attach is carried, from its runner's transport-ready
    /// report until the next start; nil before that report. Unlike
    /// `lastSessionFlavor` it never stands for an earlier run.
    private(set) var runningFlavor: TerminalSessionFlavor?
    /// A live mosh session whose server has gone quiet past MoshCore's
    /// stall threshold (#105): the screen is the last frame the Host sent,
    /// not necessarily its current one.
    private(set) var isStalled = false
    private var connectivityTask: Task<Void, Never>?
    /// How long a mosh session's first bytes may stay blank before the
    /// terminal goes live anyway (#105).
    private let blankFrameGrace: Duration
    /// Set once a lost mosh link has reattached this store automatically;
    /// cleared when a session goes live again, so each live stretch gets one.
    private var linkLossReattachUsed = false
    /// The attach attempts and mosh losses the network telemetry counts.
    private let telemetry: TerminalAttachTelemetry?
    #if DEBUG
    private(set) var restorationTrace = AttachRestorationTrace()

    func adoptRestorationTrace(_ trace: AttachRestorationTrace) {
        restorationTrace = trace
    }
    #endif

    init(
        target: TerminalAttachTarget, takeover: Bool = false,
        recordsNetworkTelemetry: Bool = true,
        input: TerminalInputController = TerminalInputController(),
        transportGeneration: UInt64? = nil,
        observeOutput: @escaping @MainActor @Sendable (Data) -> Void = { _ in },
        finishOutput: @escaping @MainActor @Sendable () -> Void = {},
        transportReady: @escaping @MainActor @Sendable (TerminalSurfaceID, UInt64, TerminalSessionFlavor) -> Void = {
            _, _, _ in
        },
        runDidFinish: @escaping @MainActor @Sendable (TerminalSurfaceID) -> Void = { _ in },
        onMoshFailure: MoshInvalidation? = nil,
        blankFrameGrace: Duration = .milliseconds(400),
        runTerminal: @escaping TerminalSessionRunner
    ) {
        telemetry = recordsNetworkTelemetry ? TerminalAttachTelemetry() : nil
        self.target = target
        self.takeover = takeover
        self.input = input
        self.transportGeneration = transportGeneration
        self.observeOutput = observeOutput
        self.finishOutput = finishOutput
        self.transportReady = transportReady
        self.runDidFinish = runDidFinish
        self.onMoshFailure = onMoshFailure
        self.blankFrameGrace = blankFrameGrace
        self.runTerminal = runTerminal
    }

    convenience init(
        target: String, takeover: Bool = false,
        input: TerminalInputController = TerminalInputController(),
        transportGeneration: UInt64? = nil,
        observeOutput: @escaping @MainActor @Sendable (Data) -> Void = { _ in },
        finishOutput: @escaping @MainActor @Sendable () -> Void = {},
        transportReady: @escaping @MainActor @Sendable (TerminalSurfaceID, UInt64, TerminalSessionFlavor) -> Void = {
            _, _, _ in
        },
        runDidFinish: @escaping @MainActor @Sendable (TerminalSurfaceID) -> Void = { _ in },
        onMoshFailure: MoshInvalidation? = nil,
        runTerminal: @escaping TerminalSessionRunner
    ) {
        self.init(
            target: .agentPane(target),
            takeover: takeover,
            input: input,
            transportGeneration: transportGeneration,
            observeOutput: observeOutput,
            finishOutput: finishOutput,
            transportReady: transportReady,
            runDidFinish: runDidFinish,
            onMoshFailure: onMoshFailure,
            runTerminal: runTerminal)
    }

    /// The terminal view's geometry, reported on first layout and on every
    /// change (rotation, split view, keyboard). The first report opens the
    /// session; later changes ride the live channel as window-change.
    func viewDidResize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, cols != self.cols || rows != self.rows else { return }
        #if DEBUG
        TerminalStreamCapture.shared.recordEvent(surfaceID: surfaceID, kind: "resize \(self.cols)x\(self.rows)->\(cols)x\(rows)")
        #endif
        self.cols = cols
        self.rows = rows
        if runTask == nil {
            if status == .waitingForSize {
                #if DEBUG
                restorationTrace.emit(.initialResize, generation: transportGeneration)
                #endif
                start()
            }
            // .ended waits for retry(); .stopped is terminal.
        } else {
            session?.resize(cols: cols, rows: rows)
        }
    }

    /// Opens the session before any view has laid out (#105), on the grid
    /// size the screen last had in this layout: the attach starts at
    /// intent instead of after the surface's first layout. The view's own
    /// report then rides `viewDidResize` as a resize when it differs. Only
    /// a pipeline still waiting for its size starts.
    func start(assumingCols cols: Int, rows: Int) {
        guard cols > 0, rows > 0, status == .waitingForSize, runTask == nil else { return }
        self.cols = cols
        self.rows = rows
        #if DEBUG
        restorationTrace.emit(.initialResize, generation: transportGeneration)
        #endif
        start()
    }

    /// The grid size this pipeline runs at, once one is known.
    var gridSize: (cols: Int, rows: Int)? {
        guard let cols, let rows else { return nil }
        return (cols, rows)
    }

    /// A run carried by mosh whose session is still up (or still coming
    /// up): its UDP flow does not ride the Host's SSH connection, so a new
    /// connection generation leaves it running (#105).
    var isRunningMosh: Bool {
        guard runTask != nil, runningFlavor == .mosh, !stopRequested else { return false }
        return status == .live || status == .connecting
    }

    /// A run under way that holds no connection yet — its runner reported
    /// none and no session is up: whichever connection it gets is the
    /// Host's newest, so a new connection generation does not leave it
    /// behind (#105).
    var isAwaitingTransport: Bool {
        runTask != nil && !stopRequested && acquiredTransportGeneration == nil && session == nil
    }

    /// Whether the running mosh session hears from its server within
    /// `timeout` (`TerminalSessionLink.awaitServerContact`); false with no
    /// mosh session.
    func awaitServerContact(within timeout: Duration) async -> Bool {
        guard let link = session?.link else { return false }
        return await link.awaitServerContact(within: timeout)
    }

    /// Keystrokes from the terminal view, forwarded raw. Dropped while no
    /// session is live — there is nothing to type into yet.
    func send(_ keystrokes: Data) {
        input.send(keystrokes)
    }

    /// The app returned to the foreground.
    ///
    /// A short bounce asks the remote TUI to repaint without replacing the
    /// current session. Extended absences are recovered at the owner boundary
    /// instead, because this store cannot observe presentation and must not
    /// treat a byte handed to a sink object as proof that a frame was drawn.
    /// A mosh session also redraws the terminal at once from its last known
    /// screen, healing any cell left stale while the app was away.
    func didBecomeActive() {
        guard status == .live, let session, let cols, let rows, cols > 1 else { return }
        if let link = session.link {
            Task { await link.repaint(cols: cols, rows: rows) }
        }
        // A window-change only reaches the remote when the size actually
        // changes, so the nudge is a shrink followed by a restore. Both ride
        // the reliable input queue, in order, on the live channel; the
        // store's own geometry is untouched, so a later real resize still
        // compares against what the view last reported.
        session.resize(cols: cols - 1, rows: rows)
        session.resize(cols: cols, rows: rows)
    }

    /// Reattaches after the session ended remotely.
    func retry() {
        guard case .ended = status, runTask == nil else { return }
        // A user-driven reattach is a fresh consent to the mosh path: the
        // Host may have been fixed since the last handshake failed.
        moshAutoFallbackUsed = false
        start()
    }

    /// The connection dot popover's "Use SSH Instead": invalidates mosh for
    /// the Host (so the runner picks SSH), then reattaches. The automatic
    /// fallback budget stays spent — if mosh were somehow chosen again and
    /// failed, the overlay would come back rather than loop.
    func retryOverSSH() {
        guard case .ended = status else { return }
        moshAutoFallbackUsed = true
        let current = runTask
        Task { @MainActor [weak self] in
            guard let self else { return }
            await current?.value
            guard !self.stopRequested else { return }
            await self.onMoshFailure?(.userChoseSSH)
            self.start()
        }
    }

    /// True while a mosh-upgrade restart is scheduled for the live
    /// session. A second request must not schedule a second restart, and
    /// the dying run must not overwrite the Connecting status the
    /// scheduled restart already installed.
    private var moshUpgradeRestartScheduled = false

    /// Whether `upgradeToMosh()` would restart this pipeline: a live
    /// session, or one still connecting over SSH — the probe proving mosh
    /// can land while a cold-restored attach opens its PTY (#105).
    var canUpgradeToMosh: Bool {
        guard runTask != nil, !stopRequested, !moshUpgradeRestartScheduled else { return false }
        switch status {
        case .live: return true
        case .connecting: return runningFlavor == .ssh
        case .waitingForSize, .ended, .stopped: return false
        }
    }

    /// The host-level mosh capsule's upgrade: the Host's probe proved
    /// mosh available, so the SSH session is ended and the pipeline
    /// reattaches — the runner re-selects mosh for the fresh attach. A
    /// session still opening is cancelled instead. Same spawned-restart
    /// shape as the automatic mosh-failure fallback: the restart is
    /// scheduled off this run task (a synchronous `start()` would be
    /// cleared by `run()`'s own `runTask = nil` teardown), one restart is
    /// ever in flight, and a session that stopped meanwhile stays stopped.
    func upgradeToMosh() {
        guard canUpgradeToMosh else { return }
        moshUpgradeRestartScheduled = true
        // Fresh consent to the mosh path, like a user-driven retry: the
        // upgrade is deliberate, so a spent automatic fallback must not
        // pin the reattach to SSH.
        moshAutoFallbackUsed = false
        status = .connecting
        let session = self.session
        let current = runTask
        if session == nil { current?.cancel() }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await session?.end()
            await current?.value
            guard !self.stopRequested else { return }
            self.moshUpgradeRestartScheduled = false
            self.start()
        }
    }

    /// Ends the session by explicit close (only `end()` runs the channel's
    /// teardown; abandoning the session does not) and waits for the teardown.
    /// Terminal: the detail screen creates a fresh store after a Host
    /// reconnect.
    ///
    /// `abandoning` is for a session whose server is presumed gone (a
    /// recovery replacing it, #105): mosh stops at once instead of waiting
    /// for a shutdown acknowledgement that will not come. User closes and
    /// suspension teardown end cleanly, so mosh-server exits promptly (#19).
    ///
    /// The run task is also cancelled: before a session exists it can be
    /// queued for the Host's terminal channel, and teardown must abort that
    /// wait rather than sit behind whoever holds the channel — a stop must
    /// never depend on the channel becoming available.
    func stop(preservingPendingPaste: Bool = false, abandoning: Bool = false) async {
        stopRequested = true
        telemetry?.stopped()
        preservesPendingPasteOnStop = preservingPendingPaste
        if let session {
            if abandoning {
                await session.abandon()
            } else {
                await session.end()
            }
        }
        if let task = runTask {
            task.cancel()
            await task.value
        }
        status = .stopped
    }

    private func start() {
        status = .connecting
        telemetry?.began()
        endedWithMoshFailure = false
        runningFlavor = nil
        acquiredTransportGeneration = nil
        runTask = Task { await self.run() }
    }

    /// One session lifetime: open at the current geometry, pump output until
    /// the stream ends, surface how it ended.
    private func run() async {
        defer {
            runTask = nil
            runDidFinish(surfaceID)
        }
        guard let cols, let rows else { return }
        let request = TerminalAttachRequest(
            target: target, takeover: takeover, cols: cols, rows: rows)
        let operation: TerminalSessionOperation = { [weak self] session in
            guard let self else {
                await session.end()
                return
            }
            try await self.consume(session, initialCols: cols, initialRows: rows)
        }
        let transportReady: @MainActor @Sendable (UInt64, TerminalSessionFlavor) -> Void = { [weak self] generation, flavor in
            guard let self else { return }
            self.transportGeneration = generation
            self.acquiredTransportGeneration = generation
            self.lastSessionFlavor = flavor
            self.runningFlavor = flavor
            self.transportReady(self.surfaceID, generation, flavor)
            self.telemetry?.transportReady(flavor)
            #if DEBUG
            self.restorationTrace.emit(.transportAcquired, generation: generation)
            #endif
        }
        let transportAcquired: @MainActor @Sendable (UInt64) -> Void = { [weak self] generation in
            guard let self else { return }
            self.transportGeneration = generation
            self.acquiredTransportGeneration = generation
        }
        let routeResolved: @MainActor @Sendable (TerminalAttachRoute) -> Void = { [weak self] route in
            self?.telemetry?.routeResolved(route)
        }
        #if DEBUG
        let handler = TerminalSessionHandler(
            transportReady: transportReady,
            transportAcquired: transportAcquired,
            routeResolved: routeResolved,
            traceEvents: AttachRestorationTraceEvents(
                trace: restorationTrace,
                generation: { [weak self] in self?.acquiredTransportGeneration }),
            operation)
        #else
        let handler = TerminalSessionHandler(
            transportReady: transportReady, transportAcquired: transportAcquired,
            routeResolved: routeResolved, operation)
        #endif
        do {
            try await runTerminal(request, handler)
        } catch {
            guard !stopRequested, !moshUpgradeRestartScheduled else { return }
            if error is MoshLinkLost, !linkLossReattachUsed {
                // The Host stopped answering a mosh session that had been
                // live (#105): the link went, not mosh. Reattach once the
                // ordinary way — mosh stays chosen — instead of falling back
                // to SSH. Scheduled off this run task like the fallback.
                linkLossReattachUsed = true
                telemetry?.runEnded(error, restarting: true)
                status = .connecting
                let current = runTask
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await current?.value
                    guard !self.stopRequested else { return }
                    self.start()
                }
                return
            }
            if case TransportError.moshSessionFailed = error {
                endedWithMoshFailure = true
                // The mosh attempt died after the banner: invalidate mosh
                // for the Host and restart once, so SSH takes over without
                // user action. The fallback restart is scheduled off this
                // run task — `start()` synchronously would be cleared by
                // this function's `runTask = nil` defer.
                if !moshAutoFallbackUsed, onMoshFailure != nil {
                    moshAutoFallbackUsed = true
                    telemetry?.runEnded(error, restarting: true)
                    status = .connecting
                    let current = runTask
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await current?.value
                        guard !self.stopRequested else { return }
                        await self.onMoshFailure?(.automaticFallback)
                        self.start()
                    }
                    return
                }
            }
            if Self.isTransient(error), !transientRetryUsed {
                // The channel died under a session the Host never refused
                // (a connection invalidated mid-attach): reattach once
                // before telling the user. Scheduled off this run task like
                // the fallbacks above, and dropped if the screen stops.
                transientRetryUsed = true
                telemetry?.runEnded(error, restarting: true)
                status = .connecting
                let current = runTask
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await current?.value
                    guard !self.stopRequested else { return }
                    self.start()
                }
                return
            }
            telemetry?.runEnded(error, restarting: false)
            status = .ended(Self.message(for: error))
            return
        }
        guard !stopRequested, !moshUpgradeRestartScheduled else { return }
        telemetry?.runEnded(nil, restarting: false)
        status = .ended("The session ended.")
    }

    private func consume(
        _ session: TerminalAttachSession,
        initialCols: Int,
        initialRows: Int
    ) async throws {
        defer { finishOutput() }
        if stopRequested {
            await session.end()
            return
        }
        self.session = session
        let inputGeneration = input.beginSession(
            writer: { data in session.send(data) },
            scroller: { sequence, rows in
                session.scroll(sequence, rows: rows)
            })
        self.inputGeneration = inputGeneration
        if let latestCols = cols, let latestRows = rows,
            latestCols != initialCols || latestRows != initialRows
        {
            // The view resized while the channel was coming up; catch the
            // remote PTY up to the latest geometry.
            session.resize(cols: latestCols, rows: latestRows)
        }
        if let link = session.link {
            connectivityTask = Task { [weak self] in
                for await connectivity in link.connectivity() {
                    guard let self, self.session === session else { return }
                    self.isStalled = connectivity == .stalled
                }
            }
        }
        // mosh-server paints its own blank screen before the Agent's arrives
        // (#105): a mosh session stays connecting — the last frame or the
        // spinner up — until its output draws something, or for
        // `blankFrameGrace` after its first bytes for a screen that is
        // genuinely blank.
        let waitsForContent = runningFlavor == .mosh
        var content = TerminalVisibleContentScanner()
        var blankFrameTimer: Task<Void, Never>?
        defer { blankFrameTimer?.cancel() }

        do {
            for try await bytes in session.output {
                // Live when the new PTY Attach produces output, not when the
                // channel opens: the transport withholds the login shell's
                // noise, so an open channel with no output yet is still
                // connecting. This does not prove that a renderer presented
                // the bytes on screen.
                if status == .connecting {
                    if !waitsForContent || content.containsVisibleContent(bytes) {
                        goLive()
                    } else if blankFrameTimer == nil {
                        let grace = blankFrameGrace
                        blankFrameTimer = Task { [weak self] in
                            do { try await Task.sleep(for: grace) } catch { return }
                            guard let self, self.session === session,
                                self.status == .connecting
                            else { return }
                            self.goLive()
                        }
                    }
                }
                #if DEBUG
                restorationTrace.emit(.firstOutputBytes, generation: acquiredTransportGeneration)
                TerminalStreamCapture.shared.record(
                    surfaceID: surfaceID, generation: acquiredTransportGeneration, bytes: bytes)
                #endif
                observeOutput(bytes)
                feed.write(bytes)
            }
        } catch {
            finishSession(inputGeneration)
            throw error
        }
        #if DEBUG
        TerminalStreamCapture.shared.recordEvent(surfaceID: surfaceID, kind: "stream-end")
        #endif
        finishSession(inputGeneration)
    }

    private func goLive() {
        status = .live
        hasBeenLive = true
        telemetry?.wentLive()
        linkLossReattachUsed = false
        transientRetryUsed = false
    }

    private func finishSession(_ inputGeneration: TerminalInputController.SessionGeneration) {
        self.session = nil
        connectivityTask?.cancel()
        connectivityTask = nil
        isStalled = false
        input.endSession(
            inputGeneration,
            preservingPendingPaste: preservesPendingPasteOnStop)
        if self.inputGeneration == inputGeneration {
            self.inputGeneration = nil
        }
    }

    /// Failures worth one silent retry: the attach channel's own I/O died
    /// (its output or input). Anything the Host or the user decided
    /// (credentials, host key, the remote command's own exit status, a clean
    /// exit, the mosh handshake, which has its own fallback) and any other
    /// `channelFailed` (a mosh bootstrap, tmux) is shown at once.
    private static func isTransient(_ error: any Error) -> Bool {
        guard case TransportError.channelFailed(let detail) = error else { return false }
        if detail.hasPrefix(HostSSHSession.attachRemoteExitDetailPrefix) { return false }
        return detail.hasPrefix(HostSSHSession.attachChannelDetailPrefix)
            || detail.hasPrefix(HostSSHSession.attachInputDetailPrefix)
    }

    static func message(for error: any Error) -> String {
        switch error {
        case TransportError.sshUnreachable:
            "The Host is not connected."
        case TransportError.terminalChannelAlreadyOpen:
            "Another terminal is already open on this Host."
        case TransportError.timedOut:
            "The Host did not answer in time."
        case TransportError.moshSessionFailed(let detail):
            "The mosh session failed: \(detail)"
        case let lost as MoshLinkLost:
            MoshAttachSession.timeoutDetail(lost.timeoutMs)
        case TransportError.herdrBinaryNotFound:
            TransportError.herdrBinaryNotFound.presentation.message
        default:
            "The session failed: \(error)"
        }
    }
}
