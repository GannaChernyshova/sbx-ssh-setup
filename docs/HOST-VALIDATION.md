# Host validation — 5-minute checklist

This toolkit was authored inside a Docker Sandbox where the real `sbx`, `cursor`, `code`, and `ssh`-to-sandbox were **not available to probe**. Everything uncertain is encoded as a `# VERIFY-ON-HOST` variable in [`lib/sbx-interface.sh`](../lib/sbx-interface.sh). Run this checklist once on a real macOS host after copying the toolkit out of the sandbox — it takes ~5 minutes and confirms (or corrects) every assumption. The VS Code path (real sshd + published loopback port + Remote-SSH) has its own checklist in [`docs/VSCODE-NOTES.md`](VSCODE-NOTES.md).

## Prerequisites

- `sbx` v0.35.0+ installed, daemon running.
- **For the Cursor target only:** SSH-to-sandbox enabled once. SSH is an
  *experimental* sbx feature, so it must be turned on and the daemon restarted
  before the config is written:
  ```bash
  sbx settings set platform.allowExperimentalFeatures true
  sbx settings set feature.ssh true
  sbx daemon stop
  sbx daemon start -d
  sbx ssh setup
  ```
  `sbx-ide doctor` prints these exact steps if the config is missing. If anything
  is off, `sbx diagnose` reports common issues. (The **VS Code** target needs
  none of this — it runs its own sshd on a published loopback port.)
- Cursor installed; `cursor` CLI on PATH (Cursor → Command Palette → "Shell Command: Install cursor command").
- For `--vscode`: VS Code with the `code` CLI on PATH and the **Remote-SSH**
  extension (`ms-vscode-remote.remote-ssh`) installed. A dedicated passwordless
  key (`~/.ssh/sbx-vscode`) is auto-generated on first use — no manual key setup,
  no passphrase, and your GitHub/general key is never used.

## Step 1 — Install & health check (1 min)

```bash
./install.sh
sbx-ide doctor
```
Expect ✅ for sbx version, daemon, SSH config, Cursor CLI. Fix any ❌ using the printed command.

## Step 2 — Auto-verify assumptions (1 min)

```bash
sbx-ide doctor --verify
```
This prints an **expected-vs-detected** report for each assumption below. Every line should say `match`. For any `DIFF`, edit `lib/sbx-interface.sh` (or export the matching `SBX_*` env var) so the detected value wins, then re-run.

| Assumption | Variable | How `--verify` checks it |
|---|---|---|
| Subcommands exist | `SBX_CMD_*` | greps `sbx --help` (create, run, exec, stop, rm, ls) |
| Detached create/wake flag | `SBX_RUN_DETACH_FLAG` (`--detached`) | greps `sbx run --help` |
| Cursor's agent | `SBX_DEFAULT_AGENT` (`shell`) | greps `sbx run --help` (agent list) |
| `sbx ls` column format | (parser) | header has `SANDBOX AGENT STATUS WORKSPACE` |
| SSH host suffix | `SBX_SSH_SUFFIX` (`.sbx`) | reads the `Host *.…` line sbx wrote |
| Mount mirrors host path | `SBX_MOUNT_MIRRORS_HOST` | `sbx exec <name> -- pwd` (or ssh `test -d`) vs host path |
| `rm` force flag *(host-verified)* | `SBX_RM_FORCE_FLAG` (`--force`) | greps `sbx rm --help`; `clean`/`doctor --fix` pass it so a **running/in-use orphan** removes non-interactively |

`sbx-ide doctor --verify` also checks the **VS Code** assumptions: it verifies
the `sbx ports` subcommand exists and flags the rest (Remote-SSH extension id,
loopback publish form, that the kit boots sshd) as `VERIFY-ON-HOST` to validate
manually per [`docs/VSCODE-NOTES.md`](VSCODE-NOTES.md).

## Step 3 — Manual spot-checks the auto-verifier can't fully do (2 min)

1. **Detached create + in-container mount path.** Create a throwaway sandbox
   **detached** (note the `--detached` — a bare `sbx run` would drop you into a
   shell) and check where the workspace lands. The command should return to your
   prompt immediately, with **no shell to exit**:
   ```bash
   sbx run --detached shell --name vtest "$PWD"
   sbx exec vtest -- pwd          # or: ssh vtest.sbx 'pwd; findmnt | grep -i workspace'
   ```
   - If the container path equals the **host path** (`$PWD`), the mirror
     assumption holds — leave `SBX_MOUNT_MIRRORS_HOST=1`.
   - If it's somewhere else (e.g. `/workspace`), set `SBX_MOUNT_MIRRORS_HOST=0`
     and `SBX_FALLBACK_CONTAINER_WS` to that path.
2. **SSH config shape.** Confirm the wildcard host line:
   ```bash
   grep -RniE 'host .*\.sbx' ~/.ssh/config ~/.ssh/config.d 2>/dev/null
   ```
   Adjust `SBX_SSH_SUFFIX` if it isn't `.sbx`.
3. **Clean up:**
   ```bash
   sbx rm vtest        # or: sbx-ide clean
   ```

## Step 4 — Real end-to-end (1 min)

```bash
time sbx-ide open ~/path/to/a/repo
```
`sbx-ide open` should return in a couple of seconds **without dropping you into a
shell to exit** (proves the detached create path), then Cursor opens already
connected to `…sbx` and already in the repo folder. In its terminal, `pwd` must
be your repo path — **not** `/home/agent/workspace`. Re-running on a stopped
project should wake it (no `sbx start: unknown command`).

## Step 4b — VS Code (if you use `--vscode`)

VS Code connects to a **real sshd inside the sandbox** over a **published
loopback port** (not attach, not sandboxd's SSH — see
[`docs/VSCODE-NOTES.md`](VSCODE-NOTES.md) for why). Validate and record findings:

```bash
sbx-ide doctor --target vscode                       # code CLI + Remote-SSH ext + key + kit
sbx-ide open ~/path/to/a/repo --vscode               # create w/ kit, publish port, launch
# then confirm, on the host:
grep -A8 'Host sbx-' ~/.ssh/config                   # the loopback Host block we wrote
ssh sbx-<name> true && echo reachable                # our sshd answers on 127.0.0.1
```

VS Code should open **without a reconnect loop** and land in the workspace. If
the first connect is slow, that's the ~140 MB server download — pre-seeding
(`SBX_VSCODE_PRESEED=1`) mitigates it. `--vscode` must **never** fall back to
sandboxd's SSH; if the sshd/port/key can't be set up, it fails with a pointer to
the notes. On macOS, the launch sets `TMPDIR=/tmp` to dodge the Remote-SSH
unix-socket-path bug — quit VS Code fully before re-launching if it misbehaves.

## Step 5 — Lock it in

If you changed any values, commit `lib/sbx-interface.sh` so the whole team inherits the verified config, and re-run `sbx-ide doctor --verify` to confirm all `match`.

---

### The VERIFY-ON-HOST inventory

Grep the source for the authoritative list at any time:

```bash
grep -n 'VERIFY-ON-HOST' lib/sbx-interface.sh
```
