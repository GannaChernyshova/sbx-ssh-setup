# Deployment guide (for IT admins)

This is the playbook for rolling `sbx-codex` out to non-technical staff at scale. It covers the
trust model, silent/MDM install, credential and network provisioning, upgrades, and a support
runbook so the toolkit deflects tickets instead of creating them.

## What you're deploying, and why it's safe

Staff use the **OpenAI Codex desktop app**, but the agent runs inside a **Docker Sandbox** on their
own machine rather than directly on the laptop. `sbx-codex` is a thin, auditable layer of shell /
PowerShell scripts (no binaries, no telemetry, no network calls of its own) that wires the two
together.

- **Blast radius = one folder.** Only the project directory a user opens is mounted into the
  sandbox. `sbx-open` refuses to mount a home directory.
- **No secrets in the toolkit.** OpenAI and GitHub credentials are provisioned as `sbx` secrets on
  each machine (below). The scripts only *detect* whether they exist.
- **No unsupported hacks.** The toolkit automates only officially supported surfaces. It never edits
  Codex's private state (`~/.codex/.codex-global-state.json`), which OpenAI overwrites and changes
  between versions — so a Codex auto-update cannot silently break a deployed fleet.
- **Reviewable.** Everything is plain text. `make check` (macOS/Linux) and
  `Invoke-ScriptAnalyzer -Path win -Recurse` (Windows) run in your own CI before you sign off.

## Per-machine prerequisites

Provision these once per machine (via your MDM, or a first-run script):

1. **Docker** (Desktop or Engine) installed and running.
2. **`sbx` CLI** v0.35+ on `PATH` — see
   [Docker Sandboxes: Get started](https://docs.docker.com/ai/sandboxes/get-started/).
3. **OpenAI Codex desktop app** installed.
4. **OpenAI login for the sandbox** (Codex runs *inside* it). One interactive login per machine,
   shared by all sandboxes:
   ```bash
   sbx secret set -g openai --oauth
   ```
   This opens a browser for SSO, so it is user-driven; surface it in your onboarding doc.
   `sbx-doctor` reports if it's missing.
5. *(Only if users open private Git repos over HTTPS in the sandbox)* a GitHub token secret:
   ```bash
   sbx secret set -g github -t "$(gh auth token)"
   ```

## Installing the toolkit

The installers are idempotent and version-aware — the same command installs and upgrades.

### macOS / Linux (Jamf, or any script runner)

```bash
# Run as the target user (installs to ~/.local/bin). For a shared prefix:
sudo PREFIX=/usr/local /path/to/sbx-codex/install.sh
```

Non-interactive by design: it makes no prompts and only fails on a real copy error (a failing
`sbx-doctor` is reported but does not fail the install). To pin a version, deploy a specific tag/commit
of this repo.

### Windows (Intune / SCCM)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

Installs to `%LOCALAPPDATA%\Programs\sbx-codex` and adds it to the user `PATH`. For a system-wide
install, pass `-Prefix 'C:\Program Files\sbx-codex'` and add that directory to the machine `PATH` via
policy. Uninstall with `install.ps1 -Uninstall`.

### Code signing — read this before packaging

`sbx-codex` ships as **scripts**, not signed binaries. If you repackage them as a `.pkg`/`.dmg`
(macOS) or `.msi`/`.exe` (Windows) for MDM, the notarization/Authenticode certificates must be **your
organization's own** — this project cannot provide them. Unsigned packages trigger Gatekeeper /
SmartScreen prompts that confuse non-technical users and generate tickets, so sign with your
enterprise identity as part of your packaging pipeline. Distributing the scripts directly (e.g. via a
managed folder + the installer) avoids the packaging-signature question entirely.

## Network policy for data feeds

Staff building against data feeds will need the sandbox to reach those endpoints. Sandboxes are
default-deny; allow the specific domains on each host:

```bash
sbx policy allow network api.internal.example.com,feeds.example.com
sbx policy log     # inspect what got blocked and why
```

Keep the allow-list tight (named domains, not `**`) so the blast-radius argument holds.

## Upgrades

Pull the latest source and re-run the installer (`./install.sh` / `install.ps1`); it reports the
version bump and overwrites in place. Roll out through your normal MDM update ring. Because the SSH
alias approach is version-independent, a Codex app update requires no action from you.

## Verifying the toolkit against your real `sbx`

A handful of `sbx` CLI details are encoded as assumptions tagged `# VERIFY-ON-HOST` in
`lib/sbx-interface.sh`. On one representative machine, after a first `sbx-open` run:

```bash
sbx-doctor --verify     # expected-vs-detected report for every assumption
```

If anything shows `DIFF`, set the matching `SBX_*` environment variable in your deployment (or edit
the lib) so the detected value is used, then re-verify. This is a five-minute, one-time check per
`sbx` release.

## Support runbook (give this to your help desk)

| Symptom | First check | Fix |
|---|---|---|
| "It won't connect" / any error | `sbx-doctor` | Follow the exact fix printed next to each ❌. |
| Host not listed in Codex | `sbx-doctor`, then re-run `sbx-open <path>` | Re-adds the concrete SSH alias. |
| Codex connects but tasks do nothing | `sbx-doctor` (OpenAI secret) | `sbx secret set -g openai --oauth` |
| Sandbox unreachable right after create | wait ~10s, re-run `sbx-open` | It was still starting. |
| A data feed / URL is blocked | `sbx policy log` | `sbx policy allow network <domain>` |
| Too many old sandboxes (disk/compute) | `sbx-ls` | `sbx-clean` (removes orphan/stopped + prunes SSH aliases) |
| Private repo won't clone in sandbox | — | `sbx secret set -g github -t "$(gh auth token)"` |

`sbx-clean` doubles as cost hygiene: orphan and stopped sandboxes hold resources; a scheduled
`sbx-clean --stopped --yes` (or `-Stopped -Yes` on Windows) keeps machines tidy.
