# shellcheck shell=bash
# sbx-interface.sh — the ONE place that knows how to talk to the sbx CLI.
#
# Everything the toolkit assumes about sbx/Cursor that could not be verified
# inside the build sandbox is a variable below tagged `# VERIFY-ON-HOST`.
# `sbx-doctor --verify` checks each of these against the real CLI and prints a
# diff-style report, so the first run on a real machine validates them.
#
# Override any of these via the environment without editing the file, e.g.:
#   SBX_DEFAULT_AGENT=shell SBX_SSH_SUFFIX=.sbx sbx-open ~/src/myproj

# --- Binaries -------------------------------------------------------------
: "${SBX_BIN:=sbx}"        # the sbx CLI
: "${CURSOR_BIN:=cursor}"  # the Cursor CLI (`cursor --folder-uri ...`)
: "${CODE_BIN:=code}"      # the VS Code CLI (`code --remote ...`)
: "${SSH_BIN:=ssh}"        # ssh client used for reachability + path probes

# --- VS Code — real sshd + published loopback port (NOT sandboxd SSH) ------
# sbx sandboxes are microVMs, so Dev Containers "attach to running container"
# is impossible (nothing to attach to). And VS Code Remote-SSH over sandboxd's
# EMULATED SSH endpoint (*.sbx) retry-loops, because sandboxd services each
# forwarded channel with a fresh ~0.5s docker exec — VS Code re-opens its
# primary port-forward on every reconnect and treats that latency as a dead
# link. The fix (HOST-VERIFIED, see docs/VSCODE-NOTES.md): run a REAL OpenSSH
# server inside the sandbox (via the bundled remote-ssh kit), publish its port
# 22 to a host loopback port, and point VS Code Remote-SSH at 127.0.0.1:<port>
# — a real sshd where opening a channel is sub-millisecond.
#
# VERIFY-ON-HOST: the Remote-SSH extension id as `code --list-extensions` prints it.
: "${SBX_VSCODE_EXT:=ms-vscode-remote.remote-ssh}"
: "${SBX_VSCODE_SSH_USER:=agent}"                       # the in-sandbox login user
: "${SBX_VSCODE_SSH_PORT_BASE:=2222}"                   # first host loopback port to try
# A DEDICATED, passwordless key just for sbx-ide VS Code sandboxes — NOT your
# GitHub / general key. Auto-generated on first use (ed25519, no passphrase), so
# BatchMode auth always works with no agent, no prompts. Pinned in ~/.ssh/config
# via IdentityFile + IdentitiesOnly, so only this key is offered to the sandbox.
: "${SBX_VSCODE_SSH_KEY:=$HOME/.ssh/sbx-vscode}"        # private key path (pub = <key>.pub)
: "${SBX_VSCODE_AUTOGEN_KEY:=1}"                        # 1 = create it if missing
: "${SBX_VSCODE_HOST_PREFIX:=sbx-}"                     # ssh_config Host alias prefix
: "${SBX_VSCODE_PRESEED:=1}"                            # 1 = pre-seed server+extensions
: "${SBX_VSCODE_SSH_RETRIES:=15}"                       # attempts to reach our sshd
: "${SBX_VSCODE_SSH_RETRY_DELAY:=1}"                    # seconds between attempts
: "${SBX_CMD_PORTS:=ports}"                             # `sbx ports <name> --publish …`
# ssh_config block markers (per alias) so uninstall/clean can find & remove them.
: "${SBX_SSH_BLOCK_BEGIN:=# sbx-ide ssh BEGIN}"
: "${SBX_SSH_BLOCK_END:=# sbx-ide ssh END}"

# --- Versioning -----------------------------------------------------------
: "${SBX_MIN_VERSION:=0.35}"   # SSH-to-sandbox support landed in 0.35.

# --- Agent / template -----------------------------------------------------
# The sbx agent the sandbox RUNS. `shell` is a plain environment the IDE opens
# into. Cursor ships its own in-IDE agent, so `shell` is fine there; vanilla
# VS Code doesn't, so you may want an sbx agent (e.g. `claude`) IN the box —
# choose per target with `--agent`, $SBX_AGENT_<TARGET>, or
# `sbx-ide set-default --agent <name> [--cursor|--vscode]`. This is the GLOBAL
# floor when nothing more specific is set. VERIFY-ON-HOST: confirm the chosen
# agent in `sbx run --help` (Available agents: …).
: "${SBX_DEFAULT_AGENT:=shell}"
# Known agents (for a soft hint if you set an unrecognized one; the real list is
# `sbx run --help`). Space-separated. VERIFY-ON-HOST.
: "${SBX_KNOWN_AGENTS:=claude codex copilot cursor gemini shell}"

# --- SSH host suffix ------------------------------------------------------
# `sbx setup ssh` writes an SSH config making sandboxes reachable as
# <name><suffix>. VERIFY-ON-HOST: confirm the suffix (grep the Host line in
# the ssh config sbx writes — likely `Host *.sbx`).
: "${SBX_SSH_SUFFIX:=.sbx}"

# --- In-container workspace mount -----------------------------------------
# Where the host workspace is mounted *inside* the container. The spec says it
# likely mirrors the host path; we treat that as the primary guess and confirm
# it with an `ssh <host> test -d <path>` probe at runtime.
# VERIFY-ON-HOST: inspect a live sandbox and confirm the mount target.
: "${SBX_MOUNT_MIRRORS_HOST:=1}"                  # 1 = container path == host path
: "${SBX_FALLBACK_CONTAINER_WS:=/home/agent/workspace}"  # throwaway/orphan default

# --- Subcommand names -----------------------------------------------------
# The real command set per `sbx --help`: create, run, ls, rm, stop, exec,
# diagnose, setup, ssh. There is NO `start` and NO `inspect` command — a
# stopped sandbox is woken by re-running it detached (`sbx run --detached
# --name <name>`). Isolated as variables because this CLI is evolving.
: "${SBX_CMD_LS:=ls}"
: "${SBX_CMD_RUN:=run}"
: "${SBX_CMD_CREATE:=create}"   # alt create path (create without attaching)
: "${SBX_CMD_EXEC:=exec}"       # run a command inside a sandbox (path probe)
: "${SBX_CMD_STOP:=stop}"
: "${SBX_CMD_RM:=rm}"
: "${SBX_CMD_DIAGNOSE:=diagnose}"

# `sbx rm` REQUIRES confirmation and refuses a sandbox that is "in use" (e.g. an
# open SSH channel) unless --force is given. Every orphan we clean up is running
# and often in use, and we always run non-interactively (piped stdin), so we must
# pass --force. HOST-VERIFIED against `sbx rm --help`:
#   "-f, --force  Skip confirmation prompts and delete even if in use".
# Set SBX_RM_FORCE_FLAG= (empty) to opt out of forcing.
: "${SBX_RM_FORCE_FLAG:=--force}"

# --- Detached create / wake ----------------------------------------------
# How to create-or-wake a sandbox WITHOUT attaching an interactive shell.
# `sbx run --detached` (-d) "prints the sandbox ID and exits without opening an
# interactive session" and also re-attaches (starts) an existing sandbox by
# name. VERIFY-ON-HOST: confirm the flag spelling in `sbx run --help`.
: "${SBX_RUN_DETACH_FLAG:=--detached}"
: "${SBX_CREATE_MODE:=run-detach}"   # run-detach | create
#   run-detach : `sbx run --detached <agent> --name <name> <path>` (also wakes)
#   create     : `sbx create <agent> --name <name> <path>` then wake via run -d

# The one-time SSH enablement steps, one clean command per line (callers render
# these as copy/paste commands). `sbx --help` shows `setup` ("prepare Docker
# Sandboxes") and `ssh` ("Configure SSH access to sandboxes (experimental)") as
# real subcommands; there is no `sbx config`. VERIFY-ON-HOST: confirm the exact
# invocation/flags against `sbx setup --help` and `sbx ssh --help`, then correct.
sbx_ssh_setup_steps() {
  cat <<EOF
${SBX_BIN} setup
${SBX_BIN} ssh
EOF
}

# ---------------------------------------------------------------------------
# Raw invocation
# ---------------------------------------------------------------------------

sbx_present()    { have "$SBX_BIN"; }
cursor_present() { have "$CURSOR_BIN"; }

# sbx_version : print detected sbx version string (numeric portion), or empty.
sbx_version() {
  sbx_present || return 1
  # Try common shapes; take the first dotted-number we see.
  { "$SBX_BIN" version 2>/dev/null || "$SBX_BIN" --version 2>/dev/null; } \
    | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1
}

# ---------------------------------------------------------------------------
# `sbx ls` parsing
#
# Output format (verbatim from a real host):
#   SANDBOX      AGENT    STATUS    PORTS      WORKSPACE
#   cursor-sbx   shell    running              /Users/marcpardee/demos
#   demo         claude   stopped              /Users/marcpardee/demos/sbx-demo
#
# We parse by *header column offsets* rather than field-splitting, because the
# PORTS column is frequently empty — whitespace-splitting would misalign every
# row. Aligned CLI tables pad the header to each column's width, so a header
# token's start offset is that column's start offset. Synonyms are mapped so a
# rename (NAME/STATE/PATH) still parses.
#
# Emits normalized TSV: name<TAB>agent<TAB>status<TAB>workspace
# An empty or "-" workspace becomes an empty field (the orphan signal).
# ---------------------------------------------------------------------------
sbx_ls_normalized() {
  sbx_present || return 1
  "$SBX_BIN" "$SBX_CMD_LS" 2>/dev/null | awk '
    function colval(ci,   st, en, v) {
      if (ci == 0) return ""
      st = starts[ci]
      en = (ci < ncol) ? starts[ci+1] - 1 : length($0)
      v = substr($0, st, en - st + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      return v
    }
    NR == 1 {
      # Locate every header token and its start column offset.
      rest = $0; pos = 1; ncol = 0
      while (match(rest, /[^ \t]+/)) {
        ncol++
        starts[ncol] = pos + RSTART - 1
        label = toupper(substr(rest, RSTART, RLENGTH))
        if (label == "SANDBOX" || label == "NAME")               ci_name = ncol
        else if (label == "AGENT" || label == "TEMPLATE")        ci_agent = ncol
        else if (label == "STATUS" || label == "STATE")          ci_status = ncol
        else if (label == "WORKSPACE" || label == "PATH" || \
                 label == "FOLDER" || label == "DIR")            ci_ws = ncol
        adv = RSTART + RLENGTH - 1
        rest = substr(rest, adv + 1)
        pos += adv
      }
      next
    }
    /^[[:space:]]*$/ { next }
    {
      name = colval(ci_name); agent = colval(ci_agent)
      status = colval(ci_status); ws = colval(ci_ws)
      if (ws == "-") ws = ""
      if (name != "") printf "%s\t%s\t%s\t%s\n", name, agent, status, ws
    }
  '
}

# sbx_get <name> : print the row for <name> as name<TAB>agent<TAB>status<TAB>ws.
# Returns non-zero if no such sandbox exists.
sbx_get() {
  local name="$1" line
  line=$(sbx_ls_normalized | awk -F'\t' -v n="$name" '$1 == n {print; exit}')
  [[ -n "$line" ]] || return 1
  printf '%s\n' "$line"
}

# Field accessors built on sbx_get (all take a name).
sbx_status()    { sbx_get "$1" | cut -f3; }
sbx_workspace() { sbx_get "$1" | cut -f4; }
sbx_exists()    { sbx_get "$1" >/dev/null 2>&1; }

# sbx_rm <name> : remove a sandbox non-interactively. Forces (so it never blocks
# on a confirmation prompt and can delete a running/in-use orphan) and takes its
# stdin from /dev/null so it can NEVER consume a caller's loop input (e.g. a
# `while read … done <<< "$list"` here-string). Prints sbx's own stdout+stderr
# so callers can surface the real reason on failure; returns sbx's exit status.
sbx_rm() {
  "$SBX_BIN" "$SBX_CMD_RM" ${SBX_RM_FORCE_FLAG:+$SBX_RM_FORCE_FLAG} "$1" </dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Lifecycle: create-or-wake, DETACHED (never attaches an interactive shell)
#
# `sbx run` without --detached behaves like `docker run -it`: it opens an
# interactive agent shell and blocks until you exit. That would freeze sbx-open
# before it can SSH-probe and launch Cursor. We always create/wake detached so
# control returns immediately; Cursor attaches later over SSH.
# ---------------------------------------------------------------------------

# _sbx_run_detached <args...> : `sbx run --detached <args>`, non-interactive.
# stdin from /dev/null so it can never block on a prompt; caller redirects stdout.
_sbx_run_detached() {
  "$SBX_BIN" "$SBX_CMD_RUN" "$SBX_RUN_DETACH_FLAG" "$@" </dev/null
}

# sbx_ensure_running <agent> <name> <path> : create the sandbox if absent, or
# wake it if stopped — always detached, returning control immediately. A
# running sandbox is left as-is. For the wake case, agent/path are read from the
# sandbox's stored spec, so callers may pass "" for both.
# sbx_ensure_running <agent> <name> <path> [extra-create-args...] : the extra
# args (e.g. `--kit <dir>` for the VS Code target) are applied on CREATE only —
# a wake reuses the sandbox's stored spec, so the kit is already attached.
# (`${extra[@]+…}` guard keeps this safe under `set -u` on bash 3.2 / macOS.)
sbx_ensure_running() {
  local agent="$1" name="$2" path="$3"; shift 3 2>/dev/null || true
  local -a extra=("$@")
  sbx_present || return 1

  if sbx_exists "$name"; then
    [[ "$(sbx_status "$name")" == "running" ]] && return 0
    _sbx_run_detached --name "$name" >/dev/null      # wake (agent/kit from spec)
    return
  fi

  if [[ "$SBX_CREATE_MODE" == "create" ]]; then
    "$SBX_BIN" "$SBX_CMD_CREATE" "$agent" ${extra[@]+"${extra[@]}"} --name "$name" "$path" </dev/null >/dev/null
    _sbx_run_detached --name "$name" >/dev/null       # ensure it is started
  else
    _sbx_run_detached "$agent" ${extra[@]+"${extra[@]}"} --name "$name" "$path" >/dev/null
  fi
}

# sbx_ensure_running_cmd <agent> <name> <path> [extra...] : the command we WOULD
# run, for --dry-run display (create form).
sbx_ensure_running_cmd() {
  local agent="$1" name="$2" path="$3"; shift 3 2>/dev/null || true
  local extra_str="$*"
  if [[ "$SBX_CREATE_MODE" == "create" ]]; then
    printf '%s %s %s %s--name %s %s' "$SBX_BIN" "$SBX_CMD_CREATE" "$agent" "${extra_str:+$extra_str }" "$name" "$path"
  else
    printf '%s %s %s %s %s--name %s %s' \
      "$SBX_BIN" "$SBX_CMD_RUN" "$SBX_RUN_DETACH_FLAG" "$agent" "${extra_str:+$extra_str }" "$name" "$path"
  fi
}

# ---------------------------------------------------------------------------
# VS Code helpers: publish the sandbox's sshd port + inject the auth key.
# ---------------------------------------------------------------------------

# sbx_published_ssh_port <name> : the host port already published to the
# sandbox's :22, or empty. VERIFY-ON-HOST: `sbx ports <name>` output format.
sbx_published_ssh_port() {
  sbx_present || return 0
  "$SBX_BIN" "$SBX_CMD_PORTS" "$1" 2>/dev/null \
    | sed -nE 's/.*[^0-9]([0-9]+)->22(\/tcp)?([[:space:]]|$).*/\1/p' | head -n1
}

# sbx_publish_ssh_port <name> <host_port> : publish 127.0.0.1:<host_port> -> :22.
# Binds loopback ONLY (never 0.0.0.0) so the sandbox's sshd is unreachable off
# this machine. VERIFY-ON-HOST: `sbx ports --publish` accepts the HOST_IP form.
sbx_publish_ssh_port() {
  "$SBX_BIN" "$SBX_CMD_PORTS" "$1" --publish "127.0.0.1:${2}:22/tcp" </dev/null 2>&1
}

# sbx_inject_pubkey <name> <pubkey_file> : install the key as the sandbox user's
# sole authorized_keys. sshd reads it per-connection, so no restart is needed.
sbx_inject_pubkey() {
  local name="$1" keyfile="$2" home="/home/${SBX_VSCODE_SSH_USER}"
  # Create ~/.ssh ourselves (don't assume the kit's dir-create step ran) so the
  # write can't fail with "Directory nonexistent". The single-quoted sh -c body
  # runs INSIDE the sandbox; $KEY is expanded there (from --env), not here.
  # shellcheck disable=SC2016
  "$SBX_BIN" "$SBX_CMD_EXEC" --env KEY="$(cat "$keyfile")" "$name" -- \
    sh -c 'mkdir -p '"$home"'/.ssh && chmod 700 '"$home"'/.ssh && printf "%s\n" "$KEY" > '"$home"'/.ssh/authorized_keys && chmod 600 '"$home"'/.ssh/authorized_keys' </dev/null 2>&1
}

# sbx_has_remote_ssh_kit <name> : true if the sandbox was created with our
# remote-ssh kit (the sshd drop-in it writes is present). Lets --vscode detect a
# sandbox created WITHOUT the kit (e.g. one that predates --vscode) instead of
# failing cryptically. VERIFY-ON-HOST: the marker path the kit writes.
sbx_has_remote_ssh_kit() {
  "$SBX_BIN" "$SBX_CMD_EXEC" "$1" -- \
    sh -c 'test -f /etc/ssh/sshd_config.d/10-sbx-ide.conf' </dev/null >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# In-container workspace path resolution
# ---------------------------------------------------------------------------

# ssh_host <name> : the ssh host alias for a sandbox.
ssh_host() { printf '%s%s' "$1" "$SBX_SSH_SUFFIX"; }

# ssh_reachable <name> : true if the sandbox answers over SSH (batch mode, so
# it never blocks on a password/known-hosts prompt).
ssh_reachable() {
  have "$SSH_BIN" || return 1
  "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=8 \
    -o StrictHostKeyChecking=accept-new "$(ssh_host "$1")" true >/dev/null 2>&1
}

# container_ws_path <name> <host_ws> : resolve the workspace path *inside* the
# container. Strategy, best-to-worst:
#   1. mirror assumption confirmed by an ssh `test -d`  (VERIFY-ON-HOST)
#   2. ask the container for its working dir via `sbx exec`
#   3. the mirror path, unconfirmed (best guess, warn)
container_ws_path() {
  local name="$1" host_ws="$2" candidate probed

  if [[ "$SBX_MOUNT_MIRRORS_HOST" == "1" && -n "$host_ws" ]]; then
    candidate="$host_ws"
    if ssh_reachable "$name" \
       && "$SSH_BIN" -o BatchMode=yes "$(ssh_host "$name")" "test -d '$candidate'" >/dev/null 2>&1; then
      printf '%s' "$candidate"; return 0
    fi
  fi

  # Fallback: ask the sandbox directly where its workspace lives.
  probed=$(exec_ws_probe "$name" 2>/dev/null || true)
  if [[ -n "$probed" ]]; then
    printf '%s' "$probed"; return 0
  fi

  # Last resort: return the mirror guess so Cursor still opens *somewhere*
  # sensible; caller decides whether to warn.
  printf '%s' "${host_ws:-$SBX_FALLBACK_CONTAINER_WS}"
  return 2
}

# exec_ws_probe <name> : print the sandbox's default working directory (its
# workspace mount) by running `pwd` inside it. VERIFY-ON-HOST: confirm the
# `sbx exec` argument form (`sbx exec <name> -- <cmd>`) against `sbx exec --help`.
exec_ws_probe() {
  local name="$1" out
  sbx_present || return 1
  out=$("$SBX_BIN" "$SBX_CMD_EXEC" "$name" -- pwd 2>/dev/null | tr -d '\r' | tail -n1)
  case "$out" in
    /*) printf '%s' "$out" ;;
    *)  return 1 ;;
  esac
}
