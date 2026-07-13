# sbx-ssh-setup

Provisions an SSH-accessible [`sbx`](https://docs.docker.com/) sandbox named after the current
directory. Pick the script for your platform.

| Platform      | Script               |
|---------------|----------------------|
| macOS / Linux | `sbx_ssh_setup.sh`   |
| Windows       | `sbx_ssh_setup.ps1`  |

## What it does

1. Derives the sandbox name from the current directory's basename.
2. On first run only (tracked by `~/.sbx_features_enabled`):
   enables `platform.allowExperimentalFeatures` and `feature.ssh`,
   restarts the `sbx` daemon, and runs `sbx ssh setup`.
3. Creates the sandbox from the `codex` template.
4. Prints the SSH connection command.

## Requirements

- `sbx` CLI on `PATH`.
- macOS/Linux: `bash` (macOS also assumes Homebrew at `/opt/homebrew/bin`).
- Windows: PowerShell 5.1+.

## Usage

Run from inside the project directory you want as the sandbox name.

**macOS / Linux**
```bash
chmod +x sbx_ssh_setup.sh
./sbx_ssh_setup.sh
```

**Windows (PowerShell)**
```powershell
# once, if scripts are blocked:
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
.\sbx_ssh_setup.ps1
```

Then connect:
```bash
ssh <directory-name>.sbx
```

To re-run the one-time setup: `rm ~/.sbx_features_enabled` (Windows: `del %USERPROFILE%\.sbx_features_enabled`).
