import AudioToolbox
import Foundation
import Observation

/// One foreground banner with the push renderer's exact copy.
struct AgentNotificationBanner: Equatable, Sendable {
    let target: AgentNotificationTarget
    let status: AgentStatus
    let alert: AgentNotificationAlert
}

/// Announces held Blocked/Done transitions. First sight is a baseline;
/// summaries arriving by foreground push can rewrite or accompany a held
/// transition. Presentation-time gates suppress the shown Agent, fail closed
/// on unknown notification preferences, and defer while CarPlay voice speaks.
@MainActor
@Observable
final class AgentNotificationBannerStore {
    var banner: AgentNotificationBanner? { presentation.banner }
    private var presentation = NotificationBannerPresentationMachine()
    @ObservationIgnored private var pipeline = AgentNotificationPipelineMachine()
    @ObservationIgnored private var holds: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var replays: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var dismissals: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private let replayInterval: Duration
    @ObservationIgnored private let holdDuration: Duration
    @ObservationIgnored private let dismissDelay: Duration
    @ObservationIgnored private let presentedAgent: @MainActor () -> ConsoleAgent.ID?
    @ObservationIgnored private let triggers:
        @MainActor (Host.ID) -> NotificationTriggerPreferences?
    @ObservationIgnored private let playSound: @MainActor () -> Void
    @ObservationIgnored private let carVoice: @MainActor () -> CarVoiceActivity.State

    init(
        holdDuration: Duration = .seconds(3),
        dismissDelay: Duration = .seconds(5),
        replayInterval: Duration = .seconds(1),
        presentedAgent: @escaping @MainActor () -> ConsoleAgent.ID?,
        triggers: @escaping @MainActor (Host.ID) -> NotificationTriggerPreferences?,
        playSound: @escaping @MainActor () -> Void = { AudioServicesPlayAlertSound(1007) },
        carVoice: @escaping @MainActor () -> CarVoiceActivity.State = {
            CarVoiceActivity.shared.state
        }
    ) {
        self.holdDuration = holdDuration
        self.dismissDelay = dismissDelay
        self.replayInterval = replayInterval
        self.presentedAgent = presentedAgent
        self.triggers = triggers
        self.playSound = playSound
        self.carVoice = carVoice
    }

    func agentsDidChange(_ agents: [ConsoleAgent]) {
        let current = Dictionary(agents.map { ($0.id, $0) }) { _, last in last }
        for id in pipeline.knownIDs where current[id] == nil { send(.removed(id)) }
        for agent in current.values {
            send(.observed(AgentNotificationBanner(
                target: AgentNotificationTarget(hostID: agent.hostID, paneID: agent.agent.paneID),
                status: agent.agent.status,
                alert: AgentNotificationRenderer.alert(
                    workspace: agent.workspaceLabel, agentKind: agent.agent.kind,
                    status: agent.agent.status)), at: Date()))
        }
    }

    func pushDidArrive(target: AgentNotificationTarget, payload: NotificationPayload) {
        let summary = payload.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reply = payload.reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let status = payload.status
        guard status == .blocked || status == .done else { return }
        guard !summary.isEmpty || (status == .done && !reply.isEmpty) else { return }
        send(.push(AgentNotificationBanner(
            target: target, status: status, alert: AgentNotificationRenderer.alert(for: payload)),
            timestamp: payload.timestamp, showing: banner, gate: gate(for: target, status: status)))
    }

    func dismiss() { sendPresentation(.dismiss) }

    private func gate(
        for target: AgentNotificationTarget, status: AgentStatus
    ) -> AgentNotificationPipelineMachine.Gate {
        guard !AgentNotificationRouting.shouldSuppressBanner(
            target: target, presentedAgent: presentedAgent()) else { return .suppressed }
        if carVoice().quiets(target) { return .voiceQuiet }
        guard let notify = triggers(target.hostID), status == .done ? notify.done : notify.blocked
        else { return .disabled }
        return .allowed
    }

    private func send(_ event: AgentNotificationPipelineMachine.Event) {
        for effect in pipeline.handle(event) {
            switch effect {
            case .cancelHold(_, let token):
                holds.removeValue(forKey: token)?.cancel()
            case .armHold(let id, let token):
                let duration = holdDuration
                let target = AgentNotificationTarget(hostID: id.hostID, paneID: id.paneID)
                guard let status = pipeline.state.agents[id]?.observation?.status else { continue }
                holds[token] = Task { [weak self] in
                    try? await Task.sleep(for: duration)
                    guard let self, !Task.isCancelled else { return }
                    self.holds[token] = nil
                    self.send(.holdElapsed(id, token, self.gate(for: target, status: status)))
                }
            case .show(let banner, let sound):
                let effects = presentation.handle(.show(banner))
                if sound { playSound() }
                performPresentation(effects)
            case .armReplay(let token):
                let interval = replayInterval
                replays[token] = Task { [weak self] in
                    try? await Task.sleep(for: interval)
                    guard let self, !Task.isCancelled else { return }
                    self.replays[token] = nil
                    let voice = self.carVoice()
                    var gates: [ConsoleAgent.ID: AgentNotificationPipelineMachine.Gate] = [:]
                    for (id, target) in self.pipeline.deferred {
                        guard let status = self.pipeline.state.agents[id]?.observation?.status else { continue }
                        gates[id] = voice.quiets(target) ? .voiceQuiet : self.gate(for: target, status: status)
                    }
                    self.send(.replayElapsed(token, gates: gates))
                }
            }
        }
    }

    private func sendPresentation(_ event: NotificationBannerPresentationMachine.Event) {
        performPresentation(presentation.handle(event))
    }

    private func performPresentation(_ effects: [NotificationBannerPresentationMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .cancelDismissal(let token):
                dismissals.removeValue(forKey: token)?.cancel()
            case .armDismissal(let token):
                let delay = dismissDelay
                dismissals[token] = Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    self?.dismissals[token] = nil
                    self?.sendPresentation(.dismissalElapsed(token))
                }
            }
        }
    }
}
