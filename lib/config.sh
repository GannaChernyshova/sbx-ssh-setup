# shellcheck shell=bash
# config.sh — the persisted user preference (the default IDE target) and the
# rules for resolving which target a given invocation should use.
#
# Sourced by the dispatcher after common.sh. Depends only on common.sh.

# --- Config file location (XDG-respecting) --------------------------------
# ${XDG_CONFIG_HOME:-~/.config}/sbx-ide/config, one KEY=value per line.
config_dir()  { printf '%s/sbx-ide' "${XDG_CONFIG_HOME:-$HOME/.config}"; }
config_file() { printf '%s/config' "$(config_dir)"; }

# config_get <key> : print the value for <key> from the config file, or empty.
config_get() {
  local f; f="$(config_file)"
  [[ -f "$f" ]] || return 0
  # Last assignment wins; ignore comments/blank lines and surrounding spaces.
  awk -F= -v k="$1" '
    /^[[:space:]]*#/ {next}
    {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)}
    $1==k {v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)}
    END{ if (v!="") print v }' "$f"
}

# config_set <key> <value> : upsert KEY=value, creating the dir (0700) and file
# (0600) if needed. Rewrites atomically so a crash can't truncate the file.
config_set() {
  local key="$1" val="$2" dir f tmp
  dir="$(config_dir)"; f="$(config_file)"
  mkdir -p "$dir"; chmod 0700 "$dir" 2>/dev/null || true
  tmp="$(mktemp "${TMPDIR:-/tmp}/sbx-ide-cfg.XXXXXX")"
  if [[ -f "$f" ]]; then
    awk -F= -v k="$key" '
      /^[[:space:]]*#/ {print; next}
      { line=$0; key2=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", key2)
        if (key2==k) next; print line }' "$f" >"$tmp"
  fi
  printf '%s=%s\n' "$key" "$val" >>"$tmp"
  mv "$tmp" "$f"
  chmod 0600 "$f" 2>/dev/null || true
}

# --- Target resolution -----------------------------------------------------
# Precedence (highest first):
#   1. explicit --cursor/--vscode flag  (passed in as $1, may be empty)
#   2. per-invocation env  SBX_IDE_TARGET
#   3. config default      (default_target=)
#   4. built-in default    cursor
#
# resolve_target [flag] : prints "<target>\t<source>" (source is one of
# flag|env|config|default). Callers split on the tab.
resolve_target() {
  local flag="${1:-}"
  if [[ -n "$flag" ]]; then printf '%s\tflag\n' "$flag"; return 0; fi
  if [[ -n "${SBX_IDE_TARGET:-}" ]]; then printf '%s\tenv\n' "$SBX_IDE_TARGET"; return 0; fi
  local cfg; cfg="$(config_get default_target)"
  if [[ -n "$cfg" ]]; then printf '%s\tconfig\n' "$cfg"; return 0; fi
  printf 'cursor\tdefault\n'
}

# ---------------------------------------------------------------------------
# ~/.ssh/config Host blocks for the VS Code target.
#
# Each block is wrapped in per-alias markers ("# sbx-ide ssh BEGIN <alias>" …
# "# sbx-ide ssh END <alias>") so `clean` and `uninstall` can find, report, and
# remove exactly the blocks we wrote — and never touch anything else (notably
# sbx's own wildcard `*.sbx` block).
# ---------------------------------------------------------------------------
ssh_config_path() { printf '%s/.ssh/config' "$HOME"; }

# ssh_config_remove_block <alias> : strip our block for <alias>, if present.
ssh_config_remove_block() {
  local alias="$1" f b e tmp
  f="$(ssh_config_path)"; [[ -f "$f" ]] || return 0
  b="$SBX_SSH_BLOCK_BEGIN $alias"; e="$SBX_SSH_BLOCK_END $alias"
  grep -qF "$b" "$f" 2>/dev/null || return 0
  tmp="$(mktemp)"
  awk -v b="$b" -v e="$e" '$0==b{skip=1;next} $0==e{skip=0;next} !skip{print}' "$f" >"$tmp"
  mv "$tmp" "$f"; chmod 600 "$f" 2>/dev/null || true
}

# ssh_config_write_block <alias> <port> <user> [identity_file] : (re)write the
# loopback Host block for <alias>. Rewrites fresh so a changed port is picked up.
# Strict host checking is off and known-hosts is /dev/null because the link is
# loopback-only and the sandbox's host keys regenerate on each create. When an
# identity file is given, it is pinned with IdentitiesOnly so ONLY that key is
# offered (the sandbox authorizes only it; the user's other keys stay out).
ssh_config_write_block() {
  local alias="$1" port="$2" user="$3" identity="${4:-}" f
  f="$(ssh_config_path)"
  mkdir -p "$(dirname "$f")"; chmod 700 "$(dirname "$f")" 2>/dev/null || true
  ssh_config_remove_block "$alias"
  {
    printf '\n%s %s\n' "$SBX_SSH_BLOCK_BEGIN" "$alias"
    printf 'Host %s\n' "$alias"
    printf '  HostName 127.0.0.1\n  Port %s\n  User %s\n' "$port" "$user"
    if [[ -n "$identity" ]]; then
      printf '  IdentityFile %s\n  IdentitiesOnly yes\n' "$identity"
    fi
    printf '  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n'
    printf '  ServerAliveInterval 15\n  ServerAliveCountMax 4\n  TCPKeepAlive yes\n'
    printf '%s %s\n' "$SBX_SSH_BLOCK_END" "$alias"
  } >> "$f"
  chmod 600 "$f" 2>/dev/null || true
}

# ssh_config_write_codex_alias <alias> : (re)write an EMPTY concrete Host block
# for <alias> so Codex auto-discovers the sandbox — it enumerates concrete Host
# aliases and ignores the pattern-only `Host *<suffix>` block sbx manages. The
# block carries NO options: every setting is inherited from that managed block
# via `ssh -G`, so nothing is duplicated (and a managed value is never copied out
# of place). Wrapped in the same per-alias markers as the VS Code block, so
# `clean`/uninstall find and remove it with the existing machinery.
ssh_config_write_codex_alias() {
  local alias="$1" f
  f="$(ssh_config_path)"
  mkdir -p "$(dirname "$f")"; chmod 700 "$(dirname "$f")" 2>/dev/null || true
  ssh_config_remove_block "$alias"
  {
    printf '\n%s %s\n' "$SBX_SSH_BLOCK_BEGIN" "$alias"
    printf '# Concrete alias so Codex auto-discovers this sandbox (it ignores '\''Host *%s'\'').\n' "$SBX_SSH_SUFFIX"
    printf '# All options inherit from the sbx-managed '\''Host *%s'\'' block via '\''ssh -G'\''.\n' "$SBX_SSH_SUFFIX"
    printf 'Host %s\n' "$alias"
    printf '%s %s\n' "$SBX_SSH_BLOCK_END" "$alias"
  } >> "$f"
  chmod 600 "$f" 2>/dev/null || true
}

# ssh_config_our_aliases : list aliases we have blocks for (for uninstall report).
ssh_config_our_aliases() {
  local f; f="$(ssh_config_path)"; [[ -f "$f" ]] || return 0
  sed -nE "s/^${SBX_SSH_BLOCK_BEGIN} (.*)$/\1/p" "$f"
}

# --- Per-target agent resolution ------------------------------------------
# Which sbx agent/template the sandbox RUNS. Cursor brings its own IDE agent, so
# `shell` is fine; vanilla VS Code doesn't, so you may want e.g. `claude` in the
# box. Precedence (highest first):
#   1. --agent <name> flag           (this run)
#   2. SBX_AGENT_<TARGET> env         (e.g. SBX_AGENT_VSCODE)
#   3. config  agent_<target>         (persisted, per target)
#   4. SBX_DEFAULT_AGENT              (env, or the built-in 'shell')
#
# resolve_agent <target> [flag] : prints "<agent>\t<source>" (source ∈
# flag|env|config|default). Callers split on the tab.
resolve_agent() {
  local target="$1" flag="${2:-}" tvar tenv cfg
  if [[ -n "$flag" ]]; then printf '%s\tflag\n' "$flag"; return 0; fi
  tvar="SBX_AGENT_$(printf '%s' "$target" | tr '[:lower:]' '[:upper:]')"
  tenv="${!tvar:-}"
  if [[ -n "$tenv" ]]; then printf '%s\tenv\n' "$tenv"; return 0; fi
  cfg="$(config_get "agent_${target}")"
  if [[ -n "$cfg" ]]; then printf '%s\tconfig\n' "$cfg"; return 0; fi
  printf '%s\tdefault\n' "$SBX_DEFAULT_AGENT"
}

# source_label <source> : human phrasing for a resolution source.
source_label() {
  case "$1" in
    flag)    printf 'command-line flag' ;;
    env)     printf 'SBX_IDE_TARGET env var' ;;
    config)  printf 'config file (%s)' "$(config_file)" ;;
    default) printf 'built-in default' ;;
    *)       printf '%s' "$1" ;;
  esac
}
