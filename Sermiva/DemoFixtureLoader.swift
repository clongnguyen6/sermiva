import Foundation

enum DemoFixtureLoader {
    enum LoaderError: Error {
        case resourceNotFound
    }

    /// Loads and decodes the `cafe_vi_en` scenario's events from
    /// `demo-data.json`, bundled from `design/claude-handoff/` (never
    /// copied - the app and the tests read the same file).
    static func loadCafeViEnEvents(bundle: Bundle = .main) throws -> [DemoEvent] {
        guard let url = bundle.url(forResource: "demo-data", withExtension: "json") else {
            throw LoaderError.resourceNotFound
        }
        let data = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode(DemoFixture.self, from: data)
        return fixture.scenarios.cafeViEn.events
    }
}
