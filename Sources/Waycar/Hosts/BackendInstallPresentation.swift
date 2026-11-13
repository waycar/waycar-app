import Foundation

/// What a Host lacks that New Agent needs (WAY-338): neither herdr nor tmux,
/// or tmux under the floor with no herdr. Read from the Host's last detected
/// presence; nil presence (never detected) is no gap, so a Host that has not
/// been asked yet behaves as before.
enum HostBackendGap: Equatable, Sendable {
    case noBackend
    /// tmux is installed but older than `HostBackendPresence.minimumTmuxVersion`.
    case tmuxTooOld(found: String)

    /// A supported herdr runtime or Zellij can launch on its own: such a Host
    /// has nothing missing, even without tmux.
    init?(presence: HostBackendPresence?) {
        guard let presence,
            presence.herdrSlot == nil,
            presence.zellij?.meetsFloor != true
        else { return nil }
        guard let version = presence.tmuxVersion else {
            self = .noBackend
            return
        }
        guard !HostBackendPresence.meetsTmuxFloor(version) else { return nil }
        self = .tmuxTooOld(found: version)
    }

    /// The panel's title, and the Console banner's first line.
    var title: String {
        switch self {
        case .noBackend: "No tmux or herdr on this Host"
        case .tmuxTooOld: "tmux on this Host is too old"
        }
    }

    func explanation(hostName: String) -> String {
        switch self {
        case .noBackend:
            "Agents run inside Herdr TUI, herdr-core or tmux. \(hostName) has none of them, so New Agent has nowhere to Launch one."
        case .tmuxTooOld(let found):
            "Waycar needs tmux \(HostBackendPresence.minimumTmuxVersion) or later. \(hostName) has tmux \(found). Herdr TUI and herdr-core need no admin rights."
        }
    }

    /// The chip under the explanation.
    var foundLabel: String {
        switch self {
        case .noBackend: "Found: nothing"
        case .tmuxTooOld(let found): "Found: tmux \(found)"
        }
    }

    /// Install tmux is offered only when the Host has no tmux: an old tmux
    /// is not replaced here (a newer one needs admin rights and the
    /// distribution's package may be just as old).
    var offersTmux: Bool { self == .noBackend }

    /// Install herdr-core is offered on both gaps, after Herdr TUI and tmux:
    /// it needs no admin rights, so a too-old tmux does not stop it.
    var offersCore: Bool { true }

    /// Default Shell's reason and when Start turns on, shown under the
    /// Agent picker.
    static let shellUnavailableReason =
        "Unavailable. It opens a tab in herdr or tmux, and this Host has neither."
    static let startGateHint =
        "Start turns on when Waycar finds herdr, or tmux \(HostBackendPresence.minimumTmuxVersion) or later."
    /// The Workspace row's value on such a Host.
    static let noWorkspaceValue = "None found"
    /// What the Console banner adds to the title: a tap opens the panel.
    static let tapToSetUp = "Tap to set up."
}

extension BackendInstallTarget {
    /// "herdr", "herdr-core" or "tmux".
    var name: String { backend.displayName }
    /// The button and the consent sheet's confirm: "Install Herdr TUI",
    /// "Install herdr-core", "Install tmux". herdr's own button carries the
    /// TUI's name, since the panel now offers two Herdr runtimes (WAY-482).
    var installTitle: String {
        switch self {
        case .herdr: "Install Herdr TUI"
        case .core, .tmux: "Install \(name)"
        }
    }
    var consentTitle: String { "\(installTitle)?" }
    var runningTitle: String { "Installing \(name)…" }
    var lookingTitle: String { "Looking for \(name)…" }
    var foundTitle: String { "\(name) Found" }

    /// The line under an Install button on the panel.
    var buttonDetail: String {
        switch self {
        case .herdr: "The terminal app. No admin rights. Adds one file in ~/.local/bin."
        case .core:
            "For the Herdr app. Alerts and Chat Mode aren’t available on it yet. "
                + "No admin rights. Adds herdr-core to ~/.local/bin."
        case .tmux: "Needs admin rights on the Host (sudo without a password) or Homebrew."
        }
    }
}

/// What the consent sheet says about one plan. Every line describes what
/// the installer does: herdr's writes one file in `~/.local/bin` (creating
/// the folder when missing), checks the download against the checksum
/// herdr.dev publishes, edits no shell file and needs no admin rights
/// (herdr.dev/install.sh, read 2026-10-27, AGENTS.md).
struct BackendInstallConsent: Equatable {
    struct Bullet: Equatable {
        let symbol: String
        let text: String
    }

    let title: String
    let command: String
    let bullets: [Bullet]
    /// Who wrote what runs, under the "On this Host now" rows.
    let sourceNote: String
    let confirmTitle: String

    static let askNote = "Waycar asks every time. Nothing runs until you tap Install."

    init(plan: BackendInstallPlan) {
        title = plan.target.consentTitle
        command = plan.command
        confirmTitle = plan.target.installTitle
        switch plan.target {
        case .herdr:
            bullets = [
                Bullet(
                    symbol: "arrow.down.circle",
                    text: "Downloads herdr’s installer and runs it on the Host over SSH."),
                Bullet(
                    symbol: "shippingbox",
                    text: "Adds one file: ~/.local/bin/herdr, and the folder if it is missing. "
                        + "The installer checks the download against herdr.dev’s checksum."),
                Bullet(
                    symbol: "checkmark.shield",
                    text: "Uses no admin rights. Edits no shell files. "
                        + "Afterwards Waycar starts herdr once, so it can connect."),
            ]
            sourceNote = "herdr’s installer from herdr.dev. Waycar is not affiliated with herdr."
        case .core:
            bullets = [
                Bullet(
                    symbol: "arrow.down.circle",
                    text: "Downloads herdr-core’s installer and runs it on the Host over SSH."),
                Bullet(
                    symbol: "shippingbox",
                    text: "Adds herdr-core to ~/.local/bin, and the folder if it is missing. "
                        + "Adds an hc shortcut there unless an hc already exists. "
                        + "The installer checks the download against Herdr’s published checksum."),
                Bullet(
                    symbol: "checkmark.shield",
                    text: "Uses no admin rights. Edits no shell files."),
                Bullet(
                    symbol: "info.circle",
                    text: "Agents show a status only if they report one to herdr-core. "
                        + "Others show Unknown. "
                        + "Alerts and Chat Mode aren’t available on herdr-core yet."),
            ]
            sourceNote =
                "herdr-core’s installer from releases.herdr.dev. Waycar is not affiliated with herdr."
        case .tmux(let manager):
            let name = manager.rawValue
            sourceNote =
                "tmux from the Host’s own package manager (\(name)). Waycar checks the version after."
            if plan.usesSudo {
                bullets = [
                    Bullet(
                        symbol: "arrow.down.circle",
                        text: "Installs tmux with \(name), using sudo without a password."),
                    Bullet(symbol: "shippingbox", text: "Changes system packages on the Host."),
                    Bullet(
                        symbol: "lock",
                        text: "If sudo asks for a password, it stops. Waycar never asks for one."),
                ]
            } else if manager.needsAdmin {
                // The account is root: the manager runs with no sudo.
                bullets = [
                    Bullet(
                        symbol: "arrow.down.circle",
                        text: "Installs tmux with \(name). This account is root, so no sudo is needed."),
                    Bullet(symbol: "shippingbox", text: "Changes system packages on the Host."),
                ]
            } else {
                bullets = [
                    Bullet(symbol: "arrow.down.circle", text: "Installs tmux with Homebrew."),
                    Bullet(symbol: "shippingbox", text: "Changes Homebrew’s packages on the Host."),
                    Bullet(symbol: "checkmark.shield", text: "Uses no admin rights."),
                ]
            }
        }
    }
}

extension BackendInstallTarget {
    /// Whose installer a failure line names: "herdr’s", "herdr-core’s".
    fileprivate var installerOwner: String { self == .core ? "herdr-core’s" : "herdr’s" }
}

/// What the sheet shows when a run ended (frames 5a to 6c and the cases the
/// mockup describes as "same layout"): one screen per `BackendInstallResult`,
/// worded from the fixed failure list, never from a log line.
struct BackendInstallOutcomeScreen: Equatable {
    enum Tone: Equatable {
        case found, failed, warning
    }

    /// The one extra action a failure offers next to Copy Command, How to
    /// install and Check Again.
    enum Extra: Equatable {
        /// 6a: after a tmux failure, "Install Herdr TUI instead".
        case installHerdrInstead
        /// 6c: tmux is too old, "Install Herdr TUI" leads the screen.
        case installHerdr
        /// 6b: "Retry" runs the same install again, after a new consent.
        case retry
    }

    let title: String
    let tone: Tone
    /// The row at the top: what was found or why it failed.
    let reason: String
    /// The footnote under the row.
    let hint: String?
    /// A second row inside the card on a found screen.
    let note: String?
    /// The installer's last line, for a failure the fixed list cannot name.
    let lastLine: String?
    /// What Copy Command copies; nil when no command could help.
    let command: String?
    let extra: Extra?
    /// What VoiceOver says when the screen appears.
    let announcement: String
}

extension BackendInstallOutcomeScreen {
    init(outcome: BackendInstallCenter.Outcome, hostName: String) {
        let plan = outcome.plan
        switch outcome.result {
        case .found(let presence):
            self = Self.found(plan: plan, presence: presence, hostName: hostName)
        case .failed(let failure):
            self = Self.failed(failure, plan: plan, hostName: hostName)
        case .hostUnreachable(let error):
            let reason = error.presentation.message
            self = Self(
                title: "Install Not Confirmed", tone: .failed, reason: reason,
                hint: "The install may have run. Check Again looks without installing.",
                note: nil, lastLine: nil, command: plan.copyCommand, extra: nil,
                announcement: "Install not confirmed. \(reason)")
        }
    }

    private static func found(
        plan: BackendInstallPlan, presence: HostBackendPresence, hostName: String
    ) -> Self {
        let target = plan.target
        let what: String
        switch target {
        case .herdr, .core:
            what = target.name
        case .tmux:
            what = presence.tmuxVersion.map { "tmux \($0)" } ?? "tmux"
        }
        // The Host Tools are what give tmux Agents their status; herdr marks
        // its own.
        var hasHostTools = false
        if case .installed = presence.waycarPlugin { hasHostTools = true }
        var note: String?
        if case .tmux = target, !hasHostTools {
            note = "Agents show Unknown until Waycar host tools are installed on this Host."
        } else if case .core = target {
            // No Host Tools offer here: the Host Tools screen has its own.
            note = "Alerts and Chat Mode aren’t available on herdr-core yet."
        }
        return Self(
            title: target.foundTitle, tone: .found, reason: "\(what) found on \(hostName)",
            hint: "Waycar checked the Host after the install.", note: note, lastLine: nil,
            command: nil, extra: nil,
            announcement: "\(target.name) found on \(hostName)."
                + (note.map { " \($0)" } ?? ""))
    }

    private static func failed(
        _ failure: BackendInstallFailure, plan: BackendInstallPlan, hostName: String
    ) -> Self {
        let target = plan.target
        let floor = HostBackendPresence.minimumTmuxVersion
        func screen(
            _ reason: String, title: String = "Install Failed", tone: Tone = .failed,
            hint: String? = nil, lastLine: String? = nil, command: String? = nil,
            showsCommand: Bool = true, extra: Extra? = nil, announcement: String? = nil
        ) -> Self {
            Self(
                title: title, tone: tone, reason: reason, hint: hint, note: nil, lastLine: lastLine,
                command: showsCommand ? (command ?? plan.copyCommand) : nil, extra: extra,
                announcement: announcement ?? "Install failed. \(reason)")
        }
        switch failure {
        case .needsAdmin:
            return screen(
                "\(target.name) needs admin rights. sudo on \(hostName) asked for a password.",
                hint: "Waycar only runs sudo without a password. It never asks for yours.",
                extra: .installHerdrInstead)
        case .cannotReachInstaller:
            return screen(
                "\(hostName) could not reach \(target == .core ? "releases.herdr.dev" : "herdr.dev").",
                hint: "Check the Host’s internet connection, then try again.", extra: .retry)
        case .tmuxTooOld(let found):
            // A newer tmux cannot be installed from here, so the command to
            // copy is herdr's.
            return screen(
                "tmux \(found) is installed, but Waycar needs \(floor) or later.",
                title: "tmux Too Old", tone: .warning,
                hint: "Installing a newer tmux needs admin rights. herdr does not.",
                command: BackendInstallPlan(target: .herdr).copyCommand, extra: .installHerdr,
                announcement: "Install finished, but tmux is still too old. Waycar needs \(floor) or later.")
        case .noCurl:
            return screen(
                "\(hostName) has no curl. \(target.installerOwner) installer needs it.",
                showsCommand: false)
        case .noTar:
            return screen(
                "\(hostName) has no tar. \(target.installerOwner) installer needs it.",
                showsCommand: false)
        case .noPackageManager:
            return screen(
                "Waycar did not find a package manager it can use on \(hostName).",
                showsCommand: false, extra: .installHerdrInstead)
        case .unsupportedSystem:
            return screen(
                "\(target == .core ? "herdr-core" : "herdr") does not support the system on \(hostName).",
                showsCommand: false)
        case .other(let line):
            return screen(
                "The install did not finish on \(hostName).", lastLine: line, extra: .retry)
        }
    }
}
