import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sdk_package_schema import SchemaError, check_manifest, validate_metadata, validator
from sdk_package_inventory import InventoryError

EXAMPLES = Path(__file__).resolve().parents[2] / 'packages/share_hub_media_api/native/draft/package-examples'


@unittest.skipUnless(importlib.util.find_spec('jsonschema'), 'install sdk_schema_requirements.txt for schema tests')
class SchemaTests(unittest.TestCase):
    def candidate(self, name='native-windows-x64.json'):
        value = json.loads((EXAMPLES / name).read_text())
        value['exampleOnly'] = False
        value['inventoryComplete'] = True
        value['target']['minimumOs'] = '13.0' if value['target']['os'] == 'macos' else '10.0'
        for entry in value['apiCompatibility']:
            entry['testedVersions'] = [entry['minInclusive']]
        for entry in value['files']:
            if entry['type'] == 'file':
                entry['sizeBytes'], entry['sha256'] = 0, '0' * 64
        for entry in value['publicSnapshots']:
            entry['publicRevision'], entry['sourceDigest'] = '1' * 40, '2' * 64
        if value['kind'] == 'flutter':
            value['nativePayload']['manifestSha256'] = '3' * 64
        return value

    def reject(self, value):
        with self.assertRaises((SchemaError, InventoryError)):
            validate_metadata(value)

    def test_six_examples_and_six_synthetic_candidate_shapes(self):
        for path in sorted(EXAMPLES.glob('native-*.json')) + sorted(EXAMPLES.glob('flutter-*.json')):
            with self.subTest(path=path.name):
                result = validate_metadata(json.loads(path.read_text()))
                self.assertTrue(result['exampleOnly'])
                self.assertFalse(result['installable'])
                result = validate_metadata(self.candidate(path.name))
                self.assertFalse(result['exampleOnly'])
                self.assertFalse(result['installable'])

    def test_flipping_example_flag_does_not_make_a_candidate(self):
        value = json.loads((EXAMPLES / 'flutter-macos-universal.json').read_text())
        value.update(exampleOnly=False, inventoryComplete=True)
        self.reject(value)

    def test_target_matrix_and_nested_payload_directory(self):
        for os_name, architectures in [('windows', ['arm64', 'x86_64']), ('macos', ['arm64']), ('macos', ['arm64', 'arm64']), ('linux', ['x86_64'])]:
            value = self.candidate()
            value['target'].update(os=os_name, architectures=architectures)
            self.reject(value)
        value = self.candidate('flutter-windows-x64.json')
        value['nativePayload']['directory'] = 'native/windows-arm64'
        self.reject(value)

    def test_api_identity_range_and_tested_versions(self):
        for change in ['duplicate', 'empty-range', 'outside']:
            value = self.candidate()
            first = value['apiCompatibility'][0]
            if change == 'duplicate':
                value['apiCompatibility'][1] = copy.deepcopy(first)
            elif change == 'empty-range':
                first['maxExclusive'] = first['minInclusive']
            else:
                first['testedVersions'] = [first['maxExclusive']]
            self.reject(value)

    def test_real_identity_cannot_use_null_placeholder(self):
        value = self.candidate('flutter-macos-universal.json')
        for change in ['file', 'minimum-os', 'snapshot', 'native']:
            broken = copy.deepcopy(value)
            if change == 'file':
                next(e for e in broken['files'] if e['type'] == 'file')['sha256'] = None
            elif change == 'minimum-os':
                broken['target']['minimumOs'] = None
            elif change == 'snapshot':
                broken['publicSnapshots'][0]['sourceDigest'] = None
            else:
                broken['nativePayload']['manifestSha256'] = None
            self.reject(broken)

    def test_snapshot_identity_and_declarations_remain_distinct(self):
        for change in ['duplicate', 'wrong-directory', 'untested-version']:
            value = self.candidate('flutter-windows-x64.json')
            if change == 'duplicate':
                value['publicSnapshots'][1] = copy.deepcopy(value['publicSnapshots'][0])
            elif change == 'wrong-directory':
                value['publicSnapshots'][0]['directory'] = 'public_api/other'
            else:
                value['publicSnapshots'][0]['version'] = '99.0.0'
            self.reject(value)

    def test_unknown_fields_and_version_lexical_forms(self):
        for location in ['root', 'abi', 'target', 'api']:
            value = self.candidate()
            node = value if location == 'root' else value['nativeAbi'] if location == 'abi' else value['target'] if location == 'target' else value['apiCompatibility'][0]
            node['allowUnverified'] = True
            self.reject(value)
        for text in ['01.0.0', '0.1.0-01', '0.1.0\n', '0.1.0 extra']:
            value = self.candidate()
            value['sdkVersion'] = text
            self.reject(value)

    def test_release_shape_requires_stable_abi_and_report_but_is_never_trust(self):
        value = self.candidate()
        value['channel'] = 'release'
        self.reject(value)  # Draft revision 2 cannot be relabelled as stable.
        value['nativeAbi'] = {'family': 'sharehub-media-c', 'stability': 'stable', 'major': 1, 'minor': 0, 'requiredFeatures': []}
        self.reject(value)  # Neither runtime inspection nor report is declared.
        value['target']['runtimeInspectionComplete'] = True
        value['signing'] = {'status': 'signed', 'reportPath': 'metadata/signature.json'}
        value['files'].append({'type': 'file', 'path': 'metadata/signature.json', 'role': 'signature-report', 'sizeBytes': 0, 'sha256': '4' * 64})
        value['files'].sort(key=lambda e: e['path'])
        result = validate_metadata(value)
        self.assertTrue(result['schemaValid'])
        self.assertFalse(result['installable'])  # All entries above are synthetic metadata.
        value['nativeAbi']['draftRevision'] = 2
        self.reject(value)

    def test_inventory_collision_reserved_path_and_unlisted_reference(self):
        for change in ['duplicate', 'reserved', 'self', 'reference', 'unsorted']:
            value = self.candidate()
            if change == 'duplicate':
                value['files'].insert(1, copy.deepcopy(value['files'][0]))
            elif change == 'reserved':
                value['files'][0]['path'] = 'bin/CON.dll'
            elif change == 'self':
                value['files'][0]['path'] = 'sdk-manifest.json'
            elif change == 'reference':
                value['validationFile'] = 'metadata/not-listed.json'
            else:
                value['files'].reverse()
            self.reject(value)

    def test_json_limits_duplicates_nonfinite_and_numeric_encoding(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'manifest.json'
            for raw in ['{"schema": "one", "schema": "two"}', '{"value": NaN}', '{"value": 2.0}', ' ' * (4 * 1024 * 1024 + 1)]:
                path.write_text(raw)
                with self.assertRaises((SchemaError, InventoryError)):
                    check_manifest(path)
        for value in [2.0, True]:
            candidate = self.candidate()
            candidate['nativeAbi']['draftRevision'] = value
            self.reject(candidate)

    def test_schema_uses_local_definitions_and_never_opens_payload(self):
        validator()  # Resolve the fixed meta-schema before the network guard.
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'sdk-manifest.json'
            path.write_text(json.dumps(self.candidate()))
            with patch('urllib.request.urlopen', side_effect=AssertionError('network forbidden')):
                result = check_manifest(path)
            self.assertTrue(result['schemaValid'])
            self.assertFalse(result['installable'])
            self.assertEqual(list(Path(directory).iterdir()), [path])


if __name__ == '__main__':
    unittest.main()
