"""Offline pipeline regressions; SteamCMD is mocked and no item is published."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


stage = load("workshop_stage", "scripts/workshop/stage.py")
publisher = load("workshop_publisher", "docker/workshop/publish.py")
ITEM = "3706460551"
SHA = "a" * 40


class WorkshopTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        mod = self.source / "Contents/mods/Test/42"
        mod.mkdir(parents=True)
        (mod / "mod.info").write_text("name=Test\nid=test\n")
        (self.source / "preview.png").write_bytes(b"\x89PNG\r\n\x1a\n" + b"fixture")
        (self.source / "workshop.txt").write_text("id=" + ITEM + "\n")
        (self.source / "not-for-publishing.txt").write_text("source-only")
        self.package = self.root / "package"

    def staged(self):
        with contextlib.redirect_stdout(io.StringIO()):
            stage.stage(self.source, self.package, ITEM)

    def test_ready_package_copies_only_contents_preview_and_manifest(self):
        self.staged()
        self.assertEqual({"Contents", "preview.png", "manifest.json"},
                         {p.name for p in self.package.iterdir()})
        self.assertEqual(ITEM, json.loads((self.package / "manifest.json").read_text())["workshop_id"])
        self.assertEqual(0o644, (self.package / "Contents/mods/Test/42/mod.info").stat().st_mode & 0o777)

    def test_wrong_item_and_new_item_are_rejected(self):
        for item in ["0", "3781972601", "invalid"]:
            with self.assertRaises(ValueError):
                stage.stage(self.source, self.package, item)
        self.assertFalse(self.package.exists())

    def test_symlink_and_missing_mod_info_are_rejected(self):
        link = self.source / "Contents/mods/Test/link"
        link.symlink_to(self.source / "workshop.txt")
        with self.assertRaises(ValueError):
            stage.stage(self.source, self.package, ITEM)
        link.unlink()
        (self.source / "Contents/mods/Test/42/mod.info").unlink()
        with self.assertRaises(ValueError):
            stage.stage(self.source, self.package, ITEM)

    def test_project_and_pzstudio_output_stay_inside_expected_roots(self):
        self.assertEqual(self.source, stage.contained(self.root, "source"))
        with self.assertRaises(ValueError):
            stage.contained(self.source, "..")
        config = self.root / "project.json"
        config.write_text(json.dumps({"title": "Built Mod"}))
        (self.root / "Built Mod").mkdir()
        self.assertEqual(self.root / "Built Mod", stage.output(self.root, config))
        config.write_text(json.dumps({"title": "../escape"}))
        with self.assertRaises(ValueError):
            stage.output(self.root, config)

    def test_publisher_uses_contents_and_protects_credentials(self):
        self.staged()
        command_paths = []

        def steamcmd(args, **kwargs):
            self.assertNotIn("test_account", str(args))
            commands = Path(args[-1])
            command_paths.append(commands)
            self.assertEqual(0o600, commands.stat().st_mode & 0o777)
            text = commands.read_text()
            self.assertIn("login " + publisher.quoted("test_account") + "\n", text)
            vdf = (commands.parent / "workshop.vdf").read_text()
            self.assertIn('"appid" "108600"', vdf)
            self.assertIn('"publishedfileid" "' + ITEM + '"', vdf)
            self.assertIn(publisher.quoted(str(self.package / "Contents")), vdf)
            self.assertNotIn('"visibility"', vdf)
            return subprocess.CompletedProcess(args, 0, "Logon state: Logged On\nSuccess. Published Item " + ITEM)

        out = io.StringIO()
        with patch.object(publisher.subprocess, "run", side_effect=steamcmd), contextlib.redirect_stdout(out):
            self.assertEqual(0, publisher.publish(self.package, "/fake/steamcmd", "test_account", ITEM, SHA))
        self.assertNotIn("test_account", out.getvalue())
        self.assertTrue(all(not path.exists() for path in command_paths))

    def test_existing_item_commit_confirmation_succeeds(self):
        self.staged()
        for output in [
            "Preparing update...Uploading content...Committing update...Success.\nquit\n",
            "Committing update...\r\nSuccess.\r\n",
            "Committing update...\x1b[0mSuccess.\x1b[0m\nquit\n",
        ]:
            with self.subTest(output=output), \
                    patch.object(publisher.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "Logon state: Logged On\n" + output)), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(0, publisher.publish(self.package, "/fake/steamcmd", "test_account", ITEM, SHA))

    def test_zero_exit_without_expected_publication_fails_and_hides_raw_output(self):
        self.staged()
        for code, output in [(0, "ERROR: password secret"), (1, "Success. Published Item " + ITEM),
                             (0, "Success. Published Item 3781972601"),
                             (0, "Success.\n"),
                             (0, "Uploading content...Success.\n"),
                             (0, "Committing update...ERROR! Failed to update workshop item.\nSuccess.\n"),
                             (0, "Committing update...Success. Created new item, PublishedFileId 3781972601\n"),
                             (1, "Committing update...Success.\n")]:
            out, err = io.StringIO(), io.StringIO()
            with patch.object(publisher.subprocess, "run", return_value=subprocess.CompletedProcess([], code, output)), \
                    contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                self.assertEqual(1, publisher.publish(self.package, "/fake/steamcmd", "test_account", ITEM, SHA))
            self.assertNotIn(output, out.getvalue() + err.getvalue())
            self.assertNotIn("secret", out.getvalue() + err.getvalue())

    def test_password_control_characters_cannot_inject_commands(self):
        for value in ["password\nquit", "password\rquit", "password\0quit"]:
            with self.assertRaises(ValueError):
                publisher.quoted(value)

    def test_steam_failure_diagnostics_classify_without_exposing_account_data(self):
        for output, reason in [
            ("private-account: Steam Guard code required", "Steam requested or rejected Steam Guard authentication."),
            ("private-account: FAILED (Invalid Password)", "Steam rejected the login credentials or remembered session."),
            ("private-account: Access Denied", "Steam denied account access to the game or Workshop item."),
            ("private-account: LegalAgreement", "Steam requires acceptance of the Workshop agreement."),
            ("private-account: FAILED (No Connection)", "Steam reported a connection failure."),
        ]:
            self.assertEqual(reason, publisher.failure_reason(output))
            self.assertNotIn("private-account", publisher.failure_reason(output))


if __name__ == "__main__":
    unittest.main()
