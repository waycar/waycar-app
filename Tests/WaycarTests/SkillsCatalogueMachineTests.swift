import Testing

@testable import Waycar

@Suite("Skills catalogue machine")
struct SkillsCatalogueMachineTests {
    private let previous = [AgentSkill(scope: .global, name: "kept", description: nil)]

    @Test func initialLoadOwnsOneFetchAndSuccessReplacesTheList() {
        var machine = SkillsCatalogueMachine()
        #expect(machine.handle(.loadIfNeeded) == [.fetch(1, forceRefresh: false)])
        #expect(machine.state == .loading(previous: [], token: 1))
        #expect(machine.handle([.loadIfNeeded, .refresh]) == [])
        #expect(machine.handle(.finished(1, .loaded(previous))) == [])
        #expect(machine.state == .loaded(previous))
        #expect(machine.handle(.loadIfNeeded) == [])
    }

    @Test func refreshFromIdleForcesTheFetch() {
        var machine = SkillsCatalogueMachine()
        #expect(machine.handle(.refresh) == [.fetch(1, forceRefresh: true)])
    }

    @Test func failedRefreshRetainsItsListAndOnlyExplicitRetryStartsAgain() {
        var machine = SkillsCatalogueMachine().after([
            .loadIfNeeded, .finished(1, .loaded(previous)),
        ])
        #expect(machine.handle(.refresh) == [.fetch(2, forceRefresh: true)])
        #expect(machine.skills == previous)
        #expect(machine.handle(.finished(2, .failed("offline"))) == [])
        #expect(machine.state == .failed(previous: previous, message: "offline"))
        #expect(machine.handle(.loadIfNeeded) == [])
        #expect(machine.handle(.refresh) == [.fetch(3, forceRefresh: true)])
        #expect(machine.handle(.finished(3, .loaded([]))) == [])
        #expect(machine.skills.isEmpty)
    }

    @Test func cancellationRetainsTheListButAllowsANewAppearanceToLoad() {
        var machine = SkillsCatalogueMachine().after([
            .loadIfNeeded, .finished(1, .loaded(previous)), .refresh,
        ])
        #expect(machine.handle(.finished(2, .cancelled)) == [])
        #expect(machine.state == .idle(previous: previous))
        #expect(machine.handle(.loadIfNeeded) == [.fetch(3, forceRefresh: false)])
        #expect(machine.skills == previous)
    }

    @Test func oldCompletionsNeverChangeTheCurrentFetchOrAFinishedCatalogue() {
        var machine = SkillsCatalogueMachine().after([
            .loadIfNeeded, .finished(1, .cancelled), .refresh,
        ])
        #expect(machine.handle(.finished(1, .loaded(previous))) == [])
        #expect(machine.state == .loading(previous: [], token: 2))
        #expect(machine.handle(.finished(2, .failed("offline"))) == [])
        let failed = machine.state
        #expect(machine.handle(.finished(2, .loaded(previous))) == [])
        #expect(machine.state == failed)
        _ = machine.handle(.refresh)
        _ = machine.handle(.finished(3, .loaded(previous)))
        #expect(machine.handle(.finished(2, .failed("late"))) == [])
        #expect(machine.state == .loaded(previous))
        var idle = SkillsCatalogueMachine()
        #expect(idle.handle(.finished(1, .loaded(previous))) == [])
        #expect(idle.state == .idle(previous: []))
    }
}
