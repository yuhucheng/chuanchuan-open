# Exit interaction across dialogs

The field body previously used AbsorbPointer during exit. That did not cover
already-open dialog routes or keyboard activation: while auxiliary cleanup was
pending, Enter on the settings Save Name button still persisted a device rename.
Two widget cases reproduced that behavior under macOS and Windows target themes,
at 860x640 and 200% text scale.

The normal application's MaterialApp builder now keeps the Navigator mounted
inside an exit interaction guard. While cleanup is pending, it absorbs pointers
and excludes descendant focus, including open dialogs. A cancelled exit restores
the previously focused live node after focusability returns. It borrows that
node; removed dialogs and a subsequent exit prevent stale restoration. No media
or connection owner is recreated, and pending input remains in the same dialog.

The two new cases check that keyboard and pointer activation cannot rename during
cleanup, then simulate failed auxiliary cleanup and verify the original focus,
input and retry action. No source query or capture starts. An initial post-fix
assertion expected only one error text, but both the global banner and settings
correctly display it; the final check targets the foreground settings error key.

Validation with Flutter 3.47.2 / Dart 3.13.2:

- 35 targeted exit, lifecycle, widget and keyboard cases passed.
- Full development worktree: 346 passed, one Windows-only skip.
- Static analysis and normal macOS Debug build passed; the app was not launched.

The worktree includes unrelated uncommitted device-name/discovery changes; these
full-worktree results do not identify a clean release. No public API, grant,
SDK runtime, native platform or wire change. macOS OS capture/GUI tests remain
skipped per user instruction. Windows real background, VoiceOver/Narrator,
dual-device and formal release acceptance remain pending.
