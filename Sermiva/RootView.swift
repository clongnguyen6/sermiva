import SwiftUI

/// `Setup (no key) -> Conversation` per HANDOFF.md section 2. Only the
/// demo path is wired; the real-key path stays on Setup, per scope.
struct RootView: View {
    private enum Mode {
        case setup
        case conversation
    }

    @State private var mode: Mode = .setup
    @State private var demoEvents: [DemoEvent] = []

    var body: some View {
        switch mode {
        case .setup:
            SetupView(onStartDemo: startDemo)
        case .conversation:
            ConversationView(events: demoEvents, isDemo: true)
        }
    }

    private func startDemo() {
        do {
            demoEvents = try DemoFixtureLoader.loadCafeViEnEvents()
            mode = .conversation
        } catch {
            assertionFailure("demo-data.json missing from the app bundle: \(error)")
        }
    }
}
