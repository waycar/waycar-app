import Testing

@testable import Waycar

struct RuntimeStartMachineTests {
    @Test func terminalStartHoldsTheClaimThroughVerification() {
        let host = Host.fixture()
        var machine = RuntimeStartMachine()
        #expect(machine.handle(.userStart(host)) == [.start(1, host)])
        #expect(machine.isStarting)
        #expect(machine.handle(.userStart(host)) == [.finish(false)])
        #expect(machine.handle(.started(1, current: host, error: nil, serverChat: false))
            == [.verify(1, retry: true)])
        #expect(machine.state == .verifying(token: 1))
        #expect(machine.handle(.clearError).isEmpty)
        #expect(machine.isStarting)
        #expect(machine.handle(.verified(1)) == [.finish(true)])
        #expect(machine.state == .idle)
    }

    @Test func serverStartDetectsThenRecordsBeforeVerification() {
        let host = Host.fixture()
        let presence = HostBackendPresence.herdrOnly
        var machine = RuntimeStartMachine().after([.userStart(host)])
        #expect(machine.handle(.started(1, current: host, error: nil, serverChat: true)) == [.detect(1, host)])
        #expect(machine.handle(.userStart(host)) == [.finish(false)])
        #expect(machine.handle(.detected(1, current: host, presence: presence, error: nil))
            == [.record(presence), .verify(1, retry: false)])
        #expect(machine.handle(.userStart(host)) == [.finish(false)])
        #expect(machine.handle(.verified(1)) == [.finish(true)])
    }

    @Test func failureClearsOnlyOnAnotherTapOrConnection() {
        let host = Host.fixture()
        var machine = RuntimeStartMachine().after([.userStart(host)])
        #expect(machine.handle(.started(1, current: host, error: "refused", serverChat: false)) == [.finish(false)])
        #expect(machine.error == "refused")
        #expect(!machine.isStarting)
        var retry = machine
        #expect(retry.handle(.userStart(host)) == [.start(2, host)])
        #expect(retry.error == nil)
        #expect(retry.handle(.started(1, current: host, error: "old", serverChat: false)).isEmpty)
        #expect(retry.state == .starting(token: 2, host: host))
        #expect(machine.handle(.clearError).isEmpty)
        #expect(machine.state == .idle)
    }

    @Test func serverDetectionFailureIsAStartFailure() {
        let host = Host.fixture()
        var machine = RuntimeStartMachine().after([
            .userStart(host), .started(1, current: host, error: nil, serverChat: true),
        ])
        #expect(machine.handle(.detected(1, current: host, presence: nil, error: "probe failed")) == [.finish(false)])
        #expect(machine.error == "probe failed")
    }

    @Test func editedOrRemovedHostsGetNeitherOutcome() {
        let host = Host.fixture()
        var edited = host
        edited.address = "changed.example"
        for current in [nil, edited] {
            for error in [nil, "refused"] {
                var terminal = RuntimeStartMachine().after([.userStart(host)])
                #expect(terminal.handle(.started(1, current: current, error: error, serverChat: false))
                    == [.finish(false)])
                #expect(terminal.state == .idle)
                var server = RuntimeStartMachine().after([
                    .userStart(host), .started(1, current: current, error: nil, serverChat: true),
                ])
                #expect(server.handle(.detected(1, current: current, presence: .herdrOnly, error: error))
                    == [.finish(false)])
                #expect(server.state == .idle)
            }
        }
    }

    @Test func staleAndUnsolicitedCompletionsDoNothing() {
        let host = Host.fixture()
        for state in [
            RuntimeStartMachine(),
            RuntimeStartMachine().after([.userStart(host)]),
            RuntimeStartMachine().after([
                .userStart(host), .started(1, current: host, error: nil, serverChat: true),
            ]),
            RuntimeStartMachine().after([
                .userStart(host), .started(1, current: host, error: nil, serverChat: false),
            ]),
            RuntimeStartMachine().after([
                .userStart(host), .started(1, current: host, error: "refused", serverChat: false),
            ]),
        ] {
            var machine = state
            #expect(machine.handle(.started(99, current: host, error: nil, serverChat: false)).isEmpty)
            #expect(machine.handle(.detected(99, current: host, presence: .herdrOnly, error: nil)).isEmpty)
            #expect(machine.handle(.verified(99)).isEmpty)
            #expect(machine.state == state.state)
        }
    }
}
