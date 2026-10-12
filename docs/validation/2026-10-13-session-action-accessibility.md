# Session action accessibility

The local connection panel previously exposed every disconnect button as only
“断开并撤销”, including two authenticated connections with the same peer in opposite
directions. Button navigation in a screen reader could not identify which grant
would be revoked. Recovery cancellation had the same missing target context.

The accessible action names now include the displayed device name, the existing
short identity fingerprint and the authenticated connection direction. Visible
button text is unchanged. Each callback still closes or cancels its original
connection object; display names and fingerprint summaries grant no authority.
No raw session ID or public key is added to the accessible labels.

Validation on macOS arm64 with Flutter 3.47.2 / Dart 3.13.2:

- Before the fix, the new directional-action check failed because the target's
  accessible label was absent. After the fix, two real authenticated loopback
  grants to the same peer have distinct action names; activating the outgoing
  disconnect revokes that grant while the incoming grant remains active.
- Initiator and receiver recovery cancellation checks inspect accessible action
  names at 200% text and confirm the original suspended grant is revoked.
- Keyboard-only Enter/Escape navigation from the local node to the preview tool
  keeps focus in the active dialog and restores the node on dismissal at 200%
  text, for both Mac and Windows widget configurations. Opening the tool performs
  no source query or capture. This path already passed before the label fix.
- The four targeted test files passed 20 tests. Full client regression passed
  339 tests with one Windows-only skip; `flutter analyze --no-pub` and the
  ordinary `flutter build macos --debug --no-pub` passed. The app was not launched.

The tests use widget semantics and controlled presentation, plus loopback
connection authentication. They do not run VoiceOver/Narrator, launch an app,
enumerate/capture OS sources or establish a real two-device connection. The full
working tree contains other sessions' uncommitted changes; these results are not
a reproducible release-combination claim. System screen-reader checks and actual
Windows/macOS accessibility comparison remain pending.
