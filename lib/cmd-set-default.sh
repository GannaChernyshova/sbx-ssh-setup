# shellcheck shell=bash
# cmd-set-default.sh — `sbx-ide set-default`: persist the default IDE target.
#
# Writes default_target to the XDG config file (0600). With no argument, prints
# the current default and where it came from (flag/env/config/built-in).

cmd_set_default() {
  local PROG="${SBX_IDE_PROG:-sbx-ide} set-default"

  case "${1:-}" in
    -h|--help)
      cat <<EOF
${C_BOLD}$PROG${C_RESET} — set (or show) the default IDE target

${C_BOLD}USAGE${C_RESET}
  $PROG                 Show the current default and its source.
  $PROG <cursor|vscode> Persist the default target.

Resolution order for any run: --cursor/--vscode flag > \$SBX_IDE_TARGET >
config default > cursor. Setting it here means you can drop the flag entirely.

Config file: $(config_file)
EOF
      return 0 ;;
  esac

  # No argument → report current default and source.
  if [[ $# -eq 0 ]]; then
    local target source
    IFS=$'\t' read -r target source < <(resolve_target "")
    printf '%sDefault IDE target:%s %s\n' "$C_BOLD" "$C_RESET" "$target" >&2
    hint "source: $(source_label "$source")"
    if [[ "$source" != "config" ]]; then
      hint "Set it persistently with: $PROG cursor   (or: $PROG vscode)"
    fi
    return 0
  fi

  local target="$1"; shift || true
  [[ $# -eq 0 ]] || die "unexpected extra argument: $1  (try --help)"
  target_known "$target" || die "unknown IDE target: '$target' (known: $SBX_IDE_TARGETS)"

  config_set default_target "$target"
  success "Default IDE target set to ${C_BOLD}$target${C_RESET}."
  hint "written to: $(config_file)"
  hint "Override per-run with --cursor/--vscode or \$SBX_IDE_TARGET."
}
