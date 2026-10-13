#!/usr/bin/env python3
"""Check the SDK manifest review schema, never package/ABI trust or installation.

Requires the development dependencies in sdk_schema_requirements.txt. This tool
reads one bounded JSON document plus the fixed public schema; it does not open
referenced files, fetch schemas, execute package hooks or change SDK configuration.
"""
import argparse
from functools import lru_cache
import hashlib
import json
import os
from pathlib import Path
import sys

from sdk_package_compatibility import APIS, CompatibilityError, version
from sdk_package_inventory import (MANIFEST, MAX_MANIFEST_BYTES, InventoryError,
                                   checked_regular, invalid_constant,
                                   portable_path, stamp, unique_object)

SCHEMA_PATH = Path(__file__).resolve().parents[1] / 'packages/share_hub_media_api/native/draft/sdk-package.schema.json'


class SchemaError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


@lru_cache(maxsize=1)
def validator():
    try:
        from jsonschema import Draft202012Validator
    except ImportError as error:
        raise SchemaError('schema_dependency_missing') from error
    schema = json.loads(SCHEMA_PATH.read_text(encoding='utf-8'))
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema)


def no_float(_):
    # No manifest field is floating-point. JSON Schema's mathematical integer
    # type alone would accept 2.0, unlike the native/draft metadata parsers.
    raise SchemaError('non_integer_number')


def validate_metadata(value):
    if next(validator().iter_errors(value), None) is not None:
        raise SchemaError('invalid_manifest_shape')
    apis = value['apiCompatibility']
    if {item['package'] for item in apis} != APIS:
        raise SchemaError('invalid_api_declarations')
    for item in apis:
        lower, upper = version(item['minInclusive']), version(item['maxExclusive'])
        if lower >= upper or any(not lower <= version(v) < upper for v in item['testedVersions']):
            raise SchemaError('invalid_api_range')
    entries = {}
    folded = set()
    previous = ''
    for item in value['files']:
        path = portable_path(item['path'])
        if path == MANIFEST or path.casefold() in folded or path < previous:
            raise SchemaError('invalid_inventory_paths')
        previous = path
        folded.add(path.casefold())
        entries[path] = item
        if item['type'] == 'symlink':
            portable_path(item['target'])
        elif item['sizeBytes'] is not None and type(item['sizeBytes']) is not int:
            raise SchemaError('non_integer_number')
    for path in [*value['licenseFiles'], value['validationFile'], value['signing']['reportPath']]:
        if path is not None:
            portable_path(path)
            if entries.get(path, {}).get('type') != 'file':
                raise SchemaError('invalid_package_reference')
    for snapshot in value['publicSnapshots']:
        if snapshot['directory'] != 'public_api/' + snapshot['package']:
            raise SchemaError('invalid_public_snapshots')
        portable_path(snapshot['directory'])
        tested = next(item['testedVersions'] for item in apis if item['package'] == snapshot['package'])
        if not value['exampleOnly'] and snapshot['version'] not in tested:
            raise SchemaError('invalid_public_snapshots')
    if value['kind'] == 'flutter' and value['nativePayload']['artifactId'] == value['artifactId']:
        raise SchemaError('invalid_native_identity')
    if value['kind'] == 'flutter' and {item['package'] for item in value['publicSnapshots']} != APIS:
        raise SchemaError('invalid_public_snapshots')
    abi = value['nativeAbi']
    numbers = [abi['draftRevision']] if abi['stability'] == 'draft' else [abi['major'], abi['minor']]
    if any(type(number) is not int for number in numbers):
        raise SchemaError('non_integer_number')
    return {'ok': True, 'schemaValid': True, 'installable': False,
            'schemaProfile': 'review-draft-1', 'exampleOnly': value['exampleOnly'],
            'kind': value['kind'], 'artifactId': value['artifactId'],
            'nativeAbiStability': abi['stability']}


def check_manifest(path):
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0))
    try:
        before = checked_regular(fd)
        if before.st_size > MAX_MANIFEST_BYTES:
            raise SchemaError('manifest_limit')
        chunks, remaining = [], MAX_MANIFEST_BYTES + 1
        while remaining:
            chunk = os.read(fd, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b''.join(chunks)
        if len(raw) > MAX_MANIFEST_BYTES:
            raise SchemaError('manifest_limit')
        if stamp(before) != stamp(os.fstat(fd)):
            raise SchemaError('manifest_changed')
    finally:
        os.close(fd)
    value = json.loads(raw.decode('utf-8'), object_pairs_hook=unique_object,
                       parse_constant=invalid_constant, parse_float=no_float)
    result = validate_metadata(value)
    result['manifestSha256'] = hashlib.sha256(raw).hexdigest()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    args = parser.parse_args()
    try:
        result = check_manifest(args.manifest)
    except (SchemaError, InventoryError, CompatibilityError) as error:
        result = {'ok': False, 'installable': False, 'error': error.code}
    except (OSError, ValueError, UnicodeError, RecursionError):
        result = {'ok': False, 'installable': False, 'error': 'invalid_manifest'}
    print(json.dumps(result, sort_keys=True))
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    sys.exit(main())
