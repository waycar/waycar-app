import WaycarSSH
import Testing

@Suite("WaycarSSH Native Runtime")
struct WaycarSSHNativeRuntimeTests {
    @Test("libssh2 initializes at runtime")
    func initializesLibSSH2() {
        #expect(NativeRuntime.smokeTest())
    }
}
