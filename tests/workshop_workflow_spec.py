"""Runner integration regressions; Docker and GitHub are mocked."""
import contextlib
import hashlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/workshop"))
import run_publisher as runner


class PublishWorkflowTests(unittest.TestCase):
    def test_runner_status_and_backup_under_lock(self):
        for code, publication, expected_exit in [(0, "confirmed", 0), (2, "unconfirmed", 0), (1, "failed", 1), (125, "failed", 125)]:
            with self.subTest(code=code), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                account = root / "state" / hashlib.sha256(b"fixture").hexdigest()
                runtime = account / "steamcmd"
                runtime.mkdir(parents=True)
                (runtime / "authenticated").write_text("old marker")
                env = dict(STEAM_STATE_ROOT=str(root / "state"), STEAM_USERNAME="fixture",
                           WORKSHOP_CONTAINER="fixture", RUNNER_TEMP=directory, STEAM_SECRETS_ORGANIZATION="FixtureOrg",
                           GITHUB_OUTPUT=str(root / "output"), GITHUB_STEP_SUMMARY=str(root / "summary"))

                def docker(args, **kwargs):
                    self.assertFalse((runtime / "authenticated").exists())
                    self.assertIn("HOME=/steam-state", args)
                    self.assertIn("STEAM_STATE_PERSISTENT=1", args)
                    if code != 125:
                        (runtime / "authenticated").write_text("confirmed")
                        (runtime / "config").mkdir()
                        (runtime / "config/config.vdf").write_text("new-session")
                    return subprocess.CompletedProcess(args, code)

                def save(org, config):
                    self.assertEqual("new-session", config.read_text())
                    with self.assertRaises(TimeoutError), runner.account_lock(account, timeout=0):
                        pass

                with patch.dict(os.environ, env), patch.object(runner.subprocess, "run", side_effect=docker), \
                        patch.object(runner.steam_session, "save", side_effect=save) as backup, \
                        contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(expected_exit, runner.main())
                self.assertEqual("publication=" + publication + "\n", (root / "output").read_text())
                self.assertEqual(code != 125, backup.called)
                if code == 2:
                    self.assertIn("Server restart skipped", (root / "summary").read_text())

    def test_lock_releases_after_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(ValueError):
                with runner.account_lock(root, timeout=0):
                    raise ValueError("fixture")
            with runner.account_lock(root, timeout=0):
                self.assertEqual(0o700, root.stat().st_mode & 0o777)

    def test_timeout_stops_container_before_releasing_account_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            account = root / hashlib.sha256(b"fixture").hexdigest()
            env = dict(STEAM_STATE_ROOT=directory, STEAM_USERNAME="fixture", WORKSHOP_CONTAINER="fixture", RUNNER_TEMP=directory)
            calls = []

            def docker(args, **kwargs):
                calls.append(args)
                if args[1] == "run":
                    raise subprocess.TimeoutExpired("docker", 1250)
                self.assertEqual(["docker", "rm", "-f", "fixture"], args)
                with self.assertRaises(TimeoutError), runner.account_lock(account, timeout=0):
                    pass
                return subprocess.CompletedProcess(args, 0)

            with patch.dict(os.environ, env), patch.object(runner.subprocess, "run", side_effect=docker), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(1, runner.main())
            self.assertEqual(2, len(calls))

    def test_backup_failure_keeps_confirmed_output_and_latest_runner_config(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = dict(STEAM_STATE_ROOT=directory, STEAM_USERNAME="fixture", WORKSHOP_CONTAINER="fixture", RUNNER_TEMP=directory,
                       STEAM_SECRETS_ORGANIZATION="FixtureOrg", GITHUB_OUTPUT=str(root / "output"), GITHUB_STEP_SUMMARY=str(root / "summary"))
            config = root / hashlib.sha256(b"fixture").hexdigest() / "steamcmd/config/config.vdf"

            def docker(args, **kwargs):
                config.parent.mkdir(parents=True)
                config.write_text("new-session")
                (config.parent.parent / "authenticated").write_text("confirmed")
                return subprocess.CompletedProcess(args, 0)

            with patch.dict(os.environ, env), patch.object(runner.subprocess, "run", side_effect=docker), \
                    patch.object(runner.steam_session, "save", side_effect=ValueError("private-token")), \
                    contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(1, runner.main())
            self.assertEqual("publication=confirmed\n", (root / "output").read_text())
            self.assertEqual("new-session", config.read_text())
            self.assertNotIn("private-token", out.getvalue())

    def test_workflow_keeps_confirmed_restart_when_session_backup_fails(self):
        workflow = (ROOT / ".github/workflows/publish-workshop.yml").read_text()
        self.assertIn("python3 .workshop-tools/scripts/workshop/run_publisher.py", workflow)
        restart = workflow.split("      - name: Request server restart after successful Steam publish\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("steps.steam.outputs.publication == 'confirmed'", restart)
        self.assertNotIn("steps.steam.outcome == 'success'", restart)
        self.assertIn("!cancelled()", restart)
