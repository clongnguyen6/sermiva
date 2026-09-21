import XCTest

/// One smoke test on the real app, no hooks or shortcuts in product code:
/// open the app, enter demo, reach the listening state, see the first
/// fixture segment appear. Proves the app launches on a Simulator and the
/// demo path works end to end. Does not prove translation content, display
/// styles other than "Phu de", scroll/layout details, or anything needing
/// Soniox - see AGENTS.md's Verify section for what "runs" covers here.
final class SermivaUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_demoReachesListeningAndShowsFirstSegment() throws {
        let app = XCUIApplication()
        app.launch()

        let demoButton = app.buttons["demoButton"]
        XCTAssertTrue(demoButton.waitForExistence(timeout: 5), "Setup must show the demo entry button")
        demoButton.tap()

        let startButton = app.buttons["primaryButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 5), "Conversation must show the primary dock button")
        startButton.tap()

        let currentSegment = app.otherElements["currentSegment"]
        XCTAssertTrue(currentSegment.waitForExistence(timeout: 5), "the first fixture segment must appear once listening starts")
    }
}
