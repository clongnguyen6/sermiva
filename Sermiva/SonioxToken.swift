import Foundation

/// One token from a Soniox stream, already translated from the wire JSON
/// shape into the app's own type. This is the boundary the WebSocket
/// adapter sits behind - `SonioxJoinEngine` and its tests only ever see
/// this type, never raw Soniox JSON, per AGENTS.md's rule against testing
/// through the unconfirmed wire contract. See docs/soniox-routing.md.
struct SonioxToken: Equatable {
    enum TranslationStatus: Equatable {
        /// Documented: original (spoken) text that this stream is not
        /// translating, because the audio is already in this stream's own
        /// target language. Built into segments exactly like `.original` -
        /// see docs/soniox-routing.md's Unknowns table.
        case none
        case original
        case translation
        /// Any wire value other than the three documented strings
        /// (`none`/`original`/`translation`), including a missing field.
        /// Kept distinct from `.none` on purpose - a live, undocumented
        /// value must never be silently folded into a case that now carries
        /// real meaning.
        case unrecognized
    }

    var text: String
    var isFinal: Bool
    var startMs: Int?
    var endMs: Int?
    var speaker: String?
    var language: String?
    var translationStatus: TranslationStatus
}
