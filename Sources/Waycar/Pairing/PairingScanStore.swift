import Foundation
import Observation

/// User-facing outcome of a failed pairing attempt, classified per ceremony
/// step (ADR 0007) so the copy says whether to rescan, fix the network, or
/// regenerate the Pairing Code on the computer.
struct PairingFailure: Equatable, Sendable {
    /// The Pairing step the failure is attributed to. `.parse` marks
    /// failures caught before any connection was attempted (an expired code,
    /// an unloadable Device Key): no ceremony step ran, so none is to blame.
    let step: PairingStep
    /// Step-specific copy, including its recovery guidance.
    let message: String
    /// Whether trying again with the same scanned code (inside its TTL) can
    /// succeed; false means the user needs a fresh Pairing Code or the
    /// manual form.
    let canRetry: Bool
}

/// Drives Scan to Pair (#62, #66, #204): turns strings recognized by the QR
/// scanner or pasted from the clipboard into a parsed Pairing Code, runs
/// the ceremony through the injected `PairingConnector`, and persists the
/// Host only after the verified reconnect, with its fingerprint pinned so
/// preflight never TOFU-prompts. Camera capture and pasteboard access stay
/// in the view layer; everything downstream of the scanned string is
/// testable here with scripted connector fakes.
@MainActor
@Observable
final class PairingScanStore {
    private var ceremony = PairingCeremonyMachine()

    var pairingCode: PairingCode? { ceremony.pairingCode }
    var scanFailureMessage: String? { ceremony.scanFailureMessage }
    var isPairing: Bool { ceremony.isPairing }
    var step: PairingStep? { ceremony.step }
    var failure: PairingFailure? { ceremony.failure }
    var pairedHost: Host? { ceremony.pairedHost }
    var method: PairingMethod? { ceremony.method }
    /// Where the flow stands, for the abandonment funnel event.
    var stage: PairingStage { ceremony.stage }

    @ObservationIgnored private let catalog: HostStore
    @ObservationIgnored private let connector: any PairingConnector
    @ObservationIgnored private let knownHosts: any KnownHostsStore
    @ObservationIgnored private let credentials: HostCredentialsProvider
    @ObservationIgnored private let now: @Sendable () -> Date

    init(
        catalog: HostStore,
        connector: any PairingConnector = SSHPairingConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.catalog = catalog
        self.connector = connector
        self.knownHosts = knownHosts
        self.credentials = credentials
        self.now = now
    }

    func submit(scannedCode: String, method: PairingMethod = .scan) {
        guard pairingCode == nil else { return }
        // Paste (and a trailing newline from pbcopy/manual selection) is the
        // same parse path as a scan; trim so the two cannot disagree.
        let scanned = scannedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let code = try PairingCode.decode(scanned)
            _ = ceremony.handle(.parsed(code, method))
        } catch {
            _ = ceremony.handle(.parseFailed(Self.message(for: error)))
        }
    }

    /// Runs one ceremony attempt against the scanned code. Reentrancy-safe:
    /// a call while an attempt runs, or after one succeeded, does nothing.
    /// Calling it again after a retryable failure is the Try Again action.
    func pair() async {
        await send(.pair(now: now()))
    }

    /// Back to a fresh scanning state (the "Scan Again" action).
    func rescan() {
        _ = ceremony.handle(.rescan)
    }

    private func send(_ event: PairingCeremonyMachine.Event) async {
        for effect in ceremony.handle(event) {
            switch effect {
            case .connect(let token, let code):
                await connect(token: token, code: code)
            case .save(let token, let result):
                await save(token: token, result: result)
            }
        }
    }

    private func connect(token: UInt64, code: PairingCode) async {
        let deviceKey: DeviceKey
        do {
            deviceKey = try credentials.deviceKey()
        } catch {
            await send(.failed(token, PairingFailure(
                step: .parse,
                message: "This device's Device Key could not be loaded. "
                    + "Open the manual Add Host form to inspect or replace it.",
                canRetry: false)))
            return
        }

        let result: PairingResult
        do {
            result = try await connector.pair(code: code, deviceKey: deviceKey) { [weak self] step in
                Task { @MainActor [weak self] in
                    _ = self?.ceremony.handle(.step(token, step))
                }
            }
        } catch let error as PairingCeremonyError {
            await send(.ceremonyFailed(token, error))
            return
        } catch is CancellationError {
            // The scan sheet went away mid-ceremony; nobody is left to tell.
            await send(.cancelled(token))
            return
        } catch {
            await send(.failed(token, PairingFailure(
                step: .reach,
                message: "Pairing failed unexpectedly. Try again with the same code. (\(error))",
                canRetry: true)))
            return
        }
        await send(.verified(token, result))
    }

    private func save(token: UInt64, result: PairingResult) async {
        // Only a fully verified ceremony creates a Host (ADR 0007). The
        // fingerprint pin lands with it, against the address that actually
        // answered, so preflight connects without a TOFU prompt.
        let host = Host(
            address: result.address, port: result.port, username: result.username,
            authMethod: .deviceKey)
        do {
            try catalog.add(host)
        } catch {
            await send(.failed(token, PairingFailure(
                step: .verify,
                message: "Pairing succeeded, but the Host could not be saved because the Host "
                    + "catalog on this device is unreadable. Resolve that first, then pair again "
                    + "with a fresh code.",
                canRetry: false)))
            return
        }
        await knownHosts.setFingerprint(
            result.hostKeyFingerprint, host: result.address, port: result.port)
        await send(.saved(token, host))
    }

    private static func message(for error: PairingCodeError) -> String {
        switch error {
        case .badPrefix:
            "That QR code is not a herdr Pairing Code."
        case .unsupportedVersion(let found):
            "This Pairing Code uses version \(found), which this app does not "
                + "understand. Update the app and the pairing plugin so they match."
        case .badEncoding, .badPayload:
            "The Pairing Code could not be read. Regenerate it on your Host and scan again."
        }
    }
}
