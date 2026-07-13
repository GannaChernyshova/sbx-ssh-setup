# shellcheck shell=bash
# common.sh — shared UI + utility helpers for the sbx-cursor toolkit.
#
# Sourced by every bin/ command. Contains NO sbx-specific knowledge — that
# lives in lib/sbx-interface.sh. Keep this file dependency-free (POSIX-ish
# bash, no jq/awk requirement) so it can be sourced very early.

# ---------------------------------------------------------------------------
# Colorized but pipe-safe output.
# Colors are emitted only when stdout is a TTY and NO_COLOR is unset, so piped
# or redirected output stays clean.
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
fi

# Diagnostics go to stderr so they never contaminate parseable stdout.
info()    { printf '%s\n' "${C_BLUE}•${C_RESET} $*" >&2; }
success() { printf '%s\n' "${C_GREEN}✅${C_RESET} $*" >&2; }
warn()    { printf '%s\n' "${C_YELLOW}⚠️ ${C_RESET} $*" >&2; }
err()     { printf '%s\n' "${C_RED}❌${C_RESET} $*" >&2; }
die()     { err "$*"; exit 1; }
hint()    { printf '%s\n' "   ${C_DIM}$*${C_RESET}" >&2; }
heading() { printf '\n%s\n' "${C_BOLD}$*${C_RESET}" >&2; }

# A command the user can copy/paste, rendered so it stands out.
cmd() { printf '%s\n' "   ${C_CYAN}\$ $*${C_RESET}" >&2; }

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------

# have <bin> : true if a command exists on PATH.
have() { command -v "$1" >/dev/null 2>&1; }

# toolkit_version : print the installed sbx-cursor version. Reads the VERSION
# file shipped alongside the libs (installed) or at the repo root (dev), or the
# SBX_CURSOR_VERSION override.
toolkit_version() {
  [[ -n "${SBX_CURSOR_VERSION:-}" ]] && { printf '%s' "$SBX_CURSOR_VERSION"; return; }
  local d f
  d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for f in "$d/VERSION" "$d/../VERSION"; do
    [[ -f "$f" ]] && { tr -d '[:space:]' < "$f"; return; }
  done
  printf 'unknown'
}

# trim : strip leading/trailing whitespace from stdin.
trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# sanitize_name <string> : produce a DNS-ish sandbox name.
# Lowercase, non-alphanumerics -> '-', collapse repeats, trim leading/trailing
# '-', and guarantee a non-empty result.
sanitize_name() {
  local raw="$1" out
  out=$(printf '%s' "$raw" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]/-/g' -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')
  [[ -n "$out" ]] || out="sandbox"
  printf '%s' "$out"
}

# version_ge <a> <b> : true if version a >= version b (dotted numeric compare).
# Ignores any non-numeric prefix/suffix (e.g. "sbx 0.35.2" -> "0.35.2").
version_ge() {
  local a b
  a=$(printf '%s' "$1" | grep -oE '[0-9]+(\.[0-9]+)*' | head -n1)
  b=$(printf '%s' "$2" | grep -oE '[0-9]+(\.[0-9]+)*' | head -n1)
  [[ -n "$a" && -n "$b" ]] || return 1
  # Highest version first; if that equals a, then a >= b.
  [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -n1)" == "$a" ]]
}

# confirm <prompt> : interactive yes/no. Returns 0 on yes. Non-interactive
# (no TTY) returns 1 so callers must require an explicit --yes flag instead.
confirm() {
  local reply
  [[ -t 0 ]] || return 1
  printf '%s [y/N] ' "$1" >&2
  read -r reply || return 1
  [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]
}

# abspath <path> : absolute, symlink-resolved path without requiring the
# target to be a directory. Falls back gracefully if realpath is absent.
abspath() {
  local p="$1"
  if have realpath; then
    realpath -m -- "$p" 2>/dev/null && return 0
  fi
  # Portable fallback.
  case "$p" in
    /*) printf '%s' "$p" ;;
    *)  printf '%s/%s' "$(pwd)" "$p" ;;
  esac
}
