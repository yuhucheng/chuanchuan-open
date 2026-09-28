#!/usr/bin/env python3
"""Read-only ZIP byte preflight for a pinned draft SDK artifact.

The expected hashes must come from an independently authenticated release
identity. This does not extract, install, load or trust an SDK.
"""
import argparse
import hashlib
import json
from pathlib import Path
import stat
import sys
import zipfile

from sdk_package_inventory import (
    HASH, MANIFEST, MAX_ENTRIES, MAX_MANIFEST_BYTES, InventoryError,
    parse_manifest, portable_path,
)

MAX_ARCHIVE_BYTES = 8 * 1024 * 1024 * 1024
MAX_PAYLOAD_BYTES = 16 * 1024 * 1024 * 1024


def _digest_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _read_entry(archive, info, limit):
    chunks, count = [], 0
    with archive.open(info) as source:
        while chunk := source.read(min(65536, limit - count + 1)):
            count += len(chunk)
            if count > limit:
                raise InventoryError("archive_entry_limit")
            chunks.append(chunk)
    return b"".join(chunks)


def _entry_type(info):
    mode = (info.external_attr >> 16) & 0xffff
    if mode & (stat.S_ISUID | stat.S_ISGID):
        raise InventoryError("unsafe_archive_entry")
    kind = stat.S_IFMT(mode)
    if info.is_dir():
        if kind not in (0, stat.S_IFDIR) or info.file_size != 0:
            raise InventoryError("unsafe_archive_entry")
        return "directory"
    if kind == stat.S_IFLNK:
        return "symlink"
    if kind in (0, stat.S_IFREG):
        return "file"
    raise InventoryError("unsafe_archive_entry")


def verify_archive(path, expected_archive_sha256, expected_manifest_sha256):
    if not isinstance(expected_archive_sha256, str) or not HASH.fullmatch(expected_archive_sha256):
        raise InventoryError("invalid_expected_archive_hash")
    if not isinstance(expected_manifest_sha256, str) or not HASH.fullmatch(expected_manifest_sha256):
        raise InventoryError("invalid_expected_manifest_hash")
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise InventoryError("archive_missing_or_redirected")
    try:
        if path.stat().st_size > MAX_ARCHIVE_BYTES:
            raise InventoryError("archive_limit")
        if _digest_file(path) != expected_archive_sha256:
            raise InventoryError("archive_checksum_mismatch")
    except OSError as error:
        raise InventoryError("archive_io_error") from error
    try:
        with zipfile.ZipFile(path) as archive:
            infos = archive.infolist()
            if not infos or len(infos) > MAX_ENTRIES * 2:
                raise InventoryError("archive_entry_limit")
            root, entries, folded, root_seen = None, {}, set(), False
            for info in infos:
                if info.flag_bits & 1 or info.compress_type not in (
                    zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED,
                ):
                    raise InventoryError("unsupported_archive_entry")
                name = info.filename[:-1] if info.is_dir() else info.filename
                parts = name.split("/", 1)
                portable_path(parts[0])
                if root is None:
                    root = parts[0]
                if parts[0] != root:
                    raise InventoryError("multiple_package_roots")
                if len(parts) == 1:
                    if _entry_type(info) != "directory" or root_seen:
                        raise InventoryError("unsafe_archive_entry")
                    root_seen = True
                    continue
                relative = portable_path(parts[1])
                if relative.casefold() in folded:
                    raise InventoryError("path_collision", relative)
                folded.add(relative.casefold())
                entries[relative] = (info, _entry_type(info))
            prefixes = {}
            for name in entries:
                components = name.split("/")
                for index in range(1, len(components) + 1):
                    prefix = "/".join(components[:index])
                    folded_prefix = prefix.casefold()
                    if folded_prefix in prefixes and prefixes[folded_prefix] != prefix:
                        raise InventoryError("path_collision", name)
                    prefixes[folded_prefix] = prefix
                    if index < len(components):
                        if prefix in entries and entries[prefix][1] != "directory":
                            raise InventoryError("unsafe_archive_entry", name)
            manifest_item = entries.get(MANIFEST)
            if manifest_item is None or manifest_item[1] != "file":
                raise InventoryError("manifest_missing")
            raw = _read_entry(archive, manifest_item[0], MAX_MANIFEST_BYTES)
            if hashlib.sha256(raw).hexdigest() != expected_manifest_sha256:
                raise InventoryError("manifest_checksum_mismatch")
            expected = parse_manifest(raw)
            actual = {name for name, (_, kind) in entries.items() if kind != "directory"}
            file_parents = {
                "/".join(name.split("/")[:index])
                for name in actual for index in range(1, len(name.split("/")))
            }
            if actual != set(expected) | {MANIFEST}:
                missing = (set(expected) | {MANIFEST}) - actual
                extra = actual - set(expected) - {MANIFEST}
                raise InventoryError("file_missing" if missing else "unlisted_file",
                                     sorted(missing or extra)[0])
            total = 0
            for name, (info, kind) in entries.items():
                if kind == "directory":
                    if name not in file_parents:
                        raise InventoryError("unlisted_directory", name)
                    continue
                if name == MANIFEST:
                    continue
                record = expected[name]
                if kind != record["type"]:
                    raise InventoryError("entry_type_mismatch", name)
                if kind == "symlink":
                    if info.file_size > 1024 or _read_entry(archive, info, 1024).decode("utf-8") != record["target"]:
                        raise InventoryError("link_target_mismatch", name)
                else:
                    if info.file_size != record["sizeBytes"]:
                        raise InventoryError("file_size_mismatch", name)
                    total += info.file_size
                    if total > MAX_PAYLOAD_BYTES:
                        raise InventoryError("archive_payload_limit")
                    digest = hashlib.sha256()
                    count = 0
                    with archive.open(info) as source:
                        while chunk := source.read(1024 * 1024):
                            count += len(chunk)
                            if count > record["sizeBytes"]:
                                raise InventoryError("file_size_mismatch", name)
                            digest.update(chunk)
                    if count != record["sizeBytes"] or digest.hexdigest() != record["sha256"]:
                        raise InventoryError("file_checksum_mismatch", name)
        # Detect replacement or in-place mutation during the preflight.
        if _digest_file(path) != expected_archive_sha256:
            raise InventoryError("archive_changed")
    except (zipfile.BadZipFile, OSError, UnicodeError, ValueError) as error:
        raise InventoryError("invalid_archive") from error
    return {"archiveVerified": True, "archiveSha256": expected_archive_sha256,
            "manifestSha256": expected_manifest_sha256, "packageRoot": root,
            "entries": len(expected), "regularFileBytes": total,
            "installable": False,
            "notValidated": ["source trust", "safe extraction", "runtime binary ABI",
                             "signatures", "license review", "installation"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--expected-archive-sha256", required=True)
    parser.add_argument("--expected-manifest-sha256", required=True)
    args = parser.parse_args()
    try:
        result = verify_archive(args.archive, args.expected_archive_sha256,
                                args.expected_manifest_sha256)
    except InventoryError as error:
        print(json.dumps({"error": error.code, "path": error.path,
                          "installable": False}))
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
