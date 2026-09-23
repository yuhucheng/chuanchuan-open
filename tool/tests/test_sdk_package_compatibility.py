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
from sdk_package_compatibility import (CONSUMER_SCHEMA, CompatibilityError,
                                       check_compatibility, os_version, read_json, version)
from sdk_package_inventory import SCHEMA


class CompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.manifest = {
            "schema": SCHEMA, "exampleOnly": False, "inventoryComplete": True,
            "kind": "flutter", "sdkVersion": "0.1.0-candidate.1", "productTarget": "0.1.0",
            "channel": "internal-candidate",
            "target": {"os": "macos", "architectures": ["arm64", "x86_64"],
                       "minimumOs": "13.0", "runtimeInspectionComplete": True,
                       "runtimeDependencies": []},
            "apiCompatibility": [
                {"package": "share_hub_media_api", "minInclusive": "0.7.0",
                 "maxExclusive": "0.8.0", "testedVersions": ["0.7.0"]},
                {"package": "share_hub_session_api", "minInclusive": "0.1.0",
                 "maxExclusive": "0.2.0", "testedVersions": ["0.1.0"]}],
            "nativeAbi": {"family": "sharehub-media-c", "stability": "draft",
                          "draftRevision": 2, "requiredFeatures": ["frame-leases"]},
            "capabilities": ["preview"],
        }
        self.consumer = {
            "schema": CONSUMER_SCHEMA, "kind": "flutter", "productTarget": "0.1.0",
            "target": {"os": "macos", "architecture": "arm64", "osVersion": "13.0.1"},
            "apiVersions": {"share_hub_media_api": "0.7.0", "share_hub_session_api": "0.1.0"},
            "nativeAbi": {"family": "sharehub-media-c", "stability": "draft",
                          "draftRevision": 2, "supportedFeatures": ["frame-leases"]},
            "requiredCapabilities": ["preview"], "allowInternalCandidate": True,
        }

    def check(self):
        return check_compatibility(self.manifest, self.consumer)

    def rejects(self, code):
        with self.assertRaises(CompatibilityError) as raised:
            self.check()
        self.assertEqual(raised.exception.code, code)

    def test_valid_declarations_are_not_installability_or_binary_proof(self):
        before = copy.deepcopy((self.manifest, self.consumer))
        result = self.check()
        self.assertTrue(result["declarationsCompatible"])
        self.assertFalse(result["installable"])
        self.assertEqual(result["untestedApiPackages"], [])
        self.assertIn("binary ABI/capabilities", result["notValidated"])
        self.assertIn("runtime dependencies", result["notValidated"])
        self.assertEqual(before, (self.manifest, self.consumer))

    def test_candidate_requires_explicit_boolean_policy(self):
        self.consumer["allowInternalCandidate"] = False
        self.rejects("candidate_not_enabled")
        for value in (1, "true", None):
            self.consumer["allowInternalCandidate"] = value
            self.rejects("invalid_consumer_policy")

    def test_examples_and_incomplete_inventory(self):
        self.manifest["exampleOnly"] = True
        self.rejects("non_installable_example")
        self.manifest["exampleOnly"] = False
        self.manifest["inventoryComplete"] = False
        self.rejects("incomplete_inventory")

    def test_checked_in_example_is_never_accepted(self):
        examples = Path(__file__).resolve().parents[2] / "packages/share_hub_media_api/native/draft/package-examples"
        for name in ("flutter-windows-x64.json", "native-windows-x64.json"):
            self.manifest = json.loads((examples / name).read_text())
            self.rejects("non_installable_example")

    def test_wrong_kind_is_distinct(self):
        self.manifest["kind"] = "native"
        self.rejects("wrong_package_kind")
        self.consumer["kind"] = "native"
        self.assertTrue(self.check()["declarationsCompatible"])

    def test_sdk_product_api_versions_are_separate(self):
        self.manifest["sdkVersion"] = "9.4.2-experiment.1+build.123"
        self.assertTrue(self.check()["declarationsCompatible"])
        self.manifest["productTarget"] = "0.2.0"
        self.rejects("incompatible_product")
        self.manifest["productTarget"] = "0.1.0"
        self.consumer["apiVersions"]["share_hub_session_api"] = "0.2.0"
        self.rejects("incompatible_public_api")

    def test_os_architecture_and_minimum_os(self):
        self.consumer["target"]["os"] = "windows"
        self.rejects("unsupported_os")
        self.manifest["target"].update(os="windows", architectures=["x86_64"], minimumOs="10.0.19041")
        self.rejects("unsupported_architecture")
        self.consumer["target"].update(architecture="x86_64", osVersion="10.0.19040")
        self.rejects("os_too_old")
        self.consumer["target"]["osVersion"] = "10.0.19041.0"
        self.assertTrue(self.check()["declarationsCompatible"])

    def test_package_architecture_matrix_is_not_inferred_from_label(self):
        for architectures in (["arm64"], ["arm64", "arm64"], ["universal"], [], None, [{"arch": "arm64"}]):
            with self.subTest(architectures=architectures):
                self.manifest["target"]["architectures"] = architectures
                self.rejects("invalid_package_architectures")
        self.manifest["target"].update(os="windows", architectures=["arm64", "x86_64"])
        self.consumer["target"]["os"] = "windows"
        self.rejects("invalid_package_architectures")

    def test_unknown_minimum_or_runtime_inspection_cannot_pass(self):
        for minimum in (None, "", "13", "013.0", "13.0-beta", 13, "13.0.0.0.1"):
            self.manifest["target"]["minimumOs"] = minimum
            self.rejects("invalid_os_version")
        self.manifest["target"]["minimumOs"] = "13.0"
        for inspected in (None, False, 1, "true"):
            self.manifest["target"]["runtimeInspectionComplete"] = inspected
            self.rejects("runtime_inspection_incomplete")
        self.manifest["target"]["runtimeInspectionComplete"] = True
        self.manifest["target"]["runtimeDependencies"] = None
        self.rejects("invalid_runtime_declarations")

    def test_api_inclusive_minimum_exclusive_maximum(self):
        for selected in ("0.6.99", "0.8.0", "1.0.0"):
            self.consumer["apiVersions"]["share_hub_media_api"] = selected
            self.rejects("incompatible_public_api")
        self.consumer["apiVersions"]["share_hub_media_api"] = "0.7.0"
        self.assertEqual(self.check()["untestedApiPackages"], [])
        self.consumer["apiVersions"]["share_hub_media_api"] = "0.7.1"
        self.assertEqual(self.check()["untestedApiPackages"], ["share_hub_media_api"])

    def test_api_names_are_required_once_no_overwrite(self):
        self.manifest["apiCompatibility"][1] = copy.deepcopy(self.manifest["apiCompatibility"][0])
        self.rejects("invalid_api_declarations")
        self.manifest["apiCompatibility"][1]["package"] = "unknown"
        self.rejects("invalid_api_declarations")
        self.manifest["apiCompatibility"] = []
        self.rejects("invalid_api_declarations")

    def test_bad_ranges_and_claimed_test_versions(self):
        entry = self.manifest["apiCompatibility"][0]
        entry["maxExclusive"] = "0.7.0"
        self.rejects("invalid_api_range")
        entry["maxExclusive"] = "0.8.0"
        for tested in (["0.8.0"], ["0.7.0", "0.7.0"], "0.7.0", None):
            entry["testedVersions"] = tested
            self.rejects("invalid_tested_versions")
        entry["testedVersions"] = [{}]
        self.rejects("invalid_version")

    def test_prerelease_needs_exact_tested_identity(self):
        self.consumer["apiVersions"]["share_hub_media_api"] = "0.8.0-rc.1+build.7"
        self.rejects("untested_prerelease_api")
        self.manifest["apiCompatibility"][0]["testedVersions"].append("0.8.0-rc.1+build.7")
        self.assertEqual(self.check()["untestedApiPackages"], [])
        self.consumer["apiVersions"]["share_hub_media_api"] = "0.8.0-rc.1+build.8"
        self.rejects("untested_prerelease_api")

    def test_build_metadata_does_not_change_range_but_changes_test_identity(self):
        self.consumer["apiVersions"]["share_hub_media_api"] = "0.7.0+rebuild.1"
        self.assertEqual(self.check()["untestedApiPackages"], ["share_hub_media_api"])
        self.manifest["apiCompatibility"][0]["testedVersions"].append("0.7.0+rebuild.1")
        self.assertEqual(self.check()["untestedApiPackages"], [])

    def test_abi_exact_revision_and_feature_direction(self):
        self.manifest["nativeAbi"]["draftRevision"] = 3
        self.rejects("incompatible_native_abi")
        self.manifest["nativeAbi"]["draftRevision"] = 2
        self.consumer["nativeAbi"]["supportedFeatures"] = []
        self.rejects("unsupported_abi_feature")
        self.consumer["nativeAbi"]["supportedFeatures"] = ["frame-leases", "other-feature"]
        self.assertTrue(self.check()["declarationsCompatible"])
        self.manifest["nativeAbi"]["draftRevision"] = True
        self.rejects("invalid_native_abi")

    def test_stable_abi_is_unsupported_until_real_negotiation_exists(self):
        self.manifest["nativeAbi"] = {"family": "sharehub-media-c", "stability": "stable",
                                      "major": 1, "minMinor": 0, "requiredFeatures": []}
        self.rejects("unsupported_native_abi")
        self.consumer["nativeAbi"] = copy.deepcopy(self.manifest["nativeAbi"])
        self.rejects("unsupported_native_abi")

    def test_draft_cannot_be_relabelled_as_release(self):
        self.manifest["channel"] = "release"
        self.rejects("prerelease_sdk_in_release")
        self.manifest["sdkVersion"] = "0.1.0"
        self.rejects("draft_abi_not_release")

    def test_preview_only_cannot_enable_remote_or_future_control(self):
        for capability in ("watch", "cast", "remote-control", "text-clipboard"):
            self.consumer["requiredCapabilities"] = ["preview", capability]
            self.rejects("unavailable_capability")
        self.manifest["capabilities"].append("cast")
        self.consumer["requiredCapabilities"] = ["preview", "cast"]
        self.assertTrue(self.check()["declarationsCompatible"])

    def test_capability_and_feature_duplicates_and_limits(self):
        for value in (["preview", "preview"], ["unsafe/value"], [None], "preview", ["a"] * 129):
            self.manifest["capabilities"] = value
            self.rejects("invalid_capabilities")
        self.manifest["capabilities"] = ["preview"]
        self.consumer["requiredCapabilities"] = ["preview", "preview"]
        self.rejects("invalid_required_capabilities")

    def test_unknown_schema_channel_and_consumer_fields(self):
        self.manifest["schema"] = "future"
        self.rejects("unknown_manifest_schema")
        self.manifest["schema"] = SCHEMA
        self.manifest["channel"] = "stable-ish"
        self.rejects("invalid_channel")
        self.manifest["channel"] = "internal-candidate"
        self.consumer["allowCandidate"] = True
        self.rejects("invalid_consumer_policy")

    def test_malformed_json_values_have_controlled_errors(self):
        # Every replaced field is fed from JSON, including unhashable arrays/objects.
        for original in (self.manifest, self.consumer):
            saved = copy.deepcopy(original)
            for key in saved:
                for invalid in (None, [], {}, True):
                    with self.subTest(side="manifest" if original is self.manifest else "consumer", key=key, value=invalid):
                        original[key] = invalid
                        try:
                            self.check()
                        except CompatibilityError:
                            pass
                        else:
                            # Original true flags and empty requirements remain valid.
                            self.assertTrue(invalid == saved[key] or
                                            (key, invalid) == ("requiredCapabilities", []))
                original[key] = saved[key]

    def test_semver_official_precedence_and_numeric_order(self):
        ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
                   "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.9.0", "1.10.0"]
        self.assertEqual(sorted(reversed(ordered), key=version), ordered)
        self.assertEqual(version("1.0.0+x.001"), version("1.0.0+other"))
        self.assertEqual(os_version("13.0"), os_version("13.0.0.0"))

    def test_invalid_semver_has_no_coercion(self):
        for value in (None, True, 1, {}, "1.0", "01.0.0", "1.0.0-01", "1.0.0+",
                      "v1.0.0", "1.0.0\n", "1.0.0-é", "1.0.0-..", "1.0.0+" + "a" * 128):
            with self.subTest(value=value), self.assertRaises(CompatibilityError):
                version(value)

    def test_cli_pins_manifest_and_returns_safe_diagnostics(self):
        with tempfile.TemporaryDirectory(prefix="compatibility 中文 ") as directory:
            manifest, consumer = Path(directory) / "manifest.json", Path(directory) / "consumer.json"
            raw = json.dumps(self.manifest).encode()
            manifest.write_bytes(raw)
            consumer.write_text(json.dumps(self.consumer))
            command = [sys.executable, str(Path(__file__).resolve().parents[1] / "sdk_package_compatibility.py"),
                       str(manifest), str(consumer), "--expected-manifest-sha256", hashlib.sha256(raw).hexdigest()]
            run = subprocess.run(command, text=True, capture_output=True, check=True)
            self.assertFalse(json.loads(run.stdout)["installable"])
            self.manifest["capabilities"].append("watch")
            manifest.write_text(json.dumps(self.manifest))
            run = subprocess.run(command, text=True, capture_output=True)
            self.assertEqual(run.returncode, 1)
            self.assertEqual(json.loads(run.stdout), {"error": "manifest_checksum_mismatch", "installable": False})
            self.assertNotIn(directory, run.stdout + run.stderr)

    def test_json_reader_rejects_duplicates_limits_and_non_regular_files(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "metadata.json"
            for raw in (b'{"schema":"x","schema":"y"}', b'{"x":NaN}', b'\xff'):
                path.write_bytes(raw)
                with self.assertRaises(CompatibilityError) as raised:
                    read_json(path)
                self.assertEqual(raised.exception.code, "invalid_metadata_json")
            path.write_bytes(b" " * (4 * 1024 * 1024 + 1))
            with self.assertRaises(CompatibilityError) as raised:
                read_json(path)
            self.assertEqual(raised.exception.code, "metadata_limit")
            if os.name == "posix":
                path.unlink()
                os.mkfifo(path)
                with self.assertRaises(CompatibilityError) as raised:
                    read_json(path)
                self.assertEqual(raised.exception.code, "invalid_metadata_file")


if __name__ == "__main__":
    unittest.main()
