import SwiftUI
import Testing

@testable import Waycar

@Suite("Console slide-over geometry")
struct ConsoleSlideOverGeometryTests {
    private let column = ConsoleSplitPresentation.ColumnWidth(minimum: 320, ideal: 380, maximum: 440)
    private var landscape: ConsoleSlideOverGeometry {
        ConsoleSlideOverGeometry(containerWidth: 1194, column: column)
    }

    @Test(arguments: [
        (1194, 380),  // Wide: the ideal width.
        (700, 350),  // Narrow window: half of it.
        (600, 320),  // Never below the minimum...
        (300, 300),  // ...unless the window itself is narrower.
        (0, 0),
    ] as [(CGFloat, CGFloat)])
    func sidebarWidthClampsToTheWindow(containerWidth: CGFloat, expected: CGFloat) {
        let geometry = ConsoleSlideOverGeometry(containerWidth: containerWidth, column: column)
        #expect(geometry.sidebarWidth == expected)
    }

    @Test func offsetFollowsProgressAndClamps() {
        #expect(landscape.detailOffset(progress: 0) == CGFloat(0))
        #expect(landscape.detailOffset(progress: 0.5) == CGFloat(190))
        #expect(landscape.detailOffset(progress: 1) == CGFloat(380))
        #expect(landscape.detailOffset(progress: 1.4) == CGFloat(380))
        #expect(landscape.detailOffset(progress: -0.2) == CGFloat(0))
    }

    @Test func agentNarrowsOnlyAtRestBesideTheOpenList() {
        #expect(ConsoleSlideOverGeometry.restsNarrowed(
            reveal: .beside, isSidebarVisible: true, isMoving: false))
        #expect(!ConsoleSlideOverGeometry.restsNarrowed(
            reveal: .beside, isSidebarVisible: true, isMoving: true))
        #expect(!ConsoleSlideOverGeometry.restsNarrowed(
            reveal: .beside, isSidebarVisible: false, isMoving: false))
        #expect(!ConsoleSlideOverGeometry.restsNarrowed(
            reveal: .push, isSidebarVisible: true, isMoving: false))
        #expect(landscape.detailWidth(isNarrowed: true) == CGFloat(814))
        #expect(landscape.detailWidth(isNarrowed: false) == CGFloat(1194))
    }

    @Test func cornersRampInOverTheEdgeRampDistance() {
        let geometry = ConsoleSlideOverGeometry(containerWidth: 600, column: column)
        let rampEnd = ConsoleSlideOverGeometry.edgeRampDistance / geometry.sidebarWidth
        let fullRadius = ConsoleSlideOverGeometry.cornerRadius
        // A closed Agent against the screen edge keeps square corners.
        #expect(geometry.cornerRadius(progress: 0) == CGFloat(0))
        let midRamp = geometry.cornerRadius(progress: rampEnd / 2)
        #expect(midRamp > 0 && midRamp < fullRadius)
        #expect(abs(geometry.cornerRadius(progress: rampEnd) - fullRadius) < 1e-9)
        #expect(geometry.cornerRadius(progress: 1) == fullRadius)
    }

    @Test func listRecedesAndDimsAsItIsCovered() {
        // The open list is drawn as it is.
        #expect(ConsoleSlideOverGeometry.sidebarScale(progress: 1) == CGFloat(1))
        #expect(ConsoleSlideOverGeometry.sidebarDim(progress: 1) == Double(0))
        #expect(ConsoleSlideOverGeometry.sidebarScale(progress: 0) < 1)
        #expect(ConsoleSlideOverGeometry.sidebarDim(progress: 0) > 0)
        // Clamped outside 0...1.
        #expect(ConsoleSlideOverGeometry.sidebarScale(progress: 2)
            == ConsoleSlideOverGeometry.sidebarScale(progress: 1))
        #expect(ConsoleSlideOverGeometry.sidebarDim(progress: -1)
            == ConsoleSlideOverGeometry.sidebarDim(progress: 0))
    }

    @Test func lightModeShadowDeepensAsTheAgentCoversTheList() {
        let open = ConsoleSlideOverGeometry.edgeShadowOpacity(progress: 1, colorScheme: .light)
        let midSlide = ConsoleSlideOverGeometry.edgeShadowOpacity(progress: 0.5, colorScheme: .light)
        let covering = ConsoleSlideOverGeometry.edgeShadowOpacity(progress: 0, colorScheme: .light)
        #expect(open < midSlide && midSlide < covering)
        #expect(open < ConsoleSlideOverGeometry.edgeShadowOpacity(progress: 1, colorScheme: .dark))
    }

    @Test func dragMovesFromWhereTheAgentRestedAndClamps() {
        #expect(landscape.dragProgress(fromOpen: false, translation: 95) == CGFloat(0.25))
        #expect(landscape.dragProgress(fromOpen: true, translation: -95) == CGFloat(0.75))
        #expect(landscape.dragProgress(fromOpen: false, translation: -50) == CGFloat(0))
        #expect(landscape.dragProgress(fromOpen: true, translation: 50) == CGFloat(1))
        #expect(landscape.dragProgress(fromOpen: false, translation: 1000) == CGFloat(1))
    }

    @Test func aStillFingerSettlesOnTheSideItPassedHalfwayOn() {
        #expect(!landscape.settlesOpen(fromOpen: false, translation: 190, velocity: 0))
        #expect(landscape.settlesOpen(fromOpen: false, translation: 191, velocity: 0))
        #expect(!landscape.settlesOpen(fromOpen: true, translation: -191, velocity: 0))
        #expect(landscape.settlesOpen(fromOpen: true, translation: -189, velocity: 0))
    }

    @Test func flingCoastsAboutHalfASecondOfItsSpeed() {
        #expect(ConsoleSlideOverGeometry.projectedTranslation(35, velocity: 0) == 35)
        let leftward = ConsoleSlideOverGeometry.projectedTranslation(0, velocity: -1000)
        let rightward = ConsoleSlideOverGeometry.projectedTranslation(0, velocity: 1000)
        #expect((-600 ... -400).contains(leftward))
        #expect((400 ... 600).contains(rightward))
    }

    @Test func quickShortFlickClosesAndOpens() {
        // 20 points at 500 points a second: SwiftUI's quarter-second
        // prediction (145 points) stopped short of halfway and sprang back.
        #expect(!landscape.settlesOpen(fromOpen: true, translation: -20, velocity: -500))
        #expect(landscape.settlesOpen(fromOpen: false, translation: 20, velocity: 500))
    }

    @Test func slowShortDragStaysWhereItRested() {
        #expect(landscape.settlesOpen(fromOpen: true, translation: -40, velocity: -100))
        #expect(!landscape.settlesOpen(fromOpen: false, translation: 40, velocity: 100))
    }

    @Test func flingDirectionOutweighsWhereTheFingerLifted() {
        // Past halfway toward closed, then thrown back open.
        #expect(landscape.settlesOpen(fromOpen: true, translation: -250, velocity: 300))
        // Short of halfway toward closed, but thrown on through it.
        #expect(!landscape.settlesOpen(fromOpen: true, translation: -120, velocity: -200))
    }

    @Test func zeroWidthWindowKeepsTheRestingState() {
        let empty = ConsoleSlideOverGeometry(containerWidth: 0, column: column)
        #expect(empty.dragProgress(fromOpen: true, translation: -40) == CGFloat(1))
        #expect(empty.dragProgress(fromOpen: false, translation: 40) == CGFloat(0))
        #expect(empty.edgeDepth(progress: 1) == CGFloat(0))
    }

    @Test func headerStartsClearOfTheToggleAndSharesItsLine() {
        let toggleSize = ConsoleSlideOverGeometry.toggleSize
        let slot = ConsoleSlideOverGeometry.headerSlot(windowControlsWidth: 0)
        #expect(slot.leading
            >= ConsoleSlideOverGeometry.toggleLeading(windowControlsWidth: 0) + toggleSize)
        #expect(slot.centerY == ConsoleSlideOverGeometry.toggleTopInset + toggleSize / 2)
        let controlsWidth: CGFloat = 70
        let windowed = ConsoleSlideOverGeometry.headerSlot(windowControlsWidth: controlsWidth)
        #expect(windowed.leading == slot.leading + controlsWidth)
        #expect(windowed.centerY == slot.centerY)
    }

    @Test func headerRowCentersOnTheToggleLine() {
        let slot = ConsoleSlideOverGeometry.headerSlot(windowControlsWidth: 0)
        let rowHeight: CGFloat = 34
        let verticalPadding: CGFloat = 6
        let top = slot.topPadding(rowHeight: rowHeight, verticalPadding: verticalPadding)
        #expect(top + verticalPadding + rowHeight / 2 == slot.centerY)
    }
}
