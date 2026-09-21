import SwiftUI

/// HANDOFF.md section 5: ending a session always goes through this
/// confirmation sheet. Copy taken verbatim from the approved prototype.
struct EndSessionSheet: View {
    let segmentCount: Int
    let elapsed: TimeInterval
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Kết thúc phiên?")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Tokens.text)

            Text("Mic sẽ tắt. Bản ghi vẫn xem lại được cho đến khi bạn bắt đầu phiên mới.")
                .font(.system(size: 15))
                .foregroundStyle(Tokens.text2)

            Text("\(segmentCount) đoạn · \(Self.formatElapsed(elapsed))")
                .font(.system(size: 13))
                .foregroundStyle(Tokens.text3)

            Button(action: onConfirm) {
                Text("Kết thúc phiên")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .background(Tokens.danger)
            .foregroundStyle(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            Button(action: onCancel) {
                Text("Hủy")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .background(Tokens.surface2)
            .foregroundStyle(Tokens.text)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .padding(20)
        .presentationDetents([.medium])
    }

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
