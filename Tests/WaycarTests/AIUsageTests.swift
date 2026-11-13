import Foundation
import Testing

@testable import Waycar

/// CodexBar's `usage --format json`, in the shape CodexBar 0.67 prints
/// (captured live over SSH, emails removed): compact, one array, windows
/// always present as keys even when null.
@Suite("AI Usage report decoding")
struct AIUsageReportDecodingTests {
    private static let codexAndClaude = #"""
        [{"provider":"codex","version":"0.157.1","source":"oauth","rateWindowLabels":{"primary":"Session","secondary":"Weekly"},"credits":{"remaining":0,"events":[],"updatedAt":"2026-09-26T16:13:03Z","balanceReadSucceeded":true,"creditsAvailable":false,"balanceIsWorkspace":false},"pace":{"primary":{"stage":"farBehind","deltaPercent":-49,"expectedUsedPercent":55,"willLastToReset":true,"summary":"49% in reserve"}},"usage":{"primary":{"usedPercent":6,"windowMinutes":300,"resetsAt":"2026-09-26T18:27:20Z","resetDescription":"2:27 PM"},"secondary":{"usedPercent":4,"windowMinutes":10080,"resetsAt":"2026-10-02T09:00:00Z"},"tertiary":null,"updatedAt":"2026-09-26T16:13:03Z","dataConfidence":"exact"}},{"provider":"claude","source":"web","rateWindowLabels":{"primary":"Session","secondary":"Weekly","tertiary":"Opus"},"usage":{"primary":{"usedPercent":35,"windowMinutes":300,"resetsAt":"2026-09-26T18:00:00Z"},"secondary":{"usedPercent":81,"windowMinutes":10080,"resetsAt":"2026-09-29T00:00:00Z"},"tertiary":{"usedPercent":12,"windowMinutes":10080},"extraRateWindows":[{"id":"fable","title":"Fable only","window":{"usedPercent":50,"windowMinutes":10080}},{"id":"spark","title":"Spark","window":{"usedPercent":0},"usageKnown":false}],"updatedAt":"2026-09-26T16:13:05Z"}}]
        """#

    @Test func decodesEveryWindowWithLabelsResetsAndPace() throws {
        let report = try AIUsageReport.decode(Data(Self.codexAndClaude.utf8))

        #expect(report.commandError == nil)
        #expect(report.providers.map(\.displayName) == ["Claude", "Codex"])
        let claude = try #require(report.providers.first)
        #expect(claude.windows.map(\.label) == ["Session", "Weekly", "Opus", "Fable only"])
        #expect(claude.windows.map(\.remainingPercent) == [65, 19, 88, 50])
        #expect(claude.errorMessage == nil)

        let codex = try #require(report.providers.last)
        let session = try #require(codex.windows.first)
        #expect(session.label == "Session")
        #expect(session.usedPercent == 6)
        #expect(session.resetsAt == Date(timeIntervalSince1970: 1_790_447_240))
        #expect(session.expectedUsedPercent == 55)
        #expect(session.displayPacePercent(showsUsed: false) == 45)
        #expect(session.displayPacePercent(showsUsed: true) == 55)
        let pace = try #require(session.pace)
        #expect(pace.stage == .farBehind)
        #expect(pace.deltaPercent == -49)
        #expect(pace.lastsUntilReset == true)
        #expect(pace.etaSeconds == nil)
        #expect(codex.windows[1].pace == nil)
        #expect(codex.windows[1].expectedUsedPercent == nil)
    }

    @Test func aWindowWhoseUsageIsUnknownIsNotShown() throws {
        let report = try AIUsageReport.decode(Data(Self.codexAndClaude.utf8))
        let claude = try #require(report.providers.first { $0.providerID == "claude" })
        #expect(!claude.windows.contains { $0.label == "Spark" })
    }

    @Test func aFailedProviderIsAnErrorRowBesideHealthyOnes() throws {
        let json = #"""
            [{"provider":"codex","source":"oauth","usage":{"primary":{"usedPercent":20,"windowMinutes":300},"secondary":null,"tertiary":null}},{"provider":"gemini","source":"auto","error":{"code":3,"kind":"provider","message":"Google no longer supports Gemini CLI OAuth"}}]
            """#
        let report = try AIUsageReport.decode(Data(json.utf8))

        #expect(report.commandError == nil)
        #expect(report.providers.map(\.providerID) == ["codex", "gemini"])
        let gemini = try #require(report.providers.last)
        #expect(gemini.windows.isEmpty)
        #expect(gemini.errorMessage == "Google no longer supports Gemini CLI OAuth")
    }

    /// Over SSH CodexBar cannot read the Host's login keychain; Claude's row
    /// then fails like this (captured live, CodexBar 0.67).
    @Test func aKeychainBlockedClaudeRowIsFlaggedAndOthersAreNot() throws {
        let json = #"""
            [{"provider":"claude","source":"auto","error":{"kind":"provider","code":1,"message":"No Claude session key found in browser cookies."}},{"provider":"codex","source":"oauth","usage":{"primary":{"usedPercent":20,"windowMinutes":300},"secondary":null,"tertiary":null}},{"provider":"gemini","source":"auto","error":{"code":3,"kind":"provider","message":"The request timed out."}}]
            """#
        let report = try AIUsageReport.decode(Data(json.utf8))

        #expect(report.fixableProviders.map(\.providerID) == ["claude"])
        let gemini = try #require(report.providers.first { $0.providerID == "gemini" })
        #expect(!gemini.isHostKeychainBlocked(onMacOS: true))
    }

    /// CodexBar 0.84 over SSH on a Mac without the helper (message captured
    /// live): Claude's row no longer names the cookies. On a Mac that is the
    /// keychain; elsewhere Claude is just not set up.
    private static let noFetchStrategyClaude = #"""
        [{"provider":"claude","source":"auto","error":{"kind":"provider","code":1,"message":"No available fetch strategy for claude."}},{"provider":"codex","source":"oauth","usage":{"primary":{"usedPercent":20,"windowMinutes":300}}}]
        """#

    @Test func noFetchStrategyForClaudeOnAMacIsKeychainBlocked() throws {
        let output = "\(CodexBarCommand.macOSHostMarker)\n\(CodexBarCommand.cliBaseStartMarker)\n"
            + "\(Self.noFetchStrategyClaude)\n\(CodexBarCommand.cliBaseEndMarker)\n"
        let report = try AIUsageReport.decode(Data(output.utf8))

        #expect(report.isMacOSHost)
        let claude = try #require(report.providers.first { $0.providerID == "claude" })
        #expect(report.fixableProblem(claude) == .keychainBlocked)
        #expect(report.fixableProviders.map(\.providerID) == ["claude"])
    }

    @Test func noFetchStrategyForClaudeOffAMacIsNotFlagged() throws {
        let output = "\(CodexBarCommand.cliBaseStartMarker)\n\(Self.noFetchStrategyClaude)\n"
            + "\(CodexBarCommand.cliBaseEndMarker)\n"
        let report = try AIUsageReport.decode(Data(output.utf8))

        #expect(!report.isMacOSHost)
        #expect(report.fixableProviders.isEmpty)
    }

    /// A `codexbar serve` with CodexBar's default 30-second request timeout
    /// gives Claude 24 seconds, then answers its row like this (captured
    /// live, CodexBar 0.84.0); the fix gives the helper a longer timeout.
    private static let serverTimedOutClaude = #"""
        [{"provider":"codex","source":"oauth","usage":{"primary":{"usedPercent":20,"windowMinutes":300}}},{"provider":"claude","source":"auto","error":{"kind":"provider","code":1,"message":"claude usage timed out"}},{"provider":"gemini","source":"auto","error":{"kind":"provider","code":3,"message":"The request timed out."}}]
        """#

    @Test func aServerProviderTimeoutOffersToUpdateTheHelper() throws {
        let output = "\(CodexBarCommand.serverSourceMarker)\n\(Self.serverTimedOutClaude)\n"
        let report = try AIUsageReport.decode(Data(output.utf8))

        let claude = try #require(report.providers.first { $0.providerID == "claude" })
        #expect(report.fixableProblem(claude) == .serverTimedOut)
        #expect(report.fixableProviders.map(\.providerID) == ["claude"])
    }

    /// Only a server gives providers its request timeout; the same words from
    /// the CLI are no reason to touch the helper.
    @Test func aCLIProviderTimeoutIsNotFlagged() throws {
        let report = try AIUsageReport.decode(Data(Self.serverTimedOutClaude.utf8))
        #expect(report.source == .cli)
        #expect(report.fixableProviders.isEmpty)
    }

    /// Rows are matched by account, not by provider: one locked-out codex
    /// account must not put the Keychain Fix on its healthy sibling.
    @Test func aBlockedAccountDoesNotFlagItsHealthySibling() throws {
        let json = #"""
            [{"provider":"codex","account":"a","usage":{"primary":{"usedPercent":20,"windowMinutes":300}}},{"provider":"codex","account":"b","source":"auto","error":{"kind":"provider","code":1,"message":"User interaction is not allowed."}}]
            """#
        let report = try AIUsageReport.decode(Data(json.utf8))
        let healthy = try #require(report.providers.first { $0.id == "codex:a" })
        let blocked = try #require(report.providers.first { $0.id == "codex:b" })

        #expect(report.fixableProblem(healthy) == nil)
        #expect(report.fixableProblem(blocked) == .keychainBlocked)
        #expect(report.fixableProviders.map(\.id) == ["codex:b"])
    }

    private static func cliReport(error: String) -> (AIUsageReport, AIUsageProvider) {
        let provider = AIUsageProvider(
            id: "claude", providerID: "claude", displayName: "Claude", account: nil,
            windows: [], errorMessage: error)
        return (AIUsageReport(providers: [provider], commandError: nil), provider)
    }

    @Test(arguments: [
        "User interaction is not allowed.",
        "The KEYCHAIN IS UNAVAILABLE",
        "keychain not available",
        "Keychain is not available",
        "keychain unavailable",
    ])
    func keychainFailuresAreFlaggedInAnyCase(error: String) {
        let (report, provider) = Self.cliReport(error: error)
        #expect(report.fixableProblem(provider) == .keychainBlocked)
    }

    @Test(arguments: [
        "Claude usage endpoint returned 401",
        "No Claude session found",
        "The request timed out.",
        "No available fetch strategy for claude.",
    ])
    func otherFailuresAreNotFlagged(error: String) {
        let (report, provider) = Self.cliReport(error: error)
        #expect(report.fixableProblem(provider) == nil)
    }

    private static let keychainBlockedClaude = #"""
        [{"provider":"claude","source":"auto","error":{"kind":"provider","code":1,"message":"No Claude session key found in browser cookies."}}]
        """#

    /// A server runs in the GUI session, where the keychain is reachable: its
    /// errors are shown as they are, never as the SSH keychain problem.
    @Test func aServerAnswerIsNeverKeychainBlocked() throws {
        let output = "\(CodexBarCommand.serverSourceMarker)\n\(Self.keychainBlockedClaude)\n"
        let report = try AIUsageReport.decode(Data(output.utf8))
        #expect(report.source == .server)
        #expect(report.providers.map(\.providerID) == ["claude"])
        #expect(report.fixableProviders.isEmpty)
    }

    @Test func aCLIAnswerCanBeKeychainBlocked() throws {
        let report = try AIUsageReport.decode(Data(Self.keychainBlockedClaude.utf8))
        #expect(report.source == .cli)
        #expect(report.fixableProviders.map(\.providerID) == ["claude"])
    }

    /// Login-shell noise before the marker, even a line that looks like an
    /// array, is not the report.
    @Test func noiseBeforeTheServerMarkerIsIgnored() throws {
        let output = "Welcome to studio!\n[motd] rc sourced\n\(CodexBarCommand.serverSourceMarker)\n"
            + #"[{"provider":"codex","usage":{"primary":{"usedPercent":30,"windowMinutes":300}}}]"#
            + "\n"
        let report = try AIUsageReport.decode(Data(output.utf8))
        #expect(report.source == .server)
        #expect(report.providers.map(\.providerID) == ["codex"])
    }

    @Test func aServerMarkerWithNothingAfterItIsAnError() {
        #expect(throws: AIUsageDecodingError.noJSONArray) {
            try AIUsageReport.decode(
                Data("[{\"provider\":\"codex\"}]\n\(CodexBarCommand.serverSourceMarker)\n".utf8))
        }
    }

    /// A CLI array printed before the marker loses to the server's answer.
    @Test func theServersAnswerWinsOverACLIArrayBeforeIt() throws {
        let output = "\(Self.keychainBlockedClaude)\n\(CodexBarCommand.serverSourceMarker)\n"
            + #"[{"provider":"codex","usage":{"primary":{"usedPercent":30,"windowMinutes":300}}}]"#
        let report = try AIUsageReport.decode(Data(output.utf8))
        #expect(report.source == .server)
        #expect(report.providers.map(\.providerID) == ["codex"])
        #expect(report.fixableProviders.isEmpty)
    }

    /// A server answers with its last report while it rebuilds, so the data
    /// is as old as its oldest provider, never newer than the fetch.
    @Test func aServerAnswerIsDatedByItsOldestProvider() throws {
        let json = #"""
            [{"provider":"codex","usage":{"primary":{"usedPercent":20,"windowMinutes":300},"updatedAt":"2026-09-26T16:13:03Z"}},{"provider":"claude","usage":{"primary":{"usedPercent":5,"windowMinutes":300},"updatedAt":"2026-09-26T16:12:03Z"}}]
            """#
        let finishedAt = Date(timeIntervalSince1970: 1_790_443_000)
        let server = try AIUsageReport.decode(
            Data("\(CodexBarCommand.serverSourceMarker)\n\(json)".utf8))
        #expect(server.dataDate(finishedAt: finishedAt) == Date(timeIntervalSince1970: 1_790_439_123))
        let early = Date(timeIntervalSince1970: 1_790_439_000)
        #expect(server.dataDate(finishedAt: early) == early)
        let cli = try AIUsageReport.decode(Data(json.utf8))
        #expect(cli.dataDate(finishedAt: finishedAt) == finishedAt)
    }

    @Test func paceDecodesStageDeltaOutlookAndToleratesAnUnknownStage() throws {
        let json = #"""
            [{"provider":"codex","source":"oauth","rateWindowLabels":{"primary":"Session","secondary":"Weekly"},"pace":{"primary":{"stage":"onTrack","deltaPercent":-1,"expectedUsedPercent":20,"willLastToReset":true},"secondary":{"stage":"veryAhead","deltaPercent":9,"expectedUsedPercent":56,"etaSeconds":182235,"willLastToReset":false}},"usage":{"primary":{"usedPercent":19,"windowMinutes":300},"secondary":{"usedPercent":65,"windowMinutes":10080}}}]
            """#
        let report = try AIUsageReport.decode(Data(json.utf8))

        let windows = try #require(report.providers.first?.windows)
        #expect(windows[0].pace?.stage == .onTrack)
        #expect(windows[0].pace?.deltaPercent == -1)
        #expect(windows[0].pace?.lastsUntilReset == true)
        #expect(windows[0].pace?.etaSeconds == nil)
        // A stage this build does not know costs only the stage.
        #expect(windows[1].pace?.stage == nil)
        #expect(windows[1].pace?.deltaPercent == 9)
        #expect(windows[1].pace?.etaSeconds == 182235)
        #expect(windows[1].pace?.lastsUntilReset == false)
        #expect(windows[1].expectedUsedPercent == 56)
    }

    @Test func theCLIEntryIsACommandErrorNotAProvider() throws {
        let json = #"""
            [{"provider":"cli","source":"cli","error":{"code":64,"message":"Unknown option --nope","kind":"args"}}]
            """#
        let report = try AIUsageReport.decode(Data(json.utf8))

        #expect(report.providers.isEmpty)
        #expect(report.commandError == "Unknown option --nope")
    }

    @Test func unknownAndRetypedFieldsCostOnlyThemselves() throws {
        let json = #"""
            [{"provider":"claude","futureField":{"nested":[1,2,3]},"account":42,"rateWindowLabels":"not an object","pace":[],"usage":{"primary":{"usedPercent":40,"windowMinutes":"300","resetsAt":12345,"shiny":true},"secondary":{"usedPercent":"lots"},"extraRateWindows":[7,{"id":"x","title":"Extra","window":{"usedPercent":10}}]}},"not a payload",{"source":"api"}]
            """#
        let report = try AIUsageReport.decode(Data(json.utf8))

        let claude = try #require(report.providers.first)
        #expect(report.providers.count == 1)
        #expect(claude.account == nil)
        // windowMinutes retyped to a string: the label falls back to the slot.
        #expect(claude.windows.map(\.label) == ["Primary", "Extra"])
        #expect(claude.windows.first?.resetsAt == nil)
    }

    @Test func usedPercentOutside0To100IsClamped() throws {
        let json = #"""
            [{"provider":"codex","usage":{"primary":{"usedPercent":137.5,"windowMinutes":300},"secondary":{"usedPercent":-4,"windowMinutes":10080}}}]
            """#
        let report = try AIUsageReport.decode(Data(json.utf8))
        let codex = try #require(report.providers.first)

        #expect(codex.windows.map(\.usedPercent) == [100, 0])
        #expect(codex.windows.map(\.remainingPercent) == [0, 100])
    }

    @Test func aProviderWithNeitherWindowsNorErrorIsOmitted() throws {
        let json = #"""
            [{"provider":"openrouter","source":"api","usage":{"primary":null,"secondary":null,"tertiary":null,"details":[{"rows":[{"label":"Balance","value":"$4.20"}]}]}},{"provider":"codex","usage":{"primary":{"usedPercent":1}}}]
            """#
        let report = try AIUsageReport.decode(Data(json.utf8))
        #expect(report.providers.map(\.providerID) == ["codex"])
    }

    @Test func loginShellNoiseAroundTheArrayIsSkipped() throws {
        let output = "Welcome to studio!\n[warn] rc sourced\n"
            + #"[{"provider":"codex","usage":{"primary":{"usedPercent":30,"windowMinutes":300}}}]"#
            + "\n"
        let report = try AIUsageReport.decode(Data(output.utf8))
        #expect(report.providers.first?.windows.first?.remainingPercent == 70)
    }

    @Test func outputWithoutAnArrayIsAnError() {
        #expect(throws: AIUsageDecodingError.noJSONArray) {
            try AIUsageReport.decode(Data("zsh: command not found: codexbar\n".utf8))
        }
    }

    @Test func twoAccountsKeepTheirLabelsAndIndependentUsageBesideOtherProviders() throws {
        let json = #"""
            [{"provider":"codex","account":"Work","usage":{"primary":{"usedPercent":10,"windowMinutes":300},"secondary":{"usedPercent":35,"windowMinutes":10080}}},{"provider":"codex","account":"Personal","usage":{"primary":{"usedPercent":70,"windowMinutes":300},"secondary":{"usedPercent":80,"windowMinutes":10080}}},{"provider":"claude","usage":{"primary":{"usedPercent":25,"windowMinutes":300}}}]
            """#
        let report = try AIUsageReport.decode(Data(json.utf8))
        let codex = report.providers.filter { $0.providerID == "codex" }
        #expect(codex.count == 2)
        #expect(Set(codex.map(\.id)).count == 2)
        let work = try #require(codex.first { $0.account == "Work" })
        let personal = try #require(codex.first { $0.account == "Personal" })
        #expect(work.windows.map(\.remainingPercent) == [90, 65])
        #expect(personal.windows.map(\.remainingPercent) == [30, 20])
        #expect(report.providers.first?.id == personal.id)
        #expect(report.providers.first { $0.providerID == "claude" }?.windows.first?.remainingPercent == 75)
        #expect(report.commandError == nil)
    }

    @Test func accountIdentitySurvivesDuplicateLabelsReorderingAndRenaming() throws {
        let work = #"{"provider":"codex","account":"Shared","cacheAccountKey":"fake-work","usage":{"primary":{"usedPercent":10}}}"#
        let personal = #"{"provider":"codex","account":"Shared","cacheAccountKey":"fake-personal","usage":{"primary":{"usedPercent":70}}}"#
        let first = try AIUsageReport.decode(Data("[\(work),\(personal)]".utf8))
        let reversed = try AIUsageReport.decode(Data("[\(personal),\(work)]".utf8))
        #expect(first.providers.count == 2)
        #expect(Set(first.providers.map(\.id)).count == 2)
        for row in first.providers {
            let after = try #require(reversed.providers.first { $0.id == row.id })
            #expect(after.account == "Shared")
            #expect(after.windows == row.windows)
        }
        let renamed = try AIUsageReport.decode(Data(
            "[\(personal),\(work.replacingOccurrences(of: "Shared", with: "Work"))]".utf8))
        let workBefore = try #require(first.providers.first { $0.windows.first?.usedPercent == 10 })
        let workAfter = try #require(renamed.providers.first { $0.account == "Work" })
        #expect(workAfter.id == workBefore.id)
        #expect(workAfter.windows == workBefore.windows)
    }

    @Test func unlabeledAccountsGetDistinctStableLabelsWithoutExposingOpaqueKeys() throws {
        let work = #"{"provider":"codex","cacheAccountKey":"fake-private-work","usage":{"primary":{"usedPercent":10}}}"#
        let personal = #"{"provider":"codex","cacheAccountKey":"fake-private-personal","usage":{"primary":{"usedPercent":70}}}"#
        let report = try AIUsageReport.decode(Data("[\(work),\(personal)]".utf8))
        let reversed = try AIUsageReport.decode(Data("[\(personal),\(work)]".utf8))
        #expect(report.providers.count == 2)
        #expect(Set(report.providers.compactMap(\.account)).count == 2)
        for row in report.providers {
            let label = try #require(row.account)
            #expect(!label.isEmpty)
            #expect(!label.contains("fake-private"))
            #expect(reversed.providers.first { $0.id == row.id }?.account == label)
        }
    }

    private static let baseAccounts = #"""
        [{"provider":"codex","account":"Work","cacheAccountKey":"fake-work","usage":{"primary":{"usedPercent":20}}},{"provider":"claude","usage":{"primary":{"usedPercent":35}}}]
        """#
    private static let allCodexAccounts = #"""
        [{"provider":"codex","account":"Work","cacheAccountKey":"fake-work","usage":{"primary":{"usedPercent":10}}},{"provider":"codex","account":"Personal","cacheAccountKey":"fake-personal","usage":{"primary":{"usedPercent":70}}}]
        """#

    private static func cliOutput(
        base: String = AIUsageReportDecodingTests.baseAccounts, supplement: String, status: Int? = 0
    ) -> Data {
        let end = status.map { "\(CodexBarCommand.codexAccountsEndMarker) \($0)\n" } ?? ""
        return Data(("""
            Login shell noise
            \(CodexBarCommand.cliBaseStartMarker)
            \(base)
            \(CodexBarCommand.cliBaseEndMarker)
            \(CodexBarCommand.codexAccountsStartMarker)
            \(supplement)
            \(end)
            """).utf8)
    }

    @Test func aCompleteSupplementReplacesOnlyCodexWithBothAccounts() throws {
        let report = try AIUsageReport.decode(Self.cliOutput(supplement: Self.allCodexAccounts))
        #expect(report.source == .cli)
        #expect(report.providers.count == 3)
        let codex = report.providers.filter { $0.providerID == "codex" }
        #expect(Set(codex.compactMap(\.account)) == ["Work", "Personal"])
        #expect(codex.first { $0.account == "Work" }?.windows.first?.usedPercent == 10)
        #expect(codex.first { $0.account == "Personal" }?.windows.first?.usedPercent == 70)
        #expect(report.providers.first { $0.providerID == "claude" }?.windows.first?.usedPercent == 35)
        #expect(report.commandError == nil)
    }

    @Test(arguments: [
        (#"[{"provider":"cli","error":{"message":"Unknown option --all-accounts"}}]"#, 64 as Int?),
        ("", 143),
        ("not JSON", 0),
        (AIUsageReportDecodingTests.allCodexAccounts, nil),
    ])
    func anUnusableSupplementKeepsTheBaseReport(supplement: String, status: Int?) throws {
        let report = try AIUsageReport.decode(Self.cliOutput(supplement: supplement, status: status))
        let base = try AIUsageReport.decode(Data(Self.baseAccounts.utf8))
        #expect(report.providers == base.providers)
        #expect(report.commandError == nil)
    }

    @Test func aPartialSupplementNeverReplacesWorkingUsageWithAnAccountError() throws {
        let supplement = #"""
            [{"provider":"codex","account":"Work","cacheAccountKey":"fake-work","error":{"message":"The request timed out."}},{"provider":"codex","account":"Personal","cacheAccountKey":"fake-personal","usage":{"primary":{"usedPercent":70}}}]
            """#
        let report = try AIUsageReport.decode(Self.cliOutput(supplement: supplement, status: 1))
        let work = try #require(report.providers.first { $0.account == "Work" })
        #expect(work.windows.first?.usedPercent == 20)
        #expect(work.errorMessage == nil)
        #expect(report.providers.first { $0.account == "Personal" }?.windows.first?.usedPercent == 70)
        #expect(report.providers.first { $0.providerID == "claude" }?.windows.first?.usedPercent == 35)
        #expect(report.commandError == nil)
    }

    @Test(arguments: [
        #"{"provider":"codex","account":"Work","cacheAccountKey":"fake-work","usage":{"primary":{"usedPercent":"unknown"}}}"#,
        "null",
        "42",
    ])
    func anIncompleteSupplementCannotDropAWorkingAccount(unusableEntry: String) throws {
        let personal = #"{"provider":"codex","account":"Personal","cacheAccountKey":"fake-personal","usage":{"primary":{"usedPercent":70}}}"#
        let report = try AIUsageReport.decode(Self.cliOutput(
            supplement: "[\(unusableEntry),\(personal)]", status: 0))
        let base = try AIUsageReport.decode(Data(Self.baseAccounts.utf8))
        #expect(report.providers == base.providers)
        #expect(report.commandError == nil)
    }

    @Test func aCompleteInventoryReplacesAnAnonymousBaseWithoutDuplicatingAccounts() throws {
        let base = #"""
            [{"provider":"codex","usage":{"primary":{"usedPercent":20}}},{"provider":"claude","usage":{"primary":{"usedPercent":35}}}]
            """#
        let supplement = #"""
            [{"provider":"codex","account":"Work","cacheAccountKey":"fake-work","usage":{"primary":{"usedPercent":10}}},{"provider":"codex","account":"Personal","cacheAccountKey":"fake-personal","error":{"message":"The request timed out."}}]
            """#
        let report = try AIUsageReport.decode(
            Self.cliOutput(base: base, supplement: supplement, status: 1))
        let codex = report.providers.filter { $0.providerID == "codex" }
        #expect(codex.count == 2)
        #expect(Set(codex.compactMap(\.account)) == ["Work", "Personal"])
        #expect(codex.first { $0.account == "Work" }?.windows.first?.usedPercent == 10)
        let personal = try #require(codex.first { $0.account == "Personal" })
        #expect(personal.windows.isEmpty)
        #expect(personal.errorMessage == "The request timed out.")
        #expect(report.providers.first { $0.providerID == "claude" }?.windows.first?.usedPercent == 35)
        #expect(report.commandError == nil)
    }

    @Test func duplicateInventoryLabelsCannotAssignLegacyUsageToTheWrongAccount() throws {
        let base = #"""
            [{"provider":"codex","account":"Shared","usage":{"primary":{"usedPercent":20}}}]
            """#
        let supplement = #"""
            [{"provider":"codex","account":"Shared","cacheAccountKey":"fake-a","error":{"message":"The request timed out."}},{"provider":"codex","account":"Shared","cacheAccountKey":"fake-b","usage":{"primary":{"usedPercent":70}}}]
            """#
        let report = try AIUsageReport.decode(
            Self.cliOutput(base: base, supplement: supplement, status: 1))
        let codex = report.providers.filter { $0.providerID == "codex" }
        #expect(codex.count == 2)
        #expect(codex.allSatisfy { $0.account == "Shared" })
        let failed = try #require(codex.first { $0.id == "codex:fake-a" })
        #expect(failed.windows.isEmpty)
        #expect(failed.errorMessage == "The request timed out.")
        let healthy = try #require(codex.first { $0.id == "codex:fake-b" })
        #expect(healthy.windows.first?.usedPercent == 70)
        #expect(healthy.errorMessage == nil)
        #expect(report.commandError == nil)
    }

    @Test func aSupplementCannotReenableCodexAbsentFromTheBaseReport() throws {
        let base = #"[{"provider":"claude","usage":{"primary":{"usedPercent":35}}}]"#
        let report = try AIUsageReport.decode(
            Self.cliOutput(base: base, supplement: Self.allCodexAccounts))
        #expect(report.providers.map(\.providerID) == ["claude"])
        #expect(report.providers.first?.windows.first?.usedPercent == 35)
    }

    @Test(arguments: [
        (nil as Int?, "Primary"),
        (300, "5h"),
        (10080, "Weekly"),
        (1440, "1d"),
        (43200, "30d"),
        (60, "1h"),
        (720, "12h"),
        (90, "90m"),
        (0, "Primary"),
    ])
    func windowLabelFallsBackToTheWindowLength(minutes: Int?, expected: String) {
        #expect(
            AIUsageReport.windowLabel(explicit: nil, windowMinutes: minutes, fallback: "Primary")
                == expected)
    }

    @Test func anExplicitLabelWinsOverTheWindowLength() {
        #expect(
            AIUsageReport.windowLabel(explicit: "Session", windowMinutes: 10080, fallback: "Primary")
                == "Session")
        #expect(
            AIUsageReport.windowLabel(explicit: "  ", windowMinutes: 10080, fallback: "Primary")
                == "Weekly")
    }

    @Test func unknownProviderIdsAreCapitalizedAndKnownOnesMatchAnyCase() {
        #expect(AIUsageReport.displayName(forProviderID: "newthing") == "Newthing")
        #expect(AIUsageReport.displayName(forProviderID: "newThing") == "NewThing")
        #expect(
            AIUsageReport.displayName(forProviderID: "OPENROUTER")
                == AIUsageReport.displayName(forProviderID: "openrouter"))
    }
}

@Suite("AI Usage pace text")
struct AIUsagePaceTextTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private static func pace(
        stage: AIUsagePace.Stage? = nil, delta: Double? = nil,
        eta: Int? = nil, lasts: Bool? = nil
    ) -> AIUsagePace {
        AIUsagePace(stage: stage, deltaPercent: delta, etaSeconds: eta, lastsUntilReset: lasts)
    }

    private static func window(id: String = "w", label: String, minutes: Int?) -> AIUsageWindow {
        AIUsageWindow(
            id: id, label: label, usedPercent: 0, resetsAt: nil, expectedUsedPercent: nil,
            windowMinutes: minutes)
    }

    @Test func theSummaryReadsDeficitReserveOrOnPace() {
        #expect(Self.pace(delta: -49).summary == "49% in reserve")
        #expect(Self.pace(delta: 9).summary == "9% in deficit")
        #expect(Self.pace(stage: .farBehind, delta: -49).summary == "49% in reserve")
        #expect(Self.pace(stage: .farAhead, delta: 20).summary == "20% in deficit")
        #expect(Self.pace(delta: 0).summary == "On pace")
        #expect(Self.pace(delta: -0.4).summary == "On pace")
        #expect(Self.pace(stage: .onTrack, delta: -2).summary == "On pace")
        #expect(Self.pace(stage: .onTrack).summary == "On pace")
        #expect(Self.pace().summary == nil)
        #expect(Self.pace(stage: .ahead).summary == nil)
        #expect(Self.pace(delta: 1e300).summary == "100% in deficit")
        #expect(Self.pace(delta: -1e300).summary == "100% in reserve")
        #expect(Self.pace(delta: .infinity).summary == nil)
        #expect(Self.pace(stage: .onTrack, delta: .infinity).summary == "On pace")
    }

    @Test func theOutlookReadsTheProjection() {
        #expect(
            Self.pace(lasts: true).outlook(usesSessionWording: true, now: Self.now)
                == "Lasts until reset")
        #expect(
            Self.pace(eta: 187_200, lasts: false).outlook(usesSessionWording: false, now: Self.now)
                == "Runs out in 2d 4h")
        #expect(
            Self.pace(eta: 187_200, lasts: false).outlook(usesSessionWording: true, now: Self.now)
                == "Projected empty in 2d 4h")
        #expect(
            Self.pace(eta: 0, lasts: false).outlook(usesSessionWording: false, now: Self.now)
                == "Runs out now")
        #expect(
            Self.pace(eta: 0, lasts: false).outlook(usesSessionWording: true, now: Self.now)
                == "Projected empty now")
        #expect(
            Self.pace(lasts: false).outlook(usesSessionWording: false, now: Self.now)
                == "Runs out before reset")
        #expect(Self.pace().outlook(usesSessionWording: false, now: Self.now) == nil)
        #expect(Self.pace(eta: .max, lasts: false).outlook(usesSessionWording: false, now: Self.now)
            == nil)
        #expect(
            Self.pace(eta: 365 * 86_400 + 1, lasts: false)
                .outlook(usesSessionWording: false, now: Self.now) == nil)
        #expect(
            Self.pace(eta: 365 * 86_400, lasts: false)
                .outlook(usesSessionWording: false, now: Self.now) == "Runs out in 365d")
    }

    @Test func wordingContextFollowsTheSlot() {
        #expect(Self.window(id: "primary", label: "Session", minutes: 300).usesSessionPaceWording)
        #expect(!Self.window(id: "primary", label: "Weekly", minutes: 10080).usesSessionPaceWording)
        #expect(!Self.window(id: "secondary", label: "Weekly", minutes: 10080).usesSessionPaceWording)
        #expect(!Self.window(id: "tertiary", label: "Opus", minutes: 10080).usesSessionPaceWording)
        #expect(!Self.window(id: "extra:x", label: "30d", minutes: 43200).usesSessionPaceWording)
    }

    @Test func thePaceLineJoinsSummaryAndOutlook() {
        #expect(
            Self.pace(stage: .farBehind, delta: -49, lasts: true)
                .paceText(usesSessionWording: true, now: Self.now)
                == "49% in reserve · Lasts until reset")
        #expect(
            Self.pace(stage: .ahead, delta: 9, eta: 182_235, lasts: false)
                .paceText(usesSessionWording: false, now: Self.now)
                == "9% in deficit · Runs out in 2d 2h")
        #expect(Self.pace().paceText(usesSessionWording: true, now: Self.now) == nil)
    }

    @Test func weeklyIsTheLabelOrSevenDays() {
        #expect(Self.window(label: "Weekly", minutes: 300).isWeeklyWindow)
        #expect(Self.window(label: "Session", minutes: 10080).isWeeklyWindow)
        #expect(Self.window(label: "weekly", minutes: nil).isWeeklyWindow)
        #expect(!Self.window(label: "Session", minutes: 300).isWeeklyWindow)
    }
}

@Suite("AI Usage urgency")
struct AIUsageUrgencyTests {
    private static func provider(
        _ name: String, remaining: [Double], error: String? = nil
    ) -> AIUsageProvider {
        AIUsageProvider(
            id: name, providerID: name.lowercased(), displayName: name, account: nil,
            windows: remaining.enumerated().map { index, remaining in
                AIUsageWindow(
                    id: "w\(index)", label: "w\(index)", usedPercent: 100 - remaining,
                    resetsAt: nil, expectedUsedPercent: nil)
            },
            errorMessage: error)
    }

    @Test func providersSortByTheirLeastRemainingWindowWithErrorRowsLast() {
        let report = AIUsageReport(
            providers: [
                Self.provider("Gemini", remaining: [], error: "broken"),
                Self.provider("Codex", remaining: [90, 40]),
                Self.provider("Claude", remaining: [70, 12]),
                Self.provider("Amp", remaining: [40]),
            ],
            commandError: nil)

        #expect(report.providers.map(\.displayName) == ["Claude", "Amp", "Codex", "Gemini"])
    }

    private static func window(
        _ id: String, label: String, minutes: Int?, remaining: Double
    ) -> AIUsageWindow {
        AIUsageWindow(
            id: id, label: label, usedPercent: 100 - remaining, resetsAt: nil,
            expectedUsedPercent: nil, windowMinutes: minutes)
    }

    private static func provider(_ name: String, windows: [AIUsageWindow]) -> AIUsageProvider {
        AIUsageProvider(
            id: name, providerID: name.lowercased(), displayName: name, account: nil,
            windows: windows, errorMessage: nil)
    }

    @Test func theSessionPillNamesTheProviderWithTheLeastSessionLeftNotTheLeastWeekly() throws {
        let report = AIUsageReport(
            providers: [
                // Nearly out of weekly, plenty of session.
                Self.provider("Codex", windows: [
                    Self.window("primary", label: "Session", minutes: 300, remaining: 80),
                    Self.window("secondary", label: "Weekly", minutes: 10080, remaining: 5),
                ]),
                Self.provider("Claude", windows: [
                    Self.window("primary", label: "5h", minutes: 300, remaining: 30),
                    Self.window("secondary", label: "Weekly", minutes: 10080, remaining: 60),
                ]),
            ],
            commandError: nil)

        // The sheet still leads with the least remaining in any window.
        #expect(report.providers.first?.displayName == "Codex")
        var options = AIUsageDisplayOptions()
        options.pillWindow = .session
        let pill = try #require(report.pillSelection(options))
        #expect(pill.provider.displayName == "Claude")
        #expect(pill.windows.map(\.remainingPercent) == [30])
        #expect(pill.windows.first?.level == .normal)
    }

    @Test func withoutASessionWindowThePillUsesTheShortestWindow() {
        let provider = Self.provider("Amp", windows: [
            Self.window("secondary", label: "Weekly", minutes: 10080, remaining: 3),
            Self.window("primary", label: "Daily", minutes: 1440, remaining: 50),
        ])
        #expect(provider.sessionWindow?.label == "Daily")
    }

    @Test func aReportOfOnlyErrorsHasNoPillProvider() {
        let report = AIUsageReport(
            providers: [Self.provider("Gemini", remaining: [], error: "broken")],
            commandError: nil)
        #expect(report.pillSelection(AIUsageDisplayOptions()) == nil)
    }

    @Test(arguments: [
        (100.0, AIUsageLevel.normal),
        (25.0, .normal),
        (24.9, .low),
        (10.0, .low),
        (9.9, .critical),
        (0.0, .critical),
    ])
    func levelThresholdsAreUnder25AndUnder10Remaining(remaining: Double, expected: AIUsageLevel) {
        #expect(AIUsageLevel(remainingPercent: remaining) == expected)
    }
}

@Suite("AI Usage display options")
@MainActor
struct AIUsageDisplayOptionsTests {
    private static func window(
        _ id: String, label: String, minutes: Int?, remaining: Double,
        resetsAt: Date? = nil, expectedUsed: Double? = nil
    ) -> AIUsageWindow {
        AIUsageWindow(
            id: id, label: label, usedPercent: 100 - remaining, resetsAt: resetsAt,
            expectedUsedPercent: expectedUsed, windowMinutes: minutes)
    }

    private static func provider(_ name: String, session: Double, weekly: Double?)
        -> AIUsageProvider
    {
        var windows = [window("primary", label: "Session", minutes: 300, remaining: session)]
        if let weekly {
            windows.append(window("secondary", label: "Weekly", minutes: 10080, remaining: weekly))
        }
        return AIUsageProvider(
            id: name, providerID: name.lowercased(), displayName: name, account: nil,
            windows: windows, errorMessage: nil)
    }

    private static func options(
        _ mode: AIUsagePillWindow = .session, provider: String? = nil
    ) -> AIUsageDisplayOptions {
        var options = AIUsageDisplayOptions()
        options.pillWindow = mode
        options.pillProviderID = provider
        return options
    }

    @Test(arguments: [
        (AIUsagePillWindow.session, ["Session"]),
        (.weekly, ["Weekly"]),
        (.sessionAndWeekly, ["Session", "Weekly"]),
    ])
    func eachModeShowsItsWindows(mode: AIUsagePillWindow, labels: [String]) {
        let provider = Self.provider("Claude", session: 64, weekly: 12)
        #expect(provider.pillWindows(mode).map(\.label) == labels)
    }

    @Test(arguments: [(64.0, 12.0, "Weekly"), (10.0, 80.0, "Session"), (40.0, 40.0, "Session")])
    func automaticShowsTheBindingLimitAndATieKeepsTheSession(
        session: Double, weekly: Double, expected: String
    ) {
        let provider = Self.provider("Claude", session: session, weekly: weekly)
        #expect(provider.pillWindows(.automatic).map(\.label) == [expected])
    }

    @Test(arguments: AIUsagePillWindow.allCases)
    func aWeeklyOnlyProviderShowsOnlyItsWeeklyWindow(mode: AIUsagePillWindow) {
        let provider = AIUsageProvider(
            id: "claude", providerID: "claude", displayName: "Claude", account: nil,
            windows: [Self.window("secondary", label: "Weekly", minutes: 10080, remaining: 30)],
            errorMessage: nil)
        #expect(provider.pillWindows(mode).map(\.label) == ["Weekly"])
    }

    @Test(arguments: AIUsagePillWindow.allCases)
    func withoutAWeeklyWindowEveryModeFallsBackToTheSession(mode: AIUsagePillWindow) {
        let provider = Self.provider("Amp", session: 40, weekly: nil)
        #expect(provider.pillWindows(mode).map(\.label) == ["Session"])
    }

    @Test func theModeDecidesWhichProviderIsMostUrgent() throws {
        let report = AIUsageReport(
            providers: [
                Self.provider("Codex", session: 80, weekly: 5),
                Self.provider("Claude", session: 30, weekly: 60),
            ],
            commandError: nil)
        #expect(report.pillSelection(Self.options(.session))?.provider.displayName == "Claude")
        #expect(report.pillSelection(Self.options(.weekly))?.provider.displayName == "Codex")
        #expect(
            report.pillSelection(Self.options(.sessionAndWeekly))?.provider.displayName == "Codex")
    }

    @Test func aChosenProviderWinsAndAMissingOneFallsBackToTheMostUrgent() {
        let report = AIUsageReport(
            providers: [
                Self.provider("Codex", session: 80, weekly: 50),
                Self.provider("Claude", session: 30, weekly: 60),
            ],
            commandError: nil)
        #expect(report.pillSelection(Self.options(provider: "codex"))?.provider.displayName
            == "Codex")
        #expect(report.pillSelection(Self.options(provider: "gemini"))?.provider.displayName
            == "Claude")
    }

    @Test func aChosenProviderWithOnlyAnErrorFallsBackToTheMostUrgent() {
        let report = AIUsageReport(
            providers: [
                AIUsageProvider(
                    id: "codex", providerID: "codex", displayName: "Codex", account: nil,
                    windows: [], errorMessage: "signed out"),
                Self.provider("Claude", session: 30, weekly: 60),
            ],
            commandError: nil)
        #expect(report.pillSelection(Self.options(provider: "codex"))?.provider.displayName
            == "Claude")
    }

    @Test func sessionAndWeeklyTitleShowsBothNumbersThenTheFirstReset() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let provider = AIUsageProvider(
            id: "claude", providerID: "claude", displayName: "Claude", account: nil,
            windows: [
                Self.window(
                    "primary", label: "Session", minutes: 300, remaining: 64,
                    resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60)),
                Self.window(
                    "secondary", label: "Weekly", minutes: 10080, remaining: 12,
                    resetsAt: now.addingTimeInterval(3 * 86_400)),
            ],
            errorMessage: nil)
        var options = Self.options(.sessionAndWeekly)
        let selection = AIUsagePillSelection(
            provider: provider, windows: provider.pillWindows(.sessionAndWeekly))
        #expect(AIUsageFormat.pillTitle(selection, options: options, now: now)
            == "Claude 64% · 12%")
        options.pillShowsResetTime = true
        #expect(AIUsageFormat.pillTitle(selection, options: options, now: now)
            == "Claude 64% · 12% · 2h 14m")
        // Cut to one window, the number is no longer obviously the session's.
        #expect(AIUsageFormat.pillTitles(selection, options: options, now: now)
            == ["Claude 64% · 12% · 2h 14m", "Claude 64% · 12%", "Claude S64%"])
        options.showsUsed = true
        #expect(AIUsageFormat.pillTitle(selection, options: options, now: now)
            == "Claude 36% · 88% · 2h 14m")
        #expect(AIUsageFormat.pillAccessibilityValue(selection, options: options, now: now)
            == "Claude Session, 36 percent used, resets in 2 hours 14 minutes; "
            + "Weekly, 88 percent used, resets in 3 days")
    }

    @Test func onlyAnUnambiguousTitleLeavesItsNumbersUnlettered() {
        let provider = Self.provider("Claude", session: 64, weekly: 12)
        func title(_ mode: AIUsagePillWindow) -> String {
            AIUsageFormat.pillTitle(
                AIUsagePillSelection(provider: provider, windows: provider.pillWindows(mode)),
                options: Self.options(mode), now: .now)
        }
        #expect(title(.session) == "Claude 64%")
        #expect(title(.sessionAndWeekly) == "Claude 64% · 12%")
        #expect(title(.weekly) == "Claude W12%")
        #expect(title(.automatic) == "Claude W12%")
        let amp = Self.provider("Amp", session: 40, weekly: nil)
        #expect(AIUsageFormat.pillTitle(
            AIUsagePillSelection(provider: amp, windows: amp.pillWindows(.weekly)),
            options: Self.options(.weekly), now: .now) == "Amp S40%")
        #expect(AIUsageFormat.pillTitle(
            AIUsagePillSelection(provider: amp, windows: amp.pillWindows(.sessionAndWeekly)),
            options: Self.options(.sessionAndWeekly), now: .now) == "Amp S40%")
    }

    /// The approved mockup: out of the box the row reads "Claude 64% · 12%".
    /// A choice stored before the default changed is kept.
    @Test func theDefaultSummaryShowsSessionThenWeeklyUnlettered() throws {
        let provider = Self.provider("Claude", session: 64, weekly: 12)
        let report = AIUsageReport(providers: [provider], commandError: nil)
        let options = AIUsageDisplayOptions()
        let selection = try #require(report.pillSelection(options))
        #expect(AIUsageFormat.pillTitle(selection, options: options, now: .now)
            == "Claude 64% · 12%")
        let empty = try JSONDecoder().decode(AIUsageDisplayOptions.self, from: Data("{}".utf8))
        #expect(empty.pillWindow == .sessionAndWeekly)
        let stored = try JSONDecoder().decode(
            AIUsageDisplayOptions.self, from: Data(#"{"pillWindow":"session"}"#.utf8))
        #expect(stored.pillWindow == .session)
    }

    @Test func clockModePillReadsAndSpeaksTheResetTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let locale = Locale(identifier: "en_US")
        // Wed 2026-09-23 10:00 New York.
        let now = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 23, hour: 10)))
        let provider = AIUsageProvider(
            id: "claude", providerID: "claude", displayName: "Claude", account: nil,
            windows: [
                Self.window(
                    "primary", label: "Session", minutes: 300, remaining: 64,
                    resetsAt: now.addingTimeInterval(4.45 * 3600)),
            ],
            errorMessage: nil)
        var options = Self.options()
        options.pillShowsResetTime = true
        options.resetStyle = .clock
        let selection = AIUsagePillSelection(provider: provider, windows: provider.windows)
        let title = AIUsageFormat.pillTitle(
            selection, options: options, now: now, calendar: calendar, locale: locale)
        let spoken = AIUsageFormat.pillAccessibilityValue(
            selection, options: options, now: now, calendar: calendar, locale: locale)
        #expect(title.replacingOccurrences(of: "\u{202F}", with: " ") == "Claude 64% · 2:27 PM")
        #expect(spoken.replacingOccurrences(of: "\u{202F}", with: " ")
            == "Claude Session, 64 percent remaining, resets 2:27 PM")
    }

    @Test(arguments: [
        (0.0, false, 0.0, AIUsageLevel.critical),
        (0.0, true, 100.0, .critical),
        (100.0, false, 100.0, .normal),
        (100.0, true, 0.0, .normal),
    ])
    func displayPercentAtTheEdges(
        remaining: Double, showsUsed: Bool, shown: Double, level: AIUsageLevel
    ) {
        let window = Self.window("primary", label: "Session", minutes: 300, remaining: remaining)
        #expect(window.displayPercent(showsUsed: showsUsed) == shown)
        #expect(window.level == level)
    }

    @Test func paceOutsideTheGaugeIsClamped() {
        let early = Self.window("primary", label: "Session", minutes: 300, remaining: 50, expectedUsed: -5)
        let late = Self.window("primary", label: "Session", minutes: 300, remaining: 50, expectedUsed: 120)
        #expect(early.displayPacePercent(showsUsed: true) == 0)
        #expect(early.displayPacePercent(showsUsed: false) == 100)
        #expect(late.displayPacePercent(showsUsed: true) == 100)
        #expect(late.displayPacePercent(showsUsed: false) == 0)
    }

    @Test func usedShowsTheSpentShareButColorStillWarnsOnLittleLeft() {
        let window = Self.window(
            "primary", label: "Session", minutes: 300, remaining: 8, expectedUsed: 70)
        #expect(window.displayPercent(showsUsed: true) == 92)
        #expect(window.displayPercent(showsUsed: false) == 8)
        #expect(window.displayPacePercent(showsUsed: true) == 70)
        #expect(window.displayPacePercent(showsUsed: false) == 30)
        #expect(window.level == .critical)
    }

    @Test func hidingAccountLabelsRemovesOnlyTheAccountFromSpokenUsage() {
        let window = Self.window("primary", label: "Session", minutes: 300, remaining: 64)
        let provider = AIUsageProvider(
            id: "codex:fake-work", providerID: "codex", displayName: "Codex", account: "Work",
            windows: [window], errorMessage: nil)
        var options = Self.options()
        let visible = AIUsageFormat.accessibilityLabel(
            provider: provider, window: window, options: options, now: .now)
        #expect(visible.contains("Work"))
        options.hidesAccountLabels = true
        let hidden = AIUsageFormat.accessibilityLabel(
            provider: provider, window: window, options: options, now: .now)
        #expect(!hidden.contains("Work"))
        #expect(hidden.contains("Codex"))
        #expect(hidden.contains("Session"))
        #expect(hidden.contains("64 percent remaining"))
    }

    @Test func clockResetsReadTheTimeWithTheDayWhenNotToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let locale = Locale(identifier: "en_US")
        // Wed 2026-09-23 10:00 New York.
        let now = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 23, hour: 10)))
        func text(_ hours: Double) -> String? {
            AIUsageFormat.resetText(
                now.addingTimeInterval(hours * 3600), now: now, style: .clock,
                calendar: calendar, locale: locale)
        }
        func normalized(_ string: String?) -> String? {
            // Formatters may use a narrow no-break space before AM/PM.
            string?.replacingOccurrences(of: "\u{202F}", with: " ")
        }
        #expect(normalized(text(4.45)) == "Resets 2:27 PM")
        #expect(normalized(text(24)) == "Resets Tomorrow 10:00 AM")
        #expect(normalized(text(48)) == "Resets Fri 10:00 AM")
        // Under six days reads the weekday; six days on reads the date.
        #expect(normalized(text(6 * 24 - 1.0 / 60)) == "Resets Tue 9:59 AM")
        #expect(normalized(text(6 * 24)) == "Resets Sep 29")
        #expect(normalized(text(24 * 10)) == "Resets Oct 3")
        let lateNight = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 23, hour: 23, minute: 30)))
        #expect(normalized(AIUsageFormat.resetText(
            lateNight.addingTimeInterval(3600), now: lateNight, style: .clock,
            calendar: calendar, locale: locale)) == "Resets Tomorrow 12:30 AM")
        #expect(AIUsageFormat.resetText(
            now.addingTimeInterval(-60), now: now, style: .clock) == "Resetting now")
        #expect(AIUsageFormat.resetText(
            now.addingTimeInterval(8040), now: now, style: .countdown) == "Resets in 2h 14m")
    }

    @Test func optionsSurviveARelaunchAndAnUnreadableFieldCostsOnlyItself() throws {
        let defaults = try #require(UserDefaults(suiteName: "AIUsageDisplayOptionsTests"))
        defaults.removePersistentDomain(forName: "AIUsageDisplayOptionsTests")
        defer { defaults.removePersistentDomain(forName: "AIUsageDisplayOptionsTests") }
        var options = AIUsageDisplayOptions()
        options.pillWindow = .sessionAndWeekly
        options.pillProviderID = "codex"
        options.showsUsed = true
        AIUsagePreferences(defaults: defaults).updateDisplay(options)
        #expect(AIUsagePreferences(defaults: defaults).display == options)
        let json = #"{"pillWindow":"hourly","showsUsed":true,"showsPace":false}"#
        let decoded = try JSONDecoder().decode(AIUsageDisplayOptions.self, from: Data(json.utf8))
        #expect(decoded.pillWindow == AIUsageDisplayOptions().pillWindow)
        #expect(decoded.showsUsed)
        #expect(!decoded.showsPace)
    }

    /// The stored key is still `isEnabled`: an old false stays off, an old
    /// true (only ever stored beside another choice) stays on, and a Host
    /// never stored is undecided.
    @Test func legacyHostChoicesKeepTheirMeaning() throws {
        func choice(_ json: String) throws -> Bool? {
            try JSONDecoder().decode(AIUsageHostSettings.self, from: Data(json.utf8)).enabledChoice
        }
        #expect(try choice(#"{"isEnabled":false}"#) == false)
        #expect(try choice(#"{"isEnabled":true,"customPath":"/x"}"#) == true)
        #expect(try choice("{}") == nil)

        let suiteName = "AIUsageHostChoiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let on = Host.ID(), off = Host.ID()
        let preferences = AIUsagePreferences(defaults: defaults)
        preferences.update(AIUsageHostSettings(enabledChoice: true), for: on)
        preferences.update(AIUsageHostSettings(enabledChoice: false), for: off)
        let reloaded = AIUsagePreferences(defaults: defaults)
        #expect(reloaded.settings(for: on).enabledChoice == true)
        #expect(reloaded.settings(for: off).enabledChoice == false)
    }
}

@Suite("AI Usage poll schedule")
struct AIUsagePollScheduleTests {
    @Test func failuresDoubleTheIntervalUpTo15Minutes() {
        let interval = AIUsageRefreshInterval.oneMinute.duration
        let delays = (0...6).map {
            AIUsagePollSchedule.delay(interval: interval, consecutiveFailures: $0)
        }
        #expect(delays == [60, 120, 240, 480, 900, 900, 900].map { Duration.seconds($0) })
    }

    @Test func aFifteenMinuteIntervalNeverShrinksOrGrows() {
        let interval = AIUsageRefreshInterval.fifteenMinutes.duration
        for failures in 0...5 {
            #expect(
                AIUsagePollSchedule.delay(interval: interval, consecutiveFailures: failures)
                    == .seconds(900))
        }
    }

    @Test func dataIsStaleOnlyPastThreeIntervals() {
        let fetchedAt = Date(timeIntervalSince1970: 1_000_000)
        let interval = AIUsageRefreshInterval.fiveMinutes.duration
        #expect(!AIUsagePollSchedule.isStale(
            fetchedAt: fetchedAt, now: fetchedAt.addingTimeInterval(900), interval: interval))
        #expect(AIUsagePollSchedule.isStale(
            fetchedAt: fetchedAt, now: fetchedAt.addingTimeInterval(901), interval: interval))
    }
}

@Suite("CodexBar command")
struct CodexBarCommandTests {
    @Test func theProbeReportsOnlyAnAbsoluteMarkedPath() {
        let output = Data(
            ("motd noise\n__WAYCAR_CODEXBAR__=relative/codexbar\n"
                + "__WAYCAR_CODEXBAR__=/opt/homebrew/bin/codexbar\r\n").utf8)
        #expect(CodexBarCommand.locatedPath(in: output) == "/opt/homebrew/bin/codexbar")
        #expect(CodexBarCommand.locatedPath(in: Data("__WAYCAR_CODEXBAR__=codexbar\n".utf8)) == nil)
        #expect(CodexBarCommand.locatedPath(in: Data()) == nil)
    }

    /// sshd's bare PATH misses Homebrew, linuxbrew and `~/.local/bin`, so
    /// the lookup has to run after the Host PATH fix, not before it.
    @Test func autoDetectionLooksCodexBarUpUnderTheHostPathFix() throws {
        let command = try CodexBarCommand.locateCommand(customPath: nil)
        let pathFix = try #require(command.range(of: HerdrHostPath.pathExport))
        let lookup = try #require(command.range(of: "command -v codexbar"))
        #expect(pathFix.upperBound <= lookup.lowerBound)
    }


    /// A `codexbar serve` answers `/usage` once its slowest provider has
    /// answered or used up its budget. On a Mac where Claude took 31
    /// seconds, the old 10-second wait gave up on every answer and fell back
    /// to the CLI, which cannot read Claude over SSH. The wait outlasts the
    /// Keychain Fix's server, and both still fit the app's budget.
    @Test func aHealthyServerIsWaitedForLongerThanItWorksOnAnyProvider() throws {
        #expect(CodexBarCommand.serveUsageSeconds > CodexBarServe.providerBudgetSeconds)
        #expect(CodexBarServe.providerBudgetSeconds > 31)
        #expect(
            CodexBarCommand.serveHealthSeconds + CodexBarCommand.serveUsageSeconds
                < CodexBarCommand.hostDeadlineSeconds)
        #expect(CodexBarCommand.watchdogSeconds <= CodexBarCommand.hostDeadlineSeconds)
        #expect(
            Duration.seconds(CodexBarCommand.hostDeadlineSeconds + 3) <= CodexBarCommand.usageTimeout)
        let command = try CodexBarCommand.usageCommand(executablePath: "/opt/homebrew/bin/codexbar")
        #expect(command.contains(
            "--max-time \(CodexBarCommand.serveUsageSeconds) http://127.0.0.1:\(CodexBarServe.port)/usage"))
    }

    /// A CLI run says whether it ran on a Mac, where "No available fetch
    /// strategy for claude." means the keychain; a server answer needs no
    /// such line.
    @Test func theCLIRunMarksAMacHost() throws {
        let command = try CodexBarCommand.usageCommand(executablePath: "/opt/homebrew/bin/codexbar")
        let server = try #require(command.range(of: "/usage 2>/dev/null"))
        let mark = try #require(command.range(of:
            "[ \"$(uname -s 2>/dev/null)\" != Darwin ] || printf \"%s\\n\" \"\(CodexBarCommand.macOSHostMarker)\""))
        let cli = try #require(command.range(of: "usage --format json"))
        #expect(server.upperBound <= mark.lowerBound)
        #expect(mark.upperBound <= cli.lowerBound)
    }

    @Test(arguments: [
        (Int32(126), CodexBarError.executableMissing as CodexBarError?),
        (127, .executableMissing),
        (143, .timedOut),
        (0, nil),
        (1, nil),
        (2, nil),
    ])
    func usageExitStatusesThatCarryNoReport(status: Int32, expected: CodexBarError?) {
        #expect(CodexBarCommand.usageFailure(exitStatus: status) == expected)
    }

    /// Both ways a CodexBar run can run out of time become CodexBar's own
    /// failure; `TransportError.timedOut` would make the Console redial the
    /// Host and run the CLI again. Every other failure keeps its meaning.
    @Test func runningOutOfTimeIsCodexBarsFailureNotALinkFailure() {
        #expect(
            CodexBarError.replacingTimeout(AsyncDeadlineError.timedOut) as? CodexBarError
                == .timedOut)
        #expect(
            CodexBarError.replacingTimeout(TransportError.timedOut) as? CodexBarError == .timedOut)
        let unreachable = TransportError.sshUnreachable(detail: "gone")
        #expect(CodexBarError.replacingTimeout(unreachable) as? TransportError == unreachable)
        #expect(
            CodexBarError.replacingTimeout(TransportError.cancelled) as? TransportError
                == .cancelled)
        #expect(
            CodexBarError.replacingTimeout(CodexBarError.invalidPath) as? CodexBarError
                == .invalidPath)
    }

    @Test func customPathsMustBeAbsoluteOrHomeRelativeAndQuotable() throws {
        #expect(try CodexBarCommand.quotedCustomPath("/opt/cb/codexbar") == "'/opt/cb/codexbar'")
        #expect(try CodexBarCommand.quotedCustomPath("~/bin/codexbar") == "'~/bin/codexbar'")
        #expect(!CodexBarCommand.isValidCustomPath("bin/codexbar"))
        #expect(!CodexBarCommand.isValidCustomPath("/opt/it's/codexbar"))
        #expect(!CodexBarCommand.isValidCustomPath("~user/codexbar"))
    }
}

/// The Console's side of the store's inputs, scripted: each Host's
/// connection status and generation, and the clock.
@MainActor
private final class ScriptedConnections {
    var statuses: [Host.ID: EventsSessionStatus] = [:]
    var generations: [Host.ID: UInt64] = [:]
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    func connect(_ hostID: Host.ID, generation: UInt64 = 1) {
        statuses[hostID] = .connected
        generations[hostID] = generation
    }
}

@MainActor
@Suite("AI Usage store")
struct AIUsageStoreTests {
    private let studio = Host.fixture(name: "studio", address: "10.0.0.2")
    private let build = Host.fixture(name: "build", address: "10.0.0.3")
    private let window = UUID()
    private let connections = ScriptedConnections()
    private let preferences: AIUsagePreferences
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(
            UserDefaults(suiteName: "ai-usage-store-tests.\(UUID().uuidString)"))
        preferences = AIUsagePreferences(defaults: defaults)
    }

    private func makeStore(
        transports: [Host.ID: ScriptedTransport],
        probeRetryDelay: Duration = .seconds(30)
    ) -> AIUsageStore {
        let connections = connections
        return AIUsageStore(
            preferences: preferences,
            transports: ScriptedTransportProvider(transports: transports),
            connectionStatus: { connections.statuses[$0] },
            connectionGeneration: { connections.generations[$0] },
            now: { connections.now },
            probeRetryDelay: probeRetryDelay)
    }

    private static func report(_ provider: String, remaining: Double) -> AIUsageReport {
        AIUsageReport(
            providers: [
                AIUsageProvider(
                    id: provider, providerID: provider, displayName: provider, account: nil,
                    windows: [
                        AIUsageWindow(
                            id: "primary", label: "Session", usedPercent: 100 - remaining,
                            resetsAt: nil, expectedUsedPercent: nil)
                    ],
                    errorMessage: nil)
            ],
            commandError: nil)
    }

    /// CodexBar's output for one provider whose data is from `updatedAt`,
    /// marked as a server answer or not.
    private static func codexBarOutput(updatedAt: Date, fromServer: Bool) throws -> AIUsageReport {
        let json = #"[{"provider":"claude","usage":{"primary":{"usedPercent":60,"windowMinutes":300},"updatedAt":"\#(updatedAt.formatted(.iso8601))"}}]"#
        let output = fromServer ? "\(CodexBarCommand.serverSourceMarker)\n\(json)\n" : "\(json)\n"
        return try AIUsageReport.decode(Data(output.utf8))
    }

    /// Over the real Console connection path: a run that outlasts its
    /// budget is CodexBar's failure, not a dead link, so the Host is neither
    /// redialed nor asked to run the CLI a second time.
    @Test func aCodexBarTimeoutNeitherRedialsTheHostNorRunsTwice() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        await transport.scriptCodexBarLocations([.success("/usr/local/bin/codexbar")])
        await transport.scriptCodexBarUsage([.failure(CodexBarError.timedOut)])
        let connector = SequencedTransportConnector([transport])
        let console = ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { try await connector.connect() },
                reconnectPolicy: ReconnectPolicy(
                    initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
                keepalive: nil)
        }
        let store = AIUsageStore(
            preferences: preferences,
            transports: console,
            connectionStatus: { console.hostStatuses[$0] },
            connectionGeneration: { console.hostConnectionGenerations[$0] })
        console.setHosts([host])
        store.setHosts([host])
        store.setScope(nil, forWindow: window)
        await console.resume()
        try await waitUntil("the Host should connect") {
            console.hostStatuses[host.id] == .connected
        }
        let generation = console.hostConnectionGenerations[host.id]
        store.connectionsDidChange()

        try await waitUntil("the timeout should land as the Host's failure") {
            store.usage[host.id]?.lastFailure == CodexBarError.timedOut.message
        }
        // Let a redial or a retry surface before counting.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await transport.codexBarUsagePaths == ["/usr/local/bin/codexbar"])
        #expect(await connector.connectCount == 1)
        #expect(console.hostConnectionGenerations[host.id] == generation)
        #expect(store.usage[host.id]?.consecutiveFailures == 1)
        console.setHosts([])
    }

    @Test func aFailedProbeKeepsTheFoundPathAndIsRetried() async throws {
        let path = "/opt/homebrew/bin/codexbar"
        let transport = ScriptedTransport()
        await transport.scriptCodexBarLocations([
            .success(path), .failure(TransportError.channelFailed(detail: "busy")), .success(path),
        ])
        await transport.scriptCodexBarUsage([.success(Self.report("claude", remaining: 40))])
        let store = makeStore(
            transports: [studio.id: transport], probeRetryDelay: .milliseconds(300))
        connections.connect(studio.id, generation: 1)
        store.setHosts([studio])
        store.setScope(nil, forWindow: window)
        try await waitUntil("the first probe should find CodexBar") {
            store.detection(for: studio.id) == .found(path: path)
        }

        // A reconnect re-checks, and that check fails.
        connections.connect(studio.id, generation: 2)
        store.connectionsDidChange()
        try await waitUntil("the reconnect should probe again") {
            await transport.codexBarLocateCount == 2
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.detection(for: studio.id) == .found(path: path))
        #expect(store.source(scopedTo: nil) == AIUsageSource(hostID: studio.id, isLive: true))

        try await waitUntil("the failed probe should be retried on the same connection") {
            await transport.codexBarLocateCount == 3
        }
        #expect(store.detection(for: studio.id) == .found(path: path))
    }

    @Test(arguments: [true, false])
    func aHostDeletedOrTurnedOffMidFetchKeepsNothingFromIt(deleted: Bool) async throws {
        let transport = ScriptedTransport()
        await transport.scriptCodexBarLocations([.success("/usr/local/bin/codexbar")])
        await transport.scriptCodexBarUsage([.success(Self.report("claude", remaining: 40))])
        let gate = ScriptedTransportCallGate()
        await transport.gateNextCodexBarUsage(gate)
        let store = makeStore(transports: [studio.id: transport])
        connections.connect(studio.id)
        store.setHosts([studio])
        store.setScope(nil, forWindow: window)
        await gate.waitForEntry()
        #expect(store.fetchingHostID == studio.id)

        if deleted {
            store.setHosts([])
        } else {
            store.updateSettings(AIUsageHostSettings(enabledChoice: false), for: studio.id)
        }
        #expect(store.fetchingHostID == nil)
        await gate.open()
        try await waitUntil("the abandoned run should still answer") {
            await transport.codexBarUsageAnswerCount == 1
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.usage[studio.id] == nil)
        #expect(store.source(scopedTo: nil) == nil)
    }

    @Test func switchingSourcesShowsEachHostsReportAndFetchesOnlyWhenDue() async throws {
        let studioTransport = ScriptedTransport()
        await studioTransport.scriptCodexBarLocations([.success("/usr/local/bin/codexbar")])
        await studioTransport.scriptCodexBarUsage([.success(Self.report("claude", remaining: 40))])
        let buildTransport = ScriptedTransport()
        await buildTransport.scriptCodexBarLocations([.success("/usr/local/bin/codexbar")])
        await buildTransport.scriptCodexBarUsage([.success(Self.report("codex", remaining: 70))])
        let store = makeStore(transports: [studio.id: studioTransport, build.id: buildTransport])
        preferences.update(AIUsageHostSettings(enabledChoice: true), for: studio.id)
        preferences.update(AIUsageHostSettings(enabledChoice: true), for: build.id)
        connections.connect(studio.id)
        connections.connect(build.id)
        store.setHosts([studio, build])
        store.setScope(studio.id, forWindow: window)
        try await waitUntil("the scoped Host should be fetched") {
            store.usage[studio.id]?.snapshot != nil
        }

        store.setScope(build.id, forWindow: window)
        try await waitUntil("a Host never fetched is due at once") {
            store.usage[build.id]?.snapshot != nil
        }

        store.setScope(studio.id, forWindow: window)
        #expect(store.source(scopedTo: studio.id) == AIUsageSource(hostID: studio.id, isLive: true))
        #expect(
            store.usage[studio.id]?.snapshot?.report == Self.report("claude", remaining: 40))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await studioTransport.codexBarUsagePaths.count == 1)

        // Once its interval has passed since that fetch finished, it is due.
        connections.now += TimeInterval(AIUsageRefreshInterval.default.rawValue * 60)
        store.connectionsDidChange()
        try await waitUntil("the scoped Host should be fetched once due") {
            await studioTransport.codexBarUsagePaths.count == 2
        }
        #expect(await buildTransport.codexBarUsagePaths.count == 1)
    }

    /// A server answering with its last report shows that report's age, so
    /// old data reads as old; the CLI's answer is as new as the run.
    @Test(arguments: [true, false])
    func aServerReportIsDatedByItsDataNotTheFetch(fromServer: Bool) async throws {
        let updatedAt = connections.now.addingTimeInterval(-20 * 60)
        let transport = ScriptedTransport()
        await transport.scriptCodexBarLocations([.success("/usr/local/bin/codexbar")])
        let report = try Self.codexBarOutput(updatedAt: updatedAt, fromServer: fromServer)
        await transport.scriptCodexBarUsage([.success(report)])
        let store = makeStore(transports: [studio.id: transport])
        connections.connect(studio.id)
        store.setHosts([studio])
        store.setScope(nil, forWindow: window)
        try await waitUntil("the report should land") {
            store.usage[studio.id]?.snapshot != nil
        }

        let snapshot = try #require(store.usage[studio.id]?.snapshot)
        #expect(snapshot.fetchedAt == (fromServer ? updatedAt : connections.now))
        // Twenty minutes is past three five-minute intervals.
        #expect(store.isStale(studio.id, at: connections.now) == fromServer)
    }

    /// A server keeps answering with its last report for a moment after it
    /// expires while it rebuilds: old data is asked for once more shortly,
    /// once per scheduled poll, so a server stuck on it is not asked in a
    /// loop. Fresh data waits for the interval.
    @Test(arguments: [true, false])
    func aServerAnsweringWithOldDataIsAskedOnceMoreShortly(oldData: Bool) async throws {
        let updatedAt = connections.now.addingTimeInterval(oldData ? -20 * 60 : 0)
        let transport = ScriptedTransport()
        await transport.scriptCodexBarLocations([.success("/usr/local/bin/codexbar")])
        // The server answers with the same report every time.
        let report = try Self.codexBarOutput(updatedAt: updatedAt, fromServer: true)
        await transport.scriptCodexBarUsage([.success(report)])
        let store = makeStore(transports: [studio.id: transport])
        connections.connect(studio.id)
        store.setHosts([studio])
        store.setScope(nil, forWindow: window)
        try await waitUntil("the scheduled fetch should land") {
            store.usage[studio.id]?.lastFinishedAt != nil
        }

        // Moves the clock on, then lets the store act on it.
        func advance(_ seconds: TimeInterval, expectingFetches count: Int) async throws {
            connections.now += seconds
            store.connectionsDidChange()
            try await waitUntil("the store should settle after the expected fetches") {
                let answered = await transport.codexBarUsageAnswerCount
                return answered == count && store.fetchingHostID == nil
            }
            // Let an unexpected extra fetch surface before counting.
            try await Task.sleep(for: .milliseconds(50))
            #expect(await transport.codexBarUsagePaths.count == count)
        }

        let followUp = AIUsagePollSchedule.serverFollowUpDelay
        try await advance(followUp, expectingFetches: oldData ? 2 : 1)
        try await advance(followUp, expectingFetches: oldData ? 2 : 1)
        guard oldData else { return }
        // The next scheduled poll allows one more follow-up.
        try await advance(
            TimeInterval(AIUsageRefreshInterval.default.rawValue * 60), expectingFetches: 3)
        try await advance(followUp, expectingFetches: 4)
    }

    @Test func aRunCutOffByTheConnectionDoesNotBackTheHostOff() async throws {
        let transport = ScriptedTransport()
        await transport.scriptCodexBarLocations([.success("/usr/local/bin/codexbar")])
        await transport.scriptCodexBarUsage([
            .failure(TransportError.sshUnreachable(detail: "The Host is not connected."))
        ])
        let store = makeStore(transports: [studio.id: transport])
        connections.connect(studio.id)
        store.setHosts([studio])
        store.setScope(nil, forWindow: window)
        try await waitUntil("the interrupted run should finish") {
            store.usage[studio.id]?.lastFinishedAt != nil
        }
        #expect(store.usage[studio.id]?.consecutiveFailures == 0)
        #expect(store.usage[studio.id]?.lastFailure == nil)
    }

    @Test func aVanishedExecutableIsDetectedAgain() async throws {
        let transport = ScriptedTransport()
        await transport.scriptCodexBarLocations([
            .success("/usr/local/bin/codexbar"), .success("/opt/homebrew/bin/codexbar"),
        ])
        await transport.scriptCodexBarUsage([.failure(CodexBarError.executableMissing)])
        let store = makeStore(transports: [studio.id: transport])
        connections.connect(studio.id)
        store.setHosts([studio])
        store.setScope(nil, forWindow: window)
        try await waitUntil("the missing executable should send detection round again") {
            store.detection(for: studio.id) == .found(path: "/opt/homebrew/bin/codexbar")
        }
        #expect(await transport.codexBarLocateCount == 2)
        #expect(store.usage[studio.id]?.lastFailure == CodexBarError.executableMissing.message)
    }

    /// Uninstalling CodexBar must not leave a dimmed pill behind for good:
    /// once detection says it is gone, the old report holds no place.
    @Test func anUninstalledCodexBarLeavesNoPillBehind() async throws {
        let transport = ScriptedTransport()
        await transport.scriptCodexBarLocations([.success("/usr/local/bin/codexbar"), .success(nil)])
        await transport.scriptCodexBarUsage([
            .success(Self.report("claude", remaining: 40)),
            .failure(CodexBarError.executableMissing),
        ])
        let store = makeStore(transports: [studio.id: transport])
        connections.connect(studio.id)
        store.setHosts([studio])
        store.setScope(nil, forWindow: window)
        try await waitUntil("the Host should be fetched") {
            store.usage[studio.id]?.snapshot != nil
        }
        #expect(store.source(scopedTo: nil) == AIUsageSource(hostID: studio.id, isLive: true))

        connections.now += TimeInterval(AIUsageRefreshInterval.default.rawValue * 60)
        store.connectionsDidChange()
        try await waitUntil("the re-probe should find CodexBar gone") {
            store.detection(for: studio.id) == .notFound
        }
        #expect(store.usage[studio.id]?.snapshot != nil)
        #expect(store.source(scopedTo: nil) == nil)
        #expect(store.source(scopedTo: studio.id) == nil)
    }

    /// The Console restarts an edited Host's connection at generation 0, so
    /// a generation match must not skip the probe of the new address.
    @Test func anEditedHostIsDetectedAgainAndLosesTheOldReport() async throws {
        let transport = ScriptedTransport()
        await transport.scriptCodexBarLocations([.success("/usr/local/bin/codexbar")])
        await transport.scriptCodexBarUsage([.success(Self.report("claude", remaining: 40))])
        let store = makeStore(transports: [studio.id: transport])
        connections.connect(studio.id)
        store.setHosts([studio])
        store.setScope(nil, forWindow: window)
        try await waitUntil("the Host should be fetched") {
            store.usage[studio.id]?.snapshot != nil
        }

        var edited = studio
        edited.address = "10.0.0.9"
        store.setHosts([edited])
        #expect(store.usage[studio.id] == nil)
        try await waitUntil("the edited Host should be probed again") {
            await transport.codexBarLocateCount == 2
        }
    }

    /// A Host known to have CodexBar keeps the row in place, with no report
    /// yet, while it cannot answer; one found without CodexBar holds none.
    @Test func aDisconnectedCodexBarHostHoldsTheRowWithoutAReport() async throws {
        let transport = ScriptedTransport()
        await transport.scriptCodexBarLocations([.success("/usr/local/bin/codexbar")])
        let buildTransport = ScriptedTransport()
        await buildTransport.scriptCodexBarLocations([.success(nil)])
        let store = makeStore(transports: [studio.id: transport, build.id: buildTransport])
        connections.connect(studio.id)
        connections.connect(build.id)
        store.setHosts([studio, build])
        try await waitUntil("both Hosts should be probed") {
            store.detection(for: studio.id) == .found(path: "/usr/local/bin/codexbar")
                && store.detection(for: build.id) == .notFound
        }
        #expect(store.usage[studio.id]?.snapshot == nil)

        connections.statuses[studio.id] = nil
        #expect(store.source(scopedTo: build.id) == AIUsageSource(hostID: studio.id, isLive: false))

        store.setHosts([build])
        #expect(store.source(scopedTo: nil) == nil)
    }

    /// Opening the usage (the sheet, or the Console card showing) fetches a
    /// source not heard from lately only with Refresh When Opened.
    @Test func openingTheUsageRefreshesOnlyWhenAskedTo() async throws {
        let transport = ScriptedTransport()
        await transport.scriptCodexBarLocations([.success("/usr/local/bin/codexbar")])
        await transport.scriptCodexBarUsage([
            .success(Self.report("claude", remaining: 40)),
            .success(Self.report("claude", remaining: 30)),
        ])
        let store = makeStore(transports: [studio.id: transport])
        connections.connect(studio.id)
        store.setHosts([studio])
        store.setScope(studio.id, forWindow: window)
        try await waitUntil("the scoped Host should be fetched") {
            store.usage[studio.id]?.snapshot != nil
        }
        // Past the open threshold, well short of the poll interval.
        connections.now += AIUsageDisplayOptions.openRefreshThreshold * 2

        await store.sheetDidOpen(scopedTo: studio.id)
        #expect(await transport.codexBarUsagePaths.count == 1)

        var options = store.preferences.display
        options.refreshesWhenOpened = true
        store.preferences.updateDisplay(options)
        await store.sheetDidOpen(scopedTo: studio.id)
        try await waitUntil("opening should refresh the stale source") {
            store.usage[studio.id]?.snapshot?.report == Self.report("claude", remaining: 30)
        }
        #expect(await transport.codexBarUsagePaths.count == 2)
    }

    /// Two Hosts ask the same AI accounts, so only the first found with
    /// CodexBar defaults to on; the second is decided off and never asked.
    @Test func onlyTheFirstUndecidedHostWithCodexBarDefaultsToOn() async throws {
        let studioTransport = ScriptedTransport()
        await studioTransport.scriptCodexBarLocations([.success("/usr/local/bin/codexbar")])
        await studioTransport.scriptCodexBarUsage([.success(Self.report("claude", remaining: 40))])
        let buildTransport = ScriptedTransport()
        await buildTransport.scriptCodexBarLocations([.success("/usr/local/bin/codexbar")])
        await buildTransport.scriptCodexBarUsage([.success(Self.report("claude", remaining: 40))])
        let store = makeStore(transports: [studio.id: studioTransport, build.id: buildTransport])
        store.setScope(build.id, forWindow: window)
        connections.connect(studio.id)
        store.setHosts([studio, build])
        try await waitUntil("the first Host should be decided on") {
            preferences.settings(for: studio.id).enabledChoice == true
        }

        connections.connect(build.id)
        store.connectionsDidChange()
        try await waitUntil("the second Host should be decided off") {
            preferences.settings(for: build.id).enabledChoice == false
        }
        try await waitUntil("the first Host should be fetched") {
            store.usage[studio.id]?.snapshot != nil
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await buildTransport.codexBarUsagePaths.isEmpty)
        #expect(store.source(scopedTo: build.id) == AIUsageSource(hostID: studio.id, isLive: true))

        let reloaded = AIUsagePreferences(defaults: defaults)
        #expect(reloaded.settings(for: studio.id).enabledChoice == true)
        #expect(reloaded.settings(for: build.id).enabledChoice == false)
    }

    @Test func hostsTheUserTurnedOnAllStayOn() async throws {
        let studioTransport = ScriptedTransport()
        await studioTransport.scriptCodexBarLocations([.success("/usr/local/bin/codexbar")])
        let buildTransport = ScriptedTransport()
        await buildTransport.scriptCodexBarLocations([.success("/usr/local/bin/codexbar")])
        preferences.update(AIUsageHostSettings(enabledChoice: true), for: studio.id)
        preferences.update(AIUsageHostSettings(enabledChoice: true), for: build.id)
        let store = makeStore(transports: [studio.id: studioTransport, build.id: buildTransport])
        connections.connect(studio.id)
        connections.connect(build.id)
        store.setHosts([studio, build])
        try await waitUntil("both Hosts should be probed") {
            store.detection(for: studio.id).path != nil && store.detection(for: build.id).path != nil
        }
        #expect(preferences.settings(for: studio.id).enabledChoice == true)
        #expect(preferences.settings(for: build.id).enabledChoice == true)
        #expect(store.source(scopedTo: build.id) == AIUsageSource(hostID: build.id, isLive: true))
        #expect(store.source(scopedTo: studio.id) == AIUsageSource(hostID: studio.id, isLive: true))
    }

    /// A Host that is on but lacks CodexBar asks nothing, so it does not
    /// keep another Host off.
    @Test func anOnHostWithoutCodexBarDoesNotKeepANewHostOff() async throws {
        let studioTransport = ScriptedTransport()
        await studioTransport.scriptCodexBarLocations([.success("/usr/local/bin/codexbar")])
        let buildTransport = ScriptedTransport()
        await buildTransport.scriptCodexBarLocations([.success(nil)])
        preferences.update(AIUsageHostSettings(enabledChoice: true), for: build.id)
        let store = makeStore(transports: [studio.id: studioTransport, build.id: buildTransport])
        connections.connect(build.id)
        store.setHosts([studio, build])
        try await waitUntil("the on Host should be found without CodexBar") {
            store.detection(for: build.id) == .notFound
        }
        connections.connect(studio.id)
        store.connectionsDidChange()
        try await waitUntil("the new Host should be decided on") {
            preferences.settings(for: studio.id).enabledChoice == true
        }
    }

    /// Undecided until CodexBar turns up, so a later install is still decided.
    @Test func aHostWithoutCodexBarStaysUndecided() async throws {
        let transport = ScriptedTransport()
        await transport.scriptCodexBarLocations([.success(nil), .success("/usr/local/bin/codexbar")])
        let store = makeStore(transports: [studio.id: transport])
        connections.connect(studio.id)
        store.setHosts([studio])
        try await waitUntil("the probe should find no CodexBar") {
            store.detection(for: studio.id) == .notFound
        }
        #expect(preferences.settings(for: studio.id).enabledChoice == nil)

        store.checkAgain(studio.id)
        try await waitUntil("a later install should be decided on") {
            preferences.settings(for: studio.id).enabledChoice == true
        }
    }

    /// Only a Host explicitly on keeps a new one off, even before that Host
    /// was ever checked; one explicitly off does not.
    @Test(arguments: [true, false])
    func anotherHostsExplicitChoiceDecidesTheNewHost(otherIsOn: Bool) async throws {
        let transport = ScriptedTransport()
        await transport.scriptCodexBarLocations([.success("/usr/local/bin/codexbar")])
        preferences.update(AIUsageHostSettings(enabledChoice: otherIsOn), for: build.id)
        let store = makeStore(transports: [studio.id: transport, build.id: ScriptedTransport()])
        connections.connect(studio.id)
        store.setHosts([studio, build])
        try await waitUntil("the new Host should be decided") {
            preferences.settings(for: studio.id).enabledChoice != nil
        }
        #expect(store.detection(for: build.id) == .unknown)
        #expect(preferences.settings(for: studio.id).enabledChoice == !otherIsOn)
    }

    /// Probes landing together at launch still leave exactly one Host on.
    @Test func undecidedHostsConnectingTogetherLeaveOneOn() async throws {
        let studioTransport = ScriptedTransport()
        await studioTransport.scriptCodexBarLocations([.success("/usr/local/bin/codexbar")])
        let buildTransport = ScriptedTransport()
        await buildTransport.scriptCodexBarLocations([.success("/usr/local/bin/codexbar")])
        let store = makeStore(transports: [studio.id: studioTransport, build.id: buildTransport])
        connections.connect(studio.id)
        connections.connect(build.id)
        store.setHosts([studio, build])
        try await waitUntil("both Hosts should be decided") {
            preferences.settings(for: studio.id).enabledChoice != nil
                && preferences.settings(for: build.id).enabledChoice != nil
        }
        let choices = [studio.id, build.id].map { preferences.settings(for: $0).enabledChoice }
        #expect(choices.filter { $0 == true }.count == 1)
        #expect(choices.filter { $0 == false }.count == 1)
    }

    /// A change the user makes to an undecided Host keeps it on, as its
    /// toggle showed, even with another Host on.
    @Test func customizingAnUndecidedHostKeepsItOn() async throws {
        let path = "/opt/homebrew/bin/codexbar"
        let transport = ScriptedTransport()
        await transport.scriptCodexBarLocations([.success(path)])
        preferences.update(AIUsageHostSettings(enabledChoice: true), for: build.id)
        let store = makeStore(transports: [studio.id: transport, build.id: ScriptedTransport()])
        store.setHosts([studio, build])
        store.updateSettings(AIUsageHostSettings(customPath: path), for: studio.id)
        connections.connect(studio.id)
        store.connectionsDidChange()
        try await waitUntil("the probe should find CodexBar") {
            store.detection(for: studio.id) == .found(path: path)
        }
        #expect(preferences.settings(for: studio.id).enabledChoice == true)
        #expect(AIUsagePreferences(defaults: defaults).settings(for: studio.id).enabledChoice == true)
    }
}
