#!/usr/bin/env python3
"""Read-only identity check for a draft Flutter package's embedded native package.

The caller supplies the outer manifest digest from an independently trusted
source. This does not authenticate that source or make either package installable.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys

from sdk_package_inventory import (HASH, InventoryError, MANIFEST, manifest_bytes,
                                   open_at, parse_manifest, portable_path,
                                   unique_object, invalid_constant, verify_inventory)


class CompositionError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


ARTIFACT_ID = re.compile(r"[a-z0-9][a-z0-9.-]{0,127}\Z")


def _read_manifest(root_fd):
    raw = manifest_bytes(root_fd)
    try:
        manifest = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object,
                              parse_constant=invalid_constant)
    except (ValueError, UnicodeError, RecursionError) as error:
        raise InventoryError("invalid_manifest") from error
    files = parse_manifest(raw)
    return raw, manifest, files


def _native_directory(target):
    if not isinstance(target, dict):
        raise CompositionError("invalid_package_target")
    os_name, architectures = target.get("os"), target.get("architectures")
    if os_name == "macos" and isinstance(architectures, list) and \
            len(architectures) == 2 and all(isinstance(item, str) for item in architectures) and \
            set(architectures) == {"arm64", "x86_64"}:
        return "native/macos-universal"
    if os_name == "windows" and architectures == ["x86_64"]:
        return "native/windows-x64"
    if os_name == "windows" and architectures == ["arm64"]:
        return "native/windows-arm64"
    raise CompositionError("invalid_package_target")


def verify_composition(package_root, expected_manifest_sha256):
    """Verify exact nested identity and inventory, while withholding installability."""
    verify_inventory(package_root, expected_manifest_sha256)
    root_path = Path(package_root)
    try:
        root_fd = os.open(root_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            _, outer, outer_files = _read_manifest(root_fd)
            if outer.get("kind") != "flutter":
                raise CompositionError("wrong_package_kind")
            payload = outer.get("nativePayload")
            if not isinstance(payload, dict) or set(payload) != {
                    "artifactId", "directory", "manifestSha256"}:
                raise CompositionError("invalid_native_payload")
            directory = portable_path(payload["directory"])
            if directory != _native_directory(outer.get("target")) or \
                    not isinstance(payload["artifactId"], str) or \
                    not ARTIFACT_ID.fullmatch(payload["artifactId"]) or \
                    not isinstance(payload["manifestSha256"], str) or \
                    not HASH.fullmatch(payload["manifestSha256"]):
                raise CompositionError("invalid_native_payload")
            manifest_path = f"{directory}/{MANIFEST}"
            nested_entry = outer_files.get(manifest_path)
            if not nested_entry or nested_entry["type"] != "file" or \
                    nested_entry["sha256"] != payload["manifestSha256"]:
                raise CompositionError("nested_manifest_identity_mismatch")
            nested_fd = open_at(root_fd, directory)
            try:
                if not stat.S_ISDIR(os.fstat(nested_fd).st_mode):
                    raise CompositionError("invalid_native_payload")
                nested_raw, native, native_files = _read_manifest(nested_fd)
            finally:
                os.close(nested_fd)
        finally:
            os.close(root_fd)
    except OSError as error:
        raise CompositionError("invalid_native_payload") from error

    if hashlib.sha256(nested_raw).hexdigest() != payload["manifestSha256"] or \
            nested_entry["sizeBytes"] != len(nested_raw):
        raise CompositionError("nested_manifest_identity_mismatch")
    if native.get("kind") != "native" or native.get("artifactId") != payload["artifactId"] or \
            "nativePayload" in native:
        raise CompositionError("nested_artifact_mismatch")
    for field in ("sdkVersion", "productTarget", "channel", "target",
                  "apiCompatibility", "nativeAbi", "capabilities"):
        if outer.get(field) != native.get(field):
            raise CompositionError("nested_artifact_mismatch")

    prefix = directory + "/"
    outer_nested = {path[len(prefix):]: entry for path, entry in outer_files.items()
                    if path.startswith(prefix) and path != manifest_path}
    if set(outer_nested) != set(native_files):
        raise CompositionError("nested_inventory_mismatch")
    for path, entry in native_files.items():
        outer_entry = outer_nested[path]
        if {key: value for key, value in outer_entry.items() if key != "path"} != \
                {key: value for key, value in entry.items() if key != "path"}:
            raise CompositionError("nested_inventory_mismatch")

    # Verify the native tree independently, then ensure the outer tree still
    # matches the pinned identity. This is observation, not an atomic install.
    verify_inventory(root_path / directory, payload["manifestSha256"])
    verify_inventory(root_path, expected_manifest_sha256)
    return {"compositionVerified": True, "nestedManifestSha256": payload["manifestSha256"],
            "installable": False,
            "notValidated": ["source trust", "safe archive extraction", "full manifest schema",
                             "API/ABI compatibility", "binary architecture/runtime",
                             "signatures/licenses", "native behavior", "installation"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package_root", type=Path)
    parser.add_argument("--expected-manifest-sha256", required=True)
    args = parser.parse_args()
    try:
        result = verify_composition(args.package_root, args.expected_manifest_sha256)
    except (InventoryError, CompositionError) as error:
        print(json.dumps({"error": error.code, "installable": False}))
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
