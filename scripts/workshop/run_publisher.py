"""Serialize Steam account use and keep its freshest login on the Linux runner."""
from contextlib import contextmanager
import fcntl
import hashlib
import os
from pathlib import Path
import subprocess
import signal
import sys
import time

import steam_session


@contextmanager
def account_lock(directory, timeout=300):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    with (directory / "account.lock").open("a") as lock:
        os.chmod(lock.name, 0o600)
        deadline = time.monotonic() + timeout
        print("Waiting for the runner's Steam account lock.", flush=True)
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("Steam account lock timeout") from None
                time.sleep(0.25)
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def run():
    username = os.environ.get("STEAM_USERNAME", "")
    if not username:
        raise ValueError("Missing Steam username")
    root = Path(os.environ.get("STEAM_STATE_ROOT", str(Path.home() / ".local/state/apocalipse-steam"))).resolve()
    account = root / hashlib.sha256(username.casefold().encode()).hexdigest()
    # This lock covers upload AND secret refresh, across cooperating repos on
    # this runner host. The organization secret is only a bootstrap/backup.
    with account_lock(account):
        runtime = account / "steamcmd"
        marker = runtime / "authenticated"
        marker.unlink(missing_ok=True)
        command = [
            "docker", "run", "--init", "--name", os.environ["WORKSHOP_CONTAINER"],
            "--user", str(os.getuid()) + ":" + str(os.getgid()),
            "--mount", "type=bind,src=" + str(account) + ",dst=/steam-state",
            "--mount", "type=bind,src=" + str(Path(os.environ["RUNNER_TEMP"]) / "workshop-package") + ",dst=/package,readonly",
            "--env", "HOME=/steam-state", "--env", "STEAM_STATE_PERSISTENT=1",
            "--env", "STEAM_USERNAME", "--env", "STEAM_PASSWORD", "--env", "STEAM_CONFIG_VDF",
            "--env", "WORKSHOP_ID", "--env", "SOURCE_SHA", "pz-workshop-publisher",
        ]
        try:
            status = subprocess.run(command, timeout=1250).returncode
        except BaseException:
            # Docker can outlive its attached client. Stop it before releasing
            # the account lock on timeout/cancellation.
            subprocess.run(["docker", "rm", "-f", os.environ["WORKSHOP_CONTAINER"]],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30, check=True)
            raise
        publication = {0: "confirmed", 2: "unconfirmed"}.get(status, "failed")
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write("publication=" + publication + "\n")
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as summary:
            summary.write("Workshop publication: **" + publication + "**.\n")
            if status == 2:
                summary.write("Upload attempted; verify the Workshop item before retrying. Server restart skipped.\n")
        if status == 2:
            print("::warning::Workshop publication is unconfirmed; server restart skipped.")
        if marker.is_file():
            # Keep the newer runner config even if writing its backup fails.
            steam_session.save(os.environ["STEAM_SECRETS_ORGANIZATION"], runtime / "config/config.vdf")
            print("Refreshed Steam login retained on the runner and backed up to the organization secret.")
        else:
            print("Steam login was not confirmed; organization session secret retained.")
        return 0 if status == 2 else status


def main():
    try:
        return run()
    except steam_session.SessionError as error:
        print("::error::" + str(error))
    except Exception:
        # Exception values and subprocess commands may contain session details.
        print("::error::Runner Steam publishing failed: lock, container, or session backup error. No session data was logged.")
    return 1


if __name__ == "__main__":
    def cancelled(signum, frame):
        raise RuntimeError("Publishing cancelled")

    signal.signal(signal.SIGTERM, cancelled)
    signal.signal(signal.SIGINT, cancelled)
    sys.exit(main())
