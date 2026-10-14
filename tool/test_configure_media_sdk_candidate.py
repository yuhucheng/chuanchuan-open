#!/usr/bin/env python3
"""Exercise actual candidate preflight/link configuration without Flutter or SDK load.

Requires an authorized, already verified Mac candidate and schema Python.
Uses temporary host fixtures and never changes the supplied package.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from sdk_candidate_preflight import scalar

ROOT = Path(__file__).resolve().parents[1]


def run(candidate, digest, python, pwsh, os_version):
    with tempfile.TemporaryDirectory(prefix='sdk-candidate-config-') as name:
        temp = Path(name)
        project = temp / '客户端 空格'
        project.mkdir()
        for path in ['pubspec.yaml', 'VERSION', 'packages/share_hub_media_api/pubspec.yaml',
                     'packages/share_hub_session_api/pubspec.yaml',
                     'packages/share_hub_media_api/native/draft/share_hub_media_boundary.h']:
            destination = project / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / path, destination)
        policy = {'schema': 'sharehub-sdk-consumer-draft-1', 'kind': 'flutter',
                  'productTarget': (project / 'VERSION').read_text().strip(),
                  'target': {'os': 'macos', 'architecture': 'arm64', 'osVersion': os_version},
                  'apiVersions': {key: scalar(project / 'packages' / key / 'pubspec.yaml', 'version')
                                  for key in ['share_hub_media_api', 'share_hub_session_api']},
                  'nativeAbi': {'family': 'sharehub-media-c', 'stability': 'draft',
                                'draftRevision': 2, 'supportedFeatures': []},
                  'requiredCapabilities': ['preview', 'watch', 'cast'],
                  'allowInternalCandidate': True}
        policy_path = temp / 'consumer.json'
        policy_path.write_text(json.dumps(policy))
        command = [str(pwsh), '-NoProfile', '-NonInteractive', '-File',
                   str(ROOT / 'tool/configure_media_sdk.ps1'), '-ProjectPath', str(project),
                   '-SdkPath', str(candidate), '-TargetPlatform', 'macos', '-SkipPubGet',
                   '-CandidateManifestSha256', digest, '-CandidateConsumerPolicy', str(policy_path),
                   '-PythonCommand', str(python)]
        manifest_before = (project / 'pubspec.yaml').read_bytes()
        package_manifest_before = (candidate / 'sdk-manifest.json').read_bytes()
        link = project / '.local/media-sdk/package'
        cases = []

        def attempt(label, args, error=None):
            result = subprocess.run(args, capture_output=True, text=True)
            if error is None:
                assert result.returncode == 0, result.stdout + result.stderr
                assert 'inventory checked' in result.stdout
            else:
                assert result.returncode != 0 and error in result.stdout + result.stderr, result.stdout + result.stderr
            assert (project / 'pubspec.yaml').read_bytes() == manifest_before
            assert (candidate / 'sdk-manifest.json').read_bytes() == package_manifest_before
            if link.exists():
                assert link.resolve(strict=True) == candidate
            cases.append({'case': label, 'passed': True})

        wrong = list(command)
        wrong[wrong.index('-CandidateManifestSha256') + 1] = '0' * 64
        attempt('bad checksum before first link', wrong, 'manifest_checksum_mismatch')
        assert not (project / '.local').exists()
        attempt('actual candidate first configuration', command)
        attempt('actual candidate idempotent configuration', command)
        attempt('bad checksum preserves existing link', wrong, 'manifest_checksum_mismatch')

        api = project / 'packages/share_hub_media_api/pubspec.yaml'
        original = api.read_bytes()
        api.write_text(api.read_text().replace('version: 0.8.0', 'version: 0.7.0'))
        attempt('policy cannot relabel client API', command, 'consumer_api_differs_from_client')
        api.write_bytes(original)
        header = project / 'packages/share_hub_media_api/native/draft/share_hub_media_boundary.h'
        original = header.read_bytes()
        header.write_text(header.read_text().replace('SHM_DRAFT_REVISION UINT32_C(2)', 'SHM_DRAFT_REVISION UINT32_C(3)'))
        attempt('policy cannot relabel client native ABI', command, 'consumer_abi_differs_from_client')
        header.write_bytes(original)
        (project / 'VERSION').write_text('0.2.0\n')
        attempt('policy cannot relabel client product target', command, 'consumer_product_differs_from_client')

        # Independent copy: the inventory verifier deliberately rejects
        # multiply-linked regular files, including otherwise unchanged ones.
        damaged = temp / 'Damaged SDK'
        shutil.copytree(candidate, damaged, symlinks=True)
        entry = damaged / 'lib/share_hub_media_sdk.dart'
        body = entry.read_bytes()
        entry.write_bytes(bytes([body[0] ^ 1]) + body[1:])
        (project / 'VERSION').write_text(policy['productTarget'] + '\n')
        damaged_command = list(command)
        damaged_command[damaged_command.index('-SdkPath') + 1] = str(damaged)
        attempt('bad payload preserves existing link', damaged_command, 'file_checksum_mismatch')
        return {'cases': cases, 'appLaunched': False, 'flutterUsed': False,
                'sdkLoaded': False, 'installable': False,
                'scope': 'actual candidate bytes and configurator; synthetic client contract host'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--expected-manifest-sha256', required=True)
    parser.add_argument('--python', required=True, type=Path)
    parser.add_argument('--pwsh', required=True, type=Path)
    parser.add_argument('--os-version', required=True)
    args = parser.parse_args()
    print(json.dumps(run(args.candidate.resolve(strict=True), args.expected_manifest_sha256,
                         args.python.absolute(), args.pwsh.absolute(), args.os_version), indent=2))


if __name__ == '__main__':
    main()
