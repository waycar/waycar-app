import AVFoundation
import Testing

@testable import Waycar

@MainActor
@Suite("Pairing camera access store")
struct PairingCameraAccessStoreTests {
    @Test func initialResolutionUsesCurrentAuthorizationWithoutPrompting() async {
        for status in [AVAuthorizationStatus.authorized, .denied, .restricted] {
            let client = CameraAuthorizationClient(status: status)
            let store = client.makeStore()
            #expect(store.access == .undetermined)

            await store.resolve()

            #expect(store.access == (status == .authorized ? .authorized : .denied))
            #expect(client.requests == 0)
        }
    }

    @Test(arguments: [true, false])
    func undeterminedAuthorizationWaitsForThePermissionAnswer(granted: Bool) async throws {
        let client = CameraAuthorizationClient(status: .notDetermined)
        let store = client.makeStore()
        let resolution = Task { await store.resolve() }
        try await waitUntil { client.answer != nil }
        #expect(store.access == .undetermined)
        #expect(client.requests == 1)

        client.finish(granted: granted)
        await resolution.value

        #expect(store.access == (granted ? .authorized : .denied))
    }

    /// B-16: the sheet stays alive while Settings grants camera permission.
    /// Removing the activation recheck leaves this owner permanently denied.
    @Test func returningFromSettingsRereadsAGrantWithoutAnotherPermissionPrompt() async {
        let client = CameraAuthorizationClient(status: .denied)
        let store = client.makeStore()
        await store.resolve()
        #expect(store.access == .denied)

        client.status = .authorized
        await store.sceneChanged(.background)
        await store.sceneChanged(.inactive)
        #expect(store.access == .denied)
        await store.sceneChanged(.active)

        #expect(store.access == .authorized)
        #expect(client.reads == 2)
        #expect(client.requests == 0)
    }

    @Test func returningFromSettingsAlsoNoticesRevocation() async {
        let client = CameraAuthorizationClient(status: .authorized)
        let store = client.makeStore()
        await store.resolve()
        client.status = .denied

        await store.sceneChanged(.active)

        #expect(store.access == .denied)
        #expect(client.requests == 0)
    }

    @Test func activationDuringTheSystemPromptDoesNotRequestPermissionTwice() async throws {
        let client = CameraAuthorizationClient(status: .notDetermined)
        let store = client.makeStore()
        let resolution = Task { await store.resolve() }
        try await waitUntil { client.answer != nil }

        await store.sceneChanged(.active)

        #expect(client.requests == 1)
        client.finish(granted: true)
        await resolution.value
        #expect(store.access == .authorized)
    }

    @Test func aNewAuthorizationSnapshotSupersedesALatePermissionAnswer() async throws {
        let client = CameraAuthorizationClient(status: .notDetermined)
        let store = client.makeStore()
        let resolution = Task { await store.resolve() }
        try await waitUntil { client.answer != nil }
        client.status = .authorized
        await store.sceneChanged(.active)

        client.finish(granted: false)
        await resolution.value

        #expect(store.access == .authorized)
    }
}

@MainActor
private final class CameraAuthorizationClient {
    var status: AVAuthorizationStatus
    var reads = 0
    var requests = 0
    var answer: CheckedContinuation<Bool, Never>?

    init(status: AVAuthorizationStatus) { self.status = status }

    func makeStore() -> PairingCameraAccessStore {
        PairingCameraAccessStore(
            authorization: {
                self.reads += 1
                return self.status
            },
            requestAccess: {
                await withCheckedContinuation {
                    self.requests += 1
                    self.answer = $0
                }
            })
    }

    func finish(granted: Bool) {
        let continuation = answer
        answer = nil
        continuation?.resume(returning: granted)
    }
}
