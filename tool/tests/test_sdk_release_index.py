import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sdk_package_inventory import SCHEMA
from sdk_release_index import (INDEX_SCHEMA, TARGETS, ReleaseIndexError,
                               verify_release_index)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


class ReleaseIndexTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="sdk-index-tests-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.index_path = self.root / "release-index.json"
        self.index = {
            "schema": INDEX_SCHEMA, "exampleOnly": False,
            "sdkVersion": "0.1.0", "channel": "release", "matrixComplete": True,
            "intendedTargets": [
                {"os": os_name, "architectures": architectures}
                for os_name, architectures in TARGETS.values()
            ],
            "artifacts": [],
        }
        native_hashes = {}
        for target, (os_name, architectures) in TARGETS.items():
            native_hashes[target] = self.add_artifact("native", target,
                                                       os_name, architectures)
        for target, (os_name, architectures) in TARGETS.items():
            self.add_artifact("flutter", target, os_name, architectures,
                              native_hash=native_hashes[target])

    def add_artifact(self, kind, target, os_name, architectures, native_hash=None,
                     override=None):
        artifact_id = f"{kind}-{target}-synthetic"
        name = f"sharehub-media-{kind}-0.1.0-{target}.zip"
        payload = b"synthetic bytes; no native executable"
        manifest = {
            "schema": SCHEMA, "exampleOnly": False, "inventoryComplete": True,
            "artifactId": artifact_id, "kind": kind, "sdkVersion": "0.1.0",
            "channel": "release",
            "target": {"os": os_name, "architectures": architectures},
            "files": [{"type": "file", "path": "payload.bin", "role": "synthetic",
                       "sizeBytes": len(payload), "sha256": digest(payload)}],
        }
        if native_hash is not None:
            manifest["nativePayload"] = {
                "artifactId": f"native-{target}-synthetic",
                "directory": f"native/{target}",
                "manifestSha256": native_hash,
            }
        if override:
            override(manifest)
        raw = json.dumps(manifest, sort_keys=True).encode()
        archive_path = self.root / name
        with zipfile.ZipFile(archive_path, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("sdk/", b"")
            archive.writestr("sdk/sdk-manifest.json", raw)
            archive.writestr("sdk/payload.bin", payload)
        self.index["artifacts"].append({
            "artifactId": artifact_id, "kind": kind, "archiveName": name,
            "sizeBytes": archive_path.stat().st_size,
            "sha256": digest(archive_path.read_bytes()),
            "manifestSha256": digest(raw),
        })
        return digest(raw)

    def verify(self):
        raw = json.dumps(self.index, sort_keys=True).encode()
        self.index_path.write_bytes(raw)
        return verify_release_index(self.index_path, digest(raw), self.root)

    def rejects(self, code):
        with self.assertRaises(ReleaseIndexError) as context:
            self.verify()
        self.assertEqual(context.exception.code, code)

    def test_complete_pinned_matrix_is_only_a_byte_preflight(self):
        result = self.verify()
        self.assertEqual(result["artifacts"], 6)
        self.assertTrue(result["indexVerified"])
        self.assertFalse(result["installable"])
        self.assertIn("signatures/notarization", result["notValidated"])

    def test_example_and_incomplete_matrix_cannot_claim_release(self):
        self.index["exampleOnly"] = True
        self.rejects("incomplete_release_index")
        self.index["exampleOnly"] = False
        self.index["artifacts"].pop()
        self.rejects("incomplete_artifact_matrix")

    def test_target_and_archive_identity_must_match_index(self):
        self.index["intendedTargets"][0]["architectures"] = [{}]
        self.rejects("invalid_target_matrix")
        self.index["intendedTargets"][0]["architectures"] = ["x86_64"]
        self.index["artifacts"][0]["sizeBytes"] += 1
        self.rejects("archive_size_mismatch")

    def test_nested_native_identity_is_pinned_per_target(self):
        flutter = next(item for item in self.index["artifacts"]
                       if item["kind"] == "flutter" and "windows-x64" in item["archiveName"])
        self.index["artifacts"].remove(flutter)
        self.add_artifact("flutter", "windows-x64", "windows", ["x86_64"],
                          native_hash="0" * 64)
        self.rejects("native_pair_mismatch")

    def test_caller_pin_rejects_rewritten_index(self):
        raw = json.dumps(self.index, sort_keys=True).encode()
        self.index_path.write_bytes(raw)
        self.index["sdkVersion"] = "0.1.1"
        self.index_path.write_bytes(json.dumps(self.index, sort_keys=True).encode())
        with self.assertRaises(ReleaseIndexError) as context:
            verify_release_index(self.index_path, digest(raw), self.root)
        self.assertEqual(context.exception.code, "index_checksum_mismatch")


if __name__ == "__main__":
    unittest.main()
