import Observation
import Testing

@testable import Waycar

@MainActor
@Suite("Agent input mode state")
struct AgentInputModeStateTests {
    /// While an Agent view's first updates run, SwiftUI renders the view
    /// inside the change notice and tracks the next change from that render
    /// (WAY-522). The render has to read the new mode: a render that read the
    /// old one is tracking a change that has already happened, so the view
    /// stays on the old mode with nothing left to redraw it. The notice a
    /// render sets up must also fire for the next change.
    @Test func aReadInsideTheChangeNoticeSeesTheNewModeAndTheNextChangeStillNotifies() {
        let state = AgentInputModeState()
        let log = NoticeLog()
        track(state, into: log)

        state.select(.composer)
        state.select(.direct)

        #expect(log.modesRead == [.composer, .direct])
    }

    @Test func selectingTheOpenModeNotifiesNobody() {
        let state = AgentInputModeState()
        let log = NoticeLog()
        track(state, into: log)

        state.select(.direct)

        #expect(log.modesRead.isEmpty)
        #expect(state.isDirect)
    }
}

/// Re-reads `mode` inside every change notice and tracks again, as a SwiftUI
/// render does.
@MainActor
private func track(_ state: AgentInputModeState, into log: NoticeLog) {
    withObservationTracking {
        _ = state.mode
    } onChange: {
        MainActor.assumeIsolated {
            log.modesRead.append(state.mode)
            track(state, into: log)
        }
    }
}

/// The mode each change notice read, in order.
@MainActor
private final class NoticeLog {
    var modesRead: [AgentInputMode] = []
}
