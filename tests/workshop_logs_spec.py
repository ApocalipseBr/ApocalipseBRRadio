"""Only fresh upload diagnostics may affect the current attempt."""
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
spec = importlib.util.spec_from_file_location("log_publisher", ROOT / "docker/workshop/publish.py")
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class UploadLogTests(unittest.TestCase):
    def test_old_log_errors_are_ignored_and_rotation_is_read(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "build.log"
            log.write_text("ERROR! Failed to update workshop item (25). private-token\n")
            snapshot = publisher.log_snapshot([log])
            self.assertEqual((0, ""), publisher.fresh_upload_logs([log], snapshot))
            with log.open("a") as file:
                file.write("SubmitItemUpdateResult: EResult=1\n")
            count, output = publisher.fresh_upload_logs([log], snapshot)
            self.assertEqual(1, count)
            self.assertNotIn("private-token", output)
            self.assertFalse(publisher.terminal_diagnostics(output)["commit_failed"])
            log.unlink()
            log.write_text("ERROR! Failed to update workshop item (84).\n")
            self.assertIn("84", publisher.fresh_upload_logs([log], snapshot)[1])

    def test_log_failure_overrides_stdout_success_without_leaking_raw_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "package"
            (package / "Contents/mods").mkdir(parents=True)
            (package / "preview.png").write_bytes(b"fixture")
            (package / "manifest.json").write_text(json.dumps({"workshop_id": "3706460551"}))
            log = root / "build.log"

            def steam(args, **kwargs):
                log.write_text("private-account private-token https://secret/path\nERROR! Failed to update workshop item (84).\n")
                return subprocess.CompletedProcess(args, 0, "Logon state: Logged On\nCommitting update...Success.\n")

            out = io.StringIO()
            with patch.object(publisher.subprocess, "run", side_effect=steam), \
                    contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
                self.assertEqual(1, publisher.publish(package, "steamcmd", "fixture", "3706460551", "a" * 40, log_paths=[log]))
            self.assertIn('"result_codes": [84]', out.getvalue())
            self.assertIn("temporary rate limit", out.getvalue())
            for secret in ["private-account", "private-token", "https://secret/path"]:
                self.assertNotIn(secret, out.getvalue())

    def test_unknown_result_text_is_never_exposed(self):
        result = publisher.terminal_diagnostics("ERROR! Failed to update workshop item (private-account).")
        self.assertTrue(result["commit_failed"])
        self.assertEqual([], result["result_codes"])
        self.assertNotIn("private-account", json.dumps(result))
