# SDK embedded-native composition preflight (development component)

`tool/sdk_package_composition.py` checks that a draft thin Flutter package
contains the exact native payload named by its pinned outer manifest. It is
read-only, requires an already extracted caller-owned staging tree, and never
returns `installable: true`. The expected outer manifest SHA-256 must come from
an independently authenticated release identity; hashing an arbitrary downloaded
manifest yourself does not establish source trust.

```sh
python3 tool/sdk_package_composition.py /path/to/staging-flutter-package \
  --expected-manifest-sha256 <trusted-64-character-lowercase-sha256>
python3 -m unittest discover -s tool/tests -p 'test_sdk_package_*.py'
```

The preflight runs the [outer inventory verifier](inventory-verifier.md), then
checks the embedded `native/<target>` root. The native manifest bytes must match
both the outer inventory and `nativePayload.manifestSha256`; its artifact ID,
SDK/product version, channel, target, API compatibility, draft ABI and capability
declarations must agree with the outer manifest. Every nested inventory entry
must have the same type, role, size/hash or link target under the outer prefix,
and the native tree is independently verified. It checks the proposed
`windows-x64`, `windows-arm64` and `macos-universal` directories. A native-only
root is rejected by this Flutter-package preflight.

The preflight also requires the draft bridge layout: the Flutter entrypoint,
target platform hook and both public API snapshot `pubspec.yaml` files; native
build metadata, a public header and a platform binary path; and referenced
license/validation files in both roots. Snapshot identity fields must be present
and well-formed. These are structural checks against the verified inventory,
not proof that the files contain working code or that their self-reported
provenance matches an independently trusted source.

The checked-in examples remain non-installable. Passing synthetic tests do not
prove a working SDK: this component does not authenticate the source, extract a
ZIP safely, validate every manifest field, inspect binary slices or runtime
dependencies, verify signatures/licenses, load native code, or configure the
client. It uses the POSIX descriptor-relative inventory backend and is not a
Windows installer verifier. Staging must remain private and unchanged across
checks; a passing read-only observation is not an atomic install transaction.

The [package design](../../packages/share_hub_media_api/native/draft/PACKAGING.md)
remains a draft until actual signed, multi-architecture artifacts and their
consumption evidence exist.
