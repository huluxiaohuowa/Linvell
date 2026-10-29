import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

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

    def test_apple_stages_are_named_without_credential_arguments(self):
        self.assertEqual(module.command_stage(['xcrun','stapler','staple','private-path']), 'Apple ticket staple')
        self.assertEqual(module.command_stage(['xcrun','notarytool','submit','private-path','--key','private-key']), 'Apple notarization submit')
    def test_accepted_ticket_is_retried_then_validated(self):
        with patch.object(module,'run',side_effect=[SystemExit(),b'',b'']) as run,patch.object(module.time,'sleep') as sleep:
            module.staple(Path('/fixture/Linvell.app'))
            self.assertEqual(run.call_count,3)
            sleep.assert_called_once_with(15)
            self.assertEqual(run.call_args.args[0][1:3],['stapler','validate'])
