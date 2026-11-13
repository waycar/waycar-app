import Foundation
import Synchronization
import Testing

@testable import Waycar

/// A connection's `$HOME` (#105, C-CACHE): a remembered one is used without
/// the home exec, and a socket missing where it put the path re-resolves
/// `$HOME` once so the request can retry.
@Suite("Home directory resolver")
struct HomeDirectoryResolverTests {
    /// The home exec, counted; answers `home` or throws `failure`.
    private final class HomeExec: Sendable {
        private let state: Mutex<(runs: Int, home: String, failure: TransportError?)>

        init(home: String, failure: TransportError? = nil) {
            state = Mutex((0, home, failure))
        }

        var runs: Int { state.withLock { $0.runs } }

        var resolve: @Sendable () async throws -> String {
            { [self] in
                let (home, failure) = state.withLock { state in
                    state.runs += 1
                    return (state.home, state.failure)
                }
                if let failure { throw failure }
                return home
            }
        }
    }

    private let location = HerdrSocketLocation.defaultSession

    @Test func aRememberedHomeAnswersWithoutTheExec() async throws {
        let exec = HomeExec(home: "/home/new")
        let resolver = HomeDirectoryResolver(memory: RememberedFacts(homeDirectory: "/home/dev"))

        #expect(await resolver.hasRememberedValue)
        #expect(try await resolver.value(resolvingWith: exec.resolve) == "/home/dev")
        #expect(exec.runs == 0)
    }

    @Test func withoutOneTheExecRunsOnceAndItsAnswerIsRemembered() async throws {
        let exec = HomeExec(home: "/home/dev")
        let memory = RememberedFacts()
        let resolver = HomeDirectoryResolver(memory: memory)

        #expect(await !resolver.hasRememberedValue)
        async let first = resolver.value(resolvingWith: exec.resolve)
        async let second = resolver.value(resolvingWith: exec.resolve)
        #expect(try await [first, second] == ["/home/dev", "/home/dev"])
        #expect(try await resolver.value(resolvingWith: exec.resolve) == "/home/dev")
        #expect(exec.runs == 1)
        #expect(memory.homeDirectory == "/home/dev")
    }

    /// The Host's `$HOME` moved since it was remembered: the socket is not
    /// where the remembered one put it, the exec finds the real one, and the
    /// moved path is worth one retry.
    @Test func aStaleRememberedHomeReResolvesOnceAndAsksForARetry() async throws {
        let exec = HomeExec(home: "/home/new")
        let memory = RememberedFacts(homeDirectory: "/home/old")
        let resolver = HomeDirectoryResolver(memory: memory)
        let failedPath = location.path(homeDirectory: "/home/old")

        let moved = await resolver.refresh(
            afterFailureAt: failedPath, location: location, resolvingWith: exec.resolve)
        #expect(moved)
        #expect(try await resolver.value(resolvingWith: exec.resolve) == "/home/new")
        #expect(exec.runs == 1)
        #expect(memory.homeDirectory == "/home/new")

        // Another request that failed on the old path retries too, without
        // a second exec.
        #expect(
            await resolver.refresh(
                afterFailureAt: failedPath, location: location, resolvingWith: exec.resolve))
        #expect(exec.runs == 1)
    }

    /// A socket that is really missing stays missing: the path the exec
    /// resolves is the one that failed, so nothing is retried.
    @Test func aCorrectHomeDoesNotRetryAMissingSocket() async throws {
        let exec = HomeExec(home: "/home/dev")
        let resolver = HomeDirectoryResolver(memory: RememberedFacts(homeDirectory: "/home/dev"))
        let failedPath = location.path(homeDirectory: "/home/dev")

        #expect(
            await !resolver.refresh(
                afterFailureAt: failedPath, location: location, resolvingWith: exec.resolve))
        #expect(exec.runs == 1)
        // Proved over exec now: a second failure asks nothing again.
        #expect(
            await !resolver.refresh(
                afterFailureAt: failedPath, location: location, resolvingWith: exec.resolve))
        #expect(exec.runs == 1)
    }

    @Test func aFailedReResolutionForgetsTheRememberedHome() async throws {
        let exec = HomeExec(
            home: "", failure: .homeDirectoryUnresolvable(detail: "home command printed: "))
        let memory = RememberedFacts(homeDirectory: "/home/old")
        let resolver = HomeDirectoryResolver(memory: memory)

        #expect(
            await !resolver.refresh(
                afterFailureAt: location.path(homeDirectory: "/home/old"),
                location: location, resolvingWith: exec.resolve))
        #expect(memory.homeDirectory == nil)
        #expect(await !resolver.hasRememberedValue)
    }

    @Test func anAbsoluteSocketPathNeverAsksForHome() async {
        let exec = HomeExec(home: "/home/dev")
        let resolver = HomeDirectoryResolver(memory: RememberedFacts(homeDirectory: "/home/dev"))

        #expect(
            await !resolver.refresh(
                afterFailureAt: "/tmp/herdr.sock", location: .absolutePath("/tmp/herdr.sock"),
                resolvingWith: exec.resolve))
        #expect(exec.runs == 0)
    }

    @Test func onlyMissingSocketFailuresNameAPathToReResolve() {
        #expect(
            WaycarSSHTransport.missingSocketPath(in: .socketNotFound(path: "/h/s.sock"))
                == "/h/s.sock")
        #expect(
            WaycarSSHTransport.missingSocketPath(in: .streamLocalOpenFailed(path: "/h/s.sock"))
                == "/h/s.sock")
        #expect(
            WaycarSSHTransport.missingSocketPath(in: .herdrNotRunning(path: "/h/s.sock"))
                == "/h/s.sock")
        #expect(
            WaycarSSHTransport.missingSocketPath(in: .herdrSessionNotFound(path: "/h/s.sock"))
                == "/h/s.sock")
        #expect(WaycarSSHTransport.missingSocketPath(in: .timedOut) == nil)
    }
}
