# shellcheck shell=bash
# targets.sh — the per-target table: ONE row per supported IDE.
#
# =============================== EXTENSION POINT ============================
# Each IDE target is a set of shell functions named target_<id>_<hook>. To add
# a target (for example the Codex IDE integration, now OWNED BY ANOTHER
# ENGINEER and intentionally not shipped here), add its <id> to SBX_IDE_TARGETS
# and define its hooks — mirroring the two rows already present. The dispatcher,
# doctor, open, and clean commands all drive targets through these hooks; this
# is the seam their work slots back into.
# ===========================================================================
#
# Hooks:
#   target_<id>_label                    -> human-readable IDE name
#   target_<id>_bin                      -> CLI binary used to launch
#   target_<id>_check <mode>             -> preflight; prints TSV lines
#                                           "level<TAB>message<TAB>fix"
#                                           level ∈ ok|warn|fail; <mode> open|doctor
#   target_<id>_run_args                 -> extra `sbx run` args applied on
#                                           CREATE, one token per line (may be empty)
#   target_<id>_launch <name> <host_ws> <created> <dry_run> <no_open> <print_uri>
#                                        -> connect to the running sandbox and
#                                           open it; owns everything IDE-specific
#                                           after the sandbox exists.

: "${SBX_IDE_TARGETS:=cursor vscode}"

# target_known <id> : true if <id> is a registered target.
target_known() {
  local t
  for t in $SBX_IDE_TARGETS; do [[ "$t" == "$1" ]] && return 0; done
  return 1
}

# _launch_success <name> <created> <label> : the closing line after a launch.
_launch_success() {
  if [[ "$2" == 1 ]]; then success "New sandbox '$1' created and opened in $3."
  else success "Reopened sandbox '$1' in $3."; fi
}

# ===========================================================================
# ROW 1 — Cursor  (default target)
#
# LAUNCH MECHANISM (host-verified, do not change): an SSH-remote folder URI over
# sandboxd's single stable *.sbx tunnel —
#   cursor --folder-uri "vscode-remote://ssh-remote+<name>.sbx<container-path>"
# Cursor keeps one long-keepalive tunnel, so sandboxd's emulated SSH is fine for
# it (unlike VS Code Remote-SSH — see the VS Code row).
# ===========================================================================
target_cursor_label() { printf 'Cursor'; }
target_cursor_bin()   { printf '%s' "$CURSOR_BIN"; }
target_cursor_run_args() { :; }   # no extra sbx-run args

target_cursor_uri() {
  local ssh_host="$2" cpath="$3"
  printf 'vscode-remote://ssh-remote+%s%s' "$ssh_host" "$cpath"
}

target_cursor_check() {
  if cursor_present; then
    printf 'ok\tCursor CLI '\''%s'\'' on PATH\t\n' "$CURSOR_BIN"
  else
    printf 'warn\tCursor CLI '\''%s'\'' not on PATH (open will print the URI instead)\tIn Cursor: Command Palette -> "Shell Command: Install cursor command".\n' "$CURSOR_BIN"
  fi
}

target_cursor_launch() {
  local name="$1" ws="$2" created="$3" dry_run="$4" no_open="$5" print_uri="$6"
  local host cpath uri; host="$(ssh_host "$name")"

  if [[ "$dry_run" == 1 ]]; then
    uri="$(target_cursor_uri "$name" "$host" "$ws")"
    if [[ "$print_uri" == 1 ]]; then printf '%s\n' "$uri"; return 0; fi
    info "[dry-run] would verify SSH: $SSH_BIN $host"
    info "[dry-run] would launch: $CURSOR_BIN --folder-uri \"$uri\""
    return 0
  fi

  if ! ssh_reachable "$name"; then
    err "Sandbox '$name' is not reachable over SSH ($host)."
    hint "SSH-to-sandbox is a one-time setup. Run these on this host:"
    while IFS= read -r step; do cmd "$step"; done < <(sbx_ssh_setup_steps)
    hint "Then re-run. Diagnose with: ${SBX_IDE_PROG:-sbx-ide} doctor"
    return 1
  fi
  success "SSH reachable: $host"

  if cpath="$(container_ws_path "$name" "$ws")"; then :; else
    warn "Could not confirm the in-container workspace path; using best guess."
    hint "Verify on host with: ${SBX_IDE_PROG:-sbx-ide} doctor --verify"
  fi
  uri="$(target_cursor_uri "$name" "$host" "$cpath")"

  if [[ "$print_uri" == 1 ]]; then printf '%s\n' "$uri"; return 0; fi
  if [[ "$no_open" == 1 ]]; then
    success "Sandbox ready. Open it with:"; cmd "$CURSOR_BIN --folder-uri \"$uri\""; return 0
  fi
  if ! have "$CURSOR_BIN"; then
    warn "Cursor CLI ('$CURSOR_BIN') not found on PATH — sandbox is ready anyway."
    hint "Open it manually with this folder URI:"; cmd "$CURSOR_BIN --folder-uri \"$uri\""; return 0
  fi
  info "Launching Cursor → $name ($cpath)"
  "$CURSOR_BIN" --folder-uri "$uri" >/dev/null 2>&1 || "$CURSOR_BIN" --folder-uri "$uri"
  _launch_success "$name" "$created" Cursor
}

# ===========================================================================
# ROW 2 — VS Code  (real sshd in-sandbox + published loopback port + Remote-SSH)
#
# Dev Containers "attach to running container" is IMPOSSIBLE here — sbx sandboxes
# are microVMs, so there is no container to attach to. And VS Code Remote-SSH over
# sandboxd's emulated *.sbx endpoint retry-loops (a ~0.5s docker-exec per forwarded
# channel lands on VS Code's primary port-forward every reconnect).
#
# LAUNCH MECHANISM (host-verified — see docs/VSCODE-NOTES.md), which sidesteps both:
#   1. create the sandbox WITH the bundled remote-ssh kit → a REAL sshd runs on :22
#   2. inject the user's public key as the agent's authorized_keys
#   3. publish the sandbox :22 to a host LOOPBACK port (127.0.0.1:<port>)
#   4. write a ~/.ssh/config Host block (loopback, keepalive) inside our markers
#   5. code --remote "ssh-remote+<alias>" <ws>  (with TMPDIR=/tmp, see below)
# VS Code then talks to a real sshd where opening a channel is sub-millisecond.
# There is NO fallback to sandboxd's SSH.
#
# ATTRIBUTION: this approach (real sshd in a kit + published loopback port +
# Remote-SSH, incl. the --detached and macOS TMPDIR details) is adapted from
# the DockerSolutionsEngineering/ai.gov.sbx-vscode-ssh proof-of-concept by
# @philippecharriere494 (demos 01-remote-ssh and 06-better-remote-ssh).
# ===========================================================================
target_vscode_label() { printf 'VS Code'; }
target_vscode_bin()   { printf '%s' "$CODE_BIN"; }

# vscode_kit_dir : locate the bundled remote-ssh kit (repo layout or installed).
vscode_kit_dir() {
  local c
  for c in "${SBX_VSCODE_KIT_DIR:-}" \
           "${_LIB:-}/kits/remote-ssh" "${_LIB:-}/../kits/remote-ssh"; do
    [[ -n "$c" && -f "$c/spec.yaml" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# vscode_privkey / vscode_pubkey : the dedicated key paths (leading ~ expanded).
vscode_privkey() { printf '%s' "${SBX_VSCODE_SSH_KEY/#\~/$HOME}"; }
vscode_pubkey()  { printf '%s.pub' "$(vscode_privkey)"; }

# vscode_ensure_key : make sure the dedicated passwordless keypair exists,
# generating it (ed25519, empty passphrase) on first use. Returns non-zero (and
# leaves the caller to explain) if it's missing and can't be generated.
vscode_ensure_key() {
  local priv pub; priv="$(vscode_privkey)"; pub="${priv}.pub"
  [[ -f "$priv" && -f "$pub" ]] && return 0
  [[ "$SBX_VSCODE_AUTOGEN_KEY" == 1 ]] || return 1
  have ssh-keygen || return 2
  mkdir -p "$(dirname "$priv")"; chmod 700 "$(dirname "$priv")" 2>/dev/null || true
  rm -f "$priv" "$pub" 2>/dev/null || true   # avoid ssh-keygen's overwrite prompt
  info "Generating a dedicated passwordless SSH key for VS Code sandboxes: $priv"
  ssh-keygen -t ed25519 -N '' -f "$priv" -C 'sbx-ide vscode' >/dev/null 2>&1 || return 3
  chmod 600 "$priv" 2>/dev/null || true
  return 0
}

# _vscode_ssh_auth_ok <alias> : true if a non-interactive key-auth login works.
# BatchMode means a passphrase-protected key not in ssh-agent fails here (that's
# fine — the caller falls back to a TCP-open check).
_vscode_ssh_auth_ok() {
  "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null "$1" true >/dev/null 2>&1
}

target_vscode_run_args() {
  local kit; kit="$(vscode_kit_dir)" || return 0
  printf -- '--kit\n%s\n' "$kit"
}

target_vscode_check() {
  # $1 = mode (open|doctor). Same checks for both.
  local ok_cli=1
  if have "$CODE_BIN"; then
    printf 'ok\tVS Code CLI '\''%s'\'' on PATH\t\n' "$CODE_BIN"
  else
    printf 'fail\tVS Code CLI '\''%s'\'' not on PATH\tIn VS Code: Command Palette -> "Shell Command: Install '\''code'\'' command in PATH".\n' "$CODE_BIN"
    ok_cli=0
  fi
  if [[ "$ok_cli" == 1 ]]; then
    if "$CODE_BIN" --list-extensions 2>/dev/null | grep -qi "$SBX_VSCODE_EXT"; then
      printf 'ok\tRemote-SSH extension (%s) installed\t\n' "$SBX_VSCODE_EXT"
    else
      printf 'fail\tRemote-SSH extension (%s) not installed\t%s --install-extension %s\n' \
        "$SBX_VSCODE_EXT" "$CODE_BIN" "$SBX_VSCODE_EXT"
    fi
  fi
  if have "$SSH_BIN"; then printf 'ok\tssh client '\''%s'\'' on PATH\t\n' "$SSH_BIN"
  else printf 'fail\tssh client '\''%s'\'' not on PATH\tinstall OpenSSH\n' "$SSH_BIN"; fi
  if vscode_kit_dir >/dev/null; then
    printf 'ok\tremote-ssh kit found (%s)\t\n' "$(vscode_kit_dir)"
  else
    printf 'fail\tremote-ssh kit not found (installs sshd in the sandbox)\treinstall sbx-ide (make install) or set SBX_VSCODE_KIT_DIR\n'
  fi
  local priv; priv="$(vscode_privkey)"
  if [[ -f "$priv" && -f "${priv}.pub" ]]; then
    printf 'ok\tdedicated SSH key present (%s)\t\n' "$priv"
  elif [[ "$SBX_VSCODE_AUTOGEN_KEY" == 1 ]] && have ssh-keygen; then
    printf 'ok\twill generate a dedicated passwordless SSH key (%s)\t\n' "$priv"
  elif ! have ssh-keygen; then
    printf 'fail\tno SSH key (%s) and ssh-keygen not on PATH\tinstall OpenSSH, or set SBX_VSCODE_SSH_KEY to an existing key\n' "$priv"
  else
    printf 'fail\tno SSH key (%s) and autogen is off\tssh-keygen -t ed25519 -N '\'''\'' -f %s   (or set SBX_VSCODE_AUTOGEN_KEY=1)\n' "$priv" "$priv"
  fi
}

# vscode_preseed <name> <ws> : best-effort pre-install of the VS Code server (at
# the host's exact commit) and the workspace's recommended extensions, so the
# first connect attaches instead of downloading ~140 MB over the sandbox proxy
# (which, if the link churns, re-downloads in a loop). Never fatal.
vscode_preseed() {
  local name="$1" ws="$2" commit exts ext_json
  have "$CODE_BIN" || return 0
  commit="$("$CODE_BIN" --version 2>/dev/null | sed -n '2p' | tr -d '[:space:]')"
  [[ -n "$commit" ]] || return 0
  info "Pre-seeding VS Code server (commit ${commit})…"
  # sh -c body runs inside the sandbox; $COMMIT/$HOME expand there — intentional.
  # shellcheck disable=SC2016
  "$SBX_BIN" "$SBX_CMD_EXEC" --env COMMIT="$commit" "$name" -- sh -c '
    set -e
    SRV="$HOME/.vscode-server/cli/servers/Stable-$COMMIT/server"
    [ -x "$SRV/bin/code-server" ] && exit 0
    case "$(uname -m)" in aarch64|arm64) A=arm64;; *) A=x64;; esac
    URL="https://update.code.visualstudio.com/commit:$COMMIT/server-linux-$A/stable"
    T="$(mktemp)"; curl -fsSL "$URL" -o "$T"; mkdir -p "$SRV"
    tar -xzf "$T" -C "$SRV" --strip-components=1; rm -f "$T"
  ' </dev/null >/dev/null 2>&1 || warn "server pre-seed failed — VS Code will download on connect."

  ext_json="$ws/.vscode/extensions.json"
  [[ -f "$ext_json" ]] || return 0
  exts="$(grep -oE '"[A-Za-z0-9][A-Za-z0-9_-]+\.[A-Za-z0-9][A-Za-z0-9_-]+"' "$ext_json" 2>/dev/null | tr -d '"' | sort -u | tr '\n' ' ')"
  [[ -n "$exts" ]] || return 0
  info "Pre-installing extensions: $exts"
  # shellcheck disable=SC2016
  "$SBX_BIN" "$SBX_CMD_EXEC" --env COMMIT="$commit" --env EXTS="$exts" "$name" -- sh -c '
    CODE="$HOME/.vscode-server/cli/servers/Stable-$COMMIT/server/bin/code-server"
    [ -x "$CODE" ] || exit 0
    for e in $EXTS; do "$CODE" --install-extension "$e" --force >/dev/null 2>&1 || true; done
  ' </dev/null >/dev/null 2>&1 || true
}

target_vscode_launch() {
  local name="$1" ws="$2" created="$3" dry_run="$4" no_open="$5" print_uri="$6"
  local alias="${SBX_VSCODE_HOST_PREFIX}${name}"
  local uri="vscode-remote://ssh-remote+${alias}${ws}"
  local pk out port

  if [[ "$dry_run" == 1 ]]; then
    if [[ "$print_uri" == 1 ]]; then printf '%s\n' "$uri"; return 0; fi
    info "[dry-run] would inject key, publish 127.0.0.1:<port>->22, write ~/.ssh/config ($alias),"
    info "[dry-run] then launch: TMPDIR=/tmp $CODE_BIN --remote ssh-remote+$alias \"$ws\""
    return 0
  fi

  # 0. the sandbox must have been created WITH our remote-ssh kit (real sshd).
  # `--kit` only applies on CREATE, so a REUSED sandbox made without it (e.g. one
  # that predates --vscode) has no sshd. Detect that and guide, rather than
  # failing cryptically mid-flow. We never rm it automatically.
  if ! sbx_has_remote_ssh_kit "$name"; then
    if [[ "$created" == 1 ]]; then
      err "The remote-ssh kit did not apply when creating '$name' (no sshd config inside)."
      hint "Check that 'sbx run <agent> --kit' is supported on this host. See docs/VSCODE-NOTES.md."
    else
      err "Sandbox '$name' was created WITHOUT the remote-ssh kit, so it has no sshd to connect to."
      hint "This happens for a sandbox made before --vscode (or by another tool). Recreate it:"
      cmd "$SBX_BIN $SBX_CMD_RM ${SBX_RM_FORCE_FLAG:+$SBX_RM_FORCE_FLAG }$name && ${SBX_IDE_PROG:-sbx-ide} open '$ws' --vscode"
      hint "(sbx-ide won't remove it for you.)"
    fi
    return 1
  fi

  # 1. dedicated passwordless key (generated on first use), then inject its pub
  if ! vscode_ensure_key; then
    err "No usable SSH key for VS Code, and none could be generated."
    hint "Install ssh-keygen, or point SBX_VSCODE_SSH_KEY at an existing key."
    return 1
  fi
  pk="$(vscode_pubkey)"
  if ! out="$(sbx_inject_pubkey "$name" "$pk")"; then
    err "Could not inject the SSH key into '$name'."; [[ -n "$out" ]] && hint "sbx: ${out//$'\n'/ }"; return 1
  fi

  # 2. publish the sandbox's sshd port to a host loopback port (reuse if present)
  port="$(sbx_published_ssh_port "$name")"
  if [[ -z "$port" ]]; then
    port="$(free_tcp_port "$SBX_VSCODE_SSH_PORT_BASE")"
    if ! out="$(sbx_publish_ssh_port "$name" "$port")"; then
      err "Could not publish the sshd port for '$name'."; [[ -n "$out" ]] && hint "sbx: ${out//$'\n'/ }"; return 1
    fi
  fi
  info "sshd published at 127.0.0.1:$port"

  # 3. ~/.ssh/config Host block (inside our markers), pinned to the dedicated key
  ssh_config_write_block "$alias" "$port" "$SBX_VSCODE_SSH_USER" "$(vscode_privkey)"

  # 4. Reach OUR sshd (loopback) — NOT sandboxd's SSH. Distinguish a real
  #    connection failure from a mere non-interactive AUTH miss: a passphrase-
  #    protected key that isn't in ssh-agent fails a BatchMode probe even though
  #    the link is fine and VS Code could prompt. So: try key auth; if it never
  #    succeeds, fall back to a TCP-open check — port open ⇒ auth issue (proceed,
  #    VS Code prompts); port closed ⇒ hard failure.
  local authed=0 tries="$SBX_VSCODE_SSH_RETRIES"
  while [[ "$tries" -gt 0 ]]; do
    if _vscode_ssh_auth_ok "$alias"; then authed=1; break; fi
    tries=$((tries - 1))
    [[ "$tries" -gt 0 && "$SBX_VSCODE_SSH_RETRY_DELAY" != 0 ]] && sleep "$SBX_VSCODE_SSH_RETRY_DELAY"
  done
  if [[ "$authed" == 1 ]]; then
    success "VS Code SSH reachable: $alias (127.0.0.1:$port, key auth OK)"
  elif tcp_reachable 127.0.0.1 "$port"; then
    warn "sshd is up at 127.0.0.1:$port, but non-interactive key auth didn't succeed."
    hint "Your SSH key likely has a passphrase not loaded in ssh-agent. VS Code will"
    hint "prompt for it on connect. For a promptless launch, load it first:"
    cmd "ssh-add ${pk%.pub}"
  else
    err "sshd never became reachable at 127.0.0.1:$port for '$name'."
    hint "See docs/VSCODE-NOTES.md. sbx-ide will NOT fall back to sandboxd's SSH (it retry-loops)."
    return 1
  fi

  if [[ "$print_uri" == 1 ]]; then printf '%s\n' "$uri"; return 0; fi

  [[ "$SBX_VSCODE_PRESEED" == 1 ]] && vscode_preseed "$name" "$ws"

  if [[ "$no_open" == 1 ]]; then
    success "Sandbox ready. Open it with:"; cmd "TMPDIR=/tmp $CODE_BIN --remote ssh-remote+$alias \"$ws\""; return 0
  fi
  if ! have "$CODE_BIN"; then
    warn "VS Code CLI ('$CODE_BIN') not on PATH — sandbox is ready anyway."
    cmd "TMPDIR=/tmp $CODE_BIN --remote ssh-remote+$alias \"$ws\""; return 0
  fi
  # macOS Remote-SSH bug (vscode-remote-release #11672/#11676): the default long
  # $TMPDIR overflows the 104-char unix-socket path → reconnect loop. A short
  # TMPDIR avoids it. Only affects a freshly launched editor.
  info "Launching VS Code → $alias:$ws"
  TMPDIR=/tmp "$CODE_BIN" --remote "ssh-remote+${alias}" "$ws" >/dev/null 2>&1 \
    || TMPDIR=/tmp "$CODE_BIN" --remote "ssh-remote+${alias}" "$ws"
  _launch_success "$name" "$created" "VS Code"
}
