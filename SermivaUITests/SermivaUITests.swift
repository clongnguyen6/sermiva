import XCTest

/// One smoke test on the real app, no hooks or shortcuts in product code:
/// open the app, enter demo, reach the listening state, see the first
/// fixture segment's real content appear, then see playback keep advancing
/// into the second segment's real translated content. Proves the app
/// launches on a Simulator and the demo path works end to end. Does not
/// prove translation content beyond the second segment, display styles
/// other than "Phu de", scroll/layout details, or anything needing Soniox -
/// see AGENTS.md's Verify section for what "runs" covers here.
final class SermivaUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_demoReachesListeningAndShowsFirstSegment() throws {
        let app = XCUIApplication()
        app.launch()

        let demoButton = app.buttons["demoButton"]
        XCTAssertTrue(demoButton.waitForExistence(timeout: 10), "Setup must show the demo entry button")
        demoButton.tap()

        let startButton = app.buttons["primaryButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 10), "Conversation must show the primary dock button")
        startButton.tap()

        // Confirm the UI actually reflects listening, not just that a tap
        // happened - the real section-5 signals the design already
        // defines: the connection line, the mic dock (always "Mic tat" in
        // demo, per the project owner's decision), and the primary button
        // flipping to "Tam dung".
        XCTAssertTrue(app.staticTexts["Phiên mô phỏng"].waitForExistence(timeout: 10), "the connection status line must say Phien mo phong once listening")
        XCTAssertTrue(app.staticTexts["Mic tắt"].waitForExistence(timeout: 10), "the mic dock must say Mic tat in demo, at every session state")
        XCTAssertEqual(startButton.label, "Tạm dừng", "the primary button must reflect the listening state, not still say Bat dau or wrongly say Tiep tuc")

        // Demo never reaches Apple Translation (`translationConfiguration`
        // is always nil there), so the "translation unavailable" banner -
        // reachable only from a live session's own availability check -
        // must never show here.
        XCTAssertFalse(app.staticTexts["Lời của Bạn sẽ không được dịch sang tiếng Anh trên máy này."].exists, "demo must never show the live-only translation-unavailable banner")

        let currentSegment = app.otherElements["currentSegment"]
        XCTAssertTrue(currentSegment.waitForExistence(timeout: 10), "the first fixture segment must appear once listening starts")

        // "Cho toi mot ca phe" is the common prefix of every partial and the
        // final for cafe_vi_en's first segment. Deliberately not scoped to
        // currentSegment: the fixture keeps advancing on its own real-time
        // schedule regardless of how long this test's own waits take, so by
        // the time this check runs under a loaded host, segment 1 may
        // already have scrolled from "current" into history. Either
        // location is real fixture content reaching the screen, which is
        // what this assertion is proving - a longer timeout scoped to
        // currentSegment only would make that race worse, not better.
        let firstSegmentText = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", "Cho tôi một cà phê"))
            .firstMatch
        XCTAssertTrue(firstSegmentText.waitForExistence(timeout: 15), "the first fixture event's real content must reach the screen, not just an empty container")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "demo-listening"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Confirm playback keeps advancing past the first segment, not just
        // that it started - segment 2's real target text landing is real
        // fixture content reaching the screen, not a static first frame.
        let laterSegmentText = app.staticTexts["Bạn có muốn ăn thêm gì không?"]
        XCTAssertTrue(laterSegmentText.waitForExistence(timeout: 20), "the demo must keep playing past the first segment")

        let laterAttachment = XCTAttachment(screenshot: app.screenshot())
        laterAttachment.name = "demo-multiple-segments"
        laterAttachment.lifetime = .keepAlways
        add(laterAttachment)
    }
}
