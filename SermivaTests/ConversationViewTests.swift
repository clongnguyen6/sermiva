import SwiftUI
import XCTest
@testable import Sermiva

/// `ConversationView.micDotColor(for:)` is the one place that turns the
/// controller's `MicDotColorRole` into an actual `Color`. Demo never
/// computes `.live` (see `SessionStateMachineTests`), but nothing enforced
/// that `.live` itself renders as the "listening" red rather than some other
/// role's color - this covers that mapping directly.
final class ConversationViewTests: XCTestCase {
    func test_micDotColorMapsEachRoleToItsOwnToken() {
        XCTAssertEqual(ConversationView.micDotColor(for: .neutral), Tokens.text3)
        XCTAssertEqual(ConversationView.micDotColor(for: .warn), Tokens.warn)
        XCTAssertEqual(ConversationView.micDotColor(for: .live), Tokens.live)
    }
}
