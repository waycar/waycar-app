import CLibSSH2
import CWaycarSSHSupport
import Darwin
import Foundation
import Synchronization

#if DEBUG
enum HandshakeFailureObservation {
    @TaskLocal static var observer: (@Sendable (Int32) -> Void)? = nil
}
#endif

actor SessionDriver {
    private var diagnosticStep: String {
        get { SSHDiagnosticOperation.current?.step ?? "" }
        set { SSHDiagnosticOperation.current?.step = newValue }
    }

    enum BridgeWriteResult: Equatable {
        case blocked
        case peerClosed
        case wrote(Int)
    }

    /// `writeBridge` folded every unexpected errno into `connectionFailed`,
    /// which left the forwarding pump with nothing to report (#351). The pump
    /// maps this back to `connectionFailed` after recording the errno.
    struct BridgeWriteFailure: Error, Equatable {
        let code: Int32
    }

    enum TransportSendOwnerDisposition: Equatable {
        case unchanged
        case clear
        case invalidate
    }

    private struct PacketOperationResult {
        let code: Int32
        let disposition: TransportSendOwnerDisposition
    }

    static let hostKeyAlgorithms = [
        "ssh-ed25519",
        "ecdsa-sha2-nistp384",
        "ecdsa-sha2-nistp256",
        "ecdsa-sha2-nistp521",
        "rsa-sha2-512",
        "rsa-sha2-256",
    ]

    private static let hostKeyPreference = hostKeyAlgorithms.joined(separator: ",")

    static let signatureAlgorithms = ["rsa-sha2-512"]

    private static let signaturePreference = signatureAlgorithms.joined(separator: ",")

    private static let keyExchangePreference = [
        "mlkem768x25519-sha256",
        "curve25519-sha256",
        "curve25519-sha256@libssh.org",
        "ecdh-sha2-nistp384",
        "ecdh-sha2-nistp256",
        "ecdh-sha2-nistp521",
        "diffie-hellman-group18-sha512",
        "diffie-hellman-group16-sha512",
        "diffie-hellman-group14-sha256",
        "diffie-hellman-group-exchange-sha256",
    ].joined(separator: ",")

    private static let cipherPreference = [
        "chacha20-poly1305@openssh.com",
        "aes256-gcm@openssh.com",
        "aes128-gcm@openssh.com",
        "aes256-ctr",
        "aes192-ctr",
        "aes128-ctr",
    ].joined(separator: ",")

    private static let macPreference = [
        "hmac-sha2-512-etm@openssh.com",
        "hmac-sha2-256-etm@openssh.com",
        "hmac-sha2-512",
        "hmac-sha2-256",
    ].joined(separator: ",")

    private var session: OpaquePointer?
    private var descriptor: Int32 = -1
    private var authenticated = false
    private var valid = true
    private var forwarding = false

    /// The numeric address of the TCP peer the direct handshake connected
    /// to, read from the socket itself. It stays nil over a Jump Host.
    private(set) var peerAddress: String?

    /// Whether the handshake this driver attempted ended in libssh2's key
    /// exchange rather than anywhere else. `SSHConnection` redials once on it
    /// (#332).
    ///
    /// The pinned libssh2 writes the x25519 half of a hybrid ML-KEM shared
    /// secret with `BN_bn2bin`, which drops leading zero bytes, into a
    /// fixed-offset buffer (`src/kex.c:2588`). A secret whose first byte is
    /// zero — 1 handshake in 256 — therefore hashes differently from the
    /// server's copy, host key verification fails, and libssh2 reports the
    /// generic LIBSSH2_ERROR_KEY_EXCHANGE_FAILURE. Measured locally at 12
    /// failures in 5192 `mlkem768x25519-sha256` handshakes, against 0 in 6000
    /// `curve25519-sha256` ones. Upstream master carries the same code and
    /// libssh2's other hybrids share the defect, so dropping the algorithm
    /// would cost every post-quantum Host rather than fix anything.
    ///
    /// A redial is not a repeat of the same attempt: each handshake draws a
    /// fresh secret, so the retry's odds are independent and one retry takes
    /// the per-connection failure rate to roughly 1 in 65000. The code also
    /// covers genuine post-negotiation transport loss, which is equally
    /// transient.
    private(set) var handshakeFailedInKeyExchange = false
    /// How long this driver's own TCP connect took (Happy Eyeballs race
    /// included); nil over a Jump Host's forwarding channel.
    private(set) var tcpConnectDuration: Duration?
    private var nextStreamLocalChannelID: UInt64 = 0
    private struct StreamLocalChannelState {
        let channel: OpaquePointer
        var acceptsIO = true
        var teardownInProgress = false
    }
    private var streamLocalChannels: [UInt64: StreamLocalChannelState] = [:]
    /// A long-lived session channel running one exec'd command: a PTY or an
    /// exec stream. Both kinds share one registry lifecycle — EOF, exit-status
    /// close, and the teardown transition that stops accepting I/O first —
    /// and differ only in setup and in how they read.
    private struct SessionChannelState {
        let channel: OpaquePointer
        var reachedEOF = false
        var closed = false
        var acceptsIO = true
        var teardownInProgress = false
    }
    private var nextPTYChannelID: UInt64 = 0
    private var ptyChannels: [UInt64: SessionChannelState] = [:]
    private var nextExecStreamChannelID: UInt64 = 0
    private var execStreamChannels: [UInt64: SessionChannelState] = [:]
    private struct SFTPState {
        let handle: OpaquePointer
        var files: [UInt64: OpaquePointer] = [:]
    }
    private enum SFTPCompensationPhase {
        case unlink
        case stat
    }
    private var nextSFTPID: UInt64 = 0
    private var nextSFTPFileID: UInt64 = 0
    private var sftpClients: [UInt64: SFTPState] = [:]

    /// A channel open that ended with no native state left behind and the
    /// session intact: it never got past its open-slot wait, or its pipelined
    /// channel was refused, or abandoned and then freed. Callers that treat an
    /// interrupted open as uncertain state spare the session for this one.
    private struct SettledChannelOpenError: Error, Sendable {
        let underlying: SSHError
    }

    /// What a pipelined open (patch 0004) asks the server for.
    private enum ChannelOpenRequest: Sendable {
        case session
        case streamLocal(socketPath: String)
        case directTCPIP(host: String, port: UInt16)
    }

    /// A pipelined open between `libssh2_channel_*_start` and the reply its
    /// `libssh2_channel_open_finish` settles. Until then the channel takes
    /// only finish and free; the registry is what invalidation clears, so an
    /// opener that released the mutex re-resolves it before touching it.
    private struct PendingChannelOpen {
        let channel: OpaquePointer
        let session: OpaquePointer
    }

    /// `.stock` is SFTP init, the one open left on libssh2's session-owned
    /// `open_state`; `.pipelined` keeps its state on its own channel.
    private typealias ChannelOpenKind = ChannelOpenSlotMachine.Kind

    private struct OneShotChannel {
        let channel: OpaquePointer
        let session: OpaquePointer
    }

    private enum ChannelIdentity: Equatable {
        case oneShot(UInt64)
        case pty(UInt64)
        case execStream(UInt64)
        case streamLocal(UInt64)
    }

    private var nextOneShotID: UInt64 = 0
    private var oneShotChannels: [UInt64: OneShotChannel] = [:]
    private var nextTransportSendIdentity: UInt64 = 0
    /// Who owns the pending outbound packet (`TransportSendOwnerMachine`).
    private var sendOwnership = TransportSendOwnerMachine()
    /// The logical libssh2 call that last returned `EAGAIN` with an outbound
    /// block. Cleared only by that same call returning non-`EAGAIN`, or by
    /// completed whole-session invalidation. Cancellation does not clear it.
    private var transportSendOwner: UInt64? { sendOwnership.owner }
    /// How many pipelined opens may await their replies at once. A bound on
    /// native state, not a scheduling knob: it sits above the most channels
    /// the app's channel budgets admit on one connection, so those decide.
    static let pipelinedChannelOpenLimit = 32
    /// Channel opens in flight, each holding one open slot from its claim
    /// until it settles. Pipelined opens keep their request and reply wait on
    /// their own channel, so up to `channelOpenLimit` can await replies at
    /// once; the callers' channel budgets are what bound how many channels a
    /// connection carries. SFTP init is the one stock open left, driven
    /// through the session's single `open_state`, so a second stock open
    /// waits while `stockChannelOpenInFlight`; it may overlap pipelined ones.
    /// A released slot passes straight to the first waiter it can admit
    /// (`ChannelOpenSlotMachine`).
    private var channelOpenSlots = ChannelOpenSlotMachine(
        limit: SessionDriver.pipelinedChannelOpenLimit)
    private var nextPendingChannelOpenID: UInt64 = 0
    private var pendingChannelOpens: [UInt64: PendingChannelOpen] = [:]
    private var nextChannelOpenWaiterID: UInt64 = 0
    private struct DriverWaiter {
        let continuation: CheckedContinuation<Void, any Error>
        let deadlineTask: Task<Void, Never>
    }
    private struct ChannelTeardownWaiter {
        let identity: ChannelIdentity
        let waiter: DriverWaiter
    }
    /// Each parked opener's continuation and deadline, by waiter id.
    private var channelOpenWaiters: [UInt64: DriverWaiter] = [:]
    private var nextChannelTeardownWaiterID: UInt64 = 0
    private var channelTeardownWaiters: [UInt64: ChannelTeardownWaiter] = [:]
    private var sftpUses: [UInt64: Int] = [:]
    private var nextSFTPIdleWaiterID: UInt64 = 0
    private var sftpIdleWaiters: [UInt64: DriverWaiter] = [:]

#if DEBUG
    private var directTCPIPInboundBufferHighWaterMark = 0
    private var nextDirectTCPIPInboundBufferFullHoldForTesting: (@Sendable () async -> Void)?
    private var nextSFTPWriteDelayForTesting: Duration?
    private var sftpWriteDelayIsActiveForTesting = false
    private var nextSessionWaitHoldForTesting: (@Sendable () async throws -> Void)?
    private var nextExecChannelAllocatedHoldForTesting: (@Sendable () async throws -> Void)?
    private var nextExecCleanupHoldForTesting: (@Sendable () async throws -> Void)?
    private var nextExecStreamStandardErrorDrainHoldForTesting: (@Sendable () async throws -> Void)?
    private var nextExecExchangeStandardErrorReadHoldForTesting: (@Sendable () async throws -> Void)?
    private var nextCompensationUnlinkPhaseHookForTesting: (@Sendable () async throws -> Void)?
    private var nextCompensationStatPhaseHookForTesting: (@Sendable () async throws -> Void)?
    private var nextCompensationShutdownHoldForTesting: (@Sendable () async throws -> Void)?
    private var nextOutboundWriteParkHoldForTesting: (@Sendable () async -> Void)?
    private var nextOneShotEstablishedHoldForTesting: (@Sendable () async throws -> Void)?
    private var nextOwnedLoopTopHoldForTesting: (@Sendable () async throws -> Void)?
    private var nextOwnedDrainHoldForTesting: (@Sendable () async throws -> Void)?
    private var nextChannelOpenSlotHoldForTesting: (@Sendable () async throws -> Void)?
    /// Runs at every channel-open claim, synchronously and under the
    /// operation mutex, so what it records is the claim order itself. The
    /// one-shot hold above runs after the mutex is handed on, so a hook that
    /// re-arms itself loses the claim of whoever the mutex admitted first.
    private var channelOpenClaimObserverForTesting: (@Sendable () -> Void)?
    private var nextChannelTeardownHoldForTesting: (@Sendable () async -> Void)?
    private var nextResumedChannelOpenWaiterErrorForTesting: SSHError?
    private var nextChannelOpenWaiterRegistrationHoldForTesting: (@Sendable () async -> Void)?
    /// Runs once before the free of the next abandoned pipelined open.
    private var nextAbandonedChannelOpenFreeHoldForTesting: (@Sendable () async -> Void)?
    /// Abandoned pipelined opens whose `libssh2_channel_free` has returned.
    private var abandonedChannelOpenFreesForTesting = 0
    /// The most pipelined opens that were awaiting their replies at once.
    private var pendingChannelOpenPeakForTesting = 0
    /// Persistent, unlike the `next…` holds: every background one-shot
    /// cleanup waits on it before it takes the session, until cleared.
    private var backgroundChannelReleaseHoldForTesting: (@Sendable () async -> Void)?
    private var ownerSamplesForTesting: [TransportSendOwnerSample]?
    private var shouldFailNextSFTPInitBeforeEAGAINForTesting = false
#endif

    // Actor reentrancy would otherwise allow a second task to call libssh2
    // while the first one is suspended on socket readiness. Waiters resume
    // interactive first, in arrival order within a priority (C-PRIORITY).
    private var operationInProgress = false
    private var operationWaiters = PriorityWaiterQueue<CheckedContinuation<Void, Never>>()

    // Whoever holds the session may consume the bytes the operations waiting
    // for it are blocked on, which leaves them nothing to see on the socket.
    private let activity = SessionActivity()

    func handshake(endpoint: SSHEndpoint, timeout: Duration) async throws -> SSHHostKey {
        try await withDiagnosticPhase("handshake with \(endpoint.host):\(endpoint.port)") {
            await acquireOperation()
            defer { releaseOperation() }

            guard valid, !forwarding, session == nil, descriptor < 0 else {
                throw SSHError.connectionInvalidated
            }
            let deadline = ContinuousClock.now.advanced(by: timeout)

            do {
                do {
                    let connectStarted = ContinuousClock.now
                    descriptor = try await SocketConnector.connect(to: endpoint, until: deadline)
                    tcpConnectDuration = ContinuousClock.now - connectStarted
                    peerAddress = PeerAddress.read(descriptor: descriptor)
                } catch {
                    SSHDiagnostics.note(
                        "\(diagnosticContext) failed before the TCP connection completed: \(error)")
                    throw error
                }
                return try await performHandshake(deadline: deadline)
            } catch {
                invalidateResources()
                throw normalize(error)
            }
        }
    }

    func handshake(
        transport: any SSHByteTransport,
        endpoint: SSHEndpoint,
        timeout: Duration
    ) async throws -> SSHHostKey {
        try await withDiagnosticPhase(
            "handshake with \(endpoint.host):\(endpoint.port) over the Jump Host transport"
        ) {
            await acquireOperation()
            defer { releaseOperation() }

            guard valid, !forwarding, session == nil, descriptor < 0 else {
                throw SSHError.connectionInvalidated
            }
            let deadline = ContinuousClock.now.advanced(by: timeout)

            do {
                descriptor = try transport.takeDescriptor()
                return try await performHandshake(deadline: deadline)
            } catch {
                invalidateResources()
                throw normalize(error)
            }
        }
    }

    func authenticate(username: String, password: String, timeout: Duration) async throws {
        try await withDiagnosticPhase("password authentication") {
            await acquireOperation()
            defer { releaseOperation() }

            guard valid, !forwarding, !authenticated, let session else {
                throw SSHError.connectionInvalidated
            }
            guard !username.isEmpty else { throw SSHError.authenticationFailed }
            let deadline = ContinuousClock.now.advanced(by: timeout)

            do {
                // A `none` request discovers the methods without submitting
                // the password. Keep its I/O under the same operation and
                // deadline as authentication, including EAGAIN send ownership.
                var methods: String?
                let listResult = try await repeatUntilComplete(deadline: deadline) {
                    let list = username.withCString {
                        libssh2_userauth_list(session, $0, UInt32(username.utf8.count))
                    }
                    if let list {
                        methods = String(cString: list)
                        return 0
                    }
                    // A server may accept `none`; libssh2 then returns nil.
                    if libssh2_userauth_authenticated(session) != 0 { return 0 }
                    let code = libssh2_session_last_errno(session)
                    return code == 0 ? LIBSSH2_ERROR_AUTHENTICATION_FAILED : code
                }
                guard listResult == 0 else { throw mapAuthenticationError(listResult) }
                if libssh2_userauth_authenticated(session) != 0 {
                    authenticated = true
                    return
                }
                guard methods?.split(separator: ",").contains("password") == true else {
                    throw SSHError.passwordAuthenticationUnavailable
                }
                let result = try await repeatUntilComplete(deadline: deadline) {
                    username.withCString { usernamePointer in
                        password.withCString { passwordPointer in
                            libssh2_userauth_password_ex(
                                session,
                                usernamePointer,
                                UInt32(username.utf8.count),
                                passwordPointer,
                                UInt32(password.utf8.count),
                                nil)
                        }
                    }
                }
                guard result == 0 else { throw mapAuthenticationError(result) }
                authenticated = true
            } catch {
                let normalized = normalize(error)
                if normalized != .authenticationFailed && normalized != .passwordAuthenticationUnavailable {
                    invalidateResources()
                }
                throw normalized
            }
        }
    }

    func authenticate(
        username: String,
        publicKey: Data,
        signer: @escaping SSHSigningClosure,
        timeout: Duration
    ) async throws {
        try await withDiagnosticPhase("public-key authentication") {
            await acquireOperation()
            defer { releaseOperation() }

            guard valid, !forwarding, !authenticated, let session else {
                throw SSHError.connectionInvalidated
            }
            guard !username.isEmpty, !publicKey.isEmpty else {
                throw SSHError.authenticationFailed
            }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            let context = SigningContext(publicKey: publicKey, signer: signer)
            let retainedContext = Unmanaged.passRetained(context)
            defer { retainedContext.release() }
            var abstract: UnsafeMutableRawPointer? = retainedContext.toOpaque()
            // Sign the first request instead of first asking whether the
            // server would accept this key (patch 0001): one round trip less
            // per dial. The signer therefore also runs for a key the server
            // then rejects, which `SSHConnection.authenticate` documents.
            let skipQuery = libssh2_session_flag(session, LIBSSH2_FLAG_PUBKEY_SKIP_QUERY, 1)
            if skipQuery != 0 {
                SSHDiagnostics.note(
                    "\(diagnosticContext) keeps the publickey query: libssh2 refused "
                        + "LIBSSH2_FLAG_PUBKEY_SKIP_QUERY (\(skipQuery))")
            }

            do {
                let result = try await repeatUntilComplete(deadline: deadline) {
                    username.withCString { usernamePointer in
                        publicKey.withUnsafeBytes { publicKeyBytes in
                            withUnsafeMutablePointer(to: &abstract) { abstractPointer in
                                libssh2_userauth_publickey(
                                    session,
                                    usernamePointer,
                                    publicKeyBytes.bindMemory(to: UInt8.self).baseAddress,
                                    publicKeyBytes.count,
                                    signPublicKey,
                                    abstractPointer)
                            }
                        }
                    }
                }
                guard result == 0 else {
                    // The server never saw a signature, so this is not its
                    // verdict on the key: no pinned signature algorithm could
                    // be used for this request.
                    if context.refusedSignatureAlgorithm {
                        noteFailure(result)
                        throw SSHError.algorithmNegotiationFailed
                    }
                    throw mapAuthenticationError(result)
                }
                authenticated = true
            } catch {
                let normalized = normalize(error)
                if normalized != .authenticationFailed {
                    invalidateResources()
                }
                throw normalized
            }
        }
    }

    func execute(command: String, input: Data, timeout: Duration) async throws -> SSHExecResult {
        try await withDiagnosticPhase("exec") {
            await acquireOperation()
            defer { releaseOperation() }

            guard valid, !forwarding, authenticated, session != nil else {
                throw SSHError.connectionInvalidated
            }
            guard !command.isEmpty else { throw SSHError.channelFailed }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            var oneShotID: UInt64?

            do {
                let channel = try await openChannel(.session, deadline: deadline)
                let session = try requireSession()
                let id = registerOneShot(channel: channel, session: session)
                oneShotID = id
                #if DEBUG
                try await holdExecChannelAllocationForTestingIfNeeded()
                try await holdOneShotEstablishedForTestingIfNeeded()
                #endif
                try await startExec(
                    identity: .oneShot(id),
                    command: command,
                    deadline: deadline)

                let result = try await exchange(
                    identity: .oneShot(id),
                    input: input,
                    deadline: deadline)
                diagnosticStep = "channel free"
                let freeResult = try await repeatUntilCompleteYielding(
                    deadline: deadline,
                    identity: .oneShot(id)
                ) {
                    libssh2_channel_free($0)
                }
                guard freeResult == 0 else { throw SSHError.channelFailed }
                removeOneShot(id)
                return result
            } catch {
                let normalized = normalize(error)
                if let id = oneShotID {
                    do {
                        let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                        #if DEBUG
                        try await holdExecCleanupForTestingIfNeeded()
                        #endif
                        try await cleanChannel(
                            identity: .oneShot(id),
                            deadline: cleanupDeadline,
                            cancellable: false)
                        removeOneShot(id)
                    } catch {
                        // This is the last owner of the allocated exec channel.
                        // If cleanup cannot finish, only session teardown can
                        // reclaim its native channel and server session slot.
                        invalidateResources()
                    }
                } else if !(error is SettledChannelOpenError) {
                    // A channel-open outcome is uncertain, so the session must not
                    // admit later work even if the underlying TCP socket survives.
                    invalidateResources()
                }
                throw normalized
            }
        }
    }

    /// Returns as soon as the response line is read; the channel's EOF, CLOSE
    /// and free finish in the background (C-CLOSE). `onChannelReleased` runs
    /// exactly once, as for `exchangeStreamLocal`.
    func executeResponseLine(
        command: String,
        input: Data,
        maximumResponseBytes: Int,
        timeout: Duration,
        onChannelReleased: (@Sendable () async -> Void)? = nil
    ) async throws -> Data {
        do {
            return try await executeResponseLineReleasingInBackground(
                command: command,
                input: input,
                maximumResponseBytes: maximumResponseBytes,
                timeout: timeout,
                onChannelReleased: onChannelReleased)
        } catch {
            await onChannelReleased?()
            throw error
        }
    }

    private func executeResponseLineReleasingInBackground(
        command: String,
        input: Data,
        maximumResponseBytes: Int,
        timeout: Duration,
        onChannelReleased: (@Sendable () async -> Void)?
    ) async throws -> Data {
        try await withDiagnosticPhase("exec (response line)") {
            await acquireOperation()
            defer { releaseOperation() }

            guard valid, !forwarding, authenticated, session != nil else {
                throw SSHError.connectionInvalidated
            }
            guard
                !command.isEmpty,
                !input.isEmpty,
                input.last == 0x0A,
                !input.dropLast().contains(0x0A),
                maximumResponseBytes > 0
            else {
                throw SSHError.channelFailed
            }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            var oneShotID: UInt64?

            do {
                let channel = try await openChannel(.session, deadline: deadline)
                let session = try requireSession()
                let id = registerOneShot(channel: channel, session: session)
                oneShotID = id
                #if DEBUG
                try await holdExecChannelAllocationForTestingIfNeeded()
                try await holdOneShotEstablishedForTestingIfNeeded()
                #endif
                try await startExec(
                    identity: .oneShot(id),
                    command: command,
                    deadline: deadline)
                let response = try await exchangeResponseLine(
                    identity: .oneShot(id),
                    request: input,
                    maximumResponseBytes: maximumResponseBytes,
                    deadline: deadline)
                finishOneShotInBackground(
                    id: id,
                    phase: "exec (response line)",
                    finish: .close,
                    deadline: deadline,
                    onChannelReleased: onChannelReleased)
                return response
            } catch {
                let normalized = normalize(error)
                if let id = oneShotID {
                    do {
                        let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                        #if DEBUG
                        try await holdExecCleanupForTestingIfNeeded()
                        #endif
                        try await cleanChannel(
                            identity: .oneShot(id),
                            deadline: cleanupDeadline,
                            cancellable: false)
                        removeOneShot(id)
                    } catch {
                        // The response-line channel has no owner after this scope.
                        // A failed cleanup therefore requires session teardown to
                        // reclaim the native channel and its server session slot.
                        invalidateResources()
                    }
                } else if !(error is SettledChannelOpenError) {
                    invalidateResources()
                }
                throw normalized
            }
        }
    }

    /// Runs `command` on a fresh session channel and returns as soon as a
    /// complete stdout line satisfies `predicate`, or at remote EOF — where
    /// an unterminated last line is tested too (C-EXECLINE). The channel
    /// finishes in the background: stdout and stderr are read and dropped
    /// until remote EOF, within `timeout` from the start of the call, and
    /// then the channel is closed and freed. `onChannelReleased` runs exactly
    /// once, as for `exchangeStreamLocal`.
    func executeUntilLine(
        command: String,
        maximumOutputBytes: Int,
        timeout: Duration,
        matching predicate: @Sendable (String) -> Bool,
        onChannelReleased: (@Sendable () async -> Void)?
    ) async throws -> SSHExecLineResult {
        do {
            return try await executeUntilLineReleasingInBackground(
                command: command,
                maximumOutputBytes: maximumOutputBytes,
                timeout: timeout,
                matching: predicate,
                onChannelReleased: onChannelReleased)
        } catch {
            await onChannelReleased?()
            throw error
        }
    }

    private func executeUntilLineReleasingInBackground(
        command: String,
        maximumOutputBytes: Int,
        timeout: Duration,
        matching predicate: @Sendable (String) -> Bool,
        onChannelReleased: (@Sendable () async -> Void)?
    ) async throws -> SSHExecLineResult {
        try await withDiagnosticPhase("exec (until line)", budget: timeout) {
            await acquireOperation()
            defer { releaseOperation() }

            guard valid, !forwarding, authenticated, session != nil else {
                throw SSHError.connectionInvalidated
            }
            guard !command.isEmpty, maximumOutputBytes > 0 else { throw SSHError.channelFailed }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            var oneShotID: UInt64?

            do {
                let channel = try await openChannel(.session, deadline: deadline)
                let session = try requireSession()
                let id = registerOneShot(channel: channel, session: session)
                oneShotID = id
                try await startExec(identity: .oneShot(id), command: command, deadline: deadline)

                var progress = ExecExchangeProgress(
                    input: Data(),
                    standardErrorLimit: maximumOutputBytes)
                var scanned = 0
                var matchedLine: String?
                let reachedEOF = try await runExecExchange(
                    identity: .oneShot(id),
                    &progress,
                    deadline: deadline
                ) { stdout in
                    matchedLine = Self.firstMatchingLine(in: stdout, after: &scanned, predicate)
                    if matchedLine != nil { return true }
                    guard stdout.count <= maximumOutputBytes else {
                        throw SSHError.responseTooLarge(limit: maximumOutputBytes)
                    }
                    return false
                }
                if matchedLine == nil, scanned < progress.stdout.count {
                    let lastLine = String(
                        decoding: progress.stdout.dropFirst(scanned),
                        as: UTF8.self)
                    if predicate(lastLine) { matchedLine = lastLine }
                }
                let result = SSHExecLineResult(
                    matchedLine: matchedLine,
                    stdout: progress.stdout,
                    stderr: progress.stderr)
                progress.keepsOutput = false
                progress.stdout = Data()
                progress.stderr = Data()
                finishOneShotInBackground(
                    id: id,
                    phase: "exec (until line)",
                    finish: .drainExec(progress, reachedEOF: reachedEOF),
                    deadline: deadline,
                    onChannelReleased: onChannelReleased)
                return result
            } catch {
                let normalized = normalize(error)
                if let id = oneShotID {
                    do {
                        try await cleanChannel(
                            identity: .oneShot(id),
                            deadline: ContinuousClock.now.advanced(by: Self.oneShotCleanupBudget),
                            cancellable: false)
                        removeOneShot(id)
                    } catch {
                        // The last owner of the channel: only session teardown
                        // can reclaim it and its server session slot now.
                        invalidateResources()
                    }
                } else if !(error is SettledChannelOpenError) {
                    invalidateResources()
                }
                throw normalized
            }
        }
    }

    /// The first complete line of `output` past byte `scanned` that
    /// satisfies `predicate`, without its "\n". Moves `scanned` past every
    /// complete line examined.
    static func firstMatchingLine(
        in output: Data,
        after scanned: inout Int,
        _ predicate: (String) -> Bool
    ) -> String? {
        var lineStart = output.index(output.startIndex, offsetBy: scanned)
        while let newline = output[lineStart...].firstIndex(of: 0x0A) {
            let line = String(decoding: output[lineStart..<newline], as: UTF8.self)
            lineStart = output.index(after: newline)
            scanned = output.distance(from: output.startIndex, to: lineStart)
            if predicate(line) { return line }
        }
        return nil
    }

    func openPTY(
        command: String,
        terminal: String,
        columns: Int,
        rows: Int,
        timeout: Duration
    ) async throws -> SSHPTYChannel {
        try await withDiagnosticPhase("PTY open", budget: timeout) {
            await acquireOperation()
            defer { releaseOperation() }

            guard valid, !forwarding, authenticated, session != nil else {
                throw SSHError.connectionInvalidated
            }
            guard
                !command.isEmpty,
                !command.utf8.contains(0),
                command.utf8.count <= Int(UInt32.max),
                !terminal.isEmpty,
                !terminal.utf8.contains(0),
                terminal.utf8.count <= Int(UInt32.max),
                columns > 0,
                columns <= Int(Int32.max),
                rows > 0,
                rows <= Int(Int32.max)
            else {
                throw SSHError.channelFailed
            }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            var registeredID: UInt64?

            do {
                let channel = try await openChannel(.session, deadline: deadline)
                nextPTYChannelID &+= 1
                let id = nextPTYChannelID
                ptyChannels[id] = SessionChannelState(channel: channel)
                registeredID = id
                // A refusal of either request lands in the cleanup below like
                // any failure: closing the channel also cuts off a command
                // the server may have started without the PTY it refused.
                try await startPTYProcess(
                    identity: .pty(id),
                    terminal: terminal,
                    columns: columns,
                    rows: rows,
                    command: command,
                    deadline: deadline)
                return SSHPTYChannel(id: id, driver: self)
            } catch {
                let normalized = normalize(error)
                if let id = registeredID {
                    do {
                        try await cleanChannel(
                            identity: .pty(id),
                            deadline: ContinuousClock.now.advanced(by: .seconds(2)),
                            cancellable: false)
                        ptyChannels.removeValue(forKey: id)
                    } catch {
                        invalidateResources()
                    }
                } else if !(error is SettledChannelOpenError) {
                    invalidateResources()
                }
                throw normalized
            }
        }
    }

    func writePTY(id: UInt64, data: Data, timeout: Duration) async throws {
        try await withDiagnosticPhase("PTY write channel \(id)", budget: timeout) {
            try await writeSessionChannel(.pty(id), data: data, timeout: timeout)
        }
    }

    func readPTY(
        id: UInt64,
        maximumBytes: Int,
        timeout: Duration
    ) async throws -> Data? {
        try await withDiagnosticPhase("PTY read channel \(id)", budget: timeout) {
            guard maximumBytes > 0 else { throw SSHError.channelFailed }
            let deadline = ContinuousClock.now.advanced(by: timeout)

            let owner = allocateTransportSendOwner()
            while true {
                await acquireOperation()
                let progress: (data: Data, eof: Bool, wait: SessionWaitPlan)
                do {
                    try checkProgress(deadline: deadline)
                    try await waitForTransportSendAdmission(
                        owner: owner,
                        deadline: deadline,
                        cancellable: true)
                    let session = try requireSession()
                    let channel = try resolveChannel(.pty(id))
                    var buffer = [UInt8](repeating: 0, count: maximumBytes)
                    let data = try readAvailableNoting(
                        channel: channel,
                        stream: 0,
                        buffer: &buffer,
                        owner: owner,
                        session: session)
                    let eof = libssh2_channel_eof(channel) == 1
                    if eof { ptyChannels[id]?.reachedEOF = true }
                    progress = (data, eof, sessionWaitPlan(session))
                    releaseOperation()
                } catch {
                    await finishOwnedSendIfNeeded(owner: owner) {
                        guard let channel = try? resolveChannel(.pty(id)) else { return nil }
                        var scratch = [UInt8](repeating: 0, count: maximumBytes)
                        return readOnce(channel: channel, stream: 0, buffer: &scratch)
                    }
                    releaseOperation()
                    throw normalize(error)
                }

                if !progress.data.isEmpty { return progress.data }
                if progress.eof { return nil }
                do {
                    try await awaitSessionProgress(progress.wait, until: deadline)
                } catch {
                    await acquireOperation()
                    await finishOwnedSendIfNeeded(owner: owner) {
                        guard let channel = try? resolveChannel(.pty(id)) else { return nil }
                        var scratch = [UInt8](repeating: 0, count: maximumBytes)
                        return readOnce(channel: channel, stream: 0, buffer: &scratch)
                    }
                    releaseOperation()
                    throw normalize(error)
                }
            }
        }
    }

    func resizePTY(
        id: UInt64,
        columns: Int,
        rows: Int,
        timeout: Duration
    ) async throws {
        try await withDiagnosticPhase("PTY resize channel \(id)", budget: timeout) {
            guard
                columns > 0,
                columns <= Int(Int32.max),
                rows > 0,
                rows <= Int(Int32.max)
            else {
                throw SSHError.channelFailed
            }
            await acquireOperation()
            defer { releaseOperation() }

            guard valid, session != nil else { throw SSHError.connectionInvalidated }
            guard ptyChannels[id] != nil else { throw SSHError.channelFailed }
            let result = try await repeatUntilCompleteYielding(
                deadline: ContinuousClock.now.advanced(by: timeout),
                identity: .pty(id)
            ) {
                libssh2_channel_request_pty_size_ex($0, Int32(columns), Int32(rows), 0, 0)
            }
            guard result == 0 else { throw SSHError.channelFailed }
        }
    }

    func ptyExitStatus(id: UInt64, timeout: Duration) async throws -> Int32 {
        try await withDiagnosticPhase("PTY exit status channel \(id)", budget: timeout) {
            try await sessionChannelExitStatus(.pty(id), timeout: timeout)
        }
    }

    func closePTY(id: UInt64, timeout: Duration) async throws {
        try await withDiagnosticPhase("PTY close channel \(id)", budget: timeout) {
            try await closeSessionChannel(.pty(id), label: "PTY", timeout: timeout)
        }
    }

    /// Opens one session channel without a PTY and executes `command` on it.
    /// Stdout and stderr stay separate streams; see `readExecStream`.
    func openExecStream(
        command: String,
        timeout: Duration
    ) async throws -> SSHExecStreamChannel {
        try await withDiagnosticPhase("exec stream open", budget: timeout) {
            await acquireOperation()
            defer { releaseOperation() }

            guard valid, !forwarding, authenticated, session != nil else {
                throw SSHError.connectionInvalidated
            }
            guard
                !command.isEmpty,
                !command.utf8.contains(0),
                command.utf8.count <= Int(UInt32.max)
            else {
                throw SSHError.channelFailed
            }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            var registeredID: UInt64?

            do {
                // libssh2's default extended-data mode keeps stderr queued on
                // its own stream; `readExecStream` drains it every turn.
                let channel = try await openChannel(.session, deadline: deadline)
                nextExecStreamChannelID &+= 1
                let id = nextExecStreamChannelID
                execStreamChannels[id] = SessionChannelState(channel: channel)
                registeredID = id
                try await startExec(
                    identity: .execStream(id),
                    command: command,
                    deadline: deadline)
                return SSHExecStreamChannel(id: id, driver: self)
            } catch {
                let normalized = normalize(error)
                if let id = registeredID {
                    do {
                        try await cleanChannel(
                            identity: .execStream(id),
                            deadline: ContinuousClock.now.advanced(by: .seconds(2)),
                            cancellable: false)
                        execStreamChannels.removeValue(forKey: id)
                    } catch {
                        invalidateResources()
                    }
                } else if !(error is SettledChannelOpenError) {
                    invalidateResources()
                }
                throw normalized
            }
        }
    }

    func writeExecStream(id: UInt64, data: Data, timeout: Duration) async throws {
        try await withDiagnosticPhase("exec stream write channel \(id)", budget: timeout) {
            try await writeSessionChannel(.execStream(id), data: data, timeout: timeout)
        }
    }

    /// Reads stdout, or nil after orderly remote EOF.
    ///
    /// Every turn also drains whatever stderr libssh2 has queued for the
    /// channel into `standardError`. Unread stderr would otherwise hold the
    /// channel's shared receive window closed — stalling stdout behind it —
    /// and would mask remote EOF, which libssh2 reports only once no data of
    /// either stream is queued.
    ///
    /// The two reads are separate logical calls with separate transport-send
    /// owners. A turn drives whichever of them owns a pending packet first,
    /// and drains stderr only when no foreign owner would make it wait, so
    /// stdout bytes already read are never held across a wait that could
    /// throw them away. No call returns while one of its reads still owns
    /// the transport send: the owner is driven to completion first.
    ///
    /// A turn that finds nothing waits on the receive count from before its
    /// first read. The stderr drain takes every packet on the socket into
    /// libssh2's queue, stdout that arrived after the stdout read included,
    /// and leaves no socket edge behind; a count taken after the drain would
    /// park the reader on bytes it already has.
    func readExecStream(
        id: UInt64,
        maximumBytes: Int,
        standardError: ExecStreamStandardErrorTail,
        timeout: Duration
    ) async throws -> Data? {
        try await withDiagnosticPhase("exec stream read channel \(id)", budget: timeout) {
            guard maximumBytes > 0 else { throw SSHError.channelFailed }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            let stdoutOwner = allocateTransportSendOwner()
            let stderrOwner = allocateTransportSendOwner()

            while true {
                await acquireOperation()
                let progress: (
                    data: Data,
                    eof: Bool,
                    drainedStandardError: Bool,
                    wait: SessionWaitPlan
                )
                do {
                    try checkProgress(deadline: deadline)
                    let watch = activity.watch()
                    var data = Data()
                    if transportSendOwner != stderrOwner {
                        try await waitForTransportSendAdmission(
                            owner: stdoutOwner,
                            deadline: deadline,
                            cancellable: true)
                        let session = try requireSession()
                        let channel = try resolveChannel(.execStream(id))
                        var buffer = [UInt8](repeating: 0, count: maximumBytes)
                        data = try readAvailableNoting(
                            channel: channel,
                            stream: 0,
                            buffer: &buffer,
                            owner: stdoutOwner,
                            session: session)
                    }
                    var drainedStandardError = false
                    if transportSendOwner == nil || transportSendOwner == stderrOwner {
#if DEBUG
                        if let hold = nextExecStreamStandardErrorDrainHoldForTesting {
                            nextExecStreamStandardErrorDrainHoldForTesting = nil
                            try await hold()
                        }
#endif
                        drainedStandardError = try drainExecStreamStandardError(
                            id: id,
                            owner: stderrOwner,
                            into: standardError)
                    }
                    let session = try requireSession()
                    let channel = try resolveChannel(.execStream(id))
                    let eof = libssh2_channel_eof(channel) == 1
                    if eof { execStreamChannels[id]?.reachedEOF = true }
                    // Taken before any finishing drive, which may free the session.
                    let wait = sessionWaitPlan(session, watching: watch)
                    if !data.isEmpty || eof {
                        // This turn returns, and nothing would drive its reads
                        // again: finish the one that owns a pending packet so
                        // the shared transport is never left blocked on it.
                        // Only a stdout read that hit EAGAIN can own it here,
                        // so recovered stdout lands in an empty `data`.
                        data.append(
                            await finishOwnedExecStreamReads(
                                id: id,
                                maximumBytes: maximumBytes,
                                stdoutOwner: stdoutOwner,
                                stderrOwner: stderrOwner,
                                standardError: standardError))
                    }
                    progress = (data, eof, drainedStandardError, wait)
                    releaseOperation()
                } catch {
                    await finishOwnedExecStreamReads(
                        id: id,
                        maximumBytes: maximumBytes,
                        stdoutOwner: stdoutOwner,
                        stderrOwner: stderrOwner,
                        standardError: standardError)
                    releaseOperation()
                    throw normalize(error)
                }

                if !progress.data.isEmpty { return progress.data }
                if progress.eof { return nil }
                if progress.drainedStandardError {
                    // More stderr, or stdout behind it, may already be queued
                    // locally, where no socket readiness would announce it.
                    await Task.yield()
                    continue
                }
                do {
                    try await awaitSessionProgress(progress.wait, until: deadline)
                } catch {
                    await acquireOperation()
                    await finishOwnedExecStreamReads(
                        id: id,
                        maximumBytes: maximumBytes,
                        stdoutOwner: stdoutOwner,
                        stderrOwner: stderrOwner,
                        standardError: standardError)
                    releaseOperation()
                    throw normalize(error)
                }
            }
        }
    }

    /// Drives whichever exec-stream read owns the pending outbound packet to
    /// a non-`EAGAIN` result, as `readPTY` does for its single read. Stderr
    /// the drive reads goes to `standardError`; the stdout it reads is
    /// returned.
    @discardableResult
    private func finishOwnedExecStreamReads(
        id: UInt64,
        maximumBytes: Int,
        stdoutOwner: UInt64,
        stderrOwner: UInt64,
        standardError: ExecStreamStandardErrorTail
    ) async -> Data {
        var recovered = Data()
        await finishOwnedSendIfNeeded(owner: stdoutOwner) {
            guard let channel = try? resolveChannel(.execStream(id)) else { return nil }
            var scratch = [UInt8](repeating: 0, count: maximumBytes)
            return readOnce(channel: channel, stream: 0, buffer: &scratch, keeping: &recovered)
        }
        await finishOwnedSendIfNeeded(owner: stderrOwner) {
            guard let channel = try? resolveChannel(.execStream(id)) else { return nil }
            var scratch = [UInt8](repeating: 0, count: Self.execStreamStandardErrorChunk)
            var drained = Data()
            let result = readOnce(
                channel: channel,
                stream: Int32(SSH_EXTENDED_DATA_STDERR),
                buffer: &scratch,
                keeping: &drained)
            if !drained.isEmpty { standardError.append(drained) }
            return result
        }
        return recovered
    }

    func execStreamExitStatus(id: UInt64, timeout: Duration) async throws -> Int32 {
        try await withDiagnosticPhase("exec stream exit status channel \(id)", budget: timeout) {
            try await sessionChannelExitStatus(.execStream(id), timeout: timeout)
        }
    }

    func closeExecStream(id: UInt64, timeout: Duration) async throws {
        try await withDiagnosticPhase("exec stream close channel \(id)", budget: timeout) {
            try await closeSessionChannel(.execStream(id), label: "exec stream", timeout: timeout)
        }
    }

    /// The stderr bytes one exec-stream read turn may drain before it gives
    /// the session back: `execStreamStandardErrorReadsPerTurn` reads of this
    /// size, so a flooding stderr cannot hold the operation mutex unbounded.
    private static let execStreamStandardErrorChunk = 16 * 1_024
    private static let execStreamStandardErrorReadsPerTurn = 4

    /// Reads queued stderr into `tail` within one turn. Returns whether any
    /// byte arrived. Stops at the first empty read, including the `EAGAIN`
    /// that records `owner` as the transport-send owner.
    private func drainExecStreamStandardError(
        id: UInt64,
        owner: UInt64,
        into tail: ExecStreamStandardErrorTail
    ) throws -> Bool {
        var buffer = [UInt8](repeating: 0, count: Self.execStreamStandardErrorChunk)
        var drained = false
        for _ in 0..<Self.execStreamStandardErrorReadsPerTurn {
            let session = try requireSession()
            let channel = try resolveChannel(.execStream(id))
            let data = try readAvailableNoting(
                channel: channel,
                stream: Int32(SSH_EXTENDED_DATA_STDERR),
                buffer: &buffer,
                owner: owner,
                session: session)
            guard !data.isEmpty else { break }
            tail.append(data)
            drained = true
        }
        return drained
    }

    /// The registry entry of a PTY or exec-stream channel; nil for every
    /// other identity.
    private subscript(sessionChannel identity: ChannelIdentity) -> SessionChannelState? {
        get {
            switch identity {
            case .pty(let id): ptyChannels[id]
            case .execStream(let id): execStreamChannels[id]
            case .oneShot, .streamLocal: nil
            }
        }
        set {
            switch identity {
            case .pty(let id): ptyChannels[id] = newValue
            case .execStream(let id): execStreamChannels[id] = newValue
            case .oneShot, .streamLocal: break
            }
        }
    }

    /// Writes all of `data` to a PTY or exec-stream channel in bounded turns.
    private func writeSessionChannel(
        _ identity: ChannelIdentity,
        data: Data,
        timeout: Duration
    ) async throws {
        guard !data.isEmpty else { return }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var offset = 0
        let owner = allocateTransportSendOwner()

        while offset < data.count {
            await acquireOperation()
            let progress: (written: Int, wait: SessionWaitPlan, parkedOutbound: Bool)
            do {
                try await holdOwnedLoopTopForTestingIfNeeded(owner: owner)
                try checkProgress(deadline: deadline)
                try await waitForTransportSendAdmission(
                    owner: owner,
                    deadline: deadline,
                    cancellable: true)
                let session = try requireSession()
                let channel = try resolveChannel(identity)
                let written = writeChannel(channel, data: data, offset: offset)
                let disposition = notePacketProducingWrite(
                    written,
                    owner: owner,
                    session: session)
                applyTransportSendOwnerDisposition(disposition)
                guard written >= 0 || written == Int(LIBSSH2_ERROR_EAGAIN) else {
                    throw SSHError.channelFailed
                }
                progress = (
                    written,
                    sessionWaitPlan(session),
                    written == Int(LIBSSH2_ERROR_EAGAIN) && transportSendOwner == owner
                )
                releaseOperation()
            } catch {
                let normalized = normalize(error)
                await finishOwnedSendIfNeeded(owner: owner) {
                    writeChannelOnce(identity: identity, data: data, offset: offset)
                }
                releaseOperation()
                throw normalized
            }

            if progress.written > 0 {
                offset += progress.written
                await Task.yield()
            } else {
                #if DEBUG
                if progress.parkedOutbound {
                    await holdOutboundWriteParkForTestingIfNeeded()
                }
                #endif
                do {
                    try await awaitSessionProgress(progress.wait, until: deadline)
                } catch {
                    await acquireOperation()
                    await finishOwnedSendIfNeeded(owner: owner) {
                        writeChannelOnce(identity: identity, data: data, offset: offset)
                    }
                    releaseOperation()
                    throw normalize(error)
                }
            }
        }
    }

    /// Closes a PTY or exec-stream channel after its reader saw EOF and
    /// returns the remote exit status. Stops accepting I/O first; failure
    /// restores I/O eligibility so the caller can retry or close.
    private func sessionChannelExitStatus(
        _ identity: ChannelIdentity,
        timeout: Duration
    ) async throws -> Int32 {
        diagnosticStep = "operation admission"
        await acquireOperation()
        defer { releaseOperation() }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        diagnosticStep = "exit status preflight"
        try checkProgress(deadline: deadline)
        guard valid, session != nil else { throw SSHError.connectionInvalidated }
        guard var state = self[sessionChannel: identity], state.reachedEOF else {
            throw SSHError.channelFailed
        }
        guard !state.teardownInProgress else { throw SSHError.channelFailed }
        state.acceptsIO = false
        state.teardownInProgress = true
        self[sessionChannel: identity] = state
        #if DEBUG
        diagnosticStep = "teardown test hold"
        await holdChannelTeardownForTestingIfNeeded()
        #endif

        do {
            let exitStatus = try await exitStatusAfterChannelClose(
                identity: identity,
                deadline: deadline,
                allowClosing: true)
            self[sessionChannel: identity]?.closed = true
            self[sessionChannel: identity]?.teardownInProgress = false
            wakeChannelTeardownWaiters(for: identity)
            return exitStatus
        } catch {
            self[sessionChannel: identity]?.acceptsIO = true
            self[sessionChannel: identity]?.teardownInProgress = false
            wakeChannelTeardownWaiters(for: identity)
            throw error
        }
    }

    /// Closes only this PTY or exec-stream channel. Idempotent. Waits for an
    /// in-flight exit-status handshake, then stops accepting I/O before the
    /// first yield.
    private func closeSessionChannel(
        _ identity: ChannelIdentity,
        label: String,
        timeout: Duration
    ) async throws {
        diagnosticStep = "operation admission"
        await acquireOperation()
        defer { releaseOperation() }

        guard self[sessionChannel: identity] != nil else { return }
        guard valid, session != nil else {
            self[sessionChannel: identity] = nil
            wakeChannelTeardownWaiters(for: identity)
            return
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        diagnosticStep = "teardown admission"
        do {
            try await waitUntilChannelTeardownCompletes(
                identity,
                label: label,
                deadline: deadline)
        } catch {
            throw normalize(error)
        }
        guard var state = self[sessionChannel: identity] else { return }
        guard valid, session != nil else {
            self[sessionChannel: identity] = nil
            wakeChannelTeardownWaiters(for: identity)
            return
        }
        state.acceptsIO = false
        state.teardownInProgress = true
        self[sessionChannel: identity] = state
        #if DEBUG
        diagnosticStep = "teardown test hold"
        await holdChannelTeardownForTestingIfNeeded()
        #endif
        do {
            if self[sessionChannel: identity]?.closed == true {
                diagnosticStep = "channel free"
                let freeResult = try await repeatUntilCompleteYielding(
                    deadline: deadline,
                    cancellable: false,
                    identity: identity,
                    allowClosing: true
                ) {
                    libssh2_channel_free($0)
                }
                guard freeResult == 0 else { throw SSHError.channelFailed }
            } else {
                try await cleanChannel(
                    identity: identity,
                    deadline: deadline,
                    cancellable: false,
                    allowClosing: true)
            }
            self[sessionChannel: identity] = nil
            wakeChannelTeardownWaiters(for: identity)
        } catch {
            self[sessionChannel: identity] = nil
            wakeChannelTeardownWaiters(for: identity)
            throw teardownFailure(error)
        }
    }

    /// Returns as soon as the response line is read; the channel's EOF,
    /// CLOSE and free finish in the background (C-CLOSE). `onChannelReleased`
    /// runs exactly once, when the channel no longer exists natively: after
    /// that background close, after the synchronous cleanup of a failed call,
    /// or once the session is gone.
    func exchangeStreamLocal(
        socketPath: String,
        request: Data,
        maximumResponseBytes: Int,
        timeout: Duration,
        beforeRequestWrite: (@Sendable () async throws -> Void)? = nil,
        onRequestWritten: (@Sendable () async -> Void)? = nil,
        onChannelReleased: (@Sendable () async -> Void)? = nil
    ) async throws -> Data {
        do {
            return try await exchangeStreamLocalReleasingInBackground(
                socketPath: socketPath,
                request: request,
                maximumResponseBytes: maximumResponseBytes,
                timeout: timeout,
                beforeRequestWrite: beforeRequestWrite,
                onRequestWritten: onRequestWritten,
                onChannelReleased: onChannelReleased)
        } catch {
            await onChannelReleased?()
            throw error
        }
    }

    private func exchangeStreamLocalReleasingInBackground(
        socketPath: String,
        request: Data,
        maximumResponseBytes: Int,
        timeout: Duration,
        beforeRequestWrite: (@Sendable () async throws -> Void)?,
        onRequestWritten: (@Sendable () async -> Void)?,
        onChannelReleased: (@Sendable () async -> Void)?
    ) async throws -> Data {
        try await withDiagnosticPhase("stream-local exchange on \(socketPath)") {
            await acquireOperation()
            defer { releaseOperation() }

            guard valid, !forwarding, authenticated, session != nil else {
                throw SSHError.connectionInvalidated
            }
            guard
                socketPath.hasPrefix("/"),
                !socketPath.utf8.contains(0),
                !request.isEmpty,
                request.last == 0x0A,
                maximumResponseBytes > 0
            else {
                throw SSHError.channelFailed
            }

            let deadline = ContinuousClock.now.advanced(by: timeout)
            var oneShotID: UInt64?

            do {
                let channel = try await openChannel(
                    .streamLocal(socketPath: socketPath),
                    deadline: deadline)
                let session = try requireSession()
                let id = registerOneShot(
                    channel: channel,
                    session: session)
                oneShotID = id
                #if DEBUG
                try await holdOneShotEstablishedForTestingIfNeeded()
                #endif
                let response = try await exchangeResponseLine(
                    identity: .oneShot(id),
                    request: request,
                    maximumResponseBytes: maximumResponseBytes,
                    deadline: deadline,
                    beforeRequestWrite: beforeRequestWrite,
                    onRequestWritten: onRequestWritten)
                finishOneShotInBackground(
                    id: id,
                    phase: "stream-local exchange on \(socketPath)",
                    finish: .close,
                    deadline: deadline,
                    onChannelReleased: onChannelReleased)
                return response
            } catch {
                let normalized: SSHError?
                if error is SettledChannelOpenError {
                    normalized = normalize(error)
                } else {
                    normalized = (error as? SSHError).map(normalize)
                }
                if let id = oneShotID {
                    do {
                        try await cleanChannel(
                            identity: .oneShot(id),
                            deadline: ContinuousClock.now.advanced(by: .seconds(2)),
                            cancellable: false)
                        removeOneShot(id)
                    } catch {
                        invalidateResources()
                    }
                } else if !(error is SettledChannelOpenError),
                    normalized != .streamLocalOpenFailed
                {
                    // `.streamLocalOpenFailed` now means only what it says: the
                    // server refused this one channel and the session is intact.
                    // An open interrupted mid-flight arrives settled once its
                    // channel is freed. What is left — the socket loss
                    // `mappedStreamLocalOpenError` reports as `.connectionInvalidated`
                    // — must not admit later work on this session.
                    invalidateResources()
                }
                if let normalized {
                    throw normalized
                }
                throw error
            }
        }
    }

    func openStreamLocal(
        socketPath: String,
        timeout: Duration
    ) async throws -> SSHStreamLocalChannel {
        try await withDiagnosticPhase("stream-local open on \(socketPath)") {
            await acquireOperation()
            defer { releaseOperation() }

            guard valid, !forwarding, authenticated, session != nil else {
                throw SSHError.connectionInvalidated
            }
            guard socketPath.hasPrefix("/"), !socketPath.utf8.contains(0) else {
                throw SSHError.channelFailed
            }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            var channel: OpaquePointer?

            do {
                channel = try await openChannel(
                    .streamLocal(socketPath: socketPath),
                    deadline: deadline)
                guard let channel else { throw SSHError.streamLocalOpenFailed }
                nextStreamLocalChannelID &+= 1
                let id = nextStreamLocalChannelID
                streamLocalChannels[id] = StreamLocalChannelState(channel: channel)
                return SSHStreamLocalChannel(id: id, driver: self)
            } catch {
                let normalized = normalize(error)
                if let channel {
                    do {
                        try await cleanChannel(
                            channel,
                            session: try requireSession(),
                            deadline: ContinuousClock.now.advanced(by: .seconds(2)),
                            cancellable: false)
                    } catch {
                        invalidateResources()
                    }
                } else if !(error is SettledChannelOpenError),
                    normalized != .streamLocalOpenFailed
                {
                    // The same rule `exchangeStreamLocal` states above: only a
                    // refusal of this one channel leaves the session usable.
                    invalidateResources()
                }
                throw normalized
            }
        }
    }

    /// A multiplexed direct-tcpip channel: unlike the jump-host bridge below,
    /// this keeps taking short driver turns beside exec and stream-local I/O.
    func openDirectTCP(
        host: String,
        port: UInt16,
        timeout: Duration
    ) async throws -> SSHStreamLocalChannel {
        await acquireOperation()
        defer { releaseOperation() }
        guard valid, !forwarding, authenticated, session != nil else {
            throw SSHError.connectionInvalidated
        }
        guard !host.isEmpty, !host.utf8.contains(0), port > 0 else {
            throw SSHError.channelFailed
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var channel: OpaquePointer?
        do {
            channel = try await openChannel(.directTCPIP(host: host, port: port), deadline: deadline)
            guard let channel else { throw SSHError.channelFailed }
            nextStreamLocalChannelID &+= 1
            let id = nextStreamLocalChannelID
            streamLocalChannels[id] = StreamLocalChannelState(channel: channel)
            return SSHStreamLocalChannel(id: id, driver: self)
        } catch {
            let normalized = normalize(error)
            if let channel {
                do {
                    try await cleanChannel(
                        channel,
                        session: try requireSession(),
                        deadline: ContinuousClock.now.advanced(by: .seconds(2)),
                        cancellable: false)
                } catch {
                    invalidateResources()
                }
            } else if !(error is SettledChannelOpenError),
                normalized == .timedOut || normalized == .cancelled
            {
                invalidateResources()
            }
            throw normalized
        }
    }

    func writeStreamLocal(
        id: UInt64,
        data: Data,
        timeout: Duration
    ) async throws {
        try await withDiagnosticPhase("stream-local write channel \(id)") {
            guard !data.isEmpty else { return }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            var offset = 0
            let owner = allocateTransportSendOwner()

            while offset < data.count {
                await acquireOperation()
                let progress: (written: Int, wait: SessionWaitPlan, parkedOutbound: Bool)
                do {
                    try await holdOwnedLoopTopForTestingIfNeeded(owner: owner)
                    try checkProgress(deadline: deadline)
                    try await waitForTransportSendAdmission(
                        owner: owner,
                        deadline: deadline,
                        cancellable: true)
                    let session = try requireSession()
                    let channel = try resolveChannel(.streamLocal(id))
                    let written = writeChannel(channel, data: data, offset: offset)
                    let disposition = notePacketProducingWrite(
                        written,
                        owner: owner,
                        session: session)
                    applyTransportSendOwnerDisposition(disposition)
                    guard written >= 0 || written == Int(LIBSSH2_ERROR_EAGAIN) else {
                        throw SSHError.channelFailed
                    }
                    progress = (
                        written,
                        sessionWaitPlan(session),
                        written == Int(LIBSSH2_ERROR_EAGAIN) && transportSendOwner == owner
                    )
                    releaseOperation()
                } catch {
                    let normalized = normalize(error)
                    await finishOwnedSendIfNeeded(owner: owner) {
                        writeChannelOnce(identity: .streamLocal(id), data: data, offset: offset)
                    }
                    releaseOperation()
                    throw normalized
                }

                if progress.written > 0 {
                    offset += progress.written
                    await Task.yield()
                } else {
                    #if DEBUG
                    if progress.parkedOutbound {
                        await holdOutboundWriteParkForTestingIfNeeded()
                    }
                    #endif
                    do {
                        try await awaitSessionProgress(progress.wait, until: deadline)
                    } catch {
                        await acquireOperation()
                        await finishOwnedSendIfNeeded(owner: owner) {
                            writeChannelOnce(identity: .streamLocal(id), data: data, offset: offset)
                        }
                        releaseOperation()
                        throw normalize(error)
                    }
                }
            }
        }
    }

    func readStreamLocal(
        id: UInt64,
        maximumBytes: Int,
        timeout: Duration
    ) async throws -> Data? {
        try await withDiagnosticPhase("stream-local read channel \(id)") {
            guard maximumBytes > 0 else { throw SSHError.channelFailed }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            let owner = allocateTransportSendOwner()

            while true {
                await acquireOperation()
                let progress: (data: Data, eof: Bool, wait: SessionWaitPlan)
                do {
                    try checkProgress(deadline: deadline)
                    try await waitForTransportSendAdmission(
                        owner: owner,
                        deadline: deadline,
                        cancellable: true)
                    let session = try requireSession()
                    let channel = try resolveChannel(.streamLocal(id))
                    var buffer = [UInt8](repeating: 0, count: maximumBytes)
                    let data = try readAvailableNoting(
                        channel: channel,
                        stream: 0,
                        buffer: &buffer,
                        owner: owner,
                        session: session)
                    progress = (
                        data,
                        libssh2_channel_eof(channel) == 1,
                        sessionWaitPlan(session)
                    )
                    releaseOperation()
                } catch {
                    await finishOwnedSendIfNeeded(owner: owner) {
                        guard let channel = try? resolveChannel(.streamLocal(id)) else { return nil }
                        var scratch = [UInt8](repeating: 0, count: maximumBytes)
                        return readOnce(channel: channel, stream: 0, buffer: &scratch)
                    }
                    releaseOperation()
                    throw normalize(error)
                }

                if !progress.data.isEmpty { return progress.data }
                if progress.eof { return nil }
                do {
                    try await awaitSessionProgress(progress.wait, until: deadline)
                } catch {
                    await acquireOperation()
                    await finishOwnedSendIfNeeded(owner: owner) {
                        guard let channel = try? resolveChannel(.streamLocal(id)) else { return nil }
                        var scratch = [UInt8](repeating: 0, count: maximumBytes)
                        return readOnce(channel: channel, stream: 0, buffer: &scratch)
                    }
                    releaseOperation()
                    throw normalize(error)
                }
            }
        }
    }

    func closeStreamLocal(id: UInt64, timeout: Duration) async throws {
        try await withDiagnosticPhase("stream-local close channel \(id)") {
            await acquireOperation()
            defer { releaseOperation() }

            guard var state = streamLocalChannels[id] else { return }
            guard valid, session != nil else {
                streamLocalChannels.removeValue(forKey: id)
                return
            }
            guard !state.teardownInProgress else { return }
            state.acceptsIO = false
            state.teardownInProgress = true
            streamLocalChannels[id] = state
            #if DEBUG
            await holdChannelTeardownForTestingIfNeeded()
            #endif
            do {
                try await cleanChannel(
                    identity: .streamLocal(id),
                    deadline: ContinuousClock.now.advanced(by: timeout),
                    cancellable: false,
                    allowClosing: true)
                streamLocalChannels.removeValue(forKey: id)
            } catch {
                streamLocalChannels.removeValue(forKey: id)
                throw teardownFailure(error)
            }
        }
    }

    func openSFTP(timeout: Duration) async throws -> SSHSFTPClient {
        try await withDiagnosticPhase("SFTP open") {
            await acquireOperation()
            defer { releaseOperation() }

            guard valid, !forwarding, authenticated, session != nil else {
                throw SSHError.connectionInvalidated
            }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            do {
                try await claimChannelOpenSlot(.stock, deadline: deadline, cancellable: true)
            } catch {
                // No init has started, so the session is untouched.
                throw normalize(error)
            }
            // SFTP init opens its channel through the session's one stock
            // channel-open state (`open_state`), so it is the single stock
            // open in flight. Pipelined opens keep theirs on their own
            // channels and may be awaiting replies meanwhile; patch 0003
            // leaves their replies queued while init reads for its own.
            defer { releaseChannelOpenSlot(.stock) }
            var initWasPending = false
            let owner = allocateTransportSendOwner()

            do {
                while true {
                    try checkProgress(deadline: deadline)
                    try await waitForTransportSendAdmission(
                        owner: owner,
                        deadline: deadline,
                        cancellable: true)
                    #if DEBUG
                    if shouldFailNextSFTPInitBeforeEAGAINForTesting {
                        shouldFailNextSFTPInitBeforeEAGAINForTesting = false
                        throw SSHError.sftpUnavailable
                    }
                    #endif
                    let session = try requireSession()
                    if let sftp = libssh2_sftp_init(session) {
                        let disposition = notePacketProducingResult(
                            0,
                            owner: owner,
                            session: session)
                        applyTransportSendOwnerDisposition(disposition)
                        nextSFTPID &+= 1
                        let id = nextSFTPID
                        sftpClients[id] = SFTPState(handle: sftp)
                        return SSHSFTPClient(id: id, driver: self)
                    }
                    let error = libssh2_session_last_errno(session)
                    let disposition = notePacketProducingResult(
                        error,
                        owner: owner,
                        session: session)
                    applyTransportSendOwnerDisposition(disposition)
                    if error == LIBSSH2_ERROR_EAGAIN {
                        initWasPending = true
                        try await waitForSession(session, deadline: deadline)
                    } else if Self.isConnectionLoss(error) {
                        throw SSHError.connectionInvalidated
                    } else {
                        throw SSHError.sftpUnavailable
                    }
                }
            } catch {
                if transportSendOwner == owner { invalidateResources() }
                let normalized = normalize(error)
                // libssh2 1.11.1 keeps one in-progress SFTP-init state per session,
                // including its channel and allocation. Any failure after EAGAIN
                // may abandon that state, and a later init would resume it; only
                // session teardown can safely discard it. Before the first init
                // call (or after an ordinary non-EAGAIN failure), there is no
                // native init state to reclaim and the session remains reusable.
                if initWasPending || normalized == .connectionInvalidated {
                    invalidateResources()
                }
                throw normalized
            }
        }
    }

    func createSFTPDirectory(
        id: UInt64,
        path: String,
        permissions: UInt32,
        timeout: Duration
    ) async throws {
        try await withDiagnosticPhase("SFTP create directory") {
            guard Self.isValidSFTPPath(path), Self.isValidPermissions(permissions) else {
                throw SSHError.channelFailed
            }
            await acquireOperation()
            defer { releaseOperation() }
            let result = try await repeatUntilCompleteHoldingSFTP(
                id: id,
                deadline: ContinuousClock.now.advanced(by: timeout)
            ) { sftp in
                path.withCString { pathPointer in
                    libssh2_sftp_mkdir_ex(
                        sftp,
                        pathPointer,
                        UInt32(path.utf8.count),
                        Int(permissions))
                }
            }
            try checkSFTPResult(result, sftpID: id)
        }
    }

    func sftpAttributes(
        id: UInt64,
        path: String,
        timeout: Duration
    ) async throws -> SSHSFTPAttributes {
        try await withDiagnosticPhase("SFTP attributes") {
            let attributes = try await sftpRawAttributes(id: id, path: path, timeout: timeout)
            let hasSize = attributes.flags & UInt(LIBSSH2_SFTP_ATTR_SIZE) != 0
            let hasPermissions = attributes.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0
            return SSHSFTPAttributes(
                size: hasSize ? attributes.filesize : nil,
                permissions: hasPermissions
                    ? UInt32(truncatingIfNeeded: attributes.permissions) & 0o777
                    : nil)
        }
    }

    func setSFTPPermissions(
        id: UInt64,
        path: String,
        permissions: UInt32,
        timeout: Duration
    ) async throws {
        try await withDiagnosticPhase("SFTP set permissions") {
            guard Self.isValidSFTPPath(path), Self.isValidPermissions(permissions) else {
                throw SSHError.channelFailed
            }
            await acquireOperation()
            defer { releaseOperation() }
            var attributes = LIBSSH2_SFTP_ATTRIBUTES()
            attributes.flags = UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS)
            attributes.permissions = UInt(permissions)
            let result = try await repeatUntilCompleteHoldingSFTP(
                id: id,
                deadline: ContinuousClock.now.advanced(by: timeout)
            ) { sftp in
                path.withCString { pathPointer in
                    libssh2_sftp_stat_ex(
                        sftp,
                        pathPointer,
                        UInt32(path.utf8.count),
                        Int32(LIBSSH2_SFTP_SETSTAT),
                        &attributes)
                }
            }
            try checkSFTPResult(result, sftpID: id)
        }
    }

    func readSFTPFileIfPresent(
        id: UInt64,
        path: String,
        timeout: Duration
    ) async throws -> Data? {
        try await withDiagnosticPhase("SFTP read file") {
            guard Self.isValidSFTPPath(path) else { throw SSHError.channelFailed }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            return try await withSFTPUse(id: id, deadline: deadline) {
                guard
                    let fileID = try await openSFTPFileForReadingIfPresent(
                        sftpID: id,
                        path: path,
                        deadline: deadline)
                else { return nil }

                do {
                    var contents = Data()
                    while let chunk = try await readSFTPFileChunk(
                        sftpID: id,
                        fileID: fileID,
                        deadline: deadline)
                    {
                        contents.append(chunk)
                    }
                    try await closeSFTPFileWithinUse(
                        sftpID: id,
                        fileID: fileID,
                        timeout: timeout)
                    return contents
                } catch {
                    try? await closeSFTPFileWithinUse(
                        sftpID: id,
                        fileID: fileID,
                        timeout: .seconds(2))
                    throw normalize(error)
                }
            }
        }
    }

    /// Reads up to `maxBytes` starting at `offset`, so a follower of a file
    /// that only ever grows can ask for the tail it has not folded yet.
    ///
    /// `length` is the file's own reported size, and `nil` only when the file
    /// is absent — the follower's signal to drop what it had. It is the raw
    /// size rather than the byte count this call happened to read, because a
    /// follower compares it against its own offset to notice that the path now
    /// holds a different, shorter file; reporting the read count instead would
    /// hide exactly that case.
    func readSFTPFileRange(
        id: UInt64,
        path: String,
        offset: UInt64,
        maxBytes: Int,
        timeout: Duration
    ) async throws -> SSHSFTPFileSlice {
        try await withDiagnosticPhase("SFTP read file range") {
            guard Self.isValidSFTPPath(path), maxBytes >= 0 else { throw SSHError.channelFailed }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            return try await withSFTPUse(id: id, deadline: deadline) {
                // Asked for by path inside the read's own use, so a stat this
                // read abandons is reclaimed with it (`withSFTPUse`).
                let reportedSize: UInt64?
                do {
                    let attributes = try await sftpRawAttributesWithinUse(
                        sftpID: id,
                        path: path,
                        deadline: deadline)
                    reportedSize = attributes.flags & UInt(LIBSSH2_SFTP_ATTR_SIZE) != 0
                        ? attributes.filesize : nil
                } catch SSHError.sftpFailure(let status)
                    where status == UInt64(LIBSSH2_FX_NO_SUCH_FILE)
                {
                    // A file that is not there is an answer, not a failure: it
                    // is how the follower learns to stop showing figures
                    // nothing backs.
                    return SSHSFTPFileSlice(data: Data(), length: nil)
                }

                let readDeadline = ContinuousClock.now.advanced(by: timeout)
                guard
                    let fileID = try await openSFTPFileForReadingIfPresent(
                        sftpID: id,
                        path: path,
                        deadline: readDeadline)
                else {
                    // Gone between the size check and the open.
                    return SSHSFTPFileSlice(data: Data(), length: nil)
                }

                let data: Data
                do {
                    if offset > 0 {
                        try await seekSFTPFileToStart(sftpID: id, fileID: fileID, offset: offset)
                    }
                    var contents = Data()
                    while contents.count < maxBytes {
                        guard
                            let chunk = try await readSFTPFileChunk(
                                sftpID: id,
                                fileID: fileID,
                                deadline: readDeadline)
                        else { break }
                        contents.append(chunk.prefix(maxBytes - contents.count))
                    }
                    try await closeSFTPFileWithinUse(
                        sftpID: id,
                        fileID: fileID,
                        timeout: timeout)
                    data = contents
                } catch {
                    try? await closeSFTPFileWithinUse(
                        sftpID: id,
                        fileID: fileID,
                        timeout: .seconds(2))
                    throw normalize(error)
                }
                // A server that reports no size at all leaves the bytes read as
                // the only floor available.
                return SSHSFTPFileSlice(
                    data: data,
                    length: reportedSize ?? offset + UInt64(data.count))
            }
        }
    }

    /// `stat` by path (symlinks followed), unmasked.
    private func sftpRawAttributes(
        id: UInt64,
        path: String,
        timeout: Duration
    ) async throws -> LIBSSH2_SFTP_ATTRIBUTES {
        guard Self.isValidSFTPPath(path) else { throw SSHError.channelFailed }
        await acquireOperation()
        defer { releaseOperation() }
        var attributes = LIBSSH2_SFTP_ATTRIBUTES()
        let result = try await repeatUntilCompleteHoldingSFTP(
            id: id,
            deadline: ContinuousClock.now.advanced(by: timeout)
        ) { sftp in
            path.withCString { pathPointer in
                libssh2_sftp_stat_ex(
                    sftp,
                    pathPointer,
                    UInt32(path.utf8.count),
                    Int32(LIBSSH2_SFTP_STAT),
                    &attributes)
            }
        }
        try checkSFTPResult(result, sftpID: id)
        return attributes
    }

    /// Reads one whole regular file of at most `maxBytes`, or says why not.
    ///
    /// The path is stat-ed first so a directory, FIFO, or device is refused
    /// before anything opens it; then it is opened once, the open handle is
    /// `fstat`-ed so the file read is the file checked, and every chunk comes
    /// from that one handle. A file that grows past the limit while it is
    /// read is refused too.
    ///
    /// `timeout` bounds each request: the stat, the open and `fstat`, and the
    /// wait for every next chunk. The transfer as a whole is bounded by
    /// `regularFileTransferBudget`, so a large file that keeps arriving is not
    /// cut off by a budget sized for one round trip.
    func readSFTPRegularFile(
        id: UInt64,
        path: String,
        maxBytes: Int,
        timeout: Duration
    ) async throws -> SSHSFTPRegularFileRead {
        try await withDiagnosticPhase("SFTP read regular file") {
            guard Self.isValidSFTPPath(path), maxBytes >= 0 else { throw SSHError.channelFailed }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            return try await withSFTPUse(id: id, deadline: deadline) {
                let byPath: LIBSSH2_SFTP_ATTRIBUTES
                do {
                    byPath = try await sftpRawAttributesWithinUse(
                        sftpID: id,
                        path: path,
                        deadline: deadline)
                } catch SSHError.sftpFailure(let status) {
                    if let refusal = Self.regularFileRefusal(status: status) { return refusal }
                    throw SSHError.sftpFailure(status: status)
                }
                if let refusal = Self.regularFileRefusal(byPath, maxBytes: maxBytes) {
                    return refusal
                }

                let requestDeadline = ContinuousClock.now.advanced(by: timeout)
                let opened: UInt64?
                do {
                    opened = try await openSFTPFileForReadingIfPresent(
                        sftpID: id,
                        path: path,
                        deadline: requestDeadline)
                } catch SSHError.sftpFailure(let status) {
                    if let refusal = Self.regularFileRefusal(status: status) { return refusal }
                    throw SSHError.sftpFailure(status: status)
                }
                guard let fileID = opened else { return .missing }
                do {
                    let byHandle = try await fstatSFTPFileWithinUse(
                        sftpID: id,
                        fileID: fileID,
                        deadline: requestDeadline)
                    var result: SSHSFTPRegularFileRead
                    if let refusal = Self.regularFileRefusal(byHandle, maxBytes: maxBytes) {
                        result = refusal
                    } else {
                        let transferDeadline = ContinuousClock.now.advanced(
                            by: Self.regularFileTransferBudget(
                                size: byHandle.filesize,
                                requestTimeout: timeout))
                        var contents = Data()
                        contents.reserveCapacity(Int(clamping: byHandle.filesize))
                        // Each chunk gets `timeout` from the one before it.
                        while contents.count <= maxBytes,
                            let chunk = try await readSFTPFileChunk(
                                sftpID: id,
                                fileID: fileID,
                                deadline: min(
                                    ContinuousClock.now.advanced(by: timeout),
                                    transferDeadline))
                        {
                            contents.append(chunk)
                        }
                        result = contents.count > maxBytes
                            ? .tooLarge(size: UInt64(contents.count))
                            : .contents(contents)
                    }
                    try await closeSFTPFileWithinUse(
                        sftpID: id,
                        fileID: fileID,
                        timeout: timeout)
                    return result
                } catch {
                    try? await closeSFTPFileWithinUse(
                        sftpID: id,
                        fileID: fileID,
                        timeout: .seconds(2))
                    throw normalize(error)
                }
            }
        }
    }

    private static func regularFileRefusal(status: UInt64) -> SSHSFTPRegularFileRead? {
        switch status {
        case UInt64(LIBSSH2_FX_NO_SUCH_FILE): .missing
        case UInt64(LIBSSH2_FX_PERMISSION_DENIED): .permissionDenied
        default: nil
        }
    }

    private static func regularFileRefusal(
        _ attributes: LIBSSH2_SFTP_ATTRIBUTES,
        maxBytes: Int
    ) -> SSHSFTPRegularFileRead? {
        // A server that reports no type or no size cannot prove the file is
        // safe to open or small enough to read.
        guard attributes.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0,
            attributes.flags & UInt(LIBSSH2_SFTP_ATTR_SIZE) != 0
        else { return .notRegularFile }
        switch attributes.permissions & UInt(LIBSSH2_SFTP_S_IFMT) {
        case UInt(LIBSSH2_SFTP_S_IFREG):
            break
        case UInt(LIBSSH2_SFTP_S_IFDIR):
            return .directory
        default:
            return .notRegularFile
        }
        guard attributes.filesize <= UInt64(maxBytes) else {
            return .tooLarge(size: attributes.filesize)
        }
        return nil
    }

    /// About 1 Mbit/s: the slowest link a whole-file read is sized for.
    private static let regularFileMinimumBytesPerSecond = 128 * 1_024
    private static let regularFileTransferCeiling: Duration = .seconds(300)

    /// How long a whole-file read of `size` bytes may take once `fstat` has
    /// reported that size. Every chunk already has to arrive within
    /// `requestTimeout` of the one before, so this only ends a transfer that
    /// keeps trickling: one request's time plus `size` at
    /// `regularFileMinimumBytesPerSecond`, never more than
    /// `regularFileTransferCeiling`.
    private static func regularFileTransferBudget(
        size: UInt64,
        requestTimeout: Duration
    ) -> Duration {
        let transfer = Duration.seconds(
            Double(size) / Double(regularFileMinimumBytesPerSecond))
        return min(requestTimeout + transfer, max(requestTimeout, regularFileTransferCeiling))
    }

    /// `fstat` on an open read handle, inside the caller's SFTP use.
    private func fstatSFTPFileWithinUse(
        sftpID: UInt64,
        fileID: UInt64,
        deadline: ContinuousClock.Instant
    ) async throws -> LIBSSH2_SFTP_ATTRIBUTES {
        await acquireOperation()
        defer { releaseOperation() }
        guard valid, session != nil, let file = sftpClients[sftpID]?.files[fileID] else {
            throw SSHError.connectionInvalidated
        }
        try await waitForTransportSendAdmission(
            owner: allocateTransportSendOwner(),
            deadline: deadline,
            cancellable: true)
        var attributes = LIBSSH2_SFTP_ATTRIBUTES()
        let result = try await repeatUntilCompleteHolding(deadline: deadline) {
            libssh2_sftp_fstat_ex(file, &attributes, 0)
        }
        try checkSFTPResult(result, sftpID: sftpID)
        return attributes
    }

    /// `stat` by path (symlinks followed), unmasked, inside the caller's SFTP
    /// use: the path counterpart of `fstatSFTPFileWithinUse`.
    private func sftpRawAttributesWithinUse(
        sftpID: UInt64,
        path: String,
        deadline: ContinuousClock.Instant
    ) async throws -> LIBSSH2_SFTP_ATTRIBUTES {
        await acquireOperation()
        defer { releaseOperation() }
        guard valid, session != nil, let sftp = sftpClients[sftpID]?.handle else {
            throw SSHError.connectionInvalidated
        }
        try await waitForTransportSendAdmission(
            owner: allocateTransportSendOwner(),
            deadline: deadline,
            cancellable: true)
        var attributes = LIBSSH2_SFTP_ATTRIBUTES()
        let result = try await repeatUntilCompleteHolding(deadline: deadline) {
            path.withCString { pathPointer in
                libssh2_sftp_stat_ex(
                    sftp,
                    pathPointer,
                    UInt32(path.utf8.count),
                    Int32(LIBSSH2_SFTP_STAT),
                    &attributes)
            }
        }
        try checkSFTPResult(result, sftpID: sftpID)
        return attributes
    }

    /// Moves an open read handle to `offset`. Local to the handle — the next
    /// read is what travels — so it takes no send admission of its own.
    private func seekSFTPFileToStart(
        sftpID: UInt64,
        fileID: UInt64,
        offset: UInt64
    ) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        guard valid, let state = sftpClients[sftpID], let file = state.files[fileID] else {
            throw SSHError.connectionInvalidated
        }
        libssh2_sftp_seek64(file, offset)
    }

    private func openSFTPFileForReadingIfPresent(
        sftpID: UInt64,
        path: String,
        deadline: ContinuousClock.Instant
    ) async throws -> UInt64? {
        await acquireOperation()
        defer { releaseOperation() }
        guard valid, session != nil, sftpClients[sftpID]?.handle != nil else {
            throw SSHError.connectionInvalidated
        }
        let owner = allocateTransportSendOwner()

        do {
        while true {
            try checkProgress(deadline: deadline)
            try await waitForTransportSendAdmission(
                owner: owner,
                deadline: deadline,
                cancellable: true)
            let session = try requireSession()
            guard let sftp = sftpClients[sftpID]?.handle else {
                throw SSHError.connectionInvalidated
            }
            let file = path.withCString { pathPointer in
                libssh2_sftp_open_ex(
                    sftp,
                    pathPointer,
                    UInt32(path.utf8.count),
                    UInt(LIBSSH2_FXF_READ),
                    0,
                    Int32(LIBSSH2_SFTP_OPENFILE))
            }
            if let file {
                let disposition = notePacketProducingResult(
                    0,
                    owner: owner,
                    session: session)
                applyTransportSendOwnerDisposition(disposition)
                nextSFTPFileID &+= 1
                let fileID = nextSFTPFileID
                sftpClients[sftpID]?.files[fileID] = file
                return fileID
            }

            let error = libssh2_session_last_errno(session)
            let disposition = notePacketProducingResult(
                error,
                owner: owner,
                session: session)
            if error == LIBSSH2_ERROR_EAGAIN {
                try await waitForSession(session, deadline: deadline)
                continue
            }
            if Self.isConnectionLoss(error) {
                invalidateResources()
                throw SSHError.connectionInvalidated
            }
            let status = UInt64(libssh2_sftp_last_error(sftp))
            applyTransportSendOwnerDisposition(disposition)
            if disposition == .invalidate { throw SSHError.connectionInvalidated }
            if status == UInt64(LIBSSH2_FX_NO_SUCH_FILE) { return nil }
            throw SSHError.sftpFailure(status: status)
        }
        } catch {
            if transportSendOwner == owner { invalidateResources() }
            throw error
        }
    }

    private func readSFTPFileChunk(
        sftpID: UInt64,
        fileID: UInt64,
        deadline: ContinuousClock.Instant
    ) async throws -> Data? {
        let maximumChunkBytes = 64 * 1_024
        let owner = allocateTransportSendOwner()

        while true {
            await acquireOperation()
            let progress: (data: Data, reachedEOF: Bool, wait: SessionWaitPlan)
            do {
                try checkProgress(deadline: deadline)
                try await waitForTransportSendAdmission(
                    owner: owner,
                    deadline: deadline,
                    cancellable: true)
                guard
                    valid,
                    let session,
                    let state = sftpClients[sftpID],
                    let file = state.files[fileID]
                else {
                    throw SSHError.connectionInvalidated
                }
                var buffer = [UInt8](repeating: 0, count: maximumChunkBytes)
                let read = buffer.withUnsafeMutableBytes { bytes -> Int in
                    guard let baseAddress = bytes.baseAddress else { return 0 }
                    return libssh2_sftp_read(
                        file,
                        baseAddress.assumingMemoryBound(to: CChar.self),
                        bytes.count)
                }
                let disposition = notePacketProducingWrite(
                    read,
                    owner: owner,
                    session: session)
                if read < 0, read != Int(LIBSSH2_ERROR_EAGAIN) {
                    let mappedError = mappedSFTPError(
                        sftp: state.handle,
                        code: Int32(read))
                    applyTransportSendOwnerDisposition(disposition)
                    throw mappedError
                }
                applyTransportSendOwnerDisposition(disposition)
                progress = (
                    read > 0 ? Data(buffer.prefix(read)) : Data(),
                    read == 0,
                    sessionWaitPlan(session))
                releaseOperation()
            } catch {
                let normalized = normalize(error)
                if normalized == .connectionInvalidated { invalidateResources() }
                await finishOwnedSendIfNeeded(owner: owner) {
                    readSFTPOnce(sftpID: sftpID, fileID: fileID)
                }
                releaseOperation()
                throw normalized
            }

            if !progress.data.isEmpty { return progress.data }
            if progress.reachedEOF { return nil }
            do {
                try await awaitSessionProgress(progress.wait, until: deadline)
            } catch {
                let normalized = normalize(error)
                if normalized == .connectionInvalidated { invalidateResources() }
                await acquireOperation()
                await finishOwnedSendIfNeeded(owner: owner) {
                    readSFTPOnce(sftpID: sftpID, fileID: fileID)
                }
                releaseOperation()
                throw normalized
            }
        }
    }

    /// Lists the directories directly inside one remote directory, sorted by
    /// name. Regular files are dropped, `.` and `..` are dropped, and the
    /// result is capped at `SSHSFTPDirectoryListing.maximumEntries` with
    /// `truncated` set when more directories exist. A missing directory
    /// surfaces as `SSHError.sftpFailure`; every other failure maps the same
    /// way file-operation failures do.
    func listSFTPDirectories(
        id: UInt64,
        path: String,
        timeout: Duration
    ) async throws -> SSHSFTPDirectoryListing {
        try await withDiagnosticPhase("SFTP list directories") {
            guard Self.isValidSFTPPath(path) else { throw SSHError.channelFailed }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            return try await withSFTPUse(id: id, deadline: deadline) {
                guard
                    let dirID = try await openSFTPDirIfPresent(
                        sftpID: id,
                        path: path,
                        deadline: deadline)
                else {
                    throw SSHError.sftpFailure(
                        status: UInt64(LIBSSH2_FX_NO_SUCH_FILE))
                }
                do {
                    var rawEntries: [(name: String, isDirectory: Bool)] = []
                    while let entry = try await readSFTPDirEntry(
                        sftpID: id,
                        fileID: dirID,
                        deadline: deadline)
                    {
                        rawEntries.append((entry.name, entry.isDirectory))
                    }
                    try await closeSFTPFileWithinUse(
                        sftpID: id,
                        fileID: dirID,
                        timeout: timeout)
                    return SSHSFTPDirectoryListing(rawEntries: rawEntries)
                } catch {
                    try? await closeSFTPFileWithinUse(
                        sftpID: id,
                        fileID: dirID,
                        timeout: .seconds(2))
                    throw normalize(error)
                }
            }
        }
    }

    private func openSFTPDirIfPresent(
        sftpID: UInt64,
        path: String,
        deadline: ContinuousClock.Instant
    ) async throws -> UInt64? {
        let owner = allocateTransportSendOwner()
        await acquireOperation()
        defer { releaseOperation() }
        do {
        while true {
            try checkProgress(deadline: deadline)
            try await waitForTransportSendAdmission(
                owner: owner,
                deadline: deadline,
                cancellable: true)
            let session = try requireSession()
            guard let sftp = sftpClients[sftpID]?.handle else {
                throw SSHError.connectionInvalidated
            }
            let dir = path.withCString { pathPointer in
                libssh2_sftp_open_ex(
                    sftp,
                    pathPointer,
                    UInt32(path.utf8.count),
                    0,
                    0,
                    Int32(LIBSSH2_SFTP_OPENDIR))
            }
            if let dir {
                let disposition = notePacketProducingResult(
                    0,
                    owner: owner,
                    session: session)
                applyTransportSendOwnerDisposition(disposition)
                nextSFTPFileID &+= 1
                let fileID = nextSFTPFileID
                sftpClients[sftpID]?.files[fileID] = dir
                return fileID
            }
            let error = libssh2_session_last_errno(session)
            let disposition = notePacketProducingResult(
                error,
                owner: owner,
                session: session)
            if error == LIBSSH2_ERROR_EAGAIN {
                try await waitForSession(session, deadline: deadline)
                continue
            }
            if Self.isConnectionLoss(error) {
                invalidateResources()
                throw SSHError.connectionInvalidated
            }
            let status = UInt64(libssh2_sftp_last_error(sftp))
            applyTransportSendOwnerDisposition(disposition)
            if disposition == .invalidate { throw SSHError.connectionInvalidated }
            if status == UInt64(LIBSSH2_FX_NO_SUCH_FILE) { return nil }
            throw SSHError.sftpFailure(status: status)
        }
        } catch {
            if transportSendOwner == owner { invalidateResources() }
            throw error
        }
    }

    /// Reads one readdir entry from an open directory handle. Returns `nil`
    /// at end of directory.
    private func readSFTPDirEntry(
        sftpID: UInt64,
        fileID: UInt64,
        deadline: ContinuousClock.Instant
    ) async throws -> SSHSFTPDirectoryEntry? {
        let owner = allocateTransportSendOwner()
        await acquireOperation()
        defer { releaseOperation() }
        do {
        while true {
            try checkProgress(deadline: deadline)
            try await waitForTransportSendAdmission(
                owner: owner,
                deadline: deadline,
                cancellable: true)
            let session = try requireSession()
            guard
                let state = sftpClients[sftpID],
                let dir = state.files[fileID]
            else {
                throw SSHError.connectionInvalidated
            }
            var nameBuffer = [CChar](repeating: 0, count: 512)
            var longBuffer = [CChar](repeating: 0, count: 512)
            var attributes = LIBSSH2_SFTP_ATTRIBUTES()
            let count: Int32 = nameBuffer.withUnsafeMutableBufferPointer {
                namePointer in
                longBuffer.withUnsafeMutableBufferPointer { longPointer in
                    withUnsafeMutablePointer(to: &attributes) {
                        attributesPointer in
                        libssh2_sftp_readdir_ex(
                            dir,
                            namePointer.baseAddress,
                            namePointer.count,
                            longPointer.baseAddress,
                            longPointer.count,
                            attributesPointer)
                    }
                }
            }
            if count == LIBSSH2_ERROR_EAGAIN {
                let disposition = notePacketProducingResult(
                    count,
                    owner: owner,
                    session: session)
                applyTransportSendOwnerDisposition(disposition)
                try await waitForSession(session, deadline: deadline)
                continue
            }
            if count < 0 {
                let error = libssh2_session_last_errno(session)
                let disposition = notePacketProducingResult(
                    count,
                    owner: owner,
                    session: session)
                if Self.isConnectionLoss(error) {
                    invalidateResources()
                    throw SSHError.connectionInvalidated
                }
                let status = UInt64(libssh2_sftp_last_error(state.handle))
                applyTransportSendOwnerDisposition(disposition)
                if disposition == .invalidate {
                    throw SSHError.connectionInvalidated
                }
                throw SSHError.sftpFailure(status: status)
            }
            let disposition = notePacketProducingResult(
                0,
                owner: owner,
                session: session)
            applyTransportSendOwnerDisposition(disposition)
            if count == 0 { return nil }
            let nameBytes = nameBuffer.prefix(Int(count)).map {
                UInt8(bitPattern: $0)
            }
            let nameData = Data(nameBytes)
            let name =
                String(data: nameData, encoding: .utf8)
                ?? String(decoding: nameData, as: UTF8.self)
            return SSHSFTPDirectoryEntry(
                name: name,
                isDirectory: isSFTPDirectory(
                    attributes: attributes,
                    longEntry: longBuffer))
        }
        } catch {
            if transportSendOwner == owner { invalidateResources() }
            throw error
        }
    }

    /// Directory test for one readdir entry. SFTP servers normally fill in
    /// the permissions bits; when they do not, fall back to the `ls -l`
    /// style long entry, whose first character is `d` for directories.
    private func isSFTPDirectory(
        attributes: LIBSSH2_SFTP_ATTRIBUTES,
        longEntry: [CChar]
    ) -> Bool {
        if attributes.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0 {
            return attributes.permissions & UInt(LIBSSH2_SFTP_S_IFMT)
                == UInt(LIBSSH2_SFTP_S_IFDIR)
        }
        return longEntry.first == CChar(UInt8(ascii: "d"))
    }

    func openSFTPFileForWriting(
        sftpID: UInt64,
        path: String,
        permissions: UInt32,
        timeout: Duration
    ) async throws -> SSHSFTPFile {
        try await withDiagnosticPhase("SFTP open file") {
            guard Self.isValidSFTPPath(path), Self.isValidPermissions(permissions) else {
                throw SSHError.channelFailed
            }
            await acquireOperation()
            defer { releaseOperation() }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            guard valid, session != nil else { throw SSHError.connectionInvalidated }
            guard sftpClients[sftpID]?.handle != nil else { throw SSHError.channelFailed }
            try await waitUntilSFTPIdle(
                id: sftpID,
                deadline: deadline,
                cancellable: true)
            try beginSFTPUse(sftpID)
            defer { endSFTPUse(sftpID) }
            let flags = UInt(
                LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC | LIBSSH2_FXF_EXCL)
            let owner = allocateTransportSendOwner()

            do {
                while true {
                    try checkProgress(deadline: deadline)
                    try await waitForTransportSendAdmission(
                        owner: owner,
                        deadline: deadline,
                        cancellable: true)
                    let session = try requireSession()
                    guard let sftp = sftpClients[sftpID]?.handle else {
                        throw SSHError.connectionInvalidated
                    }
                    let file = path.withCString { pathPointer in
                        libssh2_sftp_open_ex(
                            sftp,
                            pathPointer,
                            UInt32(path.utf8.count),
                            flags,
                            Int(permissions),
                            Int32(LIBSSH2_SFTP_OPENFILE))
                    }
                    if let file {
                        let disposition = notePacketProducingResult(
                            0,
                            owner: owner,
                            session: session)
                        applyTransportSendOwnerDisposition(disposition)
                        nextSFTPFileID &+= 1
                        let fileID = nextSFTPFileID
                        sftpClients[sftpID]?.files[fileID] = file
                        return SSHSFTPFile(sftpID: sftpID, fileID: fileID, driver: self)
                    }
                    let error = libssh2_session_last_errno(session)
                    let disposition = notePacketProducingResult(
                        error,
                        owner: owner,
                        session: session)
                    if error == LIBSSH2_ERROR_EAGAIN {
                        try await waitForSession(session, deadline: deadline)
                    } else {
                        let mappedError = mappedSFTPError(sftp: sftp, code: error)
                        applyTransportSendOwnerDisposition(disposition)
                        throw mappedError
                    }
                }
            } catch {
                if transportSendOwner == owner { invalidateResources() }
                throw error
            }
        }
    }

    func writeSFTPFile(
        sftpID: UInt64,
        fileID: UInt64,
        data: Data,
        timeout: Duration
    ) async throws {
        try await withDiagnosticPhase("SFTP write file \(fileID)") {
            guard !data.isEmpty else { return }
            #if DEBUG
            if let delay = nextSFTPWriteDelayForTesting {
                nextSFTPWriteDelayForTesting = nil
                sftpWriteDelayIsActiveForTesting = true
                do {
                    try await Task.sleep(for: delay)
                    sftpWriteDelayIsActiveForTesting = false
                } catch {
                    sftpWriteDelayIsActiveForTesting = false
                    throw error
                }
            }
            #endif
            let deadline = ContinuousClock.now.advanced(by: timeout)
            try await withSFTPUse(id: sftpID, deadline: deadline, reclaimOnInterruption: false) {
                var offset = 0
                let owner = allocateTransportSendOwner()

                while offset < data.count {
                    await acquireOperation()
                    let progress: (written: Int, wait: SessionWaitPlan, parkedOutbound: Bool)
                    do {
                        try checkProgress(deadline: deadline)
                        try await waitForTransportSendAdmission(
                            owner: owner,
                            deadline: deadline,
                            cancellable: true)
                        guard
                            valid,
                            let session,
                            let state = sftpClients[sftpID],
                            let file = state.files[fileID]
                        else {
                            throw SSHError.connectionInvalidated
                        }
                        let written = data.withUnsafeBytes { bytes -> Int in
                            guard let baseAddress = bytes.baseAddress else { return 0 }
                            return libssh2_sftp_write(
                                file,
                                baseAddress.advanced(by: offset).assumingMemoryBound(to: CChar.self),
                                data.count - offset)
                        }
                        let disposition = notePacketProducingWrite(
                            written,
                            owner: owner,
                            session: session)
                        if written < 0, written != Int(LIBSSH2_ERROR_EAGAIN) {
                            let mappedError = mappedSFTPError(
                                sftp: state.handle,
                                code: Int32(written))
                            applyTransportSendOwnerDisposition(disposition)
                            throw mappedError
                        }
                        applyTransportSendOwnerDisposition(disposition)
                        progress = (
                            written,
                            sessionWaitPlan(session),
                            written == Int(LIBSSH2_ERROR_EAGAIN)
                        )
                        releaseOperation()
                    } catch {
                        let normalized = normalize(error)
                        if normalized == .connectionInvalidated { invalidateResources() }
                        await finishOwnedSendIfNeeded(owner: owner) {
                            writeSFTPOnce(sftpID: sftpID, fileID: fileID, data: data, offset: offset)
                        }
                        releaseOperation()
                        throw normalized
                    }

                    if progress.written > 0 {
                        offset += progress.written
                        await Task.yield()
                    } else {
                        #if DEBUG
                        if progress.parkedOutbound {
                            await holdOutboundWriteParkForTestingIfNeeded()
                        }
                        #endif
                        do {
                            try await awaitSessionProgress(progress.wait, until: deadline)
                        } catch {
                            let normalized = normalize(error)
                            if normalized == .connectionInvalidated { invalidateResources() }
                            await acquireOperation()
                            await finishOwnedSendIfNeeded(owner: owner) {
                                writeSFTPOnce(sftpID: sftpID, fileID: fileID, data: data, offset: offset)
                            }
                            releaseOperation()
                            throw normalized
                        }
                    }
                }
            }
        }
    }

    func closeSFTPFile(
        sftpID: UInt64,
        fileID: UInt64,
        timeout: Duration
    ) async throws {
        try await withDiagnosticPhase("SFTP close file \(fileID)") {
            await acquireOperation()
            defer { releaseOperation() }
            guard sftpClients[sftpID]?.files[fileID] != nil else { return }
            guard valid, session != nil else { return }
            do {
                let deadline = ContinuousClock.now.advanced(by: timeout)
                try await waitUntilSFTPIdle(
                    id: sftpID,
                    deadline: deadline,
                    cancellable: false)
                try beginSFTPUse(sftpID)
                defer { endSFTPUse(sftpID) }
                try await closeSFTPFileHoldingOperation(
                    sftpID: sftpID,
                    fileID: fileID,
                    deadline: deadline)
            } catch {
                throw teardownFailure(error)
            }
        }
    }

    private func closeSFTPFileWithinUse(
        sftpID: UInt64,
        fileID: UInt64,
        timeout: Duration
    ) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        guard sftpClients[sftpID]?.files[fileID] != nil else { return }
        guard valid, session != nil else { return }
        do {
            try await closeSFTPFileHoldingOperation(
                sftpID: sftpID,
                fileID: fileID,
                deadline: ContinuousClock.now.advanced(by: timeout))
        } catch {
            throw teardownFailure(error)
        }
    }

    private func closeSFTPFileHoldingOperation(
        sftpID: UInt64,
        fileID: UInt64,
        deadline: ContinuousClock.Instant
    ) async throws {
        try await waitForTransportSendAdmission(
            owner: allocateTransportSendOwner(),
            deadline: deadline,
            cancellable: false)
        guard let file = sftpClients[sftpID]?.files[fileID] else { return }
        let result = try await repeatUntilCompleteHolding(
            deadline: deadline,
            cancellable: false
        ) {
            libssh2_sftp_close_handle(file)
        }
        guard result == 0 else { throw SSHError.channelFailed }
        sftpClients[sftpID]?.files[fileID] = nil
    }

    func removeSFTPFile(
        id: UInt64,
        path: String,
        timeout: Duration
    ) async throws {
        try await withDiagnosticPhase("SFTP remove file") {
            guard Self.isValidSFTPPath(path) else { throw SSHError.channelFailed }
            await acquireOperation()
            defer { releaseOperation() }
            try await removeSFTPFileHoldingOperation(
                id: id,
                path: path,
                timeout: timeout,
                cancellable: true,
                verifyAbsence: false)
        }
    }

    func removeSFTPFileForCompensation(
        id: UInt64,
        path: String,
        timeout: Duration
    ) async throws {
        try await withDiagnosticPhase("SFTP compensation") {
            guard Self.isValidSFTPPath(path) else { throw SSHError.channelFailed }
            await acquireOperation()
            defer { releaseOperation() }

            // Keep this permit through failure reclamation. If caller close ran
            // between the failed unlink/stat and shutdown, it could remove the
            // only SFTP state and leave this code unable to reclaim the handle.
            do {
                try await removeSFTPFileHoldingOperation(
                    id: id,
                    path: path,
                    timeout: timeout,
                    cancellable: false,
                    verifyAbsence: true)
            } catch {
                let normalized = normalize(error)
                var shutdownFailed = false
                do {
                    try await reclaimSFTPAfterCompensationFailureHoldingOperation(id: id)
                } catch {
                    shutdownFailed = true
                }
                // libssh2 1.11.1 shutdown frees pending unlink/stat packets and the
                // subsystem channel. That bounds an abandoned request to this SFTP
                // client; only a failed shutdown or a lost transport poisons the
                // owning SSH session.
                if shutdownFailed || normalized == .connectionInvalidated {
                    invalidateResources()
                }
                throw normalized
            }
        }
    }

    private func reclaimSFTPAfterCompensationFailureHoldingOperation(
        id: UInt64
    ) async throws {
        // The caller owns the operation permit until this handle is either
        // shut down here or reclaimed by whole-session invalidation.
        guard let state = sftpClients.removeValue(forKey: id) else { return }
        guard valid, session != nil else { throw SSHError.connectionInvalidated }

        // Compensation has already exhausted its operation budget. Reclamation
        // gets a separate bounded chance because the caller cannot safely reuse
        // this subsystem until libssh2 has freed its pending packet state.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
#if DEBUG
        if let hold = nextCompensationShutdownHoldForTesting {
            nextCompensationShutdownHoldForTesting = nil
            try await hold()
        }
#endif
        let result = try await repeatUntilCompleteHolding(
            deadline: deadline,
            cancellable: false
        ) {
            libssh2_sftp_shutdown(state.handle)
        }
        guard result == 0 else {
            if Self.isConnectionLoss(result) { throw SSHError.connectionInvalidated }
            throw SSHError.channelFailed
        }
    }

    /// Shuts down a subsystem whose request was cut off mid-flight (see
    /// `withSFTPUse`). The caller holds the operation permit and the
    /// subsystem's use, so no queued caller reaches the abandoned
    /// continuation first. Like compensation reclamation it gets a bounded
    /// budget of its own and ignores the caller's cancellation; a shutdown
    /// that cannot finish invalidates the session, because the handle is
    /// already out of the map and only session teardown can reclaim it then.
    private func reclaimInterruptedSFTPHoldingOperation(id: UInt64) async {
        guard let state = sftpClients.removeValue(forKey: id) else { return }
        guard valid, session != nil else {
            invalidateResources()
            return
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        do {
            try await waitForTransportSendAdmission(
                owner: allocateTransportSendOwner(),
                deadline: deadline,
                cancellable: false)
            let result = try await repeatUntilCompleteHolding(
                deadline: deadline,
                cancellable: false
            ) {
                libssh2_sftp_shutdown(state.handle)
            }
            guard result == 0 else { throw SSHError.channelFailed }
        } catch {
            invalidateResources()
        }
    }

    private func removeSFTPFileHoldingOperation(
        id: UInt64,
        path: String,
        timeout: Duration,
        cancellable: Bool,
        verifyAbsence: Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        try await waitUntilSFTPIdle(
            id: id,
            deadline: deadline,
            cancellable: cancellable)
        try beginSFTPUse(id)
        defer { endSFTPUse(id) }
        try await waitForTransportSendAdmission(
            owner: allocateTransportSendOwner(),
            deadline: deadline,
            cancellable: cancellable)
        guard valid, let session, let sftp = sftpClients[id]?.handle else {
            throw SSHError.connectionInvalidated
        }
        let result = try await repeatCompensationOperation(
            phase: .unlink,
            deadline: deadline,
            cancellable: cancellable
        ) {
            path.withCString { pathPointer in
                libssh2_sftp_unlink_ex(sftp, pathPointer, UInt32(path.utf8.count))
            }
        }
        if result.code != 0 {
            if Self.isConnectionLoss(result.code) {
                applyTransportSendOwnerDisposition(result.disposition)
                throw SSHError.connectionInvalidated
            }
            let status = UInt64(libssh2_sftp_last_error(sftp))
            applyTransportSendOwnerDisposition(result.disposition)
            if result.disposition == .invalidate { throw SSHError.connectionInvalidated }
            guard verifyAbsence, status == UInt64(LIBSSH2_FX_NO_SUCH_FILE) else {
                throw SSHError.sftpFailure(status: status)
            }
        } else {
            applyTransportSendOwnerDisposition(result.disposition)
        }
        guard verifyAbsence else {
            return
        }

        var attributes = LIBSSH2_SFTP_ATTRIBUTES()
        let statResult = try await repeatCompensationOperation(
            phase: .stat,
            deadline: deadline,
            cancellable: false
        ) {
            path.withCString { pathPointer in
                libssh2_sftp_stat_ex(
                    sftp,
                    pathPointer,
                    UInt32(path.utf8.count),
                    Int32(LIBSSH2_SFTP_STAT),
                    &attributes)
            }
        }
        if statResult.code == 0 {
            applyTransportSendOwnerDisposition(statResult.disposition)
            throw SSHError.channelFailed
        }
        if Self.isConnectionLoss(statResult.code) {
            applyTransportSendOwnerDisposition(statResult.disposition)
            throw SSHError.connectionInvalidated
        }
        let status = UInt64(libssh2_sftp_last_error(sftp))
        applyTransportSendOwnerDisposition(statResult.disposition)
        if statResult.disposition == .invalidate { throw SSHError.connectionInvalidated }
        guard status == UInt64(LIBSSH2_FX_NO_SUCH_FILE) else {
            throw SSHError.sftpFailure(status: status)
        }
        guard valid, self.session == session else {
            throw SSHError.connectionInvalidated
        }
    }

    func renameSFTPFileAtomically(
        id: UInt64,
        sourcePath: String,
        destinationPath: String,
        timeout: Duration
    ) async throws {
        try await withDiagnosticPhase("SFTP rename file") {
            guard
                Self.isValidSFTPPath(sourcePath),
                Self.isValidSFTPPath(destinationPath)
            else {
                throw SSHError.channelFailed
            }
            await acquireOperation()
            defer { releaseOperation() }
            let result = try await repeatUntilCompleteHoldingSFTP(
                id: id,
                deadline: ContinuousClock.now.advanced(by: timeout)
            ) { sftp in
                sourcePath.withCString { sourcePointer in
                    destinationPath.withCString { destinationPointer in
                        libssh2_sftp_posix_rename_ex(
                            sftp,
                            sourcePointer,
                            sourcePath.utf8.count,
                            destinationPointer,
                            destinationPath.utf8.count)
                    }
                }
            }
            try checkSFTPResult(result, sftpID: id)
        }
    }

    func closeSFTP(id: UInt64, timeout: Duration) async throws {
        try await withDiagnosticPhase("SFTP close channel \(id)") {
            await acquireOperation()
            defer { releaseOperation() }
            guard sftpClients[id] != nil else { return }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            do {
                try await waitUntilSFTPIdle(
                    id: id,
                    deadline: deadline,
                    cancellable: false)
                guard let state = sftpClients.removeValue(forKey: id) else { return }
                guard valid, session != nil else { return }
                try await waitForTransportSendAdmission(
                    owner: allocateTransportSendOwner(),
                    deadline: deadline,
                    cancellable: false)
                let result = try await repeatUntilCompleteHolding(
                    deadline: deadline,
                    cancellable: false
                ) {
                    libssh2_sftp_shutdown(state.handle)
                }
                guard result == 0 else { throw SSHError.channelFailed }
            } catch {
                throw teardownFailure(error)
            }
        }
    }

    func close(timeout: Duration) async throws {
        try await withDiagnosticPhase("close", budget: timeout) {
            diagnosticStep = "operation admission"
            await acquireOperation()
            defer { releaseOperation() }

            guard valid, !forwarding else {
                if forwarding { throw SSHError.channelFailed }
                invalidateResources()
                return
            }
            guard let session else {
                invalidateResources()
                return
            }
            let deadline = ContinuousClock.now.advanced(by: timeout)

            do {
                diagnosticStep = "disconnect"
                let disconnectResult = try await repeatUntilComplete(deadline: deadline) {
                    libssh2_session_disconnect_ex(
                        session,
                        SSH_DISCONNECT_BY_APPLICATION,
                        "Waycar closed the connection",
                        "")
                }
                guard disconnectResult == 0 else {
                    throw mapSessionError(disconnectResult)
                }
                try await freeSession(session, deadline: deadline, cancellable: true)
                self.session = nil
                valid = false
                oneShotChannels.removeAll()
                pendingChannelOpens.removeAll()
                streamLocalChannels.removeAll()
                ptyChannels.removeAll()
                execStreamChannels.removeAll()
                sftpClients.removeAll()
                _ = sendOwnership.handle(.sessionReleased)
                activity.releaseAllWaiters()
                closeDescriptor()
            } catch {
                invalidateResources()
                throw normalize(error)
            }
        }
    }

    func invalidate() {
        invalidateResources()
    }

    var isReusable: Bool {
        valid && session != nil && descriptor >= 0 && authenticated
    }

#if DEBUG
    func directTCPIPInboundBufferHighWaterMarkForTesting() -> Int {
        directTCPIPInboundBufferHighWaterMark
    }

    func holdNextDirectTCPIPInboundBufferFullForTesting(
        _ hold: @escaping @Sendable () async -> Void
    ) {
        nextDirectTCPIPInboundBufferFullHoldForTesting = hold
    }

    func delayNextSFTPWriteForTesting(_ delay: Duration) {
        nextSFTPWriteDelayForTesting = delay
    }

    var isSFTPWriteDelayedForTesting: Bool {
        sftpWriteDelayIsActiveForTesting
    }

    /// Holds the next operation that blocks on the session in the window it
    /// naturally passes through: released to the next operation, not yet
    /// watching the socket. Widening that window turns the race this driver
    /// has to survive into something a test can drive.
    func holdNextSessionWaitForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) {
        nextSessionWaitHoldForTesting = hold
    }

    func holdNextExecChannelAllocationForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) {
        nextExecChannelAllocatedHoldForTesting = hold
    }

    func holdNextExecCleanupForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) {
        nextExecCleanupHoldForTesting = hold
    }

    /// Holds the next exec-stream read turn between its stdout read and its
    /// stderr drain, with the session still held: stdout that reaches the
    /// socket meanwhile is taken off it by the drain, not the stdout read.
    func holdNextExecStreamStandardErrorDrainForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) {
        nextExecStreamStandardErrorDrainHoldForTesting = hold
    }

    /// Holds the next one-shot exec exchange turn that has made no progress
    /// yet between its stdout read and its stderr read, with the session
    /// still held: whatever reaches the socket meanwhile is queued by the
    /// stderr read, not the stdout read.
    func holdNextExecExchangeStandardErrorReadForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) {
        nextExecExchangeStandardErrorReadHoldForTesting = hold
    }

    func holdNextOutboundWriteParkForTesting(
        _ hold: @escaping @Sendable () async -> Void
    ) {
        nextOutboundWriteParkHoldForTesting = hold
    }

    func holdNextOneShotEstablishedForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) {
        nextOneShotEstablishedHoldForTesting = hold
    }

    func holdNextOwnedLoopTopForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) {
        nextOwnedLoopTopHoldForTesting = hold
    }

    func holdNextOwnedDrainForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) {
        nextOwnedDrainHoldForTesting = hold
    }

    func holdNextChannelOpenSlotForTesting(
        _ hold: @escaping @Sendable () async throws -> Void
    ) {
        nextChannelOpenSlotHoldForTesting = hold
    }

    func observeChannelOpenClaimsForTesting(
        _ observer: (@Sendable () -> Void)?
    ) {
        channelOpenClaimObserverForTesting = observer
    }

    func holdNextChannelTeardownForTesting(
        _ hold: @escaping @Sendable () async -> Void
    ) {
        nextChannelTeardownHoldForTesting = hold
    }

    func failNextResumedChannelOpenWaiterForTesting(_ error: SSHError) {
        nextResumedChannelOpenWaiterErrorForTesting = error
    }

    func holdNextChannelOpenWaiterRegistrationForTesting(
        _ hold: @escaping @Sendable () async -> Void
    ) {
        nextChannelOpenWaiterRegistrationHoldForTesting = hold
    }

    func holdBackgroundChannelReleasesForTesting(
        _ hold: (@Sendable () async -> Void)?
    ) {
        backgroundChannelReleaseHoldForTesting = hold
    }

    func sftpUseCountForTesting() -> Int {
        sftpUses.values.reduce(0, +)
    }

    func sftpIdleWaiterCountForTesting() -> Int {
        sftpIdleWaiters.count
    }

    func channelOpenWaiterCountForTesting() -> Int {
        channelOpenSlots.waiterCount
    }

    /// Changes how many opens may be in flight at once, admitting any
    /// waiters a higher limit lets in.
    func setChannelOpenLimitForTesting(_ limit: Int) {
        performChannelOpenSlots(channelOpenSlots.handle(.setLimit(limit)))
    }

    func holdNextAbandonedChannelOpenFreeForTesting(
        _ hold: @escaping @Sendable () async -> Void
    ) {
        nextAbandonedChannelOpenFreeHoldForTesting = hold
    }

    func abandonedChannelOpenFreeCountForTesting() -> Int {
        abandonedChannelOpenFreesForTesting
    }

    func pendingChannelOpenCountForTesting() -> Int {
        pendingChannelOpens.count
    }

    func peakPendingChannelOpensForTesting() -> Int {
        pendingChannelOpenPeakForTesting
    }

    func ptyTeardownWaiterCountForTesting() -> Int {
        channelTeardownWaiters.values.reduce(0) { count, entry in
            guard case .pty = entry.identity else { return count }
            return count + 1
        }
    }

    func ptyChannelCountForTesting() -> Int {
        ptyChannels.count
    }

    func ptyAcceptsIOForTesting(id: UInt64) -> Bool {
        ptyChannels[id]?.acceptsIO == true
    }

    func execStreamChannelCountForTesting() -> Int {
        execStreamChannels.count
    }

    func execStreamAcceptsIOForTesting(id: UInt64) -> Bool {
        execStreamChannels[id]?.acceptsIO == true
    }

    func startSamplingTransportSendOwnerForTesting() {
        ownerSamplesForTesting = []
    }

    func transportSendOwnerSamplesForTesting() -> [TransportSendOwnerSample] {
        ownerSamplesForTesting ?? []
    }

    func oneShotRegistryCountForTesting() -> Int {
        oneShotChannels.count
    }

    func shrinkSendBufferForTesting(bytes: Int) throws {
        guard descriptor >= 0 else { throw SSHError.connectionInvalidated }
        var size = Int32(clamping: bytes)
        let result = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDBUF,
            &size,
            socklen_t(MemoryLayout<Int32>.size))
        guard result == 0 else { throw SSHError.connectionInvalidated }
    }

    func runNextCompensationUnlinkPhaseHookForTesting(
        _ hook: @escaping @Sendable () async throws -> Void
    ) {
        nextCompensationUnlinkPhaseHookForTesting = hook
    }

    func runNextCompensationStatPhaseHookForTesting(
        _ hook: @escaping @Sendable () async throws -> Void
    ) {
        nextCompensationStatPhaseHookForTesting = hook
    }

    func runNextCompensationShutdownHookForTesting(
        _ hook: @escaping @Sendable () async throws -> Void
    ) {
        nextCompensationShutdownHoldForTesting = hook
    }

    func failNextSFTPInitBeforeEAGAINForTesting() {
        shouldFailNextSFTPInitBeforeEAGAINForTesting = true
    }

    var operationWaiterCountForTesting: Int {
        operationWaiters.count
    }

    func resourceStateForTesting() -> SessionDriverResourceState {
        SessionDriverResourceState(
            hasSession: session != nil,
            descriptorIsOpen: descriptor >= 0,
            isValid: valid)
    }
#endif

    private func configureAlgorithms(_ session: OpaquePointer) throws {
        let preferences: [(Int32, String)] = [
            (LIBSSH2_METHOD_HOSTKEY, Self.hostKeyPreference),
            (LIBSSH2_METHOD_SIGN_ALGO, Self.signaturePreference),
            (LIBSSH2_METHOD_KEX, Self.keyExchangePreference),
            (LIBSSH2_METHOD_CRYPT_CS, Self.cipherPreference),
            (LIBSSH2_METHOD_CRYPT_SC, Self.cipherPreference),
            (LIBSSH2_METHOD_MAC_CS, Self.macPreference),
            (LIBSSH2_METHOD_MAC_SC, Self.macPreference),
        ]
        for (method, preference) in preferences {
            let result = preference.withCString {
                libssh2_session_method_pref(session, method, $0)
            }
            guard result == 0 else { throw SSHError.algorithmNegotiationFailed }
        }
    }

    private func performHandshake(
        deadline: ContinuousClock.Instant
    ) async throws -> SSHHostKey {
        guard NativeLibrary.initializationResult == 0 else {
            throw SSHError.connectionFailed
        }
        guard let createdSession = libssh2_session_init_ex(nil, nil, nil, nil) else {
            throw SSHError.connectionFailed
        }
        session = createdSession
        libssh2_session_set_blocking(createdSession, 0)
        activity.install(on: createdSession)
        try configureAlgorithms(createdSession)

        let handshakeResult = try await repeatUntilComplete(deadline: deadline) {
            libssh2_session_handshake(createdSession, descriptor)
        }
        guard handshakeResult == 0 else {
#if DEBUG
            HandshakeFailureObservation.observer?(handshakeResult)
#endif
            handshakeFailedInKeyExchange =
                handshakeResult == LIBSSH2_ERROR_KEY_EXCHANGE_FAILURE
            throw mapSessionError(handshakeResult)
        }
        return try extractHostKey(createdSession)
    }

    func openDirectTCPIP(
        endpoint: SSHEndpoint,
        timeout: Duration
    ) async throws -> DirectTCPIPByteTransport {
        try await withDiagnosticPhase("direct-tcpip open to \(endpoint.host):\(endpoint.port)") {
            await acquireOperation()
            defer { releaseOperation() }

            guard
                valid,
                !forwarding,
                authenticated,
                let session,
                !endpoint.host.isEmpty,
                endpoint.port > 0
            else {
                throw SSHError.connectionInvalidated
            }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            var channel: OpaquePointer?

            do {
                // Holds the session for the whole open, as the stock open
                // did: no operation may start between the `forwarding` check
                // above and the pump, which then owns the session alone.
                channel = try await openChannel(
                    .directTCPIP(host: endpoint.host, port: endpoint.port),
                    deadline: deadline,
                    yielding: false)
                guard let channel else { throw SSHError.channelFailed }
                let transport = try DirectTCPIPByteTransport()
                let pumpDescriptor = try transport.takePumpDescriptor()
                #if DEBUG
                directTCPIPInboundBufferHighWaterMark = 0
                #endif
                forwarding = true
                let task = Task { [self] in
                    await withDiagnosticPhase("direct-tcpip forwarding") {
                        await pumpDirectTCPIP(
                            channel: channel,
                            bridgeDescriptor: pumpDescriptor,
                            session: session)
                    }
                }
                transport.start(task)
                return transport
            } catch {
                let normalized = normalize(error)
                if let channel {
                    do {
                        try await cleanChannel(
                            channel,
                            session: session,
                            deadline: ContinuousClock.now.advanced(by: .seconds(2)),
                            cancellable: false)
                    } catch {
                        invalidateResources()
                    }
                } else if !(error is SettledChannelOpenError),
                    normalized == .timedOut || normalized == .cancelled
                {
                    invalidateResources()
                }
                throw normalized
            }
        }
    }

    private func classifyDirectTCPIPOpenFailure(_ session: OpaquePointer) -> SSHError {
        var messagePointer: UnsafeMutablePointer<CChar>?
        var messageLength: Int32 = 0
        _ = libssh2_session_last_error(session, &messagePointer, &messageLength, 0)
        guard let messagePointer, messageLength > 0 else { return .channelFailed }
        let message = String(
            decoding: Data(bytes: messagePointer, count: Int(messageLength)),
            as: UTF8.self)
            .lowercased()
        if message.contains("administratively prohibited")
            || message.contains("forwarding disabled")
            || message.contains("not allowed")
        {
            return .forwardingDenied
        }
        if message.contains("connect failed") || message.contains("connection refused") {
            return .targetUnreachable
        }
        return .channelFailed
    }

    private func pumpDirectTCPIP(
        channel: OpaquePointer,
        bridgeDescriptor: Int32,
        session: OpaquePointer
    ) async -> Result<Void, SSHError> {
        defer {
            Darwin.close(bridgeDescriptor)
            forwarding = false
        }

        do {
            try await runDirectTCPIPPump(
                channel: channel,
                bridgeDescriptor: bridgeDescriptor,
                session: session)
            try await cleanChannel(
                channel,
                session: session,
                deadline: ContinuousClock.now.advanced(by: .seconds(2)),
                cancellable: false)
            return .success(())
        } catch {
            let normalized = normalize(error)
            do {
                try await cleanChannel(
                    channel,
                    session: session,
                    deadline: ContinuousClock.now.advanced(by: .seconds(2)),
                    cancellable: false)
            } catch {
                invalidateResources()
            }
            return .failure(normalized)
        }
    }

    private func runDirectTCPIPPump(
        channel: OpaquePointer,
        bridgeDescriptor: Int32,
        session: OpaquePointer
    ) async throws {
        let bufferLimit = 1_048_576
        var toOuter = Data()
        var toInner = Data()
        var scratch = [UInt8](repeating: 0, count: 32 * 1024)
        var innerEOF = false
        var outerEOF = false
        // How far the forwarded connection actually got. A pump that dies
        // before either direction moves is a different incident from one that
        // dies mid-stream, and the nested session sees the same bare EOF.
        var forwardedToHost = 0
        var forwardedFromHost = 0

        while true {
            if Task.isCancelled { throw SSHError.cancelled }
            guard valid else { throw SSHError.connectionInvalidated }
            var madeProgress = false

            if !innerEOF, toOuter.count < bufferLimit {
                // Capture errno with the result: anything between the syscall
                // and the check can clobber it, and the errno is the whole
                // content of the report.
                let (readCount, readErrno) = scratch.withUnsafeMutableBytes {
                    bytes -> (Int, Int32) in
                    let result = Darwin.read(bridgeDescriptor, bytes.baseAddress, bytes.count)
                    return (result, result < 0 ? errno : 0)
                }
                if readCount > 0 {
                    toOuter.append(contentsOf: scratch.prefix(readCount))
                    madeProgress = true
                } else if readCount == 0 {
                    innerEOF = true
                    madeProgress = true
                } else if readErrno != EAGAIN && readErrno != EWOULDBLOCK {
                    notePumpFailure(
                        "bridge read",
                        errnoCode: readErrno,
                        toHost: forwardedToHost,
                        fromHost: forwardedFromHost)
                    throw SSHError.connectionFailed
                }
            }

            if !toOuter.isEmpty {
                let written = toOuter.withUnsafeBytes { bytes -> Int in
                    guard let baseAddress = bytes.baseAddress else { return 0 }
                    return libssh2_channel_write_ex(
                        channel,
                        0,
                        baseAddress.assumingMemoryBound(to: CChar.self),
                        bytes.count)
                }
                if written > 0 {
                    toOuter.removeFirst(written)
                    forwardedToHost += written
                    madeProgress = true
                } else if written != Int(LIBSSH2_ERROR_EAGAIN) {
                    notePumpFailure(
                        "channel write",
                        libssh2Code: Int32(clamping: written),
                        toHost: forwardedToHost,
                        fromHost: forwardedFromHost)
                    throw SSHError.connectionFailed
                }
            }

            if !outerEOF, toInner.count < bufferLimit {
                let maximumReadCount = min(scratch.count, bufferLimit - toInner.count)
                let readCount = scratch.withUnsafeMutableBytes { bytes -> Int in
                    guard let baseAddress = bytes.baseAddress else { return 0 }
                    return libssh2_channel_read_ex(
                        channel,
                        0,
                        baseAddress.assumingMemoryBound(to: CChar.self),
                        maximumReadCount)
                }
                if readCount > 0 {
                    toInner.append(contentsOf: scratch.prefix(readCount))
#if DEBUG
                    directTCPIPInboundBufferHighWaterMark = max(
                        directTCPIPInboundBufferHighWaterMark,
                        toInner.count)
                    if toInner.count >= bufferLimit,
                        let hold = nextDirectTCPIPInboundBufferFullHoldForTesting
                    {
                        nextDirectTCPIPInboundBufferFullHoldForTesting = nil
                        await hold()
                        if Task.isCancelled { throw SSHError.cancelled }
                        guard valid else { throw SSHError.connectionInvalidated }
                    }
#endif
                    madeProgress = true
                } else if readCount != 0 && readCount != Int(LIBSSH2_ERROR_EAGAIN) {
                    notePumpFailure(
                        "channel read",
                        libssh2Code: Int32(clamping: readCount),
                        toHost: forwardedToHost,
                        fromHost: forwardedFromHost)
                    throw SSHError.connectionFailed
                }
                if libssh2_channel_eof(channel) == 1 {
                    outerEOF = true
                    madeProgress = true
                }
            }

            let shouldHoldBridgeWrites: Bool
#if DEBUG
            shouldHoldBridgeWrites = nextDirectTCPIPInboundBufferFullHoldForTesting != nil
#else
            shouldHoldBridgeWrites = false
#endif
            if !toInner.isEmpty, !shouldHoldBridgeWrites {
                let bridgeWrite: BridgeWriteResult
                do {
                    bridgeWrite = try Self.writeBridge(toInner, descriptor: bridgeDescriptor)
                } catch let failure as BridgeWriteFailure {
                    notePumpFailure(
                        "bridge write",
                        errnoCode: failure.code,
                        toHost: forwardedToHost,
                        fromHost: forwardedFromHost)
                    throw SSHError.connectionFailed
                }
                switch bridgeWrite {
                case .wrote(let written):
                    toInner.removeFirst(written)
                    forwardedFromHost += written
                    madeProgress = true
                case .blocked:
                    break
                case .peerClosed:
                    // The nested session closes its socket before the pump has
                    // necessarily delivered the last bytes already read from
                    // the outer channel. No consumer remains for this
                    // direction, and that full-descriptor close also ends the
                    // opposite one.
                    toInner.removeAll(keepingCapacity: true)
                    innerEOF = true
                    madeProgress = true
                }
            }

            if outerEOF, toInner.isEmpty {
                // `toInner` only grows while `outerEOF` is false, so no later
                // bridge write can misread this local shutdown as peer close.
                _ = Darwin.shutdown(bridgeDescriptor, SHUT_WR)
            }
            if innerEOF, toOuter.isEmpty { return }

            if !madeProgress {
                var innerDirections: SocketDirections = []
                if !innerEOF, toOuter.count < bufferLimit { innerDirections.insert(.read) }
                if !toInner.isEmpty { innerDirections.insert(.write) }
                let pumpDeadline = ContinuousClock.now.advanced(by: .seconds(60))
                // The one wait in the driver that needs no SessionActivity
                // watch. `forwarding` is a hard mutual-exclusion gate: every
                // other entry point refuses while it is set, and `close`
                // throws rather than run. Once this pump is up, the outer
                // session has no other operation that could drain the socket
                // out from under it, so the socket edge is the only edge
                // there is. Do not copy this to a site that shares a session.
                do {
                    try await SocketReadiness.wait(
                        for: [
                            .init(
                                descriptor: descriptor,
                                directions: sessionDirections(session)),
                            .init(
                                descriptor: bridgeDescriptor,
                                directions: innerDirections),
                        ],
                        until: pumpDeadline)
                } catch SSHError.timedOut {
                    continue
                }
            }
        }
    }

    static func writeBridge(_ data: Data, descriptor: Int32) throws -> BridgeWriteResult {
        let (written, writeErrno) = data.withUnsafeBytes { bytes -> (Int, Int32) in
            guard let baseAddress = bytes.baseAddress else { return (0, 0) }
            let result = Darwin.write(descriptor, baseAddress, bytes.count)
            return (result, result < 0 ? errno : 0)
        }
        if written > 0 { return .wrote(written) }
        if written == 0 || writeErrno == EAGAIN || writeErrno == EWOULDBLOCK {
            return .blocked
        }
        if writeErrno == EPIPE { return .peerClosed }
        throw BridgeWriteFailure(code: writeErrno)
    }

    /// Everything a blocked operation needs to wait on the session, captured
    /// while it still holds the session. Another operation may drain the
    /// socket between that capture and the wait actually arming, so the plan
    /// carries the receive count that makes such a drain detectable.
    private struct SessionWaitPlan {
        let descriptor: Int32
        let directions: SocketDirections
        let watch: SessionActivityWatch
    }

    /// `watch` defaults to the receive count now. An operation whose own
    /// reads may have queued bytes it has yet to take passes the count from
    /// before those reads.
    private func sessionWaitPlan(
        _ session: OpaquePointer,
        watching watch: SessionActivityWatch? = nil
    ) -> SessionWaitPlan {
        SessionWaitPlan(
            descriptor: descriptor,
            directions: sessionDirections(session),
            watch: watch ?? activity.watch())
    }

    private func awaitSessionProgress(
        _ plan: SessionWaitPlan,
        until deadline: ContinuousClock.Instant,
        cancellable: Bool = true,
        waitingFor: String = "socket"
    ) async throws {
        if let context = SSHDiagnosticOperation.current {
            let directions = [
                plan.directions.contains(.read) ? "read" : nil,
                plan.directions.contains(.write) ? "write" : nil,
            ].compactMap { $0 }.joined(separator: "/")
            context.recordWait("\(waitingFor) \(directions)")
        }
#if DEBUG
        if let hold = nextSessionWaitHoldForTesting {
            nextSessionWaitHoldForTesting = nil
            do {
                try await hold()
            } catch {
                if error as? SSHError == .timedOut { noteTimedOutOnce() }
                throw error
            }
        }
#endif
        try await SocketReadiness.wait(
            descriptor: plan.descriptor,
            directions: plan.directions,
            until: deadline,
            cancellable: cancellable,
            watching: plan.watch,
            onTimeout: SSHDiagnosticOperation.current?.noteTimeout)
    }

    private func sessionDirections(_ session: OpaquePointer) -> SocketDirections {
        let rawDirections = libssh2_session_block_directions(session)
        var directions: SocketDirections = []
        if rawDirections & LIBSSH2_SESSION_BLOCK_INBOUND != 0 {
            directions.insert(.read)
        }
        if rawDirections & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 {
            directions.insert(.write)
        }
        if directions.isEmpty { directions = [.read, .write] }
        return directions
    }

    private func sessionReportsOutbound(_ session: OpaquePointer) -> Bool {
        libssh2_session_block_directions(session) & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0
    }

    private func requireSession() throws -> OpaquePointer {
        guard valid, let session else { throw SSHError.connectionInvalidated }
        return session
    }

    private func allocateTransportSendOwner() -> UInt64 {
        nextTransportSendIdentity &+= 1
        return nextTransportSendIdentity
    }

    private func notePacketProducingResult(
        _ result: Int32,
        owner: UInt64,
        session: OpaquePointer
    ) -> TransportSendOwnerDisposition {
        SSHDiagnosticOperation.current?.recordResult(result)
        if result == LIBSSH2_ERROR_EAGAIN {
            _ = sendOwnership.handle(
                .wouldBlock(call: owner, outboundPending: sessionReportsOutbound(session)))
            return .unchanged
        }
        guard transportSendOwner == owner else { return .unchanged }
        let effects = sendOwnership.handle(
            .finished(
                call: owner, result: result,
                outboundPending: sessionReportsOutbound(session)))
        switch effects.first {
        case .cleared: return .clear
        case .invalidate: return .invalidate
        case nil: return .unchanged
        }
    }

    static func transportSendOwnerDisposition(
        result: Int32,
        isCurrentOwner: Bool,
        hasOutbound: Bool
    ) -> TransportSendOwnerDisposition {
        guard isCurrentOwner else { return .unchanged }
        if result < 0, hasOutbound { return .invalidate }
        return .clear
    }

    private func applyTransportSendOwnerDisposition(
        _ disposition: TransportSendOwnerDisposition
    ) {
        if disposition == .invalidate { invalidateResources() }
    }

    private func notePacketProducingWrite(
        _ written: Int,
        owner: UInt64,
        session: OpaquePointer
    ) -> TransportSendOwnerDisposition {
        if written == Int(LIBSSH2_ERROR_EAGAIN) {
            return notePacketProducingResult(
                LIBSSH2_ERROR_EAGAIN,
                owner: owner,
                session: session)
        } else if written >= 0 {
            return notePacketProducingResult(0, owner: owner, session: session)
        } else {
            return notePacketProducingResult(
                Int32(clamping: written),
                owner: owner,
                session: session)
        }
    }

    /// Caller holds the operation mutex. Releases it while a foreign owner
    /// occupies the send, then re-acquires before returning or throwing so a
    /// matching `releaseOperation()` stays balanced.
    private func waitForTransportSendAdmission(
        owner: UInt64,
        deadline: ContinuousClock.Instant,
        cancellable: Bool
    ) async throws {
        while let existing = transportSendOwner, existing != owner {
            let session = try requireSession()
            let plan = sessionWaitPlan(session)
            releaseOperation()
            do {
                try await awaitSessionProgress(
                    plan,
                    until: deadline,
                    cancellable: cancellable,
                    waitingFor: "transport send admission")
            } catch {
                await acquireOperation()
                throw error
            }
            await acquireOperation()
            if cancellable {
                try checkProgress(deadline: deadline)
            } else if ContinuousClock.now >= deadline {
                throw noteTimedOut()
            }
        }
    }

    /// Drives the exact owning libssh2 call to a non-`EAGAIN` result, or
    /// invalidates. Cancellation and timeout never clear ownership by themselves.
    private func finishOwnedSendIfNeeded(
        owner: UInt64,
        drive: () -> Int32
    ) async {
        await finishOwnedSendIfNeeded(owner: owner, drive: { drive() as Int32? })
    }

    private func finishOwnedSendIfNeeded(
        owner: UInt64,
        drive: () -> Int32?
    ) async {
        guard transportSendOwner == owner else { return }
#if DEBUG
        if let hold = nextOwnedDrainHoldForTesting {
            nextOwnedDrainHoldForTesting = nil
            do {
                try await hold()
            } catch {
                abandonOwnedSend(owner: owner, drive: drive)
                return
            }
        }
#endif
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        do {
            while transportSendOwner == owner {
                if ContinuousClock.now >= deadline {
                    abandonOwnedSend(owner: owner, drive: drive)
                    return
                }
                guard valid else { return }
                guard let result = drive() else {
                    invalidateResources()
                    return
                }
                let session = try requireSession()
                let disposition = notePacketProducingResult(
                    result,
                    owner: owner,
                    session: session)
                if disposition == .invalidate {
                    abandonOwnedSend(owner: owner, drive: drive)
                    return
                }
                applyTransportSendOwnerDisposition(disposition)
                if result != LIBSSH2_ERROR_EAGAIN { return }
                try await waitForSession(
                    session,
                    deadline: deadline,
                    cancellable: false)
            }
        } catch {
            abandonOwnedSend(owner: owner, drive: drive)
        }
    }

    /// Completes the one pending packet through its exact owning call while
    /// native I/O is redirected locally, then synchronously frees the session.
    private func abandonOwnedSend(
        owner: UInt64,
        drive: () -> Int32?
    ) {
        guard transportSendOwner == owner, let session else {
            invalidateResources()
            return
        }
        waycar_libssh2_prepare_session_abandonment(session)
        _ = drive()
        invalidateResources()
    }

    /// Claims one channel-open slot of `kind`. Caller holds the operation
    /// mutex on entry, on return and on throw. With no slot it may take —
    /// `channelOpenLimit` opens in flight, or for `.stock` another stock open
    /// in flight — the caller parks without the mutex, and a released slot
    /// goes to the first parked waiter it can admit, interactive first, then
    /// in arrival order (C-PRIORITY). No waiter that could be admitted is
    /// ever left parked while a slot is free.
    private func claimChannelOpenSlot(
        _ kind: ChannelOpenKind,
        deadline: ContinuousClock.Instant,
        cancellable: Bool
    ) async throws {
        if !canAdmitChannelOpen(kind) {
            if cancellable {
                try checkProgress(deadline: deadline)
            } else if ContinuousClock.now >= deadline {
                throw noteTimedOut()
            }
            nextChannelOpenWaiterID &+= 1
            let waiterID = nextChannelOpenWaiterID
            let priority = SSHOperationPriority.current
            SSHDiagnosticOperation.current?.recordWait("channel open admission")
            do {
                try await waitForChannelOpenSlot(
                    id: waiterID,
                    kind: kind,
                    priority: priority,
                    deadline: deadline,
                    cancellable: cancellable)
            } catch {
                if error as? SSHError == .timedOut { noteTimedOutOnce() }
                await acquireOperation()
                throw error
            }
            await acquireOperation()
            // Resumed without an error means handed a slot: it is this
            // caller's now, and passes on if this caller gives up.
            do {
#if DEBUG
                if let error = nextResumedChannelOpenWaiterErrorForTesting {
                    nextResumedChannelOpenWaiterErrorForTesting = nil
                    throw error
                }
#endif
                if cancellable {
                    try checkProgress(deadline: deadline)
                } else if ContinuousClock.now >= deadline {
                    throw noteTimedOut()
                }
                guard valid else { throw SSHError.connectionInvalidated }
            } catch {
                releaseChannelOpenSlot(kind)
                throw error
            }
        } else {
            takeChannelOpenSlot(kind)
        }
#if DEBUG
        channelOpenClaimObserverForTesting?()
        if let hold = nextChannelOpenSlotHoldForTesting {
            nextChannelOpenSlotHoldForTesting = nil
            // Keep the native-open slot claimed while allowing later callers
            // to reach and observe its waiter queue.
            releaseOperation()
            do {
                try await hold()
            } catch {
                await acquireOperation()
                releaseChannelOpenSlot(kind)
                throw error
            }
            await acquireOperation()
        }
#endif
    }

    private func waitForChannelOpenSlot(
        id: UInt64,
        kind: ChannelOpenKind,
        priority: SSHOperationPriority,
        deadline: ContinuousClock.Instant,
        cancellable: Bool
    ) async throws {
        if cancellable {
            try await withTaskCancellationHandler {
#if DEBUG
                await holdChannelOpenWaiterRegistrationForTestingIfNeeded()
#endif
                try await parkChannelOpenWaiterUntilDeadline(
                    id: id,
                    kind: kind,
                    priority: priority,
                    deadline: deadline,
                    cancellable: true)
            } onCancel: {
                Task { await self.resumeChannelOpenWaiter(id: id, .cancelled) }
            }
        } else {
            try await parkChannelOpenWaiterUntilDeadline(
                id: id,
                kind: kind,
                priority: priority,
                deadline: deadline,
                cancellable: false)
        }
    }

    private func parkChannelOpenWaiterUntilDeadline(
        id: UInt64,
        kind: ChannelOpenKind,
        priority: SSHOperationPriority,
        deadline: ContinuousClock.Instant,
        cancellable: Bool
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            guard !cancellable || !Task.isCancelled else {
                releaseOperation()
                continuation.resume(throwing: SSHError.cancelled)
                return
            }
            let deadlineTask = Task {
                do {
                    try await Task.sleep(until: deadline, clock: .continuous)
                } catch {
                    return
                }
                self.resumeChannelOpenWaiter(id: id, .timedOut)
            }
            channelOpenWaiters[id] = DriverWaiter(
                continuation: continuation, deadlineTask: deadlineTask)
            _ = channelOpenSlots.handle(.park(id: id, kind, priority: priority))
            releaseOperation()
        }
    }

    /// Fails one parked waiter (deadline, cancellation). A waiter already
    /// handed the slot has left the queue, so this cannot take it back.
    private func resumeChannelOpenWaiter(id: UInt64, _ error: SSHError) {
        performChannelOpenSlots(channelOpenSlots.handle(.withdraw(id: id, error)))
    }

    private func canAdmitChannelOpen(_ kind: ChannelOpenKind) -> Bool {
        channelOpenSlots.canAdmit(kind)
    }

    private func takeChannelOpenSlot(_ kind: ChannelOpenKind) {
        _ = channelOpenSlots.handle(.take(kind))
    }

    /// Frees a `kind` slot and hands slots to the waiters it lets in.
    private func releaseChannelOpenSlot(_ kind: ChannelOpenKind) {
        performChannelOpenSlots(channelOpenSlots.handle(.release(kind)))
    }

    /// Invalidation: no slot remains to hand over.
    private func failAllChannelOpenWaiters() {
        performChannelOpenSlots(channelOpenSlots.handle(.invalidate))
    }

    private func performChannelOpenSlots(_ effects: [ChannelOpenSlotMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .grant(let id):
                guard let waiter = channelOpenWaiters.removeValue(forKey: id) else { continue }
                waiter.deadlineTask.cancel()
                waiter.continuation.resume()
            case .fail(let id, let error):
                guard let waiter = channelOpenWaiters.removeValue(forKey: id) else { continue }
                waiter.deadlineTask.cancel()
                waiter.continuation.resume(throwing: error)
            }
        }
    }

    private func waitUntilChannelTeardownCompletes(
        _ identity: ChannelIdentity,
        label: String,
        deadline: ContinuousClock.Instant
    ) async throws {
        while self[sessionChannel: identity]?.teardownInProgress == true {
            guard ContinuousClock.now < deadline else { throw noteTimedOut() }
            SSHDiagnosticOperation.current?.recordWait("\(label) teardown completion")
            nextChannelTeardownWaiterID &+= 1
            let waiterID = nextChannelTeardownWaiterID
            do {
                try await parkChannelTeardownWaiter(
                    id: waiterID,
                    identity: identity,
                    deadline: deadline)
            } catch {
                if error as? SSHError == .timedOut { noteTimedOutOnce() }
                await acquireOperation()
                throw error
            }
            await acquireOperation()
            guard ContinuousClock.now < deadline else { throw noteTimedOut() }
            guard valid else { throw SSHError.connectionInvalidated }
        }
    }

    private func parkChannelTeardownWaiter(
        id: UInt64,
        identity: ChannelIdentity,
        deadline: ContinuousClock.Instant
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            let deadlineTask = Task {
                do {
                    try await Task.sleep(until: deadline, clock: .continuous)
                } catch {
                    return
                }
                self.resumeChannelTeardownWaiter(
                    id: id,
                    .failure(SSHError.timedOut))
            }
            channelTeardownWaiters[id] = ChannelTeardownWaiter(
                identity: identity,
                waiter: DriverWaiter(
                    continuation: continuation,
                    deadlineTask: deadlineTask))
            releaseOperation()
        }
    }

    private func resumeChannelTeardownWaiter(
        id: UInt64,
        _ result: Result<Void, any Error>
    ) {
        guard let entry = channelTeardownWaiters.removeValue(forKey: id) else { return }
        entry.waiter.deadlineTask.cancel()
        entry.waiter.continuation.resume(with: result)
    }

    private func wakeChannelTeardownWaiters(for identity: ChannelIdentity) {
        let ids = channelTeardownWaiters.compactMap { id, entry in
            entry.identity == identity ? id : nil
        }
        for id in ids { resumeChannelTeardownWaiter(id: id, .success(())) }
    }

    private func resumeAllChannelTeardownWaiters() {
        let ids = Array(channelTeardownWaiters.keys)
        for id in ids { resumeChannelTeardownWaiter(id: id, .success(())) }
    }

    private func registerOneShot(
        channel: OpaquePointer,
        session: OpaquePointer
    ) -> UInt64 {
        nextOneShotID &+= 1
        let id = nextOneShotID
        oneShotChannels[id] = OneShotChannel(
            channel: channel,
            session: session)
        return id
    }

    private func removeOneShot(_ id: UInt64) {
        oneShotChannels.removeValue(forKey: id)
    }

    /// The budget a one-shot channel's cleanup gets once no caller waits for
    /// it: all of it after a failed call, and at least this much in the
    /// background after a successful one.
    private static let oneShotCleanupBudget: Duration = .seconds(2)

    /// What is left of a one-shot channel once its caller has its answer.
    private enum OneShotFinish: Sendable {
        /// Nothing more to read: EOF, CLOSE (which waits for the peer's
        /// CLOSE) and free.
        case close
        /// An exec whose caller stopped reading early: both streams are read
        /// and dropped until remote EOF, then the channel is closed and freed.
        case drainExec(ExecExchangeProgress, reachedEOF: Bool)
    }

    /// Finishes one-shot channel `id` off its caller's path (C-CLOSE), then
    /// runs `onChannelReleased`. The work takes the operation mutex like any
    /// operation, under the priority of the call that left it behind, and
    /// reaches the channel by identity only: when invalidation or `close`
    /// reclaimed it first, nothing is left to do. A cleanup that cannot
    /// finish would strand a native channel and its server slot with no
    /// owner, so it notes why and invalidates the session.
    private func finishOneShotInBackground(
        id: UInt64,
        phase: String,
        finish: OneShotFinish,
        deadline: ContinuousClock.Instant,
        onChannelReleased: (@Sendable () async -> Void)?
    ) {
        Task {
#if DEBUG
            if let hold = backgroundChannelReleaseHoldForTesting { await hold() }
#endif
            await finishOneShot(id: id, phase: phase, finish: finish, deadline: deadline)
            await onChannelReleased?()
        }
    }

    private func finishOneShot(
        id: UInt64,
        phase: String,
        finish: OneShotFinish,
        deadline: ContinuousClock.Instant
    ) async {
        await withDiagnosticPhase("\(phase), background close of channel \(id)") {
            await acquireOperation()
            defer { releaseOperation() }

            let identity = ChannelIdentity.oneShot(id)
            var sendingEOF = true
            if case .drainExec(var progress, let reachedEOF) = finish {
                if !reachedEOF, oneShotChannels[id] != nil {
                    do {
                        _ = try await runExecExchange(
                            identity: identity,
                            &progress,
                            deadline: deadline
                        ) { _ in false }
                    } catch {
                        // Closed below either way: a command still running
                        // when the call's budget ends is cut off, as a
                        // timed-out exec is.
                        SSHDiagnostics.note(
                            "\(diagnosticContext) stopped draining: \(normalize(error))")
                    }
                }
                sendingEOF = !progress.sentEOF
            }
            guard oneShotChannels[id] != nil else { return }
            do {
                try await cleanChannel(
                    identity: identity,
                    deadline: max(
                        deadline,
                        ContinuousClock.now.advanced(by: Self.oneShotCleanupBudget)),
                    cancellable: false,
                    sendingEOF: sendingEOF)
                removeOneShot(id)
            } catch {
                SSHDiagnostics.note(
                    "\(diagnosticContext) failed: \(normalize(error)); "
                        + "invalidating the session, the only owner left of the channel")
                invalidateResources()
            }
        }
    }

    private func resolveChannel(
        _ identity: ChannelIdentity,
        allowClosing: Bool = false
    ) throws -> OpaquePointer {
        let session = try requireSession()
        switch identity {
        case .oneShot(let id):
            guard let entry = oneShotChannels[id], entry.session == session else {
                throw SSHError.channelFailed
            }
            return entry.channel
        case .pty, .execStream:
            guard let state = self[sessionChannel: identity], allowClosing || state.acceptsIO else {
                throw SSHError.channelFailed
            }
            return state.channel
        case .streamLocal(let id):
            guard let state = streamLocalChannels[id], allowClosing || state.acceptsIO else {
                throw SSHError.channelFailed
            }
            return state.channel
        }
    }

    private func writeChannel(
        _ channel: OpaquePointer,
        data: Data,
        offset: Int
    ) -> Int {
        data.withUnsafeBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return libssh2_channel_write_ex(
                channel,
                0,
                baseAddress.advanced(by: offset).assumingMemoryBound(to: CChar.self),
                data.count - offset)
        }
    }

    private func writeChannelOnce(
        identity: ChannelIdentity,
        data: Data,
        offset: Int
    ) -> Int32? {
        guard let channel = try? resolveChannel(identity) else { return nil }
        let written = writeChannel(channel, data: data, offset: offset)
        if written == Int(LIBSSH2_ERROR_EAGAIN) { return LIBSSH2_ERROR_EAGAIN }
        if written >= 0 { return 0 }
        return Int32(clamping: written)
    }

    private func readSFTPOnce(sftpID: UInt64, fileID: UInt64) -> Int32? {
        guard let file = sftpClients[sftpID]?.files[fileID] else { return nil }
        var scratch = [UInt8](repeating: 0, count: 64 * 1_024)
        let read = scratch.withUnsafeMutableBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return libssh2_sftp_read(
                file,
                baseAddress.assumingMemoryBound(to: CChar.self),
                bytes.count)
        }
        if read == Int(LIBSSH2_ERROR_EAGAIN) { return LIBSSH2_ERROR_EAGAIN }
        if read >= 0 { return 0 }
        return Int32(clamping: read)
    }

    private func writeSFTPOnce(
        sftpID: UInt64,
        fileID: UInt64,
        data: Data,
        offset: Int
    ) -> Int32? {
        guard let file = sftpClients[sftpID]?.files[fileID] else { return nil }
        let written = data.withUnsafeBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return libssh2_sftp_write(
                file,
                baseAddress.advanced(by: offset).assumingMemoryBound(to: CChar.self),
                data.count - offset)
        }
        if written == Int(LIBSSH2_ERROR_EAGAIN) { return LIBSSH2_ERROR_EAGAIN }
        if written >= 0 { return 0 }
        return Int32(clamping: written)
    }

    private func sampleTransportSendOwnerIfNeeded() {
#if DEBUG
        guard ownerSamplesForTesting != nil else { return }
        let outboundPending: Bool
        if let session {
            outboundPending = sessionReportsOutbound(session)
        } else {
            outboundPending = false
        }
        ownerSamplesForTesting?.append(
            TransportSendOwnerSample(
                hasOwner: transportSendOwner != nil,
                isValid: valid,
                outboundPending: outboundPending))
#endif
    }

#if DEBUG
    private func holdOutboundWriteParkForTestingIfNeeded() async {
        guard let hold = nextOutboundWriteParkHoldForTesting else { return }
        nextOutboundWriteParkHoldForTesting = nil
        await hold()
    }

    private func holdOneShotEstablishedForTestingIfNeeded() async throws {
        guard let hold = nextOneShotEstablishedHoldForTesting else { return }
        nextOneShotEstablishedHoldForTesting = nil
        try await hold()
    }
#endif

    private func extractHostKey(_ session: OpaquePointer) throws -> SSHHostKey {
        var length = 0
        var type: Int32 = 0
        guard
            let keyPointer = libssh2_session_hostkey(session, &length, &type),
            length > 0,
            let methodPointer = libssh2_session_methods(session, LIBSSH2_METHOD_HOSTKEY)
        else {
            throw SSHError.algorithmNegotiationFailed
        }
        return SSHHostKey(
            algorithm: String(cString: methodPointer),
            key: Data(bytes: keyPointer, count: length))
    }

    /// Opens one channel through libssh2's pipelined open (patch 0004): the
    /// request and its reply wait live on the channel itself, so up to
    /// `channelOpenLimit` opens await their replies at once, and SFTP init's
    /// stock open may run meanwhile. Unless `yielding` is false the opener
    /// releases the operation mutex between finish turns (WS3); whatever
    /// another operation reads off the socket meanwhile stays queued for it,
    /// because `libssh2_channel_open_finish` waits for a reply carrying this
    /// channel's local id and patch 0003 keeps any other wait reading past
    /// it. The wait cannot sleep on a reply someone else already took: the
    /// plan's receive count (`SessionActivity`) releases it the moment
    /// another operation pulls bytes off the socket.
    ///
    /// A failure that leaves the session intact throws
    /// `SettledChannelOpenError`: a refusal, whose channel is only freed
    /// locally, or an open interrupted by cancellation or its deadline once
    /// `freeAbandonedChannelOpen` has freed its channel. That free returns
    /// before this throws, so a caller's channel budget — which every caller
    /// gives back when the call throws — stays held until the channel is
    /// gone. Any other failure has invalidated the session or must.
    private func openChannel(
        _ request: ChannelOpenRequest,
        deadline: ContinuousClock.Instant,
        yielding: Bool = true
    ) async throws -> OpaquePointer {
        do {
            try await claimChannelOpenSlot(.pipelined, deadline: deadline, cancellable: true)
        } catch {
            throw SettledChannelOpenError(underlying: normalize(error))
        }
        defer { releaseChannelOpenSlot(.pipelined) }
        diagnosticStep = "channel open"
        do {
            try checkProgress(deadline: deadline)
        } catch {
            throw SettledChannelOpenError(underlying: normalize(error))
        }
        let session = try requireSession()
        guard let channel = startChannelOpen(request, on: session) else {
            // Bad input or no memory: nothing was allocated or sent.
            noteFailure(libssh2_session_last_errno(session))
            throw SettledChannelOpenError(underlying: .channelFailed)
        }
        nextPendingChannelOpenID &+= 1
        let id = nextPendingChannelOpenID
        pendingChannelOpens[id] = PendingChannelOpen(channel: channel, session: session)
        let owner = allocateTransportSendOwner()
        do {
            while true {
                try checkProgress(deadline: deadline)
                try await waitForTransportSendAdmission(
                    owner: owner,
                    deadline: deadline,
                    cancellable: true)
                guard let pending = pendingChannelOpens[id], valid, self.session == pending.session
                else {
                    throw SSHError.connectionInvalidated
                }
                let result = libssh2_channel_open_finish(pending.channel)
                let disposition = notePacketProducingResult(
                    result,
                    owner: owner,
                    session: pending.session)
                if result == 0 {
                    pendingChannelOpens[id] = nil
                    applyTransportSendOwnerDisposition(disposition)
                    return pending.channel
                }
                guard result == LIBSSH2_ERROR_EAGAIN else {
                    throw failedChannelOpen(
                        id: id,
                        request: request,
                        result: result,
                        disposition: disposition)
                }
#if DEBUG
                pendingChannelOpenPeakForTesting = max(
                    pendingChannelOpenPeakForTesting,
                    pendingChannelOpens.count)
#endif
                if yielding {
                    let plan = sessionWaitPlan(pending.session)
                    releaseOperation()
                    do {
                        try await awaitSessionProgress(plan, until: deadline)
                    } catch {
                        await acquireOperation()
                        throw error
                    }
                    await acquireOperation()
                } else {
                    try await waitForSession(pending.session, deadline: deadline)
                }
            }
        } catch let error as SettledChannelOpenError {
            throw error
        } catch {
            // Gone from the registry: the session took the channel with it.
            guard pendingChannelOpens[id] != nil else { throw error }
            let normalized = normalize(error)
            if await freeAbandonedChannelOpen(id: id, owner: owner, yielding: yielding) {
                throw SettledChannelOpenError(underlying: normalized)
            }
            throw normalized
        }
    }

    private func startChannelOpen(
        _ request: ChannelOpenRequest,
        on session: OpaquePointer
    ) -> OpaquePointer? {
        switch request {
        case .session:
            libssh2_channel_open_start(
                session,
                "session",
                UInt32("session".utf8.count),
                2 * 1024 * 1024,
                32 * 1024,
                nil,
                0)
        case .streamLocal(let socketPath):
            socketPath.withCString { socketPathPointer in
                libssh2_channel_direct_streamlocal_start(
                    session,
                    socketPathPointer,
                    "127.0.0.1",
                    0)
            }
        case .directTCPIP(let host, let port):
            host.withCString { hostPointer in
                libssh2_channel_direct_tcpip_start(
                    session,
                    hostPointer,
                    Int32(port),
                    "127.0.0.1",
                    0)
            }
        }
    }

    /// A finish that returned neither 0 nor EAGAIN has settled its open
    /// (patch 0004 marks the channel closed), so freeing it is local. Only a
    /// refusal is settled for the caller; any other code is as uncertain as
    /// it ever was, and the caller decides as it did for a stock open.
    private func failedChannelOpen(
        id: UInt64,
        request: ChannelOpenRequest,
        result: Int32,
        disposition: TransportSendOwnerDisposition
    ) -> any Error {
        noteFailure(result)
        guard let pending = pendingChannelOpens.removeValue(forKey: id) else {
            return SSHError.connectionInvalidated
        }
        let failure: SSHError
        switch request {
        case .session:
            failure = Self.isConnectionLoss(result) ? .connectionInvalidated : .channelFailed
        case .streamLocal:
            failure = Self.mappedStreamLocalOpenError(result)
        case .directTCPIP:
            failure = classifyDirectTCPIPOpenFailure(pending.session)
        }
        guard disposition != .invalidate else {
            // The transport may still hold the request: only freeing the
            // whole session, this channel with it, can reclaim it.
            invalidateResources()
            return failure
        }
        _ = libssh2_channel_free(pending.channel)
        applyTransportSendOwnerDisposition(disposition)
        guard result == LIBSSH2_ERROR_CHANNEL_FAILURE else { return failure }
        return SettledChannelOpenError(underlying: failure)
    }

    /// Frees pending open `id` once its opener stopped waiting for it
    /// (cancellation, deadline). `libssh2_channel_free` settles an open the
    /// server may have seen first — it waits for the reply and closes a
    /// confirmed channel — and discards one the transport never took. The
    /// free is never cancellable, gets `oneShotCleanupBudget`, and yields the
    /// session between turns as the open did (C-CLOSE), reaching the channel
    /// through the registry only: when invalidation or `close` freed it with
    /// the session first, nothing is left to do, so it is freed exactly once.
    /// Returns whether the session survived. A free that cannot finish
    /// invalidates it, the only owner left of the native channel, and so does
    /// one that finished over a transport the peer had ended:
    /// `libssh2_channel_free` frees the channel whatever settling or closing
    /// it reported, a failed read or send included, so only the socket can
    /// still tell the two apart.
    private func freeAbandonedChannelOpen(
        id: UInt64,
        owner: UInt64,
        yielding: Bool
    ) async -> Bool {
        diagnosticStep = "abandoned channel open free"
#if DEBUG
        if let hold = nextAbandonedChannelOpenFreeHoldForTesting {
            nextAbandonedChannelOpenFreeHoldForTesting = nil
            releaseOperation()
            await hold()
            await acquireOperation()
        }
#endif
        let deadline = ContinuousClock.now.advanced(by: Self.oneShotCleanupBudget)
        while true {
            do {
                try await waitForTransportSendAdmission(
                    owner: owner,
                    deadline: deadline,
                    cancellable: false)
            } catch {
                return abandonUnfreedChannelOpen(id: id, owner: owner)
            }
            guard let pending = pendingChannelOpens[id], valid, session == pending.session else {
                return valid
            }
            let result = libssh2_channel_free(pending.channel)
            let disposition = notePacketProducingResult(
                result,
                owner: owner,
                session: pending.session)
            if result != LIBSSH2_ERROR_EAGAIN {
                // Only EAGAIN leaves the channel allocated.
                pendingChannelOpens[id] = nil
#if DEBUG
                abandonedChannelOpenFreesForTesting += 1
#endif
                applyTransportSendOwnerDisposition(disposition)
                if valid, transportHasEnded() {
                    SSHDiagnostics.note(
                        "\(diagnosticContext) lost its transport while freeing an abandoned "
                            + "channel open; invalidating the session")
                    invalidateResources()
                }
                return valid
            }
            if ContinuousClock.now >= deadline {
                return abandonUnfreedChannelOpen(id: id, owner: owner)
            }
            // Not cancellable, so a wait ends early only out of budget, and
            // the next turn then frees or gives up.
            if yielding {
                let plan = sessionWaitPlan(pending.session)
                releaseOperation()
                try? await awaitSessionProgress(plan, until: deadline, cancellable: false)
                await acquireOperation()
            } else {
                try? await waitForSession(pending.session, deadline: deadline, cancellable: false)
            }
        }
    }

    private func abandonUnfreedChannelOpen(id: UInt64, owner: UInt64) -> Bool {
        SSHDiagnostics.note(
            "\(diagnosticContext) could not free an abandoned channel open in time; "
                + "invalidating the session, the only owner left of the channel")
        if transportSendOwner == owner {
            abandonOwnedSend(owner: owner) {
                guard let pending = pendingChannelOpens.removeValue(forKey: id) else { return nil }
                return libssh2_channel_free(pending.channel)
            }
        } else {
            invalidateResources()
        }
        return false
    }

    /// Whether the peer has already ended the session's transport: its FIN or
    /// RST is what a non-blocking peek at the socket finds. Nothing is taken
    /// off a live socket, and nothing waits.
    private func transportHasEnded() -> Bool {
        guard descriptor >= 0 else { return true }
        var byte: UInt8 = 0
        let received = Darwin.recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if received >= 0 { return received == 0 }
        let code = errno
        return code != EAGAIN && code != EWOULDBLOCK && code != EINTR
    }

    /// Two causes arrive on the same failure path and the errno is all that
    /// separates them. SSH forwarding policy or a stale socket refuses this one
    /// channel and leaves the session healthy, so the callers must spare it;
    /// a socket-level loss means there is no session left to spare, and
    /// reporting it as a refusal is what lets `isReusable` stay true on a dead
    /// connection. `mappedSFTPError` splits the same two cases the same way,
    /// down to the verdict it returns for the loss.
    ///
    /// `mapSessionError` is deliberately not consulted: it classifies
    /// handshake- and authentication-class codes and funnels everything else
    /// into `.connectionFailed`, which would erase the `.streamLocalOpenFailed`
    /// the socket diagnostic above this layer keys on.
    private static func mappedStreamLocalOpenError(_ code: Int32) -> SSHError {
        if isConnectionLoss(code) { return .connectionInvalidated }
        return .streamLocalOpenFailed
    }

    private func startExec(
        identity: ChannelIdentity,
        command: String,
        deadline: ContinuousClock.Instant
    ) async throws {
        diagnosticStep = "exec request"
        let result = try await repeatUntilCompleteYielding(
            deadline: deadline,
            identity: identity
        ) { channel in
            command.withCString { commandPointer in
                libssh2_channel_process_startup(
                    channel,
                    "exec",
                    UInt32("exec".utf8.count),
                    commandPointer,
                    UInt32(command.utf8.count))
            }
        }
        guard result == 0 else {
            noteFailure(result)
            throw SSHError.channelFailed
        }
    }

    /// Requests the PTY and execs `command` back to back on channel
    /// `identity` (patch 0002), so both replies take one round trip instead
    /// of two. Stderr merges into stdout first, as a terminal shows it.
    private func startPTYProcess(
        identity: ChannelIdentity,
        terminal: String,
        columns: Int,
        rows: Int,
        command: String,
        deadline: ContinuousClock.Instant
    ) async throws {
        diagnosticStep = "PTY request"
        let mergeChannel = try resolveChannel(identity)
        let mergeResult = libssh2_channel_handle_extended_data2(
            mergeChannel,
            LIBSSH2_CHANNEL_EXTENDED_DATA_MERGE)
        guard mergeResult == 0 else { throw SSHError.channelFailed }

        // Waits for the replies without holding the session: the requests'
        // state is the channel's own. Every turn passes the same arguments,
        // as the call requires while it returns EAGAIN.
        var denied: Int32 = 0
        let result = try await repeatUntilCompleteYielding(
            deadline: deadline,
            identity: identity
        ) { channel in
            terminal.withCString { terminalPointer in
                command.withCString { commandPointer in
                    libssh2_channel_request_pty_process_startup(
                        channel,
                        terminalPointer,
                        UInt32(terminal.utf8.count),
                        nil,
                        0,
                        Int32(columns),
                        Int32(rows),
                        0,
                        0,
                        "exec",
                        UInt32("exec".utf8.count),
                        commandPointer,
                        UInt32(command.utf8.count),
                        &denied)
                }
            }
        }
        if let failure = Self.ptyProcessStartupFailure(result: result, denied: denied) {
            noteFailure(result)
            throw failure
        }
    }

    /// Nil when the server granted both the PTY and the exec. A refused PTY
    /// reads as `.ptyDenied` even when the exec was refused too: it is the
    /// request that went first, and the one a `no-pty` key or `PermitTTY no`
    /// refuses. An exec refused alone is the ordinary exec failure.
    static func ptyProcessStartupFailure(result: Int32, denied: Int32) -> SSHError? {
        guard result != 0 else { return nil }
        guard
            result == LIBSSH2_ERROR_CHANNEL_REQUEST_DENIED,
            denied & LIBSSH2_CHANNEL_DENIED_PTY != 0
        else {
            return .channelFailed
        }
        return .ptyDenied
    }

    private func exchange(
        identity: ChannelIdentity,
        input: Data,
        deadline: ContinuousClock.Instant
    ) async throws -> SSHExecResult {
        var progress = ExecExchangeProgress(input: input)
        _ = try await runExecExchange(identity: identity, &progress, deadline: deadline) { _ in
            false
        }
        let exitStatus = try await exitStatusAfterChannelClose(
            identity: identity,
            deadline: deadline)
        return SSHExecResult(
            stdout: progress.stdout,
            stderr: progress.stderr,
            exitStatus: exitStatus,
            reachedEOF: true)
    }

    /// How far one one-shot exec exchange has got, so a later call — the
    /// background drain `executeUntilLine` leaves behind — continues where an
    /// earlier one stopped instead of resending input or EOF.
    private struct ExecExchangeProgress: Sendable {
        let input: Data
        var inputOffset = 0
        var sentEOF = false
        var stdout = Data()
        var stderr = Data()
        /// Stderr beyond this many bytes is read and dropped.
        var standardErrorLimit = Int.max
        /// False once nobody will look at the output: it is read and dropped.
        var keepsOutput = true
    }

    /// Writes the input, sends EOF, and reads both streams until remote EOF
    /// (returns true) or until `stop` accepts the stdout kept so far (returns
    /// false). `stop` sees stdout only when a read added to it. No transport
    /// send this call owns is left pending when it returns or throws.
    private func runExecExchange(
        identity: ChannelIdentity,
        _ progress: inout ExecExchangeProgress,
        deadline: ContinuousClock.Instant,
        stop: (Data) throws -> Bool
    ) async throws -> Bool {
        diagnosticStep = "exchange"
        let input = progress.input
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let writeOwner = allocateTransportSendOwner()
        let eofOwner = allocateTransportSendOwner()
        let stdoutOwner = allocateTransportSendOwner()
        let stderrOwner = allocateTransportSendOwner()

        func drainOwnedSends(inputOffset: Int) async {
            await finishOwnedSendIfNeeded(owner: writeOwner) {
                writeChannelOnce(identity: identity, data: input, offset: inputOffset)
            }
            await finishOwnedSendIfNeeded(owner: eofOwner) {
                guard let channel = try? resolveChannel(identity) else { return nil }
                return libssh2_channel_send_eof(channel)
            }
            await finishOwnedSendIfNeeded(owner: stdoutOwner) {
                guard let channel = try? resolveChannel(identity) else { return nil }
                var scratch = [UInt8](repeating: 0, count: 16 * 1024)
                return readOnce(channel: channel, stream: 0, buffer: &scratch)
            }
            await finishOwnedSendIfNeeded(owner: stderrOwner) {
                guard let channel = try? resolveChannel(identity) else { return nil }
                var scratch = [UInt8](repeating: 0, count: 16 * 1024)
                return readOnce(
                    channel: channel,
                    stream: Int32(SSH_EXTENDED_DATA_STDERR),
                    buffer: &scratch)
            }
        }

        while true {
            do {
                try checkProgress(deadline: deadline)
                // Taken before this turn's reads. Each read drains the whole
                // socket into libssh2's queue, so the stderr read can queue
                // stdout, EOF and CLOSE that arrived after the stdout read
                // looked: no bytes for stderr, EOF masked by the queued
                // stdout, and no socket edge left. A watch taken after the
                // reads would then sleep out the deadline on a finished exec.
                let watch = activity.watch()
                var madeProgress = false
                var skipReads = false

                if progress.inputOffset < input.count {
                    try await waitForTransportSendAdmission(
                        owner: writeOwner,
                        deadline: deadline,
                        cancellable: true)
                    let channel = try resolveChannel(identity)
                    let session = try requireSession()
                    let written = writeChannel(channel, data: input, offset: progress.inputOffset)
                    let disposition = notePacketProducingWrite(
                        written,
                        owner: writeOwner,
                        session: session)
                    applyTransportSendOwnerDisposition(disposition)
                    if written > 0 {
                        progress.inputOffset += written
                        madeProgress = true
                    } else if written != Int(LIBSSH2_ERROR_EAGAIN) {
                        throw SSHError.channelFailed
                    } else if transportSendOwner == writeOwner {
                        skipReads = true
                    }
                } else if !progress.sentEOF {
                    try await waitForTransportSendAdmission(
                        owner: eofOwner,
                        deadline: deadline,
                        cancellable: true)
                    let channel = try resolveChannel(identity)
                    let session = try requireSession()
                    let result = libssh2_channel_send_eof(channel)
                    let disposition = notePacketProducingResult(
                        result,
                        owner: eofOwner,
                        session: session)
                    applyTransportSendOwnerDisposition(disposition)
                    if result == 0 {
                        progress.sentEOF = true
                        madeProgress = true
                    } else if result != LIBSSH2_ERROR_EAGAIN {
                        throw SSHError.channelFailed
                    } else if transportSendOwner == eofOwner {
                        skipReads = true
                    }
                }

                if !skipReads {
                    try await waitForTransportSendAdmission(
                        owner: stdoutOwner,
                        deadline: deadline,
                        cancellable: true)
                    let stdoutChannel = try resolveChannel(identity)
                    let session = try requireSession()
                    let stdoutRead = try readAvailableNoting(
                        channel: stdoutChannel,
                        stream: 0,
                        buffer: &buffer,
                        owner: stdoutOwner,
                        session: session)
                    if stdoutRead.count > 0 {
                        madeProgress = true
                        if progress.keepsOutput {
                            progress.stdout.append(stdoutRead)
                            if try stop(progress.stdout) {
                                await drainOwnedSends(inputOffset: progress.inputOffset)
                                return false
                            }
                        }
                    }
                    if transportSendOwner != stdoutOwner {
#if DEBUG
                        if !madeProgress,
                            let hold = nextExecExchangeStandardErrorReadHoldForTesting {
                            nextExecExchangeStandardErrorReadHoldForTesting = nil
                            try await hold()
                        }
#endif
                        try await waitForTransportSendAdmission(
                            owner: stderrOwner,
                            deadline: deadline,
                            cancellable: true)
                        let stderrChannel = try resolveChannel(identity)
                        let stderrSession = try requireSession()
                        let stderrRead = try readAvailableNoting(
                            channel: stderrChannel,
                            stream: Int32(SSH_EXTENDED_DATA_STDERR),
                            buffer: &buffer,
                            owner: stderrOwner,
                            session: stderrSession)
                        if stderrRead.count > 0 {
                            madeProgress = true
                            if progress.keepsOutput {
                                let room = progress.standardErrorLimit - progress.stderr.count
                                progress.stderr.append(stderrRead.prefix(max(room, 0)))
                            }
                        }
                    }
                }

                let eofChannel = try resolveChannel(identity)
                if libssh2_channel_eof(eofChannel) == 1 {
                    await drainOwnedSends(inputOffset: progress.inputOffset)
                    return true
                }

                let plan = sessionWaitPlan(try requireSession(), watching: watch)
                if madeProgress {
                    releaseOperation()
                    await Task.yield()
                    await acquireOperation()
                } else {
                    releaseOperation()
                    do {
                        try await awaitSessionProgress(plan, until: deadline)
                    } catch {
                        let drainInputOffset = progress.inputOffset
                        await acquireOperation()
                        await drainOwnedSends(inputOffset: drainInputOffset)
                        throw error
                    }
                    await acquireOperation()
                }
            } catch {
                await drainOwnedSends(inputOffset: progress.inputOffset)
                throw error
            }
        }
    }

    private func exchangeResponseLine(
        identity: ChannelIdentity,
        request: Data,
        maximumResponseBytes: Int,
        deadline: ContinuousClock.Instant,
        beforeRequestWrite: (@Sendable () async throws -> Void)? = nil,
        onRequestWritten: (@Sendable () async -> Void)? = nil
    ) async throws -> Data {
        diagnosticStep = "response exchange"
        var requestOffset = 0
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var didAnnounceWrite = false
        let writeOwner = allocateTransportSendOwner()
        let readOwner = allocateTransportSendOwner()

        try await beforeRequestWrite?()

        func drainOwnedSends(requestOffset: Int) async {
            await finishOwnedSendIfNeeded(owner: writeOwner) {
                writeChannelOnce(identity: identity, data: request, offset: requestOffset)
            }
            await finishOwnedSendIfNeeded(owner: readOwner) {
                guard let channel = try? resolveChannel(identity) else { return nil }
                var scratch = [UInt8](repeating: 0, count: 16 * 1024)
                return readOnce(channel: channel, stream: 0, buffer: &scratch)
            }
        }

        while true {
            do {
                try checkProgress(deadline: deadline)
                var madeProgress = false
                var skipRead = false

                if requestOffset < request.count {
                    try await waitForTransportSendAdmission(
                        owner: writeOwner,
                        deadline: deadline,
                        cancellable: true)
                    let channel = try resolveChannel(identity)
                    let session = try requireSession()
                    let written = writeChannel(channel, data: request, offset: requestOffset)
                    let disposition = notePacketProducingWrite(
                        written,
                        owner: writeOwner,
                        session: session)
                    applyTransportSendOwnerDisposition(disposition)
                    if written > 0 {
                        requestOffset += written
                        madeProgress = true
                    } else if written != Int(LIBSSH2_ERROR_EAGAIN) {
                        throw SSHError.channelFailed
                    } else if transportSendOwner == writeOwner {
                        skipRead = true
                    }
                }
                if requestOffset == request.count, !didAnnounceWrite {
                    didAnnounceWrite = true
                    await onRequestWritten?()
                }

                if !skipRead {
                    try await waitForTransportSendAdmission(
                        owner: readOwner,
                        deadline: deadline,
                        cancellable: true)
                    let channel = try resolveChannel(identity)
                    let session = try requireSession()
                    let received = try readAvailableNoting(
                        channel: channel,
                        stream: 0,
                        buffer: &buffer,
                        owner: readOwner,
                        session: session)
                    if !received.isEmpty {
                        response.append(received)
                        madeProgress = true
                        if let newline = response.firstIndex(of: 0x0A) {
                            let lineLength = response.distance(
                                from: response.startIndex,
                                to: newline) + 1
                            guard lineLength <= maximumResponseBytes else {
                                throw SSHError.responseTooLarge(limit: maximumResponseBytes)
                            }
                            return Data(response.prefix(lineLength))
                        }
                        guard response.count <= maximumResponseBytes else {
                            throw SSHError.responseTooLarge(limit: maximumResponseBytes)
                        }
                    }
                }

                if libssh2_channel_eof(try resolveChannel(identity)) == 1 {
                    throw SSHError.unexpectedEOF
                }

                let plan = sessionWaitPlan(try requireSession())
                if madeProgress {
                    releaseOperation()
                    await Task.yield()
                    await acquireOperation()
                } else {
                    releaseOperation()
                    do {
                        try await awaitSessionProgress(plan, until: deadline)
                    } catch {
                        let drainRequestOffset = requestOffset
                        await acquireOperation()
                        await drainOwnedSends(requestOffset: drainRequestOffset)
                        throw error
                    }
                    await acquireOperation()
                }
            } catch {
                await drainOwnedSends(requestOffset: requestOffset)
                throw error
            }
        }
    }

    private func readAvailable(
        channel: OpaquePointer,
        stream: Int32,
        buffer: inout [UInt8]
    ) throws -> Data {
        let count = rawChannelRead(channel: channel, stream: stream, buffer: &buffer)
        if count > 0 { return Data(buffer.prefix(count)) }
        if count == 0 || count == Int(LIBSSH2_ERROR_EAGAIN) { return Data() }
        throw SSHError.channelFailed
    }

    private func readAvailableNoting(
        channel: OpaquePointer,
        stream: Int32,
        buffer: inout [UInt8],
        owner: UInt64,
        session: OpaquePointer
    ) throws -> Data {
        let count = rawChannelRead(channel: channel, stream: stream, buffer: &buffer)
        let disposition = notePacketProducingWrite(
            count,
            owner: owner,
            session: session)
        applyTransportSendOwnerDisposition(disposition)
        if count > 0 { return Data(buffer.prefix(count)) }
        if count == 0 || count == Int(LIBSSH2_ERROR_EAGAIN) { return Data() }
        throw SSHError.channelFailed
    }

    private func readOnce(
        channel: OpaquePointer,
        stream: Int32,
        buffer: inout [UInt8]
    ) -> Int32 {
        let count = rawChannelRead(channel: channel, stream: stream, buffer: &buffer)
        if count == Int(LIBSSH2_ERROR_EAGAIN) { return LIBSSH2_ERROR_EAGAIN }
        if count >= 0 { return 0 }
        return Int32(clamping: count)
    }

    /// `readOnce` that appends the bytes it read to `kept` instead of
    /// discarding them.
    private func readOnce(
        channel: OpaquePointer,
        stream: Int32,
        buffer: inout [UInt8],
        keeping kept: inout Data
    ) -> Int32 {
        let count = rawChannelRead(channel: channel, stream: stream, buffer: &buffer)
        if count == Int(LIBSSH2_ERROR_EAGAIN) { return LIBSSH2_ERROR_EAGAIN }
        if count > 0 { kept.append(contentsOf: buffer.prefix(count)) }
        if count >= 0 { return 0 }
        return Int32(clamping: count)
    }

    private func rawChannelRead(
        channel: OpaquePointer,
        stream: Int32,
        buffer: inout [UInt8]
    ) -> Int {
        buffer.withUnsafeMutableBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return libssh2_channel_read_ex(
                channel,
                stream,
                baseAddress.assumingMemoryBound(to: CChar.self),
                bytes.count)
        }
    }

    /// Close the remote channel, wait for the peer to acknowledge close, then
    /// read exit status. Remote EOF can precede the exit-status request, so
    /// status is only reliable after wait_closed.
    private func exitStatusAfterChannelClose(
        identity: ChannelIdentity,
        deadline: ContinuousClock.Instant,
        allowClosing: Bool = false
    ) async throws -> Int32 {
        diagnosticStep = "channel close"
        let closeResult = try await repeatUntilCompleteYielding(
            deadline: deadline,
            identity: identity,
            allowClosing: allowClosing
        ) {
            libssh2_channel_close($0)
        }
        guard closeResult == 0 || closeResult == LIBSSH2_ERROR_CHANNEL_CLOSED else {
            throw SSHError.channelFailed
        }
        diagnosticStep = "wait closed"
        let waitResult = try await repeatUntilCompleteYielding(
            deadline: deadline,
            identity: identity,
            allowClosing: allowClosing
        ) {
            libssh2_channel_wait_closed($0)
        }
        guard waitResult == 0 || waitResult == LIBSSH2_ERROR_CHANNEL_CLOSED else {
            throw SSHError.channelFailed
        }
        return Int32(libssh2_channel_get_exit_status(
            try resolveChannel(identity, allowClosing: allowClosing)))
    }

    /// `sendingEOF: false` skips the explicit EOF for a channel whose EOF
    /// already went out; `libssh2_channel_close` still sends one first if
    /// it has not.
    private func cleanChannel(
        identity: ChannelIdentity,
        deadline: ContinuousClock.Instant,
        cancellable: Bool,
        allowClosing: Bool = false,
        sendingEOF: Bool = true
    ) async throws {
        if sendingEOF {
            diagnosticStep = "send EOF"
            let eofResult = try await repeatUntilCompleteYielding(
                deadline: deadline,
                cancellable: cancellable,
                identity: identity,
                allowClosing: allowClosing
            ) {
                libssh2_channel_send_eof($0)
            }
            guard eofResult == 0
                || eofResult == LIBSSH2_ERROR_CHANNEL_EOF_SENT
                || eofResult == LIBSSH2_ERROR_CHANNEL_CLOSED
            else {
                throw SSHError.channelFailed
            }
        }

        diagnosticStep = "channel close"
        let closeResult = try await repeatUntilCompleteYielding(
            deadline: deadline,
            cancellable: cancellable,
            identity: identity,
            allowClosing: allowClosing
        ) {
            libssh2_channel_close($0)
        }
        guard closeResult == 0 || closeResult == LIBSSH2_ERROR_CHANNEL_CLOSED else {
            throw SSHError.channelFailed
        }

        diagnosticStep = "channel free"
        let freeResult = try await repeatUntilCompleteYielding(
            deadline: deadline,
            cancellable: cancellable,
            identity: identity,
            allowClosing: allowClosing
        ) {
            libssh2_channel_free($0)
        }
        guard freeResult == 0 else { throw SSHError.channelFailed }
    }

    private func cleanChannel(
        _ channel: OpaquePointer,
        session: OpaquePointer,
        deadline: ContinuousClock.Instant,
        cancellable: Bool
    ) async throws {
        diagnosticStep = "send EOF"
        let eofResult = try await repeatUntilComplete(
            deadline: deadline,
            cancellable: cancellable
        ) {
            libssh2_channel_send_eof(channel)
        }
        guard eofResult == 0
            || eofResult == LIBSSH2_ERROR_CHANNEL_EOF_SENT
            || eofResult == LIBSSH2_ERROR_CHANNEL_CLOSED
        else {
            throw SSHError.channelFailed
        }

        diagnosticStep = "channel close"
        let closeResult = try await repeatUntilComplete(
            deadline: deadline,
            cancellable: cancellable
        ) {
            libssh2_channel_close(channel)
        }
        guard closeResult == 0 || closeResult == LIBSSH2_ERROR_CHANNEL_CLOSED else {
            throw SSHError.channelFailed
        }

        diagnosticStep = "channel free"
        let freeResult = try await repeatUntilComplete(
            deadline: deadline,
            cancellable: cancellable
        ) {
            libssh2_channel_free(channel)
        }
        guard freeResult == 0 else { throw SSHError.channelFailed }
    }

    private func beginSFTPUse(_ id: UInt64) throws {
        guard valid else { throw SSHError.connectionInvalidated }
        // Closed, or shut down under a caller queued behind a request that was
        // cut off (`withSFTPUse`): the channel is gone, the session is not.
        guard sftpClients[id] != nil else { throw SSHError.channelFailed }
        sftpUses[id, default: 0] += 1
    }

    private func endSFTPUse(_ id: UInt64) {
        guard let count = sftpUses[id] else { return }
        if count <= 1 {
            sftpUses.removeValue(forKey: id)
            wakeSFTPIdleWaiters()
        } else {
            sftpUses[id] = count - 1
        }
    }

    private func wakeSFTPIdleWaiters() {
        let ids = Array(sftpIdleWaiters.keys)
        for id in ids { resumeSFTPIdleWaiter(id: id, .success(())) }
    }

    private func waitUntilSFTPIdle(
        id: UInt64,
        deadline: ContinuousClock.Instant,
        cancellable: Bool
    ) async throws {
        while (sftpUses[id] ?? 0) > 0 {
            if cancellable {
                try checkProgress(deadline: deadline)
            } else if ContinuousClock.now >= deadline {
                throw noteTimedOut()
            }
            nextSFTPIdleWaiterID &+= 1
            let waiterID = nextSFTPIdleWaiterID
            do {
                try await waitForSFTPIdleSignal(
                    id: waiterID,
                    deadline: deadline,
                    cancellable: cancellable)
            } catch {
                if error as? SSHError == .timedOut { noteTimedOutOnce() }
                await acquireOperation()
                throw error
            }
            await acquireOperation()
            if cancellable {
                try checkProgress(deadline: deadline)
            } else if ContinuousClock.now >= deadline {
                throw noteTimedOut()
            }
            guard valid else { throw SSHError.connectionInvalidated }
        }
    }

    private func waitForSFTPIdleSignal(
        id: UInt64,
        deadline: ContinuousClock.Instant,
        cancellable: Bool
    ) async throws {
        if cancellable {
            try await withTaskCancellationHandler {
                try await parkSFTPIdleWaiterUntilDeadline(
                    id: id,
                    deadline: deadline,
                    cancellable: true)
            } onCancel: {
                Task { await self.resumeSFTPIdleWaiter(id: id, .failure(SSHError.cancelled)) }
            }
        } else {
            try await parkSFTPIdleWaiterUntilDeadline(
                id: id,
                deadline: deadline,
                cancellable: false)
        }
    }

    private func parkSFTPIdleWaiterUntilDeadline(
        id: UInt64,
        deadline: ContinuousClock.Instant,
        cancellable: Bool
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            guard !cancellable || !Task.isCancelled else {
                releaseOperation()
                continuation.resume(throwing: SSHError.cancelled)
                return
            }
            let deadlineTask = Task {
                do {
                    try await Task.sleep(until: deadline, clock: .continuous)
                } catch {
                    return
                }
                self.resumeSFTPIdleWaiter(id: id, .failure(SSHError.timedOut))
            }
            sftpIdleWaiters[id] = DriverWaiter(
                continuation: continuation,
                deadlineTask: deadlineTask)
            releaseOperation()
        }
    }

    private func resumeSFTPIdleWaiter(
        id: UInt64,
        _ result: Result<Void, any Error>
    ) {
        guard let waiter = sftpIdleWaiters.removeValue(forKey: id) else { return }
        waiter.deadlineTask.cancel()
        waiter.continuation.resume(with: result)
    }

    /// Runs `body` as the subsystem's only user.
    ///
    /// A body that is cancelled or times out can leave a request whose reply
    /// is still due in one of libssh2's per-kind continuation slots. Draining
    /// the send side does not help once the packet has gone out: the next
    /// open, stat, `fstat`, or read of that kind would resume the abandoned
    /// call and take its reply as its own (README, "SFTP is a second
    /// exception"). With `reclaimOnInterruption` the subsystem is therefore
    /// shut down before the use ends, and callers queued behind it find the
    /// client gone (`.channelFailed`) instead of inheriting that request.
    /// Writes opt out: their caller still owes the path it staged a
    /// compensating unlink over this subsystem, and closes it afterwards.
    private func withSFTPUse<T: Sendable>(
        id: UInt64,
        deadline: ContinuousClock.Instant,
        reclaimOnInterruption: Bool = true,
        _ body: () async throws -> T
    ) async throws -> T {
        await acquireOperation()
        do {
            try await waitUntilSFTPIdle(
                id: id,
                deadline: deadline,
                cancellable: true)
            try beginSFTPUse(id)
        } catch {
            releaseOperation()
            throw error
        }
        releaseOperation()
        do {
            let result = try await body()
            await acquireOperation()
            endSFTPUse(id)
            releaseOperation()
            return result
        } catch {
            await acquireOperation()
            if reclaimOnInterruption {
                let normalized = normalize(error)
                if normalized == .cancelled || normalized == .timedOut {
                    await reclaimInterruptedSFTPHoldingOperation(id: id)
                }
            }
            endSFTPUse(id)
            releaseOperation()
            throw error
        }
    }

    private func holdOwnedLoopTopForTestingIfNeeded(owner: UInt64) async throws {
#if DEBUG
        guard transportSendOwner == owner, let hold = nextOwnedLoopTopHoldForTesting else {
            return
        }
        nextOwnedLoopTopHoldForTesting = nil
        try await hold()
#else
        _ = owner
#endif
    }

    private func checkProgressFinishingOwnedSend(
        owner: UInt64,
        deadline: ContinuousClock.Instant,
        cancellable: Bool,
        drive: () -> Int32?
    ) async throws {
        do {
            try await holdOwnedLoopTopForTestingIfNeeded(owner: owner)
        } catch {
            let normalized = normalize(error)
            await finishOwnedSendIfNeeded(owner: owner, drive: drive)
            throw normalized
        }
        let cancelled = cancellable && Task.isCancelled
        let timedOut = ContinuousClock.now >= deadline
        guard cancelled || timedOut else { return }
        if timedOut && !cancelled { noteTimedOutOnce() }
        await finishOwnedSendIfNeeded(owner: owner, drive: drive)
        if cancelled { throw SSHError.cancelled }
        throw noteTimedOut()
    }

    @discardableResult
    private func repeatUntilCompleteHolding(
        deadline: ContinuousClock.Instant,
        cancellable: Bool = true,
        _ operation: () -> Int32
    ) async throws -> Int32 {
        let owner = allocateTransportSendOwner()
        while true {
            try await checkProgressFinishingOwnedSend(
                owner: owner,
                deadline: deadline,
                cancellable: cancellable,
                drive: operation)
            let session = try requireSession()
            let result = operation()
            let disposition = notePacketProducingResult(
                result,
                owner: owner,
                session: session)
            if result != LIBSSH2_ERROR_EAGAIN {
                applyTransportSendOwnerDisposition(disposition)
                return result
            }
            do {
                try await waitForSession(
                    session,
                    deadline: deadline,
                    cancellable: cancellable)
            } catch {
                await finishOwnedSendIfNeeded(owner: owner, drive: operation)
                throw error
            }
        }
    }

    @discardableResult
    private func repeatUntilCompleteHoldingSFTP(
        id: UInt64,
        deadline: ContinuousClock.Instant,
        cancellable: Bool = true,
        _ operation: (OpaquePointer) -> Int32
    ) async throws -> PacketOperationResult {
        try await waitUntilSFTPIdle(
            id: id,
            deadline: deadline,
            cancellable: cancellable)
        try beginSFTPUse(id)
        defer { endSFTPUse(id) }
        let owner = allocateTransportSendOwner()
        func drive() -> Int32? {
            guard let sftp = sftpClients[id]?.handle else { return nil }
            return operation(sftp)
        }
        do {
            try await waitForTransportSendAdmission(
                owner: owner,
                deadline: deadline,
                cancellable: cancellable)
        } catch {
            await finishOwnedSendIfNeeded(owner: owner, drive: drive)
            throw error
        }
        while true {
            try await checkProgressFinishingOwnedSend(
                owner: owner,
                deadline: deadline,
                cancellable: cancellable,
                drive: drive)
            guard let sftp = sftpClients[id]?.handle else {
                throw SSHError.connectionInvalidated
            }
            let session = try requireSession()
            let result = operation(sftp)
            let disposition = notePacketProducingResult(
                result,
                owner: owner,
                session: session)
            if result != LIBSSH2_ERROR_EAGAIN {
                return PacketOperationResult(
                    code: result,
                    disposition: disposition)
            }
            do {
                try await waitForSession(
                    session,
                    deadline: deadline,
                    cancellable: cancellable)
            } catch {
                await finishOwnedSendIfNeeded(owner: owner, drive: drive)
                throw error
            }
        }
    }

    @discardableResult
    private func repeatUntilComplete(
        deadline: ContinuousClock.Instant,
        cancellable: Bool = true,
        _ operation: () -> Int32
    ) async throws -> Int32 {
        let owner = allocateTransportSendOwner()
        while true {
            try await checkProgressFinishingOwnedSend(
                owner: owner,
                deadline: deadline,
                cancellable: cancellable,
                drive: operation)
            do {
                try await waitForTransportSendAdmission(
                    owner: owner,
                    deadline: deadline,
                    cancellable: cancellable)
            } catch {
                await finishOwnedSendIfNeeded(owner: owner, drive: operation)
                throw error
            }
            let session = try requireSession()
            let result = operation()
            let disposition = notePacketProducingResult(
                result,
                owner: owner,
                session: session)
            if result != LIBSSH2_ERROR_EAGAIN {
                applyTransportSendOwnerDisposition(disposition)
                return result
            }
            do {
                try await waitForSession(
                    session,
                    deadline: deadline,
                    cancellable: cancellable)
            } catch {
                await finishOwnedSendIfNeeded(owner: owner, drive: operation)
                throw error
            }
        }
    }

    @discardableResult
    private func repeatUntilCompleteYielding(
        deadline: ContinuousClock.Instant,
        cancellable: Bool = true,
        identity: ChannelIdentity,
        allowClosing: Bool = false,
        _ operation: (OpaquePointer) -> Int32
    ) async throws -> Int32 {
        let owner = allocateTransportSendOwner()
        func drive() -> Int32? {
            guard let channel = try? resolveChannel(identity, allowClosing: allowClosing) else {
                return nil
            }
            return operation(channel)
        }
        while true {
            try await checkProgressFinishingOwnedSend(
                owner: owner,
                deadline: deadline,
                cancellable: cancellable,
                drive: drive)
            do {
                try await waitForTransportSendAdmission(
                    owner: owner,
                    deadline: deadline,
                    cancellable: cancellable)
            } catch {
                await finishOwnedSendIfNeeded(owner: owner, drive: drive)
                throw error
            }
            let channel = try resolveChannel(identity, allowClosing: allowClosing)
            let session = try requireSession()
            let result = operation(channel)
            let disposition = notePacketProducingResult(
                result,
                owner: owner,
                session: session)
            if result != LIBSSH2_ERROR_EAGAIN {
                applyTransportSendOwnerDisposition(disposition)
                return result
            }
            let plan = sessionWaitPlan(session)
            releaseOperation()
            do {
                try await awaitSessionProgress(
                    plan,
                    until: deadline,
                    cancellable: cancellable)
            } catch {
                await acquireOperation()
                await finishOwnedSendIfNeeded(owner: owner, drive: drive)
                throw error
            }
            await acquireOperation()
        }
    }

    private func repeatCompensationOperation(
        phase: SFTPCompensationPhase,
        deadline: ContinuousClock.Instant,
        cancellable: Bool,
        _ operation: () -> Int32
    ) async throws -> PacketOperationResult {
        let owner = allocateTransportSendOwner()
        while true {
            try await checkProgressFinishingOwnedSend(
                owner: owner,
                deadline: deadline,
                cancellable: cancellable,
                drive: operation)
            let session = try requireSession()
            let result = operation()
#if DEBUG
            try await runCompensationPhaseHookForTestingIfNeeded(phase)
#endif
            let disposition = notePacketProducingResult(
                result,
                owner: owner,
                session: session)
            if result != LIBSSH2_ERROR_EAGAIN {
                return PacketOperationResult(
                    code: result,
                    disposition: disposition)
            }
            do {
                try await waitForSession(
                    session,
                    deadline: deadline,
                    cancellable: cancellable)
            } catch {
                await finishOwnedSendIfNeeded(owner: owner, drive: operation)
                throw error
            }
        }
    }

#if DEBUG
    private func holdChannelOpenWaiterRegistrationForTestingIfNeeded() async {
        guard let hold = nextChannelOpenWaiterRegistrationHoldForTesting else { return }
        nextChannelOpenWaiterRegistrationHoldForTesting = nil
        await hold()
    }

    private func holdChannelTeardownForTestingIfNeeded() async {
        guard let hold = nextChannelTeardownHoldForTesting else { return }
        nextChannelTeardownHoldForTesting = nil
        releaseOperation()
        await hold()
        await acquireOperation()
    }

    private func holdExecChannelAllocationForTestingIfNeeded() async throws {
        guard let hold = nextExecChannelAllocatedHoldForTesting else { return }
        nextExecChannelAllocatedHoldForTesting = nil
        try await hold()
    }

    private func holdExecCleanupForTestingIfNeeded() async throws {
        guard let hold = nextExecCleanupHoldForTesting else { return }
        nextExecCleanupHoldForTesting = nil
        try await hold()
    }

    private func runCompensationPhaseHookForTestingIfNeeded(
        _ phase: SFTPCompensationPhase
    ) async throws {
        let hook: (@Sendable () async throws -> Void)?
        switch phase {
        case .unlink:
            hook = nextCompensationUnlinkPhaseHookForTesting
            nextCompensationUnlinkPhaseHookForTesting = nil
        case .stat:
            hook = nextCompensationStatPhaseHookForTesting
            nextCompensationStatPhaseHookForTesting = nil
        }
        try await hook?()
    }
#endif

    private func waitForSession(
        _ session: OpaquePointer,
        deadline: ContinuousClock.Instant,
        cancellable: Bool = true
    ) async throws {
        try await awaitSessionProgress(
            sessionWaitPlan(session),
            until: deadline,
            cancellable: cancellable)
    }

    private func freeSession(
        _ session: OpaquePointer,
        deadline: ContinuousClock.Instant,
        cancellable: Bool
    ) async throws {
        diagnosticStep = "session free"
        let result = try await repeatUntilComplete(
            deadline: deadline,
            cancellable: cancellable
        ) {
            libssh2_session_free(session)
        }
        guard result == 0 else { throw mapSessionError(result) }
    }

    private func checkProgress(deadline: ContinuousClock.Instant) throws {
        if Task.isCancelled { throw SSHError.cancelled }
        if ContinuousClock.now >= deadline { throw noteTimedOut() }
    }

    private func mapAuthenticationError(_ code: Int32) -> SSHError {
        switch code {
        case LIBSSH2_ERROR_AUTHENTICATION_FAILED,
            LIBSSH2_ERROR_PASSWORD_EXPIRED,
            LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED,
            LIBSSH2_ERROR_KEYFILE_AUTH_FAILED:
            noteFailure(code)
            return .authenticationFailed
        default:
            return mapSessionError(code)
        }
    }

    // MARK: - Failure diagnostics (#343)

    private func withDiagnosticPhase<T>(
        _ phase: @autoclosure () -> String,
        budget: Duration? = nil,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        let context = SSHDiagnostics.isEnabled
            ? SSHDiagnosticOperation(phase: phase(), budget: budget) : nil
        return try await SSHDiagnosticOperation.$current.withValue(context) {
            do {
                return try await operation()
            } catch {
                if error as? SSHError == .timedOut { context?.noteTimeout() }
                throw error
            }
        }
    }

    private var diagnosticContext: String {
        SSHDiagnosticOperation.current?.context ?? "SSH operation"
    }

    /// The forwarding pump is the one operation that returns its failure
    /// instead of throwing it, so `withDiagnosticPhase` never observes it and
    /// `noteFailure` was never reached from here (#351). Report at the point
    /// of failure, where the task-local phase and its timings still belong to
    /// this pump; by the time `connectThrough` sees the result it has already
    /// aborted the transport and is in another task's scope.
    private func notePumpFailure(
        _ source: String,
        errnoCode: Int32? = nil,
        libssh2Code: Int32? = nil,
        toHost: Int,
        fromHost: Int
    ) {
        guard SSHDiagnostics.isEnabled else { return }
        var line = "\(diagnosticContext), \(source) failed"
        if let libssh2Code {
            line += ": \(Self.libssh2ErrorName(libssh2Code)) (\(libssh2Code))"
            if let session, let message = Self.lastErrorMessage(session), !message.isEmpty {
                line += ": \(message)"
            }
        } else if let errnoCode {
            let description = strerror(errnoCode).map { String(cString: $0) } ?? "unknown"
            line += ": errno \(errnoCode) (\(description))"
        }
        line += " after \(toHost) bytes to the Host and \(fromHost) bytes from it"
        if let context = SSHDiagnosticOperation.current { line += " \(context.timingDetails)" }
        SSHDiagnostics.note(line)
    }

    /// One line per failure: the phase, the raw libssh2 code by name, and the
    /// message libssh2 attached to it. The coarse `SSHError` the caller gets
    /// is unchanged; this is the detail it deliberately does not carry.
    private func noteFailure(_ code: Int32) {
        guard SSHDiagnostics.isEnabled else { return }
        var line = "\(diagnosticContext) failed: \(Self.libssh2ErrorName(code)) (\(code))"
        if let session, let message = Self.lastErrorMessage(session), !message.isEmpty {
            line += ": \(message)"
        }
        if let context = SSHDiagnosticOperation.current { line += " \(context.timingDetails)" }
        SSHDiagnostics.note(line)
    }

    /// A deadline can expire in a progress check, in a readiness timer, or in
    /// a waiter that another task resumes, and the same expiry is normalized
    /// again on the way out of the operation. One line per operation is the
    /// contract, so the first report wins within this operation's task scope.
    private func noteTimedOut() -> SSHError {
        noteTimedOutOnce()
        return .timedOut
    }

    private func noteTimedOutOnce() {
        SSHDiagnosticOperation.current?.noteTimeout()
    }

    private static func lastErrorMessage(_ session: OpaquePointer) -> String? {
        var messagePointer: UnsafeMutablePointer<CChar>?
        var messageLength: Int32 = 0
        _ = libssh2_session_last_error(session, &messagePointer, &messageLength, 0)
        guard let messagePointer, messageLength > 0 else { return nil }
        return String(
            decoding: Data(bytes: messagePointer, count: Int(messageLength)),
            as: UTF8.self)
    }

    private static func libssh2ErrorName(_ code: Int32) -> String {
        switch code {
        case LIBSSH2_ERROR_SOCKET_NONE: "LIBSSH2_ERROR_SOCKET_NONE"
        case LIBSSH2_ERROR_BANNER_RECV: "LIBSSH2_ERROR_BANNER_RECV"
        case LIBSSH2_ERROR_BANNER_SEND: "LIBSSH2_ERROR_BANNER_SEND"
        case LIBSSH2_ERROR_INVALID_MAC: "LIBSSH2_ERROR_INVALID_MAC"
        case LIBSSH2_ERROR_KEX_FAILURE: "LIBSSH2_ERROR_KEX_FAILURE"
        case LIBSSH2_ERROR_ALLOC: "LIBSSH2_ERROR_ALLOC"
        case LIBSSH2_ERROR_SOCKET_SEND: "LIBSSH2_ERROR_SOCKET_SEND"
        case LIBSSH2_ERROR_KEY_EXCHANGE_FAILURE: "LIBSSH2_ERROR_KEY_EXCHANGE_FAILURE"
        case LIBSSH2_ERROR_TIMEOUT: "LIBSSH2_ERROR_TIMEOUT"
        case LIBSSH2_ERROR_HOSTKEY_INIT: "LIBSSH2_ERROR_HOSTKEY_INIT"
        case LIBSSH2_ERROR_HOSTKEY_SIGN: "LIBSSH2_ERROR_HOSTKEY_SIGN"
        case LIBSSH2_ERROR_DECRYPT: "LIBSSH2_ERROR_DECRYPT"
        case LIBSSH2_ERROR_SOCKET_DISCONNECT: "LIBSSH2_ERROR_SOCKET_DISCONNECT"
        case LIBSSH2_ERROR_PROTO: "LIBSSH2_ERROR_PROTO"
        case LIBSSH2_ERROR_PASSWORD_EXPIRED: "LIBSSH2_ERROR_PASSWORD_EXPIRED"
        case LIBSSH2_ERROR_FILE: "LIBSSH2_ERROR_FILE"
        case LIBSSH2_ERROR_METHOD_NONE: "LIBSSH2_ERROR_METHOD_NONE"
        case LIBSSH2_ERROR_AUTHENTICATION_FAILED: "LIBSSH2_ERROR_AUTHENTICATION_FAILED"
        case LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED: "LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED"
        case LIBSSH2_ERROR_CHANNEL_OUTOFORDER: "LIBSSH2_ERROR_CHANNEL_OUTOFORDER"
        case LIBSSH2_ERROR_CHANNEL_FAILURE: "LIBSSH2_ERROR_CHANNEL_FAILURE"
        case LIBSSH2_ERROR_CHANNEL_REQUEST_DENIED: "LIBSSH2_ERROR_CHANNEL_REQUEST_DENIED"
        case LIBSSH2_ERROR_CHANNEL_UNKNOWN: "LIBSSH2_ERROR_CHANNEL_UNKNOWN"
        case LIBSSH2_ERROR_CHANNEL_WINDOW_EXCEEDED: "LIBSSH2_ERROR_CHANNEL_WINDOW_EXCEEDED"
        case LIBSSH2_ERROR_CHANNEL_PACKET_EXCEEDED: "LIBSSH2_ERROR_CHANNEL_PACKET_EXCEEDED"
        case LIBSSH2_ERROR_CHANNEL_CLOSED: "LIBSSH2_ERROR_CHANNEL_CLOSED"
        case LIBSSH2_ERROR_CHANNEL_EOF_SENT: "LIBSSH2_ERROR_CHANNEL_EOF_SENT"
        case LIBSSH2_ERROR_SCP_PROTOCOL: "LIBSSH2_ERROR_SCP_PROTOCOL"
        case LIBSSH2_ERROR_ZLIB: "LIBSSH2_ERROR_ZLIB"
        case LIBSSH2_ERROR_SOCKET_TIMEOUT: "LIBSSH2_ERROR_SOCKET_TIMEOUT"
        case LIBSSH2_ERROR_SFTP_PROTOCOL: "LIBSSH2_ERROR_SFTP_PROTOCOL"
        case LIBSSH2_ERROR_REQUEST_DENIED: "LIBSSH2_ERROR_REQUEST_DENIED"
        case LIBSSH2_ERROR_METHOD_NOT_SUPPORTED: "LIBSSH2_ERROR_METHOD_NOT_SUPPORTED"
        case LIBSSH2_ERROR_INVAL: "LIBSSH2_ERROR_INVAL"
        case LIBSSH2_ERROR_INVALID_POLL_TYPE: "LIBSSH2_ERROR_INVALID_POLL_TYPE"
        case LIBSSH2_ERROR_PUBLICKEY_PROTOCOL: "LIBSSH2_ERROR_PUBLICKEY_PROTOCOL"
        case LIBSSH2_ERROR_EAGAIN: "LIBSSH2_ERROR_EAGAIN"
        case LIBSSH2_ERROR_BUFFER_TOO_SMALL: "LIBSSH2_ERROR_BUFFER_TOO_SMALL"
        case LIBSSH2_ERROR_BAD_USE: "LIBSSH2_ERROR_BAD_USE"
        case LIBSSH2_ERROR_COMPRESS: "LIBSSH2_ERROR_COMPRESS"
        case LIBSSH2_ERROR_OUT_OF_BOUNDARY: "LIBSSH2_ERROR_OUT_OF_BOUNDARY"
        case LIBSSH2_ERROR_AGENT_PROTOCOL: "LIBSSH2_ERROR_AGENT_PROTOCOL"
        case LIBSSH2_ERROR_SOCKET_RECV: "LIBSSH2_ERROR_SOCKET_RECV"
        case LIBSSH2_ERROR_ENCRYPT: "LIBSSH2_ERROR_ENCRYPT"
        case LIBSSH2_ERROR_BAD_SOCKET: "LIBSSH2_ERROR_BAD_SOCKET"
        case LIBSSH2_ERROR_KNOWN_HOSTS: "LIBSSH2_ERROR_KNOWN_HOSTS"
        case LIBSSH2_ERROR_CHANNEL_WINDOW_FULL: "LIBSSH2_ERROR_CHANNEL_WINDOW_FULL"
        case LIBSSH2_ERROR_KEYFILE_AUTH_FAILED: "LIBSSH2_ERROR_KEYFILE_AUTH_FAILED"
        case LIBSSH2_ERROR_RANDGEN: "LIBSSH2_ERROR_RANDGEN"
        case LIBSSH2_ERROR_MISSING_USERAUTH_BANNER: "LIBSSH2_ERROR_MISSING_USERAUTH_BANNER"
        case LIBSSH2_ERROR_ALGO_UNSUPPORTED: "LIBSSH2_ERROR_ALGO_UNSUPPORTED"
        default: "libssh2 error"
        }
    }

    private func mapSessionError(_ code: Int32) -> SSHError {
        noteFailure(code)
        switch code {
        case LIBSSH2_ERROR_KEX_FAILURE,
            LIBSSH2_ERROR_METHOD_NONE,
            LIBSSH2_ERROR_METHOD_NOT_SUPPORTED,
            LIBSSH2_ERROR_ALGO_UNSUPPORTED:
            return .algorithmNegotiationFailed
        // libssh2 emits KEY_EXCHANGE_FAILURE only after it has selected the
        // algorithms and entered the chosen method's exchange_keys callback.
        // That callback's transport, protocol, or crypto error is wrapped by
        // this code, so it is not evidence that the peers had no common method.
        case LIBSSH2_ERROR_KEY_EXCHANGE_FAILURE:
            return .connectionFailed
        case LIBSSH2_ERROR_AUTHENTICATION_FAILED,
            LIBSSH2_ERROR_PASSWORD_EXPIRED:
            return .authenticationFailed
        default:
            return .connectionFailed
        }
    }

    private func checkSFTPResult(
        _ result: Int32,
        sftp: OpaquePointer,
        session: OpaquePointer
    ) throws {
        guard result == 0 else {
            let error = mappedSFTPError(sftp: sftp, code: result)
            if error == .connectionInvalidated { invalidateResources() }
            throw error
        }
        guard valid, self.session == session else { throw SSHError.connectionInvalidated }
    }

    private func checkSFTPResult(_ result: Int32, sftpID: UInt64) throws {
        guard valid, let session, let sftp = sftpClients[sftpID]?.handle else {
            throw SSHError.connectionInvalidated
        }
        try checkSFTPResult(result, sftp: sftp, session: session)
    }

    private func checkSFTPResult(
        _ result: PacketOperationResult,
        sftpID: UInt64
    ) throws {
        do {
            try checkSFTPResult(result.code, sftpID: sftpID)
        } catch {
            applyTransportSendOwnerDisposition(result.disposition)
            throw error
        }
        applyTransportSendOwnerDisposition(result.disposition)
    }

    private func mappedSFTPError(sftp: OpaquePointer, code: Int32) -> SSHError {
        if Self.isConnectionLoss(code) { return .connectionInvalidated }
        return .sftpFailure(status: UInt64(libssh2_sftp_last_error(sftp)))
    }

    private static func isConnectionLoss(_ code: Int32) -> Bool {
        switch code {
        case LIBSSH2_ERROR_SOCKET_NONE,
            LIBSSH2_ERROR_SOCKET_SEND,
            LIBSSH2_ERROR_SOCKET_RECV,
            LIBSSH2_ERROR_SOCKET_DISCONNECT:
            true
        default:
            false
        }
    }

    private static func isValidSFTPPath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.utf8.contains(0)
            && path.utf8.count <= Int(UInt32.max)
    }

    private static func isValidPermissions(_ permissions: UInt32) -> Bool {
        permissions & ~0o777 == 0
    }

    private func normalize(_ error: any Error) -> SSHError {
        let normalized: SSHError
        if let error = error as? SettledChannelOpenError {
            normalized = error.underlying
        } else if let error = error as? SSHError {
            normalized = error
        } else {
            normalized = .connectionFailed
        }
        if normalized == .timedOut { noteTimedOutOnce() }
        return normalized
    }

    /// The single verdict every `close*` teardown path takes on its own failure:
    /// `closePTY`, `closeExecStream`, `closeStreamLocal`, `closeSFTP`, and
    /// `closeSFTPFile`.
    ///
    /// All five run on a budget their caller hands down, and every `deinit` in
    /// the package hands down the same `.seconds(2)` constant regardless of how
    /// fast the link is. Exhausting that budget arrives here as an ordinary
    /// `SSHError.timedOut` from `repeatUntilComplete`, which the shared
    /// `catch { invalidateResources() }` these used to run could not tell
    /// from a genuine transport failure — so on a slow enough link, tearing down
    /// one abandoned upload took Events, Attach, and every other channel on the
    /// connection with it, and reported it as `.sshUnreachable` on whatever the
    /// user did next (#136).
    ///
    /// Running out of time is not evidence that the session is corrupt, so
    /// expiry spares it: the caller's own handle is already out of its map,
    /// which bounds the loss to the one channel that could not be drained.
    /// Every other failure still invalidates — a close that failed for a reason
    /// other than the clock says the session itself is no longer trustworthy.
    /// `mappedStreamLocalOpenError` and `mappedSFTPError` split their two causes
    /// on one signal the same way.
    private func teardownFailure(_ error: any Error) -> SSHError {
        let normalized = normalize(error)
        if normalized != .timedOut { invalidateResources() }
        return normalized
    }

    private func invalidateResources() {
        valid = false
        authenticated = false
        streamLocalChannels.removeAll()
        ptyChannels.removeAll()
        execStreamChannels.removeAll()
        sftpClients.removeAll()
        sftpUses.removeAll()
        oneShotChannels.removeAll()
        // Freeing the session frees every pending open with it; their
        // openers find them gone. Open slots stay counted until each opener
        // releases its own.
        pendingChannelOpens.removeAll()
        failAllChannelOpenWaiters()
        resumeAllChannelTeardownWaiters()
        wakeSFTPIdleWaiters()
        activity.releaseAllWaiters()
        InvalidatedSessionTeardown.reclaim(&session)
        _ = sendOwnership.handle(.sessionReleased)
        closeDescriptor()
    }

    private func closeDescriptor() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    private func acquireOperation() async {
        if !operationInProgress {
            operationInProgress = true
            sampleTransportSendOwnerIfNeeded()
            return
        }
        SSHDiagnosticOperation.current?.recordWait("operation admission")
        let priority = SSHOperationPriority.current
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation, priority: priority)
        }
        sampleTransportSendOwnerIfNeeded()
    }

    /// Hands the session straight to the next waiter, so the mutex is never
    /// free while anyone waits and a newcomer cannot take it out of turn.
    private func releaseOperation() {
        // Handing the session on is the first moment another operation can act
        // on what this one already pulled off the socket.
        activity.wakeStaleWaiters()
        if let next = operationWaiters.popFirst() {
            next.resume()
        } else {
            operationInProgress = false
        }
    }
}

private final class SigningContext: Sendable {
    let publicKey: Data
    let signer: SSHSigningClosure
    private let refusal = Mutex(false)

    init(publicKey: Data, signer: @escaping SSHSigningClosure) {
        self.publicKey = publicKey
        self.signer = signer
    }

    var refusedSignatureAlgorithm: Bool {
        refusal.withLock { $0 }
    }

    func noteRefusedSignatureAlgorithm() {
        refusal.withLock { $0 = true }
    }
}

private func signPublicKey(
    _ session: OpaquePointer?,
    _ signaturePointer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ signatureLength: UnsafeMutablePointer<Int>?,
    _ dataPointer: UnsafePointer<UInt8>?,
    _ dataLength: Int,
    _ abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int32 {
    guard
        session != nil,
        let signaturePointer,
        let signatureLength,
        let dataPointer,
        dataLength >= 0,
        let contextPointer = abstract?.pointee
    else {
        return LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED
    }

    signaturePointer.pointee = nil
    signatureLength.pointee = 0
    let context = Unmanaged<SigningContext>
        .fromOpaque(contextPointer)
        .takeUnretainedValue()

    let signedData = Data(bytes: dataPointer, count: dataLength)
    guard PublicKeySignaturePolicy.permits(publicKey: context.publicKey, signedData: signedData)
    else {
        context.noteRefusedSignatureAlgorithm()
        // Not LIBSSH2_ERROR_ALGO_UNSUPPORTED: libssh2 answers that code by
        // retrying with the key's default algorithm, which is `ssh-rsa`.
        return LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED
    }

    do {
        let signature = try context.signer(signedData)
        // SessionDriver initializes libssh2 with its default malloc/free
        // allocator. libssh2 takes ownership here and frees this buffer after
        // copying it into the authentication packet.
        guard !signature.isEmpty, let allocation = malloc(signature.count) else {
            return LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED
        }
        signature.copyBytes(
            to: allocation.assumingMemoryBound(to: UInt8.self),
            count: signature.count)
        signaturePointer.pointee = allocation.assumingMemoryBound(to: UInt8.self)
        signatureLength.pointee = signature.count
        return 0
    } catch {
        return LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED
    }
}

enum InvalidatedSessionTeardown {
    typealias FreeSession = (OpaquePointer) -> Int32

    @discardableResult
    static func reclaim(
        _ session: inout OpaquePointer?,
        using freeSession: FreeSession = waycar_libssh2_abandon_session
    ) -> Int32 {
        guard let ownedSession = session else { return 0 }
        let result = freeSession(ownedSession)
        if result == 0 {
            session = nil
        }
        return result
    }
}

#if DEBUG
struct SessionDriverResourceState: Sendable, Equatable {
    let hasSession: Bool
    let descriptorIsOpen: Bool
    let isValid: Bool
}

struct TransportSendOwnerSample: Sendable, Equatable {
    let hasOwner: Bool
    let isValid: Bool
    let outboundPending: Bool

    var isForbiddenClearWindow: Bool {
        !hasOwner && isValid && outboundPending
    }
}
#endif

enum NativeLibrary {
    static let initializationResult = libssh2_init(0)
}
