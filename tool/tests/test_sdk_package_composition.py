import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sdk_package_composition import CompositionError, verify_composition
from sdk_package_inventory import InventoryError, SCHEMA


@unittest.skipUnless(os.name == "posix", "nested verifier requires POSIX")
class CompositionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sdk-composition-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "SDK 中文 spaces"
        self.native_root = self.root / "native/windows-x64"
        (self.native_root / "bin").mkdir(parents=True)
        for directory in ("include", "licenses", "metadata", "frameworks"):
            (self.native_root / directory).mkdir()
        for directory in ("lib", "licenses", "metadata", "windows", "macos",
                          "public_api/share_hub_media_api",
                          "public_api/share_hub_session_api"):
            (self.root / directory).mkdir(parents=True)
        (self.native_root / "bin/core.dll").write_bytes(b"synthetic, not executable")
        (self.native_root / "frameworks/core").write_bytes(b"synthetic, not executable")
        (self.native_root / "include/share_hub_media.h").write_text("// fixture")
        (self.native_root / "metadata/build.json").write_text("{}")
        (self.root / "lib/share_hub_media_sdk.dart").write_text("// fixture")
        (self.root / "pubspec.yaml").write_text("name: share_hub_media_sdk\n")
        (self.root / "windows/CMakeLists.txt").write_text("# fixture")
        (self.root / "macos/Package.swift").write_text("// fixture")
        for name in ("share_hub_media_api", "share_hub_session_api"):
            (self.root / f"public_api/{name}/pubspec.yaml").write_text(f"name: {name}\n")
        for package in (self.root, self.native_root):
            (package / "licenses/LICENSE.sdk.txt").write_text("fixture license")
            (package / "licenses/THIRD_PARTY_NOTICES.txt").write_text("fixture notice")
            (package / "metadata/validation.json").write_text("{}")
        shared = {
            "schema": SCHEMA, "exampleOnly": False, "inventoryComplete": True,
            "sdkVersion": "0.1.0-candidate.1", "productTarget": "0.1.0",
            "channel": "internal-candidate",
            "target": {"os": "windows", "architectures": ["x86_64"]},
            "apiCompatibility": [], "nativeAbi": {"family": "sharehub-media-c",
                                               "stability": "draft", "draftRevision": 2},
            "capabilities": [],
            "licenseFiles": ["licenses/LICENSE.sdk.txt", "licenses/THIRD_PARTY_NOTICES.txt"],
            "validationFile": "metadata/validation.json",
        }
        self.native = dict(copy.deepcopy(shared), kind="native", artifactId="native-win-x64",
                           publicSnapshots=[])
        self.outer = dict(copy.deepcopy(shared), kind="flutter", artifactId="flutter-win-x64",
                          nativePayload={"artifactId": "native-win-x64",
                                         "directory": "native/windows-x64",
                                         "manifestSha256": ""},
                          publicSnapshots=[
                              {"package": name, "version": "0.1.0",
                               "directory": f"public_api/{name}",
                               "publicRevision": "fixture-revision",
                               "sourceDigest": "0" * 64}
                              for name in ("share_hub_media_api", "share_hub_session_api")])

    @staticmethod
    def inventory(root):
        entries = []
        for path in root.rglob("*"):
            if not path.is_file() or path == root / "sdk-manifest.json":
                continue
            data = path.read_bytes()
            entries.append({"type": "file", "path": path.relative_to(root).as_posix(),
                            "role": "fixture", "sizeBytes": len(data),
                            "sha256": hashlib.sha256(data).hexdigest()})
        return sorted(entries, key=lambda entry: entry["path"])

    def write(self):
        self.native["files"] = self.inventory(self.native_root)
        native_raw = json.dumps(self.native, sort_keys=True).encode()
        (self.native_root / "sdk-manifest.json").write_bytes(native_raw)
        self.outer["nativePayload"]["manifestSha256"] = hashlib.sha256(native_raw).hexdigest()
        return self.write_outer()

    def write_outer(self):
        self.outer["files"] = self.inventory(self.root)
        outer_raw = json.dumps(self.outer, sort_keys=True).encode()
        (self.root / "sdk-manifest.json").write_bytes(outer_raw)
        return hashlib.sha256(outer_raw).hexdigest()

    def rejects(self, code, digest=None):
        with self.assertRaises((CompositionError, InventoryError)) as raised:
            verify_composition(self.root, digest or self.write())
        self.assertEqual(raised.exception.code, code)

    def test_matching_payload_is_read_only_and_not_installable(self):
        digest = self.write()
        result = verify_composition(self.root, digest)
        self.assertTrue(result["compositionVerified"])
        self.assertTrue(result["layoutVerified"])
        self.assertFalse(result["installable"])
        self.assertEqual(result["nestedManifestSha256"], self.outer["nativePayload"]["manifestSha256"])
        self.assertIn("source trust", result["notValidated"])

    def test_macos_universal_and_windows_arm64_have_distinct_native_roots(self):
        for os_name, arches, label in (
            ("macos", ["arm64", "x86_64"], "macos-universal"),
            ("windows", ["arm64"], "windows-arm64"),
        ):
            with self.subTest(target=label):
                next_root = self.root / "native" / label
                self.native_root.rename(next_root)
                self.native_root = next_root
                for manifest in (self.native, self.outer):
                    manifest["target"] = {"os": os_name, "architectures": arches}
                self.outer["nativePayload"]["directory"] = f"native/{label}"
                self.assertTrue(verify_composition(self.root, self.write())["compositionVerified"])

    def test_nested_metadata_or_artifact_mismatch(self):
        self.native["sdkVersion"] = "0.1.0-candidate.2"
        self.rejects("nested_artifact_mismatch")
        self.native["sdkVersion"] = self.outer["sdkVersion"]
        self.outer["nativePayload"]["artifactId"] = "another-native"
        self.rejects("nested_artifact_mismatch")

    def test_wrong_nested_directory_and_kind(self):
        self.outer["nativePayload"]["directory"] = "native/other"
        self.rejects("invalid_native_payload")
        self.outer["nativePayload"]["directory"] = "native/windows-x64"
        self.outer["kind"] = "native"
        self.rejects("wrong_package_kind")

    def test_invalid_nested_artifact_identifier(self):
        self.outer["nativePayload"]["artifactId"] = "../../private"
        self.rejects("invalid_native_payload")

    def test_nested_manifest_digest_and_pinned_outer_digest(self):
        digest = self.write()
        self.native_root.joinpath("sdk-manifest.json").write_bytes(b"replaced")
        self.rejects("file_size_mismatch", digest)
        self.native_root.joinpath("sdk-manifest.json").write_bytes(
            json.dumps(self.native, sort_keys=True).encode())
        self.outer["nativePayload"]["manifestSha256"] = "0" * 64
        self.rejects("nested_manifest_identity_mismatch", self.write_outer())

    def test_outer_and_nested_inventories_must_agree(self):
        self.write()
        (self.native_root / "bin/extra.dll").write_bytes(b"extra")
        self.rejects("nested_inventory_mismatch", self.write_outer())
        (self.native_root / "bin/extra.dll").unlink()
        digest = self.write()
        data = self.native_root / "bin/core.dll"
        data.write_bytes(b"tampered")
        self.rejects("file_size_mismatch", digest)

    def test_nested_inventory_metadata_cannot_be_relabelled(self):
        self.write()
        self.outer["files"] = self.inventory(self.root)
        for entry in self.outer["files"]:
            if entry["path"] == "native/windows-x64/bin/core.dll":
                entry["role"] = "different-role"
                break
        raw = json.dumps(self.outer, sort_keys=True).encode()
        (self.root / "sdk-manifest.json").write_bytes(raw)
        self.rejects("nested_inventory_mismatch", hashlib.sha256(raw).hexdigest())

    def test_checked_in_examples_are_rejected(self):
        self.outer["exampleOnly"] = True
        self.rejects("non_installable_example")

    def test_complete_inventory_cannot_hide_missing_bridge_or_native_components(self):
        for path in (self.root / "pubspec.yaml",
                     self.root / "lib/share_hub_media_sdk.dart",
                     self.root / "windows/CMakeLists.txt",
                     self.root / "public_api/share_hub_media_api/pubspec.yaml",
                     self.root / "metadata/validation.json",
                     self.native_root / "include/share_hub_media.h",
                     self.native_root / "bin/core.dll",
                     self.native_root / "metadata/build.json"):
            with self.subTest(path=path):
                original = path.read_bytes()
                path.unlink()
                try:
                    self.rejects("missing_package_component")
                finally:
                    path.write_bytes(original)

    def test_macos_layout_requires_framework_and_platform_hook(self):
        self.native_root.rename(self.root / "native/macos-universal")
        self.native_root = self.root / "native/macos-universal"
        for manifest in (self.native, self.outer):
            manifest["target"] = {"os": "macos", "architectures": ["arm64", "x86_64"]}
        self.outer["nativePayload"]["directory"] = "native/macos-universal"
        for path in (self.native_root / "frameworks/core",
                     self.root / "macos/Package.swift"):
            with self.subTest(path=path):
                original = path.read_bytes()
                path.unlink()
                try:
                    self.rejects("missing_package_component")
                finally:
                    path.write_bytes(original)

    def test_snapshot_provenance_and_references_cannot_be_empty_claims(self):
        self.outer["publicSnapshots"][0]["sourceDigest"] = None
        self.rejects("invalid_public_snapshots")
        self.outer["publicSnapshots"][0]["sourceDigest"] = "0" * 64
        self.outer["publicSnapshots"][0]["directory"] = "public_api/other"
        self.rejects("invalid_public_snapshots")
        self.outer["publicSnapshots"][0]["directory"] = "public_api/share_hub_media_api"
        self.native["licenseFiles"] = []
        self.rejects("invalid_package_references")
        self.native["licenseFiles"] = ["licenses/LICENSE.sdk.txt",
                                       "licenses/THIRD_PARTY_NOTICES.txt"]
        self.outer["validationFile"] = "metadata/other.json"
        self.rejects("invalid_package_references")

    def test_cli_uses_trusted_outer_hash(self):
        digest = self.write()
        tool = Path(__file__).resolve().parents[1] / "sdk_package_composition.py"
        command = [sys.executable, str(tool), str(self.root),
                   "--expected-manifest-sha256", digest]
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        self.assertFalse(json.loads(result.stdout)["installable"])
        result = subprocess.run(command[:-1] + ["0" * 64], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)["error"], "manifest_checksum_mismatch")
        self.assertNotIn(str(self.root), result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
