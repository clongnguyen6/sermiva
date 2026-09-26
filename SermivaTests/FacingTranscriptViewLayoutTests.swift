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
/// subview's own `frame.minY` - confirmed by direct measurement to equal
/// the real safe area plus the banner height in the correct case - is what
/// this test reads instead.
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

    /// A real, short (20 pt) banner above `FacingTranscriptView` already
    /// puts this view's own top edge (the pinned iPhone 17's real portrait
    /// safe area, 62 pt, plus the 20 pt banner = 82 pt) past the 62 pt
    /// desired position (`max(54, 62)`) - the correct call site must add
    /// ZERO further padding, landing the top pane's own `ScrollView` at
    /// 82 pt. The old, mutated formula (`max(54, safe.top)`, ignorant of
    /// where the banner actually put this view) adds 62 pt regardless,
    /// landing it at 144 pt instead - a 62 pt, unmistakable difference this
    /// test is sized to catch under that exact mutation.
    func test_topPaneLandsDirectlyBelowARealBannerNotDoubleInset() throws {
        let bannerHeight: CGFloat = 20
        let (window, controller) = try host(Harness(bannerHeight: bannerHeight))
        defer { unhost(controller) }

        let realSafeTop = window.safeAreaInsets.top
        try XCTSkipIf(realSafeTop <= 0, "this run reports no real top safe area to distinguish correct from double-inset behaviour against - expected on the pinned iPhone 17 Simulator in portrait (AGENTS.md's UDID)")

        // `FacingTranscriptView` renders exactly two `ScrollView`s (the top
        // and bottom reading panes, in that source order) as the only real
        // `UIView` subviews of the hosted content - see this file's own
        // top-level doc comment for why only ScrollViews materialize this
        // way. The FIRST is the top (rotated) pane, whose own `frame.minY`
        // directly reflects the real, currently-applied top inset.
        let topPane = try XCTUnwrap(controller.view.subviews.first, "FacingTranscriptView must render its top pane's ScrollView as a real subview once hosted and laid out")

        let expectedMinY = realSafeTop + bannerHeight
        XCTAssertEqual(topPane.frame.minY, expectedMinY, accuracy: 2, "the top pane must land directly below the real banner (\(bannerHeight) pt) plus the real safe area (\(realSafeTop) pt) it already sits below, with no further padding")
    }
}
