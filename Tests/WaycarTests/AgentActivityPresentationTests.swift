import SwiftUI
import Testing
import UIKit

@testable import Waycar

@Suite("Agent activity presentation")
struct AgentActivityPresentationTests {
    private static let statuses: [(wire: String, palette: AgentStatus)] = [
        ("blocked", .blocked),
        ("done", .done),
        ("working", .working),
        ("unknown", .unknown),
    ]

    private func agentDetail(
        paneID: String, status: String = "working"
    ) -> AgentActivityDetails.AgentDetail {
        AgentActivityDetails.AgentDetail(
            paneID: paneID, kind: "claude", name: nil, workspace: "Waycar", status: status,
            title: "Task \(paneID)")
    }

    private func detailedPresentation(
        agentCount: Int, total: AgentActivityAttributes.ContentState.Counts
    ) -> AgentActivityPresentation {
        let agents = (0..<agentCount).map { agentDetail(paneID: "w1:p\($0)") }
        return .detailed(
            details: AgentActivityDetails(hostName: "mbp", agents: agents),
            counts: total)
    }

    @Test func freshShowsFourRowsWhenTotalIsFour() {
        let presentation = detailedPresentation(
            agentCount: 4, total: .init(working: 4, blocked: 0, done: 0))
        #expect(presentation.lockScreenAgents(isStale: false).count == 4)
        #expect(presentation.lockScreenOverflowCount(isStale: false) == 0)
        #expect(presentation.lockScreenTrailingCaption(isStale: false) == nil)
    }

    @Test func freshShowsThreeRowsAndOverflowWhenTotalIsFive() {
        let presentation = detailedPresentation(
            agentCount: 5, total: .init(working: 5, blocked: 0, done: 0))
        #expect(
            presentation.lockScreenAgents(isStale: false).map(\.paneID)
                == ["w1:p0", "w1:p1", "w1:p2"])
        #expect(presentation.lockScreenOverflowCount(isStale: false) == 2)
        #expect(presentation.lockScreenTrailingCaption(isStale: false) == "+2 more")
    }

    @Test func freshOverflowCountsTheInventoryBeyondTheEnvelopeLimit() {
        let presentation = detailedPresentation(
            agentCount: 5, total: .init(working: 6, blocked: 0, done: 0))
        #expect(presentation.lockScreenAgents(isStale: false).count == 3)
        #expect(presentation.lockScreenOverflowCount(isStale: false) == 3)
        #expect(presentation.lockScreenTrailingCaption(isStale: false) == "+3 more")
    }

    @Test func staleGivesUpTheFourthRowForTheCaption() {
        let presentation = detailedPresentation(
            agentCount: 4, total: .init(working: 4, blocked: 0, done: 0))
        #expect(presentation.lockScreenAgents(isStale: true).count == 3)
        #expect(presentation.lockScreenOverflowCount(isStale: true) == 1)
        #expect(presentation.lockScreenTrailingCaption(isStale: true) == "+1 more · May be out of date")
    }

    @Test func staleShowsThreeRowsAndOverflowWhenTotalExceedsFour() {
        let presentation = detailedPresentation(
            agentCount: 5, total: .init(working: 5, blocked: 0, done: 0))
        #expect(presentation.lockScreenAgents(isStale: true).count == 3)
        #expect(presentation.lockScreenOverflowCount(isStale: true) == 2)
        #expect(presentation.lockScreenTrailingCaption(isStale: true) == "+2 more · May be out of date")
    }

    @Test func staleShowsAllRowsWhenTotalIsThreeOrLess() {
        let presentation = detailedPresentation(
            agentCount: 3, total: .init(working: 1, blocked: 1, done: 1))
        #expect(presentation.lockScreenAgents(isStale: true).count == 3)
        #expect(presentation.lockScreenOverflowCount(isStale: true) == 0)
        #expect(presentation.lockScreenTrailingCaption(isStale: true) == "May be out of date")
    }

    @Test func staleCountsOnlyHasNoRowsAndNoOverflow() {
        let presentation = AgentActivityPresentation.countsOnly(
            counts: .init(working: 2, blocked: 1, done: 0))
        #expect(presentation.lockScreenAgents(isStale: true).isEmpty)
        #expect(presentation.lockScreenOverflowCount(isStale: true) == 0)
        #expect(presentation.lockScreenTrailingCaption(isStale: true) == "May be out of date")
    }

    @Test func freshCountsOnlyHasNoRowsOrCaption() {
        let presentation = AgentActivityPresentation.countsOnly(
            counts: .init(working: 2, blocked: 1, done: 0))
        #expect(presentation.lockScreenAgents(isStale: false).isEmpty)
        #expect(presentation.lockScreenOverflowCount(isStale: false) == 0)
        #expect(presentation.lockScreenTrailingCaption(isStale: false) == nil)
    }

    @Test func attentionOrderPrefersBlockedThenDoneThenWorking() {
        let blockedFirst = AgentActivityAttributes.ContentState.Counts(
            working: 2, blocked: 1, done: 0)
        #expect(blockedFirst.attentionStatusItem?.status == "blocked")
        #expect(blockedFirst.attentionStatusItem?.count == 1)

        let doneBeforeWorking = AgentActivityAttributes.ContentState.Counts(
            working: 2, blocked: 0, done: 1)
        #expect(doneBeforeWorking.attentionStatusItem?.status == "done")
        #expect(doneBeforeWorking.attentionStatusItem?.count == 1)

        let workingOnly = AgentActivityAttributes.ContentState.Counts(
            working: 3, blocked: 0, done: 0)
        #expect(workingOnly.attentionStatusItem?.status == "working")
        #expect(workingOnly.attentionStatusItem?.count == 3)
    }

    @Test func idleChipTrailsTheActionableChipsAndStaysOutOfTheTotal() {
        let counts = AgentActivityAttributes.ContentState.Counts(
            working: 2, blocked: 1, done: 1, idle: 3)

        #expect(counts.chipItems.map(\.status) == ["blocked", "done", "working", "idle"])
        #expect(counts.chipItems.last?.count == 3)
        #expect(counts.total == 4)
        #expect(counts.attentionStatusItem?.status == "blocked")

        let noIdle = AgentActivityAttributes.ContentState.Counts(
            working: 1, blocked: 0, done: 0, idle: 0)
        #expect(noIdle.chipItems.map(\.status) == ["working"])
    }

    @Test func headerOtherCountsExcludeTheLeadAndKeepIdleLast() {
        let blocked = AgentActivityAttributes.ContentState.Counts(
            working: 2, blocked: 1, done: 1, idle: 3)
        #expect(blocked.otherStatusItems.map(\.status) == ["done", "working", "idle"])

        let workingLead = AgentActivityAttributes.ContentState.Counts(
            working: 2, blocked: 0, done: 0, idle: 1)
        #expect(workingLead.otherStatusItems.map(\.status) == ["idle"])

        let idleOnly = AgentActivityAttributes.ContentState.Counts(
            working: 0, blocked: 0, done: 0, idle: 2)
        #expect(idleOnly.attentionStatusItem == nil)
        #expect(idleOnly.otherStatusItems.map(\.status) == ["idle"])

        // The island never shows idle, like its compact and minimal totals.
        #expect(blocked.islandOtherStatusItems.map(\.status) == ["done", "working"])
        #expect(workingLead.islandOtherStatusItems.isEmpty)
        #expect(idleOnly.islandOtherStatusItems.isEmpty)
    }

    @Test func expandedIslandShowsThreeRowsOnlyWhenNoneOverflow() {
        let three = detailedPresentation(
            agentCount: 3, total: .init(working: 2, blocked: 1, done: 0, idle: 4))
        #expect(three.islandAgents.map(\.paneID) == ["w1:p0", "w1:p1", "w1:p2"])
        #expect(three.islandOverflowCount == 0)

        let four = detailedPresentation(
            agentCount: 4, total: .init(working: 3, blocked: 1, done: 0))
        #expect(four.islandAgents.map(\.paneID) == ["w1:p0", "w1:p1"])
        #expect(four.islandOverflowCount == 2)

        let seven = detailedPresentation(
            agentCount: 5, total: .init(working: 5, blocked: 1, done: 1))
        #expect(seven.islandAgents.map(\.paneID) == ["w1:p0", "w1:p1"])
        #expect(seven.islandOverflowCount == 5)

        let countsOnly = AgentActivityPresentation.countsOnly(
            counts: .init(working: 2, blocked: 1, done: 0))
        #expect(countsOnly.islandAgents.isEmpty)
        #expect(countsOnly.islandOverflowCount == 0)
    }

    @Test func narrationIncludesStatusForIslandAccessibility() {
        let agent = agentDetail(paneID: "w1:p1", status: "blocked")
        #expect(AgentActivityNarration.rowLabel(for: agent) == "Waycar, Claude, blocked")
    }

    @Test func identityIgnoresCustomAgentNameAndTerminalTitle() {
        let agent = AgentActivityDetails.AgentDetail(
            paneID: "w1:p1", kind: "codex", name: "identityprobe", workspace: "Waycar",
            status: "working", title: "Developer · identityprobe")

        #expect(AgentActivityFields.identityTexts(for: agent) == ["Waycar", "Codex"])
        #expect(agent.displayWorkspace == "Waycar")
    }

    @Test func liveActivityRowsNarrateWorkspaceKindAndStatusWithoutTaskNoise() {
        let agent = AgentActivityDetails.AgentDetail(
            paneID: "w1:p1", kind: "claude", workspace: "Checkout",
            status: "blocked", title: nil)

        #expect(agent.displayWorkspace == "Checkout")
        #expect(
            AgentActivityNarration.rowLabel(for: agent)
                == "Checkout, Claude, blocked")
    }

    @Test func lockScreenChromeRemainsDynamicAcrossSystemAppearances() {
        #expect(
            rgba(AgentActivityLockScreenChrome.backgroundColor, .light)
                == rgba(UIColor.systemBackground, .light))
        #expect(
            rgba(AgentActivityLockScreenChrome.backgroundColor, .dark)
                == rgba(UIColor.systemBackground, .dark))
        #expect(
            rgba(AgentActivityLockScreenChrome.actionColor, .light)
                == rgba(UIColor.label, .light))
        #expect(
            rgba(AgentActivityLockScreenChrome.actionColor, .dark)
                == rgba(UIColor.label, .dark))
        #expect(
            rgba(AgentActivityLockScreenChrome.backgroundColor, .light)
                != rgba(AgentActivityLockScreenChrome.backgroundColor, .dark))
    }

    @Test func lockScreenSemanticTextRemainsDynamicAcrossSystemAppearances() {
        let primary = UIColor(AgentActivitySemanticStyle.primary(on: .lockScreen))
        let secondary = UIColor(AgentActivitySemanticStyle.secondary(on: .lockScreen))

        #expect(rgba(primary, .light) == rgba(UIColor.label, .light))
        #expect(rgba(primary, .dark) == rgba(UIColor.label, .dark))
        #expect(rgba(secondary, .light) == rgba(UIColor.secondaryLabel, .light))
        #expect(rgba(secondary, .dark) == rgba(UIColor.secondaryLabel, .dark))
    }

    @Test func lockScreenInkMatchesPaletteForEachAppearance() {
        for (wire, palette) in Self.statuses {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let resolved = rgba(
                    UIColor(AgentActivityStatusStyle.ink(for: wire, on: .lockScreen)),
                    style)
                #expect(resolved == rgba(palette.inkUIColor, style), "\(wire) ink \(style.rawValue)")
            }
        }
    }

    @Test func lockScreenWashMatchesPaletteForEachAppearance() {
        for (wire, palette) in Self.statuses {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let resolved = rgba(
                    UIColor(AgentActivityStatusStyle.wash(for: wire, on: .lockScreen)),
                    style)
                #expect(resolved == rgba(palette.tintUIColor, style), "\(wire) wash \(style.rawValue)")
            }
        }
    }

    @Test func islandAndSmallInkStayMochaUnderLightAppearance() {
        for surface in [AgentActivitySurface.island, .small] {
            for (wire, palette) in Self.statuses {
                let resolved = rgba(
                    UIColor(AgentActivityStatusStyle.ink(for: wire, on: surface)),
                    .light)
                #expect(
                    resolved == rgba(palette.inkUIColor, .dark),
                    "\(wire) \(surface) ink must stay Mocha")
            }
        }
    }

    /// The watch shows iOS's render of the `.small` tile on a Smart Stack
    /// that turns light or dark by itself; on a light one the tile's Mocha
    /// "Done" was unreadable on white. The tile must look the same on
    /// either plate in either appearance.
    @MainActor
    @Test func smallTileLooksTheSameOnEveryPlateAndAppearance() throws {
        let presentation = configuredPresentation(
            agentCount: 3, progress: AgentProgress(steps: .init(done: 3, total: 7), phase: nil))
        for stale in [false, true] {
            var renders: Set<Data> = []
            for scheme in [ColorScheme.light, .dark] {
                for (plateName, plate) in [("white", Color.white), ("black", Color.black)] {
                    let renderer = ImageRenderer(content: AgentActivitySmallView(
                        presentation: presentation, hostID: "host", isStale: stale)
                        .frame(width: 176, height: 80)
                        .background(plate)
                        .environment(\.colorScheme, scheme))
                    renderer.scale = 2
                    let image = try #require(renderer.uiImage)
                    renders.insert(try #require(image.pngData()))
                    Attachment.record(
                        image, named: "small-tile-stale-\(stale)-\(scheme)-on-\(plateName)", as: .png)
                }
            }
            #expect(renders.count == 1, "stale \(stale): the tile changed with its plate or appearance")
        }
    }

    @Test func islandWashStaysMochaUnderLightAppearance() {
        for (wire, palette) in Self.statuses {
            let resolved = rgba(
                UIColor(AgentActivityStatusStyle.wash(for: wire, on: .island)),
                .light)
            #expect(
                resolved == rgba(palette.tintUIColor, .dark),
                "\(wire) island wash must stay Mocha")
        }
    }

    @Test func unknownWireStatusMapsToUnknownPaletteRole() {
        let bogus = "haunted"
        #expect(
            rgba(UIColor(AgentActivityStatusStyle.ink(for: bogus, on: .lockScreen)), .light)
                == rgba(AgentStatus.unknown.inkUIColor, .light))
        #expect(
            rgba(UIColor(AgentActivityStatusStyle.wash(for: bogus, on: .island)), .light)
                == rgba(AgentStatus.unknown.tintUIColor, .dark))
    }

    @Test func configuredRowsNarrateLiteralFieldsAndStatus() {
        var agent = agentDetail(paneID: "w1:p1", status: "blocked")
        agent.rows = [
            [.init(text: "**Task**"), .init(text: " · "), .init(text: "feature/one")],
            [.init(text: "/src/Waycar")],
        ]
        #expect(AgentActivityNarration.rowLabel(for: agent)
            == "**Task** · feature/one, /src/Waycar, blocked")
        #expect(String(AgentActivityFields.attributedText(
            agent.rows?[0] ?? [], rowIndex: 0, surface: .lockScreen).characters)
            == "**Task** · feature/one")
    }

    @Test func intentionallyEmptyFieldsFallBackToTheAgentKind() {
        var agent = agentDetail(paneID: "w1:p1", status: "blocked")
        agent.rows = []
        #expect(AgentActivityFields.rows(for: agent).map { $0.map(\.text) } == [["Claude"]])
        #expect(AgentActivityFields.identityTexts(for: agent) == ["Claude"])
        #expect(AgentActivityNarration.rowLabel(for: agent) == "Claude, blocked")
    }

    @Test func configuredFieldsDrawOnlyTheFirstTwoRows() {
        var agent = agentDetail(paneID: "w1:p1")
        agent.rows = (1...4).map { [.init(text: "Row \($0)")] }
        #expect(AgentActivityFields.rows(for: agent).count == 2)
        #expect(AgentActivityNarration.rowLabel(for: agent) == "Row 1, Row 2, working")
    }

    /// #190: a herdr worktree's Workspace, tab and Agent name all carry the
    /// branch, and rows 1 and 2 share one drawn line.
    @Test func repeatedValuesOnTheDrawnLineAppearOnce() {
        var agent = agentDetail(paneID: "w1:p1")
        let separator = AgentActivityDetails.Field(text: " · ")
        agent.rows = [
            [.init(text: "more-harnesses"), separator, .init(text: " more-harnesses ")],
            [.init(text: "more-harnesses")],
            [.init(text: "~/w")],
        ]
        #expect(AgentActivityFields.rows(for: agent).map { $0.map(\.text) } == [["more-harnesses"]])
        #expect(AgentActivityNarration.rowLabel(for: agent) == "more-harnesses, working")

        agent.rows = [
            [.init(text: "Waycar"), separator, .init(text: "waycar")],
            [.init(text: "reviewer"), separator, .init(text: "Waycar"), separator, .init(text: "/w")],
        ]
        #expect(AgentActivityFields.rows(for: agent).map { $0.map(\.text) }
            == [["Waycar", " · ", "waycar"], ["reviewer", " · ", "/w"]])
    }

    /// Separators are found by content, not position: rows without them,
    /// or with doubled ones, still dedupe and never keep a stray joiner.
    @Test func dedupeDoesNotAssumeAlternatingSeparators() {
        var agent = agentDetail(paneID: "w1:p1")
        let separator = AgentActivityDetails.Field(text: " · ")
        agent.rows = [
            [.init(text: "Waycar"), .init(text: "main"), .init(text: "Waycar")],
            [separator, .init(text: "main"), separator, separator, .init(text: "reviewer"), separator],
        ]
        #expect(AgentActivityFields.rows(for: agent).map { $0.map(\.text) }
            == [["Waycar", "main"], ["reviewer"]])
    }

    /// The `.small` tile names each Agent by its most specific identity
    /// value, so two Agents in one workspace never read alike.
    @Test func smallTileShortNameIsTheMostSpecificIdentityValue() {
        let separator = AgentActivityDetails.Field(text: " · ", dim: true)
        func configured(_ pane: String, _ values: [String]) -> AgentActivityDetails.AgentDetail {
            var agent = agentDetail(paneID: pane)
            agent.rows = [
                Array(values.map { AgentActivityDetails.Field(text: $0) }
                    .map { [separator, $0] }.joined().dropFirst()),
                [.init(text: "Claude")],
            ]
            return agent
        }
        let reviewer = configured("w1:p1", ["waycar", "reviewer"])
        let api = configured("w1:p2", ["waycar", "api"])
        let single = configured("w1:p3", ["ipad-keyboard-arrows"])
        // #190 dedupe runs first: the repeated value is not "more specific".
        let repeated = configured("w1:p4", ["more-harnesses", "more-harnesses"])

        #expect(AgentActivitySmallView.shortName(for: reviewer) == "reviewer")
        #expect(AgentActivitySmallView.shortName(for: api) == "api")
        #expect(AgentActivitySmallView.shortName(for: single) == "ipad-keyboard-arrows")
        #expect(AgentActivitySmallView.shortName(for: repeated) == "more-harnesses")
        #expect(AgentActivitySmallView.shortNames(for: [reviewer, api, single]) == [
            "reviewer", "api", "ipad-keyboard-arrows",
        ])

        // Legacy producer (no configured rows): herdr name, else workspace.
        var legacy = agentDetail(paneID: "w1:p5")
        #expect(AgentActivitySmallView.shortName(for: legacy) == "Waycar")
        legacy.name = "builder"
        #expect(AgentActivitySmallView.shortName(for: legacy) == "builder")
    }

    @Test func smallTileNeverRepeatsANameForDifferentIdentities() {
        var main = agentDetail(paneID: "w1:p1")
        main.rows = [[.init(text: "waycar"), .init(text: " · "), .init(text: "main")]]
        var other = agentDetail(paneID: "w2:p1")
        other.rows = [[.init(text: "mobile"), .init(text: " · "), .init(text: "main")]]

        #expect(AgentActivitySmallView.shortNames(for: [main, other])
            == ["waycar · main", "mobile · main"])
    }

    @Test func styledFieldsPreserveHexColorAndSecondarySemantics() {
        for hex in ["#abc", "#aabbcc"] {
            #expect(rgba(UIColor(AgentActivityFields.foreground(
                for: .init(text: "branch", fg: hex), rowIndex: 0, surface: .lockScreen)), .light)
                == [170, 187, 204])
        }
        for invalid in ["red", "#ggg", "#1234", "#12345678"] {
            #expect(rgba(UIColor(AgentActivityFields.foreground(
                for: .init(text: "branch", fg: invalid), rowIndex: 0, surface: .lockScreen)), .light)
                == rgba(.label, .light))
        }
        #expect(rgba(UIColor(AgentActivityFields.foreground(
            for: .init(text: "directory", dim: true), rowIndex: 0, surface: .lockScreen)), .light)
            == rgba(.secondaryLabel, .light))
        #expect(rgba(UIColor(AgentActivityFields.foreground(
            for: .init(text: "directory", dim: true), rowIndex: 1, surface: .lockScreen)), .light)
            == rgba(.tertiaryLabel, .light))
        #expect(rgba(UIColor(AgentActivityFields.foreground(
            for: .init(text: "directory", dim: true), rowIndex: 1, surface: .island)), .light)
            == rgba(.tertiaryLabel, .dark))
    }

    @MainActor
    @Test func styledFieldsChangeRenderedPixelsOnBothSurfaces() throws {
        let plain = AgentActivityDetails.Field(text: "Feature branch")
        for surface in [AgentActivitySurface.lockScreen, .island] {
            for rowIndex in [0, 1] {
                let baseline = try rowPixels(field: plain, rowIndex: rowIndex, surface: surface)
                for styled in [
                    AgentActivityDetails.Field(text: plain.text, fg: "#f00"),
                    .init(text: plain.text, bold: true),
                    .init(text: plain.text, dim: true),
                ] {
                    #expect(
                        try rowPixels(field: styled, rowIndex: rowIndex, surface: surface) != baseline,
                        "\(surface) row \(rowIndex + 1)")
                }
                let colored = try rowPixels(
                    field: .init(text: plain.text, fg: "#f00"), rowIndex: rowIndex, surface: surface)
                let dimmedColor = try rowPixels(
                    field: .init(text: plain.text, fg: "#f00", dim: true), rowIndex: rowIndex,
                    surface: surface)
                #expect(dimmedColor != colored, "\(surface) row \(rowIndex + 1): fg + dim")
            }
        }
    }

    /// Measures the rendered banner, not `sizeThatFits`: a hosting
    /// controller reports only the row frames' minimum heights and misses
    /// the text.
    @MainActor
    @Test func bannersFitTheLockScreenHeightBudget() throws {
        var cases: [(name: String, presentation: AgentActivityPresentation)] = (1...5).map {
            ("\($0)-agents", configuredPresentation(agentCount: $0))
        }
        cases.append(("80-grapheme-identity", configuredPresentation(
            agentCount: 4, identity: String(repeating: "锁", count: 80),
            secondary: String(repeating: "屏", count: 80))))
        // #189: Working rows trade their word for "3/7" and Blocked rows keep
        // a frozen rule; the 2.5 pt rule must stay inside the 28 pt row.
        let progress = AgentProgress(steps: .init(done: 3, total: 7), phase: nil)
        cases += [4, 5].map {
            ("\($0)-agents-progress", configuredPresentation(agentCount: $0, progress: progress))
        }
        cases.append(("80-grapheme-identity-progress", configuredPresentation(
            agentCount: 4, identity: String(repeating: "锁", count: 80),
            secondary: String(repeating: "屏", count: 80), progress: progress)))
        var renders: [(name: String, presentation: AgentActivityPresentation, size: DynamicTypeSize)] =
            cases.map { ($0.name, $0.presentation, .large) }
        // Dynamic Type is capped at .large; the largest sizes must render the same.
        renders.append(("4-agents-accessibility3", configuredPresentation(agentCount: 4), .accessibility3))
        renders.append((
            "4-agents-progress-accessibility3",
            configuredPresentation(agentCount: 4, progress: progress), .accessibility3))
        for (name, presentation, size) in renders {
            for stale in [false, true] {
                for scheme in [ColorScheme.light, .dark] {
                    let view = AgentActivityLockScreenView(
                        presentation: presentation, hostID: "host", isStale: stale)
                    let renderer = ImageRenderer(content: view
                        .frame(width: 360)
                        .environment(\.colorScheme, scheme)
                        .environment(\.dynamicTypeSize, size))
                    renderer.scale = 2
                    let image = try #require(renderer.uiImage)
                    let height = image.size.height
                    let label = "activity-banner-\(name)-stale-\(stale)-\(scheme)-\(Int(height.rounded(.up)))pt"
                    let estimate = AgentActivityLockScreenMetrics.height(
                        rows: presentation.lockScreenAgents(isStale: stale).count,
                        hasFooter: presentation.lockScreenTrailingCaption(isStale: stale) != nil)
                    #expect(height <= 160, "\(label): \(height) pt")
                    #expect(abs(height - estimate) <= 2, "\(label): \(height) pt, estimate \(estimate) pt")
                    Attachment.record(image, named: label, as: .png)
                }
            }
        }
    }

    /// Configured fields as the app's default layout sends them; row 3 is
    /// never drawn. Statuses cycle so the header shows several counts.
    /// `progress` goes on every Agent; only Working and Blocked draw it.
    private func configuredPresentation(
        agentCount: Int, identity: String = "waycar", secondary: String = "Claude",
        progress: AgentProgress? = nil
    ) -> AgentActivityPresentation {
        let statuses = ["blocked", "done", "working"]
        let agents = (0..<agentCount).map { index in
            var agent = agentDetail(paneID: "w1:p\(index)", status: statuses[index % 3])
            agent.progress = progress
            agent.rows = [
                [.init(text: identity, bold: true), .init(text: " · ", dim: true), .init(text: "live-activity")],
                [.init(text: secondary)],
                [.init(text: "/Users/developer/waycar", dim: true)],
            ]
            return agent
        }
        let count = { (status: String) in agents.filter { $0.status == status }.count }
        return .detailed(details: .init(hostName: "mbp", agents: agents),
            counts: .init(
                working: count("working"), blocked: count("blocked"), done: count("done"), idle: 2))
    }

    @MainActor
    private func rowPixels(
        field: AgentActivityDetails.Field, rowIndex: Int, surface: AgentActivitySurface
    ) throws -> Data {
        var agent = agentDetail(paneID: "w1:p1")
        agent.rows = rowIndex == 0 ? [[field]] : [[.init(text: "Primary")], [field]]
        let renderer = ImageRenderer(content: AgentActivityRowView(agent: agent, surface: surface)
            .frame(width: 300, height: 50)
            .background(surface == .lockScreen ? Color.white : Color.black)
            .environment(\.colorScheme, surface == .lockScreen ? .light : .dark))
        renderer.scale = 1
        return try #require(renderer.uiImage?.pngData())
    }

    private func rgba(_ color: UIColor, _ style: UIUserInterfaceStyle) -> [Int] {
        rgba(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)))
    }

    private func agentDetail(
        paneID: String, status: String, progress: AgentProgress?
    ) -> AgentActivityDetails.AgentDetail {
        var agent = agentDetail(paneID: paneID, status: status)
        agent.progress = progress
        return agent
    }

    @Test func narrationSpeaksTheDrawnEstimate() {
        let steps = AgentProgress(steps: .init(done: 3, total: 7), phase: nil)
        let phase = AgentProgress(steps: nil, phase: .verifying)

        #expect(
            AgentActivityNarration.rowLabel(
                for: agentDetail(paneID: "w1:p1", status: "working", progress: steps))
                == "Waycar, Claude, working, 3 of 7 steps done")
        #expect(
            AgentActivityNarration.rowLabel(
                for: agentDetail(paneID: "w1:p2", status: "blocked", progress: phase))
                == "Waycar, Claude, blocked, verifying")
        // Done draws no bar, so it says no estimate a stray producer sent.
        #expect(
            AgentActivityNarration.rowLabel(
                for: agentDetail(paneID: "w1:p3", status: "done", progress: steps))
                == "Waycar, Claude, done")
    }

    @Test func onlyWorkingTradesItsStatusWordForTheEstimate() {
        let steps = AgentProgress(steps: .init(done: 3, total: 7), phase: nil)
        let phase = AgentProgress(steps: nil, phase: .implementing)

        #expect(AgentActivityProgressCopy.trailingLabel(
            for: agentDetail(paneID: "w1:p1", status: "working", progress: steps)) == "3/7")
        #expect(AgentActivityProgressCopy.trailingLabel(
            for: agentDetail(paneID: "w1:p2", status: "working", progress: phase)) == "Building")
        #expect(AgentActivityProgressCopy.trailingLabel(
            for: agentDetail(paneID: "w1:p3", status: "blocked", progress: steps)) == "Blocked")
        #expect(AgentActivityProgressCopy.trailingLabel(
            for: agentDetail(paneID: "w1:p4", status: "working", progress: nil)) == "Working")
        // Blocked keeps its frozen bar; Done never draws one.
        #expect(AgentActivityProgressCopy.drawnProgress(
            for: agentDetail(paneID: "w1:p5", status: "blocked", progress: steps)) == steps)
        #expect(AgentActivityProgressCopy.drawnProgress(
            for: agentDetail(paneID: "w1:p6", status: "done", progress: steps)) == nil)
    }

    @Test func compactBarsReplaceTheCountOnlyForAWorkingLeadWithAnEstimate() {
        let steps = AgentProgress(steps: .init(done: 1, total: 4), phase: nil)
        let working = (0..<4).map { index in
            agentDetail(paneID: "w1:p\(index)", status: "working", progress: index == 2 ? steps : nil)
        }
        let withEstimate = AgentActivityPresentation.detailed(
            details: .init(hostName: "mbp", agents: working),
            counts: .init(working: 4, blocked: 0, done: 0))
        #expect(withEstimate.compactProgressAgents?.map(\.paneID) == ["w1:p0", "w1:p1", "w1:p2"])

        let blockedLead = AgentActivityPresentation.detailed(
            details: .init(
                hostName: "mbp",
                agents: [agentDetail(paneID: "w1:p9", status: "blocked", progress: steps)] + working),
            counts: .init(working: 4, blocked: 1, done: 0))
        #expect(blockedLead.compactProgressAgents == nil)

        let noEstimate = AgentActivityPresentation.detailed(
            details: .init(hostName: "mbp", agents: working.map { agentDetail(paneID: $0.paneID) }),
            counts: .init(working: 4, blocked: 0, done: 0))
        #expect(noEstimate.compactProgressAgents == nil)
        #expect(
            AgentActivityPresentation.countsOnly(counts: .init(working: 2, blocked: 0, done: 0))
                .compactProgressAgents == nil)
    }

    private func rgba(_ color: UIColor) -> [Int] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded()),
        ]
    }
}
