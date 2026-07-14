# sbx-ide

**Give an AI coding agent full autonomy — safely — by putting your IDE inside a Docker Sandbox.** `sbx-ide` is a tiny toolkit that makes [Docker Sandboxes](https://docs.docker.com/) (the `sbx` CLI, v0.35+) the default, one-command way to open any project in your editor, isolated in a throwaway container whose only shared surface with your machine is the one directory you mounted. Turn on your editor's "run everything" auto-mode without flinching: the agent, the editor server, and every terminal it spawns all execute *inside* the sandbox, so the blast radius is exactly the mounted repo — not your home directory, keychain, or other projects. The flagship command, `sbx-ide open <path>`, creates-or-reuses the right sandbox, verifies connectivity, and launches your IDE already connected to the right folder — and it refuses the footguns (orphan sandboxes, over-broad mounts, name collisions) instead of letting you fall into them. Speed and security stop being a tradeoff.

**Why `sbx-ide` and not `sbx-cursor`?** The toolkit wraps IDE-in-sandbox workflows and nothing else — the name shouldn't presume more. It also deliberately avoids squatting on the bare `sbx-*` namespace the product itself may one day claim (e.g. a future `sbx ssh <ide>`). One command, subcommands underneath.

## Install

```bash
./install.sh            # installs to ~/.local/bin, then runs sbx-ide doctor
make install            # same thing
```

Changed your mind? **`make uninstall`** is a clean, auditable teardown: it removes everything the toolkit installed and *reports* (never deletes) anything left on your system — see [Uninstall](#uninstall). This is a stopgap tool for prospect machines; a clean exit is a feature.

### Upgrading

Install is idempotent and version-aware. To update an existing install, pull the
latest source and re-run it — it overwrites in place and reports the version bump:

```bash
make update             # or: ./install.sh --update
```

Every command reports its version with `--version` (e.g. `sbx-ide --version`).

Then, in one command (both forms work):

```bash
sbx-ide open /path/to/acme-api      # by path
cd /path/to/acme-api && sbx-ide open ./   # or from inside the project
```

## Commands

`sbx-ide` is a single command with subcommands:

| Command | What it does |
|---|---|
| `sbx-ide open <path> [--cursor\|--vscode] [--name <name>]` | The golden path. Create-or-reuse one sandbox per project, verify connectivity, launch the IDE pre-connected to the right folder. Idempotent. |
| `sbx-ide set-default <cursor\|vscode>` | Persist your default IDE. Set it once, drop the flag. |
| `sbx-ide doctor [--target cursor\|vscode]` | Health check with ✅/❌ and the exact fix per failure. `--verify` validates the toolkit's host assumptions. |
| `sbx-ide ls` | Human-friendly sandbox list; flags orphans and stopped sandboxes; prints a copy/paste `sbx-ide open` per row. |
| `sbx-ide clean [--yes]` | Remove orphan/stopped sandboxes (`--dry-run`, `--yes`). |

> **Deprecated shims.** The old `sbx-open` / `sbx-doctor` / `sbx-ls` / `sbx-clean` names still work — they print a one-line deprecation notice and forward to the matching subcommand. They're removed by `make uninstall` and flagged by `sbx-ide doctor`.

### Pick your IDE once

```bash
sbx-ide set-default vscode      # now `sbx-ide open ./` uses VS Code, no flag needed
```

Target resolution order (highest precedence first): **`--cursor`/`--vscode` flag → `$SBX_IDE_TARGET` → config default → `cursor`**. The default lives in `~/.config/sbx-ide/config` (XDG-respecting, `0600`).

## Support matrix

| IDE | Status | Mechanism |
|---|---|---|
| **Cursor** | ✅ Supported | SSH-remote folder URI over sbx's single stable `*.sbx` tunnel (`cursor --folder-uri vscode-remote://ssh-remote+…`). |
| **VS Code** | ✅ Supported | **Real `sshd` in the sandbox + published loopback port + Remote-SSH** (`code --remote ssh-remote+sbx-<name> …`), via the bundled `remote-ssh` kit and a dedicated auto-generated passwordless key. See [`docs/VSCODE-NOTES.md`](docs/VSCODE-NOTES.md). |
| ~~Codex~~ | Owned by a teammate | Not shipped here. The per-target table in [`lib/targets.sh`](lib/targets.sh) is the extension point their row slots back into. |

**Why VS Code runs its own sshd instead of attaching or using sandboxd's SSH:** sbx sandboxes are **microVMs**, so VS Code's Dev Containers "attach to running container" has nothing to attach to. And VS Code Remote-SSH over sandboxd's *emulated* `*.sbx` endpoint retry-loops: sandboxd services each forwarded channel with a fresh ~0.5 s `docker exec`, and VS Code re-opens its primary port-forward on every reconnect, so it perceives the link as dead (~5 s loop). Cursor is fine because it keeps one long-keepalive tunnel. The fix `sbx-ide` ships: run a **real OpenSSH server inside the sandbox** (bundled kit), publish its `:22` to a host **loopback** port, and point Remote-SSH at `127.0.0.1:<port>` — a real sshd where opening a channel is sub-millisecond. There is **no fallback** to sandboxd's SSH: if the setup can't be validated, `sbx-ide open --vscode` fails with an explanation. Full rationale, security surface, and the macOS `TMPDIR` gotcha in [`docs/VSCODE-NOTES.md`](docs/VSCODE-NOTES.md).

## First run on a new machine

This toolkit was authored without a live `sbx` to probe, so a few interface details are encoded as `# VERIFY-ON-HOST` assumptions in [`lib/sbx-interface.sh`](lib/sbx-interface.sh). Validate them against your actual CLI in one step:

```bash
sbx-ide doctor --verify     # diff-style expected-vs-detected report
```

See [`docs/HOST-VALIDATION.md`](docs/HOST-VALIDATION.md) for the 5-minute checklist (and the VS Code attach items in [`docs/VSCODE-NOTES.md`](docs/VSCODE-NOTES.md)).

## Uninstall

```bash
make uninstall          # or: ./install.sh --uninstall
```

Removes the `sbx-ide` binary, the deprecated shims, the installed libraries, and the PATH line it added (inside `# sbx-ide BEGIN/END` markers — it migrates old `# sbx-cursor` markers too). It **offers** to remove your config file (a user preference, never silent). Then it **reports** — without deleting — the sandboxes the toolkit likely created (with ready-to-copy `sbx stop`/`sbx rm` lines) and any leftover Host entries inside its own SSH markers, and prints a final "what remains on your system" summary. It never touches sbx's own settings, feature flags, or the wildcard `*.sbx` SSH block.

## Credits

The VS Code support (real `sshd` in the sandbox + published loopback port + Remote-SSH) is adapted from the internal proof-of-concept [`DockerSolutionsEngineering/ai.gov.sbx-vscode-ssh`](https://github.com/DockerSolutionsEngineering/ai.gov.sbx-vscode-ssh) by **@philippecharriere494** (the `01-remote-ssh` and `06-better-remote-ssh` demos). See [`docs/VSCODE-NOTES.md`](docs/VSCODE-NOTES.md) for the full attribution.

## Docs

- 📏 [**docs/RULEBOOK.md**](docs/RULEBOOK.md) — Sandboxes for your IDE at Enterprise Scale (developers · non-technical users · platform/security).
- 🎬 [**docs/DEMO.md**](docs/DEMO.md) — the 10-minute prospect demo script.
- ✅ [**docs/HOST-VALIDATION.md**](docs/HOST-VALIDATION.md) — validate the toolkit on a real host.
- 🧩 [**docs/VSCODE-NOTES.md**](docs/VSCODE-NOTES.md) — the VS Code attach path: why, how, and what to verify.

## Develop

```bash
make check      # lint (optional) + stubbed smoke test (no real sbx needed)
make check STRICT=1   # CI mode: a skipped optional step (e.g. missing shellcheck) is a failure
make demo       # narrated dry-run of the demo flow against stub CLIs
```

The test suite runs entirely against fake `sbx`/`cursor`/`code`/`ssh` CLIs in [`test/stubs/`](test/stubs), so `make check` works on any machine. Optional dev tools (`shellcheck`, `shfmt`) are **detected, not required**: if one is missing, its step is skipped with an install hint and the functional tests still run. `make check STRICT=1` turns skips into failures for CI.
