# Sermiva implementation brief

The approved design is in `design/claude-handoff/HANDOFF.md`. The standalone HTML is an interactive reference, not application code to ship. Preserve the approved UX and the original handoff files.

## First milestone

Build a native SwiftUI iPhone application with a working vertical slice: microphone capture → Soniox streaming → original text, translated text and optional speaker labels on the Captions screen. Provide an explicit offline demo using the supplied fixtures. Validate on Simulator, then on an actual iPhone before expanding all layouts.

The durable constraints for this repository are in `AGENTS.md`. This document only sequences the work.

## Subsequent milestones

1. Reproduce the remaining approved layouts and settings, including Facing mode, persisted language choices, pending configuration changes, localization and light/dark appearance.
2. Implement translated-speech playback with a controlled queue and interruption, then test echo and barge-in on a device.
3. Verify the handoff acceptance criteria, including scroll anchoring and maximum text size. Prepare device signing and TestFlight separately.
