# Host validation — 5-minute checklist

This toolkit was authored inside a Docker Sandbox where the real `sbx`, `cursor`, and `ssh`-to-sandbox were **not available to probe**. Everything uncertain is encoded as a `# VERIFY-ON-HOST` variable in [`lib/sbx-interface.sh`](../lib/sbx-interface.sh). Run this checklist once on a real macOS host after copying the toolkit out of the sandbox — it takes ~5 minutes and confirms (or corrects) every assumption.

## Prerequisites

- `sbx` v0.35+ installed, daemon running.
- SSH-to-sandbox enabled once (there is **no** `sbx config` command; use the real
  `setup`/`ssh` subcommands — confirm exact flags with `sbx setup --help` /
  `sbx ssh --help`):
  ```bash
  sbx setup      # detect host config and prepare Docker Sandboxes  # VERIFY flags
  sbx ssh        # configure SSH access to sandboxes (experimental) # VERIFY flags
  ```
  If anything is off, `sbx diagnose` reports common issues.
- Cursor installed; `cursor` CLI on PATH (Cursor → Command Palette → "Shell Command: Install cursor command").

## Step 1 — Install & health check (1 min)

```bash
./install.sh
sbx-doctor
```
Expect ✅ for sbx version, daemon, SSH config, Cursor CLI. Fix any ❌ using the printed command.

## Step 2 — Auto-verify assumptions (1 min)

```bash
sbx-doctor --verify
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
   sbx rm vtest        # or: sbx-clean
   ```

## Step 4 — Real end-to-end (1 min)

```bash
time sbx-open ~/path/to/a/repo
```
`sbx-open` should return in a couple of seconds **without dropping you into a
shell to exit** (proves the detached create path), then Cursor opens already
connected to `…sbx` and already in the repo folder. In its terminal, `pwd` must
be your repo path — **not** `/home/agent/workspace`. Re-running on a stopped
project should wake it (no `sbx start: unknown command`).

## Step 5 — Lock it in

If you changed any values, commit `lib/sbx-interface.sh` so the whole team inherits the verified config, and re-run `sbx-doctor --verify` to confirm all `match`.

---

### The VERIFY-ON-HOST inventory

Grep the source for the authoritative list at any time:

```bash
grep -n 'VERIFY-ON-HOST' lib/sbx-interface.sh
```
