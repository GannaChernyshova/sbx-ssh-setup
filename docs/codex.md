# Connecting the Codex desktop app to a sandbox

`sbx-open` does everything up to the last screen for you. This page shows what it automates and the
one manual step that Codex does not yet expose to automation.

> **One sandbox per project.** `sbx-open` creates a dedicated sandbox per project directory and adds
> a matching SSH host that Codex auto-discovers.

## Prerequisites

- `sbx` 0.35.0+ and Docker running.
- The OpenAI Codex desktop app installed.
- A one-time OpenAI login for the sandbox (Codex runs *inside* it):
  ```bash
  sbx secret set -g openai --oauth
  ```
  This opens a browser once per machine; it is shared by every sandbox. If Codex connects but
  nothing happens when you run a task, this step was skipped. `sbx-doctor` flags it.

## The one command

From anywhere, point `sbx-open` at your project:

```bash
sbx-open codex ~/src/acme-api        # Windows: sbx-open codex C:\src\acme-api
```

On first run it enables the sbx SSH feature (once), then on every run it:

1. Creates or reuses the sandbox for that folder (named after the directory).
2. Verifies SSH connectivity.
3. Adds a **concrete** SSH host alias so the Codex app auto-discovers it.
   *(Codex ignores the `Host *.sbx` wildcard that `sbx ssh setup` writes — the concrete alias is
   what makes the host appear in Codex.)*
4. Launches the Codex desktop app and copies the project folder path to your clipboard.

It prints the two values you need next:

```
Last step in the Codex desktop app — New remote project:
   1. Pick the host from the list:   acme-api.sbx
   2. Choose the project folder:     /Users/you/src/acme-api   (copied to clipboard)
   3. Click Add project and start working.
```

## The last step (manual): create the remote project

Codex has no supported CLI or deep link to register a remote project
([openai/codex#21554](https://github.com/openai/codex/issues/21554)), so this stays a few clicks in
the app. It is quick:

**1. Start a new remote project.**

![Create project — Remote](images/codex-create-project-remote.png)

**2. Pick the host `sbx-open` printed** (e.g. `acme-api.sbx`) from the auto-discovered list. You do
**not** need "Add manually" — the host is already there because `sbx-open` added the concrete alias.

![Connections / pick host](images/codex-add-ssh-connection.png)

**3. Choose the project folder** — paste the path from your clipboard (it is the same directory the
sandbox was started from, mounted at the same path inside the sandbox). Click **Add project**.

![New remote project dialog](images/codex-new-remote-project.png)

Start coding — the agent now runs entirely inside the sandbox.

## Working with multiple projects

Repeat per project — one sandbox each:

```bash
sbx-open codex ~/src/acme-api
sbx-open codex ~/src/beta-service
```

`sbx-ls` shows them all; `sbx-clean` reclaims the ones you're done with (and prunes their SSH
aliases). If anything looks off, run `sbx-doctor`.
