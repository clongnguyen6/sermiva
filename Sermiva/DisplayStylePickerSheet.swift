import SwiftUI

/// HANDOFF.md section 3's style-picker sheet: "5 thẻ xem trước dạng lưới 2
/// cột, thẻ đang chọn viền `accent` + dấu ✓" - temporarily showing only the
/// two `DisplayStyle` cases this outcome implements, per
/// docs/display-style-picker.md. Settings (out of scope) opens this same
/// sheet in the approved design; here it only ever opens from the dock's
/// "Hiển thị" button.
struct DisplayStylePickerSheet: View {
    @Binding var selected: DisplayStyle
    let onClose: () -> Void

    @ScaledMetric(relativeTo: .body) private var titleSize: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Kiểu hiển thị")
                    .font(.system(size: titleSize, weight: .bold))
                    .foregroundStyle(Tokens.text)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .foregroundStyle(Tokens.text2)
                        .frame(width: 44, height: 44)
                        .background(Tokens.surface)
                        .clipShape(Circle())
                }
                .accessibilityLabel("Hủy")
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                ForEach(DisplayStyle.allCases, id: \.self) { style in
                    DisplayStyleCard(style: style, isSelected: selected == style) {
                        selected = style
                        onClose()
                    }
                    .accessibilityIdentifier("displayStyleCard_\(style)")
                }
            }
        }
        .padding(20)
        .presentationDetents([.medium])
    }
}

extension DisplayStyle: Hashable {}

private struct DisplayStyleCard: View {
    let style: DisplayStyle
    let isSelected: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var labelSize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var descSize: CGFloat = 12

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                preview
                    .frame(height: 92)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(Tokens.bg)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack {
                    Text(style.label)
                        .font(.system(size: labelSize, weight: .semibold))
                        .foregroundStyle(Tokens.text)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Tokens.accent)
                            .font(.system(size: labelSize, weight: .bold))
                    }
                }

                Text(style.cardDescription)
                    .font(.system(size: descSize))
                    .foregroundStyle(Tokens.text3)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .background(Tokens.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isSelected ? Tokens.accent : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The two mini skeleton previews from the approved prototype
    /// (`design/claude-handoff/Sermiva.dc.html` `~501` and `~515`), reused
    /// verbatim per style - the layout this sheet itself must not invent.
    @ViewBuilder
    private var preview: some View {
        switch style {
        case .captions:
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 3).fill(Tokens.surface2).frame(width: 60, height: 5)
                RoundedRectangle(cornerRadius: 3).fill(Tokens.surface2).frame(width: 44, height: 5)
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 3).fill(Tokens.surface2).frame(width: 40, height: 6)
                RoundedRectangle(cornerRadius: 4).fill(Tokens.text3).frame(maxWidth: .infinity, maxHeight: 12)
                RoundedRectangle(cornerRadius: 4).fill(Tokens.text3).frame(width: 52, height: 12)
            }
        case .facing:
            VStack(spacing: 2) {
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 4).fill(Tokens.text3).frame(maxWidth: .infinity, maxHeight: 12)
                    RoundedRectangle(cornerRadius: 3).fill(Tokens.surface2).frame(width: 36, height: 5)
                }
                .rotationEffect(.degrees(180))
                Rectangle().fill(Tokens.sep).frame(height: 2)
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 3).fill(Tokens.surface2).frame(width: 36, height: 5)
                    RoundedRectangle(cornerRadius: 4).fill(Tokens.text3).frame(maxWidth: .infinity, maxHeight: 12)
                }
            }
        }
    }
}
