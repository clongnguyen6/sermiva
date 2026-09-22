import Foundation

/// Outcome of validating a Soniox key against the real service, per
/// docs/soniox-routing.md's "Key validation and language list" section.
/// `concurrencyWarning` is set when the account's own concurrency limit is
/// below the two simultaneous connections this app's two-stream session
/// needs - reported before any session starts, not discovered mid-stream.
///
/// `unusableConfiguration` covers a 200 response that does not actually
/// confirm this app can work: undecodable JSON, no `stt-rt-v5` entry, or a
/// model that does not support one_way translation for the configured
/// `me`/`target` languages. The key itself was accepted, so calling it
/// invalid would be dishonest; HANDOFF's SettingsView vocabulary
/// ("Chưa kiểm tra / Đang kiểm tra… / Khóa hợp lệ / Khóa không hợp lệ /
/// Lỗi mạng") has no case that fits this either, so `SetupView` maps it
/// onto the existing "Lỗi mạng" copy - not literally accurate either, left
/// for the project owner to decide.
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
        // A 200 only actually confirms the key works for this app once the
        // response decodes, names `stt-rt-v5`, and that model supports
        // one_way translation for both configured languages - anything
        // less is reported honestly as unusable, never as an invalid key
        // (the key itself was accepted) and never as a false "valid".
        guard
            let decoded = try? JSONDecoder().decode(SonioxModelsResponse.self, from: modelsData),
            let model = decoded.realtimeModel,
            modelSupportsConfiguredLanguages(model, meLanguage: meLanguage, targetLanguage: targetLanguage)
        else {
            return .unusableConfiguration
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

    /// This app's two-stream session needs `stt-rt-v5` to support one_way
    /// translation into both the configured `me` and `target` languages -
    /// checked against `translation_targets`, the field the docs say
    /// supplies the me/target pickers.
    static func modelSupportsConfiguredLanguages(
        _ model: SonioxModelsResponse.Model,
        meLanguage: String,
        targetLanguage: String
    ) -> Bool {
        guard let targets = model.translationTargets else { return false }
        return targets.contains(meLanguage) && targets.contains(targetLanguage)
    }
}
