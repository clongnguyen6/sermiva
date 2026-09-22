import Foundation

enum DemoFixtureLoader {
    enum LoaderError: Error {
        case resourceNotFound
    }

    /// Loads and decodes the `cafe_vi_en` scenario's events from
    /// `demo-data.json`, bundled from `design/claude-handoff/` (never
    /// copied - the app and the tests read the same file).
    static func loadCafeViEnEvents(bundle: Bundle = .main) throws -> [DemoEvent] {
        try loadFixture(bundle: bundle).scenarios.cafeViEn.events
    }

    /// `cafe_vi_en`'s own `config` (me vi, guest en, target en - distinct
    /// from the top-level `defaultLanguageConfig` a live session uses),
    /// decoded into the same `LiveLanguageConfig` shape so the header
    /// formula (`SessionPresentation.languageHeaderText`) can read either
    /// one identically. `"auto"` maps to `guestHint == nil`, matching
    /// `LiveLanguageConfig`'s own convention - `cafe_vi_en` itself never
    /// uses it, but a future scenario might.
    static func loadCafeViEnConfig(bundle: Bundle = .main) throws -> LiveLanguageConfig {
        let config = try loadFixture(bundle: bundle).scenarios.cafeViEn.config
        return LiveLanguageConfig(
            me: config.me,
            target: config.target,
            guestHint: config.guest == "auto" ? nil : config.guest
        )
    }

    private static func loadFixture(bundle: Bundle) throws -> DemoFixture {
        guard let url = bundle.url(forResource: "demo-data", withExtension: "json") else {
            throw LoaderError.resourceNotFound
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(DemoFixture.self, from: data)
    }
}
