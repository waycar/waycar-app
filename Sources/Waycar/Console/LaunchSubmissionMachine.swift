import Foundation

/// New Agent's outcome and ordered progress. Presentation retains the last
/// success metadata just as the sheet did; only a started outcome consumes it.
/// Each launch gets a new token, including replay without form preparation.
struct LaunchSubmissionMachine: StateMachine {
    enum Presentation: Equatable, Sendable {
        case editing
        case starting
        case failed(String)
        case started(ConsoleAgent.ID)
        case queued(QueuedLaunch.ID)
    }

    struct Report: Equatable, Sendable {
        var steps: [StartAgentStore.LaunchStepProgress] = []
        var keepsLaunch = false
        var launchedKind: SupportedAgentKind?
        var launchedChat = false
    }

    enum State: Equatable, Sendable {
        case editing(Report)
        case preparing(Report)
        case launching(UInt64, Report)
        case failed(String, Report)
        case started(ConsoleAgent.ID, Report)
        case queued(QueuedLaunch.ID, Report)
    }

    enum Success: Equatable, Sendable {
        case agent(SupportedAgentKind?, chat: Bool)
        case shell
    }

    enum Event: Equatable, Sendable {
        case submissionBegan
        case preparing
        case launchBegan
        case keepsLaunch(Bool)
        case editing
        case resetFailure
        case failed(String)
        case launchFailed(UInt64, String)
        case step(UInt64, LaunchStep, Date, title: String)
        case operationFailed(UInt64)
        case started(UInt64, ConsoleAgent.ID, Success)
        case queued(QueuedLaunch.ID)
    }

    enum Effect: Equatable, Sendable {
        case launch(UInt64)
    }

    private(set) var state: State = .editing(Report())
    private var lastToken: UInt64 = 0

    var report: Report {
        switch state {
        case .editing(let report), .preparing(let report), .launching(_, let report),
            .failed(_, let report), .started(_, let report), .queued(_, let report): report
        }
    }

    var presentation: Presentation {
        switch state {
        case .editing: .editing
        case .preparing, .launching: .starting
        case .failed(let message, _): .failed(message)
        case .started(let id, _): .started(id)
        case .queued(let id, _): .queued(id)
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .submissionBegan):
            var report = report
            report.steps = []
            replaceReport(report)
        case (_, .keepsLaunch(let keeps)):
            var report = report
            report.keepsLaunch = keeps
            replaceReport(report)
        case (_, .preparing): state = .preparing(report)
        case (_, .launchBegan):
            lastToken += 1
            state = .launching(lastToken, report)
            return [.launch(lastToken)]
        case (_, .editing): state = .editing(report)
        case (.failed(_, var report), .resetFailure):
            report.steps = []
            state = .editing(report)
        case (_, .failed(let message)): state = .failed(message, report)
        case (.launching(let current, let report), .launchFailed(let token, let message))
            where current == token:
            state = .failed(message, report)
        case (.launching(let current, var report), .step(let token, let step, let date, let title))
            where current == token:
            if let last = report.steps.indices.last, report.steps[last].status == .running {
                guard report.steps[last].step != step else { return [] }
                report.steps[last].status = .done
            }
            report.steps.append(.init(step: step, startedAt: date, status: .running, title: title))
            state = .launching(current, report)
        case (.launching(let current, var report), .operationFailed(let token)) where current == token:
            if let last = report.steps.indices.last, report.steps[last].status == .running {
                report.steps[last].status = .failed
            }
            state = .launching(current, report)
        case (.launching(let current, var report), .started(let token, let id, let success))
            where current == token:
            switch success {
            case .agent(let kind, let chat):
                report.launchedKind = kind
                report.launchedChat = chat
            case .shell:
                report.launchedChat = false
            }
            state = .started(id, report)
        case (_, .queued(let id)): state = .queued(id, report)
        case (.editing, _), (.preparing, _), (.launching, _), (.failed, _), (.started, _), (.queued, _):
            break
        }
        return []
    }

    private mutating func replaceReport(_ report: Report) {
        switch state {
        case .editing: state = .editing(report)
        case .preparing: state = .preparing(report)
        case .launching(let token, _): state = .launching(token, report)
        case .failed(let message, _): state = .failed(message, report)
        case .started(let id, _): state = .started(id, report)
        case .queued(let id, _): state = .queued(id, report)
        }
    }
}
