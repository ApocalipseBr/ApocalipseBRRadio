"""Execute the real publish-step shell with Docker mocked; no Steam access."""
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]


class PublishWorkflowTests(unittest.TestCase):
    def test_workflow_distinguishes_confirmed_unconfirmed_and_failed_containers(self):
        workflow = (ROOT / ".github/workflows/publish-workshop.yml").read_text()
        step = workflow.split("      - name: Publish existing Workshop item\n", 1)[1].split("      - name:", 1)[0]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        for code, publication, expected_exit in [(0, "confirmed", 0), (2, "unconfirmed", 0), (1, "failed", 1), (125, "failed", 125)]:
            with self.subTest(code=code), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                docker = root / "docker"
                docker.write_text('#!/bin/bash\nif [[ "$1" == run ]]; then exit "$MOCK_DOCKER_EXIT"; fi\nexit 0\n')
                docker.chmod(0o700)
                output, summary = root / "output", root / "summary"
                env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                           MOCK_DOCKER_EXIT=str(code), STEAM_USERNAME="fixture", STEAM_CONFIG_VDF="fixture",
                           WORKSHOP_CONTAINER="fixture", RUNNER_TEMP=directory,
                           GITHUB_OUTPUT=str(output), GITHUB_STEP_SUMMARY=str(summary))
                result = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)
                self.assertEqual(expected_exit, result.returncode, result.stderr)
                self.assertEqual("publication=" + publication + "\n", output.read_text())
                if code == 2:
                    self.assertIn("::warning::", result.stdout)
                    self.assertIn("Server restart skipped", summary.read_text())

    def test_restart_requires_confirmed_publication_even_when_publish_step_succeeds(self):
        workflow = (ROOT / ".github/workflows/publish-workshop.yml").read_text()
        restart = workflow.split("      - name: Request server restart after successful Steam publish\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("steps.steam.outputs.publication == 'confirmed'", restart)
        self.assertIn("!cancelled()", restart)
