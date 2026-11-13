import WaycarSSH
import Testing

@testable import Waycar

/// Exercises the real connect-time and post-connect mappers (#133).
@Suite("WaycarSSH error mapping")
struct WaycarSSHErrorMappingTests {
    @Test func connectAndOperationMappersAgreeOnForwardingDenied() {
        let error = SSHError.forwardingDenied
        #expect(
            WaycarSSHTransport.mapConnectForTesting(error)
                == .tcpForwardingUnavailable)
        #expect(
            WaycarSSHTransport.mapOperationForTesting(error)
                == .tcpForwardingUnavailable)
    }

    @Test func connectAndOperationMappersAgreeOnAuthTimeoutAndCancel() {
        #expect(
            WaycarSSHTransport.mapConnectForTesting(SSHError.authenticationFailed)
                == .authenticationFailed)
        #expect(
            WaycarSSHTransport.mapOperationForTesting(SSHError.authenticationFailed)
                == .authenticationFailed)

        #expect(WaycarSSHTransport.mapConnectForTesting(SSHError.timedOut) == .timedOut)
        #expect(WaycarSSHTransport.mapOperationForTesting(SSHError.timedOut) == .timedOut)

        #expect(WaycarSSHTransport.mapConnectForTesting(SSHError.cancelled) == .cancelled)
        #expect(WaycarSSHTransport.mapOperationForTesting(SSHError.cancelled) == .cancelled)
    }

    @Test func pathSpecificMappersStillDivergeWhereIntended() {
        // A failed dial is an unreachable Host; the same failure on a live
        // connection is a dropped channel.
        #expect(isUnreachable(WaycarSSHTransport.mapConnectForTesting(SSHError.connectionFailed)))
        #expect(isDropped(WaycarSSHTransport.mapOperationForTesting(SSHError.connectionFailed)))

        // A dead connection is unreachable on both paths.
        #expect(
            isUnreachable(WaycarSSHTransport.mapConnectForTesting(SSHError.connectionInvalidated)))
        #expect(
            isUnreachable(WaycarSSHTransport.mapOperationForTesting(SSHError.connectionInvalidated)))

        // Generic channel failure is the same classification on both paths.
        #expect(isDropped(WaycarSSHTransport.mapConnectForTesting(SSHError.channelFailed)))
        #expect(isDropped(WaycarSSHTransport.mapOperationForTesting(SSHError.channelFailed)))
    }

    @Test func errorCopyNeverShowsAnSSHErrorCaseName() {
        // Every case that ends up as a Detail rather than as its own
        // TransportError. "SSH unavailable: connectionFailed." is not copy.
        let errors: [SSHError] = [
            .invalidEndpoint, .connectionFailed, .algorithmNegotiationFailed,
            .channelFailed, .ptyDenied, .targetUnreachable, .streamLocalOpenFailed, .unexpectedEOF,
            .responseTooLarge(limit: 1024), .sftpUnavailable, .sftpFailure(status: 4),
            .connectionInvalidated,
        ]
        for error in errors {
            let caseName = String(String(describing: error).prefix { $0 != "(" })
            for mapped in [
                WaycarSSHTransport.mapConnectForTesting(error),
                WaycarSSHTransport.mapOperationForTesting(error),
            ] {
                let message = mapped.presentation.message
                #expect(!message.contains(caseName), "\(caseName) shows in: \(message)")
                #expect(!message.contains(".."), "Doubled period in: \(message)")
            }
        }
    }

    @Test func jumpHostAndMoshCopyNeverShowsATransportErrorCaseName() {
        // The default branches used to interpolate the error itself, so
        // "Could not connect through the Jump Host. (tcpForwardingUnavailable)"
        // reached the user.
        let errors: [TransportError] = [
            .tcpForwardingUnavailable, .authenticationFailed, .timedOut,
            .herdrBinaryNotFound, .sshUnreachable(detail: "the address or port is not valid"),
            .channelFailed(detail: "the SSH connection is closed"),
            .socketNotFound(path: "/tmp/herdr.sock"),
            WaycarSSHTransport.mapConnectForTesting(SSHError.connectionInvalidated),
            WaycarSSHTransport.mapConnectForTesting(SSHError.algorithmNegotiationFailed),
        ]
        for error in errors {
            let caseName = String(String(describing: error).prefix { $0 != "(" })
            let report = PreflightReport.failure(.jumpHostFailed(error), authMethod: .deviceKey)
            let hints = PreflightCheck.allCases.compactMap { check -> String? in
                if case .failed(let hint) = report[check] { return hint }
                return nil
            }
            #expect(hints.count == 1)
            let mosh = HostOnboardingStore.moshFailureDetail(error)
            for copy in hints + [mosh, error.presentation.explanation] {
                #expect(!copy.contains(caseName), "\(caseName) shows in: \(copy)")
                #expect(!copy.contains(".."), "Doubled period in: \(copy)")
            }
        }
    }

    private func isUnreachable(_ error: TransportError) -> Bool {
        switch error {
        case .sshUnreachable: true
        default: false
        }
    }

    private func isDropped(_ error: TransportError) -> Bool {
        switch error {
        case .channelFailed: true
        default: false
        }
    }
}
