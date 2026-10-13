# Paused media event isolation

Pause retains the current media revision. Previously, activation events already
queued for that revision could change a paused controller to connecting, waiting
for a frame or active. A late transport-ready event also restored its ready flag
and could arm a first-frame deadline during pause.

The controller now ignores same-revision connecting, transport-ready,
waiting-first-frame and first-frame events while paused. The existing grant,
session, transport and older-revision fences remain. A resumed or replaced
picture uses a newer media revision, so valid resume events remain admissible.
Failure/end events are not suppressed by this pause guard.

Eight behavioral RED cases cover watch/cast and those four activation events.
Each final case verifies that pause remains paused with no ready flag or implicit
resume, then explicitly resumes, rejects an old first frame, and accepts the
new revision's ready and first-frame events.

Flutter 3.47.2 / Dart 3.13.2 validation:

- Eight cases failed against the old controller.
- 108 remote-controller/recovery cases passed with the fix.
- Full development worktree: 357 passed, one Windows-only skip.
- Static analysis and ordinary macOS Debug build passed. App not launched.

The harness uses authenticated TCP loopback and fake media. No physical capture,
renderer, Windows background, dual-device or TURN acceptance is claimed. The
worktree includes unrelated uncommitted device-name/discovery changes, so the
full-worktree run does not identify a clean release. SDK runtime/API/wire/grant
policy and duration are unchanged. macOS OS/GUI tests remain skipped per user
instruction. Formal v0.1.0 acceptance remains 42/83.
