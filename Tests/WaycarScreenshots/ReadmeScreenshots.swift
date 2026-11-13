import XCTest

/// Captures the README screenshots from the DEBUG simulator demo composition
/// (`DemoScreenshotMode`), which renders fixture Hosts and Agents without SSH.
/// Run through `make screenshots`; each test writes one PNG named after the
/// surface into `$WAYCAR_SCREENSHOT_DIR/iphone` or `/ipad`, so one run can
/// target both simulators at once.
final class ReadmeScreenshots: XCTestCase {
    @MainActor
    private var outputDirectory: URL {
        get throws {
            let path = ProcessInfo.processInfo.environment["WAYCAR_SCREENSHOT_DIR"] ?? ""
            try XCTSkipIf(path.isEmpty, "Set WAYCAR_SCREENSHOT_DIR (make screenshots does this).")
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            return URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent(device, isDirectory: true)
        }
    }

    override func setUp() {
        continueAfterFailure = false
    }

    /// iPhone: the Agent list. iPad: the list beside the open Agent.
    @MainActor
    func testConsole() throws {
        let app = launch()
        if isPad { openCheckoutAgent(app) }
        try capture("console", settle: isPad ? 4 : 2)
    }

    /// The Agent's live terminal over its Toolbar; full width on iPad.
    @MainActor
    func testAgent() throws {
        let app = launch()
        openCheckoutAgent(app)
        if isPad { app.buttons["Hide Sidebar"].firstMatch.tap() }
        try capture("agent", settle: 4)
    }

    /// The New Agent sheet with the Studio Mac Host picked, Claude Code as its
    /// Agent and Chat Mode on. The sheet preselects the last-used Host, Agent
    /// and Chat Mode from the simulator's own defaults (`RecentSelectionsStore`),
    /// so argument-domain overrides pin them for this capture: no Host, the
    /// claude kind, not the shell, Chat Mode on. Picking the Host fills the
    /// Workspace and detects Agents, which shows the Chat Mode toggle.
    @MainActor
    func testNewAgent() throws {
        let app = launch(pinning: [
            "-recent-agent-host", "",
            "-recent-agent-kind", "claude",
            "-recent-agent-selection-shell", "NO",
            "-recent-agent-chat-mode", "YES",
        ])
        bottomBarButton("New Agent", in: app).tap()
        XCTAssertTrue(app.navigationBars["New Agent"].waitForExistence(timeout: 30))
        // The menu Picker's row reads "Host, Select a Host". A bare "Host"
        // label is the Console bar's Host filter behind the sheet.
        let hostPicker = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Host, ")).firstMatch
        XCTAssertTrue(hostPicker.waitForExistence(timeout: 30), "The Host picker never appeared.")
        hostPicker.tap()
        let studioMac = app.buttons["Studio Mac"].firstMatch
        XCTAssertTrue(studioMac.waitForExistence(timeout: 30), "The Host menu never opened.")
        studioMac.tap()
        let chatMode = app.switches["Chat Mode"].firstMatch
        XCTAssertTrue(
            chatMode.waitForExistence(timeout: 30),
            "Agent detection never offered a Chat Mode Agent.")
        XCTAssertEqual(chatMode.value as? String, "1", "Chat Mode was not pinned on.")
        try capture("new-agent")
    }

    @MainActor
    func testHosts() throws {
        let app = launch()
        bottomBarButton("Hosts", in: app).tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 30))
        try capture("hosts")
    }

    @MainActor
    func testSettings() throws {
        let app = launch()
        bottomBarButton("Settings", in: app).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 30))
        try capture("settings")
    }

    /// Both fake Codex accounts and their independent allowances survive
    /// expanding the Console row and opening All details.
    @MainActor
    func testAIUsage() throws {
        let app = launch()
        let row = app.buttons["AI Usage"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        assertCodexAccountUsage(in: app)
        try capture("ai-usage-accounts")
        let details = app.buttons["All details"].firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 30))
        details.tap()
        XCTAssertTrue(app.navigationBars["AI Usage"].waitForExistence(timeout: 30))
        assertCodexAccountUsage(in: app)
        try capture("ai-usage")
    }

    /// The Console filtered by the Closed chip: only Closed Sessions.
    @MainActor
    func testClosedSessions() throws {
        let app = launch()
        app.buttons["Closed"].firstMatch.tap()
        let closedCard = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "Refactor auth")).firstMatch
        XCTAssertTrue(closedCard.waitForExistence(timeout: 30))
        try capture("closed")
    }

    /// A Chat Mode Agent's chat: the turns, an inline image, and the open
    /// turn's permission prompt with Allow, Cancel and Show Terminal. Full
    /// width on iPad, like the terminal shot.
    @MainActor
    func testChatMode() throws {
        // `--demo-chat-mode` opens straight into the Chat Mode Agent.
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--demo-screenshots", "--demo-chat-mode"]
        app.launch()
        let lastMessage = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "full suite on the iPad")).firstMatch
        XCTAssertTrue(lastMessage.waitForExistence(timeout: 60), "The demo chat never appeared.")
        // Allow enables once the prompt's screen read lands.
        let allow = app.buttons["Allow"].firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 30), "The permission prompt never appeared.")
        let answerable = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: allow)
        wait(for: [answerable], timeout: 30)
        if isPad {
            let hide = app.buttons["Hide Sidebar"].firstMatch
            if hide.waitForExistence(timeout: 5) { hide.tap() }
        }
        try capture("chat", settle: 5)
    }

    /// Dictate to Agent listening on the Checkout Agent: the red waveform
    /// above the Toolbar and its stop button.
    @MainActor
    func testDictation() throws {
        // `--demo-dictation` opens the Checkout Agent and starts listening to
        // the demo's scripted voice.
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--demo-screenshots", "--demo-dictation"]
        app.launch()
        let listening = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Listening")).firstMatch
        XCTAssertTrue(listening.waitForExistence(timeout: 60), "Dictate to Agent never started listening.")
        // Long enough for the waveform to fill the listening card: 4 s on the
        // iPhone, and past the waveform's 160 samples (9.6 s) on the iPad's
        // wider landscape card.
        try capture("dictation", settle: isPad ? 14 : 4)
    }

    @MainActor
    private func assertCodexAccountUsage(in app: XCUIApplication) {
        let allowances = [
            (account: "Personal", window: "Session", value: "71%"),
            (account: "Personal", window: "Weekly", value: "43%"),
            (account: "Work", window: "Session", value: "94%"),
            (account: "Work", window: "Weekly", value: "66%"),
        ]
        for allowance in allowances {
            let gauge = app.descendants(matching: .any).matching(NSPredicate(
                format: "label BEGINSWITH %@",
                "Codex \(allowance.account) \(allowance.window),")).firstMatch
            if !gauge.exists { _ = gauge.waitForExistence(timeout: 3) }
            // The full sheet virtualizes sections and the iPhone may need
            // to scroll to the second account. Do not make larger screens
            // scroll past labels that are already visible.
            for _ in 0..<4 {
                if gauge.exists && gauge.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(
                gauge.waitForExistence(timeout: 30),
                "\(allowance.account)'s \(allowance.window) allowance is missing.")
            XCTAssertEqual(
                gauge.value as? String, allowance.value,
                "\(allowance.account)'s \(allowance.window) shows another account's usage.")
        }
    }

    @MainActor
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// The Checkout Agent card's headline. Card fields are separate elements,
    /// so this matches the Agent's name, not a combined row label.
    @MainActor
    private func checkoutRow(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["Checkout"].firstMatch
    }

    /// The Console's bottom bar precedes the iPad empty detail's buttons of
    /// the same name in the element tree, so the first match is the bar's.
    /// The demo fixture always has Hosts, so the bar is on screen; with none
    /// it is hidden and "Settings" would match the setup steps' gear instead.
    @MainActor
    private func bottomBarButton(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons[label].firstMatch
    }

    /// `pinning` adds `-key value` pairs, which UserDefaults reads from its
    /// argument domain ahead of anything the simulator persisted.
    @MainActor
    private func launch(pinning defaults: [String] = []) -> XCUIApplication {
        // Portrait iPad keeps the Agent list closed; landscape rests the
        // Agent beside the open list, the layout the app is designed around.
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--demo-screenshots"] + defaults
        app.launch()
        XCTAssertTrue(
            checkoutRow(app).waitForExistence(timeout: 60),
            "Demo fixture Agents never appeared.")
        return app
    }

    @MainActor
    private func openCheckoutAgent(_ app: XCUIApplication) {
        checkoutRow(app).tap()
        XCTAssertTrue(app.buttons["Message Agent"].firstMatch.waitForExistence(timeout: 30))
    }

    @MainActor
    private func capture(_ name: String, settle: UInt32 = 2) throws {
        // Sheet presentation, terminal rendering, and badge animation settle.
        sleep(settle)
        let directory = try outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(upright(XCUIScreen.main.screenshot().image).pngData())
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// A landscape screenshot's pixels stay in the panel's native portrait
    /// orientation, with the rotation carried only as `UIImage` metadata that
    /// `pngRepresentation` drops. Redrawing bakes the rotation into pixels.
    private func upright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(at: .zero)
        }
    }
}
