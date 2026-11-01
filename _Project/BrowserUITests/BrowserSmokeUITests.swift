import XCTest

/// Fast smoke tests that check the app launches and responds to the Siri Remote.
final class BrowserSmokeUITests: XCTestCase {
    private let timeout: TimeInterval = 15

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Launches the app. The arguments override NSUserDefaults so each test starts from a known state.
    private func launchApp(showUsageGuide: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-DontShowHintsOnLaunch", showUsageGuide ? "NO" : "YES"]
        app.launch()
        return app
    }

    func testAppLaunchesToForeground() {
        let app = launchApp(showUsageGuide: false)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: timeout))
    }

    func testUsageGuideShownOnLaunch() {
        let app = launchApp(showUsageGuide: true)
        XCTAssertTrue(app.alerts["Usage Guide"].waitForExistence(timeout: timeout))
    }

    func testPlayPauseOpensAndClosesQuickMenu() {
        let app = launchApp(showUsageGuide: false)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: timeout))

        let remote = XCUIRemote.shared
        remote.press(.playPause)

        let quickMenu = app.alerts["Quick Menu"]
        XCTAssertTrue(quickMenu.waitForExistence(timeout: timeout))
        XCTAssertTrue(quickMenu.buttons["Input URL or Search with Google"].exists)

        remote.press(.menu)
        let dismissed = NSPredicate(format: "exists == false")
        expectation(for: dismissed, evaluatedWith: quickMenu)
        waitForExpectations(timeout: timeout)
    }
}
