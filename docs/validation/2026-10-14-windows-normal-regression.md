# Windows normal regression with full command log (2026-10-14)

Normal Windows regression of the current `release/v0.1.0` heads after fast-forwarding all three repositories. Every command is recorded verbatim with its working directory and result, closing the desktop 3.1 gap "record full Windows commands and results on the next normal regression". The Mac counterpart is not run here; cross-platform items stay unchecked.

Environment: Windows 11 x64, Flutter 3.47.2 / Dart 3.13.2 (`D:\code\chuan-agent\.tools\flutter`), all proxy variables unset before any `flutter test`. No `pub get` was needed: the pulled commits touched no pubspec.

Heads under test:

- chuanchuan-open `290c137` (client 0.1.0-dev.1+1, public media API 0.8.0)
- chuanchuan `4c12ae3` (internal SDK 0.1.0-dev.1, linked via `.local/media-sdk/package`)
- chuan-agent `e0f08c7` (management records)

## Commands and results

| # | cwd | command | result |
| --- | --- | --- | --- |
| 1 | `repos/chuanchuan-open` | `flutter analyze --no-pub` | No issues found (106.5s) |
| 2 | `repos/chuanchuan-open` | `flutter test --no-pub --concurrency=1` | All tests passed, 378/378 (2m30s) |
| 3 | `repos/chuanchuan-open` | `flutter build windows --debug --no-pub` | `Built build\windows\x64\runner\Debug\share_hub.exe` (102.2s) |
| 4 | `repos/chuanchuan/packages/share_hub_media_sdk` | `flutter analyze --no-pub` | No issues found (51.7s) |
| 5 | `repos/chuanchuan/packages/share_hub_media_sdk` | `flutter test --no-pub` | All tests passed, 229 passed / 30 skipped (native probe skips, same composition as the 2026-10-14 Mac follow-up) |
| 6 | `repos/chuanchuan-open/packages/share_hub_connection` | `flutter test --no-pub` | All tests passed, 94/94 |
| 7 | `repos/chuanchuan-open/packages/share_hub_media_api` | `flutter test --no-pub` | All tests passed, 35/35 |
| 8 | `repos/chuanchuan-open/packages/share_hub_session_api` | `flutter test --no-pub` | All tests passed, 21/21 |
| 9 | — | `sha256sum build/windows/x64/runner/Debug/libwebrtc.dll` vs SDK `build/windows/libwebrtc/build-manifest.json` `binarySha256` | identical: `2b1d26108aba6cd99acf461bed5a52b939e0d1e3607a7c95c9b240807a64a9ff` (patched self-built libwebrtc in place) |

## Scope

This is a normal source-tree regression: unit/widget tests, static analysis and an ordinary Debug build. It does not start the GUI, does not touch real capture permissions, tray gestures, background lifecycle, dual-device or online acceptance. Desktop 3.1/3.2, trusted 3.1, remote 3.1 and sdk-distribution 3.1 remain open until their Mac counterparts and real-device evidence land.

Note: `npm run workspace:status` / `spec:validate` could not run in this session — the sandbox blocked every Node child process (`spawnSync git EBUSY`, reproduced against both node binaries and via the PowerShell channel, while direct git worked). Branch alignment (`release/v0.1.0` on all three repos) was verified with direct git instead.
