# sbx-ssh-setup

A convenience script that provisions a [Docker Sandboxes](https://docs.docker.com/) (`sbx`)
sandbox with SSH access enabled, using the current project directory name as the sandbox name.

## What it does

`sbx_ssh_setup.sh` automates the steps needed to spin up an SSH-accessible sandbox:

1. **Ensures Homebrew is on `PATH`** — prepends `/opt/homebrew/bin` so the `sbx` CLI is found
   on Apple Silicon Macs.
2. **Derives the sandbox name** from the current working directory's basename.
3. **Runs one-time setup** (only the first time, tracked via a `~/.sbx_features_enabled` flag file):
   - Enables experimental features (`platform.allowExperimentalFeatures`).
   - Enables the SSH feature (`feature.ssh`).
   - Restarts the `sbx` daemon so the new features take effect.
   - Runs `sbx ssh setup` to configure SSH.
4. **Creates the sandbox** from the `codex` template with the derived name.
5. **Prints the SSH connection command** for the new sandbox.

On subsequent runs the one-time setup is skipped, so the script just creates the sandbox.

## Requirements

- macOS (the script assumes the Homebrew path `/opt/homebrew/bin`).
- The [`sbx` CLI](https://docs.docker.com/) installed and available.
- Homebrew installed.

## Usage

Run the script from inside the project directory you want to use as the sandbox name:

```bash
cd /path/to/your-project
./sbx_ssh_setup.sh
```

Make sure the script is executable:

```bash
chmod +x sbx_ssh_setup.sh
```

Once it finishes, connect to the sandbox with the command it prints, e.g.:

```bash
ssh your-project.sbx
```

## Notes

- The sandbox name equals the basename of the directory you run the script from.
- To re-run the one-time feature setup, delete the flag file: `rm ~/.sbx_features_enabled`.
