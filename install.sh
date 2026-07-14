#!/usr/bin/env bash
#
# install.sh — install the sbx-ide toolkit.
#
# Copies the bin/ commands (sbx-ide + deprecated shims) and lib/ helpers to a
# prefix (default ~/.local), optionally adds the bin dir to PATH inside clearly
# marked comment blocks, and runs `sbx-ide doctor` at the end.
#
#   ./install.sh                     # install (or upgrade) in ~/.local
#   ./install.sh --update            # same thing; explicit "upgrade in place"
#   PREFIX=/usr/local ./install.sh   # brew-style prefix (may need sudo)
#   ./install.sh --uninstall         # graceful, auditable teardown
#   ./install.sh --version           # print the version of this source tree
#   SBX_IDE_NO_PATH=1 ./install.sh   # do not touch shell rc files
#
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/lib/sbx-ide"
OLD_LIB_DIR="$PREFIX/lib/sbx-cursor"        # migrated/removed on install+uninstall
CORE_CMD="sbx-ide"
SHIMS=(sbx-open sbx-doctor sbx-ls sbx-clean)
ALL_CMDS=("$CORE_CMD" "${SHIMS[@]}")
SRC_VERSION="$(tr -d '[:space:]' < "$SRC/VERSION" 2>/dev/null || echo unknown)"

# PATH-block markers. We migrate the old sbx-cursor markers too.
BEGIN_MARK="# sbx-ide BEGIN (added by install.sh)"
END_MARK="# sbx-ide END"
OLD_BEGIN_MARK="# sbx-cursor BEGIN (added by install.sh)"
OLD_END_MARK="# sbx-cursor END"

# Minimal colors (this script runs before lib/ is guaranteed installed).
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; C=$'\033[36m'; Z=$'\033[0m'
else B=''; G=''; Y=''; R=''; D=''; C=''; Z=''; fi
say()  { printf '%s\n' "$*"; }
good() { printf '%s✅%s %s\n' "$G" "$Z" "$*"; }
warnx(){ printf '%s⚠️ %s %s\n' "$Y" "$Z" "$*"; }
bad()  { printf '%s❌%s %s\n' "$R" "$Z" "$*" >&2; }

usage() {
  cat <<EOF
${B}install.sh${Z} — install / upgrade the sbx-ide toolkit (v$SRC_VERSION)

USAGE
  ./install.sh [--update | --uninstall | --version]

OPTIONS
  --update     Upgrade an existing install in place (same as a plain install).
  --uninstall  Graceful, auditable teardown (reports what remains).
  --version    Print the version of this source tree and exit.

ENV
  PREFIX           install prefix (default: \$HOME/.local)
                   binaries -> \$PREFIX/bin, libraries -> \$PREFIX/lib/sbx-ide
  SBX_IDE_NO_PATH  if set, do not modify any shell rc file
  YES=1            (uninstall) assume "yes" for the config-file removal prompt
EOF
}

installed_version() {
  [[ -f "$LIB_DIR/VERSION" ]] && tr -d '[:space:]' < "$LIB_DIR/VERSION"
}

# rc_file : the shell rc we would edit for PATH.
rc_file() {
  local rc="$HOME/.zshrc"; [[ "${SHELL:-}" == *bash ]] && rc="$HOME/.bashrc"
  printf '%s' "$rc"
}

# strip_path_block <file> : remove any of our marked PATH blocks (new + old)
# from <file>, in place. Leaves everything else untouched.
strip_path_block() {
  local f="$1" tmp
  [[ -f "$f" ]] || return 0
  tmp="$(mktemp)"
  awk -v b1="$BEGIN_MARK" -v e1="$END_MARK" -v b2="$OLD_BEGIN_MARK" -v e2="$OLD_END_MARK" '
    $0==b1 || $0==b2 { skip=1; next }
    $0==e1 || $0==e2 { skip=0; next }
    !skip { print }' "$f" >"$tmp"
  # Only rewrite if something changed.
  if ! cmp -s "$f" "$tmp"; then mv "$tmp" "$f"; return 0; fi
  rm -f "$tmp"; return 1
}

# =============================== UNINSTALL =================================
uninstall() {
  # Pull in the toolkit helpers so we can report sandboxes accurately.
  # shellcheck source=lib/common.sh
  source "$SRC/lib/common.sh"
  # shellcheck source=lib/sbx-interface.sh
  source "$SRC/lib/sbx-interface.sh"
  # shellcheck source=lib/config.sh
  source "$SRC/lib/config.sh"

  say "${B}Uninstalling sbx-ide from $PREFIX${Z}"
  local removed_any=0 c

  # 1. binaries + deprecated shims
  for c in "${ALL_CMDS[@]}"; do
    if [[ -e "$BIN_DIR/$c" ]]; then rm -f "$BIN_DIR/$c" && { say "  removed $BIN_DIR/$c"; removed_any=1; }; fi
  done
  # 2. libraries (new + old location)
  [[ -d "$LIB_DIR" ]]     && { rm -rf "$LIB_DIR";     say "  removed $LIB_DIR"; removed_any=1; }
  [[ -d "$OLD_LIB_DIR" ]] && { rm -rf "$OLD_LIB_DIR"; say "  removed $OLD_LIB_DIR (legacy)"; removed_any=1; }

  # 3. PATH block in the shell rc (ours only; migrates old markers too)
  local rc; rc="$(rc_file)"
  if strip_path_block "$rc"; then say "  removed the PATH block from $rc"; removed_any=1; fi

  [[ "$removed_any" == 1 ]] || say "  (nothing was installed here)"

  # 4. config file — user preference: OFFER removal, never silent.
  local cf; cf="$(config_file)"
  local config_removed=0
  if [[ -f "$cf" ]]; then
    say
    say "${B}Config file${Z} (your default IDE target) is a user preference:"
    say "  $cf"
    local do_rm=0
    if [[ "${YES:-0}" == 1 ]]; then do_rm=1
    elif [[ -t 0 ]]; then
      printf 'Remove it too? [y/N] ' >&2
      read -r reply || reply=""
      [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]] && do_rm=1
    fi
    if [[ "$do_rm" == 1 ]]; then
      rm -f "$cf"; rmdir "$(config_dir)" 2>/dev/null || true
      good "removed config file"
      config_removed=1
    else
      say "  ${D}kept (pass YES=1 to remove non-interactively).${Z}"
    fi
  fi

  # 5. REPORT (never delete): sandboxes this toolkit likely created + any of OUR
  #    marked Host entries in ~/.ssh/config. We never touch sbx's own settings,
  #    feature flags, or the wildcard *${SBX_SSH_SUFFIX} SSH block.
  say
  heading "What remains on your system"

  local reported_sandboxes=0
  if sbx_present && "$SBX_BIN" "$SBX_CMD_LS" >/dev/null 2>&1; then
    local name _agent status ws base
    while IFS=$'\t' read -r name _agent status ws; do
      [[ -n "$name" && -n "$ws" ]] || continue
      base="$(sanitize_name "$(basename "$ws")")"
      # naming convention: <base> or <base>-N
      if [[ "$name" == "$base" || "$name" =~ ^${base}-[0-9]+$ ]]; then
        [[ "$reported_sandboxes" == 0 ]] && say "${B}Sandboxes this toolkit likely created${Z} (NOT removed — your call):"
        reported_sandboxes=1
        printf '  ○ %-24s %s\n' "$name" "${D}$ws${Z}"
        if [[ "$status" == "running" ]]; then
          printf '     %s$ %s stop %s%s\n' "$C" "$SBX_BIN" "$name" "$Z"
        fi
        printf '     %s$ %s %s %s%s\n' "$C" "$SBX_BIN" "$SBX_CMD_RM" "$name" "$Z"
      fi
    done < <(sbx_ls_normalized 2>/dev/null || true)
  fi
  [[ "$reported_sandboxes" == 1 ]] || say "  ${G}no toolkit-created sandboxes detected${Z}"

  # SSH: the Host blocks `sbx-ide open --vscode` wrote, inside our per-alias
  # markers. Offer to remove them (never silent). We NEVER touch sbx's own
  # wildcard *${SBX_SSH_SUFFIX} block. Removing a sandbox (the rm lines above)
  # also drops its published loopback port, so there's nothing else to undo.
  local ssh_leftover=0 al r
  local -a aliases=()
  while IFS= read -r al; do [[ -n "$al" ]] && aliases+=("$al"); done < <(ssh_config_our_aliases)
  if [[ ${#aliases[@]} -gt 0 ]]; then
    say "${B}VS Code SSH Host entries${Z} in $(ssh_config_path) (from 'sbx-ide open --vscode'):"
    for al in "${aliases[@]}"; do printf '  %s\n' "$al"; done
    local do_rm_ssh=0
    if [[ "${YES:-0}" == 1 ]]; then do_rm_ssh=1
    elif [[ -t 0 ]]; then
      printf 'Remove these Host entries too? [y/N] ' >&2; read -r r || r=""
      [[ "$r" == [yY] || "$r" == [yY][eE][sS] ]] && do_rm_ssh=1
    fi
    if [[ "$do_rm_ssh" == 1 ]]; then
      for al in "${aliases[@]}"; do ssh_config_remove_block "$al"; done
      good "removed ${#aliases[@]} Host entr(y/ies) from $(ssh_config_path)"
    else
      ssh_leftover=1
      say "  ${D}kept — remove later by re-running uninstall, or by hand.${Z}"
    fi
  else
    say "  ${G}no sbx-ide VS Code Host entries in ~/.ssh/config${Z} ${D}(sbx's own *${SBX_SSH_SUFFIX} block untouched)${Z}"
  fi

  say
  if [[ "$reported_sandboxes" == 0 && "$ssh_leftover" == 0 && "$config_removed" == 1 ]]; then
    good "Clean exit — nothing sbx-ide-related remains on your system."
  else
    good "Toolkit files removed. Anything listed above is left for you to decide on."
  fi
  exit 0
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  -V|--version) say "$SRC_VERSION"; exit 0 ;;
  --update|--upgrade) ;;   # same code path as install; upgrade is in place
  --uninstall) uninstall ;;
  "") ;;
  *) bad "unknown option: $1"; usage; exit 2 ;;
esac

OLD_VERSION="$(installed_version || true)"
if [[ -n "$OLD_VERSION" ]]; then
  if [[ "$OLD_VERSION" == "$SRC_VERSION" ]]; then
    say "${B}Reinstalling sbx-ide v$SRC_VERSION${Z} (already installed)"
  else
    say "${B}Upgrading sbx-ide${Z} $OLD_VERSION ${B}→${Z} $SRC_VERSION"
  fi
else
  say "${B}Installing sbx-ide v$SRC_VERSION${Z}"
fi
say "  from: $SRC"
say "  bin:  $BIN_DIR"
say "  lib:  $LIB_DIR"

mkdir -p "$BIN_DIR" "$LIB_DIR"

# Migrate a legacy sbx-cursor install out of the way.
if [[ -d "$OLD_LIB_DIR" ]]; then
  rm -rf "$OLD_LIB_DIR"; say "  ${D}migrated: removed legacy $OLD_LIB_DIR${Z}"
fi

# Libraries first (commands source them at runtime). install(1) overwrites, so
# upgrading is just re-copying — no uninstall needed.
libcount=0
for f in "$SRC"/lib/*.sh; do
  install -m 0644 "$f" "$LIB_DIR/$(basename "$f")"
  libcount=$((libcount+1))
done
install -m 0644 "$SRC/VERSION" "$LIB_DIR/VERSION"
good "installed libraries ($libcount files)"

# Bundled kits (the VS Code remote-ssh mixin lives here; resolved at runtime as
# $LIB_DIR/kits/remote-ssh). Removed with $LIB_DIR on uninstall.
if [[ -d "$SRC/kits" ]]; then
  rm -rf "$LIB_DIR/kits"
  cp -R "$SRC/kits" "$LIB_DIR/kits"
  good "installed kits"
fi

# Dispatcher + deprecated shims.
install -m 0755 "$SRC/bin/$CORE_CMD" "$BIN_DIR/$CORE_CMD"; good "installed $CORE_CMD"
for c in "${SHIMS[@]}"; do
  install -m 0755 "$SRC/bin/$c" "$BIN_DIR/$c"; good "installed $c ${D}(deprecated shim)${Z}"
done

# PATH check + optional, clearly-marked rc edit.
case ":$PATH:" in
  *":$BIN_DIR:"*) good "$BIN_DIR is on your PATH" ;;
  *)
    if [[ -n "${SBX_IDE_NO_PATH:-}" ]]; then
      warnx "$BIN_DIR is NOT on your PATH (SBX_IDE_NO_PATH set — not editing rc)."
      say "  Add it with: ${D}export PATH=\"$BIN_DIR:\$PATH\"${Z}"
    else
      rc="$(rc_file)"
      if [[ -f "$rc" ]] && grep -qF "$BEGIN_MARK" "$rc" 2>/dev/null; then
        good "PATH block already present in $rc"
      else
        {
          printf '\n%s\n' "$BEGIN_MARK"
          # shellcheck disable=SC2016  # $PATH must stay literal in the rc file
          printf 'export PATH="%s:$PATH"\n' "$BIN_DIR"
          printf '%s\n' "$END_MARK"
        } >> "$rc"
        good "added $BIN_DIR to PATH in $rc ${D}(inside sbx-ide markers)${Z}"
        say "  Reload your shell: ${D}exec \$SHELL -l${Z}   (or open a new terminal)"
      fi
    fi
    ;;
esac

say
say "${B}Running sbx-ide doctor …${Z}"
if "$BIN_DIR/$CORE_CMD" doctor; then
  :
else
  warnx "sbx-ide doctor reported issues above — fix them before using 'sbx-ide open'."
fi

say
good "Done — sbx-ide v$SRC_VERSION. Open your first project with:  ${B}sbx-ide open <path>${Z}"
say "  New to this? See ${D}docs/RULEBOOK.md${Z}. Giving a demo? See ${D}docs/DEMO.md${Z}."
say "  ${D}Change your mind? '${Z}make uninstall${D}' is a clean, auditable teardown.${Z}"
