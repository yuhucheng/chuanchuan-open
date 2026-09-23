#!/usr/bin/env python3
"""Compare pinned draft manifest declarations with an explicit consumer policy.

Read-only metadata preflight. Never loads an SDK or grants installation readiness.
The consumer policy belongs to the caller, not to the downloaded package.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys

from sdk_package_inventory import (HASH, MAX_MANIFEST_BYTES, SCHEMA,
                                   InventoryError, invalid_constant, unique_object)

CONSUMER_SCHEMA = "sharehub-sdk-consumer-draft-1"
APIS = {"share_hub_media_api", "share_hub_session_api"}
IDENTIFIER = re.compile(r"[a-z][a-z0-9-]{0,63}\Z")
SEMVER = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
                    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
                    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?\Z")


class CompatibilityError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def require(condition, code):
    if not condition:
        raise CompatibilityError(code)


def version(value):
    """SemVer 2 precedence key; build identity is intentionally not in this key."""
    match = SEMVER.fullmatch(value) if isinstance(value, str) and len(value) <= 128 else None
    require(match is not None, "invalid_version")
    major, minor, patch, prerelease, _ = match.groups()
    identifiers = []
    if prerelease is not None:
        for item in prerelease.split("."):
            numeric = item.isdigit()
            require(not numeric or item == "0" or not item.startswith("0"), "invalid_version")
            identifiers.append((0, int(item)) if numeric else (1, item))
    return (int(major), int(minor), int(patch), prerelease is None, tuple(identifiers))


def os_version(value):
    require(isinstance(value, str) and len(value) <= 43 and
            re.fullmatch(r"(?:0|[1-9][0-9]{0,9})(?:\.(?:0|[1-9][0-9]{0,9})){1,3}", value),
            "invalid_os_version")
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (4 - len(parts))


def names(value, code):
    require(isinstance(value, list) and len(value) <= 128, code)
    require(all(isinstance(item, str) and IDENTIFIER.fullmatch(item) for item in value), code)
    require(len(set(value)) == len(value), code)
    return set(value)


def fields(value, expected, code):
    require(isinstance(value, dict) and set(value) == set(expected.split()), code)


def draft_abi(value, consumer=False):
    require(isinstance(value, dict), "invalid_native_abi")
    require(value.get("family") == "sharehub-media-c", "unsupported_native_abi")
    require(value.get("stability") == "draft", "unsupported_native_abi")
    feature_key = "supportedFeatures" if consumer else "requiredFeatures"
    fields(value, "family stability draftRevision " + feature_key, "invalid_native_abi")
    revision = value["draftRevision"]
    require(type(revision) is int and 1 <= revision <= 0xffffffff, "invalid_native_abi")
    return revision, names(value[feature_key], "invalid_abi_features")


def check_compatibility(manifest, consumer):
    """Only declarations are compared. Neither dict is mutated; no filesystem I/O."""
    fields(consumer, "schema kind productTarget target apiVersions nativeAbi "
           "requiredCapabilities allowInternalCandidate", "invalid_consumer_policy")
    require(consumer["schema"] == CONSUMER_SCHEMA, "unknown_consumer_schema")
    require(consumer["kind"] in ("native", "flutter"), "invalid_consumer_policy")
    require(type(consumer["allowInternalCandidate"]) is bool, "invalid_consumer_policy")
    fields(consumer["target"], "os architecture osVersion", "invalid_consumer_target")
    host = consumer["target"]
    require(host["os"] in ("windows", "macos") and host["architecture"] in ("x86_64", "arm64"),
            "invalid_consumer_target")
    host_version = os_version(host["osVersion"])
    require(isinstance(consumer["apiVersions"], dict) and set(consumer["apiVersions"]) == APIS,
            "invalid_consumer_apis")
    selected = {name: version(value) for name, value in consumer["apiVersions"].items()}
    wanted_product = version(consumer["productTarget"])
    wanted_revision, supported_features = draft_abi(consumer["nativeAbi"], consumer=True)
    required_capabilities = names(consumer["requiredCapabilities"], "invalid_required_capabilities")

    require(isinstance(manifest, dict) and manifest.get("schema") == SCHEMA,
            "unknown_manifest_schema")
    require(manifest.get("exampleOnly") is False, "non_installable_example")
    require(manifest.get("inventoryComplete") is True, "incomplete_inventory")
    require(manifest.get("kind") in ("native", "flutter"), "invalid_artifact_kind")
    require(manifest["kind"] == consumer["kind"], "wrong_package_kind")
    sdk_version = version(manifest.get("sdkVersion"))
    require(version(manifest.get("productTarget")) == wanted_product, "incompatible_product")
    require(manifest.get("channel") in ("internal-candidate", "release"), "invalid_channel")
    if manifest["channel"] == "internal-candidate":
        require(consumer["allowInternalCandidate"], "candidate_not_enabled")
    else:
        require(sdk_version[3], "prerelease_sdk_in_release")

    target = manifest.get("target")
    require(isinstance(target, dict) and target.get("os") in ("windows", "macos"),
            "invalid_package_target")
    require(target["os"] == host["os"], "unsupported_os")
    architectures = target.get("architectures")
    require(isinstance(architectures, list) and architectures and len(architectures) <= 2 and
            all(item in ("x86_64", "arm64") for item in architectures) and
            len(set(architectures)) == len(architectures), "invalid_package_architectures")
    # These are the package variants selected by the draft, not proof of binary slices.
    require((target["os"] == "windows" and len(architectures) == 1) or
            (target["os"] == "macos" and set(architectures) == {"arm64", "x86_64"}),
            "invalid_package_architectures")
    require(host["architecture"] in architectures, "unsupported_architecture")
    require(host_version >= os_version(target.get("minimumOs")), "os_too_old")
    require(target.get("runtimeInspectionComplete") is True, "runtime_inspection_incomplete")
    require(isinstance(target.get("runtimeDependencies"), list), "invalid_runtime_declarations")

    entries = manifest.get("apiCompatibility")
    require(isinstance(entries, list) and len(entries) == len(APIS), "invalid_api_declarations")
    declarations = {}
    for entry in entries:
        fields(entry, "package minInclusive maxExclusive testedVersions", "invalid_api_declarations")
        name = entry["package"]
        require(isinstance(name, str) and name in APIS and name not in declarations,
                "invalid_api_declarations")
        lower, upper = version(entry["minInclusive"]), version(entry["maxExclusive"])
        require(lower < upper, "invalid_api_range")
        tested = entry["testedVersions"]
        require(isinstance(tested, list) and len(tested) <= 128, "invalid_tested_versions")
        # Validate types before set membership; malformed JSON must be a diagnostic.
        tested_keys = [version(item) for item in tested]
        require(len(set(tested)) == len(tested) and all(lower <= item < upper for item in tested_keys),
                "invalid_tested_versions")
        declarations[name] = (lower, upper, tested)
    untested = []
    for name in sorted(APIS):
        lower, upper, tested = declarations[name]
        require(lower <= selected[name] < upper, "incompatible_public_api")
        exact_tested = consumer["apiVersions"][name] in tested
        # A prerelease must be explicitly tested, not admitted via a broad stable range.
        require(selected[name][3] or exact_tested, "untested_prerelease_api")
        if not exact_tested:
            untested.append(name)

    revision, required_features = draft_abi(manifest.get("nativeAbi"))
    require(manifest["channel"] == "internal-candidate", "draft_abi_not_release")
    require(revision == wanted_revision, "incompatible_native_abi")
    require(required_features <= supported_features, "unsupported_abi_feature")
    capabilities = names(manifest.get("capabilities"), "invalid_capabilities")
    require(required_capabilities <= capabilities, "unavailable_capability")
    return {"declarationsCompatible": True, "installable": False,
            "untestedApiPackages": untested,
            "notValidated": ["full manifest schema", "inventory/bytes", "nested native payload",
                             "source trust", "binary ABI/capabilities", "runtime dependencies",
                             "binary architecture/minimum OS",
                             "signatures/licenses", "native behavior", "installation"]}


def read_json(path, expected_digest=None):
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode), "invalid_metadata_file")
            require(info.st_size <= MAX_MANIFEST_BYTES, "metadata_limit")
            raw = stream.read(MAX_MANIFEST_BYTES + 1)
        require(len(raw) <= MAX_MANIFEST_BYTES, "metadata_limit")
        if expected_digest is not None:
            require(isinstance(expected_digest, str) and HASH.fullmatch(expected_digest),
                    "invalid_expected_manifest_hash")
            require(hashlib.sha256(raw).hexdigest() == expected_digest, "manifest_checksum_mismatch")
        return json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object,
                          parse_constant=invalid_constant)
    except OSError as error:
        raise CompatibilityError("metadata_io_error") from error
    except (ValueError, UnicodeError, RecursionError, InventoryError) as error:
        raise CompatibilityError("invalid_metadata_json") from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("consumer_policy", type=Path)
    parser.add_argument("--expected-manifest-sha256", required=True)
    args = parser.parse_args()
    try:
        manifest = read_json(args.manifest, args.expected_manifest_sha256)
        consumer = read_json(args.consumer_policy)
        result = check_compatibility(manifest, consumer)
    except CompatibilityError as error:
        print(json.dumps({"error": error.code, "installable": False}))
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
