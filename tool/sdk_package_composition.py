#!/usr/bin/env python3
"""Read-only identity check for a draft Flutter package's embedded native package.

The caller supplies the outer manifest digest from an independently trusted
source. This does not authenticate that source or make either package installable.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys

from sdk_package_inventory import (HASH, InventoryError, MANIFEST, manifest_bytes,
                                   open_at, parse_manifest, portable_path,
                                   unique_object, invalid_constant, verify_inventory)
from sdk_package_compatibility import (CompatibilityError, APIS, draft_abi,
                                       names, os_version, version)


class CompositionError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


ARTIFACT_ID = re.compile(r"[a-z0-9][a-z0-9.-]{0,127}\Z")
PUBLIC_APIS = {"share_hub_media_api", "share_hub_session_api"}


def _check_candidate_declarations(manifest, entries):
    """Validate the review-draft field shape after comparing nested identity.

    This validates claims, not the binary, source trust, signature or runtime.
    Stable/release schema is deliberately left for a separately reviewed ABI.
    """
    common = {"schema", "exampleOnly", "inventoryComplete", "artifactId",
              "kind", "sdkVersion", "productTarget", "channel", "target",
              "apiCompatibility", "nativeAbi", "capabilities", "signing",
              "licenseFiles", "validationFile", "publicSnapshots", "files"}
    expected = common | ({"nativePayload"} if manifest.get("kind") == "flutter" else set())
    if set(manifest) != expected or manifest.get("exampleOnly") is not False or \
            manifest.get("inventoryComplete") is not True or \
            manifest.get("channel") != "internal-candidate" or \
            not isinstance(manifest.get("artifactId"), str) or \
            not ARTIFACT_ID.fullmatch(manifest["artifactId"]):
        raise CompositionError("invalid_candidate_manifest")
    try:
        version(manifest["sdkVersion"])
        version(manifest["productTarget"])
        draft_abi(manifest["nativeAbi"])
        names(manifest["capabilities"], "invalid_capabilities")
    except (CompatibilityError, KeyError) as error:
        raise CompositionError("invalid_candidate_declarations") from error
    target = manifest["target"]
    if not isinstance(target, dict) or set(target) != {
            "os", "architectures", "minimumOs", "runtimeDependencies",
            "runtimeInspectionComplete"}:
        raise CompositionError("invalid_package_target")
    _native_directory(target)
    try:
        os_version(target["minimumOs"])
    except CompatibilityError as error:
        raise CompositionError("invalid_package_target") from error
    dependencies = target["runtimeDependencies"]
    if type(target["runtimeInspectionComplete"]) is not bool or \
            not isinstance(dependencies, list) or len(dependencies) > 64 or \
            any(not isinstance(item, str) or not item or len(item) > 512
                for item in dependencies) or len(set(dependencies)) != len(dependencies):
        raise CompositionError("invalid_runtime_declarations")
    api_entries = manifest["apiCompatibility"]
    if not isinstance(api_entries, list) or len(api_entries) != len(APIS):
        raise CompositionError("invalid_api_declarations")
    seen = set()
    for entry in api_entries:
        if not isinstance(entry, dict) or set(entry) != {
                "package", "minInclusive", "maxExclusive", "testedVersions"} or \
                not isinstance(entry["package"], str) or \
                entry["package"] not in APIS or entry["package"] in seen:
            raise CompositionError("invalid_api_declarations")
        seen.add(entry["package"])
        try:
            lower, upper = version(entry["minInclusive"]), version(entry["maxExclusive"])
            tested = entry["testedVersions"]
            if lower >= upper or not isinstance(tested, list) or len(tested) > 128 or \
                    len(set(tested)) != len(tested) or \
                    any(not lower <= version(item) < upper for item in tested):
                raise CompositionError("invalid_api_declarations")
        except (CompatibilityError, TypeError) as error:
            raise CompositionError("invalid_api_declarations") from error
    signing = manifest["signing"]
    if not isinstance(signing, dict) or set(signing) != {"status", "reportPath"} or \
            not isinstance(signing["status"], str) or \
            not 1 <= len(signing["status"]) <= 64 or \
            (signing["reportPath"] is not None and
             (not isinstance(signing["reportPath"], str) or
              entries.get(signing["reportPath"], {}).get("type") != "file")):
        raise CompositionError("invalid_signing_reference")


def _require_file(entries, path):
    if entries.get(path, {}).get("type") != "file":
        raise CompositionError("missing_package_component")


def _check_layout(outer, native, outer_files, native_files):
    """Reject incomplete bridge/native roots before anyone attempts installation."""
    shared = ("licenses/LICENSE.sdk.txt", "licenses/THIRD_PARTY_NOTICES.txt",
              "metadata/validation.json")
    for path in shared:
        _require_file(outer_files, path)
        _require_file(native_files, path)
    _require_file(native_files, "metadata/build.json")
    if not any(path.startswith("include/") and path.endswith(".h") and
               entry["type"] == "file" for path, entry in native_files.items()):
        raise CompositionError("missing_package_component")
    os_name = native["target"]["os"]
    binary_root = "bin/" if os_name == "windows" else "frameworks/"
    if not any(path.startswith(binary_root) and entry["type"] == "file"
               for path, entry in native_files.items()):
        raise CompositionError("missing_package_component")
    for path in ("pubspec.yaml", "lib/share_hub_media_sdk.dart"):
        _require_file(outer_files, path)
    if not any(path.startswith(os_name + "/") and entry["type"] == "file"
               for path, entry in outer_files.items()):
        raise CompositionError("missing_package_component")
    if native.get("publicSnapshots") != []:
        raise CompositionError("invalid_public_snapshots")
    snapshots = outer.get("publicSnapshots")
    if not isinstance(snapshots, list) or len(snapshots) != len(PUBLIC_APIS):
        raise CompositionError("invalid_public_snapshots")
    seen = set()
    for snapshot in snapshots:
        if not isinstance(snapshot, dict) or set(snapshot) != {
                "package", "version", "directory", "publicRevision", "sourceDigest"}:
            raise CompositionError("invalid_public_snapshots")
        name = snapshot["package"]
        if not isinstance(name, str) or name not in PUBLIC_APIS or name in seen or \
                snapshot["directory"] != f"public_api/{name}" or \
                not isinstance(snapshot["version"], str) or not snapshot["version"] or \
                not isinstance(snapshot["publicRevision"], str) or \
                not 1 <= len(snapshot["publicRevision"]) <= 128 or \
                not isinstance(snapshot["sourceDigest"], str) or \
                not HASH.fullmatch(snapshot["sourceDigest"]):
            raise CompositionError("invalid_public_snapshots")
        _require_file(outer_files, f"public_api/{name}/pubspec.yaml")
        seen.add(name)

    for manifest, entries in ((outer, outer_files), (native, native_files)):
        licenses = manifest.get("licenseFiles")
        if not isinstance(licenses, list) or len(licenses) < 2 or \
                any(not isinstance(path, str) or not path.startswith("licenses/")
                    for path in licenses) or len(licenses) != len(set(licenses)) or \
                not set(shared[:2]) <= set(licenses):
            raise CompositionError("invalid_package_references")
        for path in licenses:
            _require_file(entries, path)
        if manifest.get("validationFile") != "metadata/validation.json":
            raise CompositionError("invalid_package_references")


def _read_manifest(root_fd):
    raw = manifest_bytes(root_fd)
    try:
        manifest = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object,
                              parse_constant=invalid_constant)
    except (ValueError, UnicodeError, RecursionError) as error:
        raise InventoryError("invalid_manifest") from error
    files = parse_manifest(raw)
    return raw, manifest, files


def _native_directory(target):
    if not isinstance(target, dict):
        raise CompositionError("invalid_package_target")
    os_name, architectures = target.get("os"), target.get("architectures")
    if os_name == "macos" and isinstance(architectures, list) and \
            len(architectures) == 2 and all(isinstance(item, str) for item in architectures) and \
            set(architectures) == {"arm64", "x86_64"}:
        return "native/macos-universal"
    if os_name == "windows" and architectures == ["x86_64"]:
        return "native/windows-x64"
    if os_name == "windows" and architectures == ["arm64"]:
        return "native/windows-arm64"
    raise CompositionError("invalid_package_target")


def verify_composition(package_root, expected_manifest_sha256):
    """Verify exact nested identity and inventory, while withholding installability."""
    verify_inventory(package_root, expected_manifest_sha256)
    root_path = Path(package_root)
    try:
        root_fd = os.open(root_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            _, outer, outer_files = _read_manifest(root_fd)
            if outer.get("kind") != "flutter":
                raise CompositionError("wrong_package_kind")
            payload = outer.get("nativePayload")
            if not isinstance(payload, dict) or set(payload) != {
                    "artifactId", "directory", "manifestSha256"}:
                raise CompositionError("invalid_native_payload")
            directory = portable_path(payload["directory"])
            if directory != _native_directory(outer.get("target")) or \
                    not isinstance(payload["artifactId"], str) or \
                    not ARTIFACT_ID.fullmatch(payload["artifactId"]) or \
                    not isinstance(payload["manifestSha256"], str) or \
                    not HASH.fullmatch(payload["manifestSha256"]):
                raise CompositionError("invalid_native_payload")
            manifest_path = f"{directory}/{MANIFEST}"
            nested_entry = outer_files.get(manifest_path)
            if not nested_entry or nested_entry["type"] != "file" or \
                    nested_entry["sha256"] != payload["manifestSha256"]:
                raise CompositionError("nested_manifest_identity_mismatch")
            nested_fd = open_at(root_fd, directory)
            try:
                if not stat.S_ISDIR(os.fstat(nested_fd).st_mode):
                    raise CompositionError("invalid_native_payload")
                nested_raw, native, native_files = _read_manifest(nested_fd)
            finally:
                os.close(nested_fd)
        finally:
            os.close(root_fd)
    except OSError as error:
        raise CompositionError("invalid_native_payload") from error

    if hashlib.sha256(nested_raw).hexdigest() != payload["manifestSha256"] or \
            nested_entry["sizeBytes"] != len(nested_raw):
        raise CompositionError("nested_manifest_identity_mismatch")
    if native.get("kind") != "native" or native.get("artifactId") != payload["artifactId"] or \
            "nativePayload" in native:
        raise CompositionError("nested_artifact_mismatch")
    for field in ("sdkVersion", "productTarget", "channel", "target",
                  "apiCompatibility", "nativeAbi", "capabilities"):
        if outer.get(field) != native.get(field):
            raise CompositionError("nested_artifact_mismatch")

    prefix = directory + "/"
    outer_nested = {path[len(prefix):]: entry for path, entry in outer_files.items()
                    if path.startswith(prefix) and path != manifest_path}
    if set(outer_nested) != set(native_files):
        raise CompositionError("nested_inventory_mismatch")
    for path, entry in native_files.items():
        outer_entry = outer_nested[path]
        if {key: value for key, value in outer_entry.items() if key != "path"} != \
                {key: value for key, value in entry.items() if key != "path"}:
            raise CompositionError("nested_inventory_mismatch")

    _check_candidate_declarations(outer, outer_files)
    _check_candidate_declarations(native, native_files)
    _check_layout(outer, native, outer_files, native_files)

    # Verify the native tree independently, then ensure the outer tree still
    # matches the pinned identity. This is observation, not an atomic install.
    verify_inventory(root_path / directory, payload["manifestSha256"])
    verify_inventory(root_path, expected_manifest_sha256)
    return {"compositionVerified": True, "layoutVerified": True,
            "nestedManifestSha256": payload["manifestSha256"],
            "installable": False,
            "notValidated": ["source trust", "safe archive extraction", "final release manifest schema",
                             "API/ABI compatibility", "binary architecture/runtime",
                             "signatures/licenses", "native behavior", "installation"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package_root", type=Path)
    parser.add_argument("--expected-manifest-sha256", required=True)
    args = parser.parse_args()
    try:
        result = verify_composition(args.package_root, args.expected_manifest_sha256)
    except (InventoryError, CompositionError) as error:
        print(json.dumps({"error": error.code, "installable": False}))
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
