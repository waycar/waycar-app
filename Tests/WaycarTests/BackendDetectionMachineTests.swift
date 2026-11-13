import Foundation
import Testing

@testable import Waycar

struct BackendDetectionMachineTests {
    private let now = Date(timeIntervalSince1970: 100_000)
    private var current: HostBackendPresence {
        HostBackendPresence(
            herdr: true, tmuxVersion: nil,
            waycarPlugin: .installed(.init(version: WaycarPluginRequirement.currentVersion, mode: .herdr)),
            ultimate: [])
    }

    @Test func unknownDetectionAndSecondaryResumeWaitForSettlement() {
        var machine = BackendDetectionMachine().after([
            .request(now: now), .scopeDeferred(.tmux),
        ])
        #expect(machine.handle(.settled(resumable: [], detectionReady: false, enabled: true)).isEmpty)
        #expect(machine.handle(.settled(resumable: [.tmux], detectionReady: true, enabled: true))
            == [.resume(.tmux), .detect(1, stoppedServers: [])])
        #expect(machine.handle(.settled(resumable: [.tmux], detectionReady: true, enabled: true)).isEmpty)
        #expect(machine.handle(.finished(1, presence: current, sameHost: true, now: now))
            == [.release(1), .apply(.init(presence: current, verifiedAt: now))])
        #expect(machine.presence == current)
    }

    @Test func freshCompleteCacheNeedsNoExecButLegacyOrStaleCachesDo() {
        var fresh = BackendDetectionMachine().after([.seed(.init(presence: current, verifiedAt: now))])
        #expect(fresh.handle(.request(now: now)).isEmpty)
        #expect(fresh.handle(.settled(resumable: [], detectionReady: true, enabled: true)).isEmpty)
        var legacy = current
        legacy.ultimate = nil
        var unprobed = current
        unprobed.codexProbed = nil
        var missingPlugin = current
        missingPlugin.waycarPlugin = nil
        for presence in [legacy, unprobed, missingPlugin] {
            var machine = BackendDetectionMachine().after([
                .seed(.init(presence: presence, verifiedAt: now)), .request(now: now),
            ])
            #expect(machine.handle(.settled(resumable: [], detectionReady: true, enabled: true))
                == [.detect(1, stoppedServers: [])])
        }
        var stale = fresh.after([.request(now: now.addingTimeInterval(BackendDetectionMachine.freshness))])
        #expect(stale.handle(.settled(resumable: [], detectionReady: true, enabled: true))
            == [.detect(1, stoppedServers: [])])
    }

    @Test func stoppedServersUseCheapProbesOncePerConnectionAndOnForeground() {
        var presence = current
        presence.codex = CodexPresence(version: "0.167.1", path: "/bin/codex")
        presence.opencode = OpenCodePresence(path: "/bin/opencode", version: "2.2.7")
        var machine = BackendDetectionMachine().after([
            .recorded(presence, now: now), .primaryVerified(4, now: now),
        ])
        #expect(machine.handle(.settled(resumable: [], detectionReady: true, enabled: true))
            == [.detect(1, stoppedServers: [.codex, .opencode])])
        #expect(machine.handle(.finished(1, presence: nil, sameHost: true, now: now)) == [.release(1)])
        #expect(machine.handle(.primaryVerified(4, now: now)).isEmpty)
        #expect(machine.handle(.settled(resumable: [], detectionReady: true, enabled: true)).isEmpty)
        _ = machine.handle(.request(now: now))
        #expect(machine.handle(.settled(resumable: [], detectionReady: true, enabled: true))
            == [.detect(2, stoppedServers: [.codex, .opencode])])
    }

    @Test func externalDetectionSupersedesFlightAndPendingWork() {
        var machine = BackendDetectionMachine().after([
            .request(now: now), .settled(resumable: [], detectionReady: true, enabled: true),
            .request(now: now),
        ])
        #expect(machine.handle(.recorded(current, now: now))
            == [.cancel(1), .apply(.init(presence: current, verifiedAt: now))])
        #expect(machine.handle(.finished(1, presence: .herdrOnly, sameHost: true, now: now)).isEmpty)
        #expect(machine.handle(.settled(resumable: [], detectionReady: true, enabled: true)).isEmpty)
        #expect(machine.presence == current)
    }

    @Test func missingBackendFailureBypassesCacheOnlyOncePerEpisode() {
        var machine = BackendDetectionMachine().after([.recorded(current, now: now)])
        #expect(machine.handle(.missing(.herdr, true, enabled: true)) == [.detect(1, stoppedServers: [])])
        #expect(machine.handle(.missing(.herdr, true, enabled: true)).isEmpty)
        #expect(machine.handle(.finished(1, presence: nil, sameHost: true, now: now)) == [.release(1)])
        #expect(machine.handle(.missing(.herdr, true, enabled: true)).isEmpty)
        _ = machine.handle(.missing(.herdr, false, enabled: true))
        #expect(machine.handle(.missing(.herdr, true, enabled: true)) == [.detect(2, stoppedServers: [])])
    }

    @Test func pendingRequestSurvivesAFailedOrCancelledDetection() {
        var machine = BackendDetectionMachine().after([
            .request(now: now), .settled(resumable: [], detectionReady: true, enabled: true),
            .deferDetection,
        ])
        #expect(machine.handle(.finished(1, presence: nil, sameHost: true, now: now)) == [.release(1)])
        #expect(machine.handle(.settled(resumable: [], detectionReady: true, enabled: true))
            == [.detect(2, stoppedServers: [])])
        _ = machine.handle(.deferDetection)
        #expect(machine.handle(.cancelDetection) == [.cancel(2)])
        #expect(machine.handle(.settled(resumable: [], detectionReady: true, enabled: true))
            == [.detect(3, stoppedServers: [])])
        #expect(machine.handle(.finished(2, presence: current, sameHost: true, now: now)).isEmpty)
    }

    @Test func editsCancelOwnershipAndKeepOnlySameTargetCache() {
        for keepsTarget in [true, false] {
            var machine = BackendDetectionMachine().after([
                .recorded(current, now: now), .scopeDeferred(.tmux),
                .missing(.herdr, true, enabled: true),
            ])
            #expect(machine.handle(.hostChanged(keepsTarget: keepsTarget)) == [.cancel(1)])
            #expect(machine.presence == (keepsTarget ? current : nil))
            #expect(machine.facts.deferredScopes.isEmpty)
            #expect(machine.facts.missing.isEmpty)
            #expect(machine.handle(.finished(1, presence: .herdrOnly, sameHost: true, now: now)).isEmpty)
            #expect(machine.handle(.missing(.herdr, true, enabled: true)) == [.detect(2, stoppedServers: [])])
        }
    }

    @Test func suspensionDropsDeferredWorkButDoesNotCancelAFlight() {
        var machine = BackendDetectionMachine().after([
            .request(now: now), .settled(resumable: [], detectionReady: true, enabled: true),
            .deferDetection, .scopeDeferred(.tmux),
        ])
        #expect(machine.handle(.suspend).isEmpty)
        #expect(machine.facts.deferredScopes.isEmpty)
        #expect(machine.handle(.finished(1, presence: current, sameHost: true, now: now))
            == [.release(1), .apply(.init(presence: current, verifiedAt: now))])
        #expect(machine.handle(.settled(resumable: [.tmux], detectionReady: true, enabled: true)).isEmpty)
    }

    @Test func disabledHostAndWrongHostCompletionNeverPublish() {
        var disabled = BackendDetectionMachine().after([.request(now: now)])
        #expect(disabled.handle(.settled(resumable: [], detectionReady: true, enabled: false)).isEmpty)
        var machine = BackendDetectionMachine().after([.missing(.herdr, true, enabled: true)])
        #expect(machine.handle(.finished(1, presence: current, sameHost: false, now: now)) == [.release(1)])
        #expect(machine.presence == nil)
        #expect(machine.handle(.finished(1, presence: current, sameHost: true, now: now)).isEmpty)
    }
}
