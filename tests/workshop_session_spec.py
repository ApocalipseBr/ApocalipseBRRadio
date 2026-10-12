"""Offline authentication-state tests: no Steam or GitHub requests."""
import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


session = load("steam_session", "scripts/workshop/steam_session.py")
publisher = load("session_publisher", "docker/workshop/publish.py")


class SteamSessionTests(unittest.TestCase):
    def test_persistent_runner_config_wins_over_stale_or_invalid_secret(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            runtime = home / "steamcmd"
            (runtime / "config").mkdir(parents=True)
            (runtime / "steamcmd.sh").write_text("fixture")
            (runtime / "config/config.vdf").write_bytes(b"fresh-runner-session")
            previous_cwd = Path.cwd()
            try:
                with patch.object(publisher.Path, "home", return_value=home), \
                        patch.dict(os.environ, {"STEAM_STATE_PERSISTENT": "1", "STEAM_CONFIG_VDF": "stale-invalid-secret"}), \
                        patch.object(publisher.sys, "argv", ["publisher"]), \
                        patch.object(publisher, "publish", return_value=0), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(0, publisher.main())
                self.assertEqual(b"fresh-runner-session", (runtime / "config/config.vdf").read_bytes())
            finally:
                os.chdir(previous_cwd)

    def test_http_failures_show_operation_and_status_without_raw_output(self):
        failure = subprocess.CalledProcessError(1, ["gh"], stderr=b"private-token: Forbidden (HTTP 403)")
        output = io.StringIO()
        with patch.object(session, "configuration", return_value="ExampleOrg"), \
                patch.object(session.sys, "argv", ["session", "--validate-only"]), \
                patch.object(session.subprocess, "run", side_effect=failure), contextlib.redirect_stdout(output):
            self.assertEqual(1, session.main())
        self.assertIn("read organization session secret metadata (HTTP 403)", output.getvalue())
        self.assertNotIn("private-token", output.getvalue())
        self.assertNotIn("Forbidden", output.getvalue())

    def test_base64_errors_are_distinguishable_from_github_permissions(self):
        env = {"STEAM_SECRETS_ORGANIZATION": "ExampleOrg", "GH_TOKEN": "writer-token",
               "STEAM_CONFIG_VDF": "not-base64!"}
        output = io.StringIO()
        with patch.dict(os.environ, env), contextlib.redirect_stdout(output):
            self.assertEqual(1, session.main())
        self.assertIn("must contain base64", output.getvalue())
        self.assertNotIn("not-base64!", output.getvalue())

    def test_pasted_config_can_have_surrounding_whitespace(self):
        env = {"STEAM_SECRETS_ORGANIZATION": "ExampleOrg", "GH_TOKEN": "writer-token",
               "STEAM_CONFIG_VDF": "\r\n" + base64.b64encode(b"session").decode() + "\r\n"}
        with patch.dict(os.environ, env):
            self.assertEqual("ExampleOrg", session.configuration())

    def test_config_is_restored_privately_and_invalid_state_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory)
            config = b'"InstallConfigStore" { "fixture" "remembered-token" }'
            publisher.restore_config(runtime, base64.b64encode(config).decode())
            file = runtime / "config/config.vdf"
            self.assertEqual(config, file.read_bytes())
            self.assertEqual(0o600, file.stat().st_mode & 0o777)
            for invalid in ["", "not base64!", base64.b64encode(b"x" * 32769).decode()]:
                with self.assertRaises(ValueError):
                    publisher.restore_config(runtime, invalid)

    def test_saving_preserves_selected_repository_access_and_uses_stdin(self):
        calls = []

        def gh(args, data=None):
            calls.append((args, data))
            if args[0] == "secret":
                return b""
            if args[-1].endswith("/repositories"):
                return json.dumps([{"repositories": [{"name": "Radio"}]},
                                   {"repositories": [{"name": "Farming"}]}]).encode()
            if args[-1].endswith("/public-key"):
                return b"{}"
            return b'{"visibility":"selected"}'

        with tempfile.TemporaryDirectory() as directory, patch.object(session, "gh", side_effect=gh):
            file = Path(directory) / "config.vdf"
            file.write_bytes(b"private-session")
            session.save("ExampleOrg", file)
        args, data = calls[-1]
        self.assertIn("Radio,Farming", args)
        self.assertIn("selected", args)
        self.assertEqual(base64.b64encode(b"private-session"), data)
        self.assertNotIn("private-session", str(args))

    def test_other_visibility_policies_are_retained(self):
        for visibility in ["all", "private"]:
            with patch.object(session, "gh", return_value=json.dumps({"visibility": visibility}).encode()):
                self.assertEqual((visibility, []), session.secret_policy("ExampleOrg"))

    def test_subprocess_never_puts_secret_in_arguments_or_output(self):
        with patch.object(session.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"ok")) as call:
            session.gh(["secret", "set", "STEAM_CONFIG_VDF"], b"private-session")
        self.assertNotIn("private-session", str(call.call_args.args))
        self.assertEqual(b"private-session", call.call_args.kwargs["input"])
        self.assertTrue(call.call_args.kwargs["capture_output"])

    def test_error_messages_hide_credential_bearing_exceptions(self):
        output = io.StringIO()
        with patch.object(session, "configuration", side_effect=ValueError("private-token")), contextlib.redirect_stdout(output):
            self.assertEqual(1, session.main())
        self.assertNotIn("private-token", output.getvalue())

    def test_validation_does_not_write_session_secret(self):
        env = {"STEAM_SECRETS_ORGANIZATION": "ExampleOrg", "GH_TOKEN": "writer-token",
               "STEAM_CONFIG_VDF": base64.b64encode(b"session").decode()}
        with patch.dict(os.environ, env), patch.object(session.sys, "argv", ["session", "--validate-only"]), \
                patch.object(session, "secret_policy"), patch.object(session, "save") as save, \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, session.main())
            save.assert_not_called()
