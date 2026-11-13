import Foundation
import Testing

@testable import Waycar

struct AgentListFieldsEditingMachineTests {
    private let host = UUID()
    private let layout = AgentRowLayout.waycarDefault

    @Test func beginCancelAndSuccessfulSaveClearTheSessionAndInvalidateSyncs() {
        var machine = AgentListFieldsEditingMachine()
        #expect(!machine.isEditing && machine.drafts.isEmpty)
        #expect(machine.handle(.begin) == [.invalidateAllSyncs])
        #expect(machine.isEditing)
        #expect(machine.handle(.edited(host, layout)) == [.invalidateSync(host)])
        #expect(machine.drafts == [host: layout])
        let changes: [Host.ID: AgentRowLayout?] = [host: layout]
        #expect(machine.handle(.save(changes)) == [.persist(changes)])
        #expect(machine.isEditing && machine.drafts == [host: layout])
        #expect(machine.handle(.saved) == [.invalidateAllSyncs])
        #expect(machine.state == .viewing(message: nil))
        _ = machine.handle([.begin, .edited(host, layout), .messageChanged("failed")])
        #expect(machine.handle(.cancel) == [.invalidateAllSyncs])
        #expect(machine.state == .viewing(message: nil))
    }

    @Test func restartingEditingDropsDraftsAndErrors() {
        var machine = AgentListFieldsEditingMachine().after([
            .begin, .edited(host, layout), .messageChanged("failed")
        ])
        #expect(machine.handle(.begin) == [.invalidateAllSyncs])
        #expect(machine.state == .editing(drafts: [:], message: nil))
        #expect(machine.handle(.save([:])) == [.persist([:])])
    }

    @Test func messagesRetainDraftsUntilAValidEditAndCanSurviveOutsideEditing() {
        var machine = AgentListFieldsEditingMachine().after([.messageChanged("outside")])
        #expect(machine.message == "outside")
        _ = machine.handle([.begin, .edited(host, layout), .messageChanged("save failed")])
        #expect(machine.message == "save failed")
        #expect(machine.drafts == [host: layout])
        #expect(machine.handle(.edited(host, layout)) == [.invalidateSync(host)])
        #expect(machine.message == nil)
        _ = machine.handle([.cancel, .messageChanged("kept")])
        #expect(machine.state == .viewing(message: "kept"))
    }

    @Test func pluginDraftApplicationDoesNotInvalidateItsSyncMessage() {
        var machine = AgentListFieldsEditingMachine().after([.begin, .messageChanged("existing")])
        #expect(machine.handle(.syncDraft(host, layout)) == [])
        #expect(machine.drafts == [host: layout])
        #expect(machine.message == "existing")
        #expect(machine.handle(.syncDraft(host, nil)) == [])
        #expect(machine.drafts.isEmpty)
    }

    @Test func viewingIgnoresEditsSyncDraftsAndUnsolicitedSaveResults() {
        var machine = AgentListFieldsEditingMachine()
        let events: [AgentListFieldsEditingMachine.Event] = [
            .edited(host, layout), .syncDraft(host, layout), .save([host: layout]), .saved
        ]
        for event in events {
            #expect(machine.handle(event) == [])
            #expect(machine.state == .viewing(message: nil))
        }
        #expect(machine.handle(.cancel) == [.invalidateAllSyncs])
    }
}
