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


UNCONFIRMED_REASON = "Steam authenticated, but its output did not confirm publication of the target Workshop item."
RESULT_NAMES = {1: "OK", 2: "Fail", 8: "InvalidParam", 9: "FileNotFound", 15: "AccessDenied",
                16: "Timeout", 25: "LimitExceeded", 33: "LockingFailed",
                34: "LogonSessionReplaced", 84: "RateLimitExceeded"}


def upload_log_paths(runtime):
    # SteamCMD installations can use either their runtime or ~/Steam for logs.
    roots = {runtime, Path.home() / "Steam", runtime / "Steam"}
    return sorted({root / relative for root in roots for relative in (
        "workshopbuilds/depot_build_108600.log", "logs/workshop_log.txt",
        "logs/Workshop_log.txt", "depot_build_output/depot_build_108600.log",
    )})


def log_snapshot(paths):
    snapshot = {}
    for path in paths:
        try:
            stat = path.stat()
            snapshot[path] = (stat.st_ino, stat.st_size)
        except FileNotFoundError:
            pass
    return snapshot


def fresh_upload_logs(paths, snapshot):
    chunks = []
    count = 0
    for path in paths:
        try:
            stat = path.stat()
            inode, offset = snapshot.get(path, (None, 0))
            if inode != stat.st_ino or stat.st_size < offset:
                offset = 0
            if stat.st_size == offset:
                continue
            # Read only this attempt's tail, bounded even for verbose builds.
            with path.open("rb") as log:
                log.seek(max(offset, stat.st_size - 2 * 1024 * 1024))
                chunks.append(log.read().decode("utf-8", errors="replace"))
            count += 1
        except FileNotFoundError:
            continue
    return count, "\n".join(chunks)


def terminal_diagnostics(output):
    # Extract only known categories and numeric EResult values. Never copy a
    # Steam line, account name, URL, path, token, or unknown textual result.
    terminal = re.findall(
        r"(?:Failed to (?:update|publish) workshop item|SubmitItemUpdate(?:Result)?)[^\r\n]{0,120}", output, re.I)
    codes = sorted({int(a or b) for line in terminal for a, b in re.findall(
        r"\(\s*([0-9]{1,3})\s*\)|(?:EResult|result(?: code)?)\s*[:=]\s*([0-9]{1,3})\b", line, re.I)})
    failed = bool(re.search(r"Failed to (?:update|publish) workshop item", output, re.I)) or any(code != 1 for code in codes)
    return {"commit_failed": failed, "result_codes": codes,
            "result_names": [RESULT_NAMES.get(code, "Unknown") for code in codes]}


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


def publication_confirmed(output, item_id):
    # Do not require Success. to end the console line: SteamCMD can append
    # command echoes or item details to the commit confirmation.
    published = re.search(r"Success\.\s+(?:Published|Updated)\s+Item\s+([0-9]+)\b", output, re.I)
    if published:
        return published.group(1) == item_id
    committed = re.search(r"\bCommitting update\.\.\.\s*Success\.(?=\s|$)([^\r\n]*)", output, re.I)
    if not committed:
        return False
    details = committed.group(1)
    if re.search(r"Created new item", details, re.I):
        return False
    # A reported item ID must still agree with the manifest and upload VDF.
    reported_ids = re.findall(
        r"(?:PublishedFileId|File\s*ID)\s*[:=]?\s*([0-9]+)\b|\(\s*([0-9]+)\s*\)", details, re.I)
    return all((named or parenthesized) == item_id for named, parenthesized in reported_ids)


def failure_reason(output, authenticated=False):
    # Classify known messages; never print raw Steam output or account details.
    if not authenticated and re.search(r"cached credentials not found|no cached credentials|cached credential is invalid|invalid cached credentials", output, re.I):
        return "Steam could not find usable remembered credentials."
    if re.search(r"not logged (?:on|in)", output, re.I):
        return "The upload process was not logged in to Steam."
    if re.search(r"(?:Failed to load|Failed to parse|Missing) build config file", output, re.I):
        return "Steam could not load or parse the Workshop upload VDF."
    if re.search(r"Content root folder does not exist", output, re.I):
        return "Steam could not find the Workshop content directory."
    if re.search(r"RateLimitExceeded|rate limit exceeded", output, re.I):
        return "Steam reported a temporary rate limit."
    if re.search(r"LockingFailed|failed to (?:acquire|aquire).*UGC.*lock", output, re.I):
        return "Steam could not acquire the Workshop update lock."
    if re.search(r"LogonSessionReplaced|logon session.*replaced", output, re.I):
        return "Steam reported that another login replaced this session."
    if re.search(r"LimitExceeded", output, re.I):
        return "Steam reported a size or storage quota limit."
    if not authenticated and re.search(r"Steam Guard|two[- ]?factor|AccountLogonDenied|authenticator code|InvalidLoginAuthCode", output, re.I):
        return "Steam requested or rejected Steam Guard authentication."
    if not authenticated and re.search(r"Invalid Password|InvalidPassword|Invalid Login|InvalidLogin", output, re.I):
        return "Steam rejected the login credentials or remembered session."
    if re.search(r"Access Denied|AccessDenied|InsufficientPrivilege|does not own|No subscription", output, re.I):
        return "Steam denied account access to the game or Workshop item."
    if re.search(r"LegalAgreement|legal agreement|Workshop agreement", output, re.I):
        return "Steam requires acceptance of the Workshop agreement."
    if re.search(r"No Connection|NoConnection|ConnectFailed|connection.*failed|timed out", output, re.I):
        return "Steam reported a connection failure."
    if re.search(r"Failed to (?:update|publish) workshop item", output, re.I):
        return "Steam reported a Workshop publication failure."
    if authenticated:
        return UNCONFIRMED_REASON
    return "Steam returned an unrecognized failure or did not confirm the target Workshop item."


def publication_status(output, item_id, returncode, authenticated):
    """0 = confirmed, 1 = failed, 2 = upload attempted but unconfirmed."""
    if returncode != 0 or not authenticated:
        return 1
    # Inspect the authenticated portion so an earlier Guard prompt cannot turn
    # an otherwise completed upload into an authentication failure.
    upload_output = re.split(r"Logon state:\s*Logged On\b", output, flags=re.I)[-1]
    if re.search(r"\bERROR\b|\bFAILED\b|Created new item", upload_output, re.I):
        return 1
    reason = failure_reason(upload_output, authenticated=True)
    if reason != UNCONFIRMED_REASON:
        return 1
    reported_ids = re.findall(
        r"(?:Published\s+Item|Updated\s+Item|PublishedFileId|File\s*ID)\s*[:=]?\s*([0-9]+)\b",
        upload_output, re.I)
    if any(reported != item_id for reported in reported_ids):
        return 1
    parenthesized_ids = re.findall(r"Success\.[^\r\n]*\(\s*([0-9]+)\s*\)", upload_output, re.I)
    if any(reported != item_id for reported in parenthesized_ids):
        return 1
    if publication_confirmed(output, item_id):
        return 0
    # Exit zero and generic Success. are insufficient proof of publication.
    # Preserve uncertainty only when every expected upload phase was reached.
    if all(re.search(pattern, upload_output, re.I) for pattern in (
        r"Preparing (?:update|content)", r"Uploading (?:content|preview)",
        r"Committing update", r"Success\.",
    )):
        return 2
    return 1


def main():
    # SteamCMD stores config/ssfn state beside its executable, not only in ~/.steam.
    runtime = Path.home() / "steamcmd"
    if not (runtime / "steamcmd.sh").exists():
        shutil.copytree("/opt/steamcmd", runtime, dirs_exist_ok=True)
    steamcmd = str(runtime / "steamcmd.sh")
    os.chdir(runtime)
    # Used only for the documented interactive Steam Guard bootstrap.
    if sys.argv[1:] == ["login"]:
        return subprocess.call([steamcmd])
    if sys.argv[1:]:
        raise ValueError("Unsupported publisher argument")
    username = os.environ.get("STEAM_USERNAME", "")
    if os.environ.get("STEAM_STATE_PERSISTENT") == "1" and (runtime / "config/config.vdf").is_file():
        print("Using the runner's latest remembered Steam login.", flush=True)
    else:
        restore_config(runtime, os.environ.get("STEAM_CONFIG_VDF", ""))
    marker = runtime / "authenticated"
    marker.unlink(missing_ok=True)
    item_id = os.environ.get("WORKSHOP_ID", "")
    sha = os.environ.get("SOURCE_SHA", "")
    return publish(Path("/package"), steamcmd, username, item_id, sha,
                   password=os.environ.get("STEAM_PASSWORD", ""), authentication_marker=marker)


def publish(package, steamcmd, username, item_id, sha, password="", authentication_marker=None, log_paths=None):
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
        log_paths = upload_log_paths(Path(steamcmd).parent) if log_paths is None else log_paths
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
            before_logs = log_snapshot(log_paths)
            # Steam logs can contain account/session details. Never print raw output.
            try:
                result = subprocess.run(
                    [steamcmd, "+runscript", str(commands)], stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                    errors="replace", timeout=1200,
                )
            except subprocess.TimeoutExpired:
                log_count, log_output = fresh_upload_logs(log_paths, before_logs)
                diagnostics = terminal_diagnostics(log_output)
                diagnostics.update(fresh_log_files=log_count, publication="unconfirmed", timed_out=True)
                print("Steam upload result: " + json.dumps(diagnostics, sort_keys=True), flush=True)
                raise
            output = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", result.stdout)
            log_count, log_output = fresh_upload_logs(log_paths, before_logs)
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
        success = publication_confirmed(output, item_id)
        status = publication_status(output, item_id, result.returncode, authenticated)
        diagnostics = terminal_diagnostics(output + "\n" + log_output)
        diagnostics["fresh_log_files"] = log_count
        diagnostics["publication"] = {0: "confirmed", 1: "failed", 2: "unconfirmed"}[status]
        if diagnostics["commit_failed"]:
            status = 1
            diagnostics["publication"] = "failed"
        print("Steam upload result: " + json.dumps(diagnostics, sort_keys=True), flush=True)
        if status != 0:
            prefix = "::warning::Workshop upload attempted; publication is unconfirmed. " if status == 2 else "SteamCMD did not confirm publication. "
            reason_output = output + "\n" + log_output + "\n" + " ".join(diagnostics["result_names"])
            print(prefix + failure_reason(reason_output, authenticated) +
                  " SteamCMD exit status: " + str(result.returncode) +
                  ". Raw Steam output remains hidden.", file=sys.stderr)
            print("Upload diagnostics: login=" + ("confirmed" if authenticated else "unconfirmed")
                  + ", preparing=" + str(bool(re.search(r"Preparing (?:update|content)", output, re.I)))
                  + ", uploading=" + str(bool(re.search(r"Uploading (?:content|preview)", output, re.I)))
                  + ", committing=" + str(bool(re.search(r"Committing update", output, re.I)))
                  + ", success_message=" + str(bool(re.search(r"Success\.", output, re.I)))
                  + ", publication_confirmed=" + str(success), file=sys.stderr)
            if status == 2:
                print("Publication status: unconfirmed for Workshop item " + item_id +
                      " from commit " + sha + ". Check the Workshop item before retrying; no automatic retry.")
            return status
        print("Published Workshop item " + item_id + " from commit " + sha)
        return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, json.JSONDecodeError, subprocess.TimeoutExpired):
        # Do not echo exception values, credential-bearing commands, or Steam output.
        print("Workshop publishing failed: configuration, package, or SteamCMD timeout error.", file=sys.stderr)
        sys.exit(1)
