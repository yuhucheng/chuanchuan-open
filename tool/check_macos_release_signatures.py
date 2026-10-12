#!/usr/bin/env python3
"""Read-only application code-signing checks, never a complete release approval.

No signing, private keys, upload, source execution or application launch.
Optional Gatekeeper/stapled-ticket assessment runs only after signing passes.
"""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

DEVELOPER_ID = 'anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
MACHO = {bytes.fromhex(v) for v in ['feedface','cefaedfe','feedfacf','cffaedfe','cafebabe','bebafeca','cafebabf','bfbafeca']}
TEAM = re.compile(r'[A-Z0-9]{10}\Z')


def run(args):
    try:
        result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=30, check=False)
        return result.returncode, result.stdout, result.stderr
    except (OSError, subprocess.TimeoutExpired):
        return 125, b'', b''


def signature_info(raw):
    text = raw.decode('utf-8', errors='replace')
    fields = {}
    for line in text.splitlines():
        if '=' in line:
            name, value = line.split('=', 1)
            if name in fields and name != 'Authority':
                raise ValueError('ambiguous_signature_metadata')
            fields[name] = value
    match = re.search(r'\bflags=0x([0-9a-fA-F]+)\(', text)
    return {'team': fields.get('TeamIdentifier'),
            'secureTimestamp': bool(fields.get('Timestamp')) and fields.get('Timestamp') != 'none',
            'hardenedRuntime': bool(match and int(match[1], 16) & 0x10000),
            'adHoc': fields.get('Signature') == 'adhoc'}


def inspect_code(path, expected_team=None, needs_runtime=False, binary=None):
    verify, _, _ = run(['/usr/bin/codesign','--verify','--strict','--all-architectures',str(path)])
    trusted, _, _ = run(['/usr/bin/codesign','--verify','--strict','--all-architectures',
                          '-R='+DEVELOPER_ID,str(path)])
    arch_code, arch_raw, _ = run(['/usr/bin/lipo','-archs',str(binary or path)])
    arches = arch_raw.decode('ascii', errors='replace').split() if arch_code == 0 else []
    slices = {}
    for arch in arches:
        code, stdout, stderr = run(['/usr/bin/codesign','--display','--arch',arch,'--verbose=4',str(path)])
        if code:
            slices[arch] = {'metadataRead': False}; continue
        info = signature_info(stderr + stdout)
        ent_code, ent_raw, _ = run(['/usr/bin/codesign','--display','--arch',arch,
                                   '--entitlements','-','--xml',str(path)])
        try:
            entitlements = plistlib.loads(ent_raw) if ent_raw else {}
            if ent_code or not isinstance(entitlements, dict): raise ValueError()
            debug = entitlements.get('com.apple.security.get-task-allow', False)
            if type(debug) is not bool: raise ValueError()
        except (ValueError, plistlib.InvalidFileException):
            debug = None
        info['debugEntitlement'] = debug
        info['metadataRead'] = True; slices[arch] = info
    debug_entitlement = (any(v.get('debugEntitlement') for v in slices.values())
                         if slices and all(type(v.get('debugEntitlement')) is bool for v in slices.values()) else None)
    reasons = []
    if verify: reasons.append('invalid_signature')
    if trusted: reasons.append('not_apple_developer_id')
    if not slices or any(not value.get('metadataRead') for value in slices.values()):
        reasons.append('signature_metadata_unavailable')
    teams = {value.get('team') for value in slices.values()}
    if len(teams) != 1 or not all(isinstance(team,str) and TEAM.fullmatch(team) for team in teams):
        reasons.append('missing_or_mixed_team')
    elif expected_team and teams != {expected_team}: reasons.append('team_mismatch')
    if any(not value.get('secureTimestamp') for value in slices.values()): reasons.append('missing_secure_timestamp')
    if needs_runtime and any(not value.get('hardenedRuntime') for value in slices.values()): reasons.append('hardened_runtime_missing')
    if debug_entitlement is None: reasons.append('entitlements_unreadable')
    elif debug_entitlement: reasons.append('debug_entitlement_present')
    return {'integrityValid': verify == 0,'developerIdRequirementPassed': trusted == 0,
            'slices': slices,'debugEntitlement': debug_entitlement,'failures': reasons}


def audit(app, expected_team=None, assess=False):
    app = app.resolve(strict=True)
    if not app.is_dir() or app.suffix != '.app': raise ValueError('application_bundle_required')
    with (app/'Contents/Info.plist').open('rb') as source: info = plistlib.load(source)
    executable = info.get('CFBundleExecutable')
    if not isinstance(executable,str) or Path(executable).name != executable: raise ValueError('invalid_executable')
    main = app/'Contents/MacOS'/executable
    if not main.is_file(): raise ValueError('executable_missing')
    root = inspect_code(app,expected_team,needs_runtime=True,binary=main)
    if expected_team is None and not root['failures']:
        expected_team = next(iter(root['slices'].values()))['team']
    components = {}
    bundles = {app}
    for path in app.rglob('*'):
        if path.is_symlink():
            if not path.resolve(strict=True).is_relative_to(app): raise ValueError('escaping_bundle_link')
            continue
        if path.is_dir() and path.suffix in ('.framework','.app','.xpc','.appex'):
            bundles.add(path)
        if path.is_file():
            with path.open('rb') as source: magic = source.read(4)
            if magic in MACHO and path != main:
                header_status, headers, _ = run(['/usr/bin/otool','-hv',str(path)])
                needs_runtime = bool(re.search(rb'\bEXECUTE\b',headers))
                inspected = inspect_code(path,expected_team,needs_runtime)
                if header_status: inspected['failures'].append('mach_header_unreadable')
                components[path.relative_to(app).as_posix()] = inspected
    # Container verification checks framework resources as well as Mach-O bytes.
    container_errors = []
    for bundle in sorted(bundles - {app}):
        code, _, _ = run(['/usr/bin/codesign','--verify','--strict','--all-architectures',str(bundle)])
        if code: container_errors.append(bundle.relative_to(app).as_posix())
    signing_ok = not root['failures'] and not container_errors and all(not c['failures'] for c in components.values())
    assessment = {'performed':False,'gatekeeperAccepted':False,'stapledTicketValid':False}
    if assess and signing_ok:
        gatekeeper, _, _ = run(['/usr/sbin/spctl','--assess','--type','execute',str(app)])
        staple, _, _ = run(['/usr/bin/xcrun','stapler','validate',str(app)])
        assessment = {'performed':True,'gatekeeperAccepted':gatekeeper==0,'stapledTicketValid':staple==0}
    return {'signingChecksPassed':signing_ok,'macTrustChecksPassed':signing_ok and all(assessment.values()),
            'releaseReady':False,'appLaunched':False,'main':root,'components':components,
            'invalidNestedContainers':container_errors,'assessment':assessment,
            'notVerified':['SDK source provenance','licenses/API/ABI','Windows release matrix','actual loading/GUI/media']}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('application',type=Path)
    parser.add_argument('--expected-team')
    parser.add_argument('--assess',action='store_true')
    args=parser.parse_args()
    if sys.platform!='darwin': parser.error('macOS required')
    if args.expected_team and not TEAM.fullmatch(args.expected_team): parser.error('expected team must be ten uppercase letters/digits')
    try: result=audit(args.application,args.expected_team,args.assess)
    except (OSError,ValueError) as error:
        print(json.dumps({'error':str(error),'releaseReady':False}));return 1
    print(json.dumps(result,indent=2))
    return 0 if result['macTrustChecksPassed'] else 1


if __name__=='__main__': raise SystemExit(main())
