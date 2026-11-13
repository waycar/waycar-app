import SwiftUI
import Testing

@testable import Waycar

@Suite("Console split presentation")
struct ConsoleSplitPresentationTests {
    private let landscape = ConsoleSplitPresentation(
        horizontalSizeClass: .regular, size: CGSize(width: 1194, height: 834))
    private let portrait = ConsoleSplitPresentation(
        horizontalSizeClass: .regular, size: CGSize(width: 834, height: 1194))

    @Test func regularLandscapeShowsBothColumns() {
        #expect(landscape.defaultVisibility == .all)
        #expect(landscape.usesRegularColumns)
        #expect(landscape.sidebarWidth == .init(minimum: 320, ideal: 380, maximum: 440))
        #expect(landscape.usesSlideOver)
        #expect(landscape.sidebarReveal == .beside)
    }

    @Test func regularPortraitShowsDetail() {
        #expect(portrait.defaultVisibility == .detailOnly)
        #expect(portrait.usesRegularColumns)
        #expect(portrait.sidebarWidth == .init(minimum: 320, ideal: 380, maximum: 400))
        #expect(portrait.usesSlideOver)
        #expect(portrait.sidebarReveal == .push)
    }

    @Test(arguments: [false, true])
    func compactRetainsAutomaticVisibility(isLandscape: Bool) {
        let presentation = ConsoleSplitPresentation(
            horizontalSizeClass: .compact,
            size: isLandscape ? CGSize(width: 844, height: 390) : CGSize(width: 390, height: 844))
        #expect(presentation.defaultVisibility == .automatic)
        #expect(!presentation.usesRegularColumns)
        #expect(presentation.sidebarWidth == .init(minimum: 320, ideal: 380, maximum: nil))
    }

    @Test func unknownSizeClassUsesAutomaticVisibility() {
        let presentation = ConsoleSplitPresentation(
            horizontalSizeClass: nil, size: CGSize(width: 1194, height: 834))
        #expect(presentation.defaultVisibility == .automatic)
        #expect(!presentation.usesRegularColumns)
    }

    @Test func squareWindowShowsDetail() {
        let presentation = ConsoleSplitPresentation(
            horizontalSizeClass: .regular, size: CGSize(width: 900, height: 900))
        #expect(presentation.defaultVisibility == .detailOnly)
        #expect(presentation.sidebarReveal == .push)
    }

    @Test func safeAreaInsetsPreservePortraitAspectWithKeyboard() {
        let presentation = ConsoleSplitPresentation(
            horizontalSizeClass: .regular, size: CGSize(width: 834, height: 700),
            safeAreaInsets: EdgeInsets(top: 24, leading: 0, bottom: 470, trailing: 0))
        #expect(presentation.defaultVisibility == .detailOnly)
    }

    @Test func portraitSeedFollowsRotationUntilUserToggles() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: portrait)
        #expect(state.visibility == .detailOnly)
        state.update(from: landscape)
        #expect(state.visibility == .all)
        state.update(from: portrait)
        #expect(state.visibility == .detailOnly)
        #expect(state.userVisibility == nil)
    }

    @Test func compactSeedFollowsRegularWidthLayout() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: ConsoleSplitPresentation(
            horizontalSizeClass: .compact, size: CGSize(width: 390, height: 844)))
        #expect(state.visibility == .automatic)
        state.update(from: landscape)
        #expect(state.visibility == .all)
        state.update(from: portrait)
        #expect(state.visibility == .detailOnly)
    }

    @Test(arguments: [false, true])
    func stableSystemToggleSurvivesRotation(startInPortrait: Bool) {
        var state = ConsoleSplitVisibilityState()
        let initial = startInPortrait ? portrait : landscape
        state.update(from: initial)
        let chosen: NavigationSplitViewVisibility = startInPortrait ? .all : .detailOnly
        state.systemDidChangeVisibility(chosen, presentation: initial)
        #expect(state.userVisibility == chosen)
        state.update(from: startInPortrait ? landscape : portrait)
        #expect(state.visibility == chosen)
        state.update(from: initial)
        #expect(state.visibility == chosen)
    }

    @Test func transitionWriteBacksBeforeUpdateDoNotBecomeIntent() {
        var state = ConsoleSplitVisibilityState()
        state.systemDidChangeVisibility(.all, presentation: portrait)
        #expect(state.userVisibility == nil)
        state.update(from: portrait)
        state.systemDidChangeVisibility(.detailOnly, presentation: landscape)
        #expect(state.userVisibility == nil)
        state.update(from: landscape)
        #expect(state.visibility == .all)
    }

    @Test func outgoingLayoutWriteBackAfterUpdateCannotOverrideNewDefault() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: portrait)
        state.update(from: landscape)
        state.systemDidChangeVisibility(.detailOnly, presentation: portrait)
        #expect(state.visibility == .all)
        #expect(state.userVisibility == nil)
    }

    @Test func seedAcknowledgementDoesNotBecomeIntent() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: portrait)
        state.systemDidChangeVisibility(.detailOnly, presentation: portrait)
        #expect(state.reportedSidebarVisibility == false)
        #expect(state.userVisibility == nil)
        state.update(from: landscape)
        state.systemDidChangeVisibility(.all, presentation: landscape)
        #expect(state.reportedSidebarVisibility == true)
        #expect(state.userVisibility == nil)
    }

    @Test func sameAspectResizePreservesPolicyAndVisibilityReport() {
        let resizedPortrait = ConsoleSplitPresentation(
            horizontalSizeClass: .regular, size: CGSize(width: 800, height: 1100))
        #expect(resizedPortrait == portrait)
        var state = ConsoleSplitVisibilityState()
        state.update(from: portrait)
        state.systemDidChangeVisibility(.all, presentation: portrait)
        state.update(from: resizedPortrait)
        #expect(state.reportedSidebarVisibility == true)
        #expect(!state.showsAgentsAction)
        #expect(state.userVisibility == .all)
        state.systemDidChangeVisibility(.detailOnly, presentation: resizedPortrait)
        #expect(state.userVisibility == nil)
    }

    @Test func policyChangesAtAspectAndSizeClassBoundaries() {
        let compactPortrait = ConsoleSplitPresentation(
            horizontalSizeClass: .compact, size: CGSize(width: 834, height: 1194))
        #expect(portrait != landscape)
        #expect(portrait != compactPortrait)
        #expect(portrait != ConsoleSplitPresentation(horizontalSizeClass: .regular, size: .zero))
    }

    @Test func compactWriteBackDoesNotReplaceRegularUserChoice() {
        let compact = ConsoleSplitPresentation(
            horizontalSizeClass: .compact, size: CGSize(width: 390, height: 844))
        var state = ConsoleSplitVisibilityState()
        state.update(from: portrait)
        state.systemDidChangeVisibility(.all, presentation: portrait)
        state.update(from: compact)
        state.systemDidChangeVisibility(.detailOnly, presentation: compact)
        #expect(state.userVisibility == .all)
        state.update(from: landscape)
        #expect(state.visibility == .all)
    }

    @Test func layoutChangeInvalidatesThePreviousVisibilityReport() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: landscape)
        state.systemDidChangeVisibility(.all, presentation: landscape)
        #expect(state.reportedSidebarVisibility == true)
        state.update(from: portrait)
        #expect(state.reportedSidebarVisibility == nil)
        #expect(state.visibility == .detailOnly)
    }

    @Test func automaticReportDoesNotClaimVisibleOrRecordIntent() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: portrait)
        state.systemDidChangeVisibility(.automatic, presentation: portrait)
        // On the iPhone test destination, automatic resolves to the concrete detailOnly value.
        #expect(state.reportedSidebarVisibility == false)
        #expect(state.isSidebarVisible == false)
        #expect(state.showsAgentsAction)
        #expect(state.userVisibility == nil)
        state.setSidebarVisible(true)
        #expect(state.visibility == .all)
        #expect(!state.showsAgentsAction)
    }

    @Test(arguments: [false, true])
    func portraitRevealThenDismissRestoresLandscapeDefault(useShowAgents: Bool) {
        var state = ConsoleSplitVisibilityState()
        state.update(from: portrait)
        if useShowAgents {
            state.setSidebarVisible(true)
        } else {
            state.systemDidChangeVisibility(.all, presentation: portrait)
        }
        #expect(state.userVisibility == .all)
        state.systemDidChangeVisibility(.detailOnly, presentation: portrait)
        #expect(state.userVisibility == nil)
        state.update(from: landscape)
        #expect(state.visibility == .all)
    }

    @Test func landscapeHideSurvivesPortraitRoundTripAndAcknowledgement() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: landscape)
        state.systemDidChangeVisibility(.detailOnly, presentation: landscape)
        #expect(state.userVisibility == .detailOnly)
        state.update(from: portrait)
        state.systemDidChangeVisibility(.detailOnly, presentation: portrait)
        #expect(state.userVisibility == .detailOnly)
        state.update(from: landscape)
        #expect(state.visibility == .detailOnly)
    }

    @Test func showingAgainInLandscapeClearsPreference() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: landscape)
        state.systemDidChangeVisibility(.detailOnly, presentation: landscape)
        state.update(from: portrait)
        state.update(from: landscape)
        state.systemDidChangeVisibility(.all, presentation: landscape)
        #expect(state.userVisibility == nil)
        state.update(from: portrait)
        #expect(state.visibility == .detailOnly)
    }

    @Test func showAgentsClearsLandscapeHidePreference() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: landscape)
        state.systemDidChangeVisibility(.detailOnly, presentation: landscape)
        state.setSidebarVisible(true)
        #expect(state.visibility == .all)
        #expect(state.userVisibility == nil)
        state.update(from: portrait)
        #expect(state.visibility == .detailOnly)
    }

    @Test(arguments: [false, true])
    func visibleLandscapeHidesShowAgentsAndPressIsNoOp(withSystemEcho: Bool) {
        var state = ConsoleSplitVisibilityState()
        state.update(from: landscape)
        if withSystemEcho {
            state.systemDidChangeVisibility(.all, presentation: landscape)
        }
        #expect(!state.showsAgentsAction)
        let empty = ConsoleEmptyDetailPresentation(showsAgentsAction: state.showsAgentsAction)
        #expect(!empty.actions.contains(.showAgents))
        state.setSidebarVisible(true)
        #expect(state.visibility == .all)
        #expect(state.userVisibility == nil)
        state.update(from: portrait)
        #expect(state.visibility == .detailOnly)
    }

    @Test func concreteVisibleReportHidesActionAndRepeatedShowPreservesChoice() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: portrait)
        state.systemDidChangeVisibility(.all, presentation: portrait)
        #expect(!state.showsAgentsAction)
        state.setSidebarVisible(true)
        #expect(state.visibility == .all)
        #expect(state.isSidebarVisible == true)
        #expect(state.userVisibility == .all)
    }

    @Test func showAgentsRevealsHiddenSidebarOnceWithoutNeedingEcho() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: portrait)
        #expect(state.showsAgentsAction)
        state.systemDidChangeVisibility(.detailOnly, presentation: portrait)
        state.setSidebarVisible(true)
        #expect(state.visibility == .all)
        #expect(state.userVisibility == .all)
        #expect(!state.showsAgentsAction)
        state.setSidebarVisible(true)
        #expect(state.visibility == .all)
        #expect(state.userVisibility == .all)
    }

    @Test(arguments: [CGSize.zero, CGSize(width: 0, height: 834), CGSize(width: 1194, height: 0)])
    func zeroSizedPassDoesNotSeedOrReplaceLayout(size: CGSize) {
        let invalid = ConsoleSplitPresentation(
            horizontalSizeClass: .regular, size: size,
            safeAreaInsets: EdgeInsets(top: 24, leading: 20, bottom: 20, trailing: 20))
        #expect(!invalid.hasUsableSize)
        var state = ConsoleSplitVisibilityState()
        state.update(from: invalid)
        #expect(state.visibility == .automatic)
        #expect(state.userVisibility == nil)
        state.update(from: landscape)
        #expect(state.visibility == .all)
        state.update(from: invalid)
        #expect(state.visibility == .all)
        // The layout itself must not swap away (rebuilding the Agent) on such a pass.
        #expect(invalid.usesSlideOver)
    }

    @Test func iPhoneAtRegularWidthKeepsTheSplitView() {
        let proMaxLandscape = ConsoleSplitPresentation(
            horizontalSizeClass: .regular, size: CGSize(width: 956, height: 440), idiom: .phone)
        #expect(proMaxLandscape.usesRegularColumns)
        #expect(!proMaxLandscape.usesSlideOver)
        #expect(proMaxLandscape.defaultVisibility == .all)
    }

    @Test func iPadSplitViewSliceKeepsTheSplitView() {
        let splitViewSlice = ConsoleSplitPresentation(
            horizontalSizeClass: .compact, size: CGSize(width: 375, height: 1194), idiom: .pad)
        #expect(!splitViewSlice.usesSlideOver)
    }

    @Test(arguments: [false, true])
    func toggledChoiceSurvivesRotation(startInPortrait: Bool) {
        var state = ConsoleSplitVisibilityState()
        let initial = startInPortrait ? portrait : landscape
        state.update(from: initial)
        // Against each orientation's default: open in portrait, closed in landscape.
        state.setSidebarVisible(startInPortrait)
        #expect(state.isSidebarVisible == startInPortrait)
        state.update(from: startInPortrait ? landscape : portrait)
        #expect(state.isSidebarVisible == startInPortrait)
        state.update(from: initial)
        #expect(state.isSidebarVisible == startInPortrait)
    }

    @Test(arguments: [false, true])
    func choosingTheDefaultLetsRotationLeadAgain(startInPortrait: Bool) {
        var state = ConsoleSplitVisibilityState()
        let initial = startInPortrait ? portrait : landscape
        state.update(from: initial)
        state.setSidebarVisible(startInPortrait)
        state.setSidebarVisible(!startInPortrait)
        #expect(state.userVisibility == nil)
        state.update(from: startInPortrait ? landscape : portrait)
        #expect(state.isSidebarVisible == startInPortrait)
    }

    @Test func openingAnAgentClosesThePortraitListWithoutAPreference() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: portrait)
        state.setSidebarVisible(true)
        #expect(state.agentOpenClosesList)
        state.agentDidOpen()
        #expect(state.isSidebarVisible == false)
        #expect(state.userVisibility == nil)
        // No preference: rotating to landscape shows its list again.
        state.update(from: landscape)
        #expect(state.isSidebarVisible == true)
    }

    @Test func openingAnAgentLeavesTheLandscapeListOpen() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: landscape)
        #expect(!state.agentOpenClosesList)
        state.agentDidOpen()
        #expect(state.isSidebarVisible == true)
    }

    @Test func openingAnAgentWithTheListClosedKeepsTheLandscapeHide() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: landscape)
        state.setSidebarVisible(false)
        state.update(from: portrait)
        #expect(!state.agentOpenClosesList)
        state.agentDidOpen()
        state.update(from: landscape)
        #expect(state.isSidebarVisible == false)
    }

    @Test func openingAnAgentLeavesTheIPhoneSplitViewAlone() {
        let phone = ConsoleSplitPresentation(
            horizontalSizeClass: .compact, size: CGSize(width: 390, height: 844), idiom: .phone)
        var state = ConsoleSplitVisibilityState()
        state.update(from: phone)
        state.setSidebarVisible(true)
        #expect(!state.agentOpenClosesList)
        state.agentDidOpen()
        #expect(state.isSidebarVisible == true)
    }

    @Test func rotationAnswersWithTheDefaultItWillApplyBeforeItIsApplied() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: landscape)
        #expect(state.isSidebarVisible(applying: portrait) == false)
        state.update(from: portrait)
        #expect(state.isSidebarVisible == false)
    }

    @Test func rotationAnswersWithTheUserChoiceBeforeItIsApplied() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: landscape)
        state.setSidebarVisible(false)
        state.update(from: portrait)
        // Landscape's default shows the list; the hide chosen there wins.
        #expect(state.isSidebarVisible(applying: landscape) == false)
        state.update(from: landscape)
        #expect(state.isSidebarVisible == false)
    }

    @Test func appliedPresentationAnswersWithTheCurrentState() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: portrait)
        // Against portrait's default: the list the user opened.
        state.setSidebarVisible(true)
        #expect(state.isSidebarVisible(applying: portrait) == true)
    }

    @Test func zeroSizedPassAnswersWithTheCurrentState() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: landscape)
        let invalid = ConsoleSplitPresentation(horizontalSizeClass: .regular, size: .zero)
        #expect(state.isSidebarVisible(applying: invalid) == true)
    }

    @Test func searchRevealsTheHiddenSlideOverListAsAToggleWould() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: portrait)
        let revealed = state.revealForSearch()
        #expect(revealed)
        #expect(state.isSidebarVisible == true)
        // Against portrait's default, so it is kept like a toggle's choice.
        #expect(state.userVisibility == .all)
    }

    @Test func searchLeavesAVisibleSlideOverListAsItIs() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: landscape)
        let revealed = state.revealForSearch()
        #expect(!revealed)
        #expect(state.isSidebarVisible == true)
        #expect(state.userVisibility == nil)
    }

    @Test func searchLeavesTheIPhoneSplitViewAlone() {
        let phone = ConsoleSplitPresentation(
            horizontalSizeClass: .compact, size: CGSize(width: 390, height: 844), idiom: .phone)
        var state = ConsoleSplitVisibilityState()
        state.update(from: phone)
        let revealed = state.revealForSearch()
        #expect(!revealed)
        #expect(state.visibility == .automatic)
        #expect(state.userVisibility == nil)
    }

    @Test func userChoiceReplacesAnEarlierSystemReport() {
        var state = ConsoleSplitVisibilityState()
        state.update(from: landscape)
        state.systemDidChangeVisibility(.all, presentation: landscape)
        state.setSidebarVisible(false)
        #expect(state.isSidebarVisible == false)
        #expect(state.showsAgentsAction)
    }
}
