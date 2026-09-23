# Binary SDK package layout and compatibility — review draft 1

This is a proposed distribution contract, not an available SDK. The
[example manifests](package-examples/README.md) are explicitly non-installable and
contain null sizes/hashes because no matching binary exists. Do not invent a
checksum, download URL, signature or tested platform to fill those fields.
Existing source-link configuration remains unchanged until real packages exist.

## Artifacts and paths

One SDK version produces native-only and complete thin-Flutter artifacts for each
of `windows-x64`, `windows-arm64`, and `macos-universal` (arm64 + x86_64). Native
components are built and signed once, then included byte-for-byte in the matching
Flutter artifact. The native artifact does not require Flutter; the Flutter
artifact is self-contained apart from standard Flutter/pub dependencies. No
installer downloads an unrecorded native dependency during a build.

The proposed archive is a ZIP with exactly one package-root directory. On macOS
it must preserve framework links and file modes; extraction checks those entries
before materializing links. Names include SDK version, artifact kind and target,
for example `sharehub-media-native-<sdk-version>-windows-x64.zip` and
`sharehub-media-flutter-<sdk-version>-macos-universal.zip`. Do not substitute product
VERSION, media API version or ABI revision for the SDK version.

Native Windows package root:

```text
sdk-manifest.json
include/                         public C headers only
bin/sharehub_media.dll            private core, no Flutter dependency
bin/libwebrtc.dll                 SDK's pinned, DPI-patched dependency
lib/sharehub_media.lib            matching architecture import library
licenses/LICENSE.sdk.txt          reviewed SDK integration terms
licenses/THIRD_PARTY_NOTICES.txt
licenses/upstream/                actual dependency license files
metadata/build.json              sanitized build/compiler/input identity
metadata/validation.json          exact artifact acceptance references
samples/                         public non-Flutter consumer/provider examples
```

The Mac counterpart has `frameworks/ShareHubMedia.xcframework` and its declared
runtime dependencies instead of the Windows bin/lib paths, plus the same public
headers/licenses/metadata/samples. Both Mac slices must be present and inspected;
a folder called "universal" is not architecture proof. Preserve system-framework
versus bundled dependency distinctions. Framework component names/required runtime
files are finalized from actual link outputs, not inferred from these placeholders.

Complete Flutter package root:

```text
sdk-manifest.json
pubspec.yaml
lib/share_hub_media_sdk.dart      public factory/contract adapter
lib/src/                         distributable FFI/channel/display bridges only
public_api/share_hub_media_api/   generated snapshot of canonical public package
public_api/share_hub_session_api/
windows/CMakeLists.txt           bundle verified matching binaries
macos/                          thin plugin registration + binary references
native/<target>/                exact native package, including its manifest
licenses/                       bridge + public snapshot terms/notices
```

The Flutter archive contains the full matching native payload, so a contributor
never manually combines arbitrary core and bridge versions. The nested native
manifest bytes and all payload bytes must match the native-only artifact. The
outer manifest covers every nested file (including that native manifest) and
records the nested manifest digest. Both artifacts remain independently usable.
Installer points `.local/media-sdk/package` at the Flutter package root only;
it refuses a native-only root as an SDK Dart package.

No private Dart state machine, private Swift/C++ implementation, SDK source checkout
path, management workspace, production configuration or credential enters these
archives. Public API snapshots are generated from the public repository, carry
its license/notices and source identity, and must not become separately edited
contract definitions. An allowlisted bridge/source audit is required before release;
renaming private source files as "bridge" does not make them distributable.

## Public Dart dependencies without workspace paths

The proposed thin package depends on `public_api/share_hub_media_api` using a
relative path. That generated package retains its existing sibling session API
path. The unique client already overrides `share_hub_media_api` to its own
`packages/share_hub_media_api`; this also selects the canonical sibling session
API used by the connection package. Do not add a second SDK copy to the client's
public API imports or edit an installed package's pubspec to absolute local paths.
Other Flutter consumers may use the supplied public snapshots, or a compatible
canonical override after validating the same API/ABI matrix.

`tool/check_sdk_package_layout.py --flutter /path/to/flutter` exercises this graph
with actual public API/connection sources and a dependency-only SDK fixture.
It rejects two different API paths without override, verifies the client's existing
override, checks standalone snapshot resolution, and repeats after a Chinese/space
path relocation. It uses offline pub resolution and no private SDK source. It
neither tests the installer nor proves a native binary, plugin build or SDK behavior.

The final thin plugin retains standard Flutter registration and public Texture/
FFI/channel adaptation. Once media ownership is migrated, `flutter_webrtc`'s Dart
plugin is not assumed to be a production dependency; native WebRTC is packaged
according to actual core linkage. The Windows DPI patch remains on the SDK-owned
native dependency. Until migration, preserve the current development replacement
hook and generated plugin registration; do not delete them merely from this plan.

## Manifest fields and compatibility decisions

Each package has UTF-8 `sdk-manifest.json`, schema ID
`sharehub-sdk-package-draft-1`. Unknown schemas fail closed. The sample field shape
is review-only; schema finalization and a production validator are still pending.

| Field | Meaning / validation |
| --- | --- |
| `exampleOnly` | Examples are always rejected by installation, even if hashes are later filled |
| `artifactId`, `kind` | Immutable release-local identity; `native` or `flutter`; no path traversal |
| `sdkVersion`, `productTarget` | Separate SemVer SDK identity and supported product baseline |
| `channel` | `internal-candidate` or `release`; a label alone conveys no trust |
| `target` | OS, exact architecture set, minimum OS and runtime dependencies from actual build/link inspection |
| `apiCompatibility` | Package names with inclusive minimum, exclusive maximum, and exact tested versions; media and session separately |
| `nativeAbi` | Family plus discriminated draft/stable identity; draft uses exact revision, stable uses major/minimum minor plus required feature identifiers |
| `capabilities` | Actually verified capabilities of this artifact, not future controls/files/multiscreen features |
| `nativePayload` | Flutter-only relative directory and expected nested native manifest digest; absent for native kind |
| `publicSnapshots` | Canonical public package version, source revision/digest and relative path; no private checkout paths |
| `inventoryComplete` | Must be true for real artifacts after complete file/link enumeration; examples are false |
| `files` | Sorted full file/link inventory with role, path, size/hash or link target; root manifest alone excluded |
| `signing` | Declared signing phase/report path; verifier still checks actual signatures/trust/notarization as applicable |
| `licenseFiles`, `validationFile` | Relative inventory entries for actual reviewed terms/notices and artifact-scoped acceptance |

No size/hash/signing status is fabricated for unfinished work. Only example files
may use null mandatory release values; a real candidate/release requires concrete
byte identity, target, runtime and API/ABI values. Internal candidates can truthfully
record untrusted/unsigned status and require explicit candidate selection; they do
not silently enter the normal trusted-install path. Release requires the complete
platform matrix, licensing and appropriate trust/runtime acceptance.

A package API range is not sufficient evidence: installer checks the selected
canonical API versions and declared required capabilities before native loading,
then the thin bridge verifies the loaded binary's ABI/capabilities. Old preview-only
packages remain preview-only; no remote entry is enabled by a matching OS or
unavailableReason=null. API versions, wire session 2/profile 3/4, SDK SemVer and ABI
identity are separate. Do not infer one from another.

Experimental artifacts must match the exact supported draft revision and explicit
candidate mode. A stable ABI must choose a major before release: changes to calling
convention, field layout/ownership or existing function signatures require a new
major. Additive minor changes need size-bounded function/structure negotiation;
missing required features fail instead of becoming null calls. The current draft
headers require exact sizes/revision and do not implement that stable minor rule.
Therefore a stable artifact cannot advertise the current draft as ABI 1 merely
because the SDK version begins with 0.1. Stable query symbols/tables remain an ABI
review item; package metadata alone cannot create binary compatibility.

Minimum systems and runtime dependencies cannot be guessed from successful header
compilation. Current Mac development targets 13.0; actual native minimum-OS testing
is separate. Windows runtime/minimum OS metadata must come from its final compiler
and binaries. The public example keeps unresolved fields null and is non-installable.

## Exact bytes, inventory and trust

File entries use canonical relative POSIX paths inside the package root. Reject
absolute paths, backslashes, `.`/`..` segments, empty segments, NUL, drive/UNC forms,
case-insensitive collisions and Windows reserved device names/trailing dots/spaces.
Package-generated names use portable ASCII; normalize/check before filesystem
access. Require every regular file/link to be listed exactly once, including bridge,
headers, licenses, nested signatures and native dependency files. Unexpected files
fail; directories alone carry no executable payload. Each file records its exact
byte size and lowercase 64-hex SHA-256. Roles help audit but confer no trust.

Framework symlinks have `type=symlink`, a relative target and no file hash/size.
Resolve the complete link graph within the package root; reject escaping, dangling
or cyclic links and duplicate inventory paths through symlinked parents.
Deliberate framework aliases are explicit link entries, not duplicate file entries. Hash the resolved real files as their
own inventory entries and the exact link target in the manifest. Extract ordinary
files first into an owned staging directory without traversing links; create
verified links last. Windows artifact contents allow no links/reparse points. The
client's installer-created package Junction is separate from artifact entries.

The manifest cannot hash itself. A release index pins the exact manifest and final
archive size/hash; consumers obtain that index/expected digest from the authenticated
chosen release channel, not from the same untrusted archive without independent
source verification. Rewriting an archive plus its internal hashes must not pass
source trust. No archive URL is inferred from a file name or a "release" label.

Order: build → inspect/audit → sign native components → applicable notarization/
stapling and final framework layout → hash final files → write manifest → archive
without changing bytes/links → hash archive → publish index plus all attachments.
If signing/notarization/packaging changes bytes afterward, regenerate dependent
hashes and give the repaired candidate a new immutable identity. Do not embed a
manifest into a signed bundle and then change that manifest after signing it.

The final application's embedding/re-signing is a separate process: validate the
SDK package first, copy binaries into the app, apply required app identity/library
validation policy and record the resulting app component hashes. Never modify the
SDK cache's signed copy to make an app signature succeed. SDK source signing does
not certify a third party's final app or guarantee SmartScreen/SAC behavior.

## Installation, diagnostics and publication

Extend the existing configurator only after a real candidate/format validator is
available. Validate source trust/archive identity, safe extraction and full file
inventory, target/API/ABI/features and package layout before changing the client's
link. Do not run pub hooks/native tools from an unverified package or fall back to
private source after a formal-package validation failure.

Use a new versioned cache/staging directory; preserve existing valid SDK bytes and
links. The current configurator refuses a link pointing elsewhere. A future explicit
upgrade operation needs validated staging and an atomic switch with rollback; it
must not start replacing links as a side effect of ordinary configure. A pub-get
failure preserves the validated link and reports retry instructions. These are
separate cancellation/install tests, not guaranteed by this document.

Diagnostic categories must distinguish: missing package, native-only/wrong layout,
unknown/non-installable manifest, bad archive/file checksum, unsafe entry, untrusted
source/signature, unsupported OS/CPU/runtime, incompatible public API, incompatible
native ABI, unavailable capability and existing destination conflict. Do not report
all of them as "SDK missing". Error messages contain safe artifact IDs/relative
paths, never private credentials or full internal configuration.

The current public repository remote is GitHub `yuhucheng/chuanchuan-open`; using
its Releases for `sdk-v<version>` attachments is the proposed concrete channel,
without creating a new repository or changing app release tags. No release/tag or
URL has been created by this draft. Final release publication still needs actual
repository permissions/immutability configuration, complete attachments, retained
old versions, licenses and target acceptance. Native + Flutter artifacts for all
three target variants (six attachments) share one SDK version for formal first
release. Internal candidates may be partial and must list that incomplete matrix
explicitly. Updating only some bytes under an existing release identity is forbidden.

## Implemented inventory component

The [read-only inventory verifier](../../../../docs/sdk/inventory-verifier.md)
now checks the root digest, bounded complete file/link inventory, exact bytes and
local link graph on POSIX hosts. It is not a full schema/compatibility/signature
validator or installer, and every success still reports `installable: false`.
Windows host traversal and remaining package gates are not implemented by it.

The separate [declaration compatibility preflight](../../../../docs/sdk/compatibility-preflight.md)
compares a pinned manifest with a caller-owned consumer policy. OS/CPU/minimum-OS
and API/ABI/capability declarations receive distinct diagnostics; runtime/binary
inspection, full schema/layout and nested payload verification are still pending.
Draft ABI requires exact revision/candidate mode. Stable negotiation remains
unsupported. Neither component changes the existing configurator or approves
formal packages.
