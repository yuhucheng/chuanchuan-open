#!/usr/bin/env python3
"""Historical source compatibility probe; not formal binary SDK acceptance.

Run with an explicitly supplied SDK repository and immutable commit. SDK source
is copied only to an automatically removed temporary tree, never into the public
checkout. The normal build remains independent of this probe and SDK source Git.
"""
import argparse
from datetime import datetime, timezone
import platform
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description="Build the current client against an explicit historical source SDK in a temporary tree; never configures the working client.")
parser.add_argument('--sdk-repository', type=Path, required=True)
parser.add_argument('--sdk-revision', required=True, help='Full 40-hex commit, not a moving ref')
parser.add_argument('--flutter', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
if not re.fullmatch('[0-9a-f]{40}', args.sdk_revision):
    parser.error('sdk-revision must be a full lowercase commit SHA')
public = Path(__file__).resolve().parents[1]
private = args.sdk_repository.resolve()
flutter = str(args.flutter.resolve())
revision = args.sdk_revision
prefix = 'packages/share_hub_media_sdk/'
records = []
versions = json.loads(subprocess.check_output([flutter, '--version', '--machine'], text=True))
if versions.get('frameworkVersion') != '3.47.2' or not versions.get('dartSdkVersion', '').startswith('3.13.2'):
    parser.error('Flutter 3.47.2 / Dart 3.13.2 is required')
evidence = args.output.resolve()
evidence.parent.mkdir(parents=True, exist_ok=True)
client_inputs = [
    'pubspec.yaml', 'pubspec.lock', 'lib/main.dart', 'lib/ui/client_app.dart',
    'lib/features/remote/remote_media.dart',
    'packages/share_hub_media_api/pubspec.yaml',
    'packages/share_hub_media_api/lib/src/remote_media_provider.dart',
]

def result_record():
    return {'date':datetime.now(timezone.utc).date().isoformat(),
            'host':{'system':platform.system(),'architecture':platform.machine()},
            'flutter':versions['frameworkVersion'],'dart':versions['dartSdkVersion'], 'scope':'Historical source preview SDK + current public client; isolated Dart build/entry contract only.',
            'sdkRevision':revision, 'sdkSourceModified':False, 'managementResourcesCopied':False,
            'nativeBinaryLoaded':False, 'realCaptureTested':False,
            'formalBinaryDistributionTested':False, 'commands':records, 'sdkSourceInputs':inputs,
            'toolSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'clientInputs':client_input_records}

with tempfile.TemporaryDirectory(prefix='preview-sdk-consumption-') as tmp:
    root = Path(tmp) / 'client'
    root.mkdir()
    for name in ('lib', 'packages'):
        shutil.copytree(public / name, root / name,
            ignore=shutil.ignore_patterns('.dart_tool','build','.git','pubspec.lock','.flutter-plugins-dependencies'))
    for name in ('pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml'):
        shutil.copy2(public / name, root / name)
    client_input_records = [{'path':p, 'sha256':hashlib.sha256((root/p).read_bytes()).hexdigest()} for p in client_inputs]
    sdk = root / '.local/media-sdk/package'
    sdk.mkdir(parents=True)
    paths = subprocess.check_output(['git','-C',str(private),'ls-tree','-r','--name-only',revision,prefix],text=True).splitlines()
    if not paths:
        raise SystemExit('SDK package absent at selected revision')
    inputs=[]
    for name in paths:
        if not name.startswith(prefix) or '..' in Path(name).parts:
            raise SystemExit('Unsafe SDK source path')
        raw = subprocess.check_output(['git','-C',str(private),'show',f'{revision}:{name}'])
        target = sdk / name.removeprefix(prefix)
        target.parent.mkdir(parents=True,exist_ok=True)
        target.write_bytes(raw)
        inputs.append({'path': name.removeprefix(prefix),'sha256':hashlib.sha256(raw).hexdigest()})
    # Test the historical entry itself, not a replacement SDK implementation.
    (root/'test').mkdir()
    (root/'test/legacy_entry_test.dart').write_text('''
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_hub_media_api/share_hub_media_api.dart';
import 'package:share_hub_media_sdk/share_hub_media_sdk.dart';
import 'package:share_hub_open/features/remote/remote_media.dart';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    test('historical preview entry on $platform declares no remote', () async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final preview = createPreviewEngine();
      expect(preview, isNot(isA<RemoteMediaProvider>()));
      expect(preview.unavailableReason, isNull);
      expect(capabilitiesOf(preview).operations, isEmpty);
      expect(remotePicturesFor(preview).capabilities.operations, isEmpty);
      await preview.dispose();
    });
  }
}
''')
    steps=[['pub','get','--offline'],['analyze','--no-pub','lib'],
           ['test','--no-pub','test/legacy_entry_test.dart'],
           ['build','bundle','--debug','--no-pub','--target-platform=darwin','--target=lib/main.dart']]
    for args in steps:
        print('Running flutter '+' '.join(args),flush=True)
        run=subprocess.run([flutter,*args],cwd=root,capture_output=True,text=True)
        clean=(run.stdout+run.stderr).replace(str(root),'<isolated-client>').replace(str(public),'<public-source>').replace(str(private),'<sdk-source>')
        records.append({'command':'flutter '+' '.join(args),'exitCode':run.returncode,'output':clean})
        evidence.write_text(json.dumps(result_record(),indent=2,ensure_ascii=False)+'\n')
        if run.returncode:
            print(clean[-4000:],flush=True)
            raise SystemExit(run.returncode)
    config=json.loads((root/'.dart_tool/package_config.json').read_text())
    for entry in config['packages']:
        if entry['name'] in ('share_hub_media_api','share_hub_session_api','share_hub_media_sdk'):
            assert not entry['rootUri'].startswith('file:')
    for item in inputs:
        assert hashlib.sha256((sdk / item['path']).read_bytes()).hexdigest() == item['sha256']
    record=result_record()
    record['packageRoots']=[p for p in config['packages'] if p['name'] in ('share_hub_media_api','share_hub_session_api','share_hub_media_sdk')]
    record['kernelProduced']=(root/'build/flutter_assets/kernel_blob.bin').is_file()
    assert record['kernelProduced']
    evidence.write_text(json.dumps(record,indent=2,ensure_ascii=False)+'\n')
    print('Historical preview entry tests and isolated standard-entry Dart bundle passed.',flush=True)
