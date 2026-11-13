import Testing

@testable import WaycarSSH

@Suite("Byte transport machine")
struct ByteTransportMachineTests {
    private typealias Machine = ByteTransportMachine

    private func machine() -> Machine { Machine(inner: 7, pump: 8) }

    @Test("each descriptor is handed out once")
    func eachDescriptorIsHandedOutOnce() {
        var transport = machine()
        #expect(transport.handle(.takeInner) == [.hand(7)])
        #expect(transport.handle(.takeInner) == [.refuse])
        #expect(transport.handle(.takePumpDescriptor) == [.hand(8)])
        #expect(transport.handle(.takePumpDescriptor) == [.refuse])
        #expect(transport.state == .init(inner: .released, pumpDescriptor: .released))
    }

    @Test("an unstarted abort closes both descriptors still held")
    func anUnstartedAbortClosesWhatItHolds() {
        var full = machine()
        #expect(full.handle(.abort) == [.closeDescriptor(7), .closeDescriptor(8)])
        #expect(full.handle(.takeInner) == [.refuse])
        #expect(full.handle(.takePumpDescriptor) == [.refuse])
        #expect(full.handle(.abort) == [])

        var innerTaken = machine().after([.takeInner])
        #expect(innerTaken.handle(.abort) == [.closeDescriptor(8)])
    }

    @Test("a started pump keeps its descriptor; abort cancels it")
    func aStartedAbortCancelsThePump() {
        var transport = machine().after([.takePumpDescriptor, .startPump])
        #expect(transport.isPumpStarted)
        #expect(transport.handle(.abort) == [.closeDescriptor(7), .cancelPump])
        #expect(transport.handle(.abort) == [.cancelPump])
        #expect(transport.handle(.takeInner) == [.refuse])
    }

    @Test("a pump started with its descriptor still held leaves it to the pump")
    func aStartedPumpOwnsItsDescriptor() {
        var transport = machine().after([.takeInner, .startPump])
        #expect(transport.handle(.abort) == [.cancelPump])
    }
}
