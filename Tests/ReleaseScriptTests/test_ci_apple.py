import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('ci_apple', Path(__file__).resolve().parents[2] / 'script/materialize_ci_apple.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class AppleCIConfigTests(unittest.TestCase):
    def fixture(self):
        return {'common': {'teamId':'TEST','temporaryKeychainPassword':'unused','certificates': {'developerIdApplication': {'p12Base64':'Y2VydA==','password':'fixture','identity':'fixture'},'unrelated': {'p12Base64':'do-not-copy'}},'appStoreConnect': {'issuerId':'fixture','keyId':'fixture','privateKeyBase64':'a2V5'}},'other-app': {'profile':'do-not-copy'}}
    def test_only_required_common_fields_are_materialized_with_private_permissions(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'apple.json'
            module.materialize(self.fixture(),path)
            value=json.loads(path.read_text())
            self.assertEqual(set(value),{'common'})
            self.assertEqual(set(value['common']['certificates']),{'developerIdApplication'})
            self.assertEqual(stat.S_IMODE(path.stat().st_mode),0o600)
            self.assertNotIn('do-not-copy',path.read_text())
            self.assertNotEqual(value['common']['temporaryKeychainPassword'],'unused')
    def test_checkout_destination_and_overwrite_are_rejected(self):
        with self.assertRaises(ValueError): module.materialize(self.fixture(),module.ROOT/'ci-apple.json')
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'apple.json';path.write_text('existing')
            with self.assertRaises(FileExistsError): module.materialize(self.fixture(),path)
            self.assertEqual(path.read_text(),'existing')

if __name__=='__main__': unittest.main()
