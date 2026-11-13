import Foundation
import Testing

@testable import Waycar

@Suite("Mosh bootstrap")
struct MoshBootstrapTests {
    /// mosh-server's real banner shape, verified live: the CONNECT line
    /// among startup chatter.
    private static let connectLine = "MOSH CONNECT 60001 MDEyMzQ1Njc4OWFiY2RlZg"
    // 22-char key: "MDEyMzQ1Njc4OWFiY2RlZg"

    @Test func parsesTheConnectBanner() {
        let bootstrap = MoshBootstrap.parse(
            Data("\(Self.connectLine)\n".utf8), host: "host.example")
        #expect(bootstrap == MoshBootstrap(
            host: "host.example", udpPort: "60001",
            key: "MDEyMzQ1Njc4OWFiY2RlZg"))
    }

    @Test func toleratesChatterBeforeAndAfterTheBanner() {
        let output = """
            mosh-server (mosh 1.4.0) [build mosh 1.4.0]
            Copyright 2012 Keith Winstein
            mosh-server: creating PTY...
            \(Self.connectLine)
            mosh-server: started
            """
        let bootstrap = MoshBootstrap.parse(Data(output.utf8))
        #expect(bootstrap?.udpPort == "60001")
        #expect(bootstrap?.key == "MDEyMzQ1Njc4OWFiY2RlZg")
    }

    @Test func toleratesLeadingWhitespaceOnTheBannerLine() {
        let bootstrap = MoshBootstrap.parse(
            Data("\r\n  \(Self.connectLine)\r\n".utf8))
        #expect(bootstrap?.udpPort == "60001")
    }

    @Test func rejectsAMalformedKeyLength() {
        #expect(MoshBootstrap.parse(
            Data("MOSH CONNECT 60001 MDEyMzQ1Njc4OWFiY2RlZ".utf8)) == nil)
        #expect(MoshBootstrap.parse(
            Data("MOSH CONNECT 60001 MDEyMzQ1Njc4OWFiY2RlZg=".utf8)) == nil)
    }

    @Test func rejectsAMissingPort() {
        #expect(MoshBootstrap.parse(
            Data("MOSH CONNECT  MDEyMzQ1Njc4OWFiY2RlZg".utf8)) == nil)
        #expect(MoshBootstrap.parse(
            Data("MOSH CONNECT 60001X MDEyMzQ1Njc4OWFiY2RlZg".utf8)) == nil)
    }

    @Test func rejectsOutputWithoutABanner() {
        #expect(MoshBootstrap.parse(Data("mosh-server: not found\n".utf8)) == nil)
        #expect(MoshBootstrap.parse(Data()) == nil)
    }

    /// The bootstrap returns on this line instead of the exec's EOF (#105):
    /// only the banner matches, never the chatter around it.
    @Test func onlyTheBannerLineEndsTheBootstrapWait() {
        #expect(MoshBootstrap.isBannerLine(Self.connectLine))
        #expect(MoshBootstrap.isBannerLine("  \(Self.connectLine)\r"))
        #expect(!MoshBootstrap.isBannerLine("mosh-server (mosh 1.4.0) [build mosh 1.4.0]"))
        #expect(!MoshBootstrap.isBannerLine("MOSH CONNECT 60001"))
        #expect(!MoshBootstrap.isBannerLine(""))
    }

    // MARK: transport choice

    @Test func agentTargetsChooseMoshWhenProbedAvailable() {
        #expect(
            MoshTransportChoice.select(availability: true, target: .agentPane("w1:p1"))
                == .mosh)
    }

    @Test func shellTargetsKeepSSH() {
        #expect(
            MoshTransportChoice.select(availability: true, target: .terminal("t1"))
                == .ssh)
    }

    @Test func anUnavailableOrMissingProbeKeepsSSH() {
        #expect(
            MoshTransportChoice.select(availability: false, target: .agentPane("w1:p1"))
                == .ssh)
        #expect(
            MoshTransportChoice.select(availability: false, target: .terminal("t1"))
                == .ssh)
    }

    // MARK: bootstrap command

    @Test func bootstrapCommandWrapsTheAttachWithMoshServer() throws {
        let command = try WaycarSSHTransport.moshBootstrapCommand(
            agentAttachCommand: "herdr agent attach",
            terminalAttachCommand: "herdr terminal attach",
            request: TerminalAttachRequest(
                target: .agentPane("w1:p1"), takeover: true, cols: 100, rows: 40),
            socketPath: "/home/user/.herdr/herdr.sock",
            bindsToPeer: false)

        // The herdr attach runs under mosh-server's PTY with the UTF-8
        // locale and a 256-color TERM (`-c` is a color count, never the
        // request's columns); the socket path reaches it through
        // HERDR_SOCKET_PATH.
        #expect(
            command
                .contains(
                    "exec mosh-server new -c 256 -l LANG=en_US.UTF-8 -- herdr agent attach \"$1\" --takeover"))
        #expect(command.contains("HERDR_SOCKET_PATH=\"$2\""))
        #expect(command.contains("'/home/user/.herdr/herdr.sock'"))
        #expect(command.contains("attach \"$1\" --takeover' mosh 'w1:p1'"))
        // A server whose client vanished exits after 60 s instead of holding
        // the pane at this device's size: the variable must be exported to
        // mosh-server itself, so before its exec.
        let timeout = try #require(command.range(of: "export MOSH_SERVER_NETWORK_TMOUT=60; "))
        let exec = try #require(command.range(of: "exec mosh-server new"))
        #expect(timeout.upperBound <= exec.lowerBound)
    }

    @Test func bootstrapCommandOmitsTakeoverWhenNotRequested() throws {
        let command = try WaycarSSHTransport.moshBootstrapCommand(
            agentAttachCommand: "herdr agent attach",
            terminalAttachCommand: "herdr terminal attach",
            request: TerminalAttachRequest(
                target: .agentPane("w1:p1"), takeover: false, cols: 80, rows: 24),
            socketPath: "/home/user/.herdr/herdr.sock",
            bindsToPeer: false)
        #expect(!command.contains("--takeover"))
    }

    @Test func bootstrapCommandRefusesAnUnquotableTarget() {
        #expect(throws: TransportError.self) {
            try WaycarSSHTransport.moshBootstrapCommand(
                agentAttachCommand: "herdr agent attach",
                terminalAttachCommand: "herdr terminal attach",
                request: TerminalAttachRequest(
                    target: .agentPane("w1:p'1"), takeover: false, cols: 80, rows: 24),
                socketPath: "/home/user/.herdr/herdr.sock",
                bindsToPeer: false)
        }
    }

    /// Unbound, the invocation is exactly the one before #122, so every
    /// builder's command is unchanged.
    @Test func unboundServerInvocationIsUnchanged() {
        #expect(
            HostSSHSession.moshServerInvocation(bindsToPeer: false)
                == "exec mosh-server new -c 256 -l LANG=en_US.UTF-8 ")
    }

    /// Bound, mosh-server takes `-s` (the address the SSH connection arrived
    /// on, #122) unless that address is loopback: sshd behind a TCP proxy
    /// on the Host would bind mosh to loopback, so it stays unbound there.
    @Test("the bound server invocation pins the loopback guard text")
    func boundServerInvocationIsTheLoopbackGuardText() {
        #expect(
            HostSSHSession.moshServerInvocation(bindsToPeer: true)
                == "mosh_addr=${SSH_CONNECTION% *}; case ${mosh_addr##* } in "
                + "\"\"|127.*|::1|::ffff:127.*) mosh_bind= ;; *) mosh_bind=-s ;; esac; "
                + "exec mosh-server new $mosh_bind -c 256 -l LANG=en_US.UTF-8 ")
    }

    @Test("a numeric Host literal pins mosh to itself, a name does not", arguments: [
        ("192.0.2.7", "192.0.2.7"),
        ("[2001:db8::1]", "2001:db8::1"),
        ("fe80::1%en0", "fe80::1%en0"),
        ("[fe80::1%en0]", "fe80::1%en0"),
        ("fe80::1%", nil),
        ("localhost", nil),
        ("cafe", nil),
        ("1", nil),
        ("shopify-mbp.brooklyn.arpa", nil),
    ] as [(String, String?)])
    func numericHostLiteralPinsMosh(host: String, expected: String?) {
        #expect(HostSSHSession.numericAddressLiteral(host) == expected)
    }

    /// herdr's attach: the unbound command is the pre-#122 one, and the
    /// bound command differs only in the server invocation.
    @Test func bootstrapCommandBindsToThePeerOnlyWhenAsked() throws {
        func command(bindsToPeer: Bool) throws -> String {
            try WaycarSSHTransport.moshBootstrapCommand(
                agentAttachCommand: "herdr agent attach",
                terminalAttachCommand: "herdr terminal attach",
                request: TerminalAttachRequest(
                    target: .agentPane("w1:p1"), takeover: true, cols: 100, rows: 40),
                socketPath: "/home/user/.herdr/herdr.sock",
                bindsToPeer: bindsToPeer)
        }
        let unbound = try command(bindsToPeer: false)
        #expect(
            unbound
                == "/bin/sh -c '\(HerdrHostPath.pathExport); "
                + "export HERDR_SOCKET_PATH=\"$2\"; export TERM=xterm-256color; "
                + "export MOSH_SERVER_NETWORK_TMOUT=60; "
                + "exec mosh-server new -c 256 -l LANG=en_US.UTF-8 "
                + "-- herdr agent attach \"$1\" --takeover' mosh 'w1:p1' "
                + "'/home/user/.herdr/herdr.sock'")
        #expect(try command(bindsToPeer: true) == Self.boundToPeer(unbound))
    }

    /// tmux's live mosh path, built from the real attach chain.
    @Test func tmuxExecCommandBindsToThePeerOnlyWhenAsked() throws {
        let attach = try TmuxTransport.moshAttachCommand(
            target: TmuxAttachCommand.Target(sessionID: "$3", windowID: "@7", paneID: "%12"),
            attachSessionName: "waycar-0a1b2c3d")
        let unbound = try HostSSHSession.moshBootstrapExecCommand(
            attachCommand: attach, bindsToPeer: false)
        let bound = try HostSSHSession.moshBootstrapExecCommand(
            attachCommand: attach, bindsToPeer: true)
        #expect(
            unbound
                == "/bin/sh -c '\(HerdrHostPath.pathExport); export TERM=xterm-256color; "
                + "export MOSH_SERVER_NETWORK_TMOUT=60; "
                + "exec mosh-server new -c 256 -l LANG=en_US.UTF-8 -- \(attach)' mosh")
        #expect(bound == Self.boundToPeer(unbound))
    }

    @Test func tmuxExecCommandRefusesAnUnquotableAttach() {
        for bindsToPeer in [false, true] {
            #expect(throws: TransportError.self) {
                try HostSSHSession.moshBootstrapExecCommand(
                    attachCommand: "tmux attach -t 'main'", bindsToPeer: bindsToPeer)
            }
        }
    }

    /// `command` with its unbound server invocation, which must occur
    /// exactly once, replaced by the bound one.
    private static func boundToPeer(_ command: String) -> String {
        let unbound = HostSSHSession.moshServerInvocation(bindsToPeer: false)
        #expect(command.components(separatedBy: unbound).count == 2)
        return command.replacingOccurrences(
            of: unbound, with: HostSSHSession.moshServerInvocation(bindsToPeer: true))
    }

    // MARK: typed mosh failure and transport choice

    @Test func moshSessionFailedCarriesItsDetailAndIsRetryable() {
        let error = TransportError.moshSessionFailed(
            detail: "mosh session failed (exit status 1)")
        #expect(error == .moshSessionFailed(detail: "mosh session failed (exit status 1)"))
        #expect(error.isRetryable)
        #expect(error.presentation.summary == "The mosh session failed")
        #expect(!error.isHostKeySecurityFailure)
    }

    @Test func probeBootstrapCommandEchoesAMarkerNotAHerdrAttach() throws {
        let command = try WaycarSSHTransport.moshProbeBootstrapCommand(
            socketPath: "/home/user/.herdr/herdr.sock", bindsToPeer: false)
        // A bare command: mosh-server flattens inner quoting when it joins
        // its arguments through the login shell, so anything that needs
        // quotes dies on connect. `echo MOSH_HANDSHAKE_OK` survives the
        // join verbatim and its marker rides the UDP session back.
        #expect(command.contains("-- echo MOSH_HANDSHAKE_OK"))
        // The probe passes appendsTarget: false — the script must not
        // reference the pane id at all. `echo MOSH_HANDSHAKE_OK mosh-probe`
        // would echo the pane id back and corrupt the marker.
        #expect(!command.contains("$1"))
        // The keep-alive must be a bare command, but the OUTER wrapper is
        // itself a `/bin/sh -c '…'` — that occurrence is the wrapper, not
        // the keep-alive.
        #expect(!command.contains("-- sh -c"))
    }

    @Test func probeBootstrapCommandBindsToThePeerOnlyWhenAsked() throws {
        let unbound = try WaycarSSHTransport.moshProbeBootstrapCommand(
            socketPath: "/home/user/.herdr/herdr.sock", bindsToPeer: false)
        let bound = try WaycarSSHTransport.moshProbeBootstrapCommand(
            socketPath: "/home/user/.herdr/herdr.sock", bindsToPeer: true)
        #expect(
            unbound
                == "/bin/sh -c '\(HerdrHostPath.pathExport); "
                + "export HERDR_SOCKET_PATH=\"$2\"; export TERM=xterm-256color; "
                + "export MOSH_SERVER_NETWORK_TMOUT=60; "
                + "exec mosh-server new -c 256 -l LANG=en_US.UTF-8 "
                + "-- echo MOSH_HANDSHAKE_OK' mosh 'mosh-probe' '/home/user/.herdr/herdr.sock'")
        #expect(bound == Self.boundToPeer(unbound))
    }

    @Test func invalidationMakesTheTransportChoiceReadSSH() {
        // The runner consults MoshTransportChoice with the Console's
        // availability read; an invalidated probe must read unavailable even
        // though mosh-server exists on the Host.
        #expect(
            MoshTransportChoice.select(availability: true, target: .agentPane("w1:p1"))
                == .mosh)
        #expect(
            MoshTransportChoice.select(availability: false, target: .agentPane("w1:p1"))
                == .ssh)
        #expect(
            MoshTransportChoice.select(availability: true, target: .terminal("t1"))
                == .ssh)
    }
}
