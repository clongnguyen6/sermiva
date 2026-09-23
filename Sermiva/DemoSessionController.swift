import Foundation
import Translation

/// Drives the section-5 session state machine for offline demo playback of
/// the `cafe_vi_en` fixture. No network, no Soniox, and - per the project
/// owner's decision - no real microphone I/O either: demo never asks for
/// OS permission and never opens real capture, so it cannot look like a
/// live session. Playback never depends on capture succeeding, which is
/// what makes that possible without the state machine lying about it -
/// see docs/demo-mic-status.md.
@MainActor
final class DemoSessionController: ObservableObject, SessionControlling {
    @Published private(set) var state: SessionState = .idle
    /// Whether the mic is genuinely capturing right now. Deliberately a
    /// separate published value, not derived from `state`: HANDOFF.md
    /// section 5's mic-dock line and the "Dang nghe..." empty state must
    /// reflect real capture, not session progress - see
    /// docs/demo-mic-status.md.
    @Published private(set) var isMicCapturing = false
    @Published private(set) var segments: [Segment] = []
    @Published private(set) var elapsed: TimeInterval = 0

    /// The single source of truth for "is this a demo session" - stored once
    /// here at construction, not re-passed as a separate flag at each call
    /// site. Views read the precomputed results below (`micDockText`,
    /// `micDotColorRole`, `micIconName`, `endSessionBodyText`) instead of
    /// branching on this themselves, so there is exactly one place left that
    /// can get the demo-vs-live decision wrong - see docs/demo-mic-status.md.
    let isDemo: Bool

    private let micPermission: MicPermissionProviding
    private let audioCapture: AudioCapturing
    private let scheduler: DemoScheduler
    private let events: [DemoEvent]
    private let eventInterval: TimeInterval
    private let translationDelay: TimeInterval
    /// `demo-data.json`'s top-level `defaultLanguageConfig` (vi/auto/en) -
    /// the same fixed default `LiveLanguageConfig.default` uses, so demo's
    /// own header genuinely matches the configuration it plays back, per
    /// HANDOFF.md section 4.
    private let languageConfig: LiveLanguageConfig

    private var eventIndex = 0
    private var playbackToken = UUID()

    init(
        events: [DemoEvent],
        isDemo: Bool,
        micPermission: MicPermissionProviding = AutoGrantedMicPermission(),
        audioCapture: AudioCapturing = NullAudioCapture(),
        scheduler: DemoScheduler = DispatchScheduler(),
        eventInterval: TimeInterval = 0.9,
        translationDelay: TimeInterval = 1.4,
        languageConfig: LiveLanguageConfig = .default
    ) {
        self.events = events
        self.isDemo = isDemo
        self.micPermission = micPermission
        self.audioCapture = audioCapture
        self.scheduler = scheduler
        self.eventInterval = eventInterval
        self.translationDelay = translationDelay
        self.languageConfig = languageConfig
        self.audioCapture.onUnexpectedStop = { [weak self] in
            self?.handleCaptureStoppedExternally()
        }
    }

    var headerText: String {
        SessionPresentation.languageHeaderText(config: languageConfig)
    }

    /// `nil` unconditionally - demo never reaches Apple Translation, so
    /// `ConversationView`'s `.translationTask` closure never runs here
    /// (fatalError rule 3).
    let translationConfiguration: TranslationSession.Configuration? = nil
    /// Demo never shows this banner, per the outcome's decision - it is
    /// visibly separated from live per AGENTS.md's demo/live invariant.
    let showsTranslationUnavailableBanner = false

    /// Never actually invoked - `translationConfiguration` is always `nil`
    /// here, so `.translationTask`'s closure never calls this - but demo
    /// still needs a real, terminating stream to satisfy `SessionControlling`.
    func makeTranslationRequests() -> AsyncStream<(id: Int, source: String)> {
        AsyncStream { $0.finish() }
    }

    func reportTranslationStarted(id: Int) {}
    func reportTranslationSuccess(id: Int, target: String) {}
    func reportTranslationFailure(id: Int) {}

    deinit {
        // The mic must not stay open once this controller leaves the view tree.
        audioCapture.stop()
    }

    /// The six HANDOFF.md section 5 mic-dock strings. In demo, per the
    /// project owner's decision, there is nothing capturing under any
    /// session state - not even "asking" or "paused", which still imply a
    /// mic that was at some point open - so `isDemo` short-circuits to
    /// "Mic tat" unconditionally, checked before anything else. The
    /// state-driven six-string mapping stays underneath for the real
    /// session Outcome 2 introduces; nothing here builds a live path early,
    /// it only keeps the existing contract reachable once `isDemo` is
    /// false. "Dang nghe" only when `isMicCapturing`, never as a function
    /// of `state` alone, so the claim that live text follows capture, not
    /// session progress, is directly testable. See docs/demo-mic-status.md
    /// for why a live `listening` with no capture falls back to "Mic tat"
    /// rather than a dedicated error string.
    static func micDockText(isMicCapturing: Bool, state: SessionState, isDemo: Bool) -> String {
        SessionPresentation.micDockText(isMicCapturing: isMicCapturing, state: state, isDemo: isDemo)
    }

    /// What `ConversationView` actually reads: the pure function above,
    /// applied to this controller's own state and its own `isDemo`. The view
    /// passes no flag of its own at this call site any more - see `isDemo`.
    var micDockText: String {
        Self.micDockText(isMicCapturing: isMicCapturing, state: state, isDemo: isDemo)
    }

    /// The mic dock's dot color, as a role rather than a `Color` so it is
    /// directly testable without SwiftUI. Demo never implies a mic that is
    /// open or was ever open - not even "asking" (warn) - so it stays
    /// `.neutral` throughout, the same rule `micDockText` follows.
    typealias MicDotColorRole = SessionPresentation.MicDotColorRole

    static func micDotColorRole(isMicCapturing: Bool, state: SessionState, isDemo: Bool) -> MicDotColorRole {
        SessionPresentation.micDotColorRole(isMicCapturing: isMicCapturing, state: state, isDemo: isDemo)
    }

    var micDotColorRole: MicDotColorRole {
        Self.micDotColorRole(isMicCapturing: isMicCapturing, state: state, isDemo: isDemo)
    }

    /// HANDOFF.md section 2.2/10: the mic dock line is chấm + icon + chữ,
    /// not color alone. `mic.fill` only while genuinely capturing; `mic.slash`
    /// otherwise - which in demo is unconditional, same rule as the text and
    /// the dot color.
    static func micIconName(isMicCapturing: Bool, isDemo: Bool) -> String {
        SessionPresentation.micIconName(isMicCapturing: isMicCapturing, isDemo: isDemo)
    }

    var micIconName: String {
        Self.micIconName(isMicCapturing: isMicCapturing, isDemo: isDemo)
    }

    /// The End Session sheet's body, precomputed here from the same single
    /// `isDemo` source rather than the sheet re-deciding it from a flag
    /// `ConversationView` passes in.
    var endSessionBodyText: String {
        EndSessionSheet.bodyText(isDemo: isDemo)
    }

    /// Whether backend activity - recognition or translation - is genuinely
    /// happening right now, i.e. `state == .listening`. Pairs with the
    /// translation lifecycle below: a pending translation is gated by the
    /// same `playbackToken` pause/end/"Phien moi" already rotate, so by the
    /// time this is false, no translation is actually landing in the
    /// background either - the demo's own activity, not merely its display,
    /// stops with the session. `CaptionsTranscriptView` never reads this
    /// value directly - it reads `displaySegments` below, which folds this
    /// into each segment's own precomputed result.
    static func isActivityRunning(for state: SessionState) -> Bool {
        SessionPresentation.isActivityRunning(for: state)
    }

    var isActivityRunning: Bool { Self.isActivityRunning(for: state) }

    /// What `CaptionsTranscriptView` actually reads: one `SegmentDisplay`
    /// per segment, combining that segment with this controller's own
    /// `isActivityRunning`. The view never sees `isActivityRunning` on its
    /// own, so it cannot recombine it with a segment's shape itself at each
    /// of its several render sites - see `SegmentDisplay`.
    var displaySegments: [SegmentDisplay] {
        let running = isActivityRunning
        return segments.map { SegmentDisplay.make(for: $0, isActivityRunning: running) }
    }

    /// Whether "Ket thuc" may open the confirmation sheet right now. A pure
    /// function of state so it is directly testable for states (like
    /// `reconnecting`) that this offline slice never actually reaches -
    /// see `SessionStateMachineTests`.
    static func canEnd(for state: SessionState) -> Bool {
        SessionPresentation.canEnd(for: state)
    }

    var canEnd: Bool { Self.canEnd(for: state) }

    private enum PrimaryAction {
        case beginRequestingMic
        case resume
        case pause
        case startNewSession
        case none
    }

    /// Maps the primary dock button per HANDOFF.md section 5: idle ->
    /// Bat dau, listening/reconnecting -> Tam dung, paused -> Tiep tuc,
    /// connecting -> spinner (disabled), ended -> Phien moi. `micDenied`
    /// re-checks the real permission (the OS answers instantly once it has
    /// already been decided, so this is how a grant via Settings takes
    /// effect - see docs/demo-mic-status.md). `requestingMic` and
    /// `authError` stay inert: the section-5 table defines no action for
    /// them here.
    private static func primaryAction(for state: SessionState) -> PrimaryAction {
        switch state {
        case .idle, .micDenied:
            return .beginRequestingMic
        case .paused:
            return .resume
        case .listening, .reconnecting:
            return .pause
        case .ended:
            return .startNewSession
        case .requestingMic, .connecting, .authError:
            return .none
        }
    }

    func primaryButtonTapped() {
        switch Self.primaryAction(for: state) {
        case .beginRequestingMic: beginRequestingMic()
        case .resume: resume()
        case .pause: pause()
        case .startNewSession: startNewSession()
        case .none: break
        }
    }

    func endSession() {
        guard canEnd else { return }
        playbackToken = UUID()
        audioCapture.stop()
        isMicCapturing = false
        state = .ended
    }

    private func beginRequestingMic() {
        state = .requestingMic
        micPermission.requestPermission { [weak self] granted in
            guard let self else { return }
            if granted {
                self.beginConnecting()
            } else {
                self.state = .micDenied
            }
        }
    }

    private func beginConnecting() {
        state = .connecting
        startCaptureAndPlayback()
    }

    private func resume() {
        startCaptureAndPlayback()
    }

    /// Attempts capture, then always starts playback regardless of whether
    /// it opened. Microphone and session are separate states (AGENTS.md): a
    /// capture failure is not a permission denial and must not silently
    /// stop the demo from playing. In production this branch is taken on
    /// purpose every time (`NullAudioCapture.start()` always throws), which
    /// is what keeps `isMicCapturing` honestly false throughout a demo
    /// session; see docs/demo-mic-status.md.
    private func startCaptureAndPlayback() {
        do {
            try audioCapture.start()
            isMicCapturing = true
        } catch {
            isMicCapturing = false
        }
        state = .listening
        playbackToken = UUID()
        rescheduleUntranslatedFinals(token: playbackToken)
        playNextEvent(token: playbackToken)
    }

    private func pause() {
        playbackToken = UUID()
        audioCapture.stop()
        isMicCapturing = false
        state = .paused
    }

    /// Capture stopped itself for a reason outside the user's own pause tap
    /// (backgrounding, a phone call, media services reset - see
    /// `AudioCapturing`). `isMicCapturing` drops immediately either way. The
    /// session also moves to `paused`, not left "listening" against a dead
    /// mic, so playback does not keep silently advancing while the app is
    /// not even in the foreground - a reasonable choice within section 5's
    /// vocabulary, not the only one; written down here since it is a
    /// judgment call.
    private func handleCaptureStoppedExternally() {
        isMicCapturing = false
        guard state == .listening else { return }
        playbackToken = UUID()
        state = .paused
    }

    /// "Phien moi" clears the transcript and restarts the flow immediately,
    /// per the approved prototype's `replay()` + `startFlow()` - it does not
    /// stop at idle waiting for a second tap.
    private func startNewSession() {
        playbackToken = UUID()
        segments = []
        elapsed = 0
        eventIndex = 0
        beginRequestingMic()
    }

    private func playNextEvent(token: UUID) {
        guard state == .listening, token == playbackToken, eventIndex < events.count else { return }
        let event = events[eventIndex]
        eventIndex += 1
        elapsed += eventInterval
        SegmentAssembler.apply(event, elapsed: elapsed, to: &segments)
        if event.type == .final, let target = event.tgt {
            scheduleTranslation(id: event.id, target: target, token: token)
        }
        scheduler.schedule(after: eventInterval) { [weak self] in
            self?.playNextEvent(token: token)
        }
    }

    /// Simulated translation is part of the session, not a background
    /// process that outlives it: `token` is the `playbackToken` in force
    /// when this was scheduled, and pause/end/"Phien moi" all rotate that
    /// token before this fires, so `applyTarget` below silently declines to
    /// land once the session that asked for it is no longer the current
    /// one - the project owner's ruling this outcome implements.
    private func scheduleTranslation(id: Int, target: String, token: UUID) {
        scheduler.schedule(after: translationDelay) { [weak self] in
            self?.applyTarget(id: id, target: target, token: token)
        }
    }

    private func applyTarget(id: Int, target: String, token: UUID) {
        guard token == playbackToken else { return }
        SegmentAssembler.fillTarget(id: id, target: target, in: &segments)
    }

    /// Resume must not leave a translation stuck forever: pause/end freeze
    /// `applyTarget` from landing via the token check above, so any segment
    /// still `isFinal` with no `target` when playback resumes had its
    /// translation interrupted, not merely delayed. Reschedule it with a
    /// fresh simulated delay under the new token, so "Dang dich..." -
    /// gated on `isActivityRunning` - reflects a translation that is
    /// genuinely running again, not a stale readout.
    private func rescheduleUntranslatedFinals(token: UUID) {
        for segment in segments where segment.isFinal && segment.target == nil {
            guard let target = events.first(where: { $0.id == segment.id && $0.type == .final })?.tgt else { continue }
            scheduleTranslation(id: segment.id, target: target, token: token)
        }
    }
}
