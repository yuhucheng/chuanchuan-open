# SDK manifest schema implementation

The SDK package draft previously had a field table and six non-installable
examples without a complete JSON Schema. The new public schema defines all
fields, the three desktop target variants, native/Flutter roots, example versus
real identity fields, and separate draft/stable ABI declarations. Stable package
metadata records actual major/minor; a future consumer's minimum minor is distinct.
The stable ABI/release branches are review proposals, not runtime support claims.

The read-only checker applies the schema and additional SemVer range, identity,
reference and portable-path consistency rules. It uses a fixed local schema and
bounded JSON input; it does not read package payload, run hooks, fetch schemas or
change the current SDK. Results always include `installable: false`.

Validation on macOS arm64, Python 3.14.2 and jsonschema 4.26.0:

- 86 package-tool tests passed with no skips, including 11 new schema tests.
  Negative cases cover incomplete examples relabelled as candidates, unknown
  fields, invalid target combinations, mismatched native directories, null real
  identities, invalid API/snapshot declarations, draft/stable field mixing,
  invalid release declarations, metadata reference/path errors, duplicate JSON
  keys, nonfinite/floating-point numbers and oversized input.
- All six public layout examples and both current internal Mac candidate
  manifests passed the CLI. The real candidate's outer manifest SHA-256 remains
  `09e36943b397ef41da19f2896ce026e260f3d5c86146c7da191e5469ed43d999`.
  Reading these manifests did not load a binary or validate its signatures.
- A synthetic schema-valid release/stable declaration still returned
  `installable: false`; no metadata label can approve a release. A network guard
  and a manifest-only temporary directory confirm no remote schema or payload
  lookup is needed. Running without the separate development dependency reports
  `schema_dependency_missing`, with failure status and no installation approval.
- Python source compilation and workspace branch/spec/link checks passed.

No client/media implementation, public API version, native C ABI, Windows host or
SDK candidate bytes changed. The app was not built or launched in this check.
Final format/ABI approval, stable negotiation, provenance, signing, license
review, real platform acceptance and installation remain pending. See
[the schema and commands](../sdk/manifest-schema.md).
