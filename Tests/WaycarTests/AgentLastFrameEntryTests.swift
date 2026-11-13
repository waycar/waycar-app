import SwiftUI
import Testing
import UIKit

@testable import Waycar

/// The per-Agent last frame through the real Agent screen and its Ghostty
/// surface: what a painted terminal leaves behind, and what entering an
/// Agent with no live frame shows (#21, #27).
@MainActor
@Suite("Agent last frame on entry")
struct AgentLastFrameEntryTests {
    /// Ghostty draws with Metal; its frame is read back as a real bitmap (not
    /// the black or background-only image a view snapshot gives), and leaving
    /// the screen keeps it as the Agent's latest frame.
    @Test func aPaintedTerminalLeavesItsRenderedFrameBehind() async throws {
        let host = Host.fixture()
        let agent = AgentSurfaceReplacementTests.makeAgent(pane: "w1:p1", host: host.id)
        let store = AgentLastFrameStore(directory: nil)
        let screen = try await Screen(agent: agent, host: host, store: store)
        func run() async throws {
            try #require(await Self.eventually { await screen.transport.attachRequests.count == 1 })
            #expect(await screen.transport.emitAttachOutput(Self.colouredScreen))
            try #require(await Self.eventually { screen.owner.terminalStatus == .live })
            let terminal = try #require(
                AgentSurfaceReplacementTests.terminals(in: screen.controller.view).first)
            var colours = 0
            try #require(await Self.eventually {
                colours = TerminalFrameCapture.image(of: terminal).map(Self.distinctColours) ?? 0
                return colours >= 3
            }, "the captured frame should carry the rendered text and backgrounds (\(colours) colours)")

            screen.window.rootViewController = UIViewController()
            try #require(await Self.eventually { store.frame(for: agent.id, host: host) != nil },
                "leaving the screen keeps its frame as the Agent's latest")
            let frame = try #require(store.frame(for: agent.id, host: host))
            #expect(frame.size == terminal.bounds.size)
            let image = try #require(frame.image.cgImage)
            #expect(Self.distinctColours(image) >= 3)
        }
        do { try await run() } catch {
            await screen.teardown()
            throw error
        }
        await screen.teardown()
    }

    /// Entering an Agent whose terminal is not live yet shows its cached frame
    /// under the Reconnecting loader rather than the cold Connecting one, until
    /// the terminal paints. An ended attach then forgets the cached frame.
    @Test func anEntryWithNoLiveFrameShowsTheCachedFrameUntilItPaints() async throws {
        let host = Host.fixture()
        let agent = AgentSurfaceReplacementTests.makeAgent(pane: "w1:p1", host: host.id)
        let store = AgentLastFrameStore(directory: nil)
        store.record(
            AgentLastFrameStoreTests.image(), size: CGSize(width: 402, height: 874),
            for: agent, host: host)
        let screen = try await Screen(agent: agent, host: host, store: store)
        func showsConnecting() -> Bool {
            AgentSurfaceReplacementTests.shows("Connecting…", in: screen.controller)
        }
        func showsReconnecting() -> Bool {
            AgentSurfaceReplacementTests.showsReconnecting(in: screen.controller)
        }
        func run() async throws {
            try #require(await Self.eventually {
                _ = showsReconnecting()
                return await screen.transport.attachRequests.count == 1
            })
            try #require(await Self.eventually { showsReconnecting() && !showsConnecting() },
                "the cached frame stands in under the Reconnecting loader")
            #expect(screen.owner.terminalStatus == .connecting)

            #expect(await screen.transport.emitAttachOutput(Data("live-frame".utf8)))
            try #require(await Self.eventually {
                screen.owner.terminalStatus == .live && !showsReconnecting()
            }, "the cached frame goes once the terminal paints")

            await screen.transport.endAttachFromRemote()
            try #require(await Self.eventually {
                AgentSurfaceReplacementTests.shows(
                    "Terminal connection: Detached", in: screen.controller)
            })
            #expect(store.frame(for: agent.id, host: host) == nil,
                "an ended attach leaves no cached frame for the next entry")
        }
        do { try await run() } catch {
            await screen.teardown()
            throw error
        }
        await screen.teardown()
    }

    /// A return past the grace: the activation edge attaches while the Host
    /// is still `.suspended`, before the Console resumes it. That is a
    /// connecting Host, so the cached frame stands under the Reconnecting
    /// loader, never under 'Connection Paused', and stays cached.
    @Test func aReturnPastTheGraceKeepsTheCachedFrameUnderReconnecting() async throws {
        let host = Host.fixture()
        let agent = AgentSurfaceReplacementTests.makeAgent(pane: "w1:p1", host: host.id)
        let store = AgentLastFrameStore(directory: nil)
        store.record(
            AgentLastFrameStoreTests.image(), size: CGSize(width: 402, height: 874),
            for: agent, host: host)
        let console = Self.console(dialing: { ScriptedTransport(snapshot: .fixture()) })
        console.setHosts([host])
        await console.resume()
        try #require(await Self.eventually { console.hostStatuses[host.id] == .connected })
        await console.suspend()
        try #require(await Self.eventually {
            console.hostStatuses[host.id] == .suspended
                && !console.hostsWithinReconnectGrace.contains(host.id)
        }, "a return past the grace finds its Host suspended and out of grace")
        let screen = try await Screen(agent: agent, host: host, store: store, console: console)
        func showsPaused() -> Bool {
            AgentSurfaceReplacementTests.shows("Connection Paused", in: screen.controller)
        }
        func run() async throws {
            var pausedSeen = false
            try #require(await Self.eventually {
                pausedSeen = pausedSeen || showsPaused()
                return await screen.transport.attachRequests.count == 1
            })
            try #require(await Self.eventually {
                pausedSeen = pausedSeen || showsPaused()
                return AgentSurfaceReplacementTests.showsReconnecting(in: screen.controller)
            }, "the cached frame stands in under the Reconnecting loader")
            #expect(!pausedSeen, "a suspended Host under a connecting attach is connecting")
            #expect(store.frame(for: agent.id, host: host) != nil)
        }
        do { try await run() } catch {
            await screen.teardown()
            throw error
        }
        await screen.teardown()
    }

    /// An unavailable Host drops the frame on screen but not the Agent's
    /// cached one: the failure is transient. Only an ended attach forgets it.
    @Test func aFailedHostKeepsTheCachedFrameAndAnEndedAttachForgetsIt() async throws {
        let host = Host.fixture()
        let agent = AgentSurfaceReplacementTests.makeAgent(pane: "w1:p1", host: host.id)
        let store = AgentLastFrameStore(directory: nil)
        store.record(
            AgentLastFrameStoreTests.image(), size: CGSize(width: 402, height: 874),
            for: agent, host: host)
        let console = Self.console(dialing: { throw TransportError.authenticationFailed })
        console.setHosts([host])
        let screen = try await Screen(agent: agent, host: host, store: store, console: console)
        func run() async throws {
            try #require(await Self.eventually { await screen.transport.attachRequests.count == 1 })
            await console.resume()
            try #require(await Self.eventually {
                if case .failed = console.hostStatuses[host.id] { return true }
                return false
            })
            try #require(await Self.eventually {
                !AgentSurfaceReplacementTests.showsReconnecting(in: screen.controller)
                    && !AgentSurfaceReplacementTests.shows("Connecting…", in: screen.controller)
            }, "the failed Host replaces the loader")
            #expect(store.frame(for: agent.id, host: host) != nil,
                "a failed Host leaves the cached frame for the next return")

            await screen.transport.endAttachFromRemote()
            try #require(await Self.eventually { store.frame(for: agent.id, host: host) == nil },
                "an ended attach leaves no cached frame for the next entry")
        }
        do { try await run() } catch {
            await screen.teardown()
            throw error
        }
        await screen.teardown()
    }

    // MARK: Fixtures

    /// Red and green backgrounds over the theme's own, and text: whatever the
    /// theme, the rendered frame has at least three colours.
    static let colouredScreen = Data(
        (String(repeating: "\u{1B}[41m RED \u{1B}[42m GREEN \u{1B}[0m waycar last frame\r\n", count: 12))
            .utf8)

    /// The number of distinct colours in `image`, quantized to 4 bits per
    /// channel so compression noise does not count.
    static func distinctColours(_ image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var colours = Set<UInt16>()
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = UInt16(pixels[index] >> 4)
            let green = UInt16(pixels[index + 1] >> 4)
            let blue = UInt16(pixels[index + 2] >> 4)
            colours.insert(red << 8 | green << 4 | blue)
        }
        return colours.count
    }

    static func eventually(
        timeout: Duration = .waitCeiling,
        condition: () async -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// A Console whose Host dials with `dial`, with a reconnect grace that
    /// is over at once.
    static func console(
        dialing dial: @escaping @Sendable () async throws -> any Transport
    ) -> ConsoleStore {
        ConsoleStore(snapshotRetryDelay: .seconds(30), reconnectGrace: .after(.zero)) {
            _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: dial,
                reconnectPolicy: .default,
                keepalive: .default)
        }
    }

    /// An Agent screen with its own scripted Attach, in a scene window, with
    /// `store` as the app's frame cache and `console` as its Console (by
    /// default one whose dials fail).
    @MainActor
    final class Screen {
        let transport: ScriptedTransport
        let owner: AgentAttachStore
        let controller: UIViewController
        let window: UIWindow

        let console: ConsoleStore

        init(
            agent: ConsoleAgent, host: Host, store: AgentLastFrameStore,
            console: ConsoleStore? = nil
        ) async throws {
            let transport = ScriptedTransport()
            self.transport = transport
            let composer = AgentComposerStore(target: agent.agent.paneID) { params in
                try await transport.promptAgent(params)
            }
            owner = AgentAttachStore(
                target: .agentPane(agent.agent.paneID),
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
            let defaults = UserDefaults(suiteName: "agent-last-frame-\(UUID())") ?? .standard
            let console = console ?? AgentLastFrameEntryTests.console(
                dialing: { throw TransportError.sshUnreachable(detail: "fixture") })
            self.console = console
            let view = AgentTerminalView(
                agent: agent,
                console: console,
                terminal: TerminalSettings(
                    themes: TerminalThemeSettings(defaults: defaults),
                    zoom: TerminalZoomSettings(defaults: defaults),
                    fonts: TerminalFontSettings(defaults: defaults),
                    snippets: SnippetStore(defaults: defaults),
                    toolbars: AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)),
                hosts: [host],
                activity: AppActivityCoordinator(),
                keyboardHandoff: TerminalKeyboardHandoff(),
                keyboardInset: TerminalKeyboardInset(),
                isOnStage: { true },
                onSwitch: { _ in },
                onClosed: {},
                composer: composer,
                attachStore: owner)
            controller = UIHostingController(rootView: view.environment(\.agentLastFrames, store))
            window = try await makeTestWindow(
                frame: CGRect(x: 0, y: 0, width: 402, height: 874),
                rootViewController: controller)
        }

        func teardown() async {
            await owner.leave().value
            window.isHidden = true
            window.rootViewController = nil
            console.setHosts([])
        }
    }
}
