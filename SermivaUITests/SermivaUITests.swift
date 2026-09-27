import XCTest
import UIKit

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

    /// HANDOFF.md section 3's "Đối diện" style, entered through the dock's
    /// "Hiển thị" sheet: the top region renders rotated 180°, and ✕ returns
    /// to Phụ đề without touching the running session (criterion 1). Pauses
    /// the demo first - real fixture content reaching the screen, then
    /// frozen in place - so the rotation check below reads a fixed segment
    /// rather than racing the demo's own advancing playback.
    func test_facingEntersRotatedAndExitReturnsToCaptionsWithSessionIntact() throws {
        let app = XCUIApplication()
        app.launch()

        app.buttons["demoButton"].tap()
        let startButton = app.buttons["primaryButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 10))
        startButton.tap()

        // Segment 2 (lang "en") is the fixture's first segment already in
        // the "target" reader's own language - its source text is real
        // content available the instant it arrives, unlike a translation,
        // which can still be pending. Waiting for it (not just segment 1)
        // is what makes the geometry check below meaningful: the rotated
        // top pane's big line is guaranteed non-empty real text, not an
        // empty container that would trivially "pass".
        let segment2Text = app.staticTexts["Would you like anything to eat?"]
        XCTAssertTrue(segment2Text.waitForExistence(timeout: 15), "the second fixture segment's own source text must reach the screen before pausing")

        startButton.tap()
        XCTAssertEqual(startButton.label, "Tiếp tục", "pausing must actually reach the paused state before Facing freezes it")

        app.buttons["displayStyleButton"].tap()
        let facingCard = app.buttons["displayStyleCard_facing"]
        XCTAssertTrue(facingCard.waitForExistence(timeout: 5), "the style sheet must offer Đối diện")
        facingCard.tap()

        // Default (not swapped): the top pane reads "target" (English) -
        // the segment above is already in English, so its own source text
        // is what the top pane's big line shows, unrotated content proven
        // by the same string reaching the screen again under a new
        // identifier.
        let topBig = app.staticTexts["facingTopBig"]
        XCTAssertTrue(topBig.waitForExistence(timeout: 5), "the top pane must show the latest segment's text")
        XCTAssertEqual(topBig.label, "Would you like anything to eat?")

        let topLabel = app.descendants(matching: .any)["facingTopReaderLabel"]
        XCTAssertTrue(topLabel.waitForExistence(timeout: 5))

        // The one real, view-level proof of a 180° rotation available to
        // XCUITest: in source order the reader-label row sits ABOVE the big
        // text, so on an unrotated pane its frame's minY is smaller. Once
        // the whole pane is rotated 180°, that same row renders BELOW the
        // big text instead - minY becomes the LARGER one. No product-code
        // hook, no accessibility shortcut - just the real on-screen layout
        // XCUITest already reports for both elements.
        XCTAssertGreaterThan(topLabel.frame.minY, topBig.frame.minY, "the top pane's reader label must render BELOW its own big text once rotated 180° - if this fails, the top pane is not actually rotated")

        app.buttons["facingExitButton"].tap()

        // Back in Phụ đề: the same paused session, not reset - the primary
        // button must still say Tiếp tục (still paused), and the same real
        // fixture content from before entering Facing must still be there.
        XCTAssertTrue(app.staticTexts["Would you like anything to eat?"].waitForExistence(timeout: 5), "exiting Facing must not lose the transcript")
        XCTAssertEqual(startButton.label, "Tiếp tục", "exiting Facing must not change the session's own paused state")
        XCTAssertTrue(app.otherElements["currentSegment"].waitForExistence(timeout: 5), "Phụ đề's own current-segment card must be back")
    }

    /// HANDOFF.md section 3's landscape insets (`22` pt bottom, vs `34` pt
    /// portrait - the top stays `54` pt either way) and its "dải giữa không
    /// bị đè" (the middle strip must never be overlapped), proven
    /// numerically rather than visually: `facingTopWrapper`/
    /// `facingBottomWrapper` are `FacingPane`'s own `ScrollView` - the exact
    /// region a long sentence scrolls within - so their measured edges are
    /// the real padding boundary, not an approximation. `XCUIDevice`'s own
    /// screenshot API renders landscape content incorrectly in this
    /// environment (see docs/display-style-picker.md); this test's
    /// assertions come from `XCUIElement.frame`, which - confirmed against
    /// `xcrun simctl io screenshot`'s real framebuffer capture - reports
    /// landscape geometry correctly regardless.
    /// Measured once via a direct UIKit read of the key window's own
    /// `safeAreaInsets` on the pinned iPhone 17 Simulator (see AGENTS.md for
    /// the UDID) - not asserted from theory. Landscape reports the Dynamic
    /// Island's clearance SYMMETRICALLY on both the leading and trailing
    /// edge (Apple's own convention for Island devices, regardless of which
    /// physical side the island actually sits on), which is why
    /// `landscapeLeft` and `landscapeRight` need only one constant each.
    /// HANDOFF.md gives no leading/trailing number at all, so - per the
    /// owner's ruling in docs/display-style-picker.md - this real value is
    /// what "no content lies outside the safe area" is measured against.
    private static let landscapeRealSafeArea = (top: CGFloat(0), bottom: CGFloat(20), leadingOrTrailing: CGFloat(62))

    /// HANDOFF.md section 3's landscape insets (top stays `54` pt, same as
    /// portrait; bottom is `22` pt, not portrait's `34`) and its "dải giữa
    /// không bị đè" (the middle strip must never be overlapped) - proven
    /// numerically rather than visually, since `app.screenshot()` renders
    /// landscape content incorrectly in this environment (see
    /// docs/display-style-picker.md; `xcrun simctl io screenshot` and
    /// `XCUIElement.frame`, used here, both report it correctly). Per the
    /// owner's ruling, an edge's real inset can only ever WIDEN the applied
    /// clearance past HANDOFF's own number, never narrow it - so top/bottom
    /// are asserted as a floor, and leading/trailing (where HANDOFF has no
    /// floor at all) as an exact real-inset containment check covering both
    /// panes' content and every middle-strip control.
    /// Review round 3, finding 5: checks BOTH rotation directions - the
    /// Island's landscape clearance reports identically on either physical
    /// side (see `landscapeRealSafeArea`'s own doc), but that symmetry is
    /// exactly the kind of claim a test must confirm empirically rather than
    /// assume, so `landscapeLeft` and `landscapeRight` are both driven
    /// through the same real device here rather than only one of them.
    func test_facingLandscapeRegionsRespectInsetsWithNoOverlap() throws {
        // Device orientation is Simulator-global, not per-test-run state -
        // a previous test (in this file or another) rotating and not
        // reaching its own `defer` (e.g. `continueAfterFailure = false`
        // aborting mid-assertion) can leave the Simulator rotated before
        // this test's own `app.launch()` below. Starting from a known
        // portrait orientation here, before anything else, is what makes
        // this test's own two rotations below deterministic regardless of
        // what ran before it.
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        app.buttons["demoButton"].tap()
        let startButton = app.buttons["primaryButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 10))
        startButton.tap()
        XCTAssertTrue(app.staticTexts["Would you like anything to eat?"].waitForExistence(timeout: 15))
        startButton.tap()
        app.buttons["displayStyleButton"].tap()
        app.buttons["displayStyleCard_facing"].tap()
        XCTAssertTrue(app.staticTexts["facingTopBig"].waitForExistence(timeout: 5))

        defer { XCUIDevice.shared.orientation = .portrait }

        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            assertFacingLandscapeInsets(app: app, orientation: orientation)
        }
    }

    private func assertFacingLandscapeInsets(app: XCUIApplication, orientation: UIDeviceOrientation, line: UInt = #line) {
        let topWrapper = app.scrollViews["facingTopWrapper"]
        XCTAssertTrue(topWrapper.waitForExistence(timeout: 5), "[\(orientation)] the top pane must still exist once rotated to landscape", line: line)
        let strip = app.otherElements["facingMiddleStrip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5), "[\(orientation)] the middle strip must still exist once rotated to landscape", line: line)
        let bottomWrapper = app.scrollViews["facingBottomWrapper"]
        XCTAssertTrue(bottomWrapper.waitForExistence(timeout: 5), "[\(orientation)] the bottom pane must still exist once rotated to landscape", line: line)

        let screen = app.windows.firstMatch.frame
        let top = topWrapper.frame
        let mid = strip.frame
        let bottom = bottomWrapper.frame

        // Top/bottom: HANDOFF's numbers are a floor, never a ceiling - the
        // real device inset (0 top / 20 bottom here) is smaller than
        // HANDOFF's own 54/22 on this device, so the applied clearance must
        // still be at least HANDOFF's own number.
        XCTAssertGreaterThanOrEqual(top.minY - screen.minY, 54 - 0.5, "[\(orientation)] the top pane must never start less than HANDOFF's own 54 pt below the true top edge", line: line)
        XCTAssertGreaterThanOrEqual(screen.maxY - bottom.maxY, 22 - 0.5, "[\(orientation)] the bottom pane must never end less than HANDOFF's own 22 pt above the true bottom edge in landscape", line: line)

        // No overlap: each region's edge must exactly meet the next, never past it.
        XCTAssertEqual(top.maxY, mid.minY, accuracy: 1, "[\(orientation)] the top pane must not overlap the middle strip", line: line)
        XCTAssertEqual(mid.maxY, bottom.minY, accuracy: 1, "[\(orientation)] the middle strip must not overlap the bottom pane", line: line)

        // Leading/trailing: no HANDOFF floor exists, so every piece of
        // region content and every strip control must sit fully inside the
        // real safe area - never merely inside the full screen width, which
        // the Dynamic Island's landscape side clearance already extends
        // past. `facingTopWrapper`/`facingBottomWrapper` are not used for
        // this axis: measured directly, the non-rotated bottom wrapper's
        // own accessibility frame reports the outer, unpadded slot's full
        // width, not its actually-inset content - confirmed by checking its
        // own content elements below, which are not subject to that quirk.
        let safeMinX = screen.minX + Self.landscapeRealSafeArea.leadingOrTrailing
        let safeMaxX = screen.maxX - Self.landscapeRealSafeArea.leadingOrTrailing

        // Review round 3, finding 5: a missing element must fail the check,
        // not be silently skipped - `guard element.exists else { return }`
        // here previously let `facingSwapButton` being hidden from
        // accessibility pass this test vacuously.
        func assertInsideSafeArea(_ identifier: String, assertLine: UInt = #line) {
            let element = app.descendants(matching: .any)[identifier]
            XCTAssertTrue(element.exists, "[\(orientation)] \(identifier) must exist to be checked against the safe area", line: assertLine)
            let frame = element.frame
            XCTAssertGreaterThanOrEqual(frame.minX, safeMinX - 1, "[\(orientation)] \(identifier) must not start left of the real safe area", line: assertLine)
            XCTAssertLessThanOrEqual(frame.maxX, safeMaxX + 1, "[\(orientation)] \(identifier) must not end right of the real safe area", line: assertLine)
        }

        // `facingTopBig`/`facingBottomBig` are deliberately not checked
        // here: `FacingPaneContent.make` only ever gives ONE of the two
        // readers an immediate big line for a given segment - the other
        // needs its translation to land, which `cafe_vi_en`'s own real
        // pacing (a fixed 0.9 s between events, a 1.4 s translation delay)
        // means the NEXT event always preempts before that happens, for
        // every segment except the fixture's very last. Which reader is
        // still waiting keeps changing every 0.9 s, so asserting either
        // identifier here would be asserting fixture timing, not layout -
        // and both Big and Small share the exact same
        // `.padding(.horizontal, 22)` container as `ReaderLabel` (see
        // `FacingPane`), so `ReaderLabel` - which renders unconditionally,
        // with or without a segment - already proves the same horizontal
        // inset this axis exists to check.
        assertInsideSafeArea("facingTopReaderLabel")
        assertInsideSafeArea("facingBottomReaderLabel")
        assertInsideSafeArea("facingPrimaryButton")
        assertInsideSafeArea("facingSwapButton")
        assertInsideSafeArea("facingExitButton")
    }

    /// Review round 9: the strip's primary pill ("Tạm dừng"/"Phiên mới")
    /// wrapped its label onto two lines on the owner's real device, portrait,
    /// default text size. Two other checks were tried and rejected first: a
    /// hosted `UIHostingController` test (constructing `FacingTranscriptView`
    /// directly with the same inputs) measured a correct, unwrapped strip
    /// height even against the unfixed code, and `XCUIElement.frame` on
    /// `facingPrimaryButton` itself stayed the same ~44 pt height and a
    /// barely-different width whether wrapped or not - confirmed by pixel-
    /// measuring the real screenshot below: the wrap happens entirely inside
    /// the pill's own fixed-size box (`HStack.frame(minHeight: 44)` still
    /// satisfies its minimum with two compressed lines), so nothing in
    /// SwiftUI's own layout tree - hosted or real - grows to reflect it.
    /// The only thing that actually differs is the rendered pixels, so this
    /// reads them directly from a real screenshot: a single-line label
    /// leaves one continuous horizontal band of light (near-white) pixels
    /// across the label area; a wrapped label leaves two, split by a gap.
    func test_facingPrimaryButtonLabelDoesNotWrapWhileListening() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["demoButton"].tap()
        let startButton = app.buttons["primaryButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 10))
        startButton.tap()
        XCTAssertTrue(app.staticTexts["Phiên mô phỏng"].waitForExistence(timeout: 10))

        app.buttons["displayStyleButton"].tap()
        app.buttons["displayStyleCard_facing"].tap()
        assertFacingPrimaryButtonDoesNotWrap(app: app, expectedLabel: "Tạm dừng")
    }

    /// Same bug, the owner's other reported case: "Phiên mới" once the
    /// session has ended.
    func test_facingPrimaryButtonLabelDoesNotWrapAfterSessionEnded() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["demoButton"].tap()
        let startButton = app.buttons["primaryButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 10))
        startButton.tap()
        XCTAssertTrue(app.staticTexts["Phiên mô phỏng"].waitForExistence(timeout: 10))

        app.buttons["Kết thúc"].tap()
        let confirmButton = app.buttons["Kết thúc phiên"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5))
        confirmButton.tap()
        XCTAssertEqual(startButton.label, "Phiên mới", "ending the session must reach the Phiên mới state before Facing is entered")

        app.buttons["displayStyleButton"].tap()
        app.buttons["displayStyleCard_facing"].tap()
        assertFacingPrimaryButtonDoesNotWrap(app: app, expectedLabel: "Phiên mới")
    }

    private func assertFacingPrimaryButtonDoesNotWrap(app: XCUIApplication, expectedLabel: String, line: UInt = #line) {
        let primary = app.buttons["facingPrimaryButton"]
        XCTAssertTrue(primary.waitForExistence(timeout: 5), "the Facing strip's primary button must exist", line: line)
        XCTAssertEqual(primary.label, expectedLabel, "must be checking the reported state, not a different one", line: line)

        let screenshot = app.screenshot()
        let windowWidth = app.windows.firstMatch.frame.width
        let bands = Self.textLineBandCount(in: screenshot, buttonFrame: primary.frame, windowWidthPoints: windowWidth)
        XCTAssertEqual(bands, 1, "the primary pill's label (\"\(expectedLabel)\") must render on exactly one line - \(bands) separate horizontal bands of light pixels means it wrapped", line: line)
    }

    /// Counts distinct horizontal bands of light (near-white, the label's
    /// own text color against the pill's blue or the strip's white
    /// background) pixel rows within `buttonFrame`'s label area, read from a
    /// real screenshot. The button's own leading edge is skipped by
    /// `leftSkip` below - it holds the pause/play icon, itself a
    /// light-colored glyph that would otherwise be counted as its own band
    /// regardless of the label - and each row's threshold is high enough
    /// (`0.15`) to ignore the capsule's own rounded-corner background
    /// bleeding into the crop, confirmed empirically against a real
    /// "Phiên mới" screenshot.
    private static func textLineBandCount(in screenshot: XCUIScreenshot, buttonFrame: CGRect, windowWidthPoints: CGFloat) -> Int {
        guard let cgImage = screenshot.image.cgImage else { return -1 }
        let scale = CGFloat(cgImage.width) / windowWidthPoints
        // The icon (pause/play, 13 pt) plus its leading padding (14 pt) and
        // the 6 pt spacing before the label together span about 33 pt,
        // regardless of which label is showing - a fixed points skip (not a
        // fraction of the button's own width, which shrinks with a shorter
        // label) is what reliably clears it for every label.
        let leftSkip: CGFloat = 36
        let cropRect = CGRect(
            x: (buttonFrame.minX + leftSkip) * scale,
            y: (buttonFrame.minY + 4) * scale,
            width: (buttonFrame.width - leftSkip - 6) * scale,
            height: (buttonFrame.height - 8) * scale
        ).integral
        guard cropRect.width > 0, cropRect.height > 0, let cropped = cgImage.cropping(to: cropRect) else { return -1 }
        guard let data = cropped.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return -1 }
        let bytesPerRow = cropped.bytesPerRow
        let bytesPerPixel = cropped.bitsPerPixel / 8

        var bands = 0
        var inBand = false
        for y in 0..<cropped.height {
            var lightCount = 0
            for x in 0..<cropped.width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                if ptr[offset] > 200, ptr[offset + 1] > 200, ptr[offset + 2] > 200 {
                    lightCount += 1
                }
            }
            let isTextRow = Double(lightCount) / Double(cropped.width) > 0.15
            if isTextRow, !inBand {
                bands += 1
                inBand = true
            } else if !isTextRow {
                inBand = false
            }
        }
        return bands
    }
}
