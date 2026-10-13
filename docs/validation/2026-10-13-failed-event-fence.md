# Failed media operations cannot be revived by callbacks

The controller retains a failed picture owner until the SDK reports release or
the user retries cleanup. Previously, later connecting/ready/frame/pause events
could reactivate that same owner. A source-changed event with a higher revision
also advanced the fence, making the original end receipt look stale and leaving
the client occupied.

After failure, the current owner now accepts only failed/end events. Nonterminal
events cannot change its state, ready flag or media revision. The existing
identity and revision checks remain; the SDK's terminal end receipt can release
client ownership, and a newly started operation remains usable. Actual SDK
cleanup is still its own contract, not proved by this controller test.

Twelve RED cases cover SDK event/link failure and six later callback kinds.
Final cases retain the failure/error, model the SDK's confirmed terminal release,
accept the original end revision, then start a different session and accept its
valid ready/first-frame events.

Flutter 3.47.2 / Dart 3.13.2 results:

- Twelve cases failed against the old controller.
- 120 remote-controller and recovery cases passed with the fix.
- Full development worktree: 369 passed, one Windows-only skip.
- Analysis and ordinary macOS Debug build passed. The app was not launched.

The harness uses actual authenticated TCP loopback and fake media. The complete
worktree includes unrelated uncommitted device-name/discovery changes; it is not
a clean release identity. No SDK runtime, API, wire or grant-policy change.
Mac OS/GUI remains skipped by user request; Windows real background, physical
capture/release, dual-device, TURN and formal distribution remain pending.
Formal v0.1.0 acceptance stays 42/83.
