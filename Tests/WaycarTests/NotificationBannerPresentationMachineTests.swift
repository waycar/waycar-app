import Foundation
import Testing

@testable import Waycar

struct NotificationBannerPresentationMachineTests {
    private let target = AgentNotificationTarget(hostID: UUID(), paneID: "w1:p1")

    private func banner(_ body: String) -> AgentNotificationBanner {
        AgentNotificationBanner(target: target, status: .done,
            alert: AgentNotificationAlert(title: "Done", body: body))
    }

    @Test func showAndAutoDismiss() {
        var machine = NotificationBannerPresentationMachine()
        #expect(machine.banner == nil)
        #expect(machine.handle(.show(banner("first"))) == [.armDismissal(1)])
        #expect(machine.banner == banner("first"))
        #expect(machine.handle(.dismissalElapsed(1)) == [])
        #expect(machine.state == .hidden)
    }

    @Test func summaryRewriteReplacesTheTimerAndStaleExpiryCannotHideIt() {
        var machine = NotificationBannerPresentationMachine().after([.show(banner("first"))])
        #expect(machine.handle(.show(banner("summary"))) == [.cancelDismissal(1), .armDismissal(2)])
        #expect(machine.handle(.dismissalElapsed(1)) == [])
        #expect(machine.banner == banner("summary"))
        #expect(machine.handle(.dismissalElapsed(2)) == [])
        #expect(machine.banner == nil)
    }

    @Test func manualDismissCancelsAndTokensAreNotReused() {
        var machine = NotificationBannerPresentationMachine().after([.show(banner("first"))])
        #expect(machine.handle(.dismiss) == [.cancelDismissal(1)])
        #expect(machine.handle(.dismissalElapsed(1)) == [])
        #expect(machine.handle(.show(banner("next"))) == [.armDismissal(2)])
        #expect(machine.handle(.dismissalElapsed(1)) == [])
        #expect(machine.banner == banner("next"))
    }

    @Test func hiddenIgnoresDismissalsAndUnsolicitedExpiries() {
        var machine = NotificationBannerPresentationMachine()
        #expect(machine.handle(.dismiss) == [])
        #expect(machine.handle(.dismissalElapsed(1)) == [])
        #expect(machine.state == .hidden)
        _ = machine.handle([.show(banner("first")), .dismissalElapsed(1)])
        #expect(machine.handle(.show(banner("next"))) == [.armDismissal(2)])
    }
}
