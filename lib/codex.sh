# shellcheck shell=bash
# codex.sh — everything specific to the OpenAI Codex desktop app.
#
# Two jobs the Codex GUI cannot do from a CLI, which we do for it:
#   1. Make a sandbox host DISCOVERABLE. Codex reads *concrete* host aliases
#      from ~/.ssh/config and ignores pattern hosts. `sbx ssh setup` only writes
#      a pattern (`Host *.sbx`), so Codex never lists the sandbox. We add a
#      concrete `Host <name>.sbx` alias inside a managed region; transport
#      (ProxyCommand/User) is still supplied by sbx's existing `*.sbx` block,
#      which also matches the concrete host.
#   2. Launch the app so the user is one screen away from the final,
#      officially-supported click (New remote project → pick host → pick folder).
#
# There is no supported CLI/deep-link to register the remote *project* itself
# (OpenAI tracking issue #21554), so we deliberately stop at launch + handoff
# rather than poking at ~/.codex/.codex-global-state.json, which the app
# overwrites and which changes between versions.

# --- Managed SSH config region -------------------------------------------
: "${SSH_CONFIG_FILE:=$HOME/.ssh/config}"
_CODEX_BEGIN="# >>> sbx-codex managed (do not edit inside this region) >>>"
_CODEX_END="# <<< sbx-codex managed <<<"

# _codex_ensure_ssh_config : make sure ~/.ssh and the config file exist with
# safe permissions.
_codex_ensure_ssh_config() {
  local dir; dir="$(dirname "$SSH_CONFIG_FILE")"
  [[ -d "$dir" ]] || { mkdir -p "$dir"; chmod 700 "$dir"; }
  [[ -f "$SSH_CONFIG_FILE" ]] || { : > "$SSH_CONFIG_FILE"; chmod 600 "$SSH_CONFIG_FILE"; }
}

# _codex_region_names : print the sandbox names currently in the managed region,
# one per line (from the `# sbx-codex: <name>` marker comments).
_codex_region_names() {
  [[ -f "$SSH_CONFIG_FILE" ]] || return 0
  awk -v b="$_CODEX_BEGIN" -v e="$_CODEX_END" '
    $0 == b {inreg=1; next}
    $0 == e {inreg=0; next}
    inreg && /^[[:space:]]*# sbx-codex: / { sub(/^[[:space:]]*# sbx-codex: /, ""); print }
  ' "$SSH_CONFIG_FILE"
}

# _codex_strip_region <file> : print <file> with the managed region removed.
_codex_strip_region() {
  awk -v b="$_CODEX_BEGIN" -v e="$_CODEX_END" '
    $0 == b {inreg=1; next}
    $0 == e {inreg=0; next}
    !inreg {print}
  ' "$1"
}

# _codex_write_region <names...> : rewrite the config so the managed region
# contains exactly one concrete Host alias per given name (sorted, de-duped).
# With no names, the region is removed entirely.
_codex_write_region() {
  _codex_ensure_ssh_config
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/sbx-codex.XXXXXX")"

  # Everything outside our region, trailing blank lines trimmed.
  _codex_strip_region "$SSH_CONFIG_FILE" | sed -e :a -e '/^\n*$/{$d;N;ba}' > "$tmp"

  if [[ "$#" -gt 0 ]]; then
    local names n
    names="$(printf '%s\n' "$@" | sort -u)"
    [[ -s "$tmp" ]] && printf '\n' >> "$tmp"
    printf '%s\n' "$_CODEX_BEGIN" >> "$tmp"
    while IFS= read -r n; do
      [[ -n "$n" ]] || continue
      {
        printf 'Host %s%s\n' "$n" "$SBX_SSH_SUFFIX"
        printf '    # sbx-codex: %s\n' "$n"
        printf '    HostName %s%s\n' "$n" "$SBX_SSH_SUFFIX"
      } >> "$tmp"
    done <<< "$names"
    printf '%s\n' "$_CODEX_END" >> "$tmp"
  fi

  chmod 600 "$tmp"
  mv "$tmp" "$SSH_CONFIG_FILE"
}

# codex_ssh_has_alias <name> : true if a concrete alias exists for <name>.
codex_ssh_has_alias() {
  _codex_region_names | grep -qxF "$1"
}

# codex_ssh_add_alias <name> : idempotently add a concrete Host alias so Codex
# auto-discovers the sandbox.
codex_ssh_add_alias() {
  local name="$1" existing
  existing="$(_codex_region_names)"
  # shellcheck disable=SC2086  # word-split intended: names are DNS-safe tokens
  _codex_write_region $existing "$name"
}

# codex_ssh_remove_alias <name> : drop the concrete alias for <name>.
codex_ssh_remove_alias() {
  local name="$1" keep
  keep="$(_codex_region_names | grep -vxF "$name" || true)"
  # shellcheck disable=SC2086
  _codex_write_region $keep
}

# --- Codex desktop app ----------------------------------------------------

# _codex_os : macos | linux | windows | unknown
_codex_os() {
  case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    darwin*|Darwin*)          echo macos ;;
    linux*|Linux*)            echo linux ;;
    msys*|cygwin*|win*|MINGW*) echo windows ;;
    *)                        echo unknown ;;
  esac
}

# codex_app_present : true if the Codex desktop app appears to be installed.
codex_app_present() {
  case "$(_codex_os)" in
    macos)
      [[ -d "/Applications/Codex.app" || -d "$HOME/Applications/Codex.app" ]] && return 0
      open -Ra "Codex" >/dev/null 2>&1 ;;
    linux)
      have codex-app || have codex ;;   # best-effort; desktop app is mac/win
    *)
      return 1 ;;
  esac
}

# codex_launch : open the Codex desktop app. Best-effort; returns non-zero if it
# could not be launched (caller falls back to printed instructions).
# CODEX_LAUNCH_OVERRIDE, if set, is run instead — a seam for tests and for
# unusual installs where the app is launched some other way.
codex_launch() {
  if [[ -n "${CODEX_LAUNCH_OVERRIDE:-}" ]]; then
    eval "$CODEX_LAUNCH_OVERRIDE"; return $?
  fi
  case "$(_codex_os)" in
    macos) open -a "Codex" >/dev/null 2>&1 ;;
    linux) { have codex-app && codex-app >/dev/null 2>&1 & } || { have xdg-open && xdg-open "codex://" >/dev/null 2>&1; } ;;
    *)     return 1 ;;
  esac
}
