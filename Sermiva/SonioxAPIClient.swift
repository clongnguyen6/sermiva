import Foundation

/// Outcome of validating a Soniox key against the real service, per
/// docs/soniox-routing.md's "Key validation and language list" section.
/// `concurrencyWarning` is set when the account's own concurrency limit is
/// below the two simultaneous connections this app's two-stream session
/// needs - reported before any session starts, not discovered mid-stream.
enum SonioxKeyValidationOutcome: Equatable {
    case valid(concurrencyWarning: String?)
    case invalidKey
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

    static func validateKey(_ key: String, urlSession: URLSession = .shared) async -> SonioxKeyValidationOutcome {
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
        _ = try? JSONDecoder().decode(SonioxModelsResponse.self, from: modelsData)

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
}
