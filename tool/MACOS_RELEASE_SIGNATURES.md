# macOS release signature inspection

Run this read-only inspection against the final application bundle:

```sh
python3 tool/check_macos_release_signatures.py '/path/to/Share Hub.app' --expected-team ABCDE12345 --assess
python3 -m unittest discover -s tool/tests -p 'test_macos_release_signatures.py'
```

The tool verifies signature integrity across all architectures, separately requires Apple's Developer ID Application certificate constraint, checks secure timestamps and consistent team IDs, and rejects debug entitlements. Application/command-line code needs Hardened Runtime. Nested framework/container resource seals and every detected Mach-O component are checked. An Authority display name is not trusted evidence; `Signed Time` is not a secure timestamp.

`--assess` performs Gatekeeper and stapled-ticket validation only after signing prerequisites pass. Without it, full macOS trust checks remain incomplete. The command never signs, accesses private keys, uploads, changes system security settings, or launches the application. Failures and incomplete trust checks return nonzero; `releaseReady` always remains false because this inspection does not validate SDK provenance, licenses/API/ABI, the Windows release matrix or actual runtime/media behavior.

The checked tree must be an isolated final artifact; this read-only observation does not lock files against concurrent replacement. Framework source signatures and final application signatures are separate responsibilities: embedded components must satisfy the final application's team/library policy, while publisher provenance and original artifact identity need independent verification. This tool does not replace those checks or formal SDK acceptance.

Release enables Hardened Runtime and disables Xcode's base-entitlement injection. The Release entitlement file does not grant debugger access; Debug/Profile use their own settings. Developer ID credentials, notarization and actual loading/operation remain separate requirements.

Primary guidance: [Apple notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues), [code-signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements), and [nested code/library validation](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html).
