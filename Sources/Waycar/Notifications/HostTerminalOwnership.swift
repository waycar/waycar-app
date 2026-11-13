import Foundation

/// What one window's Agent detail may do with its Host's terminal channel.
enum HostTerminalAccess: Equatable, Sendable {
    /// This window holds the channel, nothing else wants it, or this window
    /// does not claim that Host and so has nothing to hand over.
    case holds
    /// Another window of the app holds it; Take Over moves it here.
    case liveInAnotherWindow
}

/// One window's claim on a Host's terminal channel: the Agent detail it has
/// on screen, on that Agent's Host and backend. Only a backend with one
/// writable attach owner (herdr) contends for the channel; a tmux row
/// attaches its own client and never displaces another window (ADR 0026).
struct HostTerminalClaim: Equatable, Sendable {
    let sceneID: UUID
    let hostID: Host.ID
    var backend: HostBackend = .herdr

    /// Whether this claim takes part in Host-keyed ownership.
    var contendsForChannel: Bool { backend.capabilities.takeover }
}

extension HostBackend {
    /// A row's terminal access on this backend: herdr rows read their Host's
    /// ownership; tmux rows always hold, since several clients attach at once.
    func terminalAccess(_ hostAccess: @autoclosure () -> HostTerminalAccess) -> HostTerminalAccess {
        capabilities.takeover ? hostAccess() : .holds
    }
}

/// Which window owns each Host's interactive Agent presentation, as a pure
/// decision over window claims. ADR 0017 allows retained idle terminals
/// alongside it; those use the shared retention budget.
///
/// Only one window actively presents an Agent on a given Host. Other loaded
/// Agents may retain their idle PTYs until expiry or eviction. "Key window" here
/// is the window the user is working in (see `AgentSceneState`), not UIKit's
/// per-scene key window. The rule:
///
/// - The user moving into a window, or the window they work in turning to a
///   Host, takes that Host's channel: the window being worked in is live.
/// - Otherwise the holder keeps it, so a background window navigating never
///   pulls the channel out from under the window being worked in.
/// - An explicit takeover moves it at once and holds until the user next
///   moves into another window.
/// - A Host whose holder stops claiming it passes to the key window if that
///   window claims it, else to the first-connected window that does.
///
/// Hosts claimed by one window only are unaffected: that window holds. A
/// window that does not claim a Host (not on one of its Agents, or not yet
/// reconciled onto one) reads `.holds` for it: Live in Another Window is
/// only for a window that wants the channel. A claim on a tmux row does not
/// count as claiming the Host (`HostTerminalClaim.contendsForChannel`).
struct HostTerminalOwnership: Equatable, Sendable {
    private(set) var holders: [Host.ID: UUID] = [:]
    /// The key window and the Host it claimed at the previous reconcile; a
    /// change to either is the key edge that hands a channel over.
    private var lastKeySceneID: UUID?
    private var lastKeyHostID: Host.ID?

    init() {}

    /// Re-derives every Host's holder. `claims` is in window connection
    /// order, at most one per window; `keySceneID` is the window most
    /// recently worked in, claiming or not.
    mutating func reconcile(claims allClaims: [HostTerminalClaim], keySceneID: UUID?) {
        let claims = allClaims.filter(\.contendsForChannel)
        let keyClaim = claims.first { $0.sceneID == keySceneID }
        let isKeyEdge =
            keyClaim != nil
            && (keySceneID != lastKeySceneID || keyClaim?.hostID != lastKeyHostID)
        lastKeySceneID = keySceneID
        lastKeyHostID = keyClaim?.hostID

        var next: [Host.ID: UUID] = [:]
        for claim in claims where next[claim.hostID] == nil {
            let hostID = claim.hostID
            let current = holders[hostID].flatMap { holder in
                claims.first { $0.sceneID == holder && $0.hostID == hostID }
            }
            if let keyClaim, keyClaim.hostID == hostID, isKeyEdge {
                next[hostID] = keyClaim.sceneID
            } else if let current {
                next[hostID] = current.sceneID
            } else if let keyClaim, keyClaim.hostID == hostID {
                next[hostID] = keyClaim.sceneID
            } else {
                next[hostID] = claim.sceneID
            }
        }
        holders = next
    }

    /// Moves `hostID`'s channel to `sceneID` on the user's explicit request.
    /// False when that window does not claim the Host.
    @discardableResult
    mutating func takeOver(
        hostID: Host.ID, sceneID: UUID, claims: [HostTerminalClaim]
    ) -> Bool {
        guard Self.claims(claims, sceneID: sceneID, hostID: hostID) else { return false }
        holders[hostID] = sceneID
        return true
    }

    func access(
        sceneID: UUID, hostID: Host.ID, claims: [HostTerminalClaim]
    ) -> HostTerminalAccess {
        guard Self.claims(claims, sceneID: sceneID, hostID: hostID),
            let holder = holders[hostID], holder != sceneID,
            Self.claims(claims, sceneID: holder, hostID: hostID)
        else { return .holds }
        return .liveInAnotherWindow
    }

    /// Whether `sceneID` contends for `hostID`'s channel among `claims`.
    private static func claims(
        _ claims: [HostTerminalClaim], sceneID: UUID, hostID: Host.ID
    ) -> Bool {
        claims.contains { $0.sceneID == sceneID && $0.hostID == hostID && $0.contendsForChannel }
    }
}
