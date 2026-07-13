# sbx-ssh-setup

Provisions an SSH-accessible [`sbx`](https://docs.docker.com/ai/sandboxes/get-started/) sandbox
named after the current directory. Pick the script for your platform.

| Platform      | Script               |
|---------------|----------------------|
| macOS / Linux | `sbx_ssh_setup.sh`   |
| Windows       | `sbx_ssh_setup.ps1`  |

## What it does

1. Derives the sandbox name from the current directory's basename.
2. On first run only (tracked by `~/.sbx_features_enabled`):
   enables `platform.allowExperimentalFeatures` and `feature.ssh`,
   restarts the `sbx` daemon, and runs `sbx ssh setup`.
3. Creates the sandbox from the chosen AI agent template (required first argument).
4. Prints the SSH connection command.

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
