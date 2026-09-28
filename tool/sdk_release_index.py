#!/usr/bin/env python3
"""Read-only byte and identity preflight for a complete SDK release matrix.

The index hash must be obtained independently from the chosen publisher channel.
Successful preflight never authorizes installation, loading or publication.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import zipfile

from sdk_package_archive import MAX_ARCHIVE_BYTES, verify_archive
from sdk_package_inventory import (HASH, MANIFEST, MAX_MANIFEST_BYTES,
                                   InventoryError, SCHEMA, invalid_constant,
                                   unique_object)

INDEX_SCHEMA = "sharehub-sdk-release-index-draft-1"
TARGETS = {
    "windows-x64": ("windows", ["x86_64"]),
    "windows-arm64": ("windows", ["arm64"]),
    "macos-universal": ("macos", ["arm64", "x86_64"]),
}
MAX_INDEX_BYTES = 1024 * 1024
MAX_ARTIFACT_ID = re.compile(r"[a-z0-9][a-z0-9.-]{0,127}\Z")


class ReleaseIndexError(Exception):
    def __init__(self, code, artifact=None):
        self.code, self.artifact = code, artifact
        super().__init__(code)


def _read_regular(path, limit, expected_hash=None):
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(fd, "rb") as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > limit:
                raise ReleaseIndexError("invalid_index_file")
            raw = source.read(limit + 1)
        if len(raw) != info.st_size:
            raise ReleaseIndexError("index_changed")
    except OSError as error:
        raise ReleaseIndexError("index_io_error") from error
    if expected_hash is not None and hashlib.sha256(raw).hexdigest() != expected_hash:
        raise ReleaseIndexError("index_checksum_mismatch")
    return raw


def _json(raw):
    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object,
                          parse_constant=invalid_constant)
    except (ValueError, UnicodeError, RecursionError, InventoryError) as error:
        raise ReleaseIndexError("invalid_index_json") from error


def _manifest_from_pinned_archive(archive_path, root, expected_hash):
    try:
        with zipfile.ZipFile(archive_path) as archive:
            raw = archive.read(f"{root}/{MANIFEST}")
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        raise ReleaseIndexError("manifest_read_failed") from error
    if len(raw) > MAX_MANIFEST_BYTES or hashlib.sha256(raw).hexdigest() != expected_hash:
        raise ReleaseIndexError("manifest_changed")
    return _json(raw)


def verify_release_index(index_path, expected_index_sha256, archives_directory):
    if not isinstance(expected_index_sha256, str) or not HASH.fullmatch(expected_index_sha256):
        raise ReleaseIndexError("invalid_expected_index_hash")
    raw = _read_regular(index_path, MAX_INDEX_BYTES, expected_index_sha256)
    index = _json(raw)
    expected_fields = {"schema", "exampleOnly", "sdkVersion", "channel",
                       "matrixComplete", "intendedTargets", "artifacts"}
    if not isinstance(index, dict) or set(index) != expected_fields or \
            index["schema"] != INDEX_SCHEMA:
        raise ReleaseIndexError("unknown_index_schema")
    if index["exampleOnly"] is not False or index["matrixComplete"] is not True or \
            index["channel"] != "release":
        raise ReleaseIndexError("incomplete_release_index")
    sdk_version = index["sdkVersion"]
    if not isinstance(sdk_version, str) or not re.fullmatch(
            r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", sdk_version):
        raise ReleaseIndexError("invalid_sdk_version")
    intended = index["intendedTargets"]
    if not isinstance(intended, list) or len(intended) != len(TARGETS) or \
            any(not isinstance(item, dict) or set(item) != {"os", "architectures"} or
                not isinstance(item["os"], str) or
                not isinstance(item["architectures"], list) or
                any(not isinstance(arch, str) for arch in item["architectures"])
                for item in intended) or \
            {(item["os"], tuple(item["architectures"])) for item in intended} != \
            {(os_name, tuple(arches)) for os_name, arches in TARGETS.values()}:
        raise ReleaseIndexError("invalid_target_matrix")
    artifacts = index["artifacts"]
    if not isinstance(artifacts, list) or len(artifacts) != 2 * len(TARGETS):
        raise ReleaseIndexError("incomplete_artifact_matrix")
    archive_root = Path(archives_directory)
    if archive_root.is_symlink() or not archive_root.is_dir():
        raise ReleaseIndexError("archive_directory_missing")

    seen_ids, seen_names, verified = set(), set(), {}
    for entry in artifacts:
        fields = {"artifactId", "kind", "archiveName", "sizeBytes",
                  "sha256", "manifestSha256"}
        if not isinstance(entry, dict) or set(entry) != fields or \
                not isinstance(entry["artifactId"], str) or \
                not MAX_ARTIFACT_ID.fullmatch(entry["artifactId"]):
            raise ReleaseIndexError("invalid_artifact_entry")
        artifact_id, kind, name = entry["artifactId"], entry["kind"], entry["archiveName"]
        if artifact_id in seen_ids:
            raise ReleaseIndexError("duplicate_artifact", artifact_id)
        seen_ids.add(artifact_id)
        if kind not in ("native", "flutter") or not isinstance(name, str) or \
                name in seen_names:
            raise ReleaseIndexError("invalid_artifact_name", artifact_id)
        seen_names.add(name)
        target = next((value for value in TARGETS if name ==
                       f"sharehub-media-{kind}-{sdk_version}-{value}.zip"), None)
        if target is None or (kind, target) in verified:
            raise ReleaseIndexError("invalid_artifact_name", artifact_id)
        size = entry["sizeBytes"]
        if type(size) is not int or not 0 < size <= MAX_ARCHIVE_BYTES or \
                not isinstance(entry["sha256"], str) or \
                not HASH.fullmatch(entry["sha256"]) or \
                not isinstance(entry["manifestSha256"], str) or \
                not HASH.fullmatch(entry["manifestSha256"]):
            raise ReleaseIndexError("missing_artifact_identity", artifact_id)
        path = archive_root / name
        try:
            if path.stat().st_size != size:
                raise ReleaseIndexError("archive_size_mismatch", artifact_id)
            result = verify_archive(path, entry["sha256"], entry["manifestSha256"])
        except OSError as error:
            raise ReleaseIndexError("archive_io_error", artifact_id) from error
        except InventoryError as error:
            raise ReleaseIndexError(error.code, artifact_id) from error
        manifest = _manifest_from_pinned_archive(path, result["packageRoot"],
                                                 entry["manifestSha256"])
        manifest_target = manifest.get("target") if isinstance(manifest, dict) else None
        if not isinstance(manifest, dict) or not isinstance(manifest_target, dict) or \
                manifest.get("schema") != SCHEMA or \
                manifest.get("exampleOnly") is not False or \
                manifest.get("inventoryComplete") is not True or \
                manifest.get("channel") != "release" or \
                manifest.get("artifactId") != artifact_id or \
                manifest.get("kind") != kind or \
                manifest.get("sdkVersion") != sdk_version or \
                manifest_target.get("os") != TARGETS[target][0] or \
                manifest_target.get("architectures") != TARGETS[target][1]:
            raise ReleaseIndexError("artifact_manifest_mismatch", artifact_id)
        verified[(kind, target)] = (entry, manifest)
    if len(verified) != 2 * len(TARGETS):
        raise ReleaseIndexError("incomplete_artifact_matrix")
    for target in TARGETS:
        native, _ = verified[("native", target)]
        _, flutter_manifest = verified[("flutter", target)]
        if flutter_manifest.get("nativePayload") != {
                "artifactId": native["artifactId"],
                "directory": f"native/{target}",
                "manifestSha256": native["manifestSha256"]}:
            raise ReleaseIndexError("native_pair_mismatch", target)
    # The index is a complete byte/identity matrix, not a release acceptance.
    return {"indexVerified": True, "indexSha256": expected_index_sha256,
            "sdkVersion": sdk_version, "artifacts": len(verified),
            "installable": False,
            "notValidated": ["publisher/source trust", "full manifest schema",
                             "nested native composition", "public API/ABI compatibility",
                             "binary architecture/runtime", "signatures/notarization",
                             "licenses", "native behavior", "installation"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("index", type=Path)
    parser.add_argument("--expected-index-sha256", required=True)
    parser.add_argument("--archives-directory", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = verify_release_index(args.index, args.expected_index_sha256,
                                      args.archives_directory)
    except ReleaseIndexError as error:
        print(json.dumps({"error": error.code, "artifact": error.artifact,
                          "installable": False}))
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
