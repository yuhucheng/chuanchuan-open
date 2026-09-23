#!/usr/bin/env python3
"""Read-only byte/inventory verifier for the draft SDK package format.

Run only on an extracted, caller-owned staging tree, with a manifest digest from
an independently trusted source. This component does NOT validate source trust,
API/ABI, signatures, executable architecture or installation readiness. POSIX
fd-relative traversal is required; Windows host traversal is not implemented.
"""
import argparse
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path

SCHEMA = "sharehub-sdk-package-draft-1"
MANIFEST = "sdk-manifest.json"
MAX_MANIFEST_BYTES = 4 * 1024 * 1024
MAX_ENTRIES = 65536
MAX_TREE_NODES = 131072
MAX_FILE_BYTES = 16 * 1024 * 1024 * 1024
HASH = re.compile(r"[0-9a-f]{64}\Z")
SEGMENT = re.compile(r"[A-Za-z0-9_.-]+\Z")
DEVICE = re.compile(r"(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?\Z", re.I)


class InventoryError(Exception):
    def __init__(self, code, path=None):
        self.code, self.path = code, path
        super().__init__(code + (f": {path}" if path else ""))


def portable_path(value):
    if not isinstance(value, str) or not value or len(value) > 1024:
        raise InventoryError("unsafe_path")
    parts = value.split("/")
    if len(parts) > 64 or any(
        not SEGMENT.fullmatch(p) or p in (".", "..") or p.endswith(".") or DEVICE.fullmatch(p)
        for p in parts
    ):
        raise InventoryError("unsafe_path")
    return value


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise InventoryError("duplicate_json_key")
        result[key] = value
    return result


def invalid_constant(_):
    raise InventoryError("invalid_manifest")


def stamp(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def checked_regular(fd):
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise InventoryError("unsafe_file_type")
    return info


def open_at(root, relative):
    """Never traverse a symlink/reparse-style alias in a file's parent path."""
    parts = portable_path(relative).split("/")
    directory = os.dup(root)
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        return os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    finally:
        os.close(directory)


def manifest_bytes(root):
    fd = open_at(root, MANIFEST)
    try:
        before = checked_regular(fd)
        if before.st_size > MAX_MANIFEST_BYTES:
            raise InventoryError("manifest_limit")
        chunks = []
        remaining = MAX_MANIFEST_BYTES + 1
        while remaining:
            chunk = os.read(fd, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b"".join(chunks)
        if len(raw) > MAX_MANIFEST_BYTES:
            raise InventoryError("manifest_limit")
        if stamp(before) != stamp(os.fstat(fd)):
            raise InventoryError("package_changed")
        return raw
    finally:
        os.close(fd)


def parse_manifest(raw):
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object,
                           parse_constant=invalid_constant)
    except (ValueError, UnicodeError, RecursionError) as error:
        raise InventoryError("invalid_manifest") from error
    if not isinstance(value, dict) or value.get("schema") != SCHEMA:
        raise InventoryError("unknown_manifest_schema")
    if value.get("exampleOnly") is not False:
        raise InventoryError("non_installable_example")
    if value.get("inventoryComplete") is not True:
        raise InventoryError("incomplete_inventory")
    target = value.get("target")
    if not isinstance(target, dict) or target.get("os") not in ("windows", "macos"):
        raise InventoryError("invalid_inventory_platform")
    entries = value.get("files")
    if not isinstance(entries, list) or not 1 <= len(entries) <= MAX_ENTRIES:
        raise InventoryError("inventory_limit")
    files, folded, previous = {}, set(), ""
    for entry in entries:
        if not isinstance(entry, dict):
            raise InventoryError("invalid_inventory_entry")
        path = portable_path(entry.get("path"))
        if path == MANIFEST:
            raise InventoryError("self_inventory_forbidden")
        if path in files or path.casefold() in folded:
            raise InventoryError("path_collision", path)
        if path < previous:
            raise InventoryError("unsorted_inventory")
        previous = path
        role = entry.get("role")
        if not isinstance(role, str) or not re.fullmatch(r"[a-z][a-z0-9-]{0,63}", role):
            raise InventoryError("invalid_inventory_role", path)
        common = {"type", "path", "role"}
        if entry.get("type") == "file":
            if set(entry) != common | {"sizeBytes", "sha256"}:
                raise InventoryError("invalid_inventory_entry", path)
            size, digest = entry["sizeBytes"], entry["sha256"]
            if type(size) is not int or not 0 <= size <= MAX_FILE_BYTES or not isinstance(digest, str) or not HASH.fullmatch(digest):
                raise InventoryError("invalid_file_identity", path)
        elif entry.get("type") == "symlink":
            if target["os"] != "macos":
                raise InventoryError("links_not_allowed", path)
            if set(entry) != common | {"target"}:
                raise InventoryError("invalid_inventory_entry", path)
            portable_path(entry["target"])
        else:
            raise InventoryError("unsafe_file_type", path)
        files[path] = entry
        folded.add(path.casefold())
    return files


def scan_tree(root):
    nodes, spellings = {}, {}

    def visit(directory, prefix):
        with os.scandir(directory) as iterator:
            for item in iterator:
                path = portable_path(prefix + item.name)
                if len(nodes) >= MAX_TREE_NODES:
                    raise InventoryError("tree_limit")
                folded = path.casefold()
                if folded in spellings and spellings[folded] != path:
                    raise InventoryError("path_collision", path)
                spellings[folded] = path
                info = os.stat(item.name, dir_fd=directory, follow_symlinks=False)
                if stat.S_ISDIR(info.st_mode):
                    child = os.open(item.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
                    try:
                        if stamp(os.fstat(child)) != stamp(info):
                            raise InventoryError("package_changed", path)
                        nodes[path] = ("directory", stamp(info), None)
                        visit(child, path + "/")
                    finally:
                        os.close(child)
                elif stat.S_ISLNK(info.st_mode):
                    target = os.readlink(item.name, dir_fd=directory)
                    portable_path(target)
                    nodes[path] = ("symlink", stamp(info), target)
                elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
                    nodes[path] = ("file", stamp(info), None)
                else:
                    raise InventoryError("unsafe_file_type", path)
    visit(root, "")
    return nodes


def resolve_link(path, nodes):
    """Resolve against inspected nodes only, never via filesystem realpath."""
    parts, seen = path.split("/"), set()
    for _ in range(65):
        expanded = False
        for index in range(len(parts)):
            name = "/".join(parts[:index + 1])
            node = nodes.get(name)
            if node is None:
                raise InventoryError("dangling_link", path)
            if node[0] == "symlink":
                if name in seen:
                    raise InventoryError("cyclic_link", path)
                seen.add(name)
                parts = parts[:index] + node[2].split("/") + parts[index + 1:]
                expanded = True
                break
            if index < len(parts) - 1 and node[0] != "directory":
                raise InventoryError("invalid_link_target", path)
        if not expanded:
            return "/".join(parts)
    raise InventoryError("link_depth_limit", path)


def verify_inventory(package_root, expected_manifest_sha256):
    if not isinstance(expected_manifest_sha256, str) or not HASH.fullmatch(expected_manifest_sha256):
        raise InventoryError("invalid_expected_manifest_hash")
    if (os.name != "posix" or os.open not in os.supports_dir_fd or
            not hasattr(os, "O_NOFOLLOW")):
        raise InventoryError("unsupported_verifier_host")
    root_path = Path(package_root)
    if root_path.is_symlink():
        raise InventoryError("redirected_package_root")
    try:
        root = os.open(root_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except FileNotFoundError as error:
        raise InventoryError("package_missing") from error
    except OSError as error:
        raise InventoryError("invalid_package_root") from error
    try:
        initial_root = stamp(os.fstat(root))
        raw = manifest_bytes(root)
        if hashlib.sha256(raw).hexdigest() != expected_manifest_sha256:
            raise InventoryError("manifest_checksum_mismatch")
        expected = parse_manifest(raw)
        nodes = scan_tree(root)
        actual = {path for path, node in nodes.items() if node[0] != "directory" and path != MANIFEST}
        missing, extra = set(expected) - actual, actual - set(expected)
        if missing:
            raise InventoryError("file_missing", sorted(missing)[0])
        if extra:
            raise InventoryError("unlisted_file", sorted(extra)[0])
        total = 0
        for path, entry in expected.items():
            kind, original_stamp, target = nodes[path]
            if kind != entry["type"]:
                raise InventoryError("entry_type_mismatch", path)
            if kind == "symlink":
                if target != entry["target"]:
                    raise InventoryError("link_target_mismatch", path)
                resolve_link(path, nodes)
                continue
            fd = open_at(root, path)
            try:
                before = checked_regular(fd)
                if stamp(before) != original_stamp:
                    raise InventoryError("package_changed", path)
                if before.st_size != entry["sizeBytes"]:
                    raise InventoryError("file_size_mismatch", path)
                digest = hashlib.sha256()
                count = 0
                while True:
                    chunk = os.read(fd, min(1024 * 1024, entry["sizeBytes"] - count + 1))
                    if not chunk:
                        break
                    count += len(chunk)
                    if count > entry["sizeBytes"]:
                        raise InventoryError("package_changed", path)
                    digest.update(chunk)
                if count != entry["sizeBytes"] or stamp(os.fstat(fd)) != stamp(before):
                    raise InventoryError("package_changed", path)
                if digest.hexdigest() != entry["sha256"]:
                    raise InventoryError("file_checksum_mismatch", path)
                total += count
            finally:
                os.close(fd)
        if (manifest_bytes(root) != raw or scan_tree(root) != nodes or
                stamp(os.fstat(root)) != initial_root or
                stamp(os.lstat(root_path)) != initial_root):
            raise InventoryError("package_changed")
        return {"inventoryVerified": True, "manifestSha256": expected_manifest_sha256,
                "entries": len(expected), "regularFileBytes": total,
                "installable": False,
                "scope": "Read-only draft file inventory and byte identity only.",
                "notValidated": ["source trust", "archive extraction", "full manifest schema",
                                 "package layout", "API/ABI compatibility", "CPU/OS/runtime",
                                 "signatures/licenses", "native behavior", "installation"]}
    except FileNotFoundError as error:
        raise InventoryError("file_missing") from error
    except OSError as error:
        raise InventoryError("inventory_io_error") from error
    finally:
        os.close(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package_root", type=Path)
    parser.add_argument("--expected-manifest-sha256", required=True)
    args = parser.parse_args()
    try:
        result = verify_inventory(args.package_root, args.expected_manifest_sha256)
    except InventoryError as error:
        print(json.dumps({"error": error.code, "path": error.path, "installable": False}))
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
