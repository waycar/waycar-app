import Testing
import UIKit

@MainActor
func makeTestWindow(
    frame: CGRect,
    rootViewController: UIViewController,
    timeout: Duration = .waitCeiling
) async throws -> UIWindow {
    let deadline = ContinuousClock.now + timeout
    var windowScene: UIWindowScene?
    while windowScene == nil, ContinuousClock.now < deadline {
        windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        if windowScene == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    let window = UIWindow(
        windowScene: try #require(
            windowScene,
            "the test host should connect a window scene"))
    window.frame = frame
    window.rootViewController = rootViewController
    window.makeKeyAndVisible()
    DisplayTickMonitor.shared.restart()
    return window
}

/// Counts display link ticks from the moment a test window appears, so a wait
/// that ran out of time can say whether the display was ticking. SwiftUI's
/// update cycle and the terminal's renderer both run on the display link.
@MainActor
final class DisplayTickMonitor: NSObject {
    static let shared = DisplayTickMonitor()

    private var link: CADisplayLink?
    /// Never reset: another suite's `waitForTicks` may hold a target taken from
    /// this count, so a restart only moves the marker the summary counts from.
    private var ticks = 0
    private var ticksAtRestart = 0
    private var since = ContinuousClock.now
    private var lastTick = ContinuousClock.now
    private var longestGap = Duration.zero

    func restart() {
        let now = ContinuousClock.now
        ticksAtRestart = ticks
        since = now
        lastTick = now
        longestGap = .zero
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        let now = ContinuousClock.now
        longestGap = max(longestGap, now - lastTick)
        lastTick = now
        ticks += 1
    }

    /// Lets the display link run `count` more frames, so updates already
    /// queued when a test acts have run first.
    func waitForTicks(_ count: Int) async throws {
        let target = ticks + count
        try await waitUntil("the display link should advance") { self.ticks >= target }
    }

    var summary: String {
        let now = ContinuousClock.now
        return "display link \(ticks - ticksAtRestart) ticks in \(now - since), longest gap \(longestGap), "
            + "last tick \(now - lastTick) ago"
    }
}

/// What a UI wait that ran out of time says about the machine and the test
/// window. Evaluated only on failure (a `#require` comment is lazy), so a
/// flake on the shared CI Mac explains itself in the job log: whether the Mac
/// was oversubscribed, and whether the window was key and active.
@MainActor
enum UIWaitDiagnostics {
    /// The Mac's load averages against its cores, and the thermal state.
    static func machine() -> String {
        var load = [Double](repeating: 0, count: 3)
        let loadText = getloadavg(&load, 3) == 3
            ? String(format: "%.1f/%.1f/%.1f", load[0], load[1], load[2])
            : "unavailable"
        let info = ProcessInfo.processInfo
        return "load \(loadText) on \(info.activeProcessorCount) cores, "
            + "thermal \(info.thermalState.rawValue)"
    }

    /// App and scene activation, and which window is key.
    static func window(_ window: UIWindow) -> String {
        let scene = window.windowScene
        let keyWindows = (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene })
            .flatMap(\.windows).filter(\.isKeyWindow)
        return "app state \(UIApplication.shared.applicationState.rawValue), "
            + "scene \(scene.map { String($0.activationState.rawValue) } ?? "none"), "
            + "test window key \(window.isKeyWindow) hidden \(window.isHidden), "
            + "\(keyWindows.count) key window(s), "
            + "\(DisplayTickMonitor.shared.summary), "
            + "first responder \(FirstResponderFinder.current().map { String(describing: type(of: $0)) } ?? "none")"
    }

    /// A text view's focus state.
    static func focus(of view: UIView?) -> String {
        guard let view else { return "view missing" }
        return "in window \(view.window != nil), hidden \(view.isHidden), alpha \(view.alpha), "
            + "can focus \(view.canBecomeFirstResponder), focused \(view.isFirstResponder)"
    }

    /// What a focus or render wait sees under `root`: how many views there
    /// are, which classes, and every text view with its label.
    static func hierarchy(of root: UIView) -> String {
        var queue = [root]
        var classes: [String: Int] = [:]
        var textViews: [String] = []
        while !queue.isEmpty {
            let view = queue.removeFirst()
            classes[String(describing: type(of: view)), default: 0] += 1
            if view is UITextView {
                textViews.append("\(type(of: view)) label \(view.accessibilityLabel ?? "nil")")
            }
            queue.append(contentsOf: view.subviews)
        }
        let counts = classes.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }
        return "\(classes.values.reduce(0, +)) views [\(counts.joined(separator: ", "))], "
            + "text views [\(textViews.joined(separator: "; "))]"
    }

    /// A wait that passed after using more than a second of its budget: the
    /// near misses a green run hides. Printed with the machine's load, so the
    /// log shows how close a wait came and whether the Mac was busy.
    static func noteSlowWait(_ site: String, took: Duration, budget: Duration) {
        guard took > .seconds(1) else { return }
        print("[slow wait] \(site) took \(took) of a \(budget) budget; \(machine())")
    }
}

/// Finds the first responder the way UIKit's own responder chain does: an
/// action sent to no target reaches it.
@MainActor
private enum FirstResponderFinder {
    private static weak var found: UIResponder?

    static func current() -> UIResponder? {
        found = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.waycarTestCaptureFirstResponder), to: nil, from: nil, for: nil)
        return found
    }

    fileprivate static func capture(_ responder: UIResponder) { found = responder }
}

extension UIResponder {
    @objc fileprivate func waycarTestCaptureFirstResponder() {
        MainActor.assumeIsolated { FirstResponderFinder.capture(self) }
    }
}
