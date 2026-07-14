# Codex Desktop in a sandbox — mechanism & host validation

`sbx-ide open --codex <path>` connects **Codex Desktop** to a sandbox by
registering it as a **remote SSH connection** over sbx's single stable `*.sbx`
tunnel — the same emulated SSH endpoint Cursor uses. Codex, like Cursor, keeps a
single long-keepalive connection, so it does **not** hit the reconnect loop that
forces VS Code onto its own in-sandbox `sshd` (see
[`VSCODE-NOTES.md`](VSCODE-NOTES.md)). Codex therefore needs **none** of the
sshd-kit / published-port machinery — just the one-time SSH-to-sandbox setup.

> Status: **supported, with one manual step.** Everything except the remote
> **project folder path** is automated; that one field is pasted (the value is
> copied to your clipboard). The [VERIFY-ON-HOST](#verify-on-host) items are
> worth re-confirming after an `sbx` or Codex upgrade.

> **Attribution.** The concrete-alias + connection-deep-link + clipboard flow is
> adapted from the [`GannaChernyshova/sbx-ssh-setup`](https://github.com/GannaChernyshova/sbx-ssh-setup)
> Codex integration. `sbx-ide` packages it as the `codex` target behind
> `sbx-ide open --codex`, with the same guards and clean teardown as the other
> targets.

## Why Codex needs two extra touches (and what they are)

Unlike Cursor and VS Code, Codex is a **desktop app you don't launch from a
folder-URI CLI**. So the `codex` target's launch hook doesn't run a binary — it
prepares the connection and hands off to the app:

1. **A concrete `Host <name>.sbx` alias.** Codex enumerates *concrete* `Host`
   aliases in `~/.ssh/config` and **ignores the pattern-only `Host *.sbx`** block
   that `sbx ssh setup` writes. Without a concrete alias, the sandbox simply
   never appears in Codex's connection list. The target writes an **empty**
   `Host <name>.sbx` block (wrapped in `# sbx-ide ssh BEGIN/END <alias>` markers)
   — every option is inherited from the managed `*.sbx` block via `ssh -G`, so
   nothing is duplicated and no managed value is copied out of place.

2. **The connection deep link.** `codex://settings/connections/ssh/add?name=<alias>`
   (opened with the OS URL handler — `open`/`xdg-open`/`Start-Process`) tells
   Codex to add/enable the connection, so you don't have to open
   Settings → Connections and Refresh by hand.

The target also pre-provisions the in-container project directory (`ssh <alias>
mkdir -p <path>`) so the folder exists the moment you paste it.

## What we ruled out (and why)

**VS Code's real-sshd-on-a-published-port approach — unnecessary here.** That
exists solely because VS Code Remote-SSH retry-loops over sandboxd's emulated
SSH. Codex keeps a single keepalive connection (like Cursor), so it works over
the `*.sbx` tunnel directly. Adding a second sshd + published loopback port would
be extra surface for no benefit.

**The `~/.codex/.codex-global-state.json` hack — deliberately avoided.** Codex
has no supported way to register a remote *project/folder* from automation
([openai/codex#21554](https://github.com/openai/codex/issues/21554)). Writing the
project into Codex's private global-state file would be fragile (undocumented
schema, breaks on Codex updates) and is exactly the kind of footgun this toolkit
refuses. We leave the folder path as a paste (copied to the clipboard) until
Codex ships a supported mechanism.

## The mechanism (step by step)

`sbx-ide open --codex <path>`:

1. Creates-or-reuses one sandbox for `<path>` (shared with all targets), mounting
   only that directory — the mount is the entire blast radius.
2. Verifies the sandbox answers over sandboxd's `*.sbx` SSH. If not, it prints
   the one-time SSH-to-sandbox setup (also available as
   `sbx-ide doctor --setup-ssh`) and stops.
3. Writes the empty concrete `Host <name>.sbx` alias.
4. Resolves and pre-creates the in-container workspace path.
5. Fires `codex://settings/connections/ssh/add?name=<name>.sbx`.
6. Copies the folder path to the clipboard.

Then, in Codex: **New project → Remote → connection `<name>.sbx` → paste the
Folder path → Add project.**

## Known limitation — the project folder is the one manual step

The connection is fully automated; the **project's Folder path** must be entered
by hand (paste — it's on your clipboard). This is a Codex limitation
([openai/codex#21554](https://github.com/openai/codex/issues/21554)), not a
toolkit shortcut. `--no-open` and `--print-uri` both surface the folder path so
you can script around it if Codex adds support later.

## VERIFY-ON-HOST

These are encoded as `SBX_*` assumptions (override via the environment); confirm
them on a real machine, especially after an `sbx`/Codex upgrade:

- **Deep-link scheme.** `SBX_CODEX_DEEPLINK_PREFIX` defaults to
  `codex://settings/connections/ssh/add?name=`. Confirm the installed Codex build
  registers a connection when this link is opened (with the concrete alias name).
- **Concrete-alias discovery.** Confirm Codex lists `Host <name>.sbx` from
  `~/.ssh/config` and that an empty block correctly inherits from `Host *.sbx`
  (`ssh -G <name>.sbx` should show the managed `ProxyCommand`/`User`).
- **SSH suffix.** `SBX_SSH_SUFFIX` (default `.sbx`) matches the `Host *.<suffix>`
  block `sbx ssh setup` writes — shared with the Cursor target and checked by
  `sbx-ide doctor --verify`.
- **URL handler / clipboard.** `open`/`xdg-open`/`Start-Process` and
  `pbcopy`/`wl-copy`/`xclip`/`clip.exe` are best-effort; if absent, `sbx-ide`
  prints the link and folder path instead of failing.
