# Remote picture headings reflect actual state

The panel heading previously described watching/casting as running regardless
of phase. Incoming cast even said the peer had cast to this device before its
first frame. The adjacent status line was accurate, but the heading contradicted
waiting, pause and failure.

The heading now combines the actual send/receive direction with connecting,
waiting-first-frame, paused or failed state. Active session wording and recovery
wording stay unchanged. Cleanup failure uses "picture resources not fully released"
without a direction claim: at that point the picture can have moved to retained
cleanup ownership, and the controller's current sends getter no longer identifies
that owner. Stop/retry behavior is unchanged.

Four widget cases cover locally initiated/incoming watch/cast through connecting,
waiting, active, paused, failed and cleanup-failed headings. The harness uses
actual TCP authorization; media and incoming delivery are fixtures. After the
initial test assumed local startup was already waiting, the fixture was corrected
to emit the explicit waiting event. Corrected old-heading cases still failed in
all four directions. A first proposed directional cleanup heading failed two
cases because sending could be projected as receiving after cleanup handoff;
the final generic cleanup heading avoids that unsupported claim.

Flutter 3.47.2 / Dart 3.13.2: 124 targeted cases and 373 full-worktree tests passed
(one Windows-only skip), analysis and normal macOS Debug build passed. The app
was not launched. Full-worktree results include unrelated uncommitted device-name/
discovery edits and do not identify a clean release.

No media controller, public API, SDK runtime, wire or grant changes. Native screen
capture/GUI remain skipped per user instruction; real Windows/background,
VoiceOver/Narrator, dual-device, TURN and formal SDK acceptance remain pending.
Formal v0.1.0 acceptance remains 42/83.
