# sbx-cursor

**Give an AI coding agent full autonomy — safely — by putting Cursor inside a Docker Sandbox.** `sbx-cursor` is a tiny toolkit that makes [Docker Sandboxes](https://docs.docker.com/) (the `sbx` CLI, v0.35+) the default, one-command way to open any project in Cursor, isolated in a throwaway container whose only shared surface with your machine is the one directory you mounted. Turn on Cursor's "run everything" auto-mode without flinching: the agent, the Cursor server, and every terminal it spawns all execute *inside* the sandbox, so the blast radius is exactly the mounted repo — not your home directory, keychain, or other projects. The flagship command, `sbx-open <path>`, creates-or-reuses the right sandbox, verifies SSH, and launches Cursor already connected to the right folder — and it refuses the footguns (orphan sandboxes, over-broad mounts, name collisions) instead of letting you fall into them. Speed and security stop being a tradeoff.

## Install

```bash
./install.sh            # installs to ~/.local/bin, then runs sbx-doctor
make install            # same thing
```

### Upgrading

Install is idempotent and version-aware. To update an existing install, pull the
latest source and re-run it — it overwrites in place and reports the version bump:

```bash
make update             # or: ./install.sh --update
```

Every command reports its version with `--version` (e.g. `sbx-open --version`);
`./install.sh --version` prints the source tree's version.

Then, in one command:

```bash
sbx-open ~/src/acme-api     # create/reuse a sandbox and open it in Cursor
```

## Commands

| Command | What it does |
|---|---|
| `sbx-open <path>` | The golden path. Create-or-reuse one sandbox per project, verify SSH, launch Cursor pre-connected to the right folder. Idempotent. |
| `sbx-doctor` | Health check with ✅/❌ and the exact fix per failure. `--verify` validates the toolkit's host assumptions. |
| `sbx-ls` | Human-friendly sandbox list; flags orphans and stopped sandboxes; prints a copy/paste `sbx-open` per row. |
| `sbx-clean` | Remove orphan/stopped sandboxes (`--dry-run`, `--yes`). |

## First run on a new machine

This toolkit was authored without a live `sbx` to probe, so a few interface details are encoded as `# VERIFY-ON-HOST` assumptions in [`lib/sbx-interface.sh`](lib/sbx-interface.sh). Validate them against your actual CLI in one step:

```bash
sbx-doctor --verify     # diff-style expected-vs-detected report
```

See [`docs/HOST-VALIDATION.md`](docs/HOST-VALIDATION.md) for the 5-minute checklist.

## Docs

- 📏 [**docs/RULEBOOK.md**](docs/RULEBOOK.md) — Sandboxes for Cursor at Enterprise Scale (developers · non-technical users · platform/security).
- 🎬 [**docs/DEMO.md**](docs/DEMO.md) — the 10-minute prospect demo script.
- ✅ [**docs/HOST-VALIDATION.md**](docs/HOST-VALIDATION.md) — validate the toolkit on a real host.

## Develop

```bash
make check      # shellcheck + stubbed smoke test (no real sbx needed)
make demo       # narrated dry-run of the demo flow against stub CLIs
```

The test suite runs entirely against fake `sbx`/`cursor`/`ssh` CLIs in [`test/stubs/`](test/stubs), so `make check` works on any machine.
