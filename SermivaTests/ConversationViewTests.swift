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
        XCTAssertEqual(ConversationView<DemoSessionController>.micDotColor(for: .neutral), Tokens.text3)
        XCTAssertEqual(ConversationView<DemoSessionController>.micDotColor(for: .warn), Tokens.warn)
        XCTAssertEqual(ConversationView<DemoSessionController>.micDotColor(for: .live), Tokens.live)
    }

    // MARK: - Live reopen finding 5 (owner-decided): every diarized speaker
    // beyond A/B is a real, distinct person and must show its own label -
    // AGENTS.md forbids merging different real speakers under "Chưa xác
    // định" just because there are more than two.

    func test_speakerLabelTextForEveryLetterBeyondAB() {
        XCTAssertEqual(SpeakerLabel.text(for: "A"), "Người nói A")
        XCTAssertEqual(SpeakerLabel.text(for: "B"), "Người nói B")
        XCTAssertEqual(SpeakerLabel.text(for: "C"), "Người nói C", "a third real speaker must get its own label, not be merged into 'unidentified'")
        XCTAssertEqual(SpeakerLabel.text(for: "D"), "Người nói D")
    }

    func test_speakerLabelTextForNoSpeakerStaysUnidentified() {
        XCTAssertEqual(SpeakerLabel.text(for: nil), "Chưa xác định", "only a segment with no speaker at all may show this - never a real speaker beyond B")
    }

    func test_speakerLabelColorRoleUsesTheExistingText2ColourForCAndBeyondNoNewColour() {
        XCTAssertEqual(SpeakerLabel.colorRole(for: "A"), .speakerA)
        XCTAssertEqual(SpeakerLabel.colorRole(for: "B"), .speakerB)
        XCTAssertEqual(SpeakerLabel.colorRole(for: "C"), .other, "owner-decided: C onward use the existing text2 colour, not a new one")
        XCTAssertEqual(SpeakerLabel.colorRole(for: nil), .unidentified, "'Chưa xác định' keeps its own distinct role, not the same one as a real speaker C")
    }
}
