import Foundation
import Testing

@testable import Waycar

/// The value that names one window's Agent: a `WindowGroup` value, a dragged
/// row's user activity, and a scene-storage string. Each encoding must bring
/// back exactly the Agent that went in, pane ids being opaque strings.
@Suite("Agent route")
struct AgentRouteTests {
    private static let hostID = UUID(uuidString: "6A1F4E0C-2B7D-4C3A-9E51-0D8B7F6A2C19")!

    /// Observed herdr pane ids plus deliberately awkward opaque strings: the
    /// encodings must not assume a `w…:p…` grammar or a safe delimiter.
    private static let paneIDs = ["wV:p1H", "w1C:p1", "%7", "a/b c\"d", "ペイン:1"]

    @Test(arguments: paneIDs)
    func codableRoundTripsTheAgent(paneID: String) throws {
        let route = AgentRoute(hostID: Self.hostID, paneID: paneID)

        let data = try JSONEncoder().encode(route)
        let decoded = try JSONDecoder().decode(AgentRoute.self, from: data)

        #expect(decoded == route)
        #expect(decoded.agentID == ConsoleAgent.ID(hostID: Self.hostID, paneID: paneID))
    }

    @Test(arguments: paneIDs)
    func sceneStorageRoundTripsTheAgent(paneID: String) {
        let route = AgentRoute(hostID: Self.hostID, paneID: paneID)

        #expect(AgentRoute(sceneStorageValue: route.sceneStorageValue) == route)
    }

    /// Scene storage outlives app versions, so the same route must always
    /// write the same string.
    @Test func sceneStorageValueIsStable() {
        let route = AgentRoute(hostID: Self.hostID, paneID: "w1:p2")

        #expect(route.sceneStorageValue == route.sceneStorageValue)
        #expect(
            route.sceneStorageValue
                == #"{"hostID":"6A1F4E0C-2B7D-4C3A-9E51-0D8B7F6A2C19","paneID":"w1:p2"}"#)
    }

    @Test(arguments: ["", "not json", #"{"hostID":"nope","paneID":"w1:p1"}"#, #"{"paneID":"w1:p1"}"#])
    func unreadableSceneStorageIsNoRoute(value: String) {
        #expect(AgentRoute(sceneStorageValue: value) == nil)
    }

    @Test(arguments: paneIDs)
    func userActivityRoundTripsTheAgent(paneID: String) {
        let route = AgentRoute(hostID: Self.hostID, paneID: paneID)

        let activity = route.makeUserActivity(title: "claude")

        #expect(activity.activityType == AgentRoute.activityType)
        #expect(activity.targetContentIdentifier == route.targetContentIdentifier)
        #expect(AgentRoute(userActivity: activity) == route)
    }

    @Test func foreignOrIncompleteActivitiesAreNoRoute() {
        let info = AgentRoute(hostID: Self.hostID, paneID: "w1:p1").userActivityInfo

        #expect(AgentRoute(activityType: "com.example.other", userInfo: info) == nil)
        #expect(AgentRoute(activityType: AgentRoute.activityType, userInfo: nil) == nil)
        #expect(
            AgentRoute(
                activityType: AgentRoute.activityType,
                userInfo: ["hostID": Self.hostID.uuidString]) == nil)
        #expect(
            AgentRoute(
                activityType: AgentRoute.activityType,
                userInfo: ["hostID": "nope", "paneID": "w1:p1"]) == nil)
    }

    /// A dragged row must get a new window, not land in an existing one that
    /// prefers Waycar's own `waycar://` links.
    @Test func dragTargetIsNotAWaycarLink() {
        let route = AgentRoute(hostID: Self.hostID, paneID: "w1:p1")

        #expect(!route.targetContentIdentifier.contains("\(AgentActivityLink.scheme)://"))
    }

    @Test func routeAndNotificationTargetNameTheSameAgent() {
        let target = AgentNotificationTarget(hostID: Self.hostID, paneID: "wR:pC")

        #expect(AgentRoute(target).target == target)
        #expect(AgentRoute(target).agentID == target.agentID)
    }
}

/// Where a window's Agent comes from on first appearance: its own scene
/// storage, then the value it was opened with, then a dragged row's activity.
@Suite("Scene route restoration")
struct SceneRouteRestorationTests {
    private let stored = AgentRoute(hostID: UUID(), paneID: "w1:p1")
    private let windowValue = AgentRoute(hostID: UUID(), paneID: "w2:p1")
    private let activity = AgentRoute(hostID: UUID(), paneID: "w3:p1")

    @Test func sceneStorageWinsOverEverything() {
        let restoration = SceneRouteRestoration.resolve(
            sceneStorage: stored.sceneStorageValue,
            windowValue: windowValue,
            userActivity: activity)

        #expect(restoration == SceneRouteRestoration(route: stored, source: .sceneStorage))
    }

    @Test func windowValueWinsOverAnActivity() {
        let restoration = SceneRouteRestoration.resolve(
            sceneStorage: nil, windowValue: windowValue, userActivity: activity)

        #expect(restoration == SceneRouteRestoration(route: windowValue, source: .windowValue))
    }

    @Test func activityIsTheLastResort() {
        let restoration = SceneRouteRestoration.resolve(
            sceneStorage: nil, windowValue: nil, userActivity: activity)

        #expect(restoration == SceneRouteRestoration(route: activity, source: .userActivity))
    }

    @Test func nothingRestoresTheConsole() {
        #expect(
            SceneRouteRestoration.resolve(
                sceneStorage: nil, windowValue: nil, userActivity: nil) == nil)
    }

    /// A stored value this version cannot read does not strand the window:
    /// the next source still applies.
    @Test func unreadableSceneStorageFallsThrough() {
        let restoration = SceneRouteRestoration.resolve(
            sceneStorage: "corrupt", windowValue: windowValue, userActivity: activity)

        #expect(restoration == SceneRouteRestoration(route: windowValue, source: .windowValue))
    }
}
