/// The one foreground banner on screen. Every replacement or summary rewrite
/// owns a new dismissal timer, so an old timer cannot dismiss a newer banner.
struct NotificationBannerPresentationMachine: StateMachine {
    enum State: Equatable, Sendable {
        case hidden
        case showing(AgentNotificationBanner, timer: UInt64)
    }
    enum Event: Equatable, Sendable {
        case show(AgentNotificationBanner)
        case dismiss
        case dismissalElapsed(UInt64)
    }
    enum Effect: Equatable, Sendable {
        case armDismissal(UInt64)
        case cancelDismissal(UInt64)
    }

    private(set) var state: State = .hidden
    private var lastToken: UInt64 = 0

    var banner: AgentNotificationBanner? {
        if case .showing(let banner, _) = state { banner } else { nil }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .show(let banner)):
            let cancel: [Effect]
            if case .showing(_, let timer) = state { cancel = [.cancelDismissal(timer)] }
            else { cancel = [] }
            lastToken += 1
            state = .showing(banner, timer: lastToken)
            return cancel + [.armDismissal(lastToken)]
        case (.showing(_, let timer), .dismiss):
            state = .hidden
            return [.cancelDismissal(timer)]
        case (.showing(_, let timer), .dismissalElapsed(let token)) where timer == token:
            state = .hidden
            return []
        case (.showing, .dismissalElapsed), (.hidden, .dismiss), (.hidden, .dismissalElapsed):
            return []
        }
    }
}
