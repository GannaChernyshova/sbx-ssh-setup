# Connecting the Codex UI to a sandbox

Connect the Codex desktop app to an `sbx` sandbox over SSH, so Codex runs against the
sandboxed workspace as a Remote Project.

> **One sandbox per project.** Before creating a Remote Project in Codex, start a dedicated
> sandbox for that project, add it as an SSH connection, then associate it with the project.

## Prerequisites

- `sbx` 0.35.0+

## One-time — authenticate with OpenAI (SSO)

Codex needs OpenAI credentials to run in the sandbox. Authenticate **once per machine** with your
OpenAI SSO account (global secret, shared by every sandbox):

```bash
sbx secret set -g openai --oauth
```

This opens a browser to complete SSO login. You only need to do this once; you don't repeat it per
project. (If Codex connects but nothing happens when you run a task, this step was skipped.)

## Step 1 — Create the sandbox

`sbx_ssh_setup.sh` / `sbx_ssh_setup.ps1` handles everything in one call: on first run it enables
the SSH feature (`platform.allowExperimentalFeatures`, `feature.ssh`), restarts the daemon, and
runs `sbx ssh setup` (once); on every run it creates the sandbox for the chosen agent.

From your project directory, run it with the `codex` agent:

```bash
cd <your-project>
./sbx_ssh_setup.sh codex        # Windows: .\sbx_ssh_setup.ps1 codex
```

The sandbox is named after the directory (sanitized to lowercase). Besides creating the sandbox and
verifying SSH connectivity, the script now also:

- **Registers the SSH connection for you.** It writes a concrete `Host <sandbox-name>.sbx` alias
  into `~/.ssh/config` (Codex only reads *concrete* aliases and ignores the pattern-only
  `Host *.sbx` that `sbx` manages), then opens the Codex deep link
  `codex://settings/connections/ssh/add?name=<sandbox-name>.sbx` so the app adds/enables the
  connection without a manual Refresh. Connection settings are still inherited from the
  `sbx`-managed block via `ssh -G` — nothing is duplicated.
- **Pre-provisions the project directory** inside the sandbox (the same directory the sandbox was
  started from) and copies its exact remote path to your clipboard for Step 3.

You can also verify connectivity manually:

```bash
ssh <sandbox-name>.sbx
```

## Step 2 — The SSH connection is added automatically

You don't need **Add → Add manually** anymore. The script registers the connection via the Codex
deep link, so `<sandbox-name>.sbx` appears under **Settings → Connections**. If it isn't listed yet,
open the deep link the script printed (`codex://settings/connections/ssh/add?name=<sandbox-name>.sbx`)
or click **Refresh**. (The deep-link name must match the `Host` alias in `~/.ssh/config`, which the
script guarantees.)

![Add SSH connection dialog](images/codex-add-ssh-connection.png)

## Step 3 — Create a Remote Project

Create a new project and choose the **Remote** project type:

![Create project — Remote](images/codex-create-project-remote.png)

Select the auto-discovered `<sandbox-name>.sbx` connection as the remote host, then set the **Folder
path** to your project directory inside the sandbox. Click **Add project**, then start coding.

> **The folder path can't be pre-filled — paste it.** The script copies the correct remote path to
> your clipboard, so in the **Folder path** field just press **⌘V** (macOS) / **Ctrl+V** (Windows).
> See the blocker below for why this one field stays manual.

![New remote project dialog](images/codex-new-remote-project.png)

### What the Folder path should be

On **macOS/Linux**, the sandbox mounts the directory you started it from at its **original absolute
path** inside the sandbox. So if you ran `./sbx_ssh_setup.sh codex` in `/Users/you/src/acme-api`,
the folder to enter is `/Users/you/src/acme-api` — **not** the `/home/<user>` that the picker opens
on by default (that is just the remote home directory). The script pre-creates this directory in the
sandbox and copies its path to your clipboard.

On **Windows**, the host path is a `C:\…` path that does not exist inside the Linux sandbox, so the
script can't map it to the remote mount automatically. It reports the sandbox's default directory
and copies it instead; browse from there to your mounted project folder when creating the project.

## Known limitation / blocker — the project folder is not automatable

Everything up to opening the project is automated (sandbox, SSH alias, connection registration via
the `codex://` deep link, and pre-provisioning + copying the workdir path). **The one manual step
that remains is entering the Folder path when creating the Remote Project**, because:

- The Codex desktop app exposes **no supported CLI, app-server method, or documented config** to
  register or open a remote project (including its folder) from automation. This is an open request:
  [openai/codex#21554](https://github.com/openai/codex/issues/21554).
- The only "workaround" is seeding `~/.codex/.codex-global-state.json` (keys like `remote-projects`,
  `active-remote-project-id`). That file is **undocumented, app-version-sensitive, and rewritten by
  Codex from memory while it is running** — it drops externally inserted entries. We deliberately do
  **not** do this: it is a fragile hack that breaks on Codex updates.
- There is also **no deep-link parameter for the folder** (the `codex://…/connections/ssh/add` deep
  link only takes a connection `name`).

**Consequence:** creating a project is a two-action step — pick the (already-listed) connection, then
paste the folder path (⌘V / Ctrl+V) and click **Add project**. If OpenAI ships a supported project
API on #21554, we can close this gap and make it fully hands-off.

## Working with multiple projects

Repeat the flow per project — one sandbox each. Each run registers its own SSH connection, so the
only manual step left in Codex is creating the Remote Project:

```
Create project → Start a new sbx → Create Remote Project (connection is already there) → Start coding
```

1. Navigate to the new project directory.
2. Start a new sandbox (`./sbx_ssh_setup.sh codex`) — this registers the connection and prepares
   the workdir.
3. In Codex, create a new Remote Project and pick the auto-discovered `<sandbox-name>.sbx`
   connection (Refresh **Settings → Connections** if needed).

To remove a sandbox and its Codex connection later, use `./sbx_teardown.sh` (it also strips the
`~/.ssh/config` alias it added).
