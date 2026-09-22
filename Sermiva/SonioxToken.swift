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
