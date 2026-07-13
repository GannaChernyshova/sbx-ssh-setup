# shellcheck shell=bash
# sbx-interface.sh — the ONE place that knows how to talk to the sbx CLI.
#
# Everything the toolkit assumes about sbx that could not be verified while it
# was authored is a variable below tagged `# VERIFY-ON-HOST`. `sbx-doctor
# --verify` checks each of these against the real CLI and prints a diff-style
# report, so the first run on a real machine validates them.
#
# Override any of these via the environment without editing the file, e.g.:
#   SBX_DEFAULT_AGENT=shell SBX_SSH_SUFFIX=.sbx sbx-open ~/src/myproj

# --- Binaries -------------------------------------------------------------
: "${SBX_BIN:=sbx}"        # the sbx CLI
: "${SSH_BIN:=ssh}"        # ssh client used for reachability + path probes

# --- Versioning -----------------------------------------------------------
: "${SBX_MIN_VERSION:=0.35.0}"   # SSH-to-sandbox support landed in 0.35.

# --- Agent / template -----------------------------------------------------
# The template Codex connects to. The `codex` agent template ships the Codex
# CLI inside the sandbox, which the Codex GUI needs in order to launch its
# remote app-server over SSH. VERIFY-ON-HOST: confirm `codex` appears in
# `sbx run --help` (Available agents: …).
: "${SBX_DEFAULT_AGENT:=codex}"

# --- SSH host suffix ------------------------------------------------------
# `sbx ssh setup` writes an SSH config making sandboxes reachable as
# <name><suffix>. VERIFY-ON-HOST: confirm the suffix (grep the Host line in
# the ssh config sbx writes — likely `Host *.sbx`).
: "${SBX_SSH_SUFFIX:=.sbx}"

# --- In-container workspace mount -----------------------------------------
# Where the host workspace is mounted *inside* the container. It mirrors the
# host path; we treat that as the primary guess and confirm it with an
# `ssh <host> test -d <path>` probe at runtime.
# VERIFY-ON-HOST: inspect a live sandbox and confirm the mount target.
: "${SBX_MOUNT_MIRRORS_HOST:=1}"                         # 1 = container path == host path
: "${SBX_FALLBACK_CONTAINER_WS:=/home/agent/workspace}"  # throwaway/orphan default

# --- Subcommand names -----------------------------------------------------
# A stopped sandbox is woken by re-running it detached (`sbx run --detached
# --name <name>`); there is no `start`. Isolated as variables because this CLI
# is still evolving.
: "${SBX_CMD_LS:=ls}"
: "${SBX_CMD_RUN:=run}"
: "${SBX_CMD_EXEC:=exec}"       # run a command inside a sandbox (path probe)
: "${SBX_CMD_STOP:=stop}"
: "${SBX_CMD_RM:=rm}"
: "${SBX_CMD_DIAGNOSE:=diagnose}"

# --- Detached create / wake ----------------------------------------------
# `sbx run --detached` (-d) prints the sandbox ID and exits without opening an
# interactive session, and also re-attaches (starts) an existing sandbox by
# name. VERIFY-ON-HOST: confirm the flag spelling in `sbx run --help`.
: "${SBX_RUN_DETACH_FLAG:=--detached}"

# --- One-time feature enablement -----------------------------------------
# SSH-to-sandbox is experimental and off by default. We enable it once per
# machine and remember that with a flag file, so the golden path stays fast.
: "${SBX_FEATURES_FLAG:=$HOME/.sbx_features_enabled}"

# --- OpenAI credentials ---------------------------------------------------
# The Codex GUI runs inside the sandbox and needs OpenAI credentials there.
# They are provisioned once per machine as a global sbx secret. We never store
# or transmit the secret ourselves — we only detect whether it exists.
: "${SBX_OPENAI_SECRET:=openai}"

sbx_present() { have "$SBX_BIN"; }

# sbx_version : print detected sbx version string (numeric portion), or empty.
sbx_version() {
  sbx_present || return 1
  { "$SBX_BIN" version 2>/dev/null || "$SBX_BIN" --version 2>/dev/null; } \
    | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1
}

# ---------------------------------------------------------------------------
# `sbx ls` parsing
#
# Output format (aligned table):
#   SANDBOX      AGENT    STATUS    PORTS      WORKSPACE
#   demo         codex    running              /Users/me/demos/sbx-demo
#
# We parse by *header column offsets* rather than field-splitting, because the
# PORTS column is frequently empty — whitespace-splitting would misalign every
# row. Emits normalized TSV: name<TAB>agent<TAB>status<TAB>workspace.
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
sbx_get() {
  local name="$1" line
  line=$(sbx_ls_normalized | awk -F'\t' -v n="$name" '$1 == n {print; exit}')
  [[ -n "$line" ]] || return 1
  printf '%s\n' "$line"
}

sbx_status()    { sbx_get "$1" | cut -f3; }
sbx_workspace() { sbx_get "$1" | cut -f4; }
sbx_exists()    { sbx_get "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# One-time enablement (idempotent, remembered via a flag file)
# ---------------------------------------------------------------------------

# sbx_features_enabled : true if we have already run the one-time SSH setup.
sbx_features_enabled() { [[ -f "$SBX_FEATURES_FLAG" ]]; }

# sbx_enable_ssh_feature : enable experimental features + the ssh feature,
# restart the daemon so they take effect, and run `sbx ssh setup`. Safe to call
# repeatedly; the caller normally guards it with sbx_features_enabled.
sbx_enable_ssh_feature() {
  sbx_present || return 1
  "$SBX_BIN" settings set platform.allowExperimentalFeatures true
  "$SBX_BIN" settings set feature.ssh true
  "$SBX_BIN" daemon stop  >/dev/null 2>&1 || true
  "$SBX_BIN" daemon start -d
  "$SBX_BIN" ssh setup
  : > "$SBX_FEATURES_FLAG"
}

# The one-time SSH enablement steps, one clean command per line (callers render
# these as copy/paste commands when they need to point the user at manual setup).
sbx_ssh_setup_steps() {
  cat <<EOF
${SBX_BIN} settings set platform.allowExperimentalFeatures true
${SBX_BIN} settings set feature.ssh true
${SBX_BIN} daemon stop && ${SBX_BIN} daemon start -d
${SBX_BIN} ssh setup
EOF
}

# ---------------------------------------------------------------------------
# OpenAI credential detection
# ---------------------------------------------------------------------------

# sbx_openai_secret_set : true if a global `openai` secret appears to exist.
# `sbx secret ls` output shape varies, so we just look for the secret name in
# whatever the command prints. VERIFY-ON-HOST: confirm `sbx secret ls` lists
# global secrets by name.
sbx_openai_secret_set() {
  sbx_present || return 1
  "$SBX_BIN" secret ls 2>/dev/null | grep -qiw "$SBX_OPENAI_SECRET"
}

# ---------------------------------------------------------------------------
# Lifecycle: create-or-wake, DETACHED (never attaches an interactive shell)
#
# `sbx run` without --detached behaves like `docker run -it`: it opens an
# interactive agent shell and blocks until you exit. That would freeze the
# caller before it can SSH-probe and launch Codex. We always create/wake
# detached so control returns immediately; Codex attaches later over SSH.
# ---------------------------------------------------------------------------

# _sbx_run_detached <args...> : `sbx run --detached <args>`, non-interactive.
# stdin from /dev/null so it can never block on a prompt.
_sbx_run_detached() {
  "$SBX_BIN" "$SBX_CMD_RUN" "$SBX_RUN_DETACH_FLAG" "$@" </dev/null
}

# sbx_ensure_running <agent> <name> <path> : create the sandbox if absent, or
# wake it if stopped — always detached, returning control immediately. A
# running sandbox is left as-is. For the wake case, agent/path are read from the
# sandbox's stored spec, so callers may pass "" for both.
sbx_ensure_running() {
  local agent="$1" name="$2" path="$3"
  sbx_present || return 1

  if sbx_exists "$name"; then
    [[ "$(sbx_status "$name")" == "running" ]] && return 0
    _sbx_run_detached --name "$name" >/dev/null      # wake (agent from spec)
    return
  fi

  _sbx_run_detached "$agent" --name "$name" "$path" >/dev/null
}

# sbx_ensure_running_cmd <agent> <name> <path> : the command we WOULD run, for
# --dry-run display.
sbx_ensure_running_cmd() {
  local agent="$1" name="$2" path="$3"
  printf '%s %s %s %s --name %s %s' \
    "$SBX_BIN" "$SBX_CMD_RUN" "$SBX_RUN_DETACH_FLAG" "$agent" "$name" "$path"
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
#   1. mirror assumption confirmed by an ssh `test -d`
#   2. ask the container for its working dir via `sbx exec`
#   3. the mirror path, unconfirmed (best guess; returns 2 so caller can warn)
container_ws_path() {
  local name="$1" host_ws="$2" candidate probed

  if [[ "$SBX_MOUNT_MIRRORS_HOST" == "1" && -n "$host_ws" ]]; then
    candidate="$host_ws"
    if ssh_reachable "$name" \
       && "$SSH_BIN" -o BatchMode=yes "$(ssh_host "$name")" "test -d '$candidate'" >/dev/null 2>&1; then
      printf '%s' "$candidate"; return 0
    fi
  fi

  probed=$(exec_ws_probe "$name" 2>/dev/null || true)
  if [[ -n "$probed" ]]; then
    printf '%s' "$probed"; return 0
  fi

  printf '%s' "${host_ws:-$SBX_FALLBACK_CONTAINER_WS}"
  return 2
}

# exec_ws_probe <name> : print the sandbox's default working directory by
# running `pwd` inside it. VERIFY-ON-HOST: confirm the `sbx exec` argument form
# (`sbx exec <name> -- <cmd>`) against `sbx exec --help`.
exec_ws_probe() {
  local name="$1" out
  sbx_present || return 1
  out=$("$SBX_BIN" "$SBX_CMD_EXEC" "$name" -- pwd 2>/dev/null | tr -d '\r' | tail -n1)
  case "$out" in
    /*) printf '%s' "$out" ;;
    *)  return 1 ;;
  esac
}
