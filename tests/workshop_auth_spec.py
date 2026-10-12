"""Offline session tests; never authenticate or upload to Steam."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "steam_auth_publisher", Path(__file__).resolve().parents[1] / "docker/workshop/publish.py")
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)
ITEM = "3706460551"
SHA = "a" * 40
SUCCESS = "Logon state: Logged On\nCommitting update...Success.\n"


class SteamAuthenticationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.package = Path(self.temp.name) / "package"
        (self.package / "Contents/mods").mkdir(parents=True)
        (self.package / "preview.png").write_bytes(b"fixture")
        (self.package / "manifest.json").write_text(json.dumps({"workshop_id": ITEM}))
        self.marker = Path(self.temp.name) / "authenticated"

    def publish(self, outputs, password="private-password"):
        scripts = []
        def run(args, **kwargs):
            self.assertNotIn("private-password", str(args))
            commands = Path(args[-1])
            self.assertEqual(0o600, commands.stat().st_mode & 0o777)
            self.assertEqual(subprocess.DEVNULL, kwargs["stdin"])
            scripts.append(commands.read_text())
            return subprocess.CompletedProcess(args, *outputs[len(scripts) - 1])
        out, err = io.StringIO(), io.StringIO()
        with patch.object(publisher.subprocess, "run", side_effect=run), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = publisher.publish(self.package, "steamcmd", "account", ITEM, SHA,
                                       password=password, authentication_marker=self.marker)
        self.assertNotIn("private-password", out.getvalue() + err.getvalue())
        return status, scripts, out.getvalue() + err.getvalue()

    def test_cached_login_and_upload_share_one_process_without_password(self):
        status, scripts, _ = self.publish([(0, SUCCESS)])
        self.assertEqual(0, status)
        self.assertEqual(1, len(scripts))
        self.assertIn('login "account"\ninfo\nworkshop_build_item', scripts[0])
        self.assertNotIn("private-password", scripts[0])
        self.assertTrue(self.marker.exists())

    def test_no_cache_falls_back_to_password_and_upload_in_same_process(self):
        for message in ["Cached credentials not found.",
                        "FAILED (No cached credentials and @NoPromptForPassword is set)"]:
            status, scripts, output = self.publish([(0, message), (0, SUCCESS)])
            self.assertEqual(0, status)
            self.assertEqual(2, len(scripts))
            self.assertIn('login "account" "private-password"\ninfo\nworkshop_build_item', scripts[1])
            self.assertIn("Steam mobile app", output)
            self.assertTrue(self.marker.exists())

    def test_authenticated_upload_failure_never_retries(self):
        status, scripts, output = self.publish([(0, "Logon state: Logged On\nERROR! Failed to update workshop item.")])
        self.assertEqual(1, status)
        self.assertEqual(1, len(scripts))
        self.assertTrue(self.marker.exists())
        self.assertIn("login=confirmed", output)

    def test_mobile_guard_approval_and_commit_with_command_echo_confirm_publication(self):
        status, scripts, output = self.publish([
            (0, "No cached credentials"),
            (0, "Approve this sign-in in Steam Guard\nLogon state: Logged On\n"
                "Preparing update...Uploading content...Committing update...Success. quit\n"),
        ])
        self.assertEqual(0, status)
        self.assertEqual(2, len(scripts))
        self.assertTrue(self.marker.exists())
        self.assertIn("Published Workshop item " + ITEM, output)

    def test_guard_prompt_before_authenticated_upload_failure_is_not_a_guard_error(self):
        status, scripts, output = self.publish([
            (0, "Steam Guard approval requested\nLogon state: Logged On\n"
                "Preparing update...Uploading content...Committing update..."
                "ERROR! Failed to update workshop item.\nSuccess.\n"),
        ])
        self.assertEqual(1, status)
        self.assertEqual(1, len(scripts))
        self.assertIn("Steam reported a Workshop publication failure.", output)
        self.assertIn("publication_confirmed=False", output)
        self.assertNotIn("Steam requested or rejected Steam Guard", output)

    def test_ambiguous_completed_upload_preserves_session_without_retry_or_claiming_publication(self):
        status, scripts, output = self.publish([
            (0, "No cached credentials"),
            (0, "Steam Guard approval requested\nLogon state: Logged On\n"
                "Preparing update...Uploading content...Committing update...\n"
                "Unrecognized completion format\nSuccess.\n"),
        ])
        self.assertEqual(2, status)
        self.assertEqual(2, len(scripts))
        self.assertTrue(self.marker.exists())
        self.assertIn("::warning::", output)
        self.assertIn("Publication status: unconfirmed", output)
        self.assertNotIn("Published Workshop item", output)

    def test_explicit_failures_never_become_unconfirmed_even_with_all_progress_flags(self):
        for failure in ["ERROR! Failed to update workshop item.", "Access Denied",
                        "Committing update...Success. Published Item 3781972601",
                        "Committing update...Success. (3781972601)",
                        "Created new item, PublishedFileId " + ITEM]:
            with self.subTest(failure=failure):
                status, scripts, _ = self.publish([
                    (0, "Logon state: Logged On\nPreparing update...Uploading content..."
                        "Committing update...\n" + failure + "\nSuccess.\n"),
                ])
                self.assertEqual(1, status)
                self.assertEqual(1, len(scripts))

    def test_nonzero_exit_with_all_progress_flags_remains_failed(self):
        status, scripts, _ = self.publish([
            (1, "Logon state: Logged On\nPreparing update...Uploading content..."
                "Committing update...\nUnrecognized format\nSuccess.\n"),
        ])
        self.assertEqual(1, status)
        self.assertEqual(1, len(scripts))

    def test_uncertain_upload_or_login_failure_never_retries(self):
        for output in ["Unknown failure", "Uploading content...No cached credentials",
                       "Success.\nNo cached credentials", "Committing update...Success.\n"]:
            status, scripts, _ = self.publish([(0, output)])
            self.assertEqual(1, status)
            self.assertEqual(1, len(scripts))
            self.assertFalse(self.marker.exists())

    def test_no_password_or_failed_password_login_leaves_no_marker(self):
        status, scripts, _ = self.publish([(0, "No cached credentials")], password="")
        self.assertEqual(1, status)
        self.assertEqual(1, len(scripts))
        status, scripts, _ = self.publish([(0, "No cached credentials"), (0, "Logon state: Logged Off")])
        self.assertEqual(1, status)
        self.assertEqual(2, len(scripts))
        self.assertFalse(self.marker.exists())

    def test_timeout_does_not_launch_another_upload(self):
        with patch.object(publisher.subprocess, "run", side_effect=subprocess.TimeoutExpired("steamcmd", 1200)) as run, \
                contextlib.redirect_stdout(io.StringIO()), self.assertRaises(subprocess.TimeoutExpired):
            publisher.publish(self.package, "steamcmd", "account", ITEM, SHA,
                              password="private-password", authentication_marker=self.marker)
        self.assertEqual(1, run.call_count)
        self.assertFalse(self.marker.exists())

    def test_failure_diagnostics_do_not_expose_raw_values(self):
        for raw, expected in [
            ("private-account FAILED (No cached credentials and @NoPromptForPassword is set)",
             "Steam could not find usable remembered credentials."),
            ("private-account ERROR! Not logged on.", "The upload process was not logged in to Steam."),
            ('ERROR! Failed to load build config file "private-path".',
             "Steam could not load or parse the Workshop upload VDF."),
        ]:
            self.assertEqual(expected, publisher.failure_reason(raw))


if __name__ == "__main__":
    unittest.main()
