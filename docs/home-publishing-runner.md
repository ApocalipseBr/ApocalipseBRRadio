# Home publishing runner on Windows with WSL2

The package job and every PR check stay on GitHub-hosted Ubuntu. Only trusted
pushes to master or manual runs on master dispatch the publish job to your home
Linux x64 runner, selected by `[self-hosted, Linux, X64, pz-workshop]`.
SteamCMD runs inside a normal Docker container using your home internet connection.
No VPN, DNS updater, mirrored networking, inbound firewall changes or router port
forwarding are required. Standard WSL2 NAT networking works.

## Prepare WSL

Open your Ubuntu WSL terminal as your ordinary Linux user. Install the Linux
prerequisites (GitHub CLI here is the command `gh`, not a login requirement):

```bash
sudo apt-get update
sudo apt-get install -y git curl ca-certificates python3 gh
```

Use either Docker Desktop with **WSL integration enabled for this distribution**,
or Docker Engine installed inside WSL. For Docker Desktop, select Linux containers,
keep Desktop running, and confirm `docker info` succeeds **inside WSL**. Do not
install another Engine in the same distribution when using Desktop integration.
For a standalone Engine on Ubuntu:

```bash
sudo apt-get install -y docker.io
sudo usermod -aG docker "$USER"
# On a systemd-enabled distribution:
sudo systemctl enable --now docker
```

Restart your WSL shell after adding yourself to the Docker group and verify
`docker info`. If systemd is unavailable, start the daemon with
`sudo service docker start`; keep that distribution running. The Docker group
provides control over the Linux host, so use a dedicated runner account/distro.

## Download and register the official runner

Go to:
https://github.com/ApocalipseBr/ApocalipseBRRadio/settings/actions/runners/new

Choose **Linux**, **x64**, even though the physical host is Windows. In WSL,
follow GitHub's current Download commands, including its checksum verification.
Use a directory inside the Linux filesystem, such as `~/actions-runner`, rather
than `/mnt/c`. GitHub supplies the current runner version and a short-lived
registration token; no version, checksum or registration token is stored in this
repository. The token is for registration only, not an Actions organization secret.

From your checkout of this repository, run:

```bash
bash scripts/workshop/configure-home-runner.sh "$HOME/actions-runner"
```

Paste the token from the GitHub page when prompted. The helper checks Docker,
Python and `gh`, registers as the ordinary Linux user, and adds **pz-workshop**.
GitHub also adds the default self-hosted, Linux and X64 labels. Keep them all.
The token is entered without echo and is not stored in shell history; the official
configuration program receives it as its short-lived command argument. Do not
record the terminal/process diagnostics during registration.

Alternatively use GitHub's Configuration command directly, adding
`--labels pz-workshop`. Do not run `config.sh` as root. If it reports missing OS
libraries, run the official runner's `sudo ./bin/installdependencies.sh` and retry.

Start the runner:

```bash
cd ~/actions-runner
./run.sh
```

Leave this WSL terminal open. GitHub's runner page should show **Idle**. It must
show all four matching labels before a pending publishing job can be picked up.
After registration, subsequent starts need only `./run.sh`, not another token.

For automatic service startup inside a systemd-enabled WSL distribution:

```bash
cd ~/actions-runner
sudo ./svc.sh install "$USER"
sudo ./svc.sh start
sudo ./svc.sh status
```

A Windows reboot does not automatically start your WSL distribution. Start it and
Docker Desktop before publishing, or configure Windows Task Scheduler to launch
the WSL distribution at user logon. Keep Windows awake. If the runner is offline,
the publishing job waits for it; it does not fall back to GitHub's cloud IP.

## Access and secrets

Keep the existing Steam and pzmanager organization secrets described in
[Workshop publishing](workshop-publishing.md). GitHub supplies them to the home job,
including its scoped token for refreshing the Steam config. No personal `gh auth
login` is required for the workflow: its `GH_TOKEN` comes from that secret.
`WORKSHOP_WIREGUARD_CONFIG` is no longer consumed. The optional pzmanager home-DNS
PR is not required for this approach.

This is a public repository: keep this runner dedicated to trusted publishing.
This workflow's PR path runs only on GitHub-hosted workers, but labels are routing,
not an access boundary against other workflows. Review workflow changes before
merging and do not approve untrusted fork workflows onto this machine. An
organization runner restricted to the selected repositories/trusted workflow is
preferable where the GitHub plan supports those controls.

For reuse across several mods, register **one organization runner** from
https://github.com/organizations/ApocalipseBr/settings/actions/runners and grant
it access only to those mod repositories (including public repository access
where required). Pass `https://github.com/ApocalipseBr` as the helper's second
argument when using an organization registration token. A repository runner
cannot accept jobs from other repositories. One runner process executes one job
at a time, which also serializes shared Steam-account publication across those
repositories. Do not register multiple publishing runner processes sharing the
same Steam login/session unless you provide an organization-wide queue.

## Check and recover

Once this change is merged and the runner is Idle, manually dispatch **Steam
Workshop** on master. Package/tests run on GitHub; publish runs on your machine.
The job first checks installed tools and Docker access. Steam can still request
mobile approval for a new device; complete a local interactive bootstrap on this
same machine if remembered authentication fails. A matching home IP does not
replace Steam's device/account security checks.

Each job uses a unique `pz-workshop-<run-id>-<attempt>` container. Normal cleanup
removes it and the staged package. Radio publishing now retains a private
account directory under `~/.local/state/apocalipse-steam/` (or `STEAM_STATE_ROOT`),
uses its latest login config, and holds a Linux file lock through upload and
organization-secret backup. Other mod workflows must use the same runner wrapper
and directory to share this lock; separate machines are not coordinated. The
container runs as the service user's UID/GID. Raw Steam logs stay private there;
CI prints only safe result-code diagnostics. Interrupted WSL/runner shutdown can leave containers
and private logs behind on this persistent host. Inspect stale containers with
`docker ps -a`, then remove the specific old container once you confirm that no
publication is running. After a possibly successful upload, check the Workshop
changenote before rerunning; request a failed restart separately.

Python/Bash/YAML syntax and diff checks are performed locally; existing offline
publisher tests and container builds run in CI. Runner registration and Steam
publication must be verified on your home machine.

References: [GitHub runner labels](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/apply-labels),
[runner service](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/configure-the-application?platform=linux).
