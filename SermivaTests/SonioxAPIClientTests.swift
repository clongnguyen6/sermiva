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

    func test_concurrencyWarningOnlyBelowOne() {
        XCTAssertNil(SonioxAPIClient.concurrencyWarning(forLimit: nil))
        XCTAssertNil(SonioxAPIClient.concurrencyWarning(forLimit: 1), "option C needs only one connection")
        XCTAssertNil(SonioxAPIClient.concurrencyWarning(forLimit: 2))
        XCTAssertNil(SonioxAPIClient.concurrencyWarning(forLimit: 10))
        XCTAssertNotNil(SonioxAPIClient.concurrencyWarning(forLimit: 0))
    }

    // MARK: - Issue 8, live-key reopen: a 200 must not be reported as a usable key unless it
    // actually is. `languages` entries are `{code, name}` objects and `translation_targets`
    // entries are `{target_language, ...}` objects per the real Soniox schema - every model here
    // is built with Swift initializers, never JSON, per AGENTS.md's boundary against Soniox
    // fixtures.

    private func language(_ code: String) -> SonioxModelsResponse.Language {
        SonioxModelsResponse.Language(code: code)
    }

    private func target(_ targetLanguage: String) -> SonioxModelsResponse.TranslationTarget {
        SonioxModelsResponse.TranslationTarget(targetLanguage: targetLanguage)
    }

    func test_allLanguagesOneWayTranslationCoversMeEvenWithNoExplicitTargets() {
        let model = SonioxModelsResponse.Model(
            id: "stt-rt-v5",
            languages: [language("vi"), language("en")],
            oneWayTranslation: "all_languages",
            translationTargets: []
        )
        XCTAssertTrue(SonioxAPIClient.modelSupportsConfiguredLanguages(model, meLanguage: "vi", guestLanguage: nil), "'all_languages' must cover me even when translation_targets is empty - this is the documented shortcut, not a missing-data case")
    }

    func test_specificTranslationTargetsCoverMeWhenListedByTargetLanguage() {
        let model = SonioxModelsResponse.Model(
            id: "stt-rt-v5",
            languages: [language("vi"), language("en"), language("ja")],
            oneWayTranslation: "",
            translationTargets: [target("vi"), target("ja")]
        )
        XCTAssertTrue(SonioxAPIClient.modelSupportsConfiguredLanguages(model, meLanguage: "vi", guestLanguage: nil))
    }

    /// `target` is never checked here - option C translates `me -> target`
    /// on the device, not through Soniox - so a model missing `target` from
    /// `translation_targets` entirely must still qualify as long as `me`
    /// itself is covered.
    func test_targetMissingFromTranslationTargetsIsIrrelevant() {
        let model = SonioxModelsResponse.Model(
            id: "stt-rt-v5",
            languages: [language("vi"), language("en")],
            oneWayTranslation: "",
            translationTargets: [target("vi")]
        )
        XCTAssertTrue(SonioxAPIClient.modelSupportsConfiguredLanguages(model, meLanguage: "vi", guestLanguage: nil), "target support is irrelevant in option C - only me's own one-way translation coverage matters")
    }

    func test_meMissingFromTranslationTargetsIsUnusableWhenNotAllLanguages() {
        let model = SonioxModelsResponse.Model(
            id: "stt-rt-v5",
            languages: [language("vi"), language("en")],
            oneWayTranslation: "",
            translationTargets: [target("en")]
        )
        XCTAssertFalse(SonioxAPIClient.modelSupportsConfiguredLanguages(model, meLanguage: "vi", guestLanguage: nil), "me missing from translation_targets, with one_way_translation not 'all_languages', must not be reported as usable")
    }

    func test_undecodedLanguagesIsUnusableRatherThanCrashing() {
        let model = SonioxModelsResponse.Model(
            id: "stt-rt-v5",
            languages: nil,
            oneWayTranslation: "all_languages",
            translationTargets: []
        )
        XCTAssertFalse(SonioxAPIClient.modelSupportsConfiguredLanguages(model, meLanguage: "vi", guestLanguage: nil), "me must actually be listed in languages, even when one_way_translation says 'all_languages'")
    }

    func test_specificGuestLanguageMustAppearInLanguagesToBeUsable() {
        let model = SonioxModelsResponse.Model(
            id: "stt-rt-v5",
            languages: [language("vi"), language("en")],
            oneWayTranslation: "all_languages",
            translationTargets: []
        )
        XCTAssertFalse(SonioxAPIClient.modelSupportsConfiguredLanguages(model, meLanguage: "vi", guestLanguage: "ja"), "a specific, non-auto guest language missing from languages must not be reported as usable")
    }

    func test_autoGuestHintSkipsTheGuestLanguageCheck() {
        let model = SonioxModelsResponse.Model(
            id: "stt-rt-v5",
            languages: [language("vi"), language("en")],
            oneWayTranslation: "all_languages",
            translationTargets: []
        )
        XCTAssertTrue(SonioxAPIClient.modelSupportsConfiguredLanguages(model, meLanguage: "vi", guestLanguage: nil), "guestLanguage nil means auto - a recognition hint only - and must not require a languages entry")
    }

    // MARK: - Live reopen finding 6: an undecodable 200 body has confirmed
    // nothing about the model either way - it must not claim the specific
    // "khong ho tro cau hinh" incompatibility. `nil` here stands in for "did
    // not decode" as an app-owned Swift value, never an actual malformed
    // JSON string.

    func test_undecodedModelsBodyIsNetworkErrorNotUnusableConfiguration() {
        let outcome = SonioxAPIClient.outcomeForModelsResponse(nil, meLanguage: "vi", guestLanguage: nil)
        XCTAssertEqual(outcome, .networkError, "a body that did not decode has established nothing about the model - it must not claim the specific incompatibility")
    }

    func test_decodedResponseWithNoRealtimeModelIsUnusableConfiguration() {
        let decoded = SonioxModelsResponse(models: [])
        let outcome = SonioxAPIClient.outcomeForModelsResponse(decoded, meLanguage: "vi", guestLanguage: nil)
        XCTAssertEqual(outcome, .unusableConfiguration, "a response that decoded fine but has no stt-rt-v5 entry is genuinely unusable, not a network error")
    }

    func test_decodedResponseWithQualifyingModelQualifies() {
        let model = SonioxModelsResponse.Model(
            id: "stt-rt-v5",
            languages: [language("vi"), language("en")],
            oneWayTranslation: "all_languages",
            translationTargets: []
        )
        let decoded = SonioxModelsResponse(models: [model])
        let outcome = SonioxAPIClient.outcomeForModelsResponse(decoded, meLanguage: "vi", guestLanguage: nil)
        XCTAssertEqual(outcome, .qualifies)
    }
}
