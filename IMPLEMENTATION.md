# Sermiva implementation brief

The approved design is in `design/claude-handoff/HANDOFF.md`. The standalone HTML is an interactive reference, not application code to ship. Preserve the approved UX and the original handoff files.

## First milestone

Two sequential outcomes. The first deliberately does not touch Soniox.

**Outcome 1.** A hand-made Xcode project that builds, and the conversation screen in the Phụ đề
display style replaying the sample conversation from `design/claude-handoff/demo-data.json` with
speaker labels, following the session state machine in `HANDOFF.md` section 5 including the denied
microphone branch. No network, no Soniox, no key. The build and run commands this produces are part
of the deliverable: they replace the placeholder in the Verify section of `AGENTS.md`.

**Outcome 2.** The same screen driven by the real service. Before any integration code is written,
read the current official Soniox documentation and record the chosen `me` / `guest` / `target`
routing strategy together with its limits. Validate on a Simulator, then on an actual iPhone.

The durable constraints for this repository are in `AGENTS.md`. This document only sequences the work.

## Subsequent milestones

1. Reproduce the remaining approved layouts and settings, including Facing mode, persisted language choices, pending configuration changes, localization and light/dark appearance.
2. Implement translated-speech playback with a controlled queue and interruption, then test echo and barge-in on a device.
3. Verify the handoff acceptance criteria, including scroll anchoring and maximum text size. Prepare device signing and TestFlight separately.
