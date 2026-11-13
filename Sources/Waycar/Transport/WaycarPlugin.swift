import Foundation

/// What backend detection found of the Waycar plugin (Host Tools) on a Host
/// (#209), read from the same exec as its backends.
enum WaycarPluginDetection: Sendable, Equatable, Codable {
    /// Neither an enabled `waycar` herdr plugin nor the Host Tools.
    case notInstalled
    case installed(WaycarPluginInstall)
}

/// An installed Waycar plugin: its version, how the installer set it up,
/// and where it lives.
struct WaycarPluginInstall: Sendable, Equatable, Codable {
    /// How install.sh set Waycar up, which its rerun keeps.
    enum Mode: String, Sendable, Codable {
        /// Enabled in herdr's plugin list, or Host Tools beside a herdr whose
        /// list could not be read (install.sh picks herdr whenever `herdr`
        /// is on the PATH).
        case herdr
        /// The Host Tools CLI only (`install.sh --tmux`, or no herdr).
        case tmux
        /// The Host Tools CLI only, on a Host whose backend is herdr-core:
        /// no herdr and no usable tmux, so `install.sh` picks this shape
        /// itself and needs no flag (it prints no `for tmux`).
        case core
    }

    /// The plugin's `herdr-plugin.toml` version ("1.4.0"); nil when it is
    /// installed but its version could not be read.
    var version: String?
    var mode: Mode
    /// The plugin root: the `plugin_root` herdr reports for its `waycar`
    /// entry (never a legacy-id entry, which install.sh does not replace), or
    /// the Host Tools root the CLI runs from. Nil when neither is known; a
    /// presence cached before roots were probed decodes without one.
    var root: String?

    init(version: String?, mode: Mode, root: String? = nil) {
        self.version = version
        self.mode = mode
        self.root = root
    }
}

/// A Host's plugin measured against what this build needs
/// (`WaycarPluginRequirement.minimumVersion`).
enum WaycarPluginStatus: Sendable, Equatable {
    /// Not probed yet, or installed with a version that cannot be read.
    case unknown
    case notInstalled
    case current(version: String)
    case outdated(installed: String, required: String)
}

/// The plugin version this build relies on, and how a Host gets it.
enum WaycarPluginRequirement {
    /// The oldest plugin this build relies on. Raise it with any app change
    /// that needs newer plugin behavior; `scripts/check-plugin-version.sh`
    /// guards it ≤ the version in `plugin/herdr-plugin.toml`, so the
    /// installer can always satisfy it.
    static let minimumVersion = "1.4.0"
    /// The first plugin that runs as native tools, with no Node on the Host
    /// (the Rust Host Tools, WAY-338). A Host on an older, Node-era plugin is
    /// *prompted* to update (`nativeToolsStatus(of:)`), never gated: it keeps
    /// working with this build, so chat, push and the rest stay on at any
    /// version `minimumVersion` allows. Do not raise `minimumVersion` for it.
    /// `scripts/check-plugin-version.sh` guards it like `minimumVersion`; raise
    /// it only once waycar.dev serves a plugin at least this new, or the update
    /// would reinstall the Node package and prompt again.
    static let nativeToolsMinimumVersion = "2.0.0"
    /// The first plugin with a herdr-core mode (hooks inside core terminals,
    /// `hc:` notifications, Live Activity rows, summaries). Read only for a
    /// Host whose backends include herdr-core (``status(of:backends:)``): a
    /// Host without core keeps working on any plugin `minimumVersion` allows,
    /// so this never raises the bar for every Host.
    /// `scripts/check-plugin-version.sh` guards it like `minimumVersion`.
    static let coreMinimumVersion = "2.2.0"
    /// The first hooks/document format for Zellij, scoped only to Zellij Hosts.
    static let zellijMinimumVersion = "2.6.0"
    /// The plugin version this build ships beside: `plugin/herdr-plugin.toml`'s,
    /// which `scripts/check-plugin-version.sh` keeps it equal to. A Host on an
    /// older plugin that still meets its minimum is *offered* this version
    /// (``availableUpdate(for:)``), never gated or warned about. Bump it with
    /// every plugin version bump; never raise a minimum for it.
    static let currentVersion = "2.6.1"
    /// The official installer, rebuilt from main on every plugin change.
    static let installScriptURL = "https://waycar.dev/install.sh"
    /// The one-line install and update command, as the docs print it.
    static let installCommand = "curl -fsSL \(installScriptURL) | sh"

    /// `detection` against `nativeToolsMinimumVersion`, read like ``status(of:)``:
    /// only a version known to be older says the Host is still on the Node
    /// tools. A prompt, never a gate: no feature reads this to turn off.
    static func nativeToolsStatus(of detection: WaycarPluginDetection?) -> WaycarPluginStatus {
        status(of: detection, minimum: nativeToolsMinimumVersion)
    }

    /// `detection` against `minimumVersion`. Nil (never probed) and an
    /// installed plugin whose version is missing or unparseable are
    /// `.unknown`, never outdated: only a version known to be older prompts.
    static func status(of detection: WaycarPluginDetection?) -> WaycarPluginStatus {
        status(of: detection, minimum: minimumVersion)
    }

    /// ``status(of:)`` for a Host with these backends: the herdr-core mode
    /// needs ``coreMinimumVersion``, so a Host whose backends include core is
    /// measured against that, and every other Host against `minimumVersion`.
    static func status(
        of detection: WaycarPluginDetection?, backends: [HostBackend]
    ) -> WaycarPluginStatus {
        status(of: detection, minimum: minimumVersion(for: backends))
    }

    /// The newer plugin the installer would put on a Host: `currentVersion`
    /// when `detection`'s version is known and older, nil when it is current
    /// or newer, unreadable, missing or never probed. An offer, never a gate:
    /// read it only once ``status(of:backends:)`` says the Host meets its
    /// minimum, and turn nothing off with it.
    static func availableUpdate(for detection: WaycarPluginDetection?) -> String? {
        guard case .installed(let install) = detection, let version = install.version,
            compare(version, currentVersion) == .orderedAscending
        else { return nil }
        return currentVersion
    }

    /// The oldest plugin a Host with `backends` needs.
    static func minimumVersion(for backends: [HostBackend]) -> String {
        if backends.contains(.zellij) { return zellijMinimumVersion }
        return backends.contains(.core) ? coreMinimumVersion : minimumVersion
    }

    private static func status(
        of detection: WaycarPluginDetection?, minimum: String
    ) -> WaycarPluginStatus {
        switch detection {
        case nil:
            return .unknown
        case .notInstalled:
            return .notInstalled
        case .installed(let install):
            guard let version = install.version, let order = compare(version, minimum)
            else { return .unknown }
            return order == .orderedAscending
                ? .outdated(installed: version, required: minimum)
                : .current(version: version)
        }
    }

    /// Lenient numeric `major.minor.patch` order: a missing component is 0
    /// ("1.4" == "1.4.0"), anything after a component's leading digits is
    /// ignored ("1.4.0-beta" == "1.4.0"), and components past the third do
    /// not count. Nil when either side's first component has no leading
    /// digit ("v1.4.0", "unknown").
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let left = components(lhs), let right = components(rhs) else { return nil }
        for (l, r) in zip(left, right) where l != r {
            return l < r ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    /// `[major, minor, patch]`; nil when the first component has no leading
    /// digit or a component's digits overflow `Int`.
    private static func components(_ version: String) -> [Int]? {
        var numbers: [Int] = []
        let parts = version.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
        for part in parts.prefix(3) {
            // ASCII only: `isNumber` also takes other scripts' digits.
            let digits = part.prefix(while: { $0.isASCII && $0.isNumber })
            if digits.isEmpty {
                guard !numbers.isEmpty else { return nil }
                numbers.append(0)
            } else {
                guard let number = Int(digits) else { return nil }
                numbers.append(number)
            }
        }
        while numbers.count < 3 { numbers.append(0) }
        return numbers
    }
}

/// Where a Host's Waycar Host Tools live, resolved in shell as install.sh
/// leaves them. Both the backend detection exec (`HostBackendDetection`)
/// and the Host Tools probe (`HostToolsService.hostToolsProbeCommand`) run
/// this one snippet, so they never disagree about which install counts.
enum WaycarHostToolsShell {
    /// POSIX sh that sets `cli` to the Host Tools' CLI and `root` to the
    /// plugin root it runs from, both empty when not installed.
    /// `~/.local/bin/waycar` counts only as install.sh leaves it: a symlink
    /// (followed at most 40 hops, like `bin/waycar`) into a root whose
    /// `herdr-plugin.toml` says `id = "waycar"` (the check install.sh itself
    /// makes); any other file there is someone else's, and the CLI is the
    /// install dir's `bin/waycar`
    /// (`${WAYCAR_PLUGIN_DIR:-$HOME/.local/share/waycar/plugin}`), as
    /// install.sh then says. Defines `root_of` and overwrites `s`, `n`, `l`,
    /// `r` and `link`; it holds no single quote, so it embeds in a
    /// single-quoted `/bin/sh -c` script.
    static let resolveCLIAndRoot: String = {
        let tools = "${WAYCAR_PLUGIN_DIR:-$HOME/.local/share/waycar/plugin}/bin/waycar"
        return "root_of() { s=$1; n=0; "
            + "while [ -L \"$s\" ] && [ $n -lt 40 ]; do l=$(readlink \"$s\"); "
            + "case \"$l\" in /*) s=$l;; *) s=$(dirname \"$s\")/$l;; esac; n=$((n + 1)); done; "
            + "(cd \"$(dirname \"$s\")/..\" 2>/dev/null && pwd -P); }; "
            + "cli=; root=; link=\"$HOME/.local/bin/waycar\"; "
            + "if [ -L \"$link\" ] && [ -x \"$link\" ]; then r=$(root_of \"$link\"); "
            + "if [ -n \"$r\" ] && grep -qx \"id = \\\"waycar\\\"\" \"$r/herdr-plugin.toml\" 2>/dev/null; "
            + "then cli=$link; root=$r; fi; fi; "
            + "if [ -z \"$cli\" ] && [ -x \"\(tools)\" ]; then cli=\"\(tools)\"; root=$(root_of \"$cli\"); fi; "
    }()
}
