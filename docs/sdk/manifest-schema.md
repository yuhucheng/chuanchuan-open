# SDK manifest field schema (review draft)

The [complete JSON Schema](../../packages/share_hub_media_api/native/draft/sdk-package.schema.json)
defines the existing `sharehub-sdk-package-draft-1` review format. It covers all
fields, nested objects and the native/Flutter Windows x64, Windows ARM64 and Mac
universal variants. Unknown fields are rejected. This is executable design work;
it is not a frozen stable ABI or an installable release-package contract.

`tool/sdk_package_schema.py` reads one bounded manifest and the fixed local schema.
It performs field-shape and metadata consistency checks without reading payload
files, following package references, fetching schemas, executing hooks or changing
SDK configuration. Every successful result has `installable: false`.

Use Python 3.11+ with the separate development dependencies:

```sh
python3 -m venv /path/to/sdk-schema-checks
/path/to/sdk-schema-checks/bin/python -m pip install -r tool/sdk_schema_requirements.txt
/path/to/sdk-schema-checks/bin/python tool/sdk_package_schema.py /path/to/sdk-manifest.json
/path/to/sdk-schema-checks/bin/python -m unittest discover -s tool/tests -p 'test_sdk_package_*.py' -v
```

The checker uses pinned [jsonschema 4.26.0](https://pypi.org/project/jsonschema/4.26.0/)
for Draft 2020-12 validation; the app and existing byte/compatibility tools do not
acquire this runtime dependency. Without it, the schema CLI reports
`schema_dependency_missing` and the dedicated schema tests report a dependency
skip. Install the development requirements to execute those checks.

The field rules distinguish:

| Declaration | Rule |
| --- | --- |
| Layout example | `exampleOnly=true`, incomplete inventory and internal-candidate channel; unknown byte/source identity may be null; remains unusable |
| Real candidate | Complete inventory, concrete byte/source identities, minimum OS and matching native payload directory; no null identity placeholders |
| Windows target | Exactly x64 or ARM64; package entries cannot declare symlinks |
| Mac universal target | Both arm64 and x86_64, without duplicates |
| Native-only artifact | No Flutter nativePayload or Dart publicSnapshots |
| Flutter artifact | Two distinct canonical API snapshots and the matching target's nested native identity |
| Draft ABI | Exact draft revision, without stable major/minor fields |
| Stable ABI proposal | Actual package major/minor, without draftRevision; caller minimum minor belongs to its future consumer policy |
| Release declaration proposal | Stable ABI, runtime-inspection declaration and a listed signing-report reference; labels alone establish no trust |

The checker additionally rejects duplicate JSON keys, nonfinite/floating-point
numbers, invalid SemVer forms and ranges, duplicate API/snapshot identities,
unsorted or case-colliding inventory paths, reserved/unsafe paths, a self-listed
manifest, missing metadata references and unknown fields. It bounds input to 4 MiB
and never prints raw invalid field values. SHA-256 in the result identifies only
the document that was read; it does not authenticate its publisher.

Schema-valid release/stable declarations are still only proposed metadata. No
stable native function negotiation, binary compatibility, signature report truth,
license approval, file-byte inventory or publisher trust is proved here. The
existing composition/compatibility tools continue to reject unsupported stable
or release profiles. Actual stable ABI rules and release approval remain separate
work; draft revision 2 has not become stable ABI 1.

Continue with [inventory verification](inventory-verifier.md),
[composition](composition-preflight.md), [compatibility](compatibility-preflight.md)
and [archive checks](archive-preflight.md) as applicable. Their independent
source digests, binary/signing/platform checks and installation transaction cannot
be replaced by schema validation.
