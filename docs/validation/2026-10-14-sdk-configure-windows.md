# SDK configure tool Windows run (sdk-distribution 2.1/2.2, 2026-10-14)

The 2026-09-22 evidence for `tool/test_configure_media_sdk.ps1` was recorded on macOS (PowerShell 7.6.6) and explicitly excluded Windows junction cases. This run closes that gap on Windows 11 x64 with the same pwsh 7.6.6 line.

Heads: chuanchuan-open `290c137`, chuanchuan `4c12ae3`. Command (cwd `repos/chuanchuan-open`):

```
pwsh -NoProfile -NonInteractive -File tool/test_configure_media_sdk.ps1
```

Result: **21/21 PASS, zero failures**, including the failure-barrier groups:

- `existing unpacked SDK preserved` / `conflicting SDK link preserved` / `existing local configuration preserved` / `redirected destination rejected` — pre-existing directories and valid packages are never overwritten (the 2.1 acceptance clause).
- `pub get failure preserves SDK and supports retry (preexisting=False/True)` — simulated pub get failure leaves SDK content, link target and manifest intact; first-time and pre-existing configurations both retry cleanly.
- `interrupted configuration preserves SDK and supports retry (preexisting=False/True)` — same barrier for termination mid-configuration.
- Chinese/space/bracket path fixtures run on the Windows junction backend (`junction`, not symlink; no Developer Mode required).

Not covered, unchanged from prior records: the byte-level inventory tool remains POSIX-only (`sdk_candidate_preflight.py` byte utilities), `test_configure_media_sdk_candidate.py` requires an authorized macOS arm64 candidate package and is not runnable on Windows, formal package format / real download atomicity / no-private-source consumption acceptance (3.x) stay open. 2.1 remains unchecked pending the full diagnostics matrix against the final artifact format; 2.2's scope now has both platform backends evidenced.
