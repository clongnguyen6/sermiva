import SwiftUI
import UIKit
import XCTest
@testable import Sermiva

/// Regression proof for the CALL SITE inside `FacingTranscriptView.body`,
/// not just the pure `topInset(...)` helper (`FacingTranscriptViewTests`).
/// Replacing the production line `Self.topInset(desiredTopY:...,
/// wrapperGlobalMinY:...)` with the old, double-inseting `max(54, safe.top)`
/// leaves every test in `FacingTranscriptViewTests` green, since none of
/// them exercise the view itself. This test hosts the real
/// `FacingTranscriptView` in this test target's own real app process -
/// `SermivaTests` launches Sermiva itself as its `TEST_HOST` (AGENTS.md), so
/// `UIApplication.shared`'s key window is the real app window with the real
/// device's own safe area, exactly as in production - with a plain view
/// standing in for a banner above it the same way `ConversationView`'s own
/// `VStack` places one, and reads back where the top reading pane actually
/// renders from the real, laid-out UIKit view hierarchy. No XCUITest, no
/// real Soniox session, no product-code test hook -
/// `FacingTranscriptView.swift` is untouched by this file.
///
/// `FacingTranscriptView`'s own accessibility identifiers (`facingTopWrapper`
/// etc.), which XCUITest reads through testmanagerd, do not materialize when
/// queried directly through `UIAccessibilityContainer`'s
/// `accessibilityElementCount()`/`accessibilityElement(at:)` in this
/// in-process, no-VoiceOver-client context (confirmed empirically - it
/// stays 0 throughout the real, correctly-laid-out tree below). SwiftUI
/// renders everything in `FacingTranscriptView` except its two `ScrollView`s
/// on shared Core Animation layers inside one `_UIHostingView`, not as
/// separate `UIView`s - only a `ScrollView` needs a real `UIScrollView` for
/// gesture handling, so it alone becomes an inspectable subview. That
/// subview's own `frame.minY` is what this test reads instead - see the
/// test's own doc comment for how the expected value is computed without
/// assuming a particular Simulator orientation.
final class FacingTranscriptViewLayoutTests: XCTestCase {
    private struct Harness: View {
        let bannerHeight: CGFloat

        var body: some View {
            VStack(spacing: 0) {
                Color.red.frame(height: bannerHeight)
                FacingTranscriptView(
                    displaySegments: [],
                    meLanguage: "vi",
                    targetLanguage: "en",
                    isDemo: false,
                    swapped: .constant(false),
                    micDockText: "Mic tắt",
                    micDotColor: .gray,
                    micIconName: "mic.slash",
                    primaryLabel: "Bắt đầu",
                    primaryDisabled: false,
                    primaryIsOk: false,
                    isConnecting: false,
                    onPrimary: {},
                    onExit: {}
                )
            }
        }
    }

    /// Hosts `view` as a real, laid-out subview of the app's own real key
    /// window. `root.view.addSubview(...)` is explicitly unsupported when
    /// `root` is itself a hosting controller (SwiftUI logs a warning and
    /// the nested view never lays out correctly) - this app is
    /// SwiftUI-lifecycle, so `root` always is one. Adding directly to the
    /// window, as a sibling of `root.view` in their common superview, is
    /// what SwiftUI itself recommends instead. Full `UIViewController`
    /// containment (`addChild`/`didMove`) is not used - SwiftUI's own root
    /// hosting controller manages its child relationship privately and
    /// asserts on an external `addChild` call - and is not needed anyway:
    /// only real layout is being measured, which does not depend on VC
    /// containment.
    private func host<V: View>(_ view: V) throws -> (window: UIWindow, controller: UIHostingController<V>) {
        let window = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.windows.first(where: \.isKeyWindow) }
                .first,
            "SermivaTests launches Sermiva itself as its TEST_HOST - the real app's key window must exist"
        )
        let controller = UIHostingController(rootView: view)
        controller.view.frame = window.bounds
        controller.view.backgroundColor = .clear
        window.addSubview(controller.view)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return (window, controller)
    }

    private func unhost(_ controller: UIHostingController<some View>) {
        controller.view.removeFromSuperview()
    }

    /// Must never skip: an `XCTSkipIf` gated on the Simulator's current
    /// orientation (e.g. "only meaningful in portrait, where the real safe
    /// area is nonzero") let a Simulator left in landscape by an earlier
    /// run turn a genuinely broken call site into a green skip instead of a
    /// failure - review round 8 reproduced exactly that. The expected
    /// position is instead computed from the same two real, measured
    /// values `topInset(...)` itself takes - the real safe area
    /// (`window.safeAreaInsets.top`) and where the banner actually put this
    /// view (`realSafeTop + bannerHeight`, since the harness `VStack`
    /// places the banner right at the real safe-area boundary) - so it is
    /// correct, and distinct from the mutated formula's result, in
    /// whatever orientation the Simulator happens to be in:
    /// `max(desiredTopY, wrapperMinY)`, where `desiredTopY = max(54,
    /// realSafeTop)`. A 20 pt banner keeps the two formulas' results at
    /// least 20 pt apart even in landscape (where the real top inset is 0,
    /// so a banner shorter than HANDOFF's 54 pt floor still leaves a real,
    /// nonzero gap the correct formula closes and the mutated one does
    /// not) - see docs/display-style-picker.md's measured real-inset table
    /// for why portrait (62 pt) and landscape (0 pt) are the only two
    /// cases that matter here.
    func test_topPaneLandsDirectlyBelowARealBannerNotDoubleInset() throws {
        let bannerHeight: CGFloat = 20
        let (window, controller) = try host(Harness(bannerHeight: bannerHeight))
        defer { unhost(controller) }

        let realSafeTop = window.safeAreaInsets.top
        let desiredTopY = max(54, realSafeTop)
        let wrapperMinY = realSafeTop + bannerHeight
        let expectedMinY = max(desiredTopY, wrapperMinY)

        // `FacingTranscriptView` renders exactly two `ScrollView`s (the top
        // and bottom reading panes, in that source order) as the only real
        // `UIView` subviews of the hosted content - see this file's own
        // top-level doc comment for why only ScrollViews materialize this
        // way. The FIRST is the top (rotated) pane, whose own `frame.minY`
        // directly reflects the real, currently-applied top inset.
        let topPane = try XCTUnwrap(controller.view.subviews.first, "FacingTranscriptView must render its top pane's ScrollView as a real subview once hosted and laid out")

        XCTAssertEqual(topPane.frame.minY, expectedMinY, accuracy: 2, "the top pane must land at max(max(54, real top inset), real top inset + banner height) = \(expectedMinY) - never further padding stacked on top of where the banner already put it")
    }
}
