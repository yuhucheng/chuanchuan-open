# SDK inventory verifier (development component)

`tool/sdk_package_inventory.py` implements read-only inventory and byte checking
for the proposed `sharehub-sdk-package-draft-1` format. It does not install a package
or modify `configure_media_sdk.ps1`. A passing result always includes
`installable: false`: source trust, extraction, full metadata/layout, API/ABI,
CPU/OS/runtime, signatures/licensing and native behavior require separate gates.
Do not interpret `inventoryVerified` as SDK availability or release qualification.

Use an already extracted, caller-owned staging tree and obtain the expected root
manifest hash from an independently trusted source. The verifier neither fetches
that source nor authenticates it. Supplying a hash calculated from an arbitrary
untrusted manifest is not source verification.

```sh
python3 tool/sdk_package_inventory.py /path/to/staging-package \
  --expected-manifest-sha256 <trusted-64-character-lowercase-sha256>
python3 -m unittest discover -s tool/tests -p 'test_sdk_package_inventory.py' -v
```

Python with POSIX descriptor-relative traversal is required; this implementation
is tested on macOS arm64. It explicitly returns `unsupported_verifier_host` on
Windows. Tests of manifests declaring a Windows target are path-policy tests on
Mac, not Windows filesystem or DLL validation. A Windows-safe traversal backend
and actual Junction/reparse tests remain required before installer integration.

The component checks:

- Exact root manifest bytes against the supplied digest; strict UTF-8 JSON,
  duplicate keys, known draft schema, `exampleOnly=false`, `inventoryComplete=true`.
- Bounded, sorted file inventory with explicit file/link type, canonical portable
  paths, role syntax and exact integer sizes/lowercase SHA-256 values. Booleans do
  not count as sizes. The root manifest cannot list itself.
- Every actual regular file/link is listed once; missing and extra files fail.
  Hardlinks and special files (including FIFOs) fail. Empty directories carry no
  payload but their names and identities are still checked during traversal.
- POSIX root/parent/file opens use no-follow directory descriptors, so listed
  paths do not traverse symlinked parents. Framework links are inspected as data,
  resolved against the known in-package node graph, and checked for missing,
  escaping, cyclic or non-directory intermediate targets. Windows-target
  inventories reject links outright.
- File sizes/digests and before/after inode, type, link-count, size, mtime/ctime
  stamps. A final rescan and root-identity check reject observed changes to files,
  manifests, tree membership or the root pathname during verification.

Manifest bytes are capped at 4 MiB, inventory entries at 65,536 and total scanned
nodes at 131,072. Portable paths are at most 1,024 characters/64 segments and reject
absolute/drive/UNC, dot segments, backslashes, reserved Windows names and alternate
stream syntax. The per-file declared limit is 16 GiB; hashing streams bounded
chunks instead of reading an entire native library into memory. Limits are tooling
limits, not media resolution or SDK runtime memory promises.

Error JSON returns a stable category and, where valid, a package-relative path.
It does not echo untrusted JSON, credentials, binary contents or internal absolute
paths. Success reports verified entry count/byte count and explicitly lists the
checks not performed. Known categories include manifest/file checksum mismatch,
missing/unlisted file, unsafe path/type, invalid identity, link errors, package
changed and unsupported host. I/O failures fail closed rather than skip an entry.

This is an observation of a controlled staging tree, not a filesystem lock or an
atomic install. The caller must keep staging private/unchanged through subsequent
validation and installation; arbitrary concurrent modification after the function
returns is outside its guarantee. The verifier does not extract ZIPs, audit the
contents of native code, follow release metadata, verify nested native-payload
compatibility, validate every manifest field or execute SDK/package hooks.

The [package proposal](../../packages/share_hub_media_api/native/draft/PACKAGING.md)
remains under review. Its checked-in examples are deliberately non-installable and
are rejected even before checking their placeholder files. Unit tests use synthetic
bytes and framework-shaped links, not signed executables or a working SDK.

[Declaration compatibility preflight](compatibility-preflight.md) now provides a
separate comparison of pinned manifest metadata with caller-owned build policy.
It does not extend this verifier's scope or turn inventory success into readiness.
