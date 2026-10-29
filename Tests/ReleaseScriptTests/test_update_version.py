import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('update_version', Path(__file__).resolve().parents[2] / 'script/update_version.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class VersionUpdateTests(unittest.TestCase):
    def test_patch_carries_only_at_1000(self):
        for current, expected in [('0.2.0', '0.2.1'), ('0.2.9', '0.2.10'), ('0.2.99', '0.2.100'), ('0.2.998', '0.2.999'), ('0.2.999', '0.3.0'), ('0.999.999', '1.0.0'), ('999.999.999', '1000.0.0')]:
            with self.subTest(current=current):
                self.assertEqual(module.next_version(current), expected)

    def test_explicit_minor_and_major_clear_lower_components(self):
        for current, level, expected in [('0.2.123', 'minor', '0.3.0'), ('0.9.123', 'minor', '0.10.0'), ('0.999.123', 'minor', '1.0.0'), ('0.2.123', 'major', '1.0.0'), ('9.999.999', 'major', '10.0.0')]:
            with self.subTest(current=current, level=level):
                self.assertEqual(module.next_version(current, level), expected)

    def test_prerelease_input_and_invalid_versions(self):
        self.assertEqual(module.next_version('0.2.999-preview.1'), '0.3.0')
        for value in ['0.2', 'v0.2.0', '0.2.-1']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                module.next_version(value)

    def test_cli_updates_bundle_fields_and_build_counter(self):
        for level, expected in [(None, '0.2.124'), ('patch', '0.2.124'), ('minor', '0.3.0'), ('major', '1.0.0')]:
            with self.subTest(level=level), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                (root / 'Resources').mkdir()
                file = root / 'Resources/Info.plist'
                file.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.2.123', 'LinvellReleaseVersion': '0.2.123', 'CFBundleVersion': '12', 'CFBundleIdentifier': 'test.example'}))
                argv = ['update_version.py'] + ([level] if level else [])
                with patch.object(module, 'ROOT', root), patch('sys.argv', argv), patch('builtins.print'):
                    module.main()
                info = plistlib.loads(file.read_bytes())
                self.assertEqual(info['CFBundleShortVersionString'], expected)
                self.assertEqual(info['LinvellReleaseVersion'], expected)
                self.assertEqual(info['CFBundleVersion'], '13')
                self.assertEqual(info['CFBundleIdentifier'], 'test.example')
