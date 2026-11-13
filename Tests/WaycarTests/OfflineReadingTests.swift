import Foundation
import Testing

@testable import Waycar

func transcriptMessage(
    _ index: Int, role: ChatTranscriptMessage.Role? = nil
) -> ChatTranscriptMessage {
    ChatTranscriptMessage(
        id: "m\(index)", role: role ?? (index.isMultiple(of: 2) ? .user : .assistant),
        text: "message \(index)", timestamp: nil)
}

func transcriptMessages(_ range: Range<Int>) -> [ChatTranscriptMessage] {
    range.map { transcriptMessage($0) }
}

func waitUntilTrue(
    _ comment: Comment, timeout: Duration = .waitCeiling, condition: @MainActor () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await condition(), comment)
}

/// What a read of the Host does to the copy this device keeps.
@Suite("Chat transcript merge")
struct ChatTranscriptMergeTests {
    @Test func aSliceAfterAnIdNeverShrinksALongerCopy() {
        let kept = transcriptMessages(0..<6)
        let slice = transcriptMessages(5..<7)
        let merged = ChatTranscriptMerge.merged(
            cached: kept, incoming: slice, isWholeList: false, truncated: false)
        #expect(merged == transcriptMessages(0..<7))
        // A slice that holds nothing new, or nothing at all, changes nothing.
        #expect(
            ChatTranscriptMerge.merged(
                cached: kept, incoming: [kept[5]], isWholeList: false, truncated: false) == kept)
        #expect(
            ChatTranscriptMerge.merged(
                cached: kept, incoming: [], isWholeList: false, truncated: false) == kept)
    }

    @Test func aWholeListThatStartsLaterKeepsTheOlderMessages() {
        let kept = transcriptMessages(0..<6)
        // The Host's reader cut its oldest messages.
        let merged = ChatTranscriptMerge.merged(
            cached: kept, incoming: transcriptMessages(3..<8), isWholeList: true,
            truncated: true)
        #expect(merged == transcriptMessages(0..<8))
    }

    @Test func aWholeListThatEndsEarlierKeepsTheNewerMessages() {
        let kept = transcriptMessages(0..<6)
        let merged = ChatTranscriptMerge.merged(
            cached: kept, incoming: transcriptMessages(0..<4), isWholeList: true,
            truncated: false)
        #expect(merged == kept)
    }

    @Test func aChangedMessageIsReplacedInPlace() {
        let kept = transcriptMessages(0..<3)
        let edited = ChatTranscriptMessage(id: "m1", role: .assistant, text: "revised", timestamp: nil)
        let merged = ChatTranscriptMerge.merged(
            cached: kept, incoming: [kept[0], edited, kept[2]], isWholeList: true,
            truncated: false)
        #expect(merged.map(\.text) == ["message 0", "revised", "message 2"])
    }

    @Test func aWholeListSharingNothingIsARestartUnlessTheReaderCutOlderMessages() {
        let kept = transcriptMessages(0..<3)
        let other = transcriptMessages(10..<12)
        #expect(
            ChatTranscriptMerge.merged(
                cached: kept, incoming: other, isWholeList: true, truncated: false) == other)
        #expect(
            ChatTranscriptMerge.merged(
                cached: kept, incoming: other, isWholeList: true, truncated: true)
                == kept + other)
    }

    @Test func anEmptyCopyTakesTheAnswerAndAnEmptyAnswerKeepsTheCopy() {
        let list = transcriptMessages(0..<3)
        #expect(
            ChatTranscriptMerge.merged(
                cached: [], incoming: list, isWholeList: true, truncated: false) == list)
        #expect(
            ChatTranscriptMerge.merged(
                cached: list, incoming: [], isWholeList: true, truncated: false) == list)
    }
}

/// When the terminal offers its saved conversation, and how the reader dates it.
@Suite("Offline reading rules")
struct OfflineReadingRulesTests {
    private let saved = SavedTranscript(
        messages: transcriptMessages(0..<2), savedAt: Date(timeIntervalSince1970: 1_800_000_000))
    private let empty = SavedTranscript(
        messages: [], savedAt: Date(timeIntervalSince1970: 1_800_000_000))

    @Test func aLiveTerminalOffersNoReaderHoweverLongItWasReconnecting() {
        #expect(!OfflineReading.offersReader(connection: .live, saved: saved))
        #expect(
            !OfflineReading.offersReader(
                connection: .live, saved: saved, reconnectingFor: .seconds(60)))
    }

    @Test func anEndedAttachOrAnUnavailableHostOffersTheReaderAtOnce() {
        let states: [TerminalConnectionIndicator] = [
            .detached(message: "Ended", canUseSSH: false),
            .hostUnavailable(title: "Host Unavailable", message: nil),
            .reconnecting(message: nil, isStalled: true),
        ]
        for state in states {
            #expect(OfflineReading.offersReader(connection: state, saved: saved), "\(state)")
        }
    }

    /// A session that has not loaded in a while takes seconds on a fast
    /// network: it must not read as offline, so the offer waits for a connect
    /// that lasts.
    @Test func aSlowConnectOnAWorkingNetworkOffersTheReaderOnlyAfterEightSeconds() {
        let connecting = TerminalConnectionIndicator.reconnecting(message: nil, isStalled: false)
        for elapsed in [Duration.zero, .seconds(3), .milliseconds(7_999)] {
            #expect(
                !OfflineReading.offersReader(
                    connection: connecting, saved: saved, hasNetwork: true, reconnectingFor: elapsed),
                "\(elapsed)")
        }
        for elapsed in [Duration.seconds(8), .seconds(30)] {
            #expect(
                OfflineReading.offersReader(
                    connection: connecting, saved: saved, hasNetwork: true, reconnectingFor: elapsed),
                "\(elapsed)")
        }
        #expect(OfflineReading.isSlowConnectCandidate(connecting, hasNetwork: true))
        #expect(
            !OfflineReading.isSlowConnectCandidate(
                .reconnecting(message: nil, isStalled: true), hasNetwork: true))
        #expect(!OfflineReading.isSlowConnectCandidate(connecting, hasNetwork: false))
        #expect(!OfflineReading.isSlowConnectCandidate(.live, hasNetwork: true))
        #expect(!OfflineReading.isSlowConnectCandidate(nil, hasNetwork: true))
    }

    /// With no network at all there is nothing to wait for.
    @Test func aDeviceWithNoNetworkOffersTheReaderAtOnceInEveryNotLiveState() {
        let states: [TerminalConnectionIndicator] = [
            .reconnecting(message: nil, isStalled: false),
            .reconnecting(message: nil, isStalled: true),
            .detached(message: nil, canUseSSH: false),
            .hostUnavailable(title: "", message: nil),
        ]
        for state in states {
            #expect(OfflineReading.cause(connection: state, hasNetwork: false) == .offline, "\(state)")
            #expect(
                OfflineReading.offersReader(
                    connection: state, saved: saved, hasNetwork: false, reconnectingFor: .zero),
                "\(state)")
        }
        #expect(OfflineReading.cause(connection: .live, hasNetwork: false) == nil)
    }

    /// A Host that cannot be used says why in its own words.
    @Test func aHostThatCannotBeUsedNamesItselfInTheCard() {
        let unavailable = TerminalConnectionIndicator.hostUnavailable(
            title: "Host Unavailable", message: nil)
        #expect(OfflineReading.hostTitle(unavailable) == "Host Unavailable")
        #expect(
            OfflineReading.offerTitle(.hostUnreachable, hostTitle: OfflineReading.hostTitle(unavailable))
                == "Host Unavailable")
        // A Host with no title of its own, or a connection that is not a Host
        // problem, gets the generic line or none.
        #expect(OfflineReading.offerTitle(.hostUnreachable, hostTitle: "") == "Can't reach your Host")
        #expect(OfflineReading.offerTitle(.hostUnreachable) == "Can't reach your Host")
        #expect(OfflineReading.hostTitle(.detached(message: nil, canUseSSH: false)) == nil)
        #expect(OfflineReading.hostTitle(nil) == nil)
    }

    /// "You're offline" is only said of a device with no network; with one, the
    /// words say what the app knows.
    @Test func onlyADeviceWithNoNetworkIsCalledOffline() {
        let withNetwork: [(TerminalConnectionIndicator, OfflineReading.Cause)] = [
            (.detached(message: nil, canUseSSH: false), .disconnected),
            (.hostUnavailable(title: "", message: nil), .hostUnreachable),
            (.reconnecting(message: nil, isStalled: true), .hostUnreachable),
            (.reconnecting(message: nil, isStalled: false), .connecting),
        ]
        for (state, expected) in withNetwork {
            #expect(OfflineReading.cause(connection: state, hasNetwork: true) == expected, "\(state)")
        }
        let offline = OfflineReading.offerTitle(.offline)
        for cause in [OfflineReading.Cause.hostUnreachable, .disconnected, .connecting] {
            #expect(OfflineReading.offerTitle(cause) != offline, "\(cause)")
        }
        #expect(OfflineReading.symbol(.offline) != OfflineReading.symbol(.connecting))
    }

    @Test func nothingIsOfferedWithoutAReadableCopy() {
        let states: [TerminalConnectionIndicator] = [
            .reconnecting(message: nil, isStalled: false),
            .reconnecting(message: nil, isStalled: true),
            .detached(message: "Ended", canUseSSH: false),
            .hostUnavailable(title: "Host Unavailable", message: nil),
        ]
        for state in states {
            #expect(
                !OfflineReading.offersReader(
                    connection: state, saved: empty, reconnectingFor: .seconds(60)), "\(state)")
            #expect(
                !OfflineReading.offersReader(
                    connection: state, saved: nil, reconnectingFor: .seconds(60)), "\(state)")
        }
    }

    @Test func noTerminalStateOffersNoReader() {
        for hasNetwork in [true, false] {
            #expect(
                !OfflineReading.offersReader(
                    connection: nil, saved: saved, hasNetwork: hasNetwork,
                    reconnectingFor: .seconds(60)))
        }
    }

    @Test func theReaderCountsTheEndOfTheCopyAsTheBottomWithinAHalfLine() {
        #expect(OfflineReading.isNearBottom(visibleMaxY: 2_000, contentHeight: 2_000))
        #expect(
            OfflineReading.isNearBottom(
                visibleMaxY: 2_000 - OfflineReading.nearBottomTolerance, contentHeight: 2_000))
        #expect(!OfflineReading.isNearBottom(visibleMaxY: 1_200, contentHeight: 2_000))
        // A copy shorter than the screen is always at its bottom.
        #expect(OfflineReading.isNearBottom(visibleMaxY: 800, contentHeight: 300))
    }

    @Test func aReaderAtTheBottomFollowsAndOneReadingOlderTextIsNotPulledAway() {
        var follow = OfflineReaderFollow()
        #expect(follow.anchorsAfterChange, "a reader opens at the bottom")

        // The user drags up and lets go in older text.
        follow.scrollCameToRest(afterUserScroll: true, nearBottom: false)
        #expect(!follow.anchorsAfterChange)

        // Back at the bottom by their own hand: following again.
        follow.scrollCameToRest(afterUserScroll: true, nearBottom: true)
        #expect(follow.anchorsAfterChange)
    }

    /// The Composer card grows in several steps (queued rows crossing their
    /// cap, rows scrolling inside it): the reader's own scrolls and the layout's
    /// rest mid-change, reading "not at the bottom". None of them decides.
    @Test func aViewportThatShrinksInSeveralStepsEndsAnchoredForAReaderAtTheBottom() {
        var follow = OfflineReaderFollow()
        for _ in 0..<5 {
            // Each step: a scroll the reader or the layout drove rests short of the end.
            follow.scrollCameToRest(afterUserScroll: false, nearBottom: false)
            #expect(follow.anchorsAfterChange)
        }
        // And an animated scroll to the end that the next step cut short.
        follow.scrollCameToRest(afterUserScroll: false, nearBottom: false)
        #expect(follow.anchorsAfterChange)
    }

    @Test func aReaderScrolledUpStaysWhereItIsThroughLayoutChanges() {
        var follow = OfflineReaderFollow()
        follow.scrollCameToRest(afterUserScroll: true, nearBottom: false)
        // A layout-driven rest that happens to land at the bottom does not bring it back.
        follow.scrollCameToRest(afterUserScroll: false, nearBottom: true)
        #expect(!follow.anchorsAfterChange)
    }

    @Test func theViewportRunsFromTheReadersTopToTheChromesTopEdge() {
        // A reader starting at 100 with the chrome from 722: 622 pt to read in.
        #expect(OfflineReading.viewportHeight(readerMinY: 100, chromeTop: 722) == 622)
        // The chrome is not measured yet: the reader fills its frame.
        #expect(OfflineReading.viewportHeight(readerMinY: 100, chromeTop: nil) == nil)
        // A chrome that has reached the reader's top (or passed it) leaves no viewport, never a negative one.
        #expect(OfflineReading.viewportHeight(readerMinY: 100, chromeTop: 100) == 0)
        #expect(OfflineReading.viewportHeight(readerMinY: 100, chromeTop: 40) == 0)
        // The keyboard lifts the chrome: the viewport follows it up.
        #expect(OfflineReading.viewportHeight(readerMinY: 100, chromeTop: 436) == 336)
    }

    @Test func theReadPillRestsAboveTheChromeNotAFixedDistanceFromTheBottom() {
        // No chrome measured: the plain margin from the bottom edge.
        #expect(OfflineReading.pillBottomPadding(hostMaxY: 800, chromeTop: nil) == 24)
        // A chrome whose top is 122 below the host's bottom edge or less: the pill is clear of it by 12.
        #expect(OfflineReading.pillBottomPadding(hostMaxY: 844, chromeTop: 722) == 134)
        // A chrome that starts below the host: the plain margin still holds.
        #expect(OfflineReading.pillBottomPadding(hostMaxY: 600, chromeTop: 722) == 24)
        // A host that already ends at the chrome: just the margin.
        #expect(OfflineReading.pillBottomPadding(hostMaxY: 722, chromeTop: 722) == 24)
    }

    @Test func theComposersQueueAreaIsCappedToLeaveRoomToRead() {
        func cap(_ minY: CGFloat, _ height: CGFloat, _ chromeTop: CGFloat, _ queue: CGFloat) -> CGFloat {
            OfflineReading.queueAreaCap(
                containerMinY: minY, availableHeight: height, chromeTop: chromeTop,
                queueAreaHeight: queue)
        }
        // Room to spare: a 700 pt region with a 200 pt chrome and no queued rows
        // leaves 500 pt to read, 255 pt over the 245 pt (35%) it must keep.
        #expect(abs(cap(100, 700, 600, 0) - 255) < 0.01)
        // The same screen with 100 pt of queued rows shown: the answer holds
        // (the chrome's top moved up by exactly what the rows added).
        #expect(abs(cap(100, 700, 500, 100) - 255) < 0.01)
        // A short region (keyboard up, 3 queued rows): the chrome already
        // covers it, so the area shrinks to its floor, never to nothing.
        #expect(cap(100, 400, 42, 258) == OfflineReading.minimumQueueAreaHeight)
        // A tall region asks for its share (35%) of the height, not just the flat minimum.
        #expect(abs(cap(0, 1_000, 700, 0) - (700 - 350)) < 0.01)
        // A region the chrome has not reached yet only widens the cap.
        #expect(cap(0, 1_000, 900, 0) > cap(0, 1_000, 700, 0))
    }

    @Test func theCopysAgeNeverReadsAsAFutureSave() {
        let saved = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(OfflineReading.age(savedAt: saved, now: saved.addingTimeInterval(20)) == "just now")
        #expect(OfflineReading.age(savedAt: saved, now: saved.addingTimeInterval(2 * 3600 + 5)) == "2 hours ago")
        #expect(OfflineReading.age(savedAt: saved, now: saved.addingTimeInterval(3 * 86_400)) == "3 days ago")
        // A clock that moved back never reads as a future save.
        #expect(OfflineReading.age(savedAt: saved, now: saved.addingTimeInterval(-90)) == "just now")
    }

    @Test func theCardCarriesTheCopysAge() {
        let saved = Date(timeIntervalSince1970: 1_800_000_000)
        let later = saved.addingTimeInterval(2 * 3600 + 5)
        #expect(OfflineReading.offerSubtitle(savedAt: saved, now: later).hasSuffix("2 hours ago"))
    }

    @Test func theReaderBannerSaysOfflineOnlyForADeviceWithNoNetwork() {
        let saved = Date(timeIntervalSince1970: 1_800_000_000)
        let now = saved.addingTimeInterval(3600)
        #expect(OfflineReading.isTerminalLive(.live))
        #expect(!OfflineReading.isTerminalLive(.reconnecting(message: nil, isStalled: false)))
        #expect(!OfflineReading.isTerminalLive(nil))
        let detached = TerminalConnectionIndicator.detached(message: nil, canUseSSH: false)
        let noNetwork = OfflineReading.banner(
            connection: detached, hasNetwork: false, savedAt: saved, now: now)
        let withNetwork = OfflineReading.banner(
            connection: detached, hasNetwork: true, savedAt: saved, now: now)
        // Both date the copy; only the no-network one says the device is offline.
        #expect(noNetwork?.contains("1 hour ago") == true)
        #expect(withNetwork?.contains("1 hour ago") == true)
        #expect(noNetwork != withNetwork)
        #expect(noNetwork?.localizedCaseInsensitiveContains("offline") == true)
        #expect(withNetwork?.localizedCaseInsensitiveContains("offline") == false)
        // Back online carries no age and is the same whatever the network says.
        let back = OfflineReading.banner(connection: .live, hasNetwork: true, savedAt: saved, now: now)
        #expect(back != nil && back?.contains("hour") == false)
        #expect(back == OfflineReading.banner(connection: .live, hasNetwork: false, savedAt: saved, now: now))
        #expect(OfflineReading.banner(connection: nil, hasNetwork: true, savedAt: saved, now: now) == nil)
        #expect(
            OfflineReading.compactBanner(connection: nil, hasNetwork: true, savedAt: saved, now: now)
                == nil)
    }
}

/// The saved-time stamp the cache keeps beside each list.
@Suite("Chat transcript cache stamps")
struct ChatTranscriptCacheStampTests {
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "chat-transcript-stamps-\(UUID().uuidString)", directoryHint: .isDirectory)
    private let key = ChatTranscriptCache.Key(
        hostID: UUID(), paneID: "w1:p1", terminalID: "t1", launchedAt: "")

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date) { self.date = date }
        var now: Date {
            get { lock.withLock { date } }
            set { lock.withLock { date = newValue } }
        }
    }

    @Test func aSavedListKnowsWhenItWasSavedAcrossARelaunch() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = Clock(start)
        let writer = ChatTranscriptCache(directory: directory, now: { clock.now })
        #expect(writer.savedAt(for: key) == nil)
        writer.save(transcriptMessages(0..<3), for: key)
        #expect(writer.savedAt(for: key) == start)
        writer.flush()

        let reader = ChatTranscriptCache(directory: directory)
        #expect(reader.savedAt(for: key) == start)
    }

    @Test func confirmingMovesTheTimeOnlyOncePastItsGranularity() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = Clock(start)
        let cache = ChatTranscriptCache(directory: directory, now: { clock.now })
        cache.save(transcriptMessages(0..<3), for: key)
        cache.flush()
        let url = cache.fileURL(for: key)
        let before = try Data(contentsOf: url)

        clock.now = start.addingTimeInterval(30)
        #expect(!cache.confirm(key), "inside the granularity the time stays put")
        cache.flush()
        #expect(cache.savedAt(for: key) == start)
        #expect(try Data(contentsOf: url) == before, "a read every few seconds writes nothing")

        clock.now = start.addingTimeInterval(600)
        #expect(cache.confirm(key), "past it the time moves, and says so")
        cache.flush()
        #expect(cache.savedAt(for: key) == start.addingTimeInterval(600))
        #expect(cache.messages(for: key) == transcriptMessages(0..<3))
        let relaunched = ChatTranscriptCache(directory: directory)
        #expect(relaunched.savedAt(for: key) == start.addingTimeInterval(600))
    }

    @Test func confirmingAnAgentWithNoCopyKeepsNothing() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChatTranscriptCache(directory: directory)
        #expect(!cache.confirm(key))
        cache.flush()
        #expect(cache.savedAt(for: key) == nil)
        #expect(cache.messages(for: key).isEmpty)
    }

    /// A key with no file is looked up on disk once: a later look answers from
    /// memory (the Console asks on every reconcile), until something saves it.
    @Test func aKeyKnownToHaveNoFileIsNotLookedForAgain() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChatTranscriptCache(directory: directory)
        #expect(cache.messages(for: key).isEmpty)

        // Another writer lands the file behind this instance's back.
        let other = ChatTranscriptCache(directory: directory)
        other.save(transcriptMessages(0..<2), for: key)
        other.flush()
        #expect(cache.messages(for: key).isEmpty)
        #expect(cache.savedAt(for: key) == nil)

        cache.save(transcriptMessages(0..<3), for: key)
        #expect(cache.messages(for: key) == transcriptMessages(0..<3))
        #expect(cache.savedAt(for: key) != nil)
    }

    /// herdr keeps a terminal's ids when another Agent takes it over: what was
    /// saved for one is none of the next one's, in memory and after a relaunch.
    @Test func aListSavedForAnotherIdentityIsNotShownAndIsReplacedNotMerged() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChatTranscriptCache(directory: directory)
        cache.save(transcriptMessages(0..<4), for: key, identity: "s:a")
        cache.flush()

        #expect(cache.messages(for: key, identity: "s:a") == transcriptMessages(0..<4))
        #expect(cache.messages(for: key, identity: "s:b").isEmpty)
        #expect(cache.savedAt(for: key, identity: "s:b") == nil)
        #expect(!cache.confirm(key, identity: "s:b"), "another Agent's copy is not confirmed")
        #expect(cache.messages(for: key).isEmpty, "no identity is an identity too")

        // The same list under the next identity is still a write, not a no-op.
        cache.save(transcriptMessages(0..<4), for: key, identity: "s:b")
        cache.flush()
        #expect(cache.messages(for: key, identity: "s:b") == transcriptMessages(0..<4))
        #expect(cache.messages(for: key, identity: "s:a").isEmpty)

        let relaunched = ChatTranscriptCache(directory: directory)
        #expect(relaunched.messages(for: key, identity: "s:a").isEmpty)
        #expect(relaunched.messages(for: key, identity: "s:b") == transcriptMessages(0..<4))
    }

    @Test func removingAKeyForgetsOnlyThatLaunchsList() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = ChatTranscriptCache.Key(
            hostID: key.hostID, paneID: key.paneID, terminalID: "t2", launchedAt: "")
        let cache = ChatTranscriptCache(directory: directory)
        cache.save(transcriptMessages(0..<2), for: key)
        cache.save(transcriptMessages(2..<4), for: other)
        cache.flush()

        cache.remove(key)
        cache.flush()

        #expect(cache.messages(for: key).isEmpty)
        #expect(cache.savedAt(for: key) == nil)
        let relaunched = ChatTranscriptCache(directory: directory)
        #expect(relaunched.messages(for: key).isEmpty)
        #expect(relaunched.messages(for: other) == transcriptMessages(2..<4))
    }
}

/// The bounded background reads that keep recently finished Agents' copies fresh.
@MainActor
@Suite("Chat transcript prefetch", .timeLimit(.minutes(1)))
struct ChatTranscriptPrefetcherTests {
    private let hostA = Host.fixture(id: UUID(), name: "alpha")
    private let hostB = Host.fixture(id: UUID(), name: "bravo")

    private func agent(
        _ host: Host, _ pane: String, seq: Int, status: AgentStatus = .idle,
        kind: String = "claude"
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host.id, hostName: host.displayName,
            agent: Agent(
                terminalID: "term_\(pane)", kind: kind, title: "Task", status: status,
                workspaceID: "w1", tabID: "w1:t1", paneID: pane, cwd: "/work", revision: 1,
                stateChangeSeq: seq),
            workspaceLabel: nil, repositoryCheckout: nil)
    }

    /// The Console's side of the prefetcher, as the test sets it.
    @MainActor
    private final class Probe {
        var agents: [ConsoleAgent] = []
        var unreadable: Set<String> = []
        var savedAt: [String: Date] = [:]
        var isActive = true
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var failures: [String: any Error] = [:]
        /// Holds a read until the test lets it go (or it is cancelled).
        var holds: Set<String> = []
        private(set) var fetched: [String] = []
        private(set) var inFlight = 0
        private(set) var mostInFlight = 0
        private(set) var cancelled: [String] = []

        func fetch(_ agent: ConsoleAgent) async throws {
            let pane = agent.agent.paneID
            fetched.append(pane)
            inFlight += 1
            mostInFlight = max(mostInFlight, inFlight)
            defer { inFlight -= 1 }
            while holds.contains(pane) {
                do { try await Task.sleep(for: .milliseconds(2)) } catch {
                    cancelled.append(pane)
                    throw error
                }
            }
            for _ in 0..<3 { await Task.yield() }
            if let failure = failures[pane] { throw failure }
            savedAt[pane] = now
        }
    }

    @Test func returningDuringCooldownKeepsAWakeForTheNextRead() async throws {
        let probe = Probe()
        probe.agents = [agent(hostA, "w1:p1", seq: 1)]
        probe.savedAt["w1:p1"] = probe.now
        let (sleeps, sleeping) = AsyncStream.makeStream(of: Void.self)
        let (ticks, tick) = AsyncStream.makeStream(of: Void.self)
        let prefetcher = ChatTranscriptPrefetcher(source: .init(
            isActive: { probe.isActive }, agents: { probe.agents }, canRead: { _ in true },
            savedAt: { probe.savedAt[$0.agent.paneID] },
            fetch: { try await probe.fetch($0) }, now: { probe.now },
            sleep: { _ in
                sleeping.yield(())
                for await _ in ticks { break }
            }))
        defer { prefetcher.cancel(); tick.finish() }
        probe.isActive = false
        prefetcher.update()
        probe.isActive = true
        prefetcher.update()
        // A wake must be installed even though no copy is due yet.
        var wakeArmed = false
        let observe = Task {
            for await _ in sleeps { wakeArmed = true; break }
        }
        defer { observe.cancel() }
        try await waitUntilTrue("foreground re-arms the cooldown wake") { wakeArmed }
        probe.now += 601
        tick.yield(())
        try await waitUntilTrue("the wake fetches without another update") {
            probe.fetched == ["w1:p1"]
        }
    }

    private func makePrefetcher(_ probe: Probe) -> ChatTranscriptPrefetcher {
        ChatTranscriptPrefetcher(
            source: .init(
                isActive: { probe.isActive },
                agents: { probe.agents },
                canRead: { !probe.unreadable.contains($0.agent.paneID) },
                savedAt: { probe.savedAt[$0.agent.paneID] },
                fetch: { try await probe.fetch($0) },
                now: { probe.now },
                // The looking-again wait never ends inside a test.
                sleep: { _ in try await Task.sleep(for: .seconds(3600)) }))
    }

    // MARK: Selection

    @Test func theEightNewestFinishedAgentsAreChosen() {
        var agents = (1...12).map { agent(hostA, "w1:p\($0)", seq: $0) }
        agents.append(agent(hostA, "w1:working", seq: 100, status: .working))
        agents.append(agent(hostA, "w1:blocked", seq: 101, status: .blocked))
        agents.append(agent(hostA, "w1:unknown", seq: 102, status: .unknown))
        agents.append(agent(hostA, "w1:done", seq: 50, status: .done))
        let shell = ConsoleAgent(
            hostID: hostA.id, hostName: "alpha",
            agent: Agent(
                terminalID: "t", kind: Agent.shellKind, title: "zsh", status: .idle,
                workspaceID: "w1", tabID: "w1:t1", paneID: "w1:shell", cwd: "/", revision: 1,
                stateChangeSeq: 200),
            workspaceLabel: nil, repositoryCheckout: nil)
        agents.append(shell)

        let chosen = ChatTranscriptPrefetcher.newestFinished(agents) { _ in true }

        #expect(
            chosen.map(\.agent.paneID)
                == ["w1:done", "w1:p12", "w1:p11", "w1:p10", "w1:p9", "w1:p8", "w1:p7", "w1:p6"])
    }

    @Test func agentsTheConsoleCannotReadDoNotUseUpAPlace() {
        let agents = (1...10).map { agent(hostA, "w1:p\($0)", seq: $0) }
        let chosen = ChatTranscriptPrefetcher.newestFinished(agents) {
            $0.agent.paneID != "w1:p10" && $0.agent.paneID != "w1:p9"
        }
        #expect(chosen.map(\.agent.paneID).first == "w1:p8")
        #expect(chosen.count == 8)
    }

    @Test func hostsTakeTurnsSoOneBusyHostDoesNotUseEveryPlace() {
        var agents = (1...10).map { agent(hostA, "a\($0)", seq: 100 + $0) }
        agents.append(agent(hostB, "b1", seq: 2))
        agents.append(agent(hostB, "b2", seq: 1))

        let chosen = ChatTranscriptPrefetcher.newestFinished(agents) { _ in true }

        #expect(chosen.map(\.agent.paneID) == ["a10", "b1", "a9", "b2", "a8", "a7", "a6", "a5"])
    }

    // MARK: Reading

    @Test func readsOneAtATimeNewestFirstAndSkipsFreshCopies() async throws {
        let probe = Probe()
        probe.agents = [
            agent(hostA, "w1:p1", seq: 1), agent(hostA, "w1:p2", seq: 2),
            agent(hostA, "w1:p3", seq: 3),
        ]
        // Saved a minute ago: within the ten it stays fresh for.
        probe.savedAt["w1:p2"] = probe.now.addingTimeInterval(-60)
        let prefetcher = makePrefetcher(probe)
        defer { prefetcher.cancel() }

        prefetcher.update()
        try await waitUntilTrue("both stale copies should be read") { probe.fetched.count == 2 }
        try await Task.sleep(for: .milliseconds(30))

        #expect(probe.fetched == ["w1:p3", "w1:p1"])
        #expect(probe.mostInFlight == 1)
    }

    @Test func aCopyOlderThanTenMinutesIsReadAgain() async throws {
        let probe = Probe()
        probe.agents = [agent(hostA, "w1:p1", seq: 1)]
        probe.savedAt["w1:p1"] = probe.now.addingTimeInterval(-11 * 60)
        let prefetcher = makePrefetcher(probe)
        defer { prefetcher.cancel() }

        prefetcher.update()
        try await waitUntilTrue("the stale copy should be read") { probe.fetched == ["w1:p1"] }
    }

    @Test func aFailingAgentWaitsOutItsCooldownInsteadOfBeingRetried() async throws {
        let probe = Probe()
        probe.agents = [agent(hostA, "w1:p1", seq: 1), agent(hostA, "w1:p2", seq: 2)]
        probe.failures["w1:p2"] = ChatTranscriptError.malformedOutput
        let prefetcher = makePrefetcher(probe)
        defer { prefetcher.cancel() }

        prefetcher.update()
        try await waitUntilTrue("each agent should be tried once") { probe.fetched.count == 2 }
        // Every later change of the Console asks again.
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(10))
            prefetcher.update()
        }
        #expect(probe.fetched == ["w1:p2", "w1:p1"])

        probe.now = probe.now.addingTimeInterval(11 * 60)
        prefetcher.update()
        try await waitUntilTrue("the cooldown should end") { probe.fetched.count >= 4 }
        // Both are due again: the failing one, and the one read, its copy now stale.
        #expect(Array(probe.fetched.suffix(2)) == ["w1:p2", "w1:p1"])
    }

    @Test func aHostWhosePluginCannotReadIsLeftAloneForTheCooldown() async throws {
        let probe = Probe()
        probe.agents = [
            agent(hostA, "a1", seq: 5), agent(hostA, "a2", seq: 4), agent(hostA, "a3", seq: 3),
            agent(hostB, "b1", seq: 2),
        ]
        for pane in ["a1", "a2", "a3"] {
            probe.failures[pane] = ChatTranscriptError.readerUnavailable
        }
        let prefetcher = makePrefetcher(probe)
        defer { prefetcher.cancel() }

        prefetcher.update()
        try await waitUntilTrue("the other Host should be read") { probe.fetched.contains("b1") }
        try await Task.sleep(for: .milliseconds(30))

        #expect(probe.fetched == ["a1", "b1"], "one failed read stands for the whole Host")
    }

    @Test func leavingTheForegroundStopsTheReadAndStartsNoMore() async throws {
        let probe = Probe()
        probe.agents = [agent(hostA, "w1:p1", seq: 2), agent(hostA, "w1:p2", seq: 1)]
        probe.holds = ["w1:p1"]
        let prefetcher = makePrefetcher(probe)
        defer { prefetcher.cancel() }

        prefetcher.update()
        try await waitUntilTrue("the first read should be under way") { probe.inFlight == 1 }
        probe.isActive = false
        prefetcher.update()
        try await waitUntilTrue("the read should be cancelled") { probe.cancelled == ["w1:p1"] }
        try await Task.sleep(for: .milliseconds(30))

        #expect(probe.fetched == ["w1:p1"])
        #expect(probe.inFlight == 0)

        // Back in the foreground the unread agent is read; the cancelled one
        // counts as tried and waits out its cooldown.
        probe.holds = []
        probe.isActive = true
        prefetcher.update()
        try await waitUntilTrue("the next agent should be read") { probe.fetched.contains("w1:p2") }
        #expect(probe.fetched == ["w1:p1", "w1:p2"])
    }

    @Test func nothingIsReadWhileTheAppIsNotActive() async throws {
        let probe = Probe()
        probe.isActive = false
        probe.agents = [agent(hostA, "w1:p1", seq: 1)]
        let prefetcher = makePrefetcher(probe)
        defer { prefetcher.cancel() }

        prefetcher.update()
        try await Task.sleep(for: .milliseconds(40))

        #expect(probe.fetched.isEmpty)
    }
}
