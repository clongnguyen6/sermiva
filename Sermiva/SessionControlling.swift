import Foundation

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
    var micDockText: String { get }
    var micDotColorRole: SessionPresentation.MicDotColorRole { get }
    var micIconName: String { get }
    var endSessionBodyText: String { get }
    var isActivityRunning: Bool { get }
    var displaySegments: [SegmentDisplay] { get }
    var canEnd: Bool { get }

    func primaryButtonTapped()
    func endSession()
}
