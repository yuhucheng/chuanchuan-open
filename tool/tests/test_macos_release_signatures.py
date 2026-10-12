import importlib.util
from pathlib import Path
import plistlib
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('signature_audit',Path(__file__).resolve().parents[1]/'check_macos_release_signatures.py')
audit=importlib.util.module_from_spec(spec);spec.loader.exec_module(audit)


class SignatureChecksTests(unittest.TestCase):
    def invoke(self, trusted=0, timestamp=True, debug=False, mixed=False):
        commands=[]
        def fake(args):
            commands.append(args)
            if args[0].endswith('lipo'): return 0,b'arm64 x86_64',b''
            if '--verify' in args: return (trusted if '-R='+audit.DEVELOPER_ID in args else 0),b'',b''
            arch=args[args.index('--arch')+1]
            if '--entitlements' in args:
                ent={'com.apple.security.get-task-allow': True} if debug and arch=='x86_64' else {}
                return 0,plistlib.dumps(ent),b''
            team='BBBBBBBBBB' if mixed and arch=='x86_64' else 'AAAAAAAAAA'
            data='Authority=Developer ID Application: A spoofable name\nTeamIdentifier='+team+'\nCodeDirectory flags=0x10000(runtime)\n'
            if timestamp: data+='Timestamp=Oct 13, 2026\n'
            return 0,b'',data.encode()
        with patch.object(audit,'run',fake):
            result=audit.inspect_code(Path('sample'),expected_team='AAAAAAAAAA',needs_runtime=True)
        return result,commands

    def test_authority_name_cannot_replace_apple_certificate_requirement(self):
        result,commands=self.invoke(trusted=3)
        self.assertTrue(result['integrityValid'])
        self.assertIn('not_apple_developer_id',result['failures'])
        self.assertTrue(any('-R='+audit.DEVELOPER_ID in c and '--all-architectures' in c for c in commands))

    def test_other_architecture_debug_entitlement_is_rejected(self):
        result,_=self.invoke(debug=True)
        self.assertIn('debug_entitlement_present',result['failures'])

    def test_missing_timestamp_and_mixed_team_cannot_pass(self):
        result,_=self.invoke(timestamp=False,mixed=True)
        self.assertIn('missing_secure_timestamp',result['failures'])
        self.assertIn('missing_or_mixed_team',result['failures'])

    def test_local_signed_time_is_not_a_secure_timestamp(self):
        info=audit.signature_info(b'TeamIdentifier=AAAAAAAAAA\nSigned Time=Oct 13, 2026\nCodeDirectory flags=0x2(adhoc)\nSignature=adhoc\n')
        self.assertFalse(info['secureTimestamp']);self.assertFalse(info['hardenedRuntime'])
        self.assertTrue(info['adHoc'])

    def test_synthetic_trusted_slices_only_establish_signing_prerequisites(self):
        result,_=self.invoke()
        self.assertEqual(result['failures'],[])
        self.assertNotIn('releaseReady',result)


if __name__=='__main__':unittest.main()
