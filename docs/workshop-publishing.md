# Automatic Steam Workshop publishing

`.github/workflows/steam-workshop.yml` packages this Build 42 mod on pull requests
and pushes to **master**. Only a push to master or a manual dispatch on master
publishes existing Workshop item **3706460551**, using Steam App ID **108600**.
Packaging and PR checks use GitHub-hosted `ubuntu-latest`. The publish job uses
a dedicated home Linux x64 runner with labels `self-hosted`, `Linux`, `X64`, and
`pz-workshop`. Follow [home runner setup](home-publishing-runner.md), configure
organization secrets and bootstrap Steam before the first publishing run.

The shared workflow `.github/workflows/publish-workshop.yml` supports:

- `build-mode: ready`: use the existing Contents, preview.png, and workshop.txt.
  This is the radio repository's mode.
- `build-mode: pzstudio`: require package.json and project.json, install project
  dependencies and pzstudio 2.2.0, set an isolated output directory, run
  `npm run build`, and stage the generated Workshop directory. A caller for the
  farming example would use Workshop ID 3781972601.

Packaging runs on GitHub-hosted Ubuntu without Steam credentials. Only Contents,
preview.png, and a small manifest enter the artifact. Each mod must have mod.info,
the expected item ID must match workshop.txt, and symbolic links/special files
are rejected. Artifacts are retained for seven days.

The Linux Docker image installs SteamCMD from Valve, 32-bit runtime libraries,
and Python. A temporary VDF uses the staged **Contents** directory as contentfolder.
The publisher updates content, preview, and changenote with the source commit;
it preserves the item's existing title, description, tags, and visibility.

## Organization secrets

Create these at https://github.com/organizations/ApocalipseBr/settings/secrets/actions
and grant **ApocalipseBRRadio** access with the selected-repositories policy:

| Secret | Value and where to get it |
| --- | --- |
| `STEAM_USERNAME` | The Steam **account login name** for the account that owns Workshop item 3706460551. It is not the profile/display name or SteamID. |
| `STEAM_PASSWORD` | That account's password, used only when remembered login cannot be confirmed. Add this to enable fresh login with mobile approval. Without it, failed remembered login stops before publication. |
| `STEAM_CONFIG_VDF` | Base64 of `config/config.vdf` from a successful interactive SteamCMD login for the same account. See bootstrap below. Contains sensitive remembered-login state. |
| `STEAM_SESSION_GITHUB_TOKEN` | Fine-grained GitHub personal access token with resource owner **ApocalipseBr** and organization **Secrets: read and write**. Create under GitHub Settings → Developer settings → Personal access tokens → Fine-grained tokens. An organization owner must authorize/approve it as required by organization policy. It allows the workflow to preserve refreshed Steam login state. |
| `PZMANAGER_RESTART_URL` | Full HTTPS URL ending in `/api/server/mod-update/restart`, reachable from your home runner. |
| `PZMANAGER_MOD_UPDATE_TOKEN` | Full API key generated through pzmanager's API-key CRUD. Sent as `X-API-Key`. |

The caller explicitly maps these organization secrets into the reusable workflow.
GitHub supplies `GITHUB_TOKEN` for checkout/artifacts, but it cannot write organization
secrets. The separate `STEAM_SESSION_GITHUB_TOKEN` provides that permission. The
workflow captures `gh` output and sends the refreshed secret through stdin for
GitHub public-key encryption, retaining its existing visibility and selected
repository list. A classic PAT with `admin:org` (and `repo` for private repositories)
is an alternative when fine-grained tokens are unavailable. Prefer the narrower
fine-grained token. Token expiry or revocation requires replacing this secret.

No Steam Web API key, SteamID or Workshop ID secret is needed. The password is
not resent when remembered login works; it is used for a fresh login only after
the remembered login fails. It stays in a private temporary script, outside
process arguments and logs, and is never included in the image or artifacts.
Organization-secret availability for private repositories depends on the GitHub
plan. Confirm that this repository can access the secrets.

The Steam account must own the Workshop item, have the required Project Zomboid
access, and accept Steam's Workshop agreement. GitHub repository access does not
grant Steam item ownership.

## Home publishing and Steam authentication

Valve's [Steamworks upload documentation](https://partner.steamgames.com/doc/sdk/uploading)
under automated builds says to complete an initial login with password and Steam
Guard, then run subsequent logins **without a password** and preserve
`config/config.vdf`, which may change after login. It warns that providing the
password again issues a new Steam Guard challenge. The
[Workshop documentation](https://partner.steamgames.com/doc/features/workshop/implementation)
documents `workshop_build_item` for updating an existing item.

The workflow restores the remembered-login config from `STEAM_CONFIG_VDF` into
an ephemeral Docker container. Each SteamCMD script logs in, runs `info`, uploads,
then quits, so the upload uses that process's authenticated session. A known
remembered-credential failure before any upload activity permits one fresh attempt
using `STEAM_PASSWORD`, with a prompt for Steam mobile approval. Unknown failures
and failed or uncertain uploads never trigger another upload automatically.
Confirmation requires exit zero, `Logon state: Logged On`, and Workshop commit
success. Each attempt has a 20-minute timeout; the job has a 30-minute limit.

After confirmed authentication, it copies the resulting config out and updates
the same organization secret even if the subsequent Workshop operation fails.
An `authenticated` marker records successful login in the container. Without it,
the refresh step retains the existing secret instead of saving failed-login state. It deletes the container, exported
config and staged content during cleanup. No login state enters artifacts or
Actions caches; secrets are never printed or embedded in the image. Pull requests
only run package/tests, not authentication, publishing or secret-writing steps.

Install Docker, Python and `gh` on the home runner. Docker uses the home
connection directly; VPN, dynamic DNS, router forwarding and a newer Windows
mirrored-networking version are not required. No persistent Docker volume is required. The account must still own the Workshop
item, meet the game's requirements and have accepted the Workshop agreement.
Steam's remembered login is not guaranteed to survive a new machine/IP, expiry or
account security changes. The password fallback supports accounts for which
SteamCMD offers mobile sign-in approval. Open Steam Guard in the mobile app when
the workflow asks; verify the request and approve within the five-minute window.
GitHub's console cannot accept an email or authenticator code interactively.
Accounts requiring code entry may still fail and need local bootstrap. The flow
never disables Guard or extracts an authenticator seed.
There is no Steam Web API key that replaces the SteamCMD account login here.

### Initial Steam Guard bootstrap

On a trusted local machine with Docker and `gh`, check out the repository and run:

```sh
docker build -t pz-workshop-publisher docker/workshop
docker run -it --name pz-steam-bootstrap pz-workshop-publisher login
```

At the `Steam>` prompt enter `login YOUR_STEAM_LOGIN_NAME`, supply the password
when prompted, and complete Steam Guard. Enter `info` to verify the account is
connected, then `quit`. Use the account named in `STEAM_USERNAME`.

Copy the saved config into a private temporary directory and upload its base64
representation directly to the organization secret without displaying it:

```sh
umask 077
session_dir="$(mktemp -d)"
docker cp pz-steam-bootstrap:/home/steam/steamcmd/config/config.vdf "$session_dir/config.vdf"
chmod 600 "$session_dir/config.vdf"
python3 -c 'import base64,sys; sys.stdout.buffer.write(base64.b64encode(sys.stdin.buffer.read()))' \
  < "$session_dir/config.vdf" \
  | gh secret set STEAM_CONFIG_VDF --org ApocalipseBr \
      --visibility selected --repos ApocalipseBRRadio
docker rm pz-steam-bootstrap
rm -rf -- "$session_dir"
```

Authenticate local `gh` with an organization-secret-capable account first. The
command above grants access only to Radio; when sharing the config with other mod
repositories, include their names in the comma-separated `--repos` list. Every
publishing caller must explicitly map the five existing secrets plus
`STEAM_PASSWORD` to enable fresh-login fallback.
The automatic refresh preserves this access policy. Config is limited to 32 KiB
before base64 encoding to fit GitHub's 48 KiB secret limit. Keep the file private;
it is authentication material, not an ordinary build asset.

After bootstrap, manually dispatch Steam Workshop on master and confirm the
item's timestamp/changenote and the pzmanager restart response. This is the first
real authentication/publishing check: offline CI tests mock Steam and GitHub.

## Failure handling

Session preflight reports missing secrets, malformed base64 or oversized config
separately from GitHub access failures. GitHub errors show only the operation and
numeric HTTP status; raw CLI responses and credentials remain hidden. For 401,
check token expiry/value; for 403, check organization Secrets permissions and
organization approval; for 404, check the resource owner and whether the token can
see `STEAM_CONFIG_VDF` in the configured organization. Surrounding whitespace from
pasting the base64 secret is trimmed before validation and restoration.

After confirmed Steam publication, the workflow calls pzmanager's dedicated
`POST /api/server/mod-update/restart` endpoint with the player message
`Restart para update de mods`. Deploy the pzmanager integration endpoint first.
Add organization secrets `PZMANAGER_RESTART_URL` (the full HTTPS endpoint URL)
and `PZMANAGER_MOD_UPDATE_TOKEN` (the full API key generated through pzmanager's
API-key CRUD). The workflow sends it as `X-API-Key`; no backend environment token
is needed. Revocation and the existing API rate limits apply. Grant both secrets to
each publishing repository and explicitly pass them in reusable-workflow callers,
alongside the Steam secrets. No integration secrets are needed by PR checks.

Configuration is checked before publishing. The API call runs only after the
Steam publish step succeeds, accepts 202/`accepted` or 200/`already_in_progress`,
and refuses redirects. Concurrent mod updates share the backend's active restart
countdown without resetting it. The backend warns all enabled game servers for
10 minutes with the supplied message. If the API call fails, the workflow fails
but the Steam update remains published; retry the restart separately. The hook
does not retry or publish again automatically. The publishing runner must be
able to reach the backend over HTTPS.

Missing session secrets or unreadable secret policy fail before launching SteamCMD.
Saving refreshed state requires organization-secret write permission; if it fails,
the job fails visibly but a confirmed publish still triggers the restart hook. SteamCMD has a 20-minute timeout and the publish
job a 30-minute limit. Both its exit status and explicit successful publication of
the expected item are required; exit zero alone is insufficient. Current SteamCMD
confirms existing-item updates with `Committing update...Success.` without an
item ID in that message. The publisher accepts this commit confirmation after
validating the target ID in the package manifest and setting it in the upload VDF;
it also accepts the older `Success. Published Item <id>` / `Updated Item` format.

Raw Steam output is not printed/uploaded because it can contain account/session
information. Diagnose Steam login, item ownership, agreements, or connectivity
through a trusted local interactive container when publishing fails. A Workshop publish is
an external side effect: inspect the changenote before retrying an uncertain run.
There is no automatic rollback.

Publication failures classify known Steam messages into Guard, rejected login,
account/game/item access, agreement or connectivity failures and report the
SteamCMD exit status and safe flags for login, preparation, upload, commit and
success messages. Unknown output remains generic. These classifications help
diagnose errors without printing Steam's raw output. Session-secret
refresh now requires confirmed authentication, but still does not prove publication
succeeded. Only explicit confirmation of the target Workshop item permits the
pzmanager restart hook.

Publishing jobs share an account concurrency group without cancelling active
uploads. GitHub concurrency is per repository and not FIFO; pending commits can
be superseded by later pushes. When reusing one account across repositories,
use separate Steam accounts/session secrets or a centralized publishing workflow
for organization-wide serialization. Separate repositories do not share a GitHub
concurrency lock. Organization secrets are snapshotted when a workflow is queued;
a queued run can still receive the previous config after another run refreshes it.
Do not run multiple publishers simultaneously against the same account/config.
Cleanup deletes the container and exported login state on the home runner.
After an interrupted runner process, inspect and remove stale `pz-workshop-<run-id>-<attempt>`
containers before rerunning. Never reset a possibly published item blindly.

## Reuse for pzstudio

Mod tests are optional: the reusable workflow's `test-command` input defaults
to an empty string, which skips mod tests. Set it to the repository's test command
(for example, `npm ci && npm test`) to run tests from `project-directory` before
building and staging. Node 22 is available when tests are configured. The command
must install any other required dependencies; a failure blocks packaging and
publishing. Publisher/packaging checks always run, even for mods without tests.

The radio caller enables `npm ci && npm test`. Its pinned npm dependencies run
the music and jukebox Lua simulations through `tests/run.lua` and both language
catalog checks through `tests/translations_spec.js`. Run the same command locally
when needed; these simulations do not replace an in-game smoke test.

A caller in another accessible repository can use:

```yaml
jobs:
  workshop:
    uses: ApocalipseBr/ApocalipseBRRadio/.github/workflows/publish-workshop.yml@master
    with:
      workshop-id: '3781972601'
      build-mode: pzstudio
      project-directory: '.'
    secrets:
      STEAM_USERNAME: ${{ secrets.STEAM_USERNAME }}
      STEAM_PASSWORD: ${{ secrets.STEAM_PASSWORD }}
      STEAM_CONFIG_VDF: ${{ secrets.STEAM_CONFIG_VDF }}
      STEAM_SESSION_GITHUB_TOKEN: ${{ secrets.STEAM_SESSION_GITHUB_TOKEN }}
      PZMANAGER_RESTART_URL: ${{ secrets.PZMANAGER_RESTART_URL }}
      PZMANAGER_MOD_UPDATE_TOKEN: ${{ secrets.PZMANAGER_MOD_UPDATE_TOKEN }}
```

Add the same triggers targeting master and contents: read permission as the radio
caller. External reuse requires permission to read this reusable workflow; a
public caller cannot consume an inaccessible private workflow. External callers
use publishing tools from the radio repository's master and source from their
own triggering commit.

Organization secrets can only be granted to repositories in that organization.
If the farming repository remains under rbm4, give it equivalent repository
secrets and access to the configured organization-secret writer, or transfer it
to ApocalipseBr. `steam-secrets-organization` defaults to `ApocalipseBr`; override
it for another organization. Session refresh always writes its `STEAM_CONFIG_VDF`
organization secret, so grant the caller access to that same value.
This PR does not change the farming repository.

## Community approaches reviewed

- [RageAgainstThePixel/upload-steam](https://github.com/RageAgainstThePixel/upload-steam)
  documents mobile approval and implements remembered login followed by password
  fallback, then username-only publication. Its
  [authentication source](https://github.com/RageAgainstThePixel/upload-steam/blob/main/src/auth.ts)
  checks the `info` logon state. This publisher uses that confirmation but keeps
  login and upload in the same process, retaining its packaging, secret persistence
  and private-script handling.
- [Steam Workshop Deploy](https://github.com/marketplace/actions/steam-workshop-deploy)
  documents stored SteamCMD config or generated TOTP as alternative approaches.
  This workflow does not require a TOTP seed and continues to use the organization
  secret for the remembered config.

Offline regression tests cover remembered-login success, fresh-login fallback,
missing password, uncertain uploads without retries, failed-login markers and password protection.
Tests run in CI; the first approved login and real Workshop upload still require
an authenticated live run. Mobile approval is supported by the community approach,
but has not yet been verified for this account on the home runner.
