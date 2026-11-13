import Foundation

/// One scanned code's ceremony, including retry credentials and persistence.
/// A verification failure consumes the bootstrap credential, not the scan's
/// provenance. Only the current attempt can report steps or publish a Host.
struct PairingCeremonyMachine: StateMachine {
    struct Scan: Equatable, Sendable {
        let code: PairingCode
        let method: PairingMethod
        var credential: Credential = .scanned

        enum Credential: Equatable, Sendable {
            case scanned
            case enrolledDeviceKey
        }

        var attemptCode: PairingCode {
            switch credential {
            case .scanned: code
            case .enrolledDeviceKey:
                PairingCode(
                    addresses: code.addresses, port: code.port, username: code.username,
                    hostKeyFingerprint: code.hostKeyFingerprint, bootstrap: nil)
            }
        }

        var isConfigOnly: Bool {
            code.bootstrap == nil && credential == .scanned
        }
    }

    enum State: Equatable, Sendable {
        case scanning(failure: String?)
        case ready(Scan)
        case attempting(UInt64, Scan, step: PairingStep?)
        case saving(UInt64, Scan, step: PairingStep?)
        case failed(Scan, PairingFailure)
        case paired(Scan, Host)
    }

    enum Event: Equatable, Sendable {
        case parsed(PairingCode, PairingMethod)
        case parseFailed(String)
        case pair(now: Date)
        case step(UInt64, PairingStep)
        case ceremonyFailed(UInt64, PairingCeremonyError)
        case failed(UInt64, PairingFailure)
        case cancelled(UInt64)
        case verified(UInt64, PairingResult)
        case saved(UInt64, Host)
        case rescan
    }

    enum Effect: Equatable, Sendable {
        case connect(UInt64, PairingCode)
        case save(UInt64, PairingResult)
    }

    private(set) var state: State = .scanning(failure: nil)
    private var lastToken: UInt64 = 0

    private var scan: Scan? {
        switch state {
        case .scanning: nil
        case .ready(let scan), .attempting(_, let scan, _), .saving(_, let scan, _),
            .failed(let scan, _), .paired(let scan, _): scan
        }
    }

    var pairingCode: PairingCode? { scan?.code }
    var method: PairingMethod? { scan?.method }
    var scanFailureMessage: String? {
        if case .scanning(let failure) = state { return failure }
        return nil
    }
    var isPairing: Bool {
        switch state {
        case .attempting, .saving: true
        case .scanning, .ready, .failed, .paired: false
        }
    }
    var step: PairingStep? {
        switch state {
        case .attempting(_, _, let step), .saving(_, _, let step): step
        case .scanning, .ready, .failed, .paired: nil
        }
    }
    var failure: PairingFailure? {
        if case .failed(_, let failure) = state { return failure }
        return nil
    }
    var pairedHost: Host? {
        if case .paired(_, let host) = state { return host }
        return nil
    }
    var stage: PairingStage {
        guard pairingCode != nil else { return .scan }
        if let failure { return PairingStage(failure.step) }
        if let step { return PairingStage(step) }
        return .start
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.scanning, .parsed(let code, let method)):
            state = .ready(Scan(code: code, method: method))
            return []
        case (.scanning, .parseFailed(let message)):
            state = .scanning(failure: message)
            return []
        case (.ready(let scan), .pair(let now)), (.failed(let scan, _), .pair(let now)):
            // canRetry controls the button, not admission to the public pair API.
            if let bootstrap = scan.attemptCode.bootstrap, bootstrap.expiresAt <= now {
                state = .failed(scan, PairingFailure(
                    step: .parse, message: Self.expiredCopy, canRetry: false))
                return []
            }
            lastToken += 1
            state = .attempting(lastToken, scan, step: nil)
            return [.connect(lastToken, scan.attemptCode)]
        case (.attempting(let current, let scan, _), .step(let token, let step))
            where current == token:
            state = .attempting(current, scan, step: step)
            return []
        case (.saving(let current, let scan, _), .step(let token, let step))
            where current == token:
            // The old owner's generation guard stayed open while fingerprint
            // persistence awaited; retain that progress-callback behavior.
            state = .saving(current, scan, step: step)
            return []
        case (.attempting(let current, var scan, _), .ceremonyFailed(let token, let error))
            where current == token:
            if case .verificationFailed = error, scan.attemptCode.bootstrap != nil {
                scan.credential = .enrolledDeviceKey
            }
            state = .failed(scan, Self.failure(for: error, isConfigOnly: scan.isConfigOnly))
            return []
        case (.attempting(let current, let scan, _), .failed(let token, let failure)),
            (.saving(let current, let scan, _), .failed(let token, let failure)):
            guard current == token else { return [] }
            state = .failed(scan, failure)
            return []
        case (.attempting(let current, let scan, _), .cancelled(let token))
            where current == token:
            state = .ready(scan)
            return []
        case (.attempting(let current, let scan, let step), .verified(let token, let result))
            where current == token:
            state = .saving(token, scan, step: step)
            return [.save(token, result)]
        case (.saving(let current, let scan, _), .saved(let token, let host))
            where current == token:
            state = .paired(scan, host)
            return []
        case (.scanning, .rescan), (.ready, .rescan), (.failed, .rescan), (.paired, .rescan):
            state = .scanning(failure: nil)
            return []
        case (.scanning, _), (.ready, _), (.attempting, _), (.saving, _), (.failed, _),
            (.paired, _):
            return []
        }
    }

    // MARK: Existing failure copy

    private static let expiredCopy =
        "This Pairing Code has expired. Generate a new one on the computer and scan it."

    private static func failure(
        for error: PairingCeremonyError, isConfigOnly: Bool
    ) -> PairingFailure {
        switch error {
        case .hostUnreachable:
            PairingFailure(
                step: .reach,
                message: "The Host did not answer at any of its addresses. Check that this "
                    + "device is on the same network or VPN as the computer, then try again "
                    + "with the same code.",
                canRetry: true)
        case .bootstrapRejected:
            PairingFailure(
                step: .authenticate,
                message: "The Host rejected this Pairing Code. It may have been used already, "
                    + "expired, or its popup was closed. Generate a new Pairing Code on the "
                    + "computer and scan it.",
                canRetry: false)
        case .enrollmentRefused(.expired):
            PairingFailure(step: .enroll, message: expiredCopy, canRetry: false)
        case .enrollmentRefused(.unknownPairing):
            PairingFailure(
                step: .enroll,
                message: "The Host has no pairing in progress for this code. Generate a new "
                    + "Pairing Code on the computer and scan it.",
                canRetry: false)
        case .enrollmentRefused(.invalidKey):
            PairingFailure(
                step: .enroll,
                message: "The Host did not accept this device's key. Try again; if it keeps "
                    + "failing, update the app and the pairing plugin so they match.",
                canRetry: true)
        case .enrollmentRefused(.noInput):
            PairingFailure(
                step: .enroll,
                message: "This device's key never reached the Host. Try again with the same code.",
                canRetry: true)
        case .enrollmentRefused(.unrecognized(let code)):
            PairingFailure(
                step: .enroll,
                message: "The Host refused Enrollment (\(code)). Update the app and the pairing "
                    + "plugin so they match, then generate a new Pairing Code.",
                canRetry: false)
        case .enrollmentFailed:
            PairingFailure(
                step: .enroll,
                message: "Enrollment did not complete, likely a network hiccup. "
                    + "Try again with the same code.",
                canRetry: true)
        case .verificationFailed where isConfigOnly:
            PairingFailure(
                step: .verify,
                message: "The Host did not accept the Device Key, so it is not authorized there "
                    + "yet. Add this device's authorized_keys line on the Host, or generate a "
                    + "Pairing Code on your Host instead.",
                canRetry: false)
        case .verificationFailed:
            PairingFailure(
                step: .verify,
                message: "This device was enrolled, but the verifying reconnect did not get "
                    + "through. Try again to finish with the enrolled key.",
                canRetry: true)
        }
    }
}
