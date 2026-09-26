import Foundation

/// HANDOFF.md section 3's five display styles, restricted to the two this
/// outcome implements - Bong bóng, Sân khấu, Kịch bản do not exist yet.
/// `DisplayStylePickerSheet` reads `allCases` directly, so the sheet's own
/// 2-card list stays in lockstep with this enum without a second list to
/// keep in sync - see docs/display-style-picker.md for why the sheet is
/// temporarily 2 cards instead of the design's 5.
enum DisplayStyle: CaseIterable {
    case captions
    case facing

    /// `t.views[k]`, verbatim from the approved prototype
    /// (`design/claude-handoff/Sermiva.dc.html`).
    var label: String {
        switch self {
        case .captions: return "Phụ đề"
        case .facing: return "Đối diện"
        }
    }

    /// `t.viewDesc[k]`, verbatim from the approved prototype.
    var cardDescription: String {
        switch self {
        case .captions: return "Câu mới nhất nổi bật"
        case .facing: return "Sân khấu 2 vùng, một vùng xoay 180°"
        }
    }
}
