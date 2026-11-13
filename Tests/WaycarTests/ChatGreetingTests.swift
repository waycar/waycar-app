import Foundation
import Testing

@testable import Waycar

@Suite("Chat greeting")
struct ChatGreetingTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func start(hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: hour))!
    }

    private static let seeds = (0..<50).map { "host|pane-\($0)|term-\($0)|\(1_790_000_000 + $0)" }

    @Test func sameSeedAndStartGiveSameText() {
        let start = Self.start(hour: 9)
        let first = ChatGreeting.text(seed: "a|b|c|1", startedAt: start, calendar: Self.calendar)
        let second = ChatGreeting.text(seed: "a|b|c|1", startedAt: start, calendar: Self.calendar)
        #expect(first == second)
    }

    @Test func differentSeedsVary() {
        let start = Self.start(hour: 14)
        let texts = Set(Self.seeds.map {
            ChatGreeting.text(seed: $0, startedAt: start, calendar: Self.calendar)
        })
        #expect(texts.count >= 5)
    }

    @Test(arguments: [
        (8, ChatGreeting.morning),
        (14, ChatGreeting.afternoon),
        (19, ChatGreeting.evening),
        (23, ChatGreeting.lateNight),
        (3, ChatGreeting.lateNight),
    ])
    func startHourPicksItsPool(hour: Int, pool: [String]) {
        let allowed = Set(pool + ChatGreeting.anytime)
        let start = Self.start(hour: hour)
        var texts: [String] = []
        for seed in Self.seeds {
            let text = ChatGreeting.text(seed: seed, startedAt: start, calendar: Self.calendar)
            #expect(allowed.contains(text), "\(text) at \(hour):00")
            texts.append(text)
        }
        // The hour's own phrases come up too, not only the anytime ones.
        let usesHourPool = texts.contains(where: pool.contains)
        #expect(usesHourPool)
    }

    @Test func noStartUsesAnytimeOnly() {
        let allowed = Set(ChatGreeting.anytime)
        for seed in Self.seeds {
            let text = ChatGreeting.text(seed: seed, startedAt: nil, calendar: Self.calendar)
            #expect(allowed.contains(text))
        }
    }

    /// One chat keeps one greeting when the Host's copy of its marker,
    /// decoded from the wire, replaces the copy recorded at launch, on
    /// whatever millisecond the launch fell.
    @Test func hostCopyOfTheMarkerKeepsTheGreeting() throws {
        let id = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1")
        var changed: [Int] = []
        for millisecond in 0..<1000 {
            // Recorded at `Date()`'s full precision, here 0.4 ms past it.
            let launchedAt = Date(
                timeIntervalSinceReferenceDate: 812_751_797 + (Double(millisecond) + 0.4) / 1000)
            let local = ChatModeMarker(
                paneID: id.paneID, terminalID: "term_a", kind: "opencode", cwd: nil,
                session: nil, launchedAt: launchedAt)
            let hostCopy = try JSONDecoder().decode(
                ChatModeMarker.self, from: JSONEncoder().encode(local))
            let seeds = [local, hostCopy].map {
                ChatGreeting.seed(agentID: id, terminalID: "term_a", launchedAt: $0.launchedAt)
            }
            if seeds[0] != seeds[1] { changed.append(millisecond) }
        }
        #expect(changed.isEmpty, "\(changed.count) launches change greeting")
    }
}
