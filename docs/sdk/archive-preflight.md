# SDK ZIP archive byte preflight (development component)

`tool/sdk_package_archive.py` checks a proposed SDK ZIP without extracting or
running it. The caller must supply the expected archive SHA-256 and root manifest
SHA-256 from an independently authenticated release index. Hashes copied from
the ZIP itself do not establish source trust.

```sh
python3 tool/sdk_package_archive.py /path/to/sdk.zip \
  --expected-archive-sha256 <trusted-archive-sha256> \
  --expected-manifest-sha256 <trusted-manifest-sha256>
python3 -m unittest discover -s tool/tests -p 'test_sdk_package_*.py'
```

The check requires one portable package root, a known non-example draft manifest,
and an exact match between ZIP entries and its complete file/link inventory. It
rejects traversal, duplicate or case-colliding paths, non-directory parents,
unexpected files, unsupported compression or entry types, and changed bytes.
Regular files are streamed and checked against their declared sizes and hashes;
Mac link entry bytes must match their declared target. The archive is never
extracted and a successful result always says `installable: false`.

This component does not verify publisher identity, safe extraction, link graph,
full package layout, API/ABI compatibility, actual binary architecture, signatures,
licenses or installation. Continue to use the separate extracted-tree inventory,
composition and compatibility preflights when those stages exist. The current
examples remain non-installable and no formal SDK artifact is available.
