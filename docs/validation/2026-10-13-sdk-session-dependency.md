# SDK session dependency identity

The native authorization adapter depends directly on the pure public session
API. A relocatable thin SDK declares both media and session snapshot paths.
The normal client must override both to its canonical public packages so that
connections, media and native authorization share one set of runtime types.
No public API, wire profile, grant type or duration changes.

The dependency-only fixture in `packages/share_hub_media_api/tool/check_sdk_package_layout.py`
passed five offline checks with Flutter 3.47.2 / Dart 3.13.2: no overrides reject
duplicate media paths; media-only overrides reject duplicate session paths;
both overrides select canonical APIs; independent snapshot resolution and
Chinese/space-path relocation resolve the expected packages. This fixture is
not a real SDK or installer acceptance test.

The current development worktree also passed analysis, 344 client tests (one
skip) and macOS Debug build. Other device-name/discovery changes are uncommitted
in that worktree; these results do not identify a reproducible release. Actual
packaged consumer evidence is recorded separately by the SDK maintainer.

Internal candidates remain unapproved for distribution. Windows, real platform
capture, dual-device communication, signing and formal SDK acceptance remain open.
