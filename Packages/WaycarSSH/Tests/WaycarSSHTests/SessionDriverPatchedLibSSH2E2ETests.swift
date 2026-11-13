import CryptoKit
import Foundation
import Security
import Synchronization
import Testing

@testable import WaycarSSH

/// SessionDriver on Waycar's libssh2 patches, against the disposable sshd:
/// publickey auth without the PK_OK query (0001), PTY and exec requested back
/// to back (0002), and pipelined channel opens (0003, 0004). Members of
/// `SessionDriverE2ETests`, so they share its fixture gate, its serialization
/// and its time limit.
extension SessionDriverE2ETests {
    /// Asked first, the server answers PK_OK before anything is signed, so a
    /// signer that runs only after a session wait means the query went out.
    /// An unauthorized key is signed too now — and must still be refused,
    /// leaving the session for the next attempt.
    @Test("publickey auth signs without a PK_OK query and still rejects an unauthorized key")
    func publicKeyAuthSkipsTheQueryAndStillRejectsAnUnauthorizedKey() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let connection = try await SSHConnection.connect(
            to: environment.endpoint,
            timeout: .sshdBudget(10))
        let waits = SessionWaitTally()
        await countSessionWaits(on: connection, into: waits)

        let stranger = Curve25519.Signing.PrivateKey()
        let strangerSignatures = SignatureLog()
        await #expect(throws: SSHError.authenticationFailed) {
            try await connection.authenticate(
                username: environment.username,
                publicKey: SessionDriverTestEnvironment.publicKeyBlob(of: stranger.publicKey),
                signer: strangerSignatures.signing(after: waits) { try stranger.signature(for: $0) },
                timeout: .sshdBudget(10))
        }
        #expect(strangerSignatures.waitsBeforeEachSignature == [0])

        let rsa = try UnauthorizedRSAKey()
        let rsaSignatures = SignatureLog()
        await #expect(throws: SSHError.authenticationFailed) {
            try await connection.authenticate(
                username: environment.username,
                publicKey: rsa.publicKeyBlob,
                signer: rsaSignatures.signing(after: waits) { try rsa.signature(for: $0) },
                timeout: .sshdBudget(10))
        }
        #expect(rsaSignatures.waitsBeforeEachSignature == [0])

        let privateKey = environment.privateKey
        let deviceKeySignatures = SignatureLog()
        try await connection.authenticate(
            username: environment.username,
            publicKey: environment.publicKeyBlob,
            signer: deviceKeySignatures.signing(after: waits) { try privateKey.signature(for: $0) },
            timeout: .sshdBudget(10))
        #expect(deviceKeySignatures.waitsBeforeEachSignature == [0])
        let echo = try await connection.execute("printf signed", timeout: .sshdBudget(5))
        #expect(echo.stdout == Data("signed".utf8))
        #expect(await connection.isConnected)
        try await connection.close(timeout: .sshdBudget(2))
    }

    /// A `no-pty` key gets the exec but not the terminal; the open must fail
    /// as `ptyDenied` with its channel closed and the session left usable,
    /// while a key that may have a PTY still attaches one. The command the
    /// server starts anyway is `cat`, which ends at the end of its input, so
    /// the close completes; one that outlived it would cost the session
    /// (`SSHError.ptyDenied`).
    @Test("a refused PTY fails the open cleanly and a permitted one attaches")
    func refusedPTYFailsCleanlyAndAPermittedOneAttaches() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let noPTYKey = try #require(SessionDriverTestEnvironment.noPTYKey)
        let refused = try await SSHConnection.connect(
            to: environment.endpoint,
            timeout: .sshdBudget(10))
        try await refused.authenticate(
            username: environment.username,
            publicKey: SessionDriverTestEnvironment.publicKeyBlob(of: noPTYKey.publicKey),
            signer: { try noPTYKey.signature(for: $0) },
            timeout: .sshdBudget(10))
        await #expect(throws: SSHError.ptyDenied) {
            _ = try await refused.openPTY(
                command: "cat",
                columns: 80,
                rows: 24,
                timeout: .sshdBudget(10))
        }
        #expect(await refused.ptyChannelCountForTesting() == 0)
        #expect(await refused.isConnected)
        let echo = try await refused.execute("printf without-pty", timeout: .sshdBudget(5))
        #expect(echo.stdout == Data("without-pty".utf8))
        try await refused.close(timeout: .sshdBudget(2))

        let permitted = try await environment.connect()
        let pty = try await permitted.openPTY(
            command: "cat",
            columns: 80,
            rows: 24,
            timeout: .sshdBudget(10))
        try await pty.write(Data("attached\n".utf8), timeout: .sshdBudget(5))
        try await readPTY(
            pty,
            untilContaining: "attached",
            timeout: .sshdBudget(5),
            comment: "the PTY opened with one combined request is not usable")
        try await pty.close(timeout: .sshdBudget(5))
        #expect(await permitted.isConnected)
        try await permitted.close(timeout: .sshdBudget(2))
    }

    /// The first open parks in its reply wait; opens of both kinds started
    /// after it must complete meanwhile instead of queueing behind it.
    @Test("channel opens started after a pending one complete while it awaits its reply")
    func channelOpensDoNotSerializeBehindAPendingOne() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let socketPath = try #require(SessionDriverTestEnvironment.streamLocalSocketPath)
        // The hold finds the step through the diagnostic context, which
        // exists only while a sink is installed; the fixture installs one.
        try #require(SSHDiagnostics.isEnabled)
        let connection = try await environment.connect()
        let parked = SessionWaitHold()
        await parkSessionWait(atStep: "channel open", on: connection, parked)
        let first = Task {
            try await connection.execute("printf first", timeout: .sshdBudget(15))
        }
        var later: Task<(Data, Data), any Error>?
        do {
            try await requireEventually("the first open should park awaiting its reply") {
                await parked.hasEntered
            }
            let laterDone = SessionWaitTally()
            let opens = Task {
                let rpc = try await connection.exchangeStreamLocal(
                    socketPath: socketPath,
                    request: Data(#"{"id":"later","method":"ping"}\#n"#.utf8),
                    timeout: .sshdBudget(10))
                let exec = try await connection.execute("printf later", timeout: .sshdBudget(10))
                let stream = try await connection.openStreamLocal(
                    socketPath: socketPath,
                    timeout: .sshdBudget(10))
                try await stream.close(timeout: .sshdBudget(5))
                laterDone.increment()
                return (rpc, exec.stdout)
            }
            later = opens
            try await requireEventually(
                "later opens should complete while the first awaits its reply",
                timeout: .sshdBudget(10)
            ) {
                laterDone.count == 1
            }
            let (rpc, exec) = try await opens.value
            #expect(!rpc.isEmpty)
            #expect(exec == Data("later".utf8))
            #expect(await connection.pendingChannelOpenCountForTesting() == 1)
            await parked.release()
            let firstResult = try await first.value
            #expect(firstResult.stdout == Data("first".utf8))
        } catch {
            await parked.release()
            first.cancel()
            later?.cancel()
            _ = try? await first.value
            _ = try? await later?.value
            try? await connection.close(timeout: .sshdBudget(2))
            throw error
        }
        #expect(await connection.peakPendingChannelOpensForTesting() >= 2)
        #expect(await connection.pendingChannelOpenCountForTesting() == 0)
        #expect(await connection.isConnected)
        try await connection.close(timeout: .sshdBudget(2))
    }

    /// The opener gives up while its request is out. libssh2 must free that
    /// channel — waiting for the reply and closing it — before the call
    /// throws, so the caller's lease, released when it throws, covers the
    /// channel until it is gone; and the session stays usable.
    @Test("a cancelled in-flight open is freed before its lease is released")
    func cancelledInFlightOpenIsFreedBeforeItsLeaseIsReleased() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let socketPath = try #require(SessionDriverTestEnvironment.streamLocalSocketPath)
        try #require(SSHDiagnostics.isEnabled)
        let connection = try await environment.connect()
        let parked = SessionWaitHold()
        await parkSessionWait(atStep: "channel open", on: connection, parked)
        let freeing = SessionWaitHold()
        await connection.holdNextAbandonedChannelOpenFreeForTesting {
            await freeing.waitUntilReleased()
        }
        // Each release records how many abandoned opens had been freed by then.
        let releases = ReleaseLog()
        let rpc = Task {
            try await connection.exchangeStreamLocal(
                socketPath: socketPath,
                request: Data(#"{"id":"abandoned","method":"ping"}\#n"#.utf8),
                timeout: .sshdBudget(15),
                onChannelReleased: {
                    await releases.record(await connection.abandonedChannelOpenFreeCountForTesting())
                })
        }
        do {
            try await requireEventually("the open should park awaiting its reply") {
                await parked.hasEntered
            }
            rpc.cancel()
            await parked.release()
            try await requireEventually("the abandoned open should reach its free") {
                await freeing.hasEntered
            }
            // Still pending natively, so the call has not thrown and its
            // lease is still held.
            #expect(await releases.values.isEmpty)
            #expect(await connection.pendingChannelOpenCountForTesting() == 1)
            await freeing.release()
            await #expect(throws: SSHError.cancelled) { _ = try await rpc.value }
        } catch {
            await parked.release()
            await freeing.release()
            rpc.cancel()
            _ = try? await rpc.value
            try? await connection.close(timeout: .sshdBudget(2))
            throw error
        }
        #expect(await releases.values == [1])
        #expect(await connection.pendingChannelOpenCountForTesting() == 0)
        #expect(await connection.isConnected)
        let after = try await connection.exchangeStreamLocal(
            socketPath: socketPath,
            request: Data(#"{"id":"after","method":"ping"}\#n"#.utf8),
            timeout: .sshdBudget(10))
        #expect(!after.isEmpty)
        try await connection.close(timeout: .sshdBudget(2))
    }

    /// The deadline expires while the open's request is out. That is the
    /// same free as a cancellation, with the same verdict: the channel is
    /// gone before the call throws, so the lease covers it to the end, and
    /// the session stays usable.
    @Test("an in-flight open that times out is freed before its lease is released")
    func timedOutInFlightOpenIsFreedBeforeItsLeaseIsReleased() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let socketPath = try #require(SessionDriverTestEnvironment.streamLocalSocketPath)
        try #require(SSHDiagnostics.isEnabled)
        let connection = try await environment.connect()
        let parked = SessionWaitHold()
        await parkSessionWait(
            atStep: "channel open", on: connection, parked, thenFailing: .timedOut)
        let releases = ReleaseLog()
        let rpc = Task {
            try await connection.exchangeStreamLocal(
                socketPath: socketPath,
                request: Data(#"{"id":"expired","method":"ping"}\#n"#.utf8),
                timeout: .sshdBudget(15),
                onChannelReleased: {
                    await releases.record(await connection.abandonedChannelOpenFreeCountForTesting())
                })
        }
        do {
            try await requireEventually("the open should park awaiting its reply") {
                await parked.hasEntered
            }
            await parked.release()
            await #expect(throws: SSHError.timedOut) { _ = try await rpc.value }
        } catch {
            await parked.release()
            rpc.cancel()
            _ = try? await rpc.value
            try? await connection.close(timeout: .sshdBudget(2))
            throw error
        }
        #expect(await releases.values == [1])
        #expect(await connection.pendingChannelOpenCountForTesting() == 0)
        #expect(await connection.isConnected)
        let after = try await connection.exchangeStreamLocal(
            socketPath: socketPath,
            request: Data(#"{"id":"after-expiry","method":"ping"}\#n"#.utf8),
            timeout: .sshdBudget(10))
        #expect(!after.isEmpty)
        try await connection.close(timeout: .sshdBudget(2))
    }

    /// The link dies while the open's request is out. Nothing settled that
    /// open, as a refusal would have, and there is no session left to spare.
    @Test("an in-flight open whose link dies invalidates the session")
    func inFlightOpenWhoseLinkDiesInvalidatesTheSession() async throws {
        try await withExecOpenAwaitingAHeldReply { connection, proxy, exec, parked in
            let severed = try await proxy.cut()
            #expect(severed > 0)
            await parked.release()
            await #expect(throws: SSHError.connectionInvalidated) { _ = try await exec.value }
            #expect(await connection.isConnected == false)
        }
    }

    /// The opener gives up and no reply comes inside the free's budget, so
    /// what the server did with the open stays unknown. Only invalidating the
    /// session reclaims the channel then: the free itself never returned.
    @Test("an abandoned open that cannot be freed in time invalidates the session")
    func abandonedOpenThatCannotBeFreedInTimeInvalidatesTheSession() async throws {
        try await withExecOpenAwaitingAHeldReply { connection, _, exec, parked in
            exec.cancel()
            await parked.release()
            await #expect(throws: SSHError.cancelled) { _ = try await exec.value }
            #expect(await connection.abandonedChannelOpenFreeCountForTesting() == 0)
            #expect(await connection.pendingChannelOpenCountForTesting() == 0)
            #expect(await connection.isConnected == false)
        }
    }

    /// The opener gives up and the link dies before the free reads the
    /// reply. `libssh2_channel_free` still returns success, since it frees
    /// the channel whatever the read under it reported, but the session went
    /// with its transport and must not read as reusable.
    @Test("an abandoned open freed after its link died invalidates the session")
    func abandonedOpenFreedAfterItsLinkDiedInvalidatesTheSession() async throws {
        try await withExecOpenAwaitingAHeldReply { connection, proxy, exec, parked in
            let freeing = SessionWaitHold()
            await connection.holdNextAbandonedChannelOpenFreeForTesting {
                await freeing.waitUntilReleased()
            }
            do {
                exec.cancel()
                await parked.release()
                try await requireEventually("the abandoned open should reach its free") {
                    await freeing.hasEntered
                }
                let severed = try await proxy.cut()
                #expect(severed > 0)
                await freeing.release()
                await #expect(throws: SSHError.cancelled) { _ = try await exec.value }
            } catch {
                await freeing.release()
                throw error
            }
            #expect(await connection.abandonedChannelOpenFreeCountForTesting() == 1)
            #expect(await connection.isConnected == false)
        }
    }

    /// Starts an exec on a proxied connection whose link then holds every
    /// chunk for ten seconds, and runs `body` once the exec's session open
    /// has sent its request and parked awaiting the reply: nothing the server
    /// says can settle that open before `body` acts on it. The proxy is reset
    /// and the connection closed either way.
    private func withExecOpenAwaitingAHeldReply(
        _ body: (
            _ connection: SSHConnection,
            _ proxy: WeakNetworkProxyFixture,
            _ exec: Task<SSHExecResult, any Error>,
            _ parked: SessionWaitHold
        ) async throws -> Void
    ) async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let proxy = try #require(WeakNetworkProxyFixture.current)
        try #require(SSHDiagnostics.isEnabled)
        try await proxy.reset()
        let connection = try await connectThroughProxy(environment: environment, proxy: proxy)
        let parked = SessionWaitHold()
        await parkSessionWait(atStep: "channel open", on: connection, parked)
        var exec: Task<SSHExecResult, any Error>?
        do {
            try await proxy.delay(milliseconds: 10_000)
            let started = Task {
                try await connection.execute("printf held", timeout: .sshdBudget(15))
            }
            exec = started
            try await requireEventually("the open should park awaiting its reply") {
                await parked.hasEntered
            }
            try await body(connection, proxy, started, parked)
        } catch {
            await parked.release()
            exec?.cancel()
            _ = try? await exec?.value
            try? await proxy.reset()
            try? await connection.close(timeout: .sshdBudget(2))
            throw error
        }
        try await proxy.reset()
        try? await connection.close(timeout: .sshdBudget(2))
    }

    /// SFTP init is the one stock open left. It must run while a pipelined
    /// open awaits its reply — reading past that reply, which stays queued
    /// for its owner — and both must work.
    @Test("SFTP opens and works while a pipelined open awaits its reply")
    func sftpOpensAndWorksAlongsidePipelinedOpens() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let socketPath = try #require(SessionDriverTestEnvironment.streamLocalSocketPath)
        try #require(SSHDiagnostics.isEnabled)
        let connection = try await environment.connect()
        let rootResult = try await connection.execute(
            "mktemp -d /tmp/waycar-sftp-pipelined.XXXXXXXX",
            timeout: .sshdBudget(5))
        let root = String(decoding: rootResult.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(root.hasPrefix("/tmp/waycar-sftp-pipelined."))
        let parked = SessionWaitHold()
        await parkSessionWait(atStep: "channel open", on: connection, parked)
        let pending = Task {
            try await connection.exchangeStreamLocal(
                socketPath: socketPath,
                request: Data(#"{"id":"pending","method":"ping"}\#n"#.utf8),
                timeout: .sshdBudget(15))
        }
        do {
            try await requireEventually("the pipelined open should park awaiting its reply") {
                await parked.hasEntered
            }
            let sftp = try await connection.openSFTP(timeout: .sshdBudget(5))
            #expect(await connection.pendingChannelOpenCountForTesting() == 1)
            let path = "\(root)/pipelined"
            let file = try await sftp.openFileForWriting(
                at: path,
                permissions: 0o600,
                timeout: .sshdBudget(5))
            try await file.write(Data("alongside".utf8), timeout: .sshdBudget(5))
            try await file.close(timeout: .sshdBudget(5))
            let rpc = try await connection.exchangeStreamLocal(
                socketPath: socketPath,
                request: Data(#"{"id":"beside","method":"ping"}\#n"#.utf8),
                timeout: .sshdBudget(10))
            #expect(!rpc.isEmpty)
            #expect(
                try await sftp.readFileIfPresent(at: path, timeout: .sshdBudget(5))
                    == Data("alongside".utf8))
            await parked.release()
            #expect(!(try await pending.value).isEmpty)
            try await sftp.removeFile(at: path, timeout: .sshdBudget(5))
            try await sftp.close(timeout: .sshdBudget(5))
        } catch {
            await parked.release()
            pending.cancel()
            _ = try? await pending.value
            _ = try? await connection.execute("rm -rf '\(root)'", timeout: .sshdBudget(5))
            try? await connection.close(timeout: .sshdBudget(2))
            throw error
        }
        _ = try await connection.execute("rmdir '\(root)'", timeout: .sshdBudget(5))
        #expect(await connection.isConnected)
        try await connection.close(timeout: .sshdBudget(2))
    }

    @Test("a response-line exec returns before its channel closes and is released once")
    func responseLineExecReturnsBeforeItsChannelCloses() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let connection = try await environment.connect()
        let closeGate = SessionWaitHold()
        await connection.holdBackgroundChannelReleasesForTesting {
            await closeGate.waitUntilReleased()
        }
        // Each release records how many one-shot channels were still registered.
        let releases = ReleaseLog()

        let response = try await connection.executeResponseLine(
            "IFS= read -r line; printf 'accepted:%s\\n' \"$line\"",
            input: Data("device-key-line\n".utf8),
            maximumResponseBytes: 64,
            timeout: .sshdBudget(10),
            onChannelReleased: {
                await releases.record(await connection.oneShotRegistryCountForTesting())
            })
        #expect(response == Data("accepted:device-key-line\n".utf8))
        // Returned with the channel still registered and its close not begun.
        #expect(await releases.values.isEmpty)
        #expect(await connection.oneShotRegistryCountForTesting() == 1)
        try await requireEventually("the close should wait in the background") {
            await closeGate.hasEntered
        }
        await connection.holdBackgroundChannelReleasesForTesting(nil)
        await closeGate.release()
        try await requireEventually("the release should follow the real close") {
            await releases.values.count == 1
        }
        #expect(await releases.values == [0])
        #expect(await connection.oneShotRegistryCountForTesting() == 0)
        #expect(await connection.isConnected)
        try await connection.close(timeout: .sshdBudget(2))
    }
}

@Test("a refused PTY reads as ptyDenied, an exec refused alone as an exec failure")
func ptyProcessStartupFailureMapsDenials() {
    // libssh2: LIBSSH2_ERROR_CHANNEL_REQUEST_DENIED, LIBSSH2_ERROR_SOCKET_RECV,
    // LIBSSH2_CHANNEL_DENIED_PTY and LIBSSH2_CHANNEL_DENIED_PROCESS (patch 0002).
    let requestDenied: Int32 = -22
    let socketReceive: Int32 = -43
    let ptyRefused: Int32 = 0x01
    let processRefused: Int32 = 0x02
    #expect(SessionDriver.ptyProcessStartupFailure(result: 0, denied: 0) == nil)
    #expect(
        SessionDriver.ptyProcessStartupFailure(result: requestDenied, denied: ptyRefused)
            == .ptyDenied)
    #expect(
        SessionDriver.ptyProcessStartupFailure(
            result: requestDenied,
            denied: ptyRefused | processRefused) == .ptyDenied)
    #expect(
        SessionDriver.ptyProcessStartupFailure(result: requestDenied, denied: processRefused)
            == .channelFailed)
    #expect(
        SessionDriver.ptyProcessStartupFailure(result: socketReceive, denied: 0)
            == .channelFailed)
}

/// Parks the first session wait whose diagnostic step is `step` on `hold`,
/// then lets it go on, or fail with `failure` as its own wait would have;
/// any other wait passes and re-arms the hook.
private func parkSessionWait(
    atStep step: String,
    on connection: SSHConnection,
    _ hold: SessionWaitHold,
    thenFailing failure: SSHError? = nil
) async {
    await connection.holdNextSessionWaitForTesting {
        if SSHDiagnosticOperation.current?.step == step {
            await hold.waitUntilReleased()
            if let failure { throw failure }
        } else {
            await parkSessionWait(atStep: step, on: connection, hold, thenFailing: failure)
        }
    }
}

/// Counts every session wait from now on, re-arming itself.
private func countSessionWaits(on connection: SSHConnection, into tally: SessionWaitTally) async {
    await connection.holdNextSessionWaitForTesting {
        tally.increment()
        await countSessionWaits(on: connection, into: tally)
    }
}

private final class SessionWaitTally: Sendable {
    private let value = Mutex(0)

    var count: Int { value.withLock { $0 } }

    func increment() { value.withLock { $0 += 1 } }
}

/// For each signature a signer made, how many session waits the attempt
/// had made before it.
private final class SignatureLog: Sendable {
    private let waits = Mutex<[Int]>([])

    var waitsBeforeEachSignature: [Int] { waits.withLock { $0 } }

    func signing(
        after tally: SessionWaitTally,
        _ sign: @escaping @Sendable (Data) throws -> Data
    ) -> SSHSigningClosure {
        let start = tally.count
        return { [self] data in
            let waited = tally.count - start
            waits.withLock { $0.append(waited) }
            return try sign(data)
        }
    }
}

private actor ReleaseLog {
    private(set) var values: [Int] = []

    func record(_ value: Int) { values.append(value) }
}

private enum UnauthorizedRSAKeyError: Error {
    case unavailable
}

/// A fresh RSA key no authorized_keys line names, signing RSA-SHA2-512.
private struct UnauthorizedRSAKey: Sendable {
    private let privateKeyDER: Data
    let publicKeyBlob: Data

    init() throws {
        var error: Unmanaged<CFError>?
        guard
            let privateKey = SecKeyCreateRandomKey(
                [
                    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                    kSecAttrKeySizeInBits as String: 2_048,
                ] as CFDictionary,
                &error),
            let privateKeyDER = SecKeyCopyExternalRepresentation(privateKey, &error) as Data?,
            let publicKey = SecKeyCopyPublicKey(privateKey),
            let publicKeyDER = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
            let integers = Self.derIntegers(publicKeyDER),
            integers.count == 2
        else {
            throw UnauthorizedRSAKeyError.unavailable
        }
        self.privateKeyDER = privateKeyDER
        // RFC 4253 §6.6: string "ssh-rsa", mpint e, mpint n. DER INTEGER
        // contents are already the minimal two's complement an mpint is.
        publicKeyBlob = Self.sshString(Data("ssh-rsa".utf8))
            + Self.sshString(integers[1])
            + Self.sshString(integers[0])
    }

    func signature(for data: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard
            let privateKey = SecKeyCreateWithData(
                privateKeyDER as CFData,
                [
                    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                    kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                ] as CFDictionary,
                &error),
            let signature = SecKeyCreateSignature(
                privateKey,
                .rsaSignatureMessagePKCS1v15SHA512,
                data as CFData,
                &error) as Data?
        else {
            throw UnauthorizedRSAKeyError.unavailable
        }
        return signature
    }

    private static func sshString(_ field: Data) -> Data {
        var length = UInt32(field.count).bigEndian
        var encoded = Data()
        withUnsafeBytes(of: &length) { encoded.append(contentsOf: $0) }
        encoded.append(field)
        return encoded
    }

    /// The INTEGER contents of a DER SEQUENCE of INTEGERs (PKCS#1
    /// RSAPublicKey: modulus, then exponent).
    private static func derIntegers(_ der: Data) -> [Data]? {
        let bytes = [UInt8](der)
        var index = 0
        func length() -> Int? {
            guard index < bytes.count else { return nil }
            let first = Int(bytes[index])
            index += 1
            guard first & 0x80 != 0 else { return first }
            let count = first & 0x7F
            guard count > 0, count <= 4, index + count <= bytes.count else { return nil }
            var value = 0
            for _ in 0..<count {
                value = value << 8 | Int(bytes[index])
                index += 1
            }
            return value
        }
        guard bytes.first == 0x30 else { return nil }
        index = 1
        guard length() != nil else { return nil }
        var integers: [Data] = []
        while index < bytes.count {
            guard bytes[index] == 0x02 else { return nil }
            index += 1
            guard let count = length(), index + count <= bytes.count else { return nil }
            integers.append(Data(bytes[index..<index + count]))
            index += count
        }
        return integers
    }
}
