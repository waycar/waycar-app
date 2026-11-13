import Testing
import UIKit
import UserNotifications

@testable import Waycar

/// `willPresent` while the app is foreground (#77, docs/design/carplay.md
/// §6): silent only while a window can show the in-app banner.
@Suite("Agent Notification foreground presentation")
struct AgentNotificationPresentationTests {
    private typealias Delegate = AgentNotificationCenterDelegate
    private static let idle = CarVoiceActivity.State()
    private static let talking = AgentNotificationTarget(hostID: UUID(), paneID: "w1:pA")
    private static let other = AgentNotificationTarget(hostID: UUID(), paneID: "w1:pB")

    @Test func aWindowOnScreenSilencesThePush() {
        #expect(
            Delegate.presentationOptions(phoneWindowOnScreen: true, target: nil, carVoice: Self.idle)
                == [])
    }

    /// CarPlay holds the app foreground while the phone is locked: the
    /// Lock Screen and the Watch still get the push, without the badge the
    /// app sets itself.
    @Test func onlyTheCarPlaySceneActivePresentsThePush() {
        let options = Delegate.presentationOptions(
            phoneWindowOnScreen: false, target: Self.other, carVoice: Self.idle)
        #expect(options == [.banner, .list, .sound])
        #expect(!options.contains(.badge))
    }

    /// The Agent the driver is talking to stays quiet for the whole turn
    /// (its Done lands on its own spoken reply) but still reaches the list;
    /// other Agents still present while the car neither speaks nor listens.
    @Test func theConversationsAgentIsQuietForTheTurn() {
        var voice = CarVoiceActivity.State()
        voice.agent = Self.talking.agentID
        #expect(
            Delegate.presentationOptions(phoneWindowOnScreen: false, target: Self.talking, carVoice: voice)
                == [.list])
        #expect(
            Delegate.presentationOptions(phoneWindowOnScreen: false, target: Self.other, carVoice: voice)
                == [.banner, .list, .sound])
    }

    /// While the car speaks or listens, every Agent Notification presents
    /// list-only (no banner, no sound), one that can't be decrypted too.
    @Test func speakingOrListeningQuietsEveryAgentToTheList() {
        var speaking = CarVoiceActivity.State()
        speaking.speaking = 1
        var listening = CarVoiceActivity.State()
        listening.listening = 1
        for voice in [speaking, listening] {
            for target in [Self.other, nil] {
                #expect(
                    Delegate.presentationOptions(
                        phoneWindowOnScreen: false, target: target, carVoice: voice) == [.list])
            }
        }
    }

    /// A line that never ends stops quieting after `maxQuiet`.
    @Test func theQuietIsTimeBounded() {
        var voice = CarVoiceActivity.State()
        voice.speaking = 1
        let start = Date()
        voice.busySince = start
        #expect(voice.quiets(Self.other, now: start.addingTimeInterval(5)))
        #expect(
            !voice.quiets(
                Self.other, now: start.addingTimeInterval(CarVoiceActivity.State.maxQuiet + 1)))
    }

    private static func payload(_ target: AgentNotificationTarget, _ status: AgentStatus)
        -> NotificationPayload
    {
        NotificationPayload(
            paneID: target.paneID, agentKind: "claude", status: status, timestamp: Date(),
            project: nil, summary: "needs approval", reply: nil)
    }

    /// A Blocked push from another Agent while the car speaks is queued for
    /// the car to announce; the turn's own Agent, a Done, or an idle car
    /// queue nothing.
    @Test func anotherAgentsBlockedPushIsQueuedForTheCar() {
        var voice = CarVoiceActivity.State()
        voice.agent = Self.talking.agentID
        voice.speaking = 1
        let queued = Delegate.pendingAnnouncement(
            target: Self.other, payload: Self.payload(Self.other, .blocked), carVoice: voice)
        #expect(queued?.target == Self.other)
        #expect(
            Delegate.pendingAnnouncement(
                target: Self.talking, payload: Self.payload(Self.talking, .blocked),
                carVoice: voice) == nil)
        #expect(
            Delegate.pendingAnnouncement(
                target: Self.other, payload: Self.payload(Self.other, .done), carVoice: voice)
                == nil)
        voice.speaking = 0
        #expect(
            Delegate.pendingAnnouncement(
                target: Self.other, payload: Self.payload(Self.other, .blocked), carVoice: voice)
                == nil)
    }

    /// Begin/end pairs return the activity to idle, and the busy clock
    /// starts with the first and clears with the last.
    @Test func countersReturnToIdle() {
        let activity = CarVoiceActivity()
        activity.setAgent(Self.talking.agentID)
        activity.beginSpeaking()
        activity.beginListening()
        #expect(activity.state.busySince != nil)
        #expect(activity.state.quiets(Self.other))
        activity.endSpeaking()
        #expect(activity.state.busySince != nil)
        activity.endListening()
        activity.setAgent(nil)
        #expect(activity.state == CarVoiceActivity.State())
        #expect(!activity.state.quiets(Self.other))
    }

    /// The queue keeps one announcement per Agent, latest wins, and
    /// draining empties it.
    @Test func pendingAnnouncementsDrainOnce() {
        let activity = CarVoiceActivity()
        let first = AgentNotificationAlert(title: "A", body: "1")
        let second = AgentNotificationAlert(title: "A", body: "2")
        activity.enqueue(.init(target: Self.other, alert: first))
        activity.enqueue(.init(target: Self.talking, alert: first))
        activity.enqueue(.init(target: Self.other, alert: second))
        #expect(
            activity.drainPending() == [
                .init(target: Self.talking, alert: first), .init(target: Self.other, alert: second),
            ])
        #expect(activity.drainPending().isEmpty)
    }

    /// Notification Center, Control Center or a system alert over a Waycar
    /// window leaves it inactive but on screen: the push stays silent and
    /// the in-app banner announces, as before CarPlay.
    @Test func anInactiveWindowStillCountsAsOnScreen() {
        #expect(PhoneWindowPresence.isOnScreen(.foregroundActive))
        #expect(PhoneWindowPresence.isOnScreen(.foregroundInactive))
        #expect(!PhoneWindowPresence.isOnScreen(.background))
        #expect(!PhoneWindowPresence.isOnScreen(.unattached))
    }
}
