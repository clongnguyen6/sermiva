import Foundation

/// One token from a Soniox stream, already translated from the wire JSON
/// shape into the app's own type. This is the boundary the WebSocket
/// adapter sits behind - `SonioxJoinEngine` and its tests only ever see
/// this type, never raw Soniox JSON, per AGENTS.md's rule against testing
/// through the unconfirmed wire contract. See docs/soniox-routing.md.
struct SonioxToken: Equatable {
    enum TranslationStatus: Equatable {
        case none
        case original
        case translation
    }

    var text: String
    var isFinal: Bool
    var startMs: Int?
    var endMs: Int?
    var speaker: String?
    var language: String?
    var translationStatus: TranslationStatus
}

/// docs/soniox-routing.md segment mapping: `"1" -> "A"`, `"2" -> "B"`,
/// `"3" -> "C"` in label order. Anything else - missing, non-numeric, or out
/// of the A-Z range - has no label, so the segment falls back to
/// "Chưa xác định" rather than a guessed one.
enum SonioxSpeakerLabel {
    static func label(for rawSpeaker: String?) -> String? {
        guard let rawSpeaker, let number = Int(rawSpeaker), number >= 1, number <= 26 else {
            return nil
        }
        let scalarValue = UInt8(ascii: "A") + UInt8(number - 1)
        return String(UnicodeScalar(scalarValue))
    }
}
