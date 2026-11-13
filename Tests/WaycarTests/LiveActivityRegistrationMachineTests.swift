import Foundation
import Testing

@testable import Waycar

@Suite("Live Activity registration machine")
struct LiveActivityRegistrationMachineTests {
    private let date = Date(timeIntervalSince1970: 123)
    private var set: LiveActivityRegistrationMachine.ActivityJob { .set(hex: "aa", startedAt: date) }

    @Test func tokenIntentAndClearCarryTheLastRequestedToken() {
        var machine = LiveActivityRegistrationMachine()
        #expect(machine.handle(.clearToken) == [])
        #expect(machine.handle(.activityToken("aa", startedAt: date)) == [.write(1, .activity(set))])
        #expect(machine.state.writtenToken == "aa")
        #expect(machine.handle(.clearToken) == [])
        #expect(machine.state.writtenToken == nil)
        #expect(machine.handle(.finished(1, succeeded: true)) == [.write(2, .activity(.clear(hex: "aa")))])
        #expect(machine.handle(.finished(2, succeeded: true)) == [])
        #expect(machine.state.phase == .idle)
    }

    @Test func startIntentDeduplicatesAndRetainsConditionalClear() {
        var machine = LiveActivityRegistrationMachine()
        #expect(machine.handle(.requestStart(.set(hex: "start"))) == [.write(1, .start(.set(hex: "start")))])
        #expect(machine.handle(.requestStart(.set(hex: "start"))) == [])
        #expect(machine.handle(.requestStart(.clear)) == [])
        #expect(machine.handle(.finished(1, succeeded: false)) == [.write(2, .start(.clear))])
        #expect(machine.handle(.finished(2, succeeded: false)) == [])
        #expect(machine.isDirty)
        #expect(machine.handle(.requestStart(.clear)) == [])
        #expect(machine.handle(.retry) == [.write(3, .start(.clear))])
    }

    @Test func failuresDoNotSpinAndOnlyExplicitRetryRestartsThem() {
        var machine = LiveActivityRegistrationMachine()
        #expect(machine.handle(.enqueue(set)) == [.write(1, .activity(set))])
        #expect(machine.handle(.retry) == [])
        #expect(machine.handle(.finished(1, succeeded: false)) == [])
        #expect(machine.isDirty)
        #expect(machine.handle(.finished(1, succeeded: true)) == [])
        #expect(machine.handle(.retry) == [.write(2, .activity(set))])
        #expect(machine.handle(.finished(1, succeeded: true)) == [])
        #expect(machine.handle(.finished(2, succeeded: true)) == [])
        #expect(!machine.isDirty)
        #expect(machine.handle(.retry) == [])
    }

    @Test func preferencesCannotSupersedeFailedTokenOrClearIntent() {
        for job in [set, .clear(hex: "aa")] {
            var machine = LiveActivityRegistrationMachine()
            #expect(machine.handle(.enqueue(job)) == [.write(1, .activity(job))])
            #expect(machine.handle(.enqueue(.setPreferences)) == [])
            #expect(machine.handle(.finished(1, succeeded: false)) == [])
            #expect(machine.state.phase == .retryPending(.init(activity: job)))
            #expect(machine.handle(.enqueue(.setPreferences)) == [.write(2, .activity(job))])
        }
    }

    @Test func newerTokenSupersedesFailureAndActivityWorkPrecedesStartWork() {
        var machine = LiveActivityRegistrationMachine()
        #expect(machine.handle(.enqueue(set)) == [.write(1, .activity(set))])
        #expect(machine.handle(.requestStart(.set(hex: "start"))) == [])
        #expect(machine.handle(.enqueue(.clear(hex: "aa"))) == [])
        #expect(machine.handle(.enqueue(.setPreferences)) == [])
        #expect(machine.handle(.finished(1, succeeded: false)) == [.write(2, .activity(.clear(hex: "aa")))])
        #expect(machine.handle(.finished(2, succeeded: true)) == [.write(3, .start(.set(hex: "start")))])
        #expect(machine.handle(.finished(3, succeeded: true)) == [])
    }

    @Test func preferenceRefreshesSupersedeEachOtherAndNewWorkPumpsADirtyQueue() {
        var machine = LiveActivityRegistrationMachine()
        #expect(machine.handle(.enqueue(.setPreferences)) == [.write(1, .activity(.setPreferences))])
        #expect(machine.handle(.enqueue(.setPreferences)) == [])
        #expect(machine.handle(.finished(1, succeeded: false)) == [.write(2, .activity(.setPreferences))])
        #expect(machine.handle(.finished(2, succeeded: false)) == [])
        #expect(machine.handle(.requestStart(.clear)) == [.write(3, .activity(.setPreferences))])
        #expect(machine.handle(.finished(3, succeeded: true)) == [.write(4, .start(.clear))])
    }
}
