import Foundation

enum SSHConnectionTeardownStep: Sendable, Equatable {
    case targetSession
    case forwardingChannel
    case jumpSession
}

/// Its `deinit`, like those of `SSHPTYChannel`, `SSHExecStreamChannel`,
/// `SSHStreamLocalChannel`, `SSHSFTPClient` and `SSHSFTPFile`, hands remote
/// cleanup to an unstructured `Task` that nothing retains: `deinit` returns
/// with that work still outstanding, and no caller can await it. In a test
/// process that reads as flakiness rather than as failure, because the work
/// begins whenever the last
/// reference happens to drop — so its cost can land on a later test than the
/// one whose assertions provoked it.
///
/// The cost is uneven across the six, and this `deinit` is the cheap end. It
/// invalidates the driver — no operation mutex, no deadline — and only for a
/// connection opened through a Jump Host does it also abort the forwarding
/// transport and close the parent, so a direct connection reaches no close at
/// all. The one close it can reach, `SessionDriver.close`, is cancellable, and
/// its two-second budget bounds only the native calls: the deadline is computed
/// after `acquireOperation()` returns, so the wait for the driver's operation
/// mutex ahead of it is unbounded. The five channel `deinit`s are the expensive
/// end — they take that same mutex and then run non-cancellably.
///
/// #139 is linked for its timing evidence, not as a cause — nothing here
/// establishes that these `deinit`s produce it; it records the same failure
/// moving between two adjacent tests of one suite, which is timing no single
/// test controls, and its own `deinit` hypothesis was built on
/// `SSHPTYChannel`. #136 has since stopped the five `close*` channel teardowns
/// invalidating the session when a close only ran out of time, but that
/// verdict reaches no further: `SessionDriver.close`, the close reached from
/// here, still invalidates on any failure including a bare expiry, as do the
/// two-second cleanup in `execute`'s catch and its sibling operation paths, of
/// which #149 tracks only some.
public final class SSHConnection: Sendable {
    public let hostKey: SSHHostKey
    /// How long the TCP connect took within `connect(to:timeout:)`'s
    /// successful attempt, for the app's phase timing; nil for a connection
    /// opened through a Jump Host.
    public let tcpConnectDuration: Duration?

    private let driver: SessionDriver
    private let parent: SSHConnection?
    private let byteTransport: (any SSHByteTransport)?
    private let teardownObserver: (@Sendable (SSHConnectionTeardownStep) -> Void)?

    private init(
        driver: SessionDriver,
        hostKey: SSHHostKey,
        tcpConnectDuration: Duration? = nil,
        parent: SSHConnection? = nil,
        byteTransport: (any SSHByteTransport)? = nil,
        teardownObserver: (@Sendable (SSHConnectionTeardownStep) -> Void)? = nil
    ) {
        self.driver = driver
        self.hostKey = hostKey
        self.tcpConnectDuration = tcpConnectDuration
        self.parent = parent
        self.byteTransport = byteTransport
        self.teardownObserver = teardownObserver
    }

    /// Attempts one handshake makes before a key-exchange failure is reported.
    /// See `SessionDriver.handshakeFailedInKeyExchange` for why the second
    /// attempt is independent of the first rather than a repeat of it (#332).
    /// Every attempt shares the caller's deadline, so a redial cannot extend
    /// the timeout the caller asked for.
    static let handshakeAttemptLimit = 2

    public static func connect(
        to endpoint: SSHEndpoint,
        timeout: Duration
    ) async throws -> SSHConnection {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var attemptsLeft = handshakeAttemptLimit
        while true {
            attemptsLeft -= 1
            let driver = SessionDriver()
            do {
                let hostKey = try await driver.handshake(
                    endpoint: endpoint,
                    timeout: ContinuousClock.now.duration(to: deadline))
                return SSHConnection(
                    driver: driver,
                    hostKey: hostKey,
                    tcpConnectDuration: await driver.tcpConnectDuration)
            } catch {
                guard
                    attemptsLeft > 0,
                    await driver.handshakeFailedInKeyExchange,
                    ContinuousClock.now < deadline
                else { throw error }
                SSHDiagnostics.note(
                    "handshake with \(endpoint.host):\(endpoint.port) failed in key exchange, "
                        + "redialling")
            }
        }
    }

    /// Opens an SSH connection to `endpoint` through this authenticated Jump
    /// Host. The returned connection owns both hops and closes them in target,
    /// forwarding-channel, Jump Host order.
    public func connectThrough(
        to endpoint: SSHEndpoint,
        timeout: Duration
    ) async throws -> SSHConnection {
        try await connectThrough(
            to: endpoint,
            timeout: timeout,
            teardownObserver: nil)
    }

    func connectThrough(
        to endpoint: SSHEndpoint,
        timeout: Duration,
        teardownObserver: (@Sendable (SSHConnectionTeardownStep) -> Void)?
    ) async throws -> SSHConnection {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var attemptsLeft = Self.handshakeAttemptLimit
        while true {
            attemptsLeft -= 1
            let remaining = ContinuousClock.now.duration(to: deadline)
            let transport = try await driver.openDirectTCPIP(
                endpoint: endpoint,
                timeout: remaining)
            let targetDriver = SessionDriver()
            do {
                let hostKey = try await targetDriver.handshake(
                    transport: transport,
                    endpoint: endpoint,
                    timeout: remaining)
                return SSHConnection(
                    driver: targetDriver,
                    hostKey: hostKey,
                    parent: self,
                    byteTransport: transport,
                    teardownObserver: teardownObserver)
            } catch {
                // Read before invalidating: only the target hop is retryable,
                // and only the forwarding channel it rode on is discarded. The
                // Jump Host session stays open for the redial and is closed
                // below once no attempt is left.
                let retryable = await targetDriver.handshakeFailedInKeyExchange
                await targetDriver.invalidate()
                transport.abort()
                try? await transport.close(timeout: .seconds(2))
                guard attemptsLeft > 0, retryable, ContinuousClock.now < deadline else {
                    try? await close(timeout: .seconds(2))
                    throw error
                }
                SSHDiagnostics.note(
                    "handshake with \(endpoint.host):\(endpoint.port) over the Jump Host "
                        + "transport failed in key exchange, redialling")
            }
        }
    }

    public func authenticate(
        username: String,
        password: String,
        timeout: Duration
    ) async throws {
        try await driver.authenticate(
            username: username,
            password: password,
            timeout: timeout)
    }

    /// Public-key authentication. The first request is signed right away
    /// rather than first asking whether the server would accept the key, a
    /// round trip less per connection — so `signer` also runs for a key the
    /// server then rejects. It must therefore never prompt the user (no
    /// user-presence or biometric gate on the key it signs with).
    public func authenticate(
        username: String,
        publicKey: Data,
        signer: @escaping SSHSigningClosure,
        timeout: Duration
    ) async throws {
        try await driver.authenticate(
            username: username,
            publicKey: publicKey,
            signer: signer,
            timeout: timeout)
    }

    public func execute(
        _ command: String,
        input: Data = Data(),
        timeout: Duration
    ) async throws -> SSHExecResult {
        try await driver.execute(command: command, input: input, timeout: timeout)
    }

    /// Opens one SSH session channel, sends exactly one newline-terminated
    /// input line, reads one bounded newline-terminated stdout response, and
    /// returns it. This is for forced-command request/response protocols
    /// whose process lifetime must not control the caller's bound. The
    /// channel's EOF, CLOSE and free finish in the background afterwards;
    /// `onChannelReleased` follows the rule `exchangeStreamLocal` states.
    public func executeResponseLine(
        _ command: String,
        input: Data,
        maximumResponseBytes: Int,
        timeout: Duration,
        onChannelReleased: (@Sendable () async -> Void)? = nil
    ) async throws -> Data {
        try await driver.executeResponseLine(
            command: command,
            input: input,
            maximumResponseBytes: maximumResponseBytes,
            timeout: timeout,
            onChannelReleased: onChannelReleased)
    }

    /// Opens one SSH session channel, requests the configured PTY, and then
    /// executes `command` directly; both requests go out back to back. No
    /// login shell or shell request is exposed to the caller's terminal
    /// stream. A server that refuses the PTY fails this with
    /// `SSHError.ptyDenied` and the channel closed.
    public func openPTY(
        command: String,
        terminal: String = "xterm-256color",
        columns: Int,
        rows: Int,
        timeout: Duration
    ) async throws -> SSHPTYChannel {
        try await driver.openPTY(
            command: command,
            terminal: terminal,
            columns: columns,
            rows: rows,
            timeout: timeout)
    }

    /// Opens one SSH session channel without a PTY and executes `command`
    /// directly, for long-lived line protocols on stdin and stdout such as
    /// `tmux -C`. The returned handle owns only that channel; closing it
    /// leaves this SSH connection reusable when native teardown succeeds.
    public func openExecStream(
        command: String,
        timeout: Duration
    ) async throws -> SSHExecStreamChannel {
        try await driver.openExecStream(command: command, timeout: timeout)
    }

    /// Opens one direct-streamlocal channel, writes one request, reads one
    /// newline-terminated response, and returns it. Every call owns a fresh
    /// channel to preserve one-request-per-socket protocols.
    /// `beforeRequestWrite` may throw after the channel opens but before any
    /// byte is written; its original error is preserved after channel cleanup.
    /// `onRequestWritten` runs exactly once after the complete request.
    ///
    /// The call returns once the response is read: the channel's EOF, CLOSE
    /// (a round trip, since it waits for the peer's) and free finish in the
    /// background, under the same session mutex as every other operation.
    /// `onChannelReleased` runs exactly once, when the channel is gone — after
    /// that background close, after the cleanup of a failed call, or with the
    /// session — so a caller can hold a channel budget slot for as long as
    /// the channel really exists. A background close that cannot finish
    /// invalidates the connection, as a failed synchronous cleanup does.
    public func exchangeStreamLocal(
        socketPath: String,
        request: Data,
        maximumResponseBytes: Int = 1_048_576,
        timeout: Duration,
        beforeRequestWrite: (@Sendable () async throws -> Void)? = nil,
        onRequestWritten: (@Sendable () async -> Void)? = nil,
        onChannelReleased: (@Sendable () async -> Void)? = nil
    ) async throws -> Data {
        try await driver.exchangeStreamLocal(
            socketPath: socketPath,
            request: request,
            maximumResponseBytes: maximumResponseBytes,
            timeout: timeout,
            beforeRequestWrite: beforeRequestWrite,
            onRequestWritten: onRequestWritten,
            onChannelReleased: onChannelReleased)
    }

    /// Runs `command` on one SSH session channel without a PTY, with stdin
    /// closed, and returns as soon as a complete stdout line satisfies
    /// `predicate` (the line is passed without its newline) — or at remote
    /// EOF, where an unterminated last line is tested too and `matchedLine`
    /// is nil when nothing matched. More than `maximumOutputBytes` of stdout
    /// without a match throws `SSHError.responseTooLarge`.
    ///
    /// The channel finishes in the background: its output is read and
    /// dropped until the command's EOF, within `timeout` from the start of
    /// the call, and then it is closed and freed. `onChannelReleased`
    /// follows the rule `exchangeStreamLocal` states.
    public func executeUntilLine(
        _ command: String,
        maximumOutputBytes: Int = 65_536,
        timeout: Duration,
        onChannelReleased: (@Sendable () async -> Void)? = nil,
        matching predicate: @Sendable (String) -> Bool
    ) async throws -> SSHExecLineResult {
        try await driver.executeUntilLine(
            command: command,
            maximumOutputBytes: maximumOutputBytes,
            timeout: timeout,
            matching: predicate,
            onChannelReleased: onChannelReleased)
    }

    /// Opens one long-lived direct-streamlocal channel. The returned handle
    /// owns only that channel; closing it leaves this SSH connection reusable
    /// when native teardown succeeds.
    public func openStreamLocal(
        socketPath: String,
        timeout: Duration
    ) async throws -> SSHStreamLocalChannel {
        try await driver.openStreamLocal(
            socketPath: socketPath,
            timeout: timeout)
    }

    /// Opens a long-lived direct-tcpip channel without taking exclusive
    /// ownership of the SSH session. Reads and writes share the same short
    /// driver turns as stream-local channels. Closing it leaves SSH reusable.
    public func openDirectTCP(
        host: String,
        port: UInt16,
        timeout: Duration
    ) async throws -> SSHStreamLocalChannel {
        try await driver.openDirectTCP(host: host, port: port, timeout: timeout)
    }

    /// Opens the package's deliberately small SFTP surface on one SSH session
    /// channel. Closing the returned client leaves this connection reusable.
    public func openSFTP(timeout: Duration) async throws -> SSHSFTPClient {
        try await driver.openSFTP(timeout: timeout)
    }

    /// Whether this session still has a live native connection that can
    /// safely admit another operation. An uncertain channel outcome makes
    /// this false before the app can reuse the connection.
    public var isConnected: Bool {
        get async { await driver.isReusable }
    }

    /// The numeric host of the TCP peer this connection reached, such as
    /// `192.0.2.7` or `fe80::1%en0`; an IPv4-mapped or NAT64 well-known-prefix
    /// (`64:ff9b::/96`) IPv6 peer reads as the dotted IPv4 it carries. It is
    /// the address the socket actually connected to, not a fresh resolution of
    /// the configured name. Nil when the connection rides a Jump Host, whose
    /// transport is not a network socket, or when the lookup failed.
    public var peerAddress: String? {
        get async { await driver.peerAddress }
    }

#if DEBUG
    public func delayNextSFTPWriteForTesting(_ delay: Duration) async {
        await driver.delayNextSFTPWriteForTesting(delay)
    }

    public var isSFTPWriteDelayedForTesting: Bool {
        get async { await driver.isSFTPWriteDelayedForTesting }
    }

    public func holdNextSessionWaitForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) async {
        await driver.holdNextSessionWaitForTesting(hold)
    }

    public func holdNextExecChannelAllocationForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) async {
        await driver.holdNextExecChannelAllocationForTesting(hold)
    }

    public func holdNextExecCleanupForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) async {
        await driver.holdNextExecCleanupForTesting(hold)
    }

    public func holdNextExecStreamStandardErrorDrainForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) async {
        await driver.holdNextExecStreamStandardErrorDrainForTesting(hold)
    }

    public func runNextCompensationUnlinkPhaseHookForTesting(
        _ hook: @escaping @Sendable () async throws -> Void
    ) async {
        await driver.runNextCompensationUnlinkPhaseHookForTesting(hook)
    }

    public func runNextCompensationStatPhaseHookForTesting(
        _ hook: @escaping @Sendable () async throws -> Void
    ) async {
        await driver.runNextCompensationStatPhaseHookForTesting(hook)
    }

    public func runNextCompensationShutdownHookForTesting(
        _ hook: @escaping @Sendable () async throws -> Void
    ) async {
        await driver.runNextCompensationShutdownHookForTesting(hook)
    }

    public func failNextSFTPInitBeforeEAGAINForTesting() async {
        await driver.failNextSFTPInitBeforeEAGAINForTesting()
    }

    public func holdNextOutboundWriteParkForTesting(
        _ hold: @escaping @Sendable () async -> Void
    ) async {
        await driver.holdNextOutboundWriteParkForTesting(hold)
    }

    public func holdNextOneShotEstablishedForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) async {
        await driver.holdNextOneShotEstablishedForTesting(hold)
    }

    public func holdNextOwnedLoopTopForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) async {
        await driver.holdNextOwnedLoopTopForTesting(hold)
    }

    public func holdNextOwnedDrainForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) async {
        await driver.holdNextOwnedDrainForTesting(hold)
    }

    public func holdNextChannelOpenSlotForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) async {
        await driver.holdNextChannelOpenSlotForTesting(hold)
    }

    /// Calls `observer` at every later channel-open claim, in claim order.
    func observeChannelOpenClaimsForTesting(
        _ observer: (@Sendable () -> Void)?
    ) async {
        await driver.observeChannelOpenClaimsForTesting(observer)
    }

    /// Lets at most `limit` channel opens be in flight at once.
    func setChannelOpenLimitForTesting(_ limit: Int) async {
        await driver.setChannelOpenLimitForTesting(limit)
    }

    /// Parks the next free of an abandoned channel open behind `hold`,
    /// without the session, before the free starts.
    func holdNextAbandonedChannelOpenFreeForTesting(
        _ hold: @escaping @Sendable () async -> Void
    ) async {
        await driver.holdNextAbandonedChannelOpenFreeForTesting(hold)
    }

    func abandonedChannelOpenFreeCountForTesting() async -> Int {
        await driver.abandonedChannelOpenFreeCountForTesting()
    }

    func pendingChannelOpenCountForTesting() async -> Int {
        await driver.pendingChannelOpenCountForTesting()
    }

    func peakPendingChannelOpensForTesting() async -> Int {
        await driver.peakPendingChannelOpensForTesting()
    }

    /// Parks every background one-shot channel cleanup behind `hold` before
    /// it takes the session, until cleared with nil.
    public func holdBackgroundChannelReleasesForTesting(
        _ hold: (@Sendable () async -> Void)?
    ) async {
        await driver.holdBackgroundChannelReleasesForTesting(hold)
    }

    func holdNextChannelTeardownForTesting(
        _ hold: @escaping @Sendable () async -> Void
    ) async {
        await driver.holdNextChannelTeardownForTesting(hold)
    }

    func failNextResumedChannelOpenWaiterForTesting(_ error: SSHError) async {
        await driver.failNextResumedChannelOpenWaiterForTesting(error)
    }

    func holdNextChannelOpenWaiterRegistrationForTesting(
        _ hold: @escaping @Sendable () async -> Void
    ) async {
        await driver.holdNextChannelOpenWaiterRegistrationForTesting(hold)
    }

    public func sftpUseCountForTesting() async -> Int {
        await driver.sftpUseCountForTesting()
    }

    public func sftpIdleWaiterCountForTesting() async -> Int {
        await driver.sftpIdleWaiterCountForTesting()
    }

    public func channelOpenWaiterCountForTesting() async -> Int {
        await driver.channelOpenWaiterCountForTesting()
    }

    func ptyTeardownWaiterCountForTesting() async -> Int {
        await driver.ptyTeardownWaiterCountForTesting()
    }

    func ptyChannelCountForTesting() async -> Int {
        await driver.ptyChannelCountForTesting()
    }

    func execStreamChannelCountForTesting() async -> Int {
        await driver.execStreamChannelCountForTesting()
    }

    public func startSamplingTransportSendOwnerForTesting() async {
        await driver.startSamplingTransportSendOwnerForTesting()
    }

    func transportSendOwnerSamplesForTesting() async -> [TransportSendOwnerSample] {
        await driver.transportSendOwnerSamplesForTesting()
    }

    public func oneShotRegistryCountForTesting() async -> Int {
        await driver.oneShotRegistryCountForTesting()
    }

    public func shrinkSendBufferForTesting(bytes: Int) async throws {
        try await driver.shrinkSendBufferForTesting(bytes: bytes)
    }

    func resourceStateForTesting() async -> SessionDriverResourceState {
        await driver.resourceStateForTesting()
    }

    public var operationWaiterCountForTesting: Int {
        get async { await driver.operationWaiterCountForTesting }
    }
#endif

    public func close(timeout: Duration) async throws {
        var firstError: (any Error)?
        do {
            try await driver.close(timeout: timeout)
        } catch {
            firstError = error
        }
        if byteTransport != nil { teardownObserver?(.targetSession) }
        if let byteTransport {
            do {
                try await byteTransport.close(timeout: timeout)
            } catch {
                if firstError == nil { firstError = error }
            }
            teardownObserver?(.forwardingChannel)
        }
        if let parent {
            do {
                try await parent.close(timeout: timeout)
            } catch {
                if firstError == nil { firstError = error }
            }
            teardownObserver?(.jumpSession)
        }
        if let firstError { throw firstError }
    }

    deinit {
        let driver = driver
        let byteTransport = byteTransport
        let parent = parent
        Task {
            await driver.invalidate()
            byteTransport?.abort()
            if let parent { try? await parent.close(timeout: .seconds(2)) }
        }
    }
}
