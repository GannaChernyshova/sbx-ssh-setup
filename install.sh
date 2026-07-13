#!/usr/bin/env bash
#
# install.sh — install the sbx-codex toolkit (macOS / Linux).
#
# Copies the bin/ commands and lib/ helpers to a prefix (default ~/.local),
# checks that the bin dir is on PATH, and runs sbx-doctor at the end.
#
#   ./install.sh                     # install (or upgrade) in ~/.local
#   ./install.sh --update            # same thing; explicit "upgrade in place"
#   PREFIX=/usr/local ./install.sh   # brew-style prefix (may need sudo)
#   ./install.sh --uninstall         # remove what we installed
#   ./install.sh --version           # print the version of this source tree
#
# Install is idempotent and version-aware. For fleet deployment (Jamf/Intune),
# run non-interactively: it makes no prompts and exits non-zero only on a real
# install failure (a failing doctor is reported but does not fail the install).
#
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/lib/sbx-codex"
COMMANDS=(sbx-open sbx-ls sbx-clean sbx-doctor)
SRC_VERSION="$(tr -d '[:space:]' < "$SRC/VERSION" 2>/dev/null || echo unknown)"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; Z=$'\033[0m'
else B=''; G=''; Y=''; R=''; D=''; Z=''; fi
say()  { printf '%s\n' "$*"; }
good() { printf '%s✅%s %s\n' "$G" "$Z" "$*"; }
warnx(){ printf '%s⚠️ %s %s\n' "$Y" "$Z" "$*"; }
bad()  { printf '%s❌%s %s\n' "$R" "$Z" "$*" >&2; }

usage() {
  cat <<EOF
${B}install.sh${Z} — install / upgrade the sbx-codex toolkit (v$SRC_VERSION)

USAGE
  ./install.sh [--update | --uninstall | --version]

OPTIONS
  --update     Upgrade an existing install in place.
  --uninstall  Remove installed commands + libs.
  --version    Print the version of this source tree and exit.

ENV
  PREFIX   install prefix (default: \$HOME/.local)
           binaries -> \$PREFIX/bin, libraries -> \$PREFIX/lib/sbx-codex
EOF
}

installed_version() { [[ -f "$LIB_DIR/VERSION" ]] && tr -d '[:space:]' < "$LIB_DIR/VERSION"; }

uninstall() {
  say "Removing sbx-codex from $PREFIX …"
  local c
  for c in "${COMMANDS[@]}"; do rm -f "$BIN_DIR/$c" && say "  removed $BIN_DIR/$c" || true; done
  rm -rf "$LIB_DIR" && say "  removed $LIB_DIR" || true
  good "Uninstalled."
  exit 0
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  -V|--version) say "$SRC_VERSION"; exit 0 ;;
  --update|--upgrade) ;;   # same code path as install
  --uninstall) uninstall ;;
  "") ;;
  *) bad "unknown option: $1"; usage; exit 2 ;;
esac

OLD_VERSION="$(installed_version || true)"
if [[ -n "$OLD_VERSION" ]]; then
  if [[ "$OLD_VERSION" == "$SRC_VERSION" ]]; then
    say "${B}Reinstalling sbx-codex v$SRC_VERSION${Z} (already installed)"
  else
    say "${B}Upgrading sbx-codex${Z} $OLD_VERSION ${B}→${Z} $SRC_VERSION"
  fi
else
  say "${B}Installing sbx-codex v$SRC_VERSION${Z}"
fi
say "  from: $SRC"
say "  bin:  $BIN_DIR"
say "  lib:  $LIB_DIR"

mkdir -p "$BIN_DIR" "$LIB_DIR"

install -m 0644 "$SRC/lib/common.sh"        "$LIB_DIR/common.sh"
install -m 0644 "$SRC/lib/sbx-interface.sh" "$LIB_DIR/sbx-interface.sh"
install -m 0644 "$SRC/lib/codex.sh"         "$LIB_DIR/codex.sh"
install -m 0644 "$SRC/VERSION"              "$LIB_DIR/VERSION"
good "installed libraries"

for c in "${COMMANDS[@]}"; do
  install -m 0755 "$SRC/bin/$c" "$BIN_DIR/$c"
  good "installed $c"
done

case ":$PATH:" in
  *":$BIN_DIR:"*) good "$BIN_DIR is on your PATH" ;;
  *)
    warnx "$BIN_DIR is NOT on your PATH."
    shell_rc="$HOME/.zshrc"; [[ "${SHELL:-}" == *bash ]] && shell_rc="$HOME/.bashrc"
    say "  Add it with:"
    say "    ${D}echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> $shell_rc${Z}"
    say "    ${D}exec \$SHELL -l${Z}"
    ;;
esac

say
say "${B}Running sbx-doctor …${Z}"
if "$BIN_DIR/sbx-doctor"; then :; else
  warnx "sbx-doctor reported issues above — fix them before using sbx-open."
fi

say
good "Done — sbx-codex v$SRC_VERSION. Open your first project with:  ${B}sbx-open ~/src/acme-api${Z}"
say "  ${D}Upgrade later: pull the latest source, then re-run ./install.sh (or: make update).${Z}"
