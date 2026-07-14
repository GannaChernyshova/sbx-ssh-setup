# Sandboxes for your IDE at Enterprise Scale

The rules for running your IDE — Cursor, or VS Code via Dev Containers attach — (and its autonomous agents) inside Docker Sandboxes. Opinionated on purpose. Each rule is one line with its reason.

> **Core idea:** the sandbox's *mount* is the entire shared surface with your machine. Everything else — the rest of your filesystem, your keychain, your SSH keys, other repos — is invisible to the IDE and its agents, because the editor server itself runs inside the container. Isolation is what lets you safely say "yes to everything."

---

## Part 1 — For developers

### The golden path

```bash
sbx-ide open /path/to/repo            # by path
cd /path/to/repo && sbx-ide open ./   # or from inside the project
```

That's it. It creates (or reuses) one sandbox for that repo, verifies connectivity, and opens your IDE already connected to the right folder. Prefer VS Code? Add `--vscode` (or set it as your default — see below).

### Rules

1. **One sandbox per project.** — Clean blast radius, clean lifecycle; no cross-project contamination.
2. **Mount the repo, nothing wider.** Never mount `$HOME` or a parent of many repos. — The mount *is* the blast radius; a wide mount hands the agent everything under it. (`sbx-ide open` refuses to mount `$HOME`.)
3. **Always start from `sbx-ide open`.** — It picks the right existing sandbox and won't create an orphan.
4. **"Run everything" / auto-run is fine — inside a sandbox.** — Worst case the agent can only touch the mounted dir; it cannot reach your host FS, credentials, or other projects.
5. **`sbx-ide open` creates the sandbox detached; Cursor attaches over SSH.** You are never dropped into the agent shell first. — `sbx-ide open` runs `sbx run --detached` so control returns immediately, then launches Cursor; the agent `shell` is not your interactive session. (A bare `sbx run <agent>` *does* attach an interactive shell — don't use it to open projects.)
6. **Cursor and your terminals share one container.** `ssh <name>.sbx` drops you into the *same* environment the agent sees. — Reproduce and debug exactly what the agent did; installed packages and processes are shared.
7. **Let the workspace be the source of truth.** Edits under the mount appear on the host immediately (it's a read-write bind mount). — Commit and push from inside the sandbox like normal.
8. **Clean up.** Run `sbx-ide clean` periodically; reopen anytime with `sbx-ide open <path>`. — Stopped sandboxes keep your files on the host; only the container is discarded.

### Anti-patterns (don't)

- ❌ **Never type a new name into Cursor's "Connect via SSH" box.** — A name that doesn't match an existing sandbox can auto-create an **empty, workspace-less** sandbox; your work lands in a throwaway `/home/agent/workspace` and is lost when it's removed.
- ❌ **Never work in `/home/agent/workspace`.** — That's the sign you're in an orphan sandbox with no host mount. Bail out and use `sbx-ide open`.
- ❌ **Never share one sandbox across unrelated projects.** — Widens blast radius and tangles lifecycle; make a second sandbox instead.
- ❌ **Never mount `~` or `~/src` "to save time."** — You just gave the agent every repo and dotfile you own.

### How do I know I'm safe?

- `sbx-ide ls` — is my sandbox **running** with the **right workspace**? Any `⚠ orphan` rows?
- Inside Cursor's terminal, `pwd` should be your mounted repo path — **not** `/home/agent/workspace`.
- `sbx-ide doctor` — is the whole setup healthy?

---

## Part 2 — For IDE users (no terminal experience needed)

You only need to learn **one command**. Copy-paste is all the terminal skill required.

### Set it once (optional)

If your team uses VS Code, set it as your default one time and never type the flag again:

```
sbx-ide set-default vscode
```

(Cursor is the default out of the box, so Cursor users can skip this.)

### 5-step quickstart

**1. One-time setup (ask IT or a teammate to run this once).**
   Your machine needs the `sbx` tools installed and connectivity turned on. Running `sbx-ide doctor` shows a checklist of ✅/❌ with the exact fix for anything red.

**2. Find your project folder.**
   In Finder, right-click the project folder → "New Terminal at Folder" (macOS). A terminal opens already pointing at your project.

**3. Type this and press Enter:**
   ```
   sbx-ide open ./
   ```
   *(The `./` means "this folder I'm in.")*

**4. Wait a few seconds.** Your IDE opens by itself, already connected to a safe, isolated copy of your environment. The title bar shows something ending in `.sbx` (Cursor) or an "attached container" indicator (VS Code) — that's how you know you're in the sandbox.

**5. Work normally.** Prompt the agent, let it run commands, accept its changes. It can only touch **this one project folder** — nothing else on your computer. When you're done, just close the window.

### The one thing to never do

> 🚫 **Do not** click "Connect to Host…" in your IDE and type a made-up name. That can create an empty workspace where your work won't be saved. **Always** open projects with `sbx-ide open`.

If you ever see your files are missing or the folder path contains `/home/agent/workspace`, close the window and run `sbx-ide open ./` again from your project folder.

---

## Part 3 — For platform & security teams

### What the sandbox guarantees

- **Process & filesystem isolation.** Cursor's server, agents, and terminals run inside the container. The host filesystem, keychain/credentials, environment, and other repos are **not** visible — even with auto-run enabled.
- **Explicit, single shared surface.** Exactly one host directory (the workspace mount) is exposed. Blast radius = that directory.
- **Network egress is limited to what `sbx` provides.** Don't assume general outbound access from inside a sandbox.

### What it does *not* guarantee

- **The mount is read-write to the host.** An agent can modify/delete anything under the mounted directory, and changes hit the host immediately. Mount narrowly; keep the repo in version control.
- **Not a security boundary against a determined kernel-level attacker.** It's container isolation, not a hardened VM/hypervisor. Treat it as strong workflow isolation, not a malware detonation chamber.
- **SSH-to-sandbox is local-only.** Sandboxes are reachable from *this host* via the SSH config `sbx setup ssh` writes (a wildcard `Host *.sbx` + ProxyCommand). They are not remote-accessible, and they do **not** appear in the IDE's host picker — they must be launched via `sbx-ide open`/CLI.
- **The VS Code target runs an sshd inside the sandbox and publishes it to `127.0.0.1` only.** `sbx-ide open --vscode` starts a real OpenSSH server in the sandbox (needed because sbx microVMs can't use Dev Containers attach, and VS Code Remote-SSH retry-loops over sandboxd's emulated SSH — see [`VSCODE-NOTES.md`](VSCODE-NOTES.md)). Auth is **key-only**, the port binds **loopback only** (never reachable off the machine), and the `~/.ssh/config` block is wrapped in `# sbx-ide ssh` markers so `sbx-ide clean` / `make uninstall` remove exactly what was added. Cursor needs none of this.

### Policy

- **Version pinning.** Require `sbx >= 0.35` (SSH-to-sandbox support). Pin a known-good version org-wide; the SSH feature is **experimental** (`sbx ssh` is marked experimental in `sbx --help`) — track changes across upgrades and re-run `sbx-ide doctor --verify` after each.
- **Validate assumptions per version.** This toolkit isolates uncertain CLI details behind `# VERIFY-ON-HOST` variables in `lib/sbx-interface.sh`; run `sbx-ide doctor --verify` after any `sbx` upgrade to catch flag/format drift.
- **Naming convention.** One sandbox per repo, named after the repo (`sbx-ide open` derives and sanitizes this, suffixing `-2`, `-3` on collision). Discourage hand-named sandboxes.
- **Lifecycle.** Clean stopped/orphan sandboxes after **N days** (suggest 7). `sbx-ide clean` is safe to run on a schedule with `--yes`; stopped sandboxes' host files are never deleted.
- **Onboarding.** Ship `sbx-cursor` + this rulebook. `sbx-ide doctor` is the paved-road health check; make a green `sbx-ide doctor` a prerequisite for using Cursor.

### Incident checklist — "the agent wrote somewhere unexpected"

1. **Confirm the mount.** `sbx-ide ls` shows each sandbox's workspace — what host path was actually mounted? Was it wider than the repo (e.g. `$HOME`)? (`ssh <name>.sbx pwd` / `sbx exec <name> -- pwd` shows it from inside.)
2. **Scope the change on the host.** Only paths *under the mount* can be affected from inside the sandbox. `git status` in the repo; check timestamps under the mount root.
3. **Rule out an orphan.** If work "vanished," it likely landed in a workspace-less sandbox (`/home/agent/workspace`). Check `sbx-ide ls` for `⚠ orphan` rows *before* removing anything.
4. **Preserve evidence.** Do **not** `sbx rm` the sandbox yet — SSH in (`ssh <name>.sbx`) and inspect state/logs first.
5. **Contain.** Stop the sandbox (`sbx stop <name>`); revert unwanted host changes from version control.
6. **Root-cause the mount.** Almost always an over-broad mount or a hand-typed sandbox name. Re-establish the `sbx-ide open`-only golden path.
7. **Report drift.** If isolation behaved differently than documented here, file it — and re-run `sbx-ide doctor --verify` to check for CLI changes.
