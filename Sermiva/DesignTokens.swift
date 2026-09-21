import SwiftUI
import UIKit

/// Color tokens from HANDOFF.md section 8. Values are taken verbatim from
/// the approved handoff; this file must not introduce new colors or change
/// existing ones without the design being reopened.
enum Tokens {
    static let bg = dynamic(light: "#F2F2F7", dark: "#000000")
    static let surface = dynamic(light: "#FFFFFF", dark: "#1C1C1E")
    static let surface2 = dynamic(light: "#E5E5EA", dark: "#2C2C2E")
    static let text = dynamic(light: "#000000", dark: "#FFFFFF")
    static let text2 = dynamic(light: "#3C3C4380", dark: "#EBEBF580") // .78 alpha per handoff
    static let text3 = dynamic(light: "#3C3C438C", dark: "#EBEBF58C") // .55 alpha per handoff
    static let sep = dynamic(light: "#3C3C433D", dark: "#54545899") // .24 / .6 alpha per handoff
    static let accent = dynamic(light: "#007AFF", dark: "#0A84FF")
    static let onAccent = Color(hex: "#FFFFFF")
    static let speakerA = dynamic(light: "#0E7C6B", dark: "#5FD2BF")
    static let speakerB = dynamic(light: "#5352C9", dark: "#9D9BFF")
    static let ok = dynamic(light: "#248A3D", dark: "#30D158")
    static let warn = dynamic(light: "#C93400", dark: "#FF9F0A")
    static let danger = dynamic(light: "#D70015", dark: "#FF453A")
    static let live = dynamic(light: "#FF3B30", dark: "#FF453A")

    private static func dynamic(light: String, dark: String) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

private extension UIColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        let hasAlpha = hex.count > 7
        let r, g, b, a: UInt64
        if hasAlpha {
            (r, g, b, a) = ((value >> 24) & 0xFF, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
        } else {
            (r, g, b, a) = ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF, 0xFF)
        }
        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }
}

extension Color {
    init(hex: String) {
        self.init(UIColor(hex: hex))
    }
}
