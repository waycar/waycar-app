import Foundation
import WaycarSSH

/// How a presented Host Key passed verification.
enum HostKeyVerdict: Sendable, Equatable {
    /// It matched a fingerprint this device already trusted.
    case alreadyTrusted
    /// The user trusted it just now, on first connect. The handshake that
    /// presented it sat idle for as long as they took to answer.
    case trustedOnFirstConnect
}

/// Applies the app-owned TOFU policy to Host Keys surfaced by the SSH
/// transport. Authentication must not begin until this verifier returns
/// successfully.
struct WaycarSSHHostKeyVerifier: Sendable {
    private let host: String
    private let port: Int
    private let policy: HostKeyPolicy

    init(host: String, port: Int, policy: HostKeyPolicy) {
        self.host = host
        self.port = port
        self.policy = policy
    }

    @discardableResult
    func verify(_ hostKey: WaycarSSH.SSHHostKey) async throws(TransportError) -> HostKeyVerdict {
        let fingerprint = HostKeyFingerprint(publicKeyBlob: hostKey.key)
        if let known = await policy.knownHosts.fingerprint(
            host: host,
            port: port,
            algorithm: fingerprint.algorithm)
        {
            guard known.digest == fingerprint.digest else {
                throw .hostKeyMismatch(known: known, presented: fingerprint)
            }
            if known.algorithm == HostKeyFingerprint.unknownAlgorithm {
                // Matching a pre-v2 digest proves its negotiated algorithm.
                await policy.knownHosts.setFingerprint(fingerprint, host: host, port: port)
            }
            return .alreadyTrusted
        }

        let previouslyTrusted = await policy.knownHosts.fingerprints(host: host, port: port)
        if let known = previouslyTrusted.first {
            // A trusted endpoint presenting another algorithm means its
            // previous algorithm disappeared from negotiation. Do not turn
            // that security change into a fresh first-connect prompt.
            throw .hostKeyMismatch(known: known, presented: fingerprint)
        }

        let candidate = HostKeyCandidate(host: host, port: port, fingerprint: fingerprint)
        guard await policy.confirmFirstConnect(candidate) else {
            throw .hostKeyRejected(presented: fingerprint)
        }
        // Persist before authentication, matching OpenSSH known_hosts: bad
        // credentials on the same Host must not cause a second trust prompt.
        await policy.knownHosts.setFingerprint(fingerprint, host: host, port: port)
        return .trustedOnFirstConnect
    }
}
