# SDK staging cancellation cleanup — 2026-10-13

The POSIX SDK extractor previously removed its new staging directory for ordinary exceptions, but retained partial files when `KeyboardInterrupt` or `SystemExit` escaped. It now cleans its owned stage for these exits and re-raises the original interruption. The CLI maps Ctrl+C to `extraction_cancelled`, `installable: false`, and exit 130.

Before the fix, new tests reproduced three failure assertions: KeyboardInterrupt during file writing, SystemExit during file writing, and SIGINT delivered to an actual child CLI after regular files and a framework link had been extracted. After the fix the extraction suite passes all 5 tests, including those two added methods. The complete Python tools suite passes 98 tests without skips, using Python 3.14.2 and jsonschema 4.26.0.

The child interruption check preserves an existing active SDK symlink and contents, the input ZIP digest, and a sibling staging directory. Writing interruptions are isolated in separate temporary parents. Fixtures are synthetic and no SDK binary is loaded, application launched or service accessed. Archive/manifest hashes, link verification and all previous non-installable results remain enforced.

This repairs handled cancellation in an existing staging component. It does not implement atomic activation, recovery after SIGKILL/power loss, Windows filesystem traversal, publisher trust, final package/ABI approval, licenses or release signing. Formal SDK installation and platform acceptance remain pending.
