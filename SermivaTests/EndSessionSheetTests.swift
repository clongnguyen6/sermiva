import XCTest
@testable import Sermiva

/// Project owner's rule: an approved string that asserts the mic is
/// active/opening/about to turn off must drop that clause in demo, or be
/// replaced by an existing true state - never get new copy. `endBody`'s
/// "Mic se tat" clause is the one case this outcome resolves that way; the
/// full approved sentence stays for a real (non-demo) session.
final class EndSessionSheetTests: XCTestCase {
    func test_demoBodyDropsTheMicClauseLiveBodyKeepsIt() {
        XCTAssertEqual(
            EndSessionSheet.bodyText(isDemo: true),
            "Bản ghi vẫn xem lại được cho đến khi bạn bắt đầu phiên mới."
        )
        XCTAssertEqual(
            EndSessionSheet.bodyText(isDemo: false),
            "Mic sẽ tắt. Bản ghi vẫn xem lại được cho đến khi bạn bắt đầu phiên mới."
        )
    }
}
