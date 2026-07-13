# Pilot runbook

A small, honest pilot you can put in front of the customer. Goal: prove that a
**non-technical user opens a project in the Codex desktop GUI with zero terminal
commands**, on both macOS and Windows, with the agent running inside an sbx sandbox.

Test on **your own Mac first** (you have one), then a Windows box, then 2–3 real users.

---

## The end-user experience we're proving

1. **Right-click a project folder → "Open in Codex Sandbox".** (No terminal. No typing.)
2. A window shows progress and finishes with the host name + folder path (folder path is
   copied to the clipboard). Codex launches.
3. In Codex: **New remote project → pick the listed host → paste the folder → Add project.**
   *(This is the only manual step; OpenAI has no API to automate it yet — see
   [openai/codex#21554](https://github.com/openai/codex/issues/21554).)*

Everything before step 3 is automated. The scary CLI commands
(`sbx daemon …`, `sbx ssh setup`, `sbx run …`) never touch the user — they run once,
invisibly, on first use.

---

## One-time machine setup (done by IT / provisioning, not the user)

Per machine, before handing it to the user:

1. Install **Docker** (running), the **`sbx` CLI** (v0.35+), and the **Codex desktop app**.
2. Provide OpenAI credentials for the sandbox — one browser login per machine:
   ```bash
   sbx secret set -g openai --oauth
   ```
3. Install the toolkit (this also registers the right-click menu):
   - **macOS:** `./install.sh`
   - **Windows:** `powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1`

The very first `sbx-open` (i.e. the first right-click) auto-runs the one-time SSH
enablement (`feature.ssh` + `sbx ssh setup`) and records `~/.sbx_features_enabled`, so it
never repeats. If you prefer, run one `sbx-open <path>` yourself during provisioning to get
that out of the way before the user's first click.

---

## Test 1 — macOS (do this first)

```bash
git clone <this repo> && cd sbx-ssh-setup
./install.sh
```

Then, in Finder, **right-click any project folder → Quick Actions / Services →
"Open in Codex Sandbox"**.

Expected: a Terminal window opens, creates the sandbox, prints
`SSH reachable`, `Codex will now auto-discover this host`, then the host name +
folder path; Codex launches.

**If the menu item isn't visible yet:**
- It lives under the right-click **Quick Actions** (or **Services**) submenu.
- Enable it: **System Settings → Keyboard → Keyboard Shortcuts → Services → Files and
  Folders → tick "Open in Codex Sandbox"**.
- Still nothing? Log out and back in once (Finder re-scans Services on login), or run
  `/System/Library/CoreServices/pbs -flush`.
- Fallback that always works: double-click **launchers/Open in Codex.command** and drag the
  folder in. Same result.

Finish in Codex: New remote project → pick the host → paste the folder (⌘V) → Add project.
Confirm the composer shows the **"Sandbox Proxy"** label and that a shell command the agent
runs appears inside the sandbox (e.g. ask it to run `hostname`).

Verify the plumbing directly if needed:
```bash
sbx-doctor            # all green?
sbx-doctor --verify   # confirms the host assumptions match your sbx
sbx-ls                # your sandbox, with its workspace
```

## Test 2 — Windows

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

Then in File Explorer, **right-click a project folder → "Open in Codex Sandbox"** (or
right-click inside the folder's empty space). A console window shows progress and stays open
with the connection steps. Finish in Codex the same way.

Fallback: drag a folder onto **launchers\Open in Codex.bat**.

## Test 3 — 2–3 real users

Give each a machine that's already provisioned (steps above done). Ask them to open one of
their own projects via right-click. Success = they reach working Codex chat without you, and
it survives closing/reopening the sandbox (`sbx-open` again, or right-click again).

---

## Success criteria

- [ ] User opens a project in Codex with **no terminal commands**.
- [ ] Same right-click flow works on macOS and Windows.
- [ ] Agent tool calls execute **inside** the sandbox ("Sandbox Proxy").
- [ ] Survives sandbox stop/wake (re-run the right-click; it reuses the sandbox).
- [ ] `sbx-doctor` is all-green on a provisioned machine.

## Known manual step (call it out to the customer)

Creating the Codex *remote project* is 2 clicks the user does once per project. OpenAI does
not expose a supported way to automate it ([#21554](https://github.com/openai/codex/issues/21554));
we intentionally do not hack Codex's private state file, because that breaks on Codex
updates. When OpenAI ships an API/deep-link, we automate this too — see the roadmap in
[README](README.md#future-improvements) / DEPLOYMENT.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Anything looks wrong | `sbx-doctor` — it prints the exact fix per issue. |
| Host not shown in Codex | Re-run the right-click (re-adds the SSH alias). |
| Codex connects, tasks do nothing | `sbx secret set -g openai --oauth` (missing OpenAI login). |
| Sandbox unreachable right after create | Wait ~10s, right-click again (it was still starting). |
| macOS menu item missing | Enable it in System Settings → … → Services, or use the .command launcher. |
| A data feed / URL is blocked | `sbx policy allow network <domain>` (see DEPLOYMENT.md). |
