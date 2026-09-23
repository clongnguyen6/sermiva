import Translation
import os

/// Resolves the fixed `me -> target` (vi -> en) on-device translation
/// direction against the device's own installed language list, per
/// docs/soniox-routing.md: matched by `languageCode`, preferring `en-US`
/// when more than one English entry exists. Shared by `SetupView`'s
/// download-check and `LiveSessionController`'s per-session availability
/// check, so both resolve to exactly the same `Locale.Language` values.
enum TranslationLanguages {
    private static let logger = Logger(subsystem: "com.clongnguyen6.sermiva", category: "MeToTargetTranslation")
    /// Logged once, ever - never any spoken text, only the resolved
    /// identifiers themselves.
    private static var didLog = false

    static func resolve() async -> (source: Locale.Language, target: Locale.Language) {
        let supported = await LanguageAvailability().supportedLanguages
        let source = resolve("vi", in: supported)
        let target = resolve("en", preferringRegion: "US", in: supported)
        if !didLog {
            didLog = true
            logger.log("resolved me->target languages: source=\(source.maximalIdentifier, privacy: .public) target=\(target.maximalIdentifier, privacy: .public)")
        }
        return (source, target)
    }

    private static func resolve(_ languageCode: String, preferringRegion: String? = nil, in supported: [Locale.Language]) -> Locale.Language {
        let matches = supported.filter { $0.languageCode?.identifier == languageCode }
        if let preferringRegion, let preferred = matches.first(where: { $0.region?.identifier == preferringRegion }) {
            return preferred
        }
        return matches.first ?? Locale.Language(identifier: languageCode)
    }
}
