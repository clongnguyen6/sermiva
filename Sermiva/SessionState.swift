import Foundation

/// The session state machine from HANDOFF.md section 5:
///
///   idle -> requestingMic -> connecting -> listening <-> paused -> ended
///                    \ micDenied            \ reconnecting (keeps segments, mic keeps permission)
///                                            \ authError (stops the stream, banner -> Settings)
///
/// `reconnecting` and `authError` only exist to make the network-loss and
/// auth-failure banners reachable once a real Soniox stream can report them.
/// This slice never triggers those two cases: it never opens a network
/// connection, so nothing can produce the signal they represent. They are
/// kept here so the type is the same contract the live path will drive.
enum SessionState: Equatable {
    case idle
    case requestingMic
    case micDenied
    case connecting
    case listening
    case paused
    case reconnecting
    case authError
    case ended
}
