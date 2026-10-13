# Pending playback actions keep their session ownership

A pause request left the client active until the SDK emitted its paused event.
Two requests arriving before completion both called the SDK; a sender could
also replace its source during the same pending pause. Two authenticated
loopback watch/cast tests reproduced duplicate pause calls before the fix.

The client now reserves playback work on its current attempt before invoking
the SDK. Pending pause/resume excludes other playback and source actions;
source work likewise excludes playback. The panel temporarily disables the
conflicting actions and keeps stop available. Completion clears only the
original attempt's reservation, so old work cannot unlock a replacement.
A synchronous stop during notification is checked before calling the SDK.
TURN credential rotation uses the same pause path and waits for pending work;
a credential notice during a user pause cannot automatically undo that pause.
Deferred renewal is reconsidered after source or playback work completes.

Validation: two duplicate-pause tests failed before the fix; six new cases
cover both directions, early resume frames, stop during pending work,
credential renewal during user pause, and synchronous notification/stop.
The remote/recovery suites passed 130 tests; full worktree regression passed
379 tests with one skip, including unrelated uncommitted device-name edits.
Flutter analysis passed and the ordinary macOS Debug build passed.
The initial test command used a nonexistent recovery filename and was corrected;
that command failure is not a behavior test failure.

The connections and authorizations are real loopback connections; media,
playback timing, credential notices and display are controlled test doubles.
No application, capture fixture or GUI was launched. This is client concurrency
evidence, not Windows/macOS device, relay, two-device or release acceptance.
Public API, native ABI, wire profiles and grant policy are unchanged.
