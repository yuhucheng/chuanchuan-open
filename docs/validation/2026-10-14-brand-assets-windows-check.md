# Brand assets Windows verification (field-client 1.2, 2026-10-14)

Follow-up to the 2026-09-22 brand assets validation (management record `projects/chuanchuan-product/docs/2026-09-22-brand-assets-validation.md`), which left 1.2 open for "Windows new host code build/real machine, multi-platform 16px/high-contrast acceptance". This record closes the Windows build/structure portion; real taskbar observation and the macOS portion remain open.

Heads: chuanchuan-open `290c137`, chuanchuan `4c12ae3`, chuan-agent `e0f08c7`. Flutter 3.47.2 / Dart 3.13.2, Windows 11 x64, proxies unset.

## What was verified today

| Check | Command / method | Result |
| --- | --- | --- |
| Token → Flutter theme drift | `python tool/generate_field_tokens.py --check` | "Field tokens match the product snapshot." |
| Token snapshot identical to management source | `diff assets/design/design-tokens.json` vs `projects/chuanchuan-product/design/field-client/design-tokens.json` | identical |
| Theme semantics regression | `flutter test --no-pub --concurrency=1` (includes `test/field_theme_tokens_test.dart`) | 378/378 passed |
| Windows host tray code compiles into the app | `flutter build windows --debug --no-pub` | `share_hub.exe` built (102.2s); includes `TrayIconResource()` → `ChooseTrayIconVariant(high_contrast, system_light, rgb)` and DPI-aware `TrayIconPixels` with `kRefreshTrayIcon` on theme/DPI changes |
| Native tray policy unit tests | VS BuildTools CMake `cmake --build . --config Debug` + `ctest -C Debug` in `windows/tests/build` | 5/5 passed incl. `tray_icon_policy_tests` (ink/white variant, high contrast) |
| Windows tray ICO structure | parsed `windows/runner/resources/tray_ink.ico` / `tray_white.ico` / `app_icon.ico` headers | tray ICOs contain 16/20/24/32/40/48/64 px; app ICO adds 128/256 px (matches assets/brand/README) |
| 16 px tray render legibility | extracted the 16 px PNG frame from `tray_ink.ico`, nearest-neighbour ×8, visual inspection | brand mark geometry is recognizable at 16 px |
| macOS tray template assets | `macos/Runner/Assets.xcassets/TrayIcon.imageset` | `tray_icon_16.png` + `tray_icon_32.png` + Contents.json present |
| Product build does not read the management repo | full-source grep for cross-repo references outside docs; normal Debug build runs without any generator (no rsvg on PATH) | only documentation mentions the boundary; build consumes checked-in assets only |

The wordmark font/outline portion stays as recorded on 2026-09-22 (pinned Source Han Sans CN 2.005 / Inter Tight 3.004, OFL 1.1, outline-only SVGs, manifest hashes in `assets/brand/wordmark-manifest.json`); the offline wordmark `--check` needs the locked Python venv and font cache, not rerun today.

## Still open for 1.2

- Real taskbar observation on Windows: 16 px readability in the actual tray, real high-contrast switch, multi-DPI monitors — needs the GUI app running (user launch; agent-spawned detached instances are forbidden for discovery/UI reasons).
- macOS 16 px menu-bar template and high-contrast appearance on a real Mac.
- librsvg `generate_brand_icons.py --check` drift run (rsvg-convert not on this machine's PATH; last run on Mac).

1.2 is **not** checked off; the gap is now only real-platform tray observation on both platforms.
