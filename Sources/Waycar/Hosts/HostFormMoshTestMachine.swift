import Foundation
import Observation

/// Existing form row presentation; no new labels accompany invalidation.
enum HostFormMoshTestResult: Equatable, Sendable {
    case idle
    case testing
    case available
    case unavailable
    case couldNotConnect(String)
}

/// A result belongs to the connection details tested, never to the mutable
/// form. A changed target retires the token before another remote step.
struct HostFormMoshTestMachine: StateMachine {
    enum Outcome: Equatable, Sendable {
        case available
        case unavailable
        case couldNotConnect(String)
    }

    struct Target: Equatable, Sendable {
        private let connectionDraft: HostDraft

        init(_ draft: HostDraft) {
            var connectionDraft = draft
            connectionDraft.name = "" // A display-name edit does not retarget SSH.
            self.connectionDraft = connectionDraft
        }
    }

    enum State: Equatable, Sendable {
        case idle
        case detecting(UInt64, Target)
        case connecting(UInt64, Target)
        case probing(UInt64, Target)
        case finished(Target, Outcome)
    }

    enum Event: Equatable, Sendable {
        case test(Target)
        case draftChanged(Target)
        case detected(UInt64)
        case connected(UInt64)
        case completed(UInt64, Outcome)
        case ended(UInt64)
    }

    enum Effect: Equatable, Sendable {
        case detect(UInt64)
        case connect(UInt64)
        case probe(UInt64)
    }

    private(set) var state: State = .idle
    private var lastToken: UInt64 = 0

    var result: HostFormMoshTestResult {
        switch state {
        case .idle: .idle
        case .detecting, .connecting, .probing: .testing
        case .finished(_, .available): .available
        case .finished(_, .unavailable): .unavailable
        case .finished(_, .couldNotConnect(let reason)): .couldNotConnect(reason)
        }
    }

    var target: Target? {
        switch state {
        case .idle: nil
        case .detecting(_, let target), .connecting(_, let target), .probing(_, let target),
             .finished(let target, _): target
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .test(let target)), (.finished, .test(let target)):
            lastToken += 1
            state = .detecting(lastToken, target)
            return [.detect(lastToken)]
        case (.detecting(let token, let target), .detected(let completed)) where token == completed:
            state = .connecting(token, target)
            return [.connect(token)]
        case (.connecting(let token, let target), .connected(let completed)) where token == completed:
            state = .probing(token, target)
            return [.probe(token)]
        case (.detecting(let token, let target), .completed(let completed, let result)),
             (.connecting(let token, let target), .completed(let completed, let result)),
             (.probing(let token, let target), .completed(let completed, let result)):
            guard token == completed else { return [] }
            state = .finished(target, result)
            return []
        case (.detecting(let token, let target), .ended(let completed)),
             (.connecting(let token, let target), .ended(let completed)),
             (.probing(let token, let target), .ended(let completed)):
            guard token == completed else { return [] }
            state = .finished(target, .couldNotConnect("The test was interrupted."))
            return []
        case (_, .draftChanged(let current)):
            if let target, target != current { state = .idle }
            return []
        case (.idle, _), (.detecting, _), (.connecting, _), (.probing, _), (.finished, _):
            return []
        }
    }
}

/// Owns the form's one-shot test; the View owns this store, not a Task or a
/// remembered result. Production still declines unknown keys and proves UDP.
@MainActor
@Observable
final class HostFormMoshTestStore {
    private var machine = HostFormMoshTestMachine()
    @ObservationIgnored private let connector: any TransportConnector
    @ObservationIgnored private let credentials: HostCredentialsProvider
    @ObservationIgnored private let knownHosts: any KnownHostsStore

    init(
        connector: any TransportConnector = SSHTransportConnector(),
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared
    ) {
        self.connector = connector
        self.credentials = credentials
        self.knownHosts = knownHosts
    }

    func result(for draft: HostDraft) -> HostFormMoshTestResult {
        guard machine.target == HostFormMoshTestMachine.Target(draft) else { return .idle }
        return machine.result
    }

    func draftChanged(_ draft: HostDraft) {
        _ = machine.handle(.draftChanged(HostFormMoshTestMachine.Target(draft)))
    }

    func test(draft: HostDraft, editing: Host?) async {
        guard editing?.isEnabled != false else { return }
        draftChanged(draft)
        for effect in machine.handle(.test(HostFormMoshTestMachine.Target(draft))) {
            switch effect {
            case .detect(let token): await test(token: token, draft: draft, editing: editing)
            case .connect, .probe: break // Emitted by the matching completion below.
            }
        }
    }

    private func test(token: UInt64, draft: HostDraft, editing: Host?) async {
        defer { _ = machine.handle(.ended(token)) }
        guard let host = draft.makeHost() else {
            complete(token, .couldNotConnect("The Host details above are incomplete."))
            return
        }
        if draft.authMethod == .password, draft.password.isEmpty, editing == nil {
            complete(token, .couldNotConnect(
                "Enter the password above first — it is not stored until the Host is saved."))
            return
        }
        do {
            let resolved = try credentials.credentials(for: host)
            let policy = HostKeyPolicy(knownHosts: knownHosts) { _ in false }
            let settings = SSHTransportSettings(host: host, credentials: resolved, hostKeyPolicy: policy)
            let presence = try await connector.detectBackends(settings: settings)
            guard machine.handle(.detected(token)) == [.connect(token)] else { return }
            let transport = try await connector.connect(
                settings: settings, backend: HostOnboardingStore.primaryBackend(for: presence))
            defer { Task { try? await transport.close() } }
            guard machine.handle(.connected(token)) == [.probe(token)] else { return }
            do {
                let available = try await transport.probeMoshServer()
                complete(token, available ? .available : .unavailable)
            } catch {
                complete(token, .couldNotConnect("The mosh probe could not run."))
            }
        } catch HostCredentialsError.passwordNotSet {
            complete(token, .couldNotConnect(
                "No password is saved for this Host. Save the Host and try again."))
        } catch {
            complete(token, .couldNotConnect(
                (error as? TransportError)?.presentation.summary ?? String(describing: error)))
        }
    }

    private func complete(_ token: UInt64, _ result: HostFormMoshTestMachine.Outcome) {
        _ = machine.handle(.completed(token, result))
    }
}
