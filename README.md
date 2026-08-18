# sbx-ssh-setup

Provisions an SSH-accessible [`sbx`](https://docs.docker.com/ai/sandboxes/get-started/) sandbox
named after the current directory. Pick the script for your platform.

| Platform      | Setup                | List            | Teardown            |
|---------------|----------------------|-----------------|---------------------|
| macOS / Linux | `sbx_ssh_setup.sh`   | `sbx_list.sh`   | `sbx_teardown.sh`   |
| Windows       | `sbx_ssh_setup.ps1`  | `sbx_list.ps1`  | `sbx_teardown.ps1`  |

## What it does

1. **Preflight:** verifies `sbx` is installed and ≥ 0.38.0, and that Docker is running.
2. Derives the sandbox name from the current directory (sanitized to lowercase, safe characters).
3. On first run only (tracked by `~/.sbx_0_38_setup_complete`), runs `sbx login`, authenticates
   OpenAI with `sbx secret set openai --oauth`, and configures SSH with `sbx setup ssh`.
4. Creates the sandbox from the chosen AI agent template (required first argument), skipping
   creation if a sandbox with that name already exists.
5. Verifies SSH connectivity.
6. Registers a concrete `Host <name>.sbx` alias in `~/.ssh/config`, then opens Codex's supported
   SSH-add deep link so Codex imports the connection. Settings are inherited from the
   `sbx`-managed `Host *.sbx` block, so nothing is duplicated. Codex imports the host with
   automatic connection disabled, as documented in the
   [official deep-link reference](https://developers.openai.com/codex/reference/commands#settings).
7. Pre-provisions the project directory inside the sandbox (the sandbox's start directory) and
   copies its remote path to the clipboard — paste it as the folder when creating the Codex
   Remote Project.

The teardown scripts remove that `~/.ssh/config` alias when they remove the sandbox.

> **Known limitation:** in the Codex desktop app the sandbox, SSH connection and workdir are all
> automated, but the **project's Folder path must be entered manually** when creating the Remote
> Project (paste it — the script copies it to your clipboard). Codex has no supported way to register
> a remote project or its folder from automation ([openai/codex#21554](https://github.com/openai/codex/issues/21554)),
> and we deliberately avoid the fragile `~/.codex/.codex-global-state.json` hack. See
> [docs/codex.md](docs/codex.md#known-limitation--blocker--the-project-folder-is-not-automatable).

## Requirements

- `sbx` CLI installed and on `PATH` — see [Docker Sandboxes: Get started](https://docs.docker.com/ai/sandboxes/get-started/).
- An OpenSSH client (`ssh`) installed and on `PATH`.
- macOS/Linux: `bash` (macOS also assumes Homebrew at `/opt/homebrew/bin`).
- Windows: PowerShell 5.1+.

The first setup run is interactive: `sbx login` and OpenAI OAuth may open a browser and wait for
you to finish authentication. The completion marker is created only after all three one-time
commands succeed.

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

To re-run login, OpenAI OAuth, and SSH setup, remove `~/.sbx_0_38_setup_complete` (Windows:
`del %USERPROFILE%\.sbx_0_38_setup_complete`) and run the setup script again.

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

| Agent  | Guide                        |
|--------|------------------------------|
| Codex  | [docs/codex.md](docs/codex.md) |
