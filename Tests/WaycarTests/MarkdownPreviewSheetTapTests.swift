import Foundation
@testable import GhosttyTerminal
import SwiftUI
import Testing
import UIKit

@testable import Waycar

/// A tap on a bare `README.md` in a hosted Agent terminal opens the Markdown
/// File Preview sheet (#147): the real `AgentTerminalView` over a scripted
/// Host, the real tap dispatch, the presented sheet.
@MainActor
@Suite("MarkdownPreviewSheetTapTests", .serialized)
struct MarkdownPreviewSheetTapTests {
    nonisolated private static let rawPreferenceKey = "recent-markdown-preview-shows-raw"

    nonisolated private static let readmeMarkdown = """
        # Title

        - first
        - second

        | Left | Right |
        | :--- | ----: |
        | a | 1 |
        """

    @Test func tappingBareReadmeOpensTheRenderedPreview() async throws {
        try await Self.withRawPreference(false) {
            try await Self.withTappedReadme { harness, window in
                #expect(Self.previewElement(id: "markdown-preview.rendered", in: window) != nil)
                #expect(Self.previewElement(id: "markdown-preview.raw", in: window) == nil)
                let reads = await harness.transport.previewFileReads.map(\.path)
                #expect(reads == ["/work/w1/README.md"])
            }
        }
    }

    @Test func rememberedRawPreferenceOpensTheRawPreview() async throws {
        try await Self.withRawPreference(true) {
            try await Self.withTappedReadme { _, window in
                #expect(Self.previewElement(id: "markdown-preview.raw", in: window) != nil)
            }
        }
    }

    // MARK: - Harness

    /// The pieces of one hosted Agent terminal the tests reach into.
    private struct PreviewTapHarness {
        let transport: ScriptedTransport
    }

    /// Sets the device-wide raw preference for `body`, then restores it.
    private static func withRawPreference(
        _ showsRaw: Bool,
        _ body: () async throws -> Void
    ) async throws {
        let standard = UserDefaults.standard
        let prior = standard.object(forKey: rawPreferenceKey)
        standard.set(showsRaw, forKey: rawPreferenceKey)
        defer {
            if let prior {
                standard.set(prior, forKey: rawPreferenceKey)
            } else {
                standard.removeObject(forKey: rawPreferenceKey)
            }
        }
        try await body()
    }

    /// Hosts a live Agent terminal (cwd `/work/w1`), draws `README.md`, taps
    /// it through `handleTap(at:)`, requires the sheet, runs `body`, then
    /// dismisses the sheet, leaves the Attach and hides the window.
    private static func withTappedReadme(
        _ body: (PreviewTapHarness, UIWindow) async throws -> Void
    ) async throws {
        let suiteName = "md-preview-tap-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        await transport.setPreviewFileResponder { path, _ in
            guard path.hasSuffix("README.md") else { throw RemoteFilePreviewError.missing }
            return Data(readmeMarkdown.utf8)
        }

        let host = Host.fixture()
        let console = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            pins: PinnedAgentsStore(defaults: defaults),
            unread: UnreadAgentsStore(defaults: defaults),
            chatMode: ChatModeStore(defaults: defaults)
        ) { _, _, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
        }
        console.setHosts([host])
        defer { console.setHosts([]) }
        await console.resume()
        try #require(await previewEventually {
            console.agents.count == 1 && !console.hostsAwaitingSnapshot.contains(host.id)
        }, "the scripted Host should connect and list its Agent")
        let agent = try #require(console.agents.first)

        let probe = AgentTerminalInteractionProbe()
        let composer = AgentComposerStore(
            target: "w1:p1",
            initialStatus: .idle,
            agentNotReadyRetryDelay: .milliseconds(5),
            agentNotReadyRetryBudget: .milliseconds(40)
        ) { params in
            try await transport.promptAgent(params)
        }
        let owner = AgentAttachStore(
            target: .agentPane("w1:p1"),
            transportGeneration: 1,
            recordsNetworkTelemetry: true,
            isOnStage: { true },
            runTerminal: { request, handler in
                let session = try await transport.attachTerminal(request)
                try await handler.runEndingSession(session)
            },
            stageImage: { _, _ in throw TransportError.cancelled },
            stageFile: { _, _ in throw TransportError.cancelled },
            composer: composer,
            closePane: {})
        owner.viewDidResize(cols: 80, rows: 24)
        try #require(await previewEventually {
            await transport.attachRequests.count == 1
        })
        #expect(await transport.emitAttachOutput(Data("live".utf8)))

        let settings = TerminalSettings(
            themes: TerminalThemeSettings(defaults: defaults),
            zoom: TerminalZoomSettings(defaults: defaults),
            fonts: TerminalFontSettings(defaults: defaults),
            snippets: SnippetStore(defaults: defaults),
            toolbars: AgentToolbarLayoutStore(defaults: defaults, idiom: .phone))
        let controller = UIHostingController(
            rootView: AgentTerminalView(
                agent: agent,
                console: console,
                terminal: settings,
                hosts: [],
                activity: AppActivityCoordinator(),
                keyboardHandoff: TerminalKeyboardHandoff(),
                keyboardInset: TerminalKeyboardInset(),
                isOnStage: { true },
                onSwitch: { _ in },
                onClosed: {},
                composer: composer,
                attachStore: owner,
                interactionProbe: probe,
                clipboard: TerminalClipboard(string: { nil }, hasStrings: { false }),
                dictationSender: nil))
        let screenBounds = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds
        let frame = screenBounds.map { CGRect(origin: .zero, size: $0.size) }
            ?? CGRect(x: 0, y: 0, width: 402, height: 874)
        let window = try await makeTestWindow(frame: frame, rootViewController: controller)
        defer { window.isHidden = true }

        do {
            controller.view.layoutIfNeeded()
            try #require(await previewEventually {
                owner.terminalStatus == AttachTerminalStore.Status.live && probe.isConnected
            }, "the Attach should go live")

            let terminal = try #require(
                previewFirstView(in: controller.view) { $0 is WaycarTerminalView } as? WaycarTerminalView)

            // Row 0 stayed empty in the CI failures at this wait (WAY-505). The
            // cause is not reproduced here; by analogy with the focus wait in
            // AgentToolbarDispatchTests, let the window's first updates run
            // before drawing. The path goes on row 0; the caret parks on the
            // bottom row so the tap is not on the input row (a tap there only
            // raises the keyboard).
            try await DisplayTickMonitor.shared.waitForTicks(20)
            #expect(await transport.emitAttachOutput(
                Data("\u{1B}[2J\u{1B}[HREADME.md\r\n\u{1B}[999;1H".utf8)))

            let geometry = try #require(terminal.touchCellGeometry())
            let tapPoint = geometry.point(in: TerminalCellPosition(column: 3, row: 0), x: 0.5, y: 0.5)
            var attachRequests = -1
            try #require(await previewEventually {
                attachRequests = await transport.attachRequests.count
                if case .openLink? = terminal.tapLink(at: tapPoint) { return true }
                return false
            }, """
                README.md should be drawn and read as a previewable link: \
                tap read \(String(describing: terminal.tapLink(at: tapPoint))), \
                attach requests \(attachRequests), \
                grid then \(geometry.columns)x\(geometry.rows) now \
                \(terminal.touchCellGeometry().map { "\($0.columns)x\($0.rows)" } ?? "none") \
                (same \(terminal.touchCellGeometry() == geometry)), \
                row 0 \(String(describing: terminal.surface?.readViewportText(from: (0, 0), to: (79, 0)))), \
                terminal in window \(terminal.window != nil) bounds \(terminal.bounds.size) \
                preview wired \(terminal.onPreviewFile != nil), \
                \(UIWaitDiagnostics.hierarchy(of: controller.view)); \
                \(UIWaitDiagnostics.window(window)); \(UIWaitDiagnostics.machine())
                """)

            terminal.handleTap(at: tapPoint)

            try #require(await previewEventually {
                previewPresented(in: window) != nil
                    && previewElement(id: "markdown-preview.sheet", in: window) != nil
            }, "markdown-preview.sheet should be presented after the tap")
            // Parse and first render are asynchronous; the body asserts which mode rendered.
            _ = try await previewEventually {
                previewElement(id: "markdown-preview.rendered", in: window) != nil
                    || previewElement(id: "markdown-preview.raw", in: window) != nil
            }

            try await body(PreviewTapHarness(transport: transport), window)
        } catch {
            await dismissPreview(in: window)
            await owner.leave().value
            throw error
        }
        await dismissPreview(in: window)
        await owner.leave().value
    }

    /// Dismisses whatever is presented and waits until nothing is.
    private static func dismissPreview(in window: UIWindow) async {
        guard let top = previewPresented(in: window) else { return }
        top.presentingViewController?.dismiss(animated: false)
        _ = try? await previewEventually(timeout: .seconds(3)) {
            previewPresented(in: window) == nil
        }
    }

    // MARK: - Helpers

    private static func previewEventually(
        timeout: Duration = .waitCeiling,
        line: UInt = #line,
        _ condition: @escaping () async -> Bool
    ) async throws -> Bool {
        let start = ContinuousClock.now
        let deadline = start + timeout
        while ContinuousClock.now < deadline {
            if await condition() {
                UIWaitDiagnostics.noteSlowWait(
                    "MarkdownPreviewSheetTapTests.swift:\(line)", took: ContinuousClock.now - start,
                    budget: timeout)
                return true
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    private static func previewFirstView(in root: UIView, where matches: (UIView) -> Bool) -> UIView? {
        if matches(root) { return root }
        for subview in root.subviews {
            if let match = previewFirstView(in: subview, where: matches) { return match }
        }
        return nil
    }

    /// The topmost controller presented anywhere under the window's root.
    private static func previewPresented(in window: UIWindow) -> UIViewController? {
        var queue = window.rootViewController.map { [$0] } ?? []
        while !queue.isEmpty {
            let controller = queue.removeFirst()
            if let presented = controller.presentedViewController {
                var deepest = presented
                while let next = deepest.presentedViewController { deepest = next }
                return deepest
            }
            queue.append(contentsOf: controller.children)
        }
        return nil
    }

    private static func previewIdentifier(of object: NSObject) -> String? {
        if let identified = object as? UIAccessibilityIdentification {
            return identified.accessibilityIdentifier
        }
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    /// The first view or accessibility element carrying `id`: SwiftUI
    /// identifiers surface only in the accessibility tree.
    private static func previewElement(id: String, in window: UIWindow) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        var stack: [NSObject] = [window]
        while let object = stack.popLast() {
            guard visited.insert(ObjectIdentifier(object)).inserted, visited.count < 40_000 else {
                continue
            }
            if previewIdentifier(of: object) == id { return object }
            if let view = object as? UIView {
                stack.append(contentsOf: view.subviews.reversed())
            }
            if let elements = object.accessibilityElements {
                stack.append(contentsOf: elements.compactMap { $0 as? NSObject }.reversed())
            } else {
                let count = object.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for index in (0..<count).reversed() {
                        if let element = object.accessibilityElement(at: index) as? NSObject {
                            stack.append(element)
                        }
                    }
                }
            }
        }
        return nil
    }
}
