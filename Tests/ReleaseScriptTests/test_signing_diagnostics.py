import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('release', Path(__file__).resolve().parents[2] / 'script/release.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class SigningDiagnosticsTests(unittest.TestCase):
    def test_diagnostics_never_echo_private_tool_output(self):
        for output in [b'private-name private-path', b'private-name: errSecInternalComponent',b'private-name: unable to build chain to self-signed root',b'private-name: no identity found']:
            reason = module.signing_failure_reason(output)
            self.assertNotIn('private-name',reason)
            self.assertNotIn('private-path',reason)
        self.assertIn('intermediate',module.signing_failure_reason(b'unable to build chain'))
