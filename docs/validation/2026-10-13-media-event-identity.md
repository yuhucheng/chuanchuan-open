# Media event identity isolation

The controller previously subscribed to the current picture but did not check
all event headers. Its frame-progress branch checked sessionId only; statistics,
first-frame and lifecycle events could change state before grant/session/transport
identity was checked. Three negative cases using wrong grant, session or transport
headers reproduced a statistics sample of 9000 being accepted as current.

The controller now checks all three headers before recovery, media-revision or
state handling. Each attempt snapshots the authenticated grant ID and transport
generation when created. Recovery advances the shared grant endpoint, which must
not relabel an old picture's callbacks. Existing attempt and media-revision
checks remain; no public API, wire profile, grant policy or SDK runtime changes.

The test media fixture now tags events with its real loopback authorization or
with the actual authenticated transport for manually delivered fixture pictures.
It no longer uses a constant fake grant ID. The initial fixture updates had
missing constructor arguments and an unsupported SessionTransport getter;
those compile failures are not counted as behavioral RED evidence.

Each final negative case rejects statistics, transport readiness, a higher-
revision first frame, pause, local/peer progress, failure and end. Subsequent
correct events still become active and publish the actual sample, proving that
the foreign revision did not advance the fence.

Flutter 3.47.2 / Dart 3.13.2 validation:

- All three behavioral RED cases failed on the old controller.
- 100 remote-controller and recovery cases passed with the fix.
- Full development worktree: 349 passed, one Windows-only skip.
- Analysis and normal macOS Debug build passed. No app launch or OS capture.

Pairing and grant metadata in the harness are actual authenticated TCP loopback;
media capture, first-frame delivery and rendering are fake. Full-worktree results
include unrelated uncommitted device-name/discovery changes and do not establish
a clean release. Real Windows/macOS media, background, dual-device, TURN and formal
SDK acceptance remain pending. The normal auxiliary TLS path remains blocked;
the diagnostic segmentation comparison does not establish first pairing.
