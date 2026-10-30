import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("publish_homebrew", Path(__file__).resolve().parents[2] / "script/publish_homebrew.py")
homebrew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(homebrew)


class HomebrewTests(unittest.TestCase):
    def test_cask_uses_verified_stable_universal_archive(self):
        cask = homebrew.render_cask("0.2.1", "a" * 64)
        self.assertIn('version "0.2.1"', cask)
        self.assertIn('sha256 "' + "a" * 64 + '"', cask)
        self.assertIn('v#{version}/Linvell-#{version}-universal.zip', cask)
        self.assertIn('app "Linvell.app"', cask)

    def test_rejects_prerelease_and_injected_inputs(self):
        for value in ("0.2.1-beta", "v0.2.1", '0.2.1"', "../1", "0.2"):
            with self.assertRaises(ValueError):
                homebrew.render_cask(value, "a" * 64)
        with self.assertRaises(ValueError):
            homebrew.render_cask("0.2.1", "bad")

    def test_checksum_must_match_one_exact_filename(self):
        checksum = "a" * 64 + "  Linvell-0.2.1-universal.zip\n"
        self.assertEqual(homebrew.checksum_for(checksum, "Linvell-0.2.1-universal.zip"), "a" * 64)
        for text in ("", checksum + checksum, checksum.replace(".zip", ".zip.bak"), checksum.replace("a" * 64, "bad")):
            with self.assertRaises(ValueError):
                homebrew.checksum_for(text, "Linvell-0.2.1-universal.zip")

    def test_retries_are_idempotent_and_old_releases_cannot_downgrade(self):
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "linvell.rb"
            homebrew.write_cask(path, "0.2.10", "a" * 64)
            original = path.read_text()
            homebrew.write_cask(path, "0.2.10", "a" * 64)
            self.assertEqual(path.read_text(), original)
            with self.assertRaises(ValueError):
                homebrew.write_cask(path, "0.2.9", "b" * 64)
            self.assertEqual(path.read_text(), original)
