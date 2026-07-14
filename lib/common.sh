# shellcheck shell=bash
# common.sh — shared UI + utility helpers for the sbx-ide toolkit.
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

# toolkit_version : print the installed sbx-ide version. Reads the VERSION
# file shipped alongside the libs (installed) or at the repo root (dev), or the
# SBX_CURSOR_VERSION override.
toolkit_version() {
  [[ -n "${SBX_IDE_VERSION:-}" ]] && { printf '%s' "$SBX_IDE_VERSION"; return; }
  [[ -n "${SBX_CURSOR_VERSION:-}" ]] && { printf '%s' "$SBX_CURSOR_VERSION"; return; }  # back-compat
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

# abspath <path> : absolute, symlink-resolved, canonicalized path.
#
# Portability note: macOS ships a BSD `realpath` that does NOT accept GNU's
# `-m` flag, so `realpath -m` silently fails there and canonicalization would
# degrade to a naive join that never collapses ./ or .. or resolves symlinks.
# For an existing directory (the only thing `open` mounts) `cd … && pwd -P` is
# the reliable cross-platform canonicalizer, so we try that FIRST, then fall
# back through realpath variants and finally a naive join.
abspath() {
  local p="$1"
  if [[ -d "$p" ]]; then
    ( cd "$p" 2>/dev/null && pwd -P ) && return 0
  fi
  if have realpath; then
    realpath -m -- "$p" 2>/dev/null && return 0   # GNU
    realpath    -- "$p" 2>/dev/null && return 0   # BSD (path must exist)
    realpath       "$p" 2>/dev/null && return 0   # BSD without `--`
  fi
  # Last-resort naive join (no canonicalization possible).
  case "$p" in
    /*) printf '%s' "$p" ;;
    *)  printf '%s/%s' "$(pwd)" "$p" ;;
  esac
}

# tcp_reachable <host> <port> : true if something is listening (bash /dev/tcp).
# (SBX_STUB_TCP_OPEN=1 forces true — a test seam; unset in real use.)
tcp_reachable() {
  [[ "${SBX_STUB_TCP_OPEN:-}" == 1 ]] && return 0
  if (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null; then { exec 3>&-; } 2>/dev/null; return 0; fi
  return 1
}

# free_tcp_port <start> : first free loopback TCP port >= <start> (probed with
# bash's /dev/tcp). Falls back to <start> if none found in a small window.
free_tcp_port() {
  local start="${1:-2222}" p max
  p="$start"; max=$((start + 200))
  while [[ "$p" -lt "$max" ]]; do
    # A successful connect means something is listening → port in use.
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
      printf '%s' "$p"; return 0
    fi
    { exec 3>&-; } 2>/dev/null || true
    p=$((p + 1))
  done
  printf '%s' "$start"
}

# count_child_git_repos <dir> : number of *immediate* subdirectories of <dir>
# that are themselves git repos (contain a .git). This detects a "parent of
# many repos" mount, which would widen the blast radius past a single project.
count_child_git_repos() {
  local dir="$1" n=0 d
  shopt -s nullglob
  for d in "$dir"/*/; do
    [[ -e "${d}.git" ]] && n=$((n+1))
  done
  shopt -u nullglob
  printf '%s' "$n"
}
