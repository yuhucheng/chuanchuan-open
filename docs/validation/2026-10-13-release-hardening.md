# Mac Release hardening and signature inspection

The generated Release application contained `get-task-allow=true` despite its source Release entitlement file omitting that key, and did not enable Hardened Runtime. Release now sets `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` and `ENABLE_HARDENED_RUNTIME=YES`.

The ordinary Mac Release build passed. Read-only inspection of the actual x86_64 and arm64 slices confirmed that debugger access is absent and Hardened Runtime is enabled. Application and nested-code integrity verification passed; production trust did not: the bundle is ad hoc, has no Developer ID/team identity and no secure timestamp. The application was not launched. This does not prove actual runtime/library validation, capture, GUI, paired-device operation, notarization or Windows acceptance.

The new `tool/check_macos_release_signatures.py` uses an Apple-anchored Developer ID certificate requirement rather than trusting certificate display names. Five controlled tests cover spoofed display names, debug access confined to the other architecture, mixed teams, missing timestamps and local signed-time confusion. These are parser/policy cases, not real Developer ID/notarization evidence. The actual current bundle is correctly rejected with a nonzero exit status.

The build used the local source SDK and current worktree, which includes other sessions' uncommitted changes. It is an observation, not a reproducible release composition. Formal signing, notarization and actual loading remain outstanding. See [inspection instructions](../../tool/MACOS_RELEASE_SIGNATURES.md).
