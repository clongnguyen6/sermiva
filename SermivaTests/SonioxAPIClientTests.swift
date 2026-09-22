import XCTest
@testable import Sermiva

/// Covers only the pure status-code decision `SetupView`'s key validation
/// relies on. `SonioxAPIClient.validateKey` itself opens a real network
/// connection and is never called from a test, per AGENTS.md and the
/// outcome's hard constraint against touching the real Soniox service.
final class SonioxAPIClientTests: XCTestCase {
    func test_200IsValidWithNoWarning() {
        XCTAssertEqual(SonioxAPIClient.classify(modelsStatus: 200), .valid(concurrencyWarning: nil))
    }

    func test_authClassStatusesAreRejected() {
        XCTAssertEqual(SonioxAPIClient.classify(modelsStatus: 401), .invalidKey)
        XCTAssertEqual(SonioxAPIClient.classify(modelsStatus: 402), .invalidKey)
        XCTAssertEqual(SonioxAPIClient.classify(modelsStatus: 403), .invalidKey, "a Read-only key's unresolved 403 must still be treated as rejected, per the Unknowns table")
    }

    func test_missingOrOtherStatusIsNetworkErrorNotAVerdict() {
        XCTAssertNil(SonioxAPIClient.classify(modelsStatus: nil))
        XCTAssertNil(SonioxAPIClient.classify(modelsStatus: 503))
    }

    func test_concurrencyWarningOnlyBelowTwo() {
        XCTAssertNil(SonioxAPIClient.concurrencyWarning(forLimit: nil))
        XCTAssertNil(SonioxAPIClient.concurrencyWarning(forLimit: 2))
        XCTAssertNil(SonioxAPIClient.concurrencyWarning(forLimit: 10))
        XCTAssertNotNil(SonioxAPIClient.concurrencyWarning(forLimit: 1))
        XCTAssertNotNil(SonioxAPIClient.concurrencyWarning(forLimit: 0))
    }

    // MARK: - Issue 8: a 200 must not be reported as a usable key unless it actually is

    func test_modelSupportsConfiguredLanguagesWhenBothInTranslationTargets() {
        let model = SonioxModelsResponse.Model(id: "stt-rt-v5", languages: ["vi", "en"], translationTargets: ["vi", "en", "ja"])
        XCTAssertTrue(SonioxAPIClient.modelSupportsConfiguredLanguages(model, meLanguage: "vi", targetLanguage: "en"))
    }

    func test_modelDoesNotSupportConfiguredLanguagesWhenOneIsMissingFromTargets() {
        let model = SonioxModelsResponse.Model(id: "stt-rt-v5", languages: ["vi", "en"], translationTargets: ["vi"])
        XCTAssertFalse(SonioxAPIClient.modelSupportsConfiguredLanguages(model, meLanguage: "vi", targetLanguage: "en"), "target missing from translation_targets must not be reported as usable")
    }

    func test_modelWithNoTranslationTargetsAtAllIsUnusable() {
        let model = SonioxModelsResponse.Model(id: "stt-rt-v5", languages: ["vi", "en"], translationTargets: nil)
        XCTAssertFalse(SonioxAPIClient.modelSupportsConfiguredLanguages(model, meLanguage: "vi", targetLanguage: "en"))
    }
}
