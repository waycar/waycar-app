/// One consent-authorized install on one Host. Only a fresh detection can
/// prove the install; a found herdr/core install then starts its runtime once.
struct BackendInstallRunMachine: StateMachine {
    enum State: Equatable, Sendable {
        case idle
        case installing(token: UInt64, run: BackendInstallCenter.Run)
        case detecting(token: UInt64, run: BackendInstallCenter.Run, installer: BackendInstallRun)
        case startingRuntime(token: UInt64, run: BackendInstallCenter.Run, outcome: BackendInstallCenter.Outcome)
        case finished(BackendInstallCenter.Outcome)
    }

    enum Event: Sendable {
        case start(BackendInstallPlan)
        case output(UInt64, String)
        case installerEnded(UInt64, Result<BackendInstallRun, TransportError>)
        case detected(UInt64, Result<HostBackendPresence, TransportError>)
        case runtimeEnded(UInt64)
        case dismiss
    }

    enum Effect: Equatable, Sendable {
        case install(UInt64, BackendInstallPlan)
        case detect(UInt64)
        case startRuntime(UInt64, BackendInstallTarget)
        case report(BackendInstallCenter.Outcome)
    }

    private(set) var state: State = .idle
    private var lastToken: UInt64 = 0

    var run: BackendInstallCenter.Run? {
        switch state {
        case .installing(_, let run), .detecting(_, let run, _), .startingRuntime(_, let run, _): run
        case .idle, .finished: nil
        }
    }

    var outcome: BackendInstallCenter.Outcome? {
        if case .finished(let outcome) = state { outcome } else { nil }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .start(let plan)), (.finished, .start(let plan)):
            lastToken += 1
            state = .installing(token: lastToken, run: .init(plan: plan, phase: .installing(latestLine: nil)))
            return [.install(lastToken, plan)]
        case (.installing(let current, var run), .output(let token, let line)) where current == token:
            run.phase = .installing(latestLine: line)
            run.output.append(line)
            if run.output.count > BackendInstallCenter.Run.outputLimit {
                run.output.removeFirst(run.output.count - BackendInstallCenter.Run.outputLimit)
            }
            state = .installing(token: token, run: run)
            return []
        case (.installing(let current, var run), .installerEnded(let token, let result)) where current == token:
            switch result {
            case .failure(let error): return finish(run.plan, .hostUnreachable(error))
            case .success(let installer):
                guard installer.exitStatus != nil else {
                    let detail = installer.lastLine.map { "The connection ended during the install. Last line: \($0)" }
                        ?? "The connection ended during the install."
                    return finish(run.plan, .hostUnreachable(.channelFailed(detail: detail)))
                }
                guard installer.succeeded else {
                    return finish(run.plan, .failed(BackendInstall.failure(for: run.plan.target, run: installer)))
                }
                run.phase = .checking
                state = .detecting(token: token, run: run, installer: installer)
                return [.detect(token)]
            }
        case (.detecting(let current, let run, let installer), .detected(let token, let detection)) where current == token:
            switch detection {
            case .failure(let error): return finish(run.plan, .hostUnreachable(error))
            case .success(let presence):
                let result = BackendInstall.result(afterInstalling: run.plan.target, run: installer, presence: presence)
                if case .found = result {
                    switch run.plan.target {
                    case .herdr, .core:
                        state = .startingRuntime(token: token, run: run, outcome: .init(plan: run.plan, result: result))
                        return [.startRuntime(token, run.plan.target)]
                    case .tmux: break
                    }
                }
                return finish(run.plan, result)
            }
        case (.startingRuntime(let current, _, let outcome), .runtimeEnded(let token)) where current == token:
            return finish(outcome.plan, outcome.result)
        case (.finished, .dismiss):
            state = .idle
            return []
        case (.idle, _), (.installing, _), (.detecting, _), (.startingRuntime, _), (.finished, _):
            return []
        }
    }

    private mutating func finish(_ plan: BackendInstallPlan, _ result: BackendInstallResult) -> [Effect] {
        let outcome = BackendInstallCenter.Outcome(plan: plan, result: result)
        state = .finished(outcome)
        return [.report(outcome)]
    }
}
