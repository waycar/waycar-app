import Foundation

/// One install's answer. An in-memory acceptance closes the sheet before
/// permission resolves, but only a completed permission prompt is durable.
struct NotificationAskMachine: StateMachine {
    enum State: Equatable, Sendable {
        case unanswered(scene: UUID?)
        case awaitingPermission(UInt64)
        case accepted
        case declined
    }

    enum Permission: Equatable, Sendable { case allowed, denied, failed }

    enum Event: Equatable, Sendable {
        case present(UUID, eligible: Bool)
        case release(UUID)
        case unavailable(denied: Bool)
        case decline
        case turnOn(needsPermission: Bool)
        case permissionFinished(UInt64, Permission)
    }

    enum Effect: Equatable, Sendable {
        case initializeEnrollment
        case clearEnrollment
        case requestPermission(UInt64)
        case persist(NotificationAsk.Answer)
        case saveEnrollment
        case processEnrollment
    }

    private(set) var state: State
    private var lastToken: UInt64 = 0

    init(answer: NotificationAsk.Answer?) {
        switch answer {
        case .accepted?: state = .accepted
        case .declined?: state = .declined
        case nil: state = .unanswered(scene: nil)
        }
    }

    var answer: NotificationAsk.Answer? {
        switch state {
        case .unanswered: nil
        case .awaitingPermission, .accepted: .accepted
        case .declined: .declined
        }
    }

    var sceneID: UUID? {
        if case .unanswered(let scene) = state { scene } else { nil }
    }

    var canEnroll: Bool { state == .accepted }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.unanswered(nil), .present(let scene, true)):
            state = .unanswered(scene: scene)
        case (.unanswered(let current?), .release(let scene)) where current == scene:
            state = .unanswered(scene: nil)
        case (.unanswered(_?), .unavailable(let denied)):
            state = denied ? .declined : .unanswered(scene: nil)
            return denied ? [.persist(.declined)] : []
        case (.unanswered, .decline):
            state = .declined
            return [.persist(.declined)]
        case (.unanswered, .turnOn(let needsPermission)):
            if needsPermission {
                lastToken &+= 1
                state = .awaitingPermission(lastToken)
                return [.initializeEnrollment, .requestPermission(lastToken)]
            }
            state = .accepted
            return [.initializeEnrollment, .persist(.accepted), .saveEnrollment, .processEnrollment]
        case (.awaitingPermission(let current), .permissionFinished(let token, let result))
            where current == token:
            switch result {
            case .denied:
                state = .declined
                return [.clearEnrollment, .persist(.declined)]
            case .failed:
                state = .unanswered(scene: nil)
                return [.clearEnrollment]
            case .allowed:
                state = .accepted
                return [.persist(.accepted), .saveEnrollment, .processEnrollment]
            }
        case (.unanswered, _), (.awaitingPermission, _), (.accepted, _), (.declined, _):
            break
        }
        return []
    }
}
