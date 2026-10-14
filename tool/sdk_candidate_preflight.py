#!/usr/bin/env python3
"""Read-only candidate checks before development link configuration.

This consumes the existing review draft. It does not install, load binaries,
verify publisher trust, or approve release readiness.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sys

from sdk_package_compatibility import (CompatibilityError, check_compatibility,
                                       read_json, require)
from sdk_package_composition import CompositionError, verify_composition
from sdk_package_inventory import InventoryError
from sdk_package_schema import SchemaError, check_manifest


def scalar(path, name):
    text = path.read_text(encoding='utf-8')
    values = re.findall(r'^' + re.escape(name) + r':\s*([^\r\n#]+)', text, re.M)
    require(len(values) == 1, 'invalid_client_contract')
    return values[0].strip().strip("\"'")


def preflight(package, policy_path, project, target, digest):
    manifest_path = package / 'sdk-manifest.json'
    manifest = read_json(manifest_path, digest)
    policy = read_json(policy_path)
    compatibility = check_compatibility(manifest, policy)
    # The caller's policy cannot substitute different contracts for this host.
    require(policy['kind'] == 'flutter' and policy['target']['os'] == target,
            'consumer_target_differs_from_configuration')
    require(policy['productTarget'] == (project / 'VERSION').read_text().strip(),
            'consumer_product_differs_from_client')
    for name in ('share_hub_media_api', 'share_hub_session_api'):
        root = project / 'packages' / name
        require(scalar(root / 'pubspec.yaml', 'name') == name and
                scalar(root / 'pubspec.yaml', 'version') == policy['apiVersions'][name],
                'consumer_api_differs_from_client')
    boundary = project / 'packages/share_hub_media_api/native/draft/share_hub_media_boundary.h'
    revisions = re.findall(r'^#define SHM_DRAFT_REVISION UINT32_C\((\d+)\)',
                           boundary.read_text(), re.M)
    require(len(revisions) == 1 and policy['nativeAbi']['draftRevision'] == int(revisions[0]),
            'consumer_abi_differs_from_client')
    schema = check_manifest(manifest_path)
    if os.name != 'posix' or os.open not in os.supports_dir_fd or not hasattr(os, 'O_NOFOLLOW'):
        raise InventoryError('unsupported_verifier_host')
    composition = verify_composition(package, digest)
    native_schema = check_manifest(package / manifest['nativePayload']['directory'] / 'sdk-manifest.json')
    return {'ok': True, 'installable': False, 'schema': schema,
            'nativeSchema': native_schema,
            'compatibility': compatibility, 'composition': composition,
            'clientContractsMatched': True,
            'notVerified': ['publisher trust', 'binary runtime/architecture',
                            'signatures/licenses', 'native behavior', 'installation']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', type=Path)
    parser.add_argument('consumer_policy', type=Path)
    parser.add_argument('project', type=Path)
    parser.add_argument('--target', required=True, choices=['macos', 'windows'])
    parser.add_argument('--expected-manifest-sha256', required=True)
    args = parser.parse_args()
    try:
        result = preflight(args.package, args.consumer_policy, args.project,
                           args.target, args.expected_manifest_sha256)
    except (CompatibilityError, CompositionError, InventoryError, SchemaError) as error:
        print(json.dumps({'ok': False, 'installable': False, 'error': error.code}))
        return 1
    except (OSError, ValueError, UnicodeError):
        print(json.dumps({'ok': False, 'installable': False, 'error': 'invalid_preflight_input'}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == '__main__':
    sys.exit(main())
