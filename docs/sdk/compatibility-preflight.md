# SDK declaration compatibility preflight (development component)

`tool/sdk_package_compatibility.py` compares the pinned draft manifest's declared
package kind, product target, target OS/CPU/minimum OS, public API ranges, draft ABI
and capabilities against an explicit consumer policy. It never loads native code,
executes hooks, changes the configured SDK or reports that a package is installable.
It is separate from the [inventory verifier](inventory-verifier.md).

```sh
python3 tool/sdk_package_compatibility.py /path/to/sdk-manifest.json \
  /path/to/caller-owned-consumer-policy.json \
  --expected-manifest-sha256 <trusted-64-character-lowercase-sha256>
python3 -m unittest discover -s tool/tests -p 'test_sdk_package_*.py' -v
```

The consumer policy must come from the caller's actual selected build/bridge
configuration, never from the downloaded package. The following illustrates the
policy shape; its values are not proof that a matching native bridge exists:

```json
{
  "schema": "sharehub-sdk-consumer-draft-1",
  "kind": "flutter",
  "productTarget": "0.1.0",
  "target": {"os": "macos", "architecture": "arm64", "osVersion": "13.0"},
  "apiVersions": {
    "share_hub_media_api": "0.7.0",
    "share_hub_session_api": "0.1.0"
  },
  "nativeAbi": {
    "family": "sharehub-media-c",
    "stability": "draft",
    "draftRevision": 2,
    "supportedFeatures": []
  },
  "requiredCapabilities": ["preview"],
  "allowInternalCandidate": false
}
```

Select the architecture of the consumer process/build target, not merely the CPU
of the computer running this tool. The tool does not inspect that process, detect
Rosetta or inspect Mach-O/PE slices. Windows declarations can be checked on Mac;
that does not constitute Windows execution or filesystem acceptance.

Consumer policy fields are exact: unknown fields fail, including misspelled
candidate flags. Candidate selection requires a literal `true`, and does not
bypass any API, ABI or capability comparison. No product version, eight-hour grant
policy, wire protocol or SDK version is used to infer an API/ABI revision.

| Check | Behavior |
| --- | --- |
| Package identity | Known draft schema; examples and incomplete inventories rejected; requested native/Flutter kind must match |
| Product and SDK | Product baseline compares SemVer precedence; SDK version has its own valid SemVer identity |
| Platform | OS must match; Windows declares one of x86_64/arm64; Mac declares both; selected CPU must be included |
| Minimum OS | Two to four numeric components, zero-padded for comparison; missing/unresolved values fail |
| Runtime metadata | Requires explicit inspection-complete flag and dependency array; dependency contents, actual availability and linkage remain a separate gate |
| Public API | Media/session each declared exactly once; inclusive lower/exclusive upper bounds; invalid/empty ranges and out-of-range tested versions fail |
| Test identity | Stable versions within range but absent from exact `testedVersions` are returned in `untestedApiPackages`; this is not an acceptance result |
| Prerelease API | Must also appear by exact identity in `testedVersions`; broad ranges alone cannot admit prereleases |
| Draft ABI | Exact family/revision; package-required features must be supported by the caller's bridge; unknown/stable ABI is rejected until implemented |
| Capabilities | Consumer requirements must be a subset of declared artifact capabilities; preview alone cannot imply watch/cast/control |

Version precedence follows [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html),
including numeric prerelease identifiers and ignoring build metadata for ordering.
Exact tested-version identity retains build metadata. The tool bounds version
strings to 128 characters and feature/tested-version arrays to 128 entries. It
reads at most 4 MiB per JSON file, rejects duplicate keys, invalid UTF-8, NaN and
non-regular input files, and pins the exact manifest bytes before interpretation.

Stable ABI negotiation does not exist yet. Consequently the current tool rejects
all stable ABI declarations and refuses to relabel a draft ABI as a release; it
cannot approve any formal release. Existing example manifests remain rejected and
retain their unresolved values. The full manifest schema remains under review;
this checker validates compatibility fields only, not unrelated layout/signing
fields. It does not require or validate an actual file inventory.

Success returns `declarationsCompatible: true`, `installable: false`, exact API
versions still lacking declared test evidence, and the remaining checks. The
inventory verifier and this tool must use the same independently trusted digest
and an isolated staging tree; passing both still leaves full schema/layout, nested
native-payload association, source authentication, runtime/binary ABI/capabilities,
signatures/licenses, real operation and installation transaction verification.
Neither tool proves that the supplied hash or test declarations came from a trusted
publisher. No automatic installer integration or formal package acceptance is
introduced by this component.

Failures return a safe JSON category and nonzero exit status. Distinct categories
include `wrong_package_kind`, `candidate_not_enabled`, `unsupported_os`,
`unsupported_architecture`, `os_too_old`, `incompatible_public_api`,
`untested_prerelease_api`, `unsupported_native_abi`, `incompatible_native_abi`,
`unsupported_abi_feature` and `unavailable_capability`. Messages do not echo
untrusted manifest bodies or internal paths. Tests use synthetic declarations,
not signed SDK binaries or actual runtime probes.
