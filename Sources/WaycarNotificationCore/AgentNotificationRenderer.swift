import Foundation

/// What the Notification Service Extension ends up showing: either decrypted
/// Agent Notification content or the generic fallback banner.
struct AgentNotificationAlert: Sendable, Equatable {
    let title: String
    let body: String
}

/// The service extension's logic as a pure function (#71): take the push's
/// `userInfo` and the registered Notification Keys, select the key by the
/// envelope's kid, decrypt, and phrase the alert as workspace, Agent kind, and
/// status. Anything undecryptable — missing or non-string envelope, unknown
/// kid, any `NotificationEnvelopeError` — degrades to `fallback`, which the
/// extension applies unconditionally so a forged push can never render
/// attacker-chosen text (spec #68, user story 20).
enum AgentNotificationRenderer {
    /// Generic, deliberately unalarming copy (the relay's wrap body; the
    /// title names this app, where the upstream relay still names Waycar).
    static let fallback = AgentNotificationAlert(title: "Waycar", body: "Agent update")

    static func alert(
        userInfo: [AnyHashable: Any], keys: [NotificationKeyRecord]
    ) -> AgentNotificationAlert {
        alert(for: NotificationEnvelope.open(userInfo: userInfo, keys: keys)?.payload)
    }

    /// The alert for an already opened payload; nil (undecryptable) is the
    /// fallback. A Done push from a Chat Mode Agent carrying its final reply
    /// shows that reply as the body, like a text message; the title stays.
    static func alert(for payload: NotificationPayload?) -> AgentNotificationAlert {
        guard let payload else { return fallback }
        let standard = alert(
            workspace: payload.project, agentKind: payload.agentKind, status: payload.status,
            summary: payload.summary)
        let reply = payload.reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard payload.status == .done, !reply.isEmpty else { return standard }
        return AgentNotificationAlert(title: standard.title, body: reply)
    }

    /// The one phrasing of an Agent Notification, shared by the push path
    /// above and the in-app foreground banner (#77) so the fixed wording
    /// cannot drift between them.
    ///
    /// The workspace leads: with several agents running, it is what tells one
    /// notification from another — the agent kind rarely differs. The Host is
    /// deliberately absent: it is the same machine every time and spends the
    /// whole line on an address nobody reads. The encrypted wire still calls
    /// this value `project` for backward compatibility with older plugins.
    ///
    /// An Agent Summary, when the Host sent one, replaces the fixed status
    /// wording after the status word ("Blocked: approve the merge"). Only a
    /// push carries one; the foreground banner opens with the fixed wording
    /// and takes the summary's when that push arrives.
    static func alert(
        workspace: String?, agentKind: String, status: AgentStatus, summary: String? = nil
    ) -> AgentNotificationAlert {
        return AgentNotificationAlert(
            title: AgentNotificationIdentity.title(workspace: workspace, kind: agentKind),
            body: body(for: status, summary: summary))
    }

    private static func body(for status: AgentStatus, summary: String?) -> String {
        let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch status {
        case .blocked: return summary.isEmpty ? "Blocked — waiting for input" : "Blocked: \(summary)"
        case .done: return summary.isEmpty ? "Done" : "Done: \(summary)"
        // The status set is open on the wire; render unrecognized values
        // factually instead of guessing at their meaning.
        default: return "Status: \(status.rawValue)"
        }
    }
}
