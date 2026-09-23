import Foundation
import Translation

/// What `ConversationView` actually reads from a session controller -
/// implemented by `DemoSessionController` (offline playback) and
/// `LiveSessionController` (real Soniox streams) so the one approved screen
/// can be driven by either, per the outcome's routing decision, without
/// `ConversationView` itself knowing which.
@MainActor
protocol SessionControlling: ObservableObject {
    var state: SessionState { get }
    var isMicCapturing: Bool { get }
    var segments: [Segment] { get }
    var elapsed: TimeInterval { get }
    var isDemo: Bool { get }
    var headerText: String { get }
    var micDockText: String { get }
    var micDotColorRole: SessionPresentation.MicDotColorRole { get }
    var micIconName: String { get }
    var endSessionBodyText: String { get }
    var isActivityRunning: Bool { get }
    var displaySegments: [SegmentDisplay] { get }
    var canEnd: Bool { get }

    /// `nil` in demo, so `ConversationView`'s `.translationTask` closure
    /// never runs there (fatalError rule 3). For a live session, set from
    /// `nil` to a value at most once per controller, only once `.installed`
    /// is confirmed, and never reassigned/invalidated/nilled afterward
    /// (fatalError rule 2) - see `LiveSessionController`.
    var translationConfiguration: TranslationSession.Configuration? { get }
    /// True only while the device cannot translate `me -> target`, from the
    /// live session-start availability check through the rest of that
    /// session - never in demo, and cleared again the moment that session
    /// attempt ends (including a failed connect). See docs/soniox-routing.md.
    var showsTranslationUnavailableBanner: Bool { get }
    /// True only while the most recent connection attempt (the very first
    /// connect of a session, never a mid-session reconnect - that has its
    /// own "Mất mạng" banner) failed for a non-auth (network-class) reason -
    /// never in demo. Cleared only once a LATER "Bắt đầu" actually succeeds
    /// (review round 4, finding 5).
    var showsNetworkErrorBanner: Bool { get }
    /// True only during the short, fixed grace wait after Kết thúc is
    /// confirmed while reconnecting (review round 5, findings 4 and 7) -
    /// the primary button and Kết thúc itself must both be inert for its
    /// duration, using only this existing flag - no new state, no new copy.
    /// Demo never has such a wait, so this is always `false` there.
    var isEndPending: Bool { get }
    /// A fresh stream every call (fatalError rule 4), of final `me`-language
    /// segments waiting for on-device translation.
    func makeTranslationRequests() -> AsyncStream<(id: Int, source: String)>
    /// The instant `.translationTask`'s closure is about to translate `id` -
    /// not when it was merely queued (fatalError rule 7). `false` means the
    /// closure must skip `translate` entirely for `id` - it is no longer
    /// recognised or translation is currently unavailable; `true` means the
    /// closure should actually call `translate` and show "Đang dịch…".
    func reportTranslationStarted(id: Int) -> Bool
    func reportTranslationSuccess(id: Int, target: String)
    func reportTranslationFailure(id: Int)

    func primaryButtonTapped()
    func endSession()
}
