import Foundation

/// The wire shapes from docs/soniox-routing.md's "Stream contract" and "Key
/// validation" sections. This file is the one place the app's JSON matches
/// Soniox's JSON - everything past it (`SonioxJoinEngine`,
/// `LiveSessionController`) only ever sees `SonioxToken` and other
/// app-owned types, so nothing outside this file needs to change if a
/// live session turns up a field name that reads differently in practice.

struct SonioxStreamConfig: Encodable {
    struct Translation: Encodable {
        let type = "one_way"
        let targetLanguage: String

        enum CodingKeys: String, CodingKey {
            case type
            case targetLanguage = "target_language"
        }
    }

    let apiKey: String
    let model = "stt-rt-v5"
    let audioFormat = "pcm_s16le"
    let sampleRate = 16_000
    let numChannels = 1
    let enableLanguageIdentification = true
    let enableSpeakerDiarization = true
    let enableEndpointDetection = true
    let languageHints: [String]
    let languageHintsStrict = false
    let translation: Translation

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case model
        case audioFormat = "audio_format"
        case sampleRate = "sample_rate"
        case numChannels = "num_channels"
        case enableLanguageIdentification = "enable_language_identification"
        case enableSpeakerDiarization = "enable_speaker_diarization"
        case enableEndpointDetection = "enable_endpoint_detection"
        case languageHints = "language_hints"
        case languageHintsStrict = "language_hints_strict"
        case translation
    }
}

struct SonioxTokenWire: Decodable {
    let text: String
    let isFinal: Bool
    let startMs: Int?
    let endMs: Int?
    let speaker: String?
    let language: String?
    let translationStatus: String?

    enum CodingKeys: String, CodingKey {
        case text
        case isFinal = "is_final"
        case startMs = "start_ms"
        case endMs = "end_ms"
        case speaker
        case language
        case translationStatus = "translation_status"
    }

    /// Drops confidence and `source_language` on purpose - the app never
    /// reads either, and this is the boundary that keeps the adapter thin.
    var appToken: SonioxToken {
        let status: SonioxToken.TranslationStatus
        switch translationStatus {
        case "original": status = .original
        case "translation": status = .translation
        default: status = .none
        }
        return SonioxToken(
            text: text,
            isFinal: isFinal,
            startMs: startMs,
            endMs: endMs,
            speaker: speaker,
            language: language,
            translationStatus: status
        )
    }
}

struct SonioxStreamResponse: Decodable {
    let tokens: [SonioxTokenWire]?
    let finalAudioProcMs: Int?
    let totalAudioProcMs: Int?
    let finished: Bool?
    let errorCode: Int?
    let errorType: String?
    let errorMessage: String?
    let requestId: String?

    enum CodingKeys: String, CodingKey {
        case tokens
        case finalAudioProcMs = "final_audio_proc_ms"
        case totalAudioProcMs = "total_audio_proc_ms"
        case finished
        case errorCode = "error_code"
        case errorType = "error_type"
        case errorMessage = "error_message"
        case requestId = "request_id"
    }
}

/// `GET /v1/models` - only the fields the Setup screen's key validation and
/// the language pickers need.
struct SonioxModelsResponse: Decodable {
    struct Model: Decodable {
        let id: String
        let languages: [String]?
        let translationTargets: [String]?

        enum CodingKeys: String, CodingKey {
            case id
            case languages
            case translationTargets = "translation_targets"
        }
    }

    let models: [Model]

    var realtimeModel: Model? {
        models.first { $0.id == "stt-rt-v5" }
    }
}

/// `GET /v1/concurrency-limits`.
struct SonioxConcurrencyLimitsResponse: Decodable {
    let concurrentSessionLimit: Int?

    enum CodingKeys: String, CodingKey {
        case concurrentSessionLimit = "concurrent_session_limit"
    }
}
