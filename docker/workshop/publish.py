"""SteamCMD publisher using Valve's saved-config, username-only login flow."""
import base64
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def quoted(value):
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError("Control characters are not allowed in Steam arguments")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def restore_config(runtime, encoded):
    config = base64.b64decode(encoded.strip(), validate=True)
    if not config or len(config) > 32768:
        raise ValueError("A valid Steam login config is required")
    config_path = runtime / "config/config.vdf"
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_bytes(config)
    config_path.chmod(0o600)


def failure_reason(output):
    # Classify known messages; never print raw Steam output or account details.
    if re.search(r"cached credentials not found|no cached credentials|cached credential is invalid|invalid cached credentials", output, re.I):
        return "Steam could not find usable remembered credentials."
    if re.search(r"not logged (?:on|in)", output, re.I):
        return "The upload process was not logged in to Steam."
    if re.search(r"(?:Failed to load|Failed to parse|Missing) build config file", output, re.I):
        return "Steam could not load or parse the Workshop upload VDF."
    if re.search(r"Content root folder does not exist", output, re.I):
        return "Steam could not find the Workshop content directory."
    if re.search(r"Steam Guard|two[- ]?factor|AccountLogonDenied|authenticator code|InvalidLoginAuthCode", output, re.I):
        return "Steam requested or rejected Steam Guard authentication."
    if re.search(r"Invalid Password|InvalidPassword|Invalid Login|InvalidLogin", output, re.I):
        return "Steam rejected the login credentials or remembered session."
    if re.search(r"Access Denied|AccessDenied|InsufficientPrivilege|does not own|No subscription", output, re.I):
        return "Steam denied account access to the game or Workshop item."
    if re.search(r"LegalAgreement|legal agreement|Workshop agreement", output, re.I):
        return "Steam requires acceptance of the Workshop agreement."
    if re.search(r"No Connection|NoConnection|ConnectFailed|connection.*failed|timed out", output, re.I):
        return "Steam reported a connection failure."
    return "Steam returned an unrecognized failure or did not confirm the target Workshop item."


def main():
    # SteamCMD stores config/ssfn state beside its executable, not only in ~/.steam.
    runtime = Path.home() / "steamcmd"
    if not runtime.exists():
        shutil.copytree("/opt/steamcmd", runtime)
    steamcmd = str(runtime / "steamcmd.sh")
    os.chdir(runtime)
    # Used only for the documented interactive Steam Guard bootstrap.
    if sys.argv[1:] == ["login"]:
        return subprocess.call([steamcmd])
    if sys.argv[1:]:
        raise ValueError("Unsupported publisher argument")
    username = os.environ.get("STEAM_USERNAME", "")
    restore_config(runtime, os.environ.get("STEAM_CONFIG_VDF", ""))
    marker = runtime / "authenticated"
    marker.unlink(missing_ok=True)
    item_id = os.environ.get("WORKSHOP_ID", "")
    sha = os.environ.get("SOURCE_SHA", "")
    return publish(Path("/package"), steamcmd, username, item_id, sha,
                   password=os.environ.get("STEAM_PASSWORD", ""), authentication_marker=marker)


def publish(package, steamcmd, username, item_id, sha, password="", authentication_marker=None):
    if not username:
        raise ValueError("STEAM_USERNAME is required")
    if not re.fullmatch(r"[1-9][0-9]{0,19}", item_id):
        raise ValueError("An existing Workshop item ID is required")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("Invalid source commit")
    manifest = json.loads((package / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("workshop_id") != item_id:
        raise ValueError("Package and target Workshop IDs differ")
    if not (package / "Contents/mods").is_dir() or not (package / "preview.png").is_file():
        raise ValueError("Incomplete Workshop package")
    # Login and upload must share a process: successful password login does not
    # guarantee another process can immediately use the remembered credentials.
    with tempfile.TemporaryDirectory(prefix="workshop-publish-") as directory:
        vdf = Path(directory) / "workshop.vdf"
        vdf.write_text('"workshopitem"\n{\n' + "\n".join(
            "    " + quoted(key) + " " + quoted(value) for key, value in {
                "appid": "108600",
                "publishedfileid": item_id,
                "contentfolder": str(package / "Contents"),
                "previewfile": str(package / "preview.png"),
                "changenote": "Automated update from commit " + sha,
            }.items()) + "\n}\n", encoding="utf-8")
        commands = Path(directory) / "publish.txt"
        print("Trying remembered Steam login and upload in the same process.", flush=True)
        attempts = [None, password] if password else [None]
        for login_password in attempts:
            if login_password is not None:
                print("Remembered login failed. Starting password login and upload; "
                      "approve this sign-in in the Steam mobile app if prompted.", flush=True)
            commands.write_text(
                "@ShutdownOnFailedCommand 1\n@NoPromptForPassword 1\n"
                "login " + quoted(username)
                + (" " + quoted(login_password) if login_password is not None else "")
                + "\ninfo\nworkshop_build_item " + quoted(str(vdf)) + "\nquit\n", encoding="utf-8")
            commands.chmod(0o600)
            # Steam logs can contain account/session details. Never print raw output.
            result = subprocess.run(
                [steamcmd, "+runscript", str(commands)], stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                errors="replace", timeout=1200,
            )
            output = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", result.stdout)
            authenticated = bool(re.search(r"Logon state:\s*Logged On\b", output, re.I))
            if authenticated and authentication_marker is not None:
                authentication_marker.write_text("confirmed\n", encoding="utf-8")
                authentication_marker.chmod(0o600)
            # Retry only a known credential failure before an upload was started.
            # An uncertain Workshop operation must never trigger a second upload.
            credential_failure = re.search(
                r"cached credentials not found|no cached credentials|cached credential is invalid|invalid cached credentials", output, re.I)
            upload_started = re.search(r"Preparing update|Preparing content|Uploading content|Uploading preview|Committing update|Success\.", output, re.I)
            if not (login_password is None and password and not authenticated
                    and credential_failure and not upload_started):
                break
        # SteamCMD can return zero even after a failed Workshop operation.
        # Current SteamCMD confirms existing-item updates with
        # "Committing update...Success.", without repeating the item ID.
        # The manifest and generated VDF above already pin the target item.
        success = re.search(
            r"Success\.\s+(?:Published|Updated)\s+Item\s+" + re.escape(item_id) + r"\b",
            output, re.IGNORECASE,
        ) or re.search(
            r"\bCommitting update\.\.\.[ \t\r\n]*Success\.[ \t]*\r?$",
            output, re.IGNORECASE | re.MULTILINE,
        )
        if result.returncode != 0 or not authenticated or not success:
            print("SteamCMD did not confirm publication. " + failure_reason(result.stdout) +
                  " SteamCMD exit status: " + str(result.returncode) +
                  ". Raw Steam output remains hidden.", file=sys.stderr)
            print("Upload diagnostics: login=" + ("confirmed" if authenticated else "unconfirmed")
                  + ", preparing=" + str(bool(re.search(r"Preparing (?:update|content)", output, re.I)))
                  + ", uploading=" + str(bool(re.search(r"Uploading (?:content|preview)", output, re.I)))
                  + ", committing=" + str(bool(re.search(r"Committing update", output, re.I)))
                  + ", success_message=" + str(bool(re.search(r"Success\.", output, re.I))), file=sys.stderr)
            return 1
        print("Published Workshop item " + item_id + " from commit " + sha)
        return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, json.JSONDecodeError, subprocess.TimeoutExpired):
        # Do not echo exception values, credential-bearing commands, or Steam output.
        print("Workshop publishing failed: configuration, package, or SteamCMD timeout error.", file=sys.stderr)
        sys.exit(1)
