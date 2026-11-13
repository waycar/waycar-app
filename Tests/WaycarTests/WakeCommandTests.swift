import CryptoKit
import Foundation
import Testing

@testable import Waycar

// The default wake command is the real herdr invocation from spec #16: the
// remote bridge's entry point ensures the server is running before bridging.
@Suite("Wake command")
struct WakeCommandTests {
    @Test func defaultsToHerdrRemoteClientBridge() {
        let settings = SSHTransportSettings(
            host: "example.invalid",
            port: 22,
            username: "u",
            credentials: .ed25519(Curve25519.Signing.PrivateKey()),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in false },
            socket: .defaultSession)

        #expect(settings.wakeCommand == "herdr remote-client-bridge")
        #expect(settings.wakesInLoginSession)
    }

    @Test func scopesNamedSessionWakeCommandToSessionState() throws {
        let wake = try WaycarSSHTransport.wakeExec(
            wakeCommand: "herdr remote-client-bridge",
            socketPath: "/home/u/.config/herdr/sessions/testloop/herdr.sock",
            socketLocation: .namedSession("testloop"),
            inLoginSession: false)

        #expect(
            wake.command == "/bin/sh -c '\(HerdrHostPath.pathExport); "
                + "export HERDR_SOCKET_PATH=\"$1\"; "
                + "export HERDR_SESSION=\"$2\"; herdr remote-client-bridge < /dev/null' wake "
                + "'/home/u/.config/herdr/sessions/testloop/herdr.sock' testloop")
        #expect(wake.input.isEmpty)
    }

    @Test func defaultSessionWakeCommandDoesNotOverrideSessionState() throws {
        let wake = try WaycarSSHTransport.wakeExec(
            wakeCommand: "/opt/herdr-wake --foreground",
            socketPath: "/home/u/.config/herdr/herdr.sock",
            socketLocation: .defaultSession,
            inLoginSession: false)

        #expect(
            wake.command == "/bin/sh -c '\(HerdrHostPath.pathExport); "
                + "export HERDR_SOCKET_PATH=\"$1\"; "
                + "/opt/herdr-wake --foreground < /dev/null' wake "
                + "'/home/u/.config/herdr/herdr.sock'")
    }

    @Test func absolutePathWakeCommandDoesNotOverrideSessionState() throws {
        let wake = try WaycarSSHTransport.wakeExec(
            wakeCommand: "/opt/herdr-wake --foreground",
            socketPath: "/home/u/My Config/herdr.sock",
            socketLocation: .absolutePath("/home/u/My Config/herdr.sock"),
            inLoginSession: false)

        #expect(
            wake.command == "/bin/sh -c '\(HerdrHostPath.pathExport); "
                + "export HERDR_SOCKET_PATH=\"$1\"; "
                + "/opt/herdr-wake --foreground < /dev/null' wake "
                + "'/home/u/My Config/herdr.sock'")
    }

    /// The login-session wake tries a `gui/<uid>` launchd job first and
    /// falls through to the plain wake, which ends the same script.
    @Test func loginSessionWakeRunsALaunchdJobBeforeThePlainWake() throws {
        let wake = try WaycarSSHTransport.wakeExec(
            wakeCommand: "herdr remote-client-bridge",
            socketPath: "/home/u/.config/herdr/sessions/testloop/herdr.sock",
            socketLocation: .namedSession("testloop"),
            inLoginSession: true)

        #expect(wake.command.hasPrefix("/bin/sh -c '\(HerdrHostPath.pathExport); "))
        #expect(wake.command.contains("launchctl print \"gui/$u\""))
        #expect(
            wake.command.contains(
                "env -i PATH=\"$PATH\" HOME=\"$HOME\" HERDR_SOCKET_PATH=\"$1\" "
                    + "HERDR_SESSION=\"$2\" /bin/sh -c \"export -p\""))
        #expect(wake.command.contains("launchctl bootstrap \"gui/$u\" \"$d/job.plist\""))
        #expect(wake.command.contains("<key>ProcessType</key><string>Interactive</string>"))
        // A stale socket exists before the wake starts: the exec waits for the
        // job to finish and reads its status, never for the socket alone.
        #expect(wake.command.contains("while [ -d \"$d\" ] && [ $i -lt 120 ]"))
        #expect(wake.command.contains("read r <&4; [ \"$r\" = 0 ] && [ -S \"$1\" ] && exit 0"))
        #expect(
            wake.command.hasSuffix(
                "rm -rf \"$d\"; fi; export HERDR_SOCKET_PATH=\"$1\"; "
                    + "export HERDR_SESSION=\"$2\"; herdr remote-client-bridge < /dev/null' wake "
                    + "'/home/u/.config/herdr/sessions/testloop/herdr.sock' testloop"))
        #expect(
            String(decoding: wake.input, as: UTF8.self)
                == """
                d=${0%/*}
                { . "$d/env" && cd "$HOME" && herdr remote-client-bridge < /dev/null; } 2> "$d/err"
                echo $? > "$d/rc"
                rm -rf "$d"
                launchctl bootout "gui/$(id -u)/${d##*/}"

                """)
    }

    @Test func loginSessionWakeOfTheDefaultSessionSetsNoSession() throws {
        let wake = try WaycarSSHTransport.wakeExec(
            wakeCommand: "herdr remote-client-bridge",
            socketPath: "/home/u/.config/herdr/herdr.sock",
            socketLocation: .defaultSession,
            inLoginSession: true)

        #expect(!wake.command.contains("HERDR_SESSION"))
        #expect(
            wake.command.contains(
                "env -i PATH=\"$PATH\" HOME=\"$HOME\" HERDR_SOCKET_PATH=\"$1\" /bin/sh -c"))
    }

    /// The script is one single-quoted word to the account shell (zsh, bash,
    /// fish), and the server inherits the wake's environment, so no locale.
    @Test(arguments: [
        (HerdrSocketLocation.namedSession("testloop"), false),
        (.namedSession("testloop"), true),
        (.defaultSession, false),
        (.defaultSession, true),
    ])
    func wakeScriptHoldsNoQuoteBackslashOrLocale(
        location: HerdrSocketLocation, inLoginSession: Bool
    ) throws {
        let wake = try WaycarSSHTransport.wakeExec(
            wakeCommand: "herdr remote-client-bridge",
            socketPath: location.path(homeDirectory: "/home/u"),
            socketLocation: location,
            inLoginSession: inLoginSession)
        let prefix = "/bin/sh -c '"
        #expect(wake.command.hasPrefix(prefix))
        let script = try #require(
            wake.command.dropFirst(prefix.count).components(separatedBy: "' wake ").first)
        #expect(!script.contains("'"))
        #expect(!script.contains("\\"))
        #expect(!wake.command.contains("LC_ALL"))
    }

    /// The default session can be started even before `~/.config/herdr`
    /// exists. A missing named-session or custom folder is a distinct error,
    /// since starting it would create a session that isn't there.
    @Test func classificationTestsTheFolderExceptForTheDefaultSession() throws {
        let folderTest = "[ -d \"${1%/*}\" ] || exit 4; "
        let defaultProbe = try #require(
            WaycarSSHTransport.classificationCommand(
                socketPath: "/home/u/.config/herdr/herdr.sock", socketLocation: .defaultSession))
        #expect(!defaultProbe.contains(folderTest))
        #expect(defaultProbe.contains("[ -S \"$1\" ] && exit 0; "))
        #expect(defaultProbe.contains("command -v herdr >/dev/null 2>&1 || exit 1; exit 3'"))
        for location in [
            HerdrSocketLocation.namedSession("work"), .absolutePath("/srv/herdr/herdr.sock"),
        ] {
            let probe = try #require(
                WaycarSSHTransport.classificationCommand(
                    socketPath: location.path(homeDirectory: "/home/u"), socketLocation: location))
            #expect(probe.contains("[ -S \"$1\" ] && exit 0; "))
            #expect(
                probe.contains("command -v herdr >/dev/null 2>&1 || exit 1; " + folderTest + "exit 3'"))
        }
    }

    @Test func refusesInvalidNamedSession() {
        #expect(throws: TransportError.self) {
            _ = try WaycarSSHTransport.wakeExec(
                wakeCommand: "herdr remote-client-bridge",
                socketPath: "/home/u/.config/herdr/sessions/work session/herdr.sock",
                socketLocation: .namedSession("work session"),
                inLoginSession: true)
        }
    }

    @Test func refusesUnquotableSocketPath() {
        #expect(throws: TransportError.self) {
            _ = try WaycarSSHTransport.wakeExec(
                wakeCommand: "herdr remote-client-bridge",
                socketPath: "/tmp/it's-a.sock",
                socketLocation: .absolutePath("/tmp/it's-a.sock"),
                inLoginSession: true)
        }
    }
}

// Connect failures that need no live sshd.
@Suite("SSH connect failure taxonomy")
struct SSHConnectFailureTests {
    @Test func unreachableHostMapsToSSHUnreachable() async throws {
        // Nothing listens on port 1 (privileged, unused): connection refused.
        let settings = SSHTransportSettings(
            host: "127.0.0.1",
            port: 1,
            username: "nobody",
            credentials: .password("irrelevant"),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true },
            socket: .defaultSession)

        do {
            let transport = try await WaycarSSHTransport.connect(settings: settings)
            try await transport.close()
            Issue.record("connect succeeded against a dead port")
        } catch let error as TransportError {
            guard case .sshUnreachable = error else {
                Issue.record("expected sshUnreachable, got \(error)")
                return
            }
        }
    }
}
