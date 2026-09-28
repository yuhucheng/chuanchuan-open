#!/usr/bin/env python3
"""Extract a pinned draft SDK ZIP into a new, private verification directory.

The result is a staging tree, never an installed SDK. The caller supplies hashes
from an independently authenticated source and owns the staging parent.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import zipfile

from sdk_package_archive import _entry_type, verify_archive
from sdk_package_inventory import (
    InventoryError, MANIFEST, MAX_MANIFEST_BYTES, parse_manifest,
    verify_inventory,
)


def _digest_open_file(source):
    source.seek(0)
    digest = hashlib.sha256()
    while chunk := source.read(1024 * 1024):
        digest.update(chunk)
    source.seek(0)
    return digest.hexdigest()


def extract_to_staging(archive_path, staging_parent, expected_archive_sha256,
                       expected_manifest_sha256):
    if os.name != "posix" or not hasattr(os, "O_NOFOLLOW"):
        raise InventoryError("unsupported_extractor_host")
    archive_path, staging_parent = Path(archive_path), Path(staging_parent)
    preflight = verify_archive(archive_path, expected_archive_sha256,
                               expected_manifest_sha256)
    if staging_parent.is_symlink() or not staging_parent.is_dir():
        raise InventoryError("invalid_staging_parent")
    stage = None
    try:
        with archive_path.open("rb") as source:
            if _digest_open_file(source) != expected_archive_sha256:
                raise InventoryError("archive_changed")
            with zipfile.ZipFile(source) as archive:
                prefix = preflight["packageRoot"] + "/"
                infos = {}
                for info in archive.infolist():
                    if info.filename.startswith(prefix) and not info.is_dir():
                        name = info.filename[len(prefix):]
                        if name in infos:
                            raise InventoryError("path_collision", name)
                        infos[name] = info
                manifest_info = infos.get(MANIFEST)
                if manifest_info is None or manifest_info.file_size > MAX_MANIFEST_BYTES:
                    raise InventoryError("manifest_missing")
                manifest = archive.read(manifest_info)
                if hashlib.sha256(manifest).hexdigest() != expected_manifest_sha256:
                    raise InventoryError("manifest_checksum_mismatch")
                records = parse_manifest(manifest)
                if set(infos) != set(records) | {MANIFEST}:
                    raise InventoryError("archive_changed")

                stage = Path(tempfile.mkdtemp(prefix="sdk-verify-", dir=staging_parent))
                package = stage / preflight["packageRoot"]
                package.mkdir(mode=0o700)
                for name in sorted(infos):
                    if name != MANIFEST and records[name]["type"] == "symlink":
                        continue
                    info = infos[name]
                    if _entry_type(info) != "file":
                        raise InventoryError("archive_changed", name)
                    target = package / name
                    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                    mode = (info.external_attr >> 16) & 0o777
                    executable = bool(mode & 0o111)
                    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                                 os.O_NOFOLLOW, 0o600)
                    try:
                        digest, count = hashlib.sha256(), 0
                        with archive.open(info) as payload:
                            while chunk := payload.read(1024 * 1024):
                                count += len(chunk)
                                if name != MANIFEST and count > records[name]["sizeBytes"]:
                                    raise InventoryError("file_size_mismatch", name)
                                digest.update(chunk)
                                view = memoryview(chunk)
                                while view:
                                    view = view[os.write(fd, view):]
                        expected_size = len(manifest) if name == MANIFEST else records[name]["sizeBytes"]
                        expected_hash = expected_manifest_sha256 if name == MANIFEST else records[name]["sha256"]
                        if count != expected_size or digest.hexdigest() != expected_hash:
                            raise InventoryError("file_checksum_mismatch", name)
                        os.fchmod(fd, 0o755 if executable else 0o644)
                    finally:
                        os.close(fd)
                # Links are created last, so no archive link can become a parent
                # of a file write. The inventory verifier checks the entire graph.
                for name, record in sorted(records.items()):
                    if record["type"] == "symlink":
                        info = infos[name]
                        if _entry_type(info) != "symlink":
                            raise InventoryError("entry_type_mismatch", name)
                        target = package / name
                        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                        if archive.read(info).decode("utf-8") != record["target"]:
                            raise InventoryError("link_target_mismatch", name)
                        os.symlink(record["target"], target)
            if _digest_open_file(source) != expected_archive_sha256:
                raise InventoryError("archive_changed")
        inventory = verify_inventory(package, expected_manifest_sha256)
        return {"stagingRoot": str(stage), "packageRoot": str(package),
                "archiveVerified": True, "inventoryVerified": True,
                "installable": False,
                "notValidated": ["source trust", "runtime binary ABI", "signatures",
                                 "license review", "installation"],
                "inventory": inventory}
    except Exception:
        if stage is not None:
            shutil.rmtree(stage)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--staging-parent", type=Path, required=True)
    parser.add_argument("--expected-archive-sha256", required=True)
    parser.add_argument("--expected-manifest-sha256", required=True)
    args = parser.parse_args()
    try:
        result = extract_to_staging(args.archive, args.staging_parent,
                                    args.expected_archive_sha256,
                                    args.expected_manifest_sha256)
    except (InventoryError, OSError, zipfile.BadZipFile, UnicodeError) as error:
        code = error.code if isinstance(error, InventoryError) else "extraction_failed"
        print(json.dumps({"error": code, "installable": False}))
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
