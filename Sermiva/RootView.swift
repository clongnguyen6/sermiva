import SwiftUI

/// `Setup (no key) -> Conversation` per HANDOFF.md section 2. Setup shows
/// only when Keychain has no key yet (section 2.1); once a key has been
/// validated and stored, later launches go straight to a live
/// `ConversationView`, the same way Setup itself hands off right after
/// validating a key for the first time.
struct RootView: View {
    private enum Mode {
        case setup
        case demoConversation
        case liveConversation(apiKey: String)
    }

    @State private var mode: Mode
    @State private var demoEvents: [DemoEvent] = []

    init() {
        if let key = SonioxKeychainStore.loadKey() {
            _mode = State(initialValue: .liveConversation(apiKey: key))
        } else {
            _mode = State(initialValue: .setup)
        }
    }

    var body: some View {
        switch mode {
        case .setup:
            SetupView(onKeyValidated: startLive, onStartDemo: startDemo)
        case .demoConversation:
            ConversationView(events: demoEvents, isDemo: true)
        case .liveConversation(let apiKey):
            ConversationView(
                controller: LiveSessionController(apiKey: apiKey),
                onReturnToSetupAfterAuthError: returnToSetupAfterAuthError
            )
        }
    }

    private func startDemo() {
        do {
            demoEvents = try DemoFixtureLoader.loadCafeViEnEvents()
            mode = .demoConversation
        } catch {
            assertionFailure("demo-data.json missing from the app bundle: \(error)")
        }
    }

    private func startLive(apiKey: String) {
        mode = .liveConversation(apiKey: apiKey)
    }

    /// The auth-error banner's "Nhập lại khóa" action. The rejected key is
    /// removed from Keychain first, so neither this launch nor a later one
    /// auto-starts a live session with it again; the live `ConversationView`
    /// (and its `LiveSessionController`, which already ended the Soniox
    /// session the moment `.authError` was entered) is then torn down by
    /// switching `mode` away from it.
    private func returnToSetupAfterAuthError() {
        SonioxKeychainStore.deleteKey()
        mode = .setup
    }
}
