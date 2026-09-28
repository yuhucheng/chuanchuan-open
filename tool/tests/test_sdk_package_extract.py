import hashlib
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sdk_package_extract import extract_to_staging
from sdk_package_inventory import InventoryError, SCHEMA


class ExtractTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sdk-extract-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.archive = self.base / "candidate.zip"
        self.parent = self.base / "staging"
        self.parent.mkdir()

    def write(self, *, mac=False, extra=None):
        payload = b"synthetic; no usable SDK"
        files = [{"type": "file", "path": "bin/core", "role": "native",
                  "sizeBytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}]
        if mac:
            files.append({"type": "symlink", "path": "bin/current", "role": "native",
                          "target": "core"})
        manifest = json.dumps({"schema": SCHEMA, "exampleOnly": False,
                               "inventoryComplete": True,
                               "target": {"os": "macos" if mac else "windows"},
                               "files": files}, sort_keys=True).encode()
        with zipfile.ZipFile(self.archive, "w") as bundle:
            bundle.writestr("sdk/", b"")
            bundle.writestr("sdk/sdk-manifest.json", manifest)
            bundle.writestr("sdk/bin/core", payload)
            if mac:
                link = zipfile.ZipInfo("sdk/bin/current")
                link.create_system = 3
                link.external_attr = (stat.S_IFLNK | 0o777) << 16
                bundle.writestr(link, b"core")
            for name, data in extra or []:
                bundle.writestr(name, data)
        return hashlib.sha256(self.archive.read_bytes()).hexdigest(), hashlib.sha256(manifest).hexdigest()

    def test_stage_verified_bytes_without_installing(self):
        hashes = self.write(mac=True)
        result = extract_to_staging(self.archive, self.parent, *hashes)
        root = Path(result["packageRoot"])
        self.assertTrue(result["inventoryVerified"])
        self.assertFalse(result["installable"])
        self.assertEqual((root / "bin/core").read_bytes(), b"synthetic; no usable SDK")
        self.assertEqual((root / "bin/current").readlink(), Path("core"))
        self.assertEqual(len(list(self.parent.iterdir())), 1)

    def test_bad_pin_or_traversal_leaves_parent_empty(self):
        hashes = self.write()
        with self.assertRaises(InventoryError):
            extract_to_staging(self.archive, self.parent, "0" * 64, hashes[1])
        self.assertEqual(list(self.parent.iterdir()), [])
        hashes = self.write(extra=[("sdk/../escape", b"x")])
        with self.assertRaises(InventoryError):
            extract_to_staging(self.archive, self.parent, *hashes)
        self.assertEqual(list(self.parent.iterdir()), [])
        self.assertFalse((self.base / "escape").exists())

    def test_symlinked_parent_rejected(self):
        hashes = self.write()
        alias = self.base / "alias"
        alias.symlink_to(self.parent, target_is_directory=True)
        with self.assertRaises(InventoryError) as caught:
            extract_to_staging(self.archive, alias, *hashes)
        self.assertEqual(caught.exception.code, "invalid_staging_parent")


if __name__ == "__main__":
    unittest.main()
