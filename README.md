# sbx-ssh-setup

Provisions an SSH-accessible [`sbx`](https://docs.docker.com/ai/sandboxes/get-started/) sandbox
named after the current directory. Pick the script for your platform.

| Platform      | Setup                | List            | Teardown            |
|---------------|----------------------|-----------------|---------------------|
| macOS / Linux | `sbx_ssh_setup.sh`   | `sbx_list.sh`   | `sbx_teardown.sh`   |
| Windows       | `sbx_ssh_setup.ps1`  | `sbx_list.ps1`  | `sbx_teardown.ps1`  |

## What it does

1. **Preflight:** verifies `sbx` is installed and ≥ 0.35.0, and that Docker is running.
2. Derives the sandbox name from the current directory (sanitized to lowercase, safe characters).
3. On first run only (tracked by `~/.sbx_features_enabled`):
   enables `platform.allowExperimentalFeatures` and `feature.ssh`,
   restarts the `sbx` daemon, and runs `sbx ssh setup`.
4. Creates the sandbox from the chosen AI agent template (required first argument), skipping
   creation if a sandbox with that name already exists.
5. Verifies SSH connectivity, then prints copy-paste-ready Codex values (Display name + Hostname)
   and copies the hostname to the clipboard.

## Requirements

- `sbx` CLI installed and on `PATH` — see [Docker Sandboxes: Get started](https://docs.docker.com/ai/sandboxes/get-started/).
- macOS/Linux: `bash` (macOS also assumes Homebrew at `/opt/homebrew/bin`).
- Windows: PowerShell 5.1+.

## Usage

Run from inside the project directory you want as the sandbox name. Pass the AI agent
template as the first argument (required, e.g. `codex`, `cursor`, `claude`).

**macOS / Linux**
```bash
chmod +x sbx_ssh_setup.sh
./sbx_ssh_setup.sh codex
./sbx_ssh_setup.sh cursor
./sbx_ssh_setup.sh claude
```

**Windows (PowerShell)**
```powershell
# once, if scripts are blocked:
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
.\sbx_ssh_setup.ps1 codex
.\sbx_ssh_setup.ps1 cursor
.\sbx_ssh_setup.ps1 claude
```

Then connect:
```bash
ssh <directory-name>.sbx
```

To re-run the one-time setup: `rm ~/.sbx_features_enabled` (Windows: `del %USERPROFILE%\.sbx_features_enabled`).

## Managing sandboxes

List running sandboxes and their SSH hostnames:
```bash
./sbx_list.sh            # Windows: .\sbx_list.ps1
```

Remove a sandbox and its resources (defaults to the current directory's sandbox):
```bash
./sbx_teardown.sh [name]     # Windows: .\sbx_teardown.ps1 [name]
```
To only stop (keep) a sandbox instead of removing it: `sbx stop <name>`.

## Connecting an agent GUI

Per-agent guides for connecting the desktop UI to the sandbox over SSH:

| Agent  | Guide                          |
|--------|--------------------------------|
| Codex  | [docs/codex.md](docs/codex.md)   |
| Cursor | [docs/cursor.md](docs/cursor.md) |
