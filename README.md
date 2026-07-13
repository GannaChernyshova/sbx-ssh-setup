# sbx-codex

**Give non-technical staff a safe, one-command way to use the OpenAI Codex desktop app —
with the agent running inside a throwaway Docker Sandbox instead of on their laptop.**

`sbx-codex` turns [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/get-started/) (the `sbx`
CLI, v0.35+) into the default way to open a project in Codex. One command creates (or reuses)
exactly one sandbox per project, makes Codex **auto-discover** it over SSH, launches the app, and
hands the user the exact values for the final click. The agent, its file access, and every command
it runs stay *inside* the sandbox — the only shared surface with the machine is the single folder
you pointed at.

```bash
sbx-open codex ~/src/acme-api      # create/reuse a sandbox and open it in Codex
```

Built for a **Director of IT** to deploy to **knowledge workers**: minimal typing, self-diagnosing,
safe by default, deployable via MDM, and nothing that breaks on a Codex auto-update. For the
deployment playbook (Jamf/Intune, signing, secrets, network policy) see
[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

## What's automated (and the one click that isn't)

| Step | Automated? | Notes |
|------|:---------:|-------|
| Create / reuse a per-project sandbox | ✅ | Idempotent; refuses footguns (mounting `$HOME`, orphans, name collisions). |
| Enable the sbx SSH feature (one-time) | ✅ | Done automatically on first run. |
| Make Codex **discover** the sandbox host | ✅ | We add a *concrete* SSH alias — Codex ignores the `Host *.sbx` pattern `sbx` writes. |
| Launch the Codex desktop app | ✅ | Plus the host name + folder path are copied to your clipboard. |
| **Create the remote *project*** | ⚠️ **one manual click** | Codex has no supported CLI/deep-link for this ([openai/codex#21554](https://github.com/openai/codex/issues/21554)). We stop at the app's *New remote project* screen rather than hacking the app's private state file, which breaks on updates. |

The final step is: **New remote project → pick the auto-discovered host → paste the folder → Add
project.** Screenshots: [docs/codex.md](docs/codex.md).

## Install

**macOS / Linux**
```bash
./install.sh            # installs to ~/.local/bin, then runs sbx-doctor
make install            # same thing
```

**Windows (PowerShell)**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

Both installers are idempotent and version-aware — re-run them to upgrade in place. Every command
reports `--version` / `-Version`.

### Least-technical users: double-click launchers

`launchers/` contains **Open in Codex.command** (macOS) and **Open in Codex.bat** (Windows). No
commands to type: double-click (macOS) and drag your project folder in, or drag a folder onto the
`.bat` (Windows). They just wrap `sbx-open`.

## Commands

| Command | What it does |
|---|---|
| `sbx-open [codex] <path>` | The golden path. Create-or-reuse one sandbox per project, make Codex discover it, launch the app. Idempotent. |
| `sbx-doctor` | Health check with ✅/❌ and the exact fix per failure. `--verify` validates the toolkit's host assumptions. |
| `sbx-ls` | Human-friendly sandbox list; flags orphans and stopped sandboxes. |
| `sbx-clean` | Remove orphan/stopped sandboxes **and** prune their SSH aliases (`--dry-run`, `--yes`). |

Windows uses the same names (`sbx-open`, `sbx-doctor`, …) via `.cmd` shims; PowerShell-native flags
use a single dash (`-DryRun`, `-OrphansOnly`).

## Requirements

- `sbx` CLI on `PATH`, v0.35+ — see [Docker Sandboxes: Get started](https://docs.docker.com/ai/sandboxes/get-started/).
- Docker running.
- The **OpenAI Codex desktop app** installed.
- A one-time OpenAI login for the sandbox (Codex runs *inside* it):
  ```bash
  sbx secret set -g openai --oauth
  ```
  `sbx-open` and `sbx-doctor` detect if this is missing and tell you.

## How it stays safe

- **Blast radius = one folder.** Only the path you pass is mounted. `sbx-open` refuses to mount your
  home directory.
- **One sandbox per project**, reused on re-run. Collisions are resolved, not silently merged.
- **No secrets in this repo.** OpenAI/GitHub credentials are `sbx` secrets provisioned per machine.
- **No unsupported hacks.** We never write Codex's private state files.

## Development

```bash
make check      # shellcheck + a hermetic smoke test (stub sbx/ssh/codex — no real Docker)
make help       # list targets
```

On Windows, validate the PowerShell with `Invoke-ScriptAnalyzer -Path win -Recurse`.
