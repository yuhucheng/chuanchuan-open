import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sdk_package_archive import verify_archive
from sdk_package_inventory import InventoryError, SCHEMA


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sdk-archive-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.archive = Path(self.temporary.name) / "sample.zip"
        self.payload = b"synthetic SDK bytes; not a binary"
        self.manifest = {
            "schema": SCHEMA, "exampleOnly": False, "inventoryComplete": True,
            "target": {"os": "windows"},
            "files": [{"type": "file", "path": "bin/core.dll", "role": "native",
                       "sizeBytes": len(self.payload),
                       "sha256": hashlib.sha256(self.payload).hexdigest()}],
        }

    def write(self, *, payload=None, extra=None):
        raw = json.dumps(self.manifest, sort_keys=True).encode()
        with zipfile.ZipFile(self.archive, "w", zipfile.ZIP_DEFLATED) as package:
            package.writestr("sdk/", b"")
            package.writestr("sdk/sdk-manifest.json", raw)
            package.writestr("sdk/bin/core.dll", self.payload if payload is None else payload)
            for name, data in extra or []:
                package.writestr(name, data)
        return hashlib.sha256(self.archive.read_bytes()).hexdigest(), hashlib.sha256(raw).hexdigest()

    def rejects(self, code, hashes):
        with self.assertRaises(InventoryError) as context:
            verify_archive(self.archive, *hashes)
        self.assertEqual(context.exception.code, code)

    def test_pinned_archive_and_manifest_are_read_only_and_non_installable(self):
        hashes = self.write()
        before = self.archive.read_bytes()
        result = verify_archive(self.archive, *hashes)
        self.assertTrue(result["archiveVerified"])
        self.assertFalse(result["installable"])
        self.assertEqual(result["entries"], 1)
        self.assertEqual(before, self.archive.read_bytes())
        self.assertEqual(list(Path(self.temporary.name).iterdir()), [self.archive])

    def test_independent_archive_pin_rejects_consistent_rewrite(self):
        hashes = self.write()
        self.write(payload=b"new payload")
        self.rejects("archive_checksum_mismatch", hashes)

    def test_manifest_pin_and_payload_hash_fail_separately(self):
        hashes = self.write()
        self.rejects("manifest_checksum_mismatch", (hashes[0], "0" * 64))
        hashes = self.write(payload=b"short")
        self.rejects("file_size_mismatch", hashes)
        hashes = self.write(payload=b"x" * len(self.payload))
        self.rejects("file_checksum_mismatch", hashes)

    def test_traversal_and_case_collisions_are_rejected(self):
        self.rejects("unsafe_path", self.write(extra=[("sdk/../escape", b"x")]))
        self.rejects("path_collision", self.write(extra=[("sdk/Bin/other", b"x")]))
        self.rejects("path_collision", self.write(extra=[("sdk/BIN/core.dll", b"x")]))

    def test_unlisted_and_non_directory_parent_are_rejected(self):
        self.rejects("unlisted_file", self.write(extra=[("sdk/other", b"x")]))
        self.rejects("unsafe_archive_entry", self.write(extra=[("sdk/bin/core.dll/child", b"x")]))

    def test_example_manifest_cannot_be_accepted(self):
        self.manifest["exampleOnly"] = True
        self.rejects("non_installable_example", self.write())


if __name__ == "__main__":
    unittest.main()
