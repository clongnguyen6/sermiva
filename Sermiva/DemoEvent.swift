import Foundation

enum DemoEventKind: String, Decodable {
    case partial
    case final
}

/// One entry from a `demo-data.json` scenario's `events` array.
///
/// `speaker` and `lang` are only ever present on the event that first
/// introduces a segment id; later partial/final events for the same id omit
/// them, and `SegmentAssembler` must not read them past creation.
struct DemoEvent: Decodable {
    let type: DemoEventKind
    let id: Int
    let speaker: String?
    let lang: String?
    let src: String
    let tgt: String?
    let overlap: Bool?
}

/// The subset of `demo-data.json` this slice reads: the `cafe_vi_en`
/// scenario. `guest_japanese` and every other top-level key are left
/// unparsed; adding them is follow-up work, not this outcome.
struct DemoFixture: Decodable {
    struct Scenario: Decodable {
        /// The scenario's own `me`/`guest`/`target`, distinct from the
        /// top-level `defaultLanguageConfig` a live session uses - e.g.
        /// `cafe_vi_en`'s guest is the specific `en`, not `auto`.
        struct Config: Decodable {
            let me: String
            let guest: String
            let target: String
        }

        let config: Config
        let events: [DemoEvent]
    }

    struct Scenarios: Decodable {
        let cafeViEn: Scenario

        enum CodingKeys: String, CodingKey {
            case cafeViEn = "cafe_vi_en"
        }
    }

    let scenarios: Scenarios
}
