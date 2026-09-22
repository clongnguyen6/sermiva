import Foundation

/// Wraps a microphone-capture attempt so the session state machine can be
/// driven by a fake in tests, or by the demo's own inert stand-in, instead
/// of real audio hardware.
///
/// `onUnexpectedStop` fires when capture stops for a reason outside an
/// explicit `stop()` call - backgrounding, an interruption, a media
/// services reset. The dock must never keep saying "Dang nghe" once that
/// has happened, so the controller uses this to fall back to a state that
/// is actually true. Nothing in this slice's production wiring ever calls
/// it (demo never opens real capture to begin with), but the seam and its
/// tests stay: Outcome 2's real implementation needs it.
protocol AudioCapturing: AnyObject {
    var onUnexpectedStop: (@MainActor () -> Void)? { get set }
    /// Fires with each captured buffer, already converted to the wire
    /// format both Soniox streams expect (PCM s16le, 16 kHz, mono) - see
    /// docs/soniox-routing.md's audio-origin section. Demo's
    /// `NullAudioCapture` never calls this; it never opens real capture at
    /// all.
    var onAudioBuffer: (@MainActor (Data) -> Void)? { get set }
    func start() throws
    func stop()
}

/// The production audio backend for demo mode. Per the project owner's
/// decision, demo never opens real hardware - it has no recognition to
/// feed, and a genuinely open mic would light the privacy indicator and
/// make demo indistinguishable from a live session. `start()` always
/// throws on purpose: `DemoSessionController` already treats a capture
/// failure as "keep the session running, report the mic honestly as off"
/// (see docs/demo-mic-status.md), and reusing that exact path is what
/// keeps the dock always saying "Mic tat" here rather than inventing a new
/// state. The real capture backend belongs to Outcome 2.
final class NullAudioCapture: AudioCapturing {
    enum NotUsedInDemo: Error {
        case audioIsNeverOpenedInDemoMode
    }

    var onUnexpectedStop: (@MainActor () -> Void)?
    var onAudioBuffer: (@MainActor (Data) -> Void)?

    func start() throws {
        throw NotUsedInDemo.audioIsNeverOpenedInDemoMode
    }

    func stop() {}
}
