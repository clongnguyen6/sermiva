import XCTest
@testable import Sermiva

/// The no-guess join's contract, from `docs/soniox-routing.md`, checked as
/// invariants against many pseudo-random token sequences, plus the exact
/// reproductions the tenth review round found against `9549525`. Per
/// AGENTS.md this is built from app-owned values only (`SonioxToken`) - no
/// Soniox JSON, no socket.
///
/// The generator tags every translation token's text with exactly which
/// ground-truth utterance and chunk it came from (`[u<utterance>c<chunk>]`),
/// so the checker never re-derives the join's own certainty logic (that
/// would let a test "invent the undecided contract" instead of checking
/// against it) - it only ever asks "does a `me`-segment's shown `target`
/// contain a tag from any utterance other than its own", which is exactly
/// the no-guess rule.
@MainActor
final class SonioxJoinInvariantTests: XCTestCase {
    // MARK: - Seeded RNG (SplitMix64) - deterministic, no flakiness.

    struct SeededRNG {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

        mutating func next() -> UInt64 {
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }

        /// A value in `range`, inclusive of the lower bound, exclusive of the upper.
        mutating func nextInt(_ range: Range<Int>) -> Int {
            let span = UInt64(range.upperBound - range.lowerBound)
            return range.lowerBound + Int(next() % span)
        }

        mutating func percent(_ chance: Int) -> Bool { nextInt(0..<100) < chance }

        mutating func pick<T>(_ items: [T]) -> T { items[nextInt(0..<items.count)] }
    }

    // MARK: - Token helpers (same shapes as SonioxJoinEngineTests)

    private let meLanguage = "vi"
    private let targetLanguage = "en"
    private let thirdLanguage = "fr"

    private func original(_ text: String, final: Bool, start: Int?, end: Int?, speaker: String?, lang: String?) -> SonioxToken {
        SonioxToken(text: text, isFinal: final, startMs: start, endMs: end, speaker: speaker, language: lang, translationStatus: .original)
    }

    private func translation(_ text: String, final: Bool = true) -> SonioxToken {
        SonioxToken(text: text, isFinal: final, startMs: nil, endMs: nil, speaker: nil, language: nil, translationStatus: .translation)
    }

    private func marker(status: SonioxToken.TranslationStatus = .original) -> SonioxToken {
        SonioxToken(text: "<end>", isFinal: true, startMs: nil, endMs: nil, speaker: nil, language: nil, translationStatus: status)
    }

    private static let allMarkerStatuses: [SonioxToken.TranslationStatus] = [.original, .none, .translation, .unrecognized]

    private func tag(_ utteranceIndex: Int, _ chunkId: Int) -> String { "[u\(utteranceIndex)c\(chunkId)]" }

    private static let tagRegex = try! NSRegularExpression(pattern: "\\[u(\\d+)c(\\d+)\\]")

    private func utteranceIndices(in text: String) -> [Int] {
        let ns = text as NSString
        let matches = Self.tagRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.map { Int(ns.substring(with: $0.range(at: 1)))! }
    }

    // MARK: - Failure reporting

    private struct ScenarioFailure: Error, CustomStringConvertible {
        let seed: UInt64
        let trace: [String]
        let reason: String
        var description: String {
            "seed=\(seed)\nreason: \(reason)\ntrace:\n" + trace.joined(separator: "\n")
        }
    }

    // MARK: - The invariant test itself

    /// Kept modest so `./scripts/verify.sh` stays fast - see the handoff for
    /// the large local run (10,000 seeds) done separately, once, by hand.
    private let committedSeedCount = 300

    func test_noGuessAndPlaceholderInvariantsHoldAcrossManyRandomSeeds() {
        for offset in 0..<committedSeedCount {
            // A fixed, distinct seed per offset - deterministic across runs.
            let seed = UInt64(0x1000_0000) &+ UInt64(offset) &* 0x9E37_79B9
            do {
                try runScenario(seed: seed)
            } catch let failure as ScenarioFailure {
                XCTFail(failure.description)
                return // one failure's trace is enough; stop rather than flooding the log
            } catch {
                XCTFail("seed \(seed): unexpected error \(error)")
                return
            }
        }
    }

    // MARK: - Scenario generation and execution

    private enum PlanKind: CaseIterable {
        case clean
        case split
        case early
        case earlyWrongLanguageBleed
        case overlapBleedLive
        case mergeWithGap
        case straddleWithNext
        case silent
        case silentMidTranslation
    }

    private func weightedPlanKind(_ rng: inout SeededRNG) -> PlanKind {
        let pool: [PlanKind] = [
            .clean, .clean, .clean, .clean,
            .split, .split,
            .early, .early,
            .earlyWrongLanguageBleed,
            .overlapBleedLive,
            .mergeWithGap,
            .straddleWithNext,
            .silent,
            .silentMidTranslation,
        ]
        return rng.pick(pool)
    }

    /// Runs one full pseudo-random scenario end to end, asserting every
    /// invariant after every single response applied to the engine.
    private func runScenario(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)
        let engine = SonioxJoinEngine(meLanguage: meLanguage)
        var trace: [String] = ["seed=\(seed)"]

        var nextChunkId = 0
        var cursorMs = 0
        var mSegmentIdForUtterance: [Int: Int] = [:]
        /// Utterances whose join must stay `target == nil, targetAbandoned == false`
        /// until a reconnect/end settles them - never guessed into "abandoned"
        /// just because nothing has happened yet.
        var pendingForever: Set<Int> = []
        var previousTarget: [Int: String] = [:]
        var everAbandoned: Set<Int> = []

        func log(_ s: String) { trace.append(s) }

        func fail(_ reason: String) -> ScenarioFailure {
            ScenarioFailure(seed: seed, trace: trace, reason: reason)
        }

        /// Checked after every single response: (a)/(b) no-guess (a
        /// me-segment's target only ever contains its own utterance's
        /// tags, and never a "PARTIAL" - non-final - token committed), plus
        /// monotonicity of `target` and permanence of `targetAbandoned`.
        func checkInvariants(_ label: String) throws {
            for segment in engine.segments {
                if let text = segment.target {
                    if segment.lang == meLanguage {
                        guard let utteranceIndex = mSegmentIdForUtterance.first(where: { $0.value == segment.id })?.key else {
                            throw fail("\(label): me-segment \(segment.id) has a target but no recorded utterance mapping")
                        }
                        for found in utteranceIndices(in: text) where found != utteranceIndex {
                            throw fail("\(label): me-segment \(segment.id) (utterance \(utteranceIndex)) shows a tag from utterance \(found) in \"\(text)\" - the no-guess rule was violated")
                        }
                        if text.contains("PARTIAL") {
                            throw fail("\(label): segment \(segment.id) committed a non-final translation token (\"PARTIAL\") to target - karaoke reveal")
                        }
                    }
                    if let prev = previousTarget[segment.id], prev != text {
                        throw fail("\(label): segment \(segment.id) target changed from \"\(prev)\" to \"\(text)\" - not monotonic once resolved")
                    }
                    previousTarget[segment.id] = text
                }
                if segment.targetAbandoned {
                    everAbandoned.insert(segment.id)
                } else if everAbandoned.contains(segment.id) {
                    throw fail("\(label): segment \(segment.id) targetAbandoned flipped back to false - abandonment must be permanent")
                }
            }
        }

        /// (e): after a reconnect or end, nothing pending remains visible.
        func assertNoPlaceholders(_ label: String) throws {
            for segment in engine.segments {
                let display = SegmentDisplay.make(for: segment, isActivityRunning: true)
                if display.showsTranslatingPlaceholder {
                    throw fail("\(label): segment \(segment.id) still shows \"Đang dịch…\" - nothing pending may remain visible")
                }
            }
        }

        func deliverM(index: Int, speaker: String, language: String, startMs: Int, endMs: Int) throws {
            log("M utterance \(index): speaker=\(speaker) lang=\(language) [\(startMs),\(endMs)]")
            if rng.percent(30) {
                engine.applyStreamM([original("u\(index)-partial", final: false, start: startMs, end: min(endMs, startMs + 50), speaker: speaker, lang: nil)])
                try checkInvariants("after M non-final tail for utterance \(index)")
            }
            engine.applyStreamM([
                original("u\(index)", final: true, start: startMs, end: endMs, speaker: speaker, lang: language),
                marker(status: rng.pick(Self.allMarkerStatuses)),
            ])
            // Recorded before the invariant check below: a replayed early T
            // chunk can attach and resolve within this very `applyStreamM`
            // call (via `closeSegment`'s `replayBufferedTChunks`), so the
            // mapping must already exist before `checkInvariants` looks for it.
            mSegmentIdForUtterance[index] = engine.segments.last!.id
            try checkInvariants("after M close for utterance \(index)")
        }

        /// One or more clean sub-chunks covering `[startMs, endMs)`, each
        /// with its own original run and translation run, the interior
        /// boundaries completed implicitly (the next sub-chunk's original
        /// token) and the last one completed by an explicit marker -
        /// exercising both "Complete" triggers from docs/soniox-routing.md.
        /// Delivered live (window already open) unless `early`, in which
        /// case it is delivered before `deliverM` and must replay once the
        /// window opens.
        func deliverCleanChunks(index: Int, subchunks: Int, startMs: Int, endMs: Int) throws -> String {
            var tags: [String] = []
            let step = max(1, (endMs - startMs) / subchunks)
            for s in 0..<subchunks {
                let subStart = startMs + s * step
                let subEnd = (s == subchunks - 1) ? endMs : subStart + step
                let chunkId = nextChunkId
                nextChunkId += 1
                let tagText = tag(index, chunkId)
                tags.append(tagText)

                var toks: [SonioxToken] = []
                if rng.percent(25) {
                    toks.append(original("partial", final: false, start: subStart, end: subStart + 1, speaker: nil, lang: meLanguage))
                }
                toks.append(original("orig", final: true, start: subStart, end: max(subStart + 1, subEnd - 1), speaker: nil, lang: meLanguage))
                if rng.percent(20) {
                    toks.append(translation("PARTIAL", final: false))
                }
                toks.append(translation(tagText, final: true))

                if rng.percent(30), toks.count > 1 {
                    let splitPoint = rng.nextInt(1..<toks.count)
                    engine.applyStreamT(Array(toks[0..<splitPoint]))
                    try checkInvariants("mid-subchunk \(s) of utterance \(index)")
                    engine.applyStreamT(Array(toks[splitPoint...]))
                } else {
                    engine.applyStreamT(toks)
                }
                try checkInvariants("after subchunk \(s) of utterance \(index)")
            }
            engine.applyStreamT([marker(status: rng.pick(Self.allMarkerStatuses))])
            try checkInvariants("after closing T marker for utterance \(index)")
            return tags.joined()
        }

        func deliverWrongLanguageBleed(index: Int, startMs: Int, endMs: Int) throws {
            let wrongLanguage = rng.pick([targetLanguage, thirdLanguage])
            let chunkId = nextChunkId
            nextChunkId += 1
            engine.applyStreamT([
                original("bleed", final: true, start: startMs, end: max(startMs + 1, endMs - 1), speaker: nil, lang: wrongLanguage),
                translation(tag(index, chunkId), final: true),
                marker(status: rng.pick(Self.allMarkerStatuses)),
            ])
            try checkInvariants("after wrong-language bleed for utterance \(index)")
        }

        var index = 0
        let utteranceCount = rng.nextInt(6..<14)

        while index < utteranceCount {
            if rng.percent(8) {
                log("reconnect before utterance \(index)")
                engine.closeOpenSegmentForReconnect()
                engine.abandonAllPendingJoins()
                engine.handleStreamMReconnected()
                try checkInvariants("after reconnect")
                try assertNoPlaceholders("after reconnect")
                pendingForever.removeAll()
            }

            let speaker = "1"
            let startMs = cursorMs + rng.nextInt(50..<400)
            let duration = rng.nextInt(300..<1200)
            let endMs = startMs + duration
            cursorMs = max(cursorMs, endMs)

            let plan = weightedPlanKind(&rng)
            log("utterance \(index) plan=\(plan)")

            switch plan {
            case .clean:
                try deliverM(index: index, speaker: speaker, language: meLanguage, startMs: startMs, endMs: endMs)
                let expected = try deliverCleanChunks(index: index, subchunks: 1, startMs: startMs, endMs: endMs)
                let segment = engine.segments.first { $0.id == mSegmentIdForUtterance[index] }!
                guard segment.target == expected, !segment.targetAbandoned else {
                    throw fail("liveness: utterance \(index) (clean) expected target \"\(expected)\", got \(String(describing: segment.target)), abandoned=\(segment.targetAbandoned)")
                }

            case .split:
                try deliverM(index: index, speaker: speaker, language: meLanguage, startMs: startMs, endMs: endMs)
                let subchunks = rng.nextInt(2..<4)
                let expected = try deliverCleanChunks(index: index, subchunks: subchunks, startMs: startMs, endMs: endMs)
                let segment = engine.segments.first { $0.id == mSegmentIdForUtterance[index] }!
                guard segment.target == expected, !segment.targetAbandoned else {
                    throw fail("liveness: utterance \(index) (split into \(subchunks)) expected target \"\(expected)\", got \(String(describing: segment.target)), abandoned=\(segment.targetAbandoned)")
                }

            case .early:
                let subchunks = rng.nextInt(1..<3)
                let expected = try deliverCleanChunks(index: index, subchunks: subchunks, startMs: startMs, endMs: endMs)
                try deliverM(index: index, speaker: speaker, language: meLanguage, startMs: startMs, endMs: endMs)
                let segment = engine.segments.first { $0.id == mSegmentIdForUtterance[index] }!
                guard segment.target == expected, !segment.targetAbandoned else {
                    throw fail("liveness: utterance \(index) (early, \(subchunks) subchunks) expected target \"\(expected)\" once its window opened, got \(String(describing: segment.target)), abandoned=\(segment.targetAbandoned)")
                }

            case .earlyWrongLanguageBleed:
                try deliverWrongLanguageBleed(index: index, startMs: startMs, endMs: endMs)
                try deliverM(index: index, speaker: speaker, language: meLanguage, startMs: startMs, endMs: endMs)
                let segment = engine.segments.first { $0.id == mSegmentIdForUtterance[index] }!
                guard segment.target == nil, segment.targetAbandoned else {
                    throw fail("critical repro: utterance \(index) - an early, wrong-language chunk replayed against the newly-opened window must disqualify it, not attach on timing alone; got target=\(String(describing: segment.target)), abandoned=\(segment.targetAbandoned)")
                }

            case .overlapBleedLive:
                try deliverM(index: index, speaker: speaker, language: meLanguage, startMs: startMs, endMs: endMs)
                try deliverWrongLanguageBleed(index: index, startMs: startMs, endMs: endMs)
                let segment = engine.segments.first { $0.id == mSegmentIdForUtterance[index] }!
                guard segment.target == nil, segment.targetAbandoned else {
                    throw fail("utterance \(index) - a live wrong-language original inside the window must disqualify it; got target=\(String(describing: segment.target)), abandoned=\(segment.targetAbandoned)")
                }

            case .mergeWithGap:
                try deliverM(index: index, speaker: speaker, language: meLanguage, startMs: startMs, endMs: endMs)
                let gapPoint = endMs + 20
                let chunkId = nextChunkId
                nextChunkId += 1
                engine.applyStreamT([
                    original("inside", final: true, start: startMs, end: max(startMs + 1, endMs - 1), speaker: nil, lang: meLanguage),
                    original("outside", final: true, start: gapPoint, end: gapPoint + 50, speaker: nil, lang: thirdLanguage),
                    translation(tag(index, chunkId), final: true),
                    marker(status: rng.pick(Self.allMarkerStatuses)),
                ])
                try checkInvariants("after merge-with-gap chunk for utterance \(index)")
                let segment = engine.segments.first { $0.id == mSegmentIdForUtterance[index] }!
                guard segment.target == nil, !segment.targetAbandoned else {
                    throw fail("critical repro: utterance \(index) - a chunk with one original outside every window must not attach on its other, matching original alone, and must not be disqualified either; got target=\(String(describing: segment.target)), abandoned=\(segment.targetAbandoned)")
                }
                pendingForever.insert(index)

            case .straddleWithNext:
                guard index + 1 < utteranceCount else { continue }
                try deliverM(index: index, speaker: speaker, language: meLanguage, startMs: startMs, endMs: endMs)
                let secondStart = endMs + rng.nextInt(50..<400)
                let secondEnd = secondStart + rng.nextInt(300..<1200)
                try deliverM(index: index + 1, speaker: speaker, language: meLanguage, startMs: secondStart, endMs: secondEnd)
                cursorMs = secondEnd
                let chunkId = nextChunkId
                nextChunkId += 1
                engine.applyStreamT([
                    original("part-one", final: true, start: startMs, end: max(startMs + 1, endMs - 1), speaker: nil, lang: meLanguage),
                    original("part-two", final: true, start: secondStart, end: max(secondStart + 1, secondEnd - 1), speaker: nil, lang: meLanguage),
                    translation(tag(index, chunkId), final: true),
                    marker(status: rng.pick(Self.allMarkerStatuses)),
                ])
                try checkInvariants("after straddling chunk for utterances \(index)/\(index + 1)")
                for i in [index, index + 1] {
                    let segment = engine.segments.first { $0.id == mSegmentIdForUtterance[i] }!
                    guard segment.target == nil, !segment.targetAbandoned else {
                        throw fail("utterance \(i) - a chunk straddling two windows must attach to neither, and must not disqualify either; got target=\(String(describing: segment.target)), abandoned=\(segment.targetAbandoned)")
                    }
                    pendingForever.insert(i)
                }
                index += 1 // the extra utterance consumed above

            case .silent:
                try deliverM(index: index, speaker: speaker, language: meLanguage, startMs: startMs, endMs: endMs)
                let segment = engine.segments.first { $0.id == mSegmentIdForUtterance[index] }!
                guard segment.target == nil, !segment.targetAbandoned else {
                    throw fail("utterance \(index) - no T signal at all must never be guessed into abandoned; got target=\(String(describing: segment.target)), abandoned=\(segment.targetAbandoned)")
                }
                pendingForever.insert(index)

            case .silentMidTranslation:
                try deliverM(index: index, speaker: speaker, language: meLanguage, startMs: startMs, endMs: endMs)
                engine.applyStreamT([
                    original("mid", final: true, start: startMs, end: max(startMs + 1, endMs - 1), speaker: nil, lang: meLanguage),
                    translation("PARTIAL-mid", final: false),
                ])
                try checkInvariants("after silent-mid-translation start for utterance \(index)")
                var segment = engine.segments.first { $0.id == mSegmentIdForUtterance[index] }!
                guard SegmentDisplay.make(for: segment, isActivityRunning: true).showsTranslatingPlaceholder else {
                    throw fail("utterance \(index) - a live non-final translation token must show the placeholder")
                }
                // T goes silent: a later, empty response must clear the
                // live signal without abandoning or resolving the window.
                engine.applyStreamT([])
                try checkInvariants("after T went silent for utterance \(index)")
                segment = engine.segments.first { $0.id == mSegmentIdForUtterance[index] }!
                guard !SegmentDisplay.make(for: segment, isActivityRunning: true).showsTranslatingPlaceholder else {
                    throw fail("utterance \(index) - the placeholder must clear once T goes silent, not linger with no live signal")
                }
                guard segment.target == nil, !segment.targetAbandoned else {
                    throw fail("utterance \(index) - going silent mid-translation must not itself resolve or abandon the window")
                }
                pendingForever.insert(index)
            }

            index += 1
        }

        if rng.percent(50) {
            log("end scenario")
            engine.abandonAllPendingJoins()
            try checkInvariants("after end")
            try assertNoPlaceholders("after end")
            for i in pendingForever {
                guard let segment = engine.segments.first(where: { $0.id == mSegmentIdForUtterance[i] }) else { continue }
                guard segment.target == nil, segment.targetAbandoned else {
                    throw fail("utterance \(i) - ending the session must abandon every still-pending window; got target=\(String(describing: segment.target)), abandoned=\(segment.targetAbandoned)")
                }
            }
        } else {
            // Left "still listening" on purpose, with no final settling
            // call: a `pendingForever` utterance may by now have already
            // been legitimately resolved (to abandoned, never to real
            // text - see each plan's own immediate check above) by a
            // LATER chunk's own completion moving on to a different real
            // window, per docs/soniox-routing.md's "Complete" rule - T is
            // one continuous stream, not one independent watcher per
            // window, so this is not itself a bug to assert against here;
            // the per-step invariants above already cover it throughout.
            log("scenario left still listening with no final settling call")
        }
    }

    // MARK: - Fixed named reproductions (the exact cases the tenth review round found)

    /// Critical repro (a): an early, wrong-language (guest) chunk completes
    /// - with its own `<end>` - before any M window exists. M later opens a
    /// window at the exact same timing, as the owner speaking `me`. The
    /// replay must still re-run the language check, not attach on timing
    /// alone just because the buffered chunk's `start_ms` now matches.
    func test_criticalRepro_earlyWrongLanguageChunkMustNotAttachOnReplayEvenThoughTimingMatches() {
        let engine = SonioxJoinEngine(meLanguage: "vi")

        engine.applyStreamT([
            original("Xin chào từ khách", final: true, start: 0, end: 500, speaker: "2", lang: "en"),
            translation("Hello from the guest"),
            marker(),
        ])

        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 500, speaker: "1", lang: "vi"),
            marker(),
        ])

        XCTAssertNil(engine.segments[0].target, "an early chunk whose original tokens were never in the me language must not attach on replay just because its timing matches a window opened later")
        XCTAssertTrue(engine.segments[0].targetAbandoned, "the language check must still disqualify the window, even on replay of a buffered chunk")
    }

    /// Critical repro (b): a chunk with one original inside the owner's
    /// window and one original outside every window (no M segment covers
    /// that time at all). The chunk must not attach on the strength of its
    /// one matching original alone - and the mismatch here is a discard,
    /// not a certified disqualification, so the window must stay available
    /// for a later, cleanly-matching chunk.
    func test_criticalRepro_chunkWithOneOriginalOutsideEveryWindowMustNotAttachOnTheMatchedTokenAlone() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 500, speaker: "1", lang: "vi"),
            marker(),
        ])

        engine.applyStreamT([
            original("Xin chào", final: true, start: 0, end: 500, speaker: "1", lang: "vi"), // inside the owner's window
            original("hi there", final: true, start: 1000, end: 1200, speaker: "2", lang: "en"), // outside every window
            translation("must not attach"),
            marker(),
        ])

        XCTAssertNil(engine.segments[0].target, "a chunk with one original outside every window must not attach on the strength of its other, matching original alone")
        XCTAssertFalse(engine.segments[0].targetAbandoned, "an out-of-window token is a discard, not a certified disqualification - the window must stay available for a later, cleanly-matching chunk")

        engine.applyStreamT([
            original("Xin chào", final: true, start: 0, end: 500, speaker: "1", lang: "vi"),
            translation("Hello"),
            marker(),
        ])

        XCTAssertEqual(engine.segments[0].target, "Hello", "a later, fully clean chunk must still be able to land after an earlier straddling/mismatched chunk was merely discarded, not disqualified")
    }

    /// Placeholder repro: within one single T response, chunk A completes
    /// (its translation run ends) the instant chunk B's original arrives.
    /// Chunk A's "Đang dịch…" must clear right then - not linger just
    /// because this same response also carries a different chunk.
    func test_criticalRepro_placeholderDoesNotLingerOnAPriorChunkOnceANewChunkStartsInTheSameResponse() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 500, speaker: "1", lang: "vi"),
            marker(),
            original("Tạm biệt", final: true, start: 1000, end: 1500, speaker: "1", lang: "vi"),
            marker(),
        ])

        engine.applyStreamT([
            original("Xin chào", final: true, start: 0, end: 500, speaker: "1", lang: "vi"),
            translation("Hel", final: false),
            original("Tạm biệt", final: true, start: 1000, end: 1500, speaker: "1", lang: "vi"),
        ])

        let displayA = SegmentDisplay.make(for: engine.segments[0], isActivityRunning: true)
        XCTAssertFalse(displayA.showsTranslatingPlaceholder, "chunk A already completed the instant chunk B's original arrived in this same response - its placeholder must not linger just because this response also mentions a different chunk")
        XCTAssertNil(engine.segments[0].target, "sanity: window A is still open, not yet resolved - only its live placeholder should have cleared")
        XCTAssertFalse(engine.segments[0].targetAbandoned)
    }

    // MARK: - Liveness oracle

    /// A clean single-speaker `me` utterance whose T chunking differs
    /// mildly from M's (three chunks instead of M's one) must still receive
    /// its complete translation.
    func test_liveness_cleanMeUtteranceWithDifferentTChunkingStillReceivesItsCompleteTranslation() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Chào buổi sáng mọi người", final: true, start: 0, end: 2000, speaker: "1", lang: "vi"),
            marker(),
        ])

        engine.applyStreamT([
            original("Chào", final: true, start: 0, end: 500, speaker: "1", lang: "vi"),
            translation("Good "),
            original("buổi sáng", final: true, start: 500, end: 1200, speaker: "1", lang: "vi"),
            translation("morning "),
            original("mọi người", final: true, start: 1200, end: 2000, speaker: "1", lang: "vi"),
            translation("everyone"),
            marker(),
        ])

        XCTAssertEqual(engine.segments[0].target, "Good morning everyone", "T chunking more finely than M must still assemble into the complete translation")
        XCTAssertFalse(engine.segments[0].targetAbandoned)
    }
}
