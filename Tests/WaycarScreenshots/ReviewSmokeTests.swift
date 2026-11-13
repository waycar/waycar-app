import XCTest

/// The walkthrough an App Reviewer takes on a fresh install. `make review-smoke`
/// (scripts/review-smoke.sh) runs it against the Release app, installed over
/// the last approved release, on simulators shaped like the reviewer's
/// devices. The app launches with no arguments: no demo mode, and a Release
/// build has no DEBUG code to enable anyway.
final class ReviewSmokeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The first UI test session on a freshly booted simulator fails at its
    /// first query with kAXError -25218 (iOS 26.4 and 27.2); the next one
    /// works. review-smoke runs this first, without launching the app, so
    /// the walkthrough's launch stays the first one after the update.
    @MainActor
    func testAccessibilityWarmUp() {
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(XCUIApplication(bundleIdentifier: "com.apple.springboard").exists)
    }

    @MainActor
    func testReviewerWalkthrough() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()

        // The one-time analytics question; a reviewer may decline it.
        let consent = app.alerts["Help make Waycar better?"]
        if consent.waitForExistence(timeout: 15) {
            consent.buttons["Don't Allow"].tap()
        }

        // First run: no Host yet, so the setup steps with the Sample Host.
        let sample = app.buttons["setup.sample"]
        require(sample, in: app, "The first-run screen never showed the Sample Host.")
        XCTAssertTrue(app.staticTexts["Add Your First Host"].exists, "The first-run heading is missing.")
        sample.tap()
        require(app.buttons["Close sample"], in: app, "The Sample never opened.")

        openAgentAndReturn(app)

        // New Agent (+) on the Sample offers to connect a real machine instead.
        app.buttons["New Agent"].firstMatch.tap()
        let connect = app.staticTexts["Connect your machine"]
        require(connect, in: app, "New Agent did not open.")
        app.navigationBars.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(connect.waitForNonExistence(timeout: 10), "Done did not close New Agent.")

        if isPad {
            // Landscape rests the Agent list beside the detail.
            XCUIDevice.shared.orientation = .landscapeLeft
            requireHittable(app.buttons["Checkout"].firstMatch, in: app, "Landscape lost the Agent list.")
            XCUIDevice.shared.orientation = .portrait
            require(app.buttons["Close sample"], in: app, "The Sample did not survive portrait.")
        }

        // Settings inside the Sample offers to connect too; the real one
        // is the first-run screen's.
        app.buttons["Close sample"].tap()
        require(app.buttons["setup.sample"], in: app, "Closing the Sample did not return to the first-run screen.")
        checkSettings(app)
    }

    /// An Agent card opens that Agent's screen, and the way back shows the
    /// cards again: Back on iPhone, the sidebar button on iPad, whose
    /// portrait layout keeps the Agent list closed.
    @MainActor
    private func openAgentAndReturn(_ app: XCUIApplication) {
        let card = app.buttons["Checkout"].firstMatch
        if isPad {
            require(app.buttons["Show Agents"], in: app, "The Sample's empty detail never appeared.")
            app.buttons["Show Agents"].tap()
        }
        requireHittable(card, in: app, "The Sample's Agent cards never appeared.")
        card.tap()
        require(
            app.descendants(matching: .any)["Agent status"].firstMatch, in: app, "The Agent never opened.")
        app.buttons[isPad ? "Show Sidebar" : "Back"].firstMatch.tap()
        requireHittable(card, in: app, "The way back did not return to the Agent cards.")
    }

    /// Settings, its About section, then Help, then closed again. CarPlay
    /// Voice is listed exactly where `CarPlaySupport.isAvailable` says: an
    /// iPhone on iOS 26.4 or later, never an iPad. A Release build never
    /// lists Admin.
    @MainActor
    private func checkSettings(_ app: XCUIApplication) {
        app.buttons["Settings"].firstMatch.tap()
        let settings = app.navigationBars["Settings"]
        require(settings, in: app, "Settings did not open.")
        require(app.buttons["settings.chatMode"], in: app, "Settings' first section never appeared.")

        let carPlay = app.buttons["settings.carPlayVoice"]
        let system = ProcessInfo.processInfo.operatingSystemVersion
        if !isPad && (system.majorVersion, system.minorVersion) >= (26, 4) {
            XCTAssertTrue(carPlay.exists, "An iPhone on iOS 26.4+ must list CarPlay Voice.")
        } else {
            XCTAssertFalse(carPlay.exists, "This device must show no CarPlay UI.")
        }
        XCTAssertFalse(app.buttons["settings.admin"].exists, "A Release build must not list Admin.")

        // About: the Version row reads as text, which is never hittable, so
        // scroll until the section's Changelog row is.
        let changelog = app.buttons["settings.about.changelog"]
        for _ in 0..<8 where !(changelog.exists && changelog.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(changelog.isHittable, "Settings never scrolled to About.")
        XCTAssertTrue(app.staticTexts["Version"].exists, "About shows no Version.")

        app.buttons["settings.support.help"].tap()
        let help = app.navigationBars["Help"]
        require(help, in: app, "Help did not open.")
        help.buttons.element(boundBy: 0).tap()
        require(settings, in: app, "Back from Help did not return to Settings.")
        settings.buttons["Done"].tap()
        XCTAssertTrue(settings.waitForNonExistence(timeout: 10), "Settings did not close.")
    }

    @MainActor
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// Waits for the element; on failure, logs the screen's element tree so a
    /// run on a reviewer device says what was there instead.
    @MainActor
    private func require(
        _ element: XCUIElement, in app: XCUIApplication, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard !element.waitForExistence(timeout: 30) else { return }
        print(app.debugDescription)
        XCTFail(message, file: file, line: line)
    }

    /// As `require`, until the element can be tapped: on iPad the closed
    /// Agent list keeps its cards in the tree.
    @MainActor
    private func requireHittable(
        _ element: XCUIElement, in app: XCUIApplication, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        guard XCTWaiter.wait(for: [hittable], timeout: 30) != .completed else { return }
        print(app.debugDescription)
        XCTFail(message, file: file, line: line)
    }
}
