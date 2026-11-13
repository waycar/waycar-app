#if DEBUG && targetEnvironment(simulator)
    import Foundation

    extension DemoScreenshotMode {
        /// Runs the watch bridge over the demo Console, for pairing a watch
        /// simulator with the demo phone. It counts only alongside
        /// `launchArgument`; screenshot runs without it never touch
        /// WatchConnectivity:
        ///
        ///     xcrun simctl launch <udid> com.otreva.waycar --demo-screenshots -WaycarWatchBridgeDemo YES
        static let watchBridgeDefaultsKey = "WaycarWatchBridgeDemo"

        static var isWatchBridgeEnabled: Bool {
            isEnabled && UserDefaults.standard.bool(forKey: watchBridgeDefaultsKey)
        }
    }

    /// The one demo composition the window and the watch bridge share while
    /// `DemoScreenshotMode.isWatchBridgeEnabled`, so the watch sees and
    /// acts on the Console the phone shows.
    @MainActor
    enum DemoWatchBridge {
        static let composition = DemoScreenshotComposition.make()
    }

    extension WatchBridge.Dependencies {
        /// The demo Console's: its verified Agents and Hosts, Latest from
        /// their summaries and transcripts, and actions through
        /// an `AgentActionService` over it. Nothing to hold awake.
        @MainActor
        static func demo(_ composition: DemoScreenshotComposition) -> Self {
            let console = composition.console
            let hosts = composition.hosts
            let actions = AgentActionService(console: console)
            let transcriber = DictationEngines.fileTranscriber
            let voiceTranscription = transcriber != nil
            return Self(
                source: {
                    WatchStateSource.reading(
                        console: console, hosts: hosts.hosts,
                        voiceTranscription: voiceTranscription)
                },
                keychainReadable: { true },
                lastReply: { agent in
                    guard let transcript = try? await console.readChatTranscript(for: agent, after: nil)
                    else { return nil }
                    return WatchStateBuilder.lastReply(from: transcript)
                },
                blockedPrompt: { id in try await actions.blockedPrompt(for: id) },
                answer: { allow, id, snapshot in
                    await actions.answer(allow: allow, agentID: id, shown: snapshot)
                },
                send: { text, id in await actions.send(text, to: id, suffix: nil) },
                transcriber: transcriber,
                hold: { _ in },
                release: {},
                now: { Date() })
        }
    }
#endif
