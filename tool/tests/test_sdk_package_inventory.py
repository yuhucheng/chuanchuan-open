import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sdk_package_inventory import InventoryError, MANIFEST, SCHEMA, verify_inventory


@unittest.skipUnless(os.name == "posix", "fd-relative verifier requires POSIX")
class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="inventory-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.container = Path(self.temporary.name)
        self.root = self.container / "SDK 中文 spaces"
        self.root.mkdir()
        (self.root / "bin").mkdir()
        (self.root / "bin/core.dll").write_bytes(b"synthetic inventory bytes; not a DLL")
        self.data = {"schema": SCHEMA, "exampleOnly": False, "inventoryComplete": True,
                     "target": {"os": "windows"}, "files": []}
        self.enumerate()

    def enumerate(self):
        entries = []
        for directory, dirs, files in os.walk(self.root, followlinks=False):
            for name in [*dirs, *files]:
                path = Path(directory) / name
                relative = path.relative_to(self.root).as_posix()
                if relative == MANIFEST:
                    continue
                if path.is_symlink():
                    entries.append({"type": "symlink", "path": relative, "role": "test-data",
                                    "target": os.readlink(path)})
                elif path.is_file():
                    raw = path.read_bytes()
                    entries.append({"type": "file", "path": relative, "role": "test-data",
                                    "sizeBytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()})
        self.data["files"] = sorted(entries, key=lambda item: item["path"])

    def write_manifest(self, raw=None):
        if raw is None:
            raw = json.dumps(self.data).encode()
        (self.root / MANIFEST).write_bytes(raw)
        return hashlib.sha256(raw).hexdigest()

    def verify(self):
        return verify_inventory(self.root, self.write_manifest())

    def rejects(self, code, digest=None):
        with self.assertRaises(InventoryError) as raised:
            verify_inventory(self.root, digest or self.write_manifest())
        self.assertEqual(raised.exception.code, code)

    def test_valid_bytes_do_not_claim_installability_or_mutate_tree(self):
        digest = self.write_manifest()
        before = {p.relative_to(self.root).as_posix(): p.read_bytes()
                  for p in self.root.rglob("*") if p.is_file()}
        result = verify_inventory(self.root, digest)
        self.assertTrue(result["inventoryVerified"])
        self.assertFalse(result["installable"])
        self.assertIn("API/ABI compatibility", result["notValidated"])
        after = {p.relative_to(self.root).as_posix(): p.read_bytes()
                 for p in self.root.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_external_digest_rejects_self_consistent_rewrite(self):
        digest = self.write_manifest()
        (self.root / "bin/core.dll").write_bytes(b"rewritten bytes")
        self.enumerate()
        self.write_manifest()
        self.rejects("manifest_checksum_mismatch", digest)

    def test_bad_same_size_hash(self):
        digest = self.write_manifest()
        payload = self.root / "bin/core.dll"
        payload.write_bytes(b"x" * payload.stat().st_size)
        self.rejects("file_checksum_mismatch", digest)

    def test_bad_size(self):
        digest = self.write_manifest()
        (self.root / "bin/core.dll").write_bytes(b"short")
        self.rejects("file_size_mismatch", digest)

    def test_missing_and_extra(self):
        digest = self.write_manifest()
        (self.root / "unlisted.txt").write_text("extra")
        self.rejects("unlisted_file", digest)
        (self.root / "unlisted.txt").unlink()
        (self.root / "bin/core.dll").unlink()
        self.rejects("file_missing", digest)

    def test_example_and_incomplete(self):
        self.data["exampleOnly"] = True
        self.rejects("non_installable_example")
        self.data["exampleOnly"] = False
        self.data["inventoryComplete"] = False
        self.rejects("incomplete_inventory")

    def test_public_example_rejected(self):
        example = Path(__file__).resolve().parents[2] / "packages/share_hub_media_api/native/draft/package-examples/native-windows-x64.json"
        self.rejects("non_installable_example", self.write_manifest(example.read_bytes()))

    def test_strict_json_and_schema(self):
        self.rejects("duplicate_json_key", self.write_manifest(b'{"schema":"x","schema":"y"}'))
        self.rejects("invalid_manifest", self.write_manifest(b'{"number":NaN}'))
        self.rejects("invalid_manifest", self.write_manifest(b'\xff'))
        self.data["schema"] = "future-schema"
        self.rejects("unknown_manifest_schema")

    def test_manifest_bounds(self):
        self.rejects("manifest_limit", self.write_manifest(b" " * (4 * 1024 * 1024 + 1)))
        self.data["files"] = []
        self.rejects("inventory_limit")

    def test_unsafe_paths(self):
        for path in ("../outside", "/absolute", "C:/drive", "a\\b", "a//b", "a/./b",
                     "bin/CON.dll", "bin/com1", "bin/LPT9.txt", "bin/trailing.",
                     "bin/trailing ", "bin/unicode-é", "bin/name:stream", "bin/\x00name"):
            with self.subTest(path=path):
                self.data["files"][0]["path"] = path
                self.rejects("unsafe_path")

    def test_file_identity_types_and_unknown_fields(self):
        entry = self.data["files"][0]
        original = dict(entry)
        for bad in (True, -1, 1.5, None, 16 * 1024**3 + 1):
            with self.subTest(size=bad):
                entry["sizeBytes"] = bad
                self.rejects("invalid_file_identity")
        entry.update(original)
        entry["sha256"] = "G" * 64
        self.rejects("invalid_file_identity")
        entry.update(original)
        entry["optionalSkip"] = True
        self.rejects("invalid_inventory_entry")

    def test_duplicate_case_and_order(self):
        self.data["files"].append(dict(self.data["files"][0]))
        self.rejects("path_collision")
        self.data["files"][1]["path"] = "BIN/CORE.DLL"
        self.rejects("path_collision")
        self.data["files"][1]["path"] = "a.txt"
        self.rejects("unsorted_inventory")

    def test_no_self_inventory(self):
        self.data["files"][0]["path"] = MANIFEST
        self.rejects("self_inventory_forbidden")

    def test_hardlink_and_special_file(self):
        digest = self.write_manifest()
        os.link(self.root / "bin/core.dll", self.container / "external-hardlink")
        self.rejects("unsafe_file_type", digest)
        (self.container / "external-hardlink").unlink()
        os.mkfifo(self.root / "pipe")
        self.rejects("unsafe_file_type", digest)

    def test_windows_links_rejected(self):
        (self.root / "link").symlink_to("bin/core.dll")
        self.enumerate()
        self.rejects("links_not_allowed")

    def test_macos_framework_links(self):
        self.data["target"]["os"] = "macos"
        framework = self.root / "Frameworks/Test.framework"
        version = framework / "Versions/A"
        (version / "Headers").mkdir(parents=True)
        (version / "Test").write_bytes(b"synthetic framework executable")
        (version / "Headers/Test.h").write_text("/* public fixture */")
        (framework / "Versions/Current").symlink_to("A")
        (framework / "Test").symlink_to("Versions/Current/Test")
        (framework / "Headers").symlink_to("Versions/Current/Headers")
        self.enumerate()
        self.assertTrue(self.verify()["inventoryVerified"])

    def test_escape_rejected_before_external_read(self):
        self.data["target"]["os"] = "macos"
        outside = self.container / "outside"
        outside.write_text("must not read")
        outside_inode = outside.stat().st_ino
        (self.root / "link").symlink_to("../outside")
        original_read = os.read
        def reading(fd, length):
            self.assertNotEqual(os.fstat(fd).st_ino, outside_inode)
            return original_read(fd, length)
        with patch("sdk_package_inventory.os.read", side_effect=reading):
            self.rejects("unsafe_path")

    def test_dangling_cycle_and_changed_target(self):
        self.data["target"]["os"] = "macos"
        link = self.root / "link"
        link.symlink_to("absent")
        self.enumerate()
        self.rejects("dangling_link")
        link.unlink()
        link.symlink_to("link")
        self.enumerate()
        self.rejects("cyclic_link")
        link.unlink()
        link.symlink_to("bin/core.dll")
        self.enumerate()
        self.data["files"][-1]["target"] = "different"
        self.rejects("link_target_mismatch")

    def test_declared_file_below_link_not_followed(self):
        self.data["target"]["os"] = "macos"
        (self.root / "alias").symlink_to("bin")
        self.enumerate()
        entry = dict(self.data["files"][-1], path="alias/core.dll")
        self.data["files"].append(entry)
        self.data["files"].sort(key=lambda x: x["path"])
        self.rejects("file_missing")

    def test_invalid_roots(self):
        digest = self.write_manifest()
        alias = self.container / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        for path, code in ((alias, "redirected_package_root"),
                           (self.root / "bin/core.dll", "invalid_package_root"),
                           (self.container / "missing", "package_missing")):
            with self.assertRaises(InventoryError) as raised:
                verify_inventory(path, digest)
            self.assertEqual(raised.exception.code, code)

    def test_change_during_hashing(self):
        digest = self.write_manifest()
        payload = self.root / "bin/core.dll"
        inode, original_read, changed = payload.stat().st_ino, os.read, False
        def reading(fd, length):
            nonlocal changed
            if os.fstat(fd).st_ino == inode and not changed:
                changed = True
                with payload.open("ab") as output:
                    output.write(b"changed")
            return original_read(fd, length)
        with patch("sdk_package_inventory.os.read", side_effect=reading):
            self.rejects("package_changed", digest)
        self.assertTrue(changed)

    def test_root_replacement_during_hashing(self):
        digest = self.write_manifest()
        inode = (self.root / "bin/core.dll").stat().st_ino
        original_read, replaced = os.read, False
        def reading(fd, length):
            nonlocal replaced
            if os.fstat(fd).st_ino == inode and not replaced:
                replaced = True
                self.root.rename(self.container / "old")
                self.root.mkdir()
                (self.root / "unexpected.txt").write_text("replacement root")
            return original_read(fd, length)
        with patch("sdk_package_inventory.os.read", side_effect=reading):
            self.rejects("package_changed", digest)
        self.assertTrue(replaced)

    def test_invalid_link_target_and_entry_type(self):
        self.data["target"]["os"] = "macos"
        link = self.root / "link"
        link.symlink_to("bin/core.dll/child")
        self.enumerate()
        self.rejects("invalid_link_target")
        digest = self.write_manifest()
        link.unlink()
        link.write_text("now a regular file")
        self.rejects("entry_type_mismatch", digest)

    def test_host_support_and_expected_digest(self):
        digest = self.write_manifest()
        with patch("sdk_package_inventory.os.name", "nt"):
            self.rejects("unsupported_verifier_host", digest)
        self.rejects("invalid_expected_manifest_hash", "not-a-hash")

    def test_cli_json_and_no_ready_claim(self):
        digest = self.write_manifest()
        tool = Path(__file__).resolve().parents[1] / "sdk_package_inventory.py"
        run = subprocess.run([sys.executable, str(tool), str(self.root),
                              "--expected-manifest-sha256", digest], text=True,
                             capture_output=True, check=True)
        self.assertFalse(json.loads(run.stdout)["installable"])
        run = subprocess.run([sys.executable, str(tool), str(self.root),
                              "--expected-manifest-sha256", "0" * 64], text=True, capture_output=True)
        self.assertEqual(run.returncode, 1)
        self.assertEqual(json.loads(run.stdout)["error"], "manifest_checksum_mismatch")


if __name__ == "__main__":
    unittest.main()
