# Connecting the Codex UI to a sandbox

Connect the Codex desktop app to an `sbx` sandbox over SSH, so Codex runs against the
sandboxed workspace as a Remote Project.

> **One sandbox per project.** Before creating a Remote Project in Codex, start a dedicated
> sandbox for that project, add it as an SSH connection, then associate it with the project.

## Prerequisites

- `sbx` 0.35.0+
- SSH feature enabled. `sbx_ssh_setup.sh` / `sbx_ssh_setup.ps1` does this for you on first run
  (enables `platform.allowExperimentalFeatures` and `feature.ssh`, restarts the daemon, and runs
  `sbx ssh setup`). `sbx ssh setup` only needs to run once.

## Step 1 — Create the sandbox

From your project directory, run the setup script with the `codex` agent:

```bash
cd <your-project>
./sbx_ssh_setup.sh codex        # Windows: .\sbx_ssh_setup.ps1 codex
```

The sandbox is named after the directory. Verify SSH connectivity:

```bash
ssh <sandbox-name>.sbx
```

## Step 2 — Add the sandbox as an SSH connection in Codex

In Codex, open **Settings → Connections → Add → Add manually**, then configure:

- **Display name:** any friendly name
- **Hostname:** `<sandbox-name>.sbx`

Save the connection.

## Step 3 — Create a Remote Project

Create a **New Remote Project**, select the SSH connection from Step 2, and choose the project
directory inside the sandbox. Then start coding.

## Working with multiple projects

Repeat the flow per project — one sandbox each:

```
Create project → Start a new sbx → Add SSH connection in Codex → Create Remote Project → Start coding
```

1. Navigate to the new project directory.
2. Start a new sandbox (`./sbx_ssh_setup.sh codex`).
3. Add the sandbox as a new SSH connection in Codex.
4. Create a new Remote Project using that connection.
