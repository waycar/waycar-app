import CryptoKit
import Foundation
import WaycarSSH

/// Shared policy for the disposable real-sshd fixtures.
///
/// `scripts/run-ci-ios-tests.sh` exports `WAYCAR_SSH_E2E_REQUIRED=1` into the
/// Simulator before the mandatory real-SSH suites run. Under that flag a
/// missing, undecodable, or partially configured fixture must fail the suite
/// rather than skip it: a merge gate that turns an unavailable fixture into a
/// green skip proves nothing. Without the variable — a developer laptop with
/// no fixture running — the same suites still skip cleanly.
///
/// The variable's *presence* is the separate, coarser signal that the gate is
/// driving the run at all; see `isUnderMergeGate`.
enum RealSSHFixture {
    /// True when the caller demands real SSH coverage rather than tolerating it.
    static var isRequired: Bool {
        Self.requirement == "1"
    }

    /// True while the merge gate drives the run, whether or not it currently
    /// has a fixture configured. The gate keeps `WAYCAR_SSH_E2E_REQUIRED` set
    /// for its whole run: `1` while the disposable fixture is up, `0` for the
    /// final full lane, where every fixture-backed suite is meant to skip.
    ///
    /// A suite that can otherwise fall back onto machine-owned resources — the
    /// developer's own sshd on port 22 and their real
    /// `~/.ssh/authorized_keys` — must refuse that fallback here. The gate
    /// promises to leave no machine state to undo, and a suite that proves one
    /// thing on CI and a different one on a laptop proves neither.
    static var isUnderMergeGate: Bool {
        Self.requirement?.isEmpty == false
    }

    /// The scheme forwards its whole test-environment allow-list
    /// unconditionally, substituting an empty string for anything the invoking
    /// shell has not exported — so "set" here means non-empty, not non-nil.
    private static var requirement: String? {
        ProcessInfo.processInfo.environment["WAYCAR_SSH_E2E_REQUIRED"]
    }

    /// Suite condition for a fixture-backed suite.
    ///
    /// Enables the suite when its fixture is configured, and also when the
    /// fixture is required but absent, so the per-test `#require` reports the
    /// missing fixture as a failure instead of a skip.
    static func gate(_ isConfigured: Bool) -> Bool {
        _ = diagnosticsSink
        return isConfigured || isRequired
    }

    /// Installed once per test process, from the gate every fixture-backed
    /// suite passes through, so a fixture failure prints its SSH phase and
    /// libssh2 code into the xcodebuild log beside the test (#343).
    private static let diagnosticsSink = SSHDiagnostics.addSink(SSHDiagnostics.printingSink())

    /// The Ed25519 Device Key the fixture authorizes.
    ///
    /// The fixture script generates a fresh seed per run and passes it in the
    /// fixture configuration, so no long-lived key in this repository ever
    /// authorizes a login on a developer machine.
    static func deviceKey(seed base64Seed: String) throws -> Curve25519.Signing.PrivateKey {
        guard let seed = Data(base64Encoded: base64Seed) else {
            throw RealSSHFixtureError.malformedDeviceKeySeed
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }
}

enum RealSSHFixtureError: Error {
    case malformedDeviceKeySeed
}

extension Duration {
    /// A real-sshd operation budget of `seconds`, stretched by
    /// `WAYCAR_SSH_E2E_TIMEOUT_SCALE` when the fixture runs on a loaded host.
    ///
    /// The literals are what an idle machine needs. CI can share its
    /// runner with the developer's own workload, and at load averages in the
    /// hundreds sshd has been seen taking 5-9 s just to fork and reap
    /// `sh -c 'exit 7'`, so a fixed 5 s budget measured the host rather than
    /// the code under test. Tests that expect `.timedOut` pass sub-second or
    /// injected deadlines and stay unscaled.
    static func sshdBudget(_ seconds: Int) -> Duration {
        .seconds(seconds) * sshdBudgetScale
    }
}

private let sshdBudgetScale: Double = {
    guard
        let text = ProcessInfo.processInfo.environment["WAYCAR_SSH_E2E_TIMEOUT_SCALE"],
        let scale = Double(text), scale >= 1
    else { return 1 }
    return scale
}()
