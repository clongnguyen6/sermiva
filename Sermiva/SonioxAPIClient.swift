import Foundation

/// Outcome of validating a Soniox key against the real service, per
/// docs/soniox-routing.md's "Key validation and language list" section.
/// `concurrencyWarning` is set when the account's own concurrency limit is
/// below the two simultaneous connections this app's two-stream session
/// needs - reported before any session starts, not discovered mid-stream.
///
/// `unusableConfiguration` covers a 200 response that decoded successfully
/// but still does not confirm this app can work: no `stt-rt-v5` entry, or a
/// model that does not support one_way translation for the configured
/// `me`/`target`/`guest` languages. The key itself was accepted, so calling
/// it invalid would be dishonest; `SetupView` maps this to its own
/// "Khóa hợp lệ, nhưng không hỗ trợ cấu hình ngôn ngữ này." status line - it
/// never falls back to the generic "Lỗi mạng" copy. A 200 body that does
/// not even decode has confirmed nothing about the model either way - that
/// is `networkError`, not this; see `validateKey` below.
enum SonioxKeyValidationOutcome: Equatable {
    case valid(concurrencyWarning: String?)
    case invalidKey
    case unusableConfiguration
    case networkError
}

/// The thin REST boundary for key validation. Per the outcome's hard
/// constraints, nothing in this app calls `validateKey` except a real user
/// tapping "Kiểm tra và tiếp tục" on `SetupView` with a key they typed
/// themselves - never a test, never a preview, never with a fake key. The
/// status-code branching itself (`classify`) is a pure function and is
/// covered by `SonioxAPIClientTests` without any network access.
enum SonioxAPIClient {
    private static let modelsURL = URL(string: "https://api.soniox.com/v1/models")!
    private static let concurrencyURL = URL(string: "https://api.soniox.com/v1/concurrency-limits")!

    static func validateKey(
        _ key: String,
        meLanguage: String,
        targetLanguage: String,
        guestHint: String?,
        urlSession: URLSession = .shared
    ) async -> SonioxKeyValidationOutcome {
        var request = URLRequest(url: modelsURL)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let modelsStatus: Int?
        let modelsData: Data?
        do {
            let (data, response) = try await urlSession.data(for: request)
            modelsStatus = (response as? HTTPURLResponse)?.statusCode
            modelsData = data
        } catch {
            return .networkError
        }

        guard let outcome = classify(modelsStatus: modelsStatus) else {
            return .networkError
        }
        guard case .valid = outcome, let modelsData else {
            return outcome
        }
        let decoded = try? JSONDecoder().decode(SonioxModelsResponse.self, from: modelsData)
        switch outcomeForModelsResponse(decoded, meLanguage: meLanguage, targetLanguage: targetLanguage, guestLanguage: guestHint) {
        case .networkError: return .networkError
        case .unusableConfiguration: return .unusableConfiguration
        case .qualifies: break
        }

        var concurrencyRequest = URLRequest(url: concurrencyURL)
        concurrencyRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard
            let (limitsData, limitsResponse) = try? await urlSession.data(for: concurrencyRequest),
            (limitsResponse as? HTTPURLResponse)?.statusCode == 200,
            let limits = try? JSONDecoder().decode(SonioxConcurrencyLimitsResponse.self, from: limitsData)
        else {
            // No metering is documented for this call (docs/soniox-routing.md),
            // but its own failure must not block a key the models call
            // already accepted - it only ever adds a warning, never a reject.
            return .valid(concurrencyWarning: nil)
        }
        return .valid(concurrencyWarning: concurrencyWarning(forLimit: limits.concurrentSessionLimit))
    }

    /// 401/402/403 are the docs' auth-class errors; treat any of them, and a
    /// Read-only key's unresolved 403 (see Unknowns), the same way - key
    /// rejected. 200 is valid. Anything else is a network-shaped failure,
    /// not a verdict on the key itself.
    static func classify(modelsStatus: Int?) -> SonioxKeyValidationOutcome? {
        switch modelsStatus {
        case 200: return .valid(concurrencyWarning: nil)
        case 401, 402, 403: return .invalidKey
        default: return nil
        }
    }

    static func concurrencyWarning(forLimit limit: Int?) -> String? {
        guard let limit, limit < 2 else { return nil }
        return "Giới hạn kết nối đồng thời của tài khoản là \(limit) - phiên này cần 2."
    }

    enum ModelsResponseOutcome: Equatable {
        case networkError
        case unusableConfiguration
        case qualifies
    }

    /// The step `validateKey` takes right after a 200 `/v1/models` response:
    /// `decoded == nil` stands for a body that did not decode at all - that
    /// has established nothing about the model either way, so it is
    /// `.networkError`, never the specific "khong ho tro cau hinh"
    /// incompatibility. Only once the response decoded does "no `stt-rt-v5`
    /// entry" or "does not support one_way translation for both configured
    /// languages" actually mean something - `.unusableConfiguration`,
    /// reported honestly, never as an invalid key (the key itself was
    /// accepted). Pure and testable directly with a Swift-constructed
    /// `SonioxModelsResponse?` - `nil` stands in for "did not decode",
    /// never an actual malformed JSON string.
    static func outcomeForModelsResponse(
        _ decoded: SonioxModelsResponse?,
        meLanguage: String,
        targetLanguage: String,
        guestLanguage: String?
    ) -> ModelsResponseOutcome {
        guard let decoded else { return .networkError }
        guard
            let model = decoded.realtimeModel,
            modelSupportsConfiguredLanguages(model, meLanguage: meLanguage, targetLanguage: targetLanguage, guestLanguage: guestLanguage)
        else {
            return .unusableConfiguration
        }
        return .qualifies
    }

    /// `languages` (guest picker and support check) must list `me`,
    /// `target`, and `guest` when `guest` is a specific, non-auto language -
    /// `languages` entries are `{code, name}` objects, matched by `code`.
    /// This app's two-stream session then needs `stt-rt-v5` to support
    /// one_way translation into both `me` and `target`: per the docs, a
    /// language is covered when `one_way_translation == "all_languages"`,
    /// or else when it appears as a `target_language` in
    /// `translation_targets`. Any other `one_way_translation` value is
    /// undocumented (see docs/soniox-routing.md's Unknowns table) and is
    /// never treated as covering anything beyond what `translation_targets`
    /// itself lists.
    static func modelSupportsConfiguredLanguages(
        _ model: SonioxModelsResponse.Model,
        meLanguage: String,
        targetLanguage: String,
        guestLanguage: String?
    ) -> Bool {
        let languageCodes = Set((model.languages ?? []).map(\.code))
        guard languageCodes.contains(meLanguage), languageCodes.contains(targetLanguage) else { return false }
        if let guestLanguage, !languageCodes.contains(guestLanguage) { return false }
        return translationCovers(meLanguage, in: model) && translationCovers(targetLanguage, in: model)
    }

    private static func translationCovers(_ language: String, in model: SonioxModelsResponse.Model) -> Bool {
        if model.oneWayTranslation == "all_languages" { return true }
        return (model.translationTargets ?? []).contains { $0.targetLanguage == language }
    }
}
