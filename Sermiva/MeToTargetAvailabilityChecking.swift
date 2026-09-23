import Translation

/// The seam behind `LiveSessionController`'s live session-start availability
/// check (docs/soniox-routing.md): language resolution plus
/// `LanguageAvailability().status(from:to:)`, both real `async` calls into
/// Apple's Translation framework that cannot run in the Simulator. Kept
/// behind a protocol, like `SonioxSocketConnecting`, so `LiveSessionControllerTests`
/// can drive the gate/banner/config-once logic deterministically with a fake
/// instead of the real framework.
protocol MeToTargetAvailabilityChecking {
    func resolveLanguages() async -> (source: Locale.Language, target: Locale.Language)
    func status(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailability.Status
}

/// The real, untested adapter - thin on purpose, exactly like
/// `SonioxStreamSocket` is for the Soniox wire format (AGENTS.md).
struct RealMeToTargetAvailabilityChecker: MeToTargetAvailabilityChecking {
    func resolveLanguages() async -> (source: Locale.Language, target: Locale.Language) {
        await TranslationLanguages.resolve()
    }

    func status(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: source, to: target)
    }
}
