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

    func test_allLanguagesOneWayTranslationCoversBothLanguagesEvenWithNoExplicitTargets() {
        let model = SonioxModelsResponse.Model(
            id: "stt-rt-v5",
            languages: [language("vi"), language("en")],
            oneWayTranslation: "all_languages",
            translationTargets: []
        )
        XCTAssertTrue(SonioxAPIClient.modelSupportsConfiguredLanguages(model, meLanguage: "vi", targetLanguage: "en", guestLanguage: nil), "'all_languages' must cover a target even when translation_targets is empty - this is the documented shortcut, not a missing-data case")
    }

    func test_specificTranslationTargetsCoverBothLanguagesWhenListedByTargetLanguage() {
        let model = SonioxModelsResponse.Model(
            id: "stt-rt-v5",
            languages: [language("vi"), language("en"), language("ja")],
            oneWayTranslation: "",
            translationTargets: [target("vi"), target("en"), target("ja")]
        )
        XCTAssertTrue(SonioxAPIClient.modelSupportsConfiguredLanguages(model, meLanguage: "vi", targetLanguage: "en", guestLanguage: nil))
    }

    func test_targetMissingFromTranslationTargetsIsUnusableWhenNotAllLanguages() {
        let model = SonioxModelsResponse.Model(
            id: "stt-rt-v5",
            languages: [language("vi"), language("en")],
            oneWayTranslation: "",
            translationTargets: [target("vi")]
        )
        XCTAssertFalse(SonioxAPIClient.modelSupportsConfiguredLanguages(model, meLanguage: "vi", targetLanguage: "en", guestLanguage: nil), "target missing from translation_targets, with one_way_translation not 'all_languages', must not be reported as usable")
    }

    func test_undecodedLanguagesIsUnusableRatherThanCrashing() {
        let model = SonioxModelsResponse.Model(
            id: "stt-rt-v5",
            languages: nil,
            oneWayTranslation: "all_languages",
            translationTargets: []
        )
        XCTAssertFalse(SonioxAPIClient.modelSupportsConfiguredLanguages(model, meLanguage: "vi", targetLanguage: "en", guestLanguage: nil), "me/target must actually be listed in languages, even when one_way_translation says 'all_languages'")
    }

    func test_specificGuestLanguageMustAppearInLanguagesToBeUsable() {
        let model = SonioxModelsResponse.Model(
            id: "stt-rt-v5",
            languages: [language("vi"), language("en")],
            oneWayTranslation: "all_languages",
            translationTargets: []
        )
        XCTAssertFalse(SonioxAPIClient.modelSupportsConfiguredLanguages(model, meLanguage: "vi", targetLanguage: "en", guestLanguage: "ja"), "a specific, non-auto guest language missing from languages must not be reported as usable")
    }

    func test_autoGuestHintSkipsTheGuestLanguageCheck() {
        let model = SonioxModelsResponse.Model(
            id: "stt-rt-v5",
            languages: [language("vi"), language("en")],
            oneWayTranslation: "all_languages",
            translationTargets: []
        )
        XCTAssertTrue(SonioxAPIClient.modelSupportsConfiguredLanguages(model, meLanguage: "vi", targetLanguage: "en", guestLanguage: nil), "guestLanguage nil means auto - a recognition hint only - and must not require a languages entry")
    }
}
