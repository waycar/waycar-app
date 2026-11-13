import Foundation
@testable import GhosttyTerminal
import QuickLook
import SwiftUI
import Testing
import UIKit

@testable import Waycar

/// A file picked in Files & Links previews over the list, which stays up:
/// the real `AgentTerminalView` over a scripted Host, its strip opening the
/// list, a row opening the rendered Markdown sheet or the Quick Look
/// gallery over it.
@MainActor
@Suite("FilesAndLinksPreviewTests", .serialized)
struct FilesAndLinksPreviewTests {
    nonisolated private static let readmeMarkdown = """
        # Title

        Body text.
        """

    @Test func closingAPreviewOpenedFromTheListLandsBackOnIt() async throws {
        try await Self.withOpenList { harness, window in
            try await Self.activate("terminal.file-list.row", in: window)

            try #require(await Self.eventually {
                let chain = Self.presentedChain(in: window)
                return chain.count == 2
                    && Self.element(id: "markdown-preview.sheet", in: chain[1].view) != nil
                    && Self.showsList(chain[0])
            }, "the Markdown sheet should present over the list, the list still up under it")
            #expect(await harness.transport.previewFileReads.map(\.path) == ["/work/w1/README.md"])

            try await Self.activate("markdown-preview.done", in: window)

            try #require(await Self.eventually {
                let chain = Self.presentedChain(in: window)
                return chain.count == 1 && Self.showsList(chain[0])
            }, "closing the preview should land back on the list")
            // And it stays: nothing closes it after the preview has gone.
            try await Task.sleep(for: .milliseconds(500))
            let chain = Self.presentedChain(in: window)
            #expect(chain.count == 1 && chain.first.map(Self.showsList) == true)
        }
    }

    @Test func closingTheListCancelsAPreviewStillLoading() async throws {
        let gate = ScriptedTransportCallGate()
        try await Self.withOpenList(readGate: gate) { harness, window in
            try await Self.activate("terminal.file-list.row", in: window)
            try #require(await Self.eventually { await gate.entryCount >= 1 }, "the row should start the read")
            try #require(await Self.eventually {
                Self.presentedChain(in: window).first.map {
                    Self.element(id: "terminal.file-preview.loading", in: $0.view) != nil
                } == true
            }, "the list should show the loading badge over its rows")

            try await Self.activate("terminal.file-list.done", in: window)
            try #require(await Self.eventually {
                Self.presentedChain(in: window).isEmpty
            }, "Done should close the list")
            // The terminal's own badge shows whenever a preview loads with the
            // list down: none means the load was stopped as the list closed.
            #expect(Self.element(id: "terminal.file-preview.loading", in: window) == nil)

            // The read answering late presents nothing.
            await gate.open()
            try await Task.sleep(for: .milliseconds(500))
            #expect(Self.presentedChain(in: window).isEmpty)
            #expect(Self.element(id: "markdown-preview.sheet", in: window) == nil)
            #expect(Self.element(id: "terminal.file-preview.loading", in: window) == nil)
            #expect(await harness.transport.previewFileReads.map(\.path) == ["/work/w1/README.md"])
        }
    }

    @Test func anImageRowOpensTheGalleryAtItOverTheListsImagesAndPDFs() async throws {
        let files = [
            "shots/a.png": Self.png(.red), "shots/b.png": Self.png(.blue),
            "doc.pdf": Self.pdf(), "README.md": Data(Self.readmeMarkdown.utf8),
        ]
        try await Self.withOpenList(
            printing: "shots/a.png shots/b.png doc.pdf README.md",
            files: files,
            stripListing: ["1 Markdown file", "1 PDF", "2 images"]
        ) { harness, window in
            try await Self.activate("terminal.file-list.row", labelPrefix: "b.png", in: window)

            try #require(await Self.eventually {
                Self.quickLook(in: window) != nil
            }, "the b.png row should present Quick Look")
            let gallery = try #require(Self.quickLook(in: window))
            let chain = Self.presentedChain(in: window)
            #expect(chain.first.map(Self.showsList) == true, "the list stays presented under the gallery")

            let source = try #require(gallery.dataSource)
            #expect(source.numberOfPreviewItems(in: gallery) == 3, "images and PDFs only, no Markdown")
            let titles = (0..<source.numberOfPreviewItems(in: gallery)).map {
                source.previewController(gallery, previewItemAt: $0).previewItemTitle ?? nil
            }
            #expect(titles.compactMap { $0 }.sorted() == ["a.png", "b.png", "doc.pdf"])
            #expect(gallery.currentPreviewItemIndex == 1)
            #expect(titles.indices.contains(1) && titles[1] == "b.png", "opened at the tapped row")

            try #require(await Self.eventually {
                Self.shownName(gallery) == "b.png"
            }, "the tapped image's copy should replace its stand-in")

            let pdfIndex = try #require(titles.firstIndex(of: "doc.pdf"))
            gallery.currentPreviewItemIndex = pdfIndex
            try #require(await Self.eventually {
                Self.shownName(gallery) == "doc.pdf"
            }, "paging to the PDF should read and show it")
            #expect(await harness.transport.previewFileReads.map(\.path).contains("/work/w1/doc.pdf"))

            let delegate = gallery.delegate
            // Animated, as `TerminalPreviewGalleryController` dismisses it:
            // on iPad Quick Look ignores a non-animated dismiss and stays up.
            gallery.dismiss(animated: true)
            try #require(await Self.eventually { gallery.presentingViewController == nil })
            // A programmatic dismiss need not tell the delegate; a user's does.
            delegate?.previewControllerDidDismiss?(gallery)

            try #require(await Self.eventually {
                let chain = Self.presentedChain(in: window)
                return Self.quickLook(in: window) == nil && chain.count == 1 && Self.showsList(chain[0])
            }, "closing the gallery should land back on the list")
        }
    }

    @Test func aPreviewTheTerminalStartedSurvivesClosingTheList() async throws {
        let gate = ScriptedTransportCallGate()
        try await Self.withOpenList(opensList: false, readGate: gate) { harness, window in
            let terminal = harness.terminal
            let geometry = try #require(terminal.touchCellGeometry())
            let tapPoint = geometry.point(in: TerminalCellPosition(column: 3, row: 0), x: 0.5, y: 0.5)
            try #require(await Self.eventually {
                if case .openLink? = terminal.tapLink(at: tapPoint) { return true }
                return false
            }, "README.md should read as a previewable link")
            terminal.handleTap(at: tapPoint)
            try #require(await Self.eventually { await gate.entryCount >= 1 }, "the tap should start the read")

            try await Self.openList(in: window)
            try await Self.activate("terminal.file-list.done", in: window)
            try #require(await Self.eventually {
                Self.presentedChain(in: window).isEmpty
            }, "Done should close the list")

            await gate.open()
            try #require(await Self.eventually {
                Self.presentedChain(in: window).last.map {
                    Self.element(id: "markdown-preview.sheet", in: $0.view) != nil
                } == true
            }, "the terminal's load should still present once the read answers")
            #expect(await harness.transport.previewFileReads.map(\.path) == ["/work/w1/README.md"])
        }
    }

    // MARK: - Harness

    private struct ListHarness {
        let transport: ScriptedTransport
        let terminal: WaycarTerminalView
    }

    /// Hosts a live Agent terminal (cwd `/work/w1`), prints `printing` on
    /// one line, waits until the strip's spoken summary holds every
    /// `stripListing` part (an image lists only once its thumbnail read
    /// lands), opens the list through the strip unless `opensList` is
    /// false, runs `body`, then closes whatever is presented, leaves the
    /// Attach and hides the window. Reads answer from `files`, keyed by the
    /// path's tail as printed; `readGate`, when given, holds every file read.
    private static func withOpenList(
        printing: String = "README.md",
        files: [String: Data] = ["README.md": Data(readmeMarkdown.utf8)],
        stripListing: [String] = ["Markdown"],
        opensList: Bool = true,
        readGate: ScriptedTransportCallGate? = nil,
        _ body: @MainActor (ListHarness, UIWindow) async throws -> Void
    ) async throws {
        let suiteName = "files-links-preview-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        await transport.setPreviewFileResponder { path, _ in
            guard let data = files.first(where: { path.hasSuffix("/" + $0.key) })?.value else {
                throw RemoteFilePreviewError.missing
            }
            return data
        }
        await transport.setMediaReadGate(readGate)

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
        try #require(await eventually {
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
        try #require(await eventually {
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
            try #require(await eventually {
                owner.terminalStatus == AttachTerminalStore.Status.live && probe.isConnected
            }, "the Attach should go live")

            let terminal = try #require(
                firstView(in: controller.view) { $0 is WaycarTerminalView } as? WaycarTerminalView)

            // The paths on row 0; the caret parked on row 10, off them and
            // off the input row (a tap there only raises the keyboard), and
            // well above the bottom. Ghostty may apply the grid's last resize
            // from going live after it has drawn these bytes, and a shrink
            // with the caret on the bottom row scrolls row 0 into scrollback:
            // a path printed right after a cursor move lists only from the
            // screen (`AttachMediaPathScanner`), which would never show it.
            #expect(await transport.emitAttachOutput(
                Data("\u{1B}[2J\u{1B}[H\(printing)\r\n\u{1B}[10;1H".utf8)))
            try #require(await eventually {
                guard let strip = element(id: "terminal.file-strip", in: window) else { return false }
                let value = strip.accessibilityValue ?? ""
                return stripListing.allSatisfy { value.contains($0) }
            }, "the strip should list everything printed (\(stripListing))")

            let harness = ListHarness(transport: transport, terminal: terminal)
            if opensList { try await openList(in: window) }
            try await body(harness, window)
        } catch {
            await readGate?.open()
            await dismissAll(in: window)
            await owner.leave().value
            throw error
        }
        await readGate?.open()
        await dismissAll(in: window)
        await owner.leave().value
    }

    /// Opens Files & Links through the strip and waits for its rows.
    private static func openList(in window: UIWindow) async throws {
        try await activate("terminal.file-strip", in: window)
        try #require(await eventually {
            let chain = presentedChain(in: window)
            return chain.count == 1 && showsList(chain[0])
                && element(id: "terminal.file-list.row", in: chain[0].view) != nil
        }, "the strip should open Files & Links with its rows")
    }

    /// Dismisses everything presented and waits until nothing is.
    private static func dismissAll(in window: UIWindow) async {
        guard let first = presentedChain(in: window).first else { return }
        first.presentingViewController?.dismiss(animated: false)
        _ = try? await eventually(timeout: .seconds(3)) {
            presentedChain(in: window).isEmpty
        }
    }

    // MARK: - Helpers

    private static func eventually(
        timeout: Duration = .waitCeiling,
        _ condition: @escaping () async -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    /// Every controller presented under the window's root, outermost first,
    /// leaving out one on its way out.
    private static func presentedChain(in window: UIWindow) -> [UIViewController] {
        var queue = window.rootViewController.map { [$0] } ?? []
        while !queue.isEmpty {
            let controller = queue.removeFirst()
            if var presented = controller.presentedViewController {
                var chain: [UIViewController] = []
                while true {
                    if !presented.isBeingDismissed { chain.append(presented) }
                    guard let next = presented.presentedViewController else { break }
                    presented = next
                }
                return chain
            }
            queue.append(contentsOf: controller.children)
        }
        return []
    }

    /// Whether `controller` is the Files & Links list.
    private static func showsList(_ controller: UIViewController) -> Bool {
        element(id: "terminal.file-list", in: controller.view) != nil
            || element(id: "terminal.file-list.done", in: controller.view) != nil
    }

    /// Taps the element carrying `id` (and, when given, a label starting
    /// with `labelPrefix`), as VoiceOver would.
    /// Waits for it first: a sheet's toolbar items can land after the sheet
    /// itself does (seen on iPad, in a full run).
    private static func activate(
        _ id: String, labelPrefix: String? = nil, in window: UIWindow
    ) async throws {
        _ = try await eventually { element(id: id, labelPrefix: labelPrefix, in: window) != nil }
        let target = try #require(
            element(id: id, labelPrefix: labelPrefix, in: window),
            "\(id) \(labelPrefix ?? "") should be on screen")
        if let control = target as? UIControl {
            control.sendActions(for: .touchUpInside)
        } else {
            try #require(target.accessibilityActivate(), "\(id) should take the tap")
        }
    }

    /// The Quick Look gallery presented anywhere under the window, unless
    /// on its way out.
    private static func quickLook(in window: UIWindow) -> QLPreviewController? {
        var stack = window.rootViewController.map { [$0] } ?? []
        while let controller = stack.popLast() {
            if let preview = controller as? QLPreviewController,
                preview.presentingViewController != nil, !preview.isBeingDismissed
            {
                return preview
            }
            stack.append(contentsOf: controller.children)
            if let presented = controller.presentedViewController { stack.append(presented) }
        }
        return nil
    }

    /// The page Quick Look shows now, by the file name it was served under.
    private static func shownName(_ gallery: QLPreviewController) -> String? {
        gallery.currentPreviewItem?.previewItemURL?.lastPathComponent
    }

    private static func firstView(in root: UIView, where matches: (UIView) -> Bool) -> UIView? {
        if matches(root) { return root }
        for subview in root.subviews {
            if let match = firstView(in: subview, where: matches) { return match }
        }
        return nil
    }

    /// A small solid PNG, so the strip decodes a real thumbnail.
    private static func png(_ color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    /// A one-page PDF.
    private static func pdf() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200)).pdfData { context in
            context.beginPage()
            ("PDF" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: nil)
        }
    }

    private static func identifier(of object: NSObject) -> String? {
        if let identified = object as? UIAccessibilityIdentification {
            return identified.accessibilityIdentifier
        }
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    /// The first view or accessibility element under `root` carrying `id`
    /// (and a label starting with `labelPrefix`, when given): SwiftUI
    /// identifiers surface only in the accessibility tree.
    private static func element(id: String, labelPrefix: String? = nil, in root: UIView?) -> NSObject? {
        guard let root else { return nil }
        var visited = Set<ObjectIdentifier>()
        var stack: [NSObject] = [root]
        while let object = stack.popLast() {
            guard visited.insert(ObjectIdentifier(object)).inserted, visited.count < 40_000 else {
                continue
            }
            if identifier(of: object) == id,
                labelPrefix.map({ object.accessibilityLabel?.hasPrefix($0) == true }) ?? true
            {
                return object
            }
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
