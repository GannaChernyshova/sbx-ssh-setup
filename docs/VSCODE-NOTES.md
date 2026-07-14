# VS Code in a sandbox — mechanism & host validation

`sbx-ide open --vscode` connects VS Code to a sandbox by running a **real
OpenSSH server inside the sandbox**, publishing its port to a host **loopback**
port, and pointing VS Code **Remote-SSH** at `127.0.0.1:<port>`. It does **not**
use Dev Containers attach, and it does **not** use sandboxd's emulated SSH.

> Status: **supported** (validated on a real host: connects and stays up, no
> reconnect loop). The [VERIFY-ON-HOST](#verify-on-host) items are worth
> re-confirming after an `sbx`/VS Code upgrade.

> **Attribution.** This mechanism is adapted from the internal proof-of-concept
> [`DockerSolutionsEngineering/ai.gov.sbx-vscode-ssh`](https://github.com/DockerSolutionsEngineering/ai.gov.sbx-vscode-ssh)
> by **@philippecharriere494** — specifically the `01-remote-ssh` (kit installs
> sshd at boot) and `06-better-remote-ssh` (template-baked) demos. The kit, the
> `--detached` requirement, the proxy-env sync, the server/extension pre-seed,
> and the macOS `TMPDIR` fix all originate there. sbx-ide packages that approach
> behind `sbx-ide open --vscode` with a dedicated auto-generated key, guards,
> and clean teardown.

## What we ruled out (and why)

**Dev Containers "attach to running container" — impossible here.** sbx
sandboxes are **microVMs**, not Docker containers. `docker ps` on the host shows
nothing to attach to, and the `vscode-remote://attached-container+…` scheme
requires a real container. Confirmed on host (microVM, empty `docker ps`).

**VS Code Remote-SSH over sandboxd's `*.sbx` endpoint — retry-loops.**
sandboxd's SSH is emulated: it services each `direct-tcpip` port-forward channel
by running a fresh `docker exec` of a helper inside the sandbox (~0.5 s per
channel, `ExecCreate`+`ExecAttach`). Interactive ssh / one-shot / SFTP don't
notice (Claude Code, Codex, and Cursor's single keepalive tunnel all work). But
VS Code Remote-SSH puts the VS Code server on a **random TCP port that is
forwarded back to the client as its primary channel**, and re-opens that forward
on every reconnect — so the ~0.5 s lands on the connection's critical path, VS
Code decides the link is dead, and reconnects every ~5 s. This is structural.

## The mechanism (works because it uses neither)

`sbx-ide open --vscode`:

1. **Creates the sandbox with the bundled `remote-ssh` kit** (`kits/remote-ssh/`,
   a `kind: mixin`), which installs and starts a **real `sshd`** on `:22` inside
   the sandbox and syncs sandboxd's proxy env so Claude auth still works.
2. **Injects a dedicated public key** as the `agent` user's `authorized_keys`
   (key-only auth). By default this is a **passwordless key created just for
   sbx-ide** (`SBX_VSCODE_SSH_KEY`, default `~/.ssh/sbx-vscode`), generated on
   first use — your general/GitHub key is never injected. The `~/.ssh/config`
   block pins it with `IdentityFile` + `IdentitiesOnly yes`, so only this key is
   ever offered to the sandbox.
3. **Publishes `:22` to a host loopback port**: `sbx ports <name> --publish
   127.0.0.1:<port>:22/tcp` (loopback only — never reachable off your machine).
4. **Writes a `~/.ssh/config` Host block** for `sbx-<name>` (inside
   `# sbx-ide ssh BEGIN/END` markers) pointing at `127.0.0.1:<port>` with
   keepalives and loopback-appropriate host-key handling.
5. **Launches** `code --remote "ssh-remote+sbx-<name>" <workspace>`.

VS Code is now talking to a **real sshd over a real TCP port**, where opening a
channel is sub-millisecond — the exec-per-channel cost simply isn't in the path.

### Details that matter (all handled)

- **`--detached` is mandatory** — otherwise sbx auto-stops the sandbox ~30 s
  after the last exec and kills the long-lived Remote-SSH session.
- **macOS TMPDIR bug** (vscode-remote-release #11672/#11676): the default long
  `$TMPDIR` overflows the 104-char unix-socket path → reconnect loop. We launch
  `code` with `TMPDIR=/tmp`. (Only affects a freshly launched editor — quit VS
  Code fully first if it's already open.)
- **Proxy env**: the kit re-exports `HTTP(S)_PROXY`/CA vars into
  `/etc/sandbox-persistent.sh` so SSH sessions (and Claude) reach the proxy.
- **Server/extension pre-seed** (`SBX_VSCODE_PRESEED=1`, default on): the first
  connect otherwise downloads ~140 MB of VS Code server over the sandbox proxy
  and can loop; we pre-fetch the server for the host's exact commit and
  pre-install the workspace's recommended extensions. Best-effort, never fatal.
- **Dedicated passwordless key (no passphrase prompts, ever).** By default
  sbx-ide generates and uses `~/.ssh/sbx-vscode` — a key scoped to this tool
  with no passphrase — so `BatchMode` auth just works: no `ssh-agent`, no
  prompts, and your GitHub/general key stays out of the sandbox. Override with
  `SBX_VSCODE_SSH_KEY=<path>` (or `SBX_VSCODE_AUTOGEN_KEY=0` to require an
  existing key). If you *do* point it at a passphrase-protected key, the probe
  still separates auth-miss from outage: TCP port open ⇒ warn (`ssh-add …`) and
  proceed (VS Code prompts); port closed ⇒ hard failure.
- **The sandbox must be created WITH the kit.** `--kit` applies only at create
  time, so a sandbox made before `--vscode` (or by another tool) has no sshd.
  `open --vscode` detects this (the kit's sshd drop-in is absent) and tells you
  to recreate it (`sbx rm --force <name> && sbx-ide open <ws> --vscode`) rather
  than failing cryptically. It never removes the sandbox for you.
- **Getting an agent into VS Code.** Unlike Cursor, vanilla VS Code has no
  built-in agent, so a plain `shell` sandbox gives you an isolated editor but no
  in-box AI. Point the sandbox at an sbx agent to fix that:
  `sbx-ide set-default --agent claude --vscode` (or `--agent <name>` per run) —
  then the sandbox runs that agent and it's available in the VS Code terminal.
  Alternatively install an agent extension (Copilot, Continue, …) into the
  remote server. The agent applies on **create**; recreate to change it. The
  VS Code terminal stays a plain shell (we don't auto-launch the agent, so
  exiting it lands you back in the shell); a login banner names the command to
  start it (e.g. `claude`).
- **No fallback.** If the key is missing, the port can't be published, or our
  sshd's port never opens, `open --vscode` fails with an explanation — it never
  silently drops to sandboxd's SSH.

### Mirror of the Cursor launch style

Both targets launch with an SSH-remote folder identity; they differ only in
*which* SSH endpoint:

| Target | Launch | SSH endpoint |
|---|---|---|
| **Cursor** | `cursor --folder-uri "vscode-remote://ssh-remote+<name>.sbx<path>"` | sandboxd's emulated `*.sbx` (one stable keepalive tunnel — fine for Cursor) |
| **VS Code** | `code --remote "ssh-remote+sbx-<name>" <path>` | a **real sshd** in the sandbox via a published loopback port |

## Security surface (for the platform/security reader)

- The published port binds **`127.0.0.1` only** — the sandbox's sshd is not
  reachable from other machines.
- Auth is **key-only** (`PasswordAuthentication no`, `AllowUsers agent`), and
  the client offers **only** the dedicated `~/.ssh/sbx-vscode` key
  (`IdentitiesOnly yes`) — your other keys are never presented to the sandbox.
- The `~/.ssh/config` block uses `StrictHostKeyChecking no` +
  `UserKnownHostsFile /dev/null` — appropriate because the link is loopback-only
  and the sandbox regenerates host keys on each create. Every block is wrapped in
  `# sbx-ide ssh BEGIN/END <alias>` markers so `sbx-ide clean` and `make
  uninstall` can find and remove exactly what we wrote — and nothing else
  (sbx's own `*.sbx` wildcard block is never touched).

## <a id="verify-on-host"></a>VERIFY-ON-HOST

Encoded as `SBX_*` variables in `lib/sbx-interface.sh` (override via env):

- [ ] **`sbx ports … --publish 127.0.0.1:<port>:22/tcp`** binds loopback only and
  maps to the sandbox's `:22`. (`sbx_publish_ssh_port` / `sbx_published_ssh_port`
  parse `sbx ports <name>` — confirm its output format.)
- [ ] **`sbx run <agent> --kit <dir>`** attaches the mixin and boots `sshd`
  (`ssh sbx-<name> true` succeeds within ~10 s). Confirm the kit works with the
  configured agent (`SBX_DEFAULT_AGENT`, default `shell`).
- [ ] **Remote-SSH extension id** is `ms-vscode-remote.remote-ssh`
  (`SBX_VSCODE_EXT`); confirm with `code --list-extensions`.
- [ ] **`sbx exec --env … <name> -- sh -c …`** injects the key (flags precede the
  name).
- [ ] **macOS TMPDIR fix** is still needed for your VS Code version.

## Findings log

**2026-07-14 — macOS.** sbx v0.35.x (SSH-to-sandbox), default `shell` agent.
_(Exact `sbx version` and VS Code/Remote-SSH build not captured — worth pinning on the next run.)_

**WORKS**
- A fresh sandbox created with the bundled `remote-ssh` kit boots a real `sshd`
  on `:22` (`pgrep -ax sshd` shows the listener), we publish it to
  `127.0.0.1:<port>`, and `code --remote ssh-remote+sbx-<name> <ws>` **connects
  and stays connected — no ~5 s reconnect loop.** This is the whole win over
  sandboxd's emulated SSH.
- Kit applied cleanly: `/etc/ssh/sshd_config.d/10-sbx-ide.conf` present,
  `~/.ssh/authorized_keys` written (mode 600), proxy-env synced.
- `sbx ports <name> --publish 127.0.0.1:<port>:22/tcp` binds loopback and shows
  as `127.0.0.1  <port>  22  tcp`; our parser reads it back for reuse.
- The dedicated auto-generated passwordless key (`~/.ssh/sbx-vscode`), pinned via
  `IdentityFile`/`IdentitiesOnly`, gives promptless `BatchMode` auth — no agent,
  no passphrase, and the user's GitHub key never enters the sandbox.

**CAVEATS**
- **First connect downloads ~140 MB** of VS Code server into the sandbox (slow
  behind the egress proxy). Pre-seeding (`SBX_VSCODE_PRESEED=1`, default) helps.
- **macOS `TMPDIR`**: the launch sets `TMPDIR=/tmp` to avoid the unix-socket-path
  reconnect bug (vscode-remote-release #11672/#11676). Only helps a *freshly*
  launched editor — quit VS Code fully first if it's already open.
- **A sandbox must be created WITH the kit.** `--kit` applies only at create
  time, so one made before `--vscode` (or by another tool) has no sshd; sbx-ide
  detects this and asks you to recreate it.
- **Passphrase keys**: the original attempt used a passphrase-protected GitHub
  key not in `ssh-agent`, which failed the `BatchMode` probe even though the
  connection was fine. Fixed two ways — the connection-vs-auth fallback, and
  (default) the dedicated passwordless key above.
- `ss`/`netstat` aren't in the sandbox image (diagnostics only; `pgrep`/`/proc`
  work).
- Default `shell` agent worked with the `kind: mixin` kit; the source PoC used
  the `claude` agent for its credential wiring, which our proxy-env sync covers.

**DOESN'T WORK (and why)**
- **Dev Containers attach** — sbx sandboxes are **microVMs**; there is no Docker
  container to attach to (host-confirmed: `docker ps` empty).
- **Remote-SSH over sandboxd's `*.sbx`** — retry-loops (~0.5 s `docker exec` per
  forwarded channel lands on VS Code's primary port-forward every reconnect).
