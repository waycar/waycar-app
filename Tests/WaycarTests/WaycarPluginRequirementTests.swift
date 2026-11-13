import Foundation
import Testing

@testable import Waycar

@Suite("Waycar plugin requirement")
struct WaycarPluginRequirementTests {
    @Test(arguments: [
        ("1.3.9", "1.4.0", .orderedAscending),
        ("1.4", "1.4.0", .orderedSame),
        ("1.4.0", "1.4", .orderedSame),
        ("1.10.0", "1.4.0", .orderedDescending),
        ("2.0.0", "1.4.0", .orderedDescending),
        ("1.4.0-beta", "1.4.0", .orderedSame),
        ("1.4.0.9", "1.4.0", .orderedSame),
        (" 1.4.1\n", "1.4.0", .orderedDescending),
        ("1", "1.0.0", .orderedSame),
    ] as [(String, String, ComparisonResult)])
    func versionsCompareNumericallyByMajorMinorPatch(
        lhs: String, rhs: String, expected: ComparisonResult
    ) {
        #expect(WaycarPluginRequirement.compare(lhs, rhs) == expected)
    }

    @Test(arguments: ["", "v1.4.0", "unknown", ".4.0"])
    func aVersionWithoutALeadingDigitDoesNotCompare(version: String) {
        #expect(WaycarPluginRequirement.compare(version, "1.4.0") == nil)
        #expect(WaycarPluginRequirement.compare("1.4.0", version) == nil)
    }

    private func installed(_ version: String?, mode: WaycarPluginInstall.Mode = .herdr)
        -> WaycarPluginDetection
    {
        .installed(WaycarPluginInstall(version: version, mode: mode))
    }

    @Test func statusMeasuresTheInstalledVersionAgainstTheMinimum() {
        let minimum = WaycarPluginRequirement.minimumVersion
        #expect(
            WaycarPluginRequirement.status(of: installed("1.3.1"))
                == .outdated(installed: "1.3.1", required: minimum))
        #expect(
            WaycarPluginRequirement.status(of: installed("1.3.9", mode: .tmux))
                == .outdated(installed: "1.3.9", required: minimum))
        #expect(WaycarPluginRequirement.status(of: installed(minimum)) == .current(version: minimum))
        #expect(WaycarPluginRequirement.status(of: installed("1.10.0")) == .current(version: "1.10.0"))
        #expect(WaycarPluginRequirement.status(of: installed("2.0.0")) == .current(version: "2.0.0"))
    }

    /// Only a version known to be older prompts: never probed, a missing
    /// version and an unparseable one are all unknown.
    @Test func statusIsUnknownUnlessTheVersionIsReadable() {
        #expect(WaycarPluginRequirement.status(of: nil) == .unknown)
        #expect(WaycarPluginRequirement.status(of: installed(nil)) == .unknown)
        #expect(WaycarPluginRequirement.status(of: installed("garbage")) == .unknown)
        #expect(WaycarPluginRequirement.status(of: .notInstalled) == .notInstalled)
    }

    // MARK: Newest plugin

    /// Host detail's three states, in order: below the Host's minimum needs
    /// an update; at or above it but older than the plugin this build ships
    /// beside is offered that version; the current one or newer is up to date.
    /// The offer never changes the status.
    @Test func aHostAtItsMinimumIsOfferedTheCurrentPluginWithoutAWarning() {
        let current = WaycarPluginRequirement.currentVersion
        let tmux: [HostBackend] = [.tmux]

        let old = installed("1.3.1", mode: .tmux)
        #expect(
            WaycarPluginRequirement.status(of: old, backends: tmux)
                == .outdated(installed: "1.3.1", required: WaycarPluginRequirement.minimumVersion))

        // The reported case: a tmux Host on 2.0.0 read "up to date".
        let behind = installed("2.0.0", mode: .tmux)
        #expect(WaycarPluginRequirement.status(of: behind, backends: tmux) == .current(version: "2.0.0"))
        #expect(WaycarPluginRequirement.availableUpdate(for: behind) == current)

        for version in [current, "\(current)-beta", "99.0.0"] {
            let fresh = installed(version, mode: .tmux)
            #expect(WaycarPluginRequirement.status(of: fresh, backends: tmux) == .current(version: version))
            #expect(WaycarPluginRequirement.availableUpdate(for: fresh) == nil, "\(version)")
        }
    }

    /// A core Host on 2.0.0 is below the core mode's minimum: it needs the
    /// update, whatever the newer plugin.
    @Test func aCoreHostBelowTheCoreMinimumNeedsTheUpdate() {
        let detection = installed("2.0.0", mode: .core)
        for backends in [[.core], [.herdr, .core], [.core, .tmux]] as [[HostBackend]] {
            #expect(
                WaycarPluginRequirement.status(of: detection, backends: backends)
                    == .outdated(installed: "2.0.0", required: WaycarPluginRequirement.coreMinimumVersion))
        }
    }

    /// Nothing is offered unless the version is known.
    @Test func noUpdateIsOfferedUnlessTheVersionIsReadable() {
        #expect(WaycarPluginRequirement.availableUpdate(for: nil) == nil)
        #expect(WaycarPluginRequirement.availableUpdate(for: .notInstalled) == nil)
        #expect(WaycarPluginRequirement.availableUpdate(for: installed(nil)) == nil)
        #expect(WaycarPluginRequirement.availableUpdate(for: installed("garbage")) == nil)
    }

    // MARK: Native tools (WAY-451)

    /// 1.x is the Node plugin and 2.0.0 the first native one: only a version
    /// known to be below 2.0.0 prompts. A pre-release of 2.0.0 is already
    /// native (the comparison ignores the suffix, as for every minimum).
    @Test(arguments: [
        ("1.7.0", true), ("1.8.0", true), ("1.99.0", true), ("1.3.1", true),
        ("2.0.0", false), ("2.0.0-beta", false), ("2.0.1", false), ("2.1.0", false),
        ("10.0.0", false),
    ] as [(String, Bool)])
    func onlyAPluginBelowTheNativeMinimumPrompts(version: String, prompts: Bool) {
        let required = WaycarPluginRequirement.nativeToolsMinimumVersion
        #expect(required == "2.0.0")
        #expect(
            WaycarPluginRequirement.nativeToolsStatus(of: installed(version))
                == (prompts
                    ? .outdated(installed: version, required: required)
                    : .current(version: version)))
    }

    /// No Host is prompted unless its version is known: not probed, none, and
    /// an unreadable one are unknown, and a missing plugin gets the Install
    /// offer instead.
    @Test func nativeToolsStatusIsUnknownUnlessTheVersionIsReadable() {
        #expect(WaycarPluginRequirement.nativeToolsStatus(of: nil) == .unknown)
        #expect(WaycarPluginRequirement.nativeToolsStatus(of: installed(nil)) == .unknown)
        for garbage in ["garbage", "", "v1.7.0", "unknown"] {
            #expect(WaycarPluginRequirement.nativeToolsStatus(of: installed(garbage)) == .unknown)
        }
        #expect(WaycarPluginRequirement.nativeToolsStatus(of: .notInstalled) == .notInstalled)
    }

    /// The prompt is not a gate: a Node-era Host keeps every feature the other
    /// minimums allow. This build's own stays below the native one and reads
    /// such a Host as current.
    @Test(arguments: ["1.7.0", "1.8.0", "1.99.0"])
    func aNodeEraHostStaysCurrentForEveryOtherMinimum(version: String) {
        let detection = installed(version)
        #expect(WaycarPluginRequirement.status(of: detection) == .current(version: version))
        let native = WaycarPluginRequirement.nativeToolsMinimumVersion
        #expect(
            WaycarPluginRequirement.compare(WaycarPluginRequirement.minimumVersion, native)
                == .orderedAscending)
    }
}
