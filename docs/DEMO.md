# sbx-cursor — 10-minute prospect demo

**Goal:** land one idea — *you can give an AI agent full autonomy without giving up control, and it costs you nothing in speed.*

**Setup (before the call):**
- A real repo checked out locally (e.g. `~/src/acme-api`), ideally with tests.
- `sbx-ide doctor` all green. (Rehearse the flow safely anytime with `make demo`.)
- Two terminal windows ready; Cursor installed with the `cursor` CLI on PATH.
- Optional: a scratch folder you're willing to let an agent modify on your *host* for the scary contrast (Part 4).

> ⏱️ Timings are guidance. The demo is 4 beats: **Hook → Golden path → Prove isolation → Contrast.**

---

## 0. The hook (1 min)

> "Everyone wants to let AI agents just *go* — run commands, install things, refactor across files. And everyone's scared to, because the agent runs on your laptop with your keys and your whole filesystem. So we half-trust it, approve every command, and lose all the speed. Watch me give an agent **full autonomy** on a real repo — 'run everything' on — and stay completely safe. One command."

**Speaker note:** name the tension explicitly — *speed vs. security is the false choice we're about to delete.*

---

## 1. The golden path (2 min)

```bash
sbx-ide open ~/src/acme-api
```

Narrate while it runs:
- "One command. It **created an isolated sandbox** for just this repo…"
- "…verified I can reach it over SSH…"
- "…and launched Cursor **already connected, already in the project folder**."

When Cursor opens, point at the title bar / remote indicator ending in `.sbx`.

> "Cursor isn't running on my Mac anymore. The editor server, the agent, every terminal it opens — all inside a container. The only thing shared with my machine is this one folder."

**Speaker note:** emphasize *zero extra steps*. This is the same effort as opening a folder — that's the whole point. Frictionless is the adoption story.

> **If they ask "does this work with VS Code?"** — Yes: `sbx-ide open <repo> --vscode` attaches VS Code via Dev Containers, or `sbx-ide set-default vscode` makes it the default so the flag disappears. (One honest caveat: VS Code uses container *attach*, not Remote-SSH, because sbx's emulated SSH makes Remote-SSH retry-loop — see `docs/VSCODE-NOTES.md`. Cursor is the fully host-verified path today.)

> **If they ask "does this work with Codex?"** — Yes: `sbx-ide open <repo> --codex` registers the sandbox as a Codex Desktop remote connection (concrete `*.sbx` alias + the `codex://…/ssh/add` deep link) and copies the folder path to your clipboard. One honest caveat: Codex has no supported way to register the remote *project folder* from automation ([openai/codex#21554](https://github.com/openai/codex/issues/21554)), so you paste that one field — see `docs/CODEX-NOTES.md`.

---

## 2. Give the agent full autonomy (3 min)

In Cursor: enable auto-run / "run everything" (agent settings). Say out loud: "I'm turning off the guardrails I'd normally never turn off."

Give it a real task, e.g.:

> "Add input validation to the POST /orders endpoint, run the test suite, and fix anything that breaks."

Let it rip — installing deps, editing files, running tests. Don't approve anything.

> "It's installing packages, editing files, running the test suite — total autonomy. I'm not clicking approve. And I'm not nervous, because none of this can escape this folder."

**Speaker note:** if the agent does something dramatic (installs a big dep, rewrites a file) — lean in, don't apologize. That's the product working.

---

## 3. Prove the isolation (3 min)

**A. The host is untouched — except the project.**

New terminal, *on the host*:
```bash
ls -la ~              # your home dir: unchanged, agent never saw it
cd ~/src/acme-api && git status   # the ONLY place changes appear
```

> "The agent installed packages and wrote files — but on my actual machine, the only thing that changed is this repo's working tree. My home directory, my SSH keys, my other projects: the agent never even knew they existed."

**B. Same container, second door.**

```bash
ssh acme-api.sbx        # or: sbx-ide open ~/src/acme-api  (reuses the sandbox)
ls -la                  # the same files the agent is editing
ps aux | grep node      # the dev server the agent started — shared
```

> "This terminal is inside the *same* sandbox as Cursor. Same files, same running processes. So I can debug exactly what the agent did — it's one shared environment, not a black box."

**Speaker note:** this is the "aha." The agent had a real, powerful environment (installed things, ran servers) **and** it was fully contained **and** you can inspect it. Powerful, contained, transparent — pick all three.

---

## 4. The contrast — life without sandboxes (1 min)

Keep this short and a little uncomfortable.

> "Without this? That agent runs as *me*. 'Run everything' means `rm`, `curl | sh`, reading `~/.aws/credentials`, touching every repo I have — on my real machine. So nobody turns it on. They approve every command and lose the speed. **That's** the tradeoff we just deleted."

Optionally show `sbx-ide ls` flagging an `⚠ orphan` and `sbx-ide clean` removing it:

> "And we guard the footguns too — type a wrong name into Cursor's SSH box and you can get an empty throwaway sandbox. Our tooling detects those and cleans them up, so people stay on the paved road."

---

## Close (30 sec)

> "One command to open any project. Full agent autonomy, contained to exactly one folder. Same environment your terminal and your agent share, so nothing's a black box. **Speed and security stop being a tradeoff** — because the agent is sandboxed, not supervised."

**Leave-behind:** `README.md` + `docs/RULEBOOK.md`. The developer path is literally one command: `sbx-ide open <repo>`.

---

### If something breaks live

- Cursor didn't open → the command prints the exact `cursor --folder-uri …` line; paste it.
- SSH error → `sbx-ide doctor` shows the one-time setup steps; you likely skipped enabling the experimental SSH feature + `sbx ssh setup` (Cursor path only).
- Wrong/missing files → you're in an orphan; `sbx-ide ls` will show it. Recover with `sbx-ide open <repo>`.
- Fall back to `make demo` for a fully stubbed, network-free rehearsal of the same beats.
