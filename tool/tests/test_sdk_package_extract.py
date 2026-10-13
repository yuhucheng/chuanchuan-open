import hashlib
import json
from pathlib import Path
import stat
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
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

    def test_process_interrupt_cleans_only_its_stage_and_preserves_active_sdk(self):
        hashes = self.write(mac=True)
        old = self.base / "old-sdk"
        old.mkdir()
        (old / "keep").write_bytes(b"existing working SDK")
        active = self.base / "active-sdk"
        active.symlink_to(old, target_is_directory=True)
        sibling = self.parent / "previous-stage"
        sibling.mkdir()
        (sibling / "keep").write_bytes(b"another operation")
        marker = self.base / "validating"
        # Stop at the final inventory check: real manifest, regular files and
        # framework link have been extracted before the child receives SIGINT.
        driver = self.base / "interrupt.py"
        driver.write_text(
            "import sys, threading\nfrom pathlib import Path\n"
            f"sys.path.insert(0, {str(Path(__file__).resolve().parents[1])!r})\n"
            "import sdk_package_extract as extractor\n"
            "arguments = sys.argv[1:]\n"
            "def pause(root, digest):\n"
            "    assert (root / 'bin/core').is_file()\n"
            "    assert (root / 'bin/current').is_symlink()\n"
            "    Path(arguments[4]).write_text('ready')\n"
            "    threading.Event().wait(30)\n"
            "extractor.verify_inventory = pause\n"
            "sys.argv = ['sdk_package_extract.py', arguments[0], '--staging-parent', arguments[1],\n"
            "    '--expected-archive-sha256', arguments[2], '--expected-manifest-sha256', arguments[3]]\n"
            "sys.exit(extractor.main())\n"
        )
        child = subprocess.Popen(
            [sys.executable, str(driver), str(self.archive), str(self.parent),
             *hashes, str(marker)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            deadline = time.monotonic() + 10
            while not marker.exists() and child.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(marker.exists(), "child never reached extracted-tree validation")
            child.send_signal(signal.SIGINT)
            stdout, stderr = child.communicate(timeout=10)
            self.assertEqual(child.returncode, 130)
            self.assertEqual(stderr, b"")
            self.assertEqual(json.loads(stdout), {"error": "extraction_cancelled", "installable": False})
            self.assertEqual(list(self.parent.iterdir()), [sibling])
            self.assertEqual((sibling / "keep").read_bytes(), b"another operation")
            self.assertEqual(active.readlink(), old)
            self.assertEqual((active / "keep").read_bytes(), b"existing working SDK")
            self.assertEqual(hashlib.sha256(self.archive.read_bytes()).hexdigest(), hashes[0])
        finally:
            if child.poll() is None:
                child.kill()
            child.communicate(timeout=10)

    def test_base_exception_during_writes_removes_partial_stage(self):
        hashes = self.write()
        for interruption in (KeyboardInterrupt, SystemExit):
            with self.subTest(interruption=interruption.__name__):
                parent = self.parent / interruption.__name__
                parent.mkdir()
                with patch("sdk_package_extract.os.write", side_effect=interruption):
                    with self.assertRaises(interruption):
                        extract_to_staging(self.archive, parent, *hashes)
                self.assertEqual(list(parent.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
