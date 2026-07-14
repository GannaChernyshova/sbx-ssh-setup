# shellcheck shell=bash
# cmd-ls.sh — `sbx-ide ls`: human-friendly view of your sandboxes.
#
# Flags orphans (running with no workspace) and stopped sandboxes, and prints a
# ready-to-copy `sbx-ide open` command for every healthy one.

cmd_ls() {
  local PROG="${SBX_IDE_PROG:-sbx-ide} ls"

  usage() {
    cat <<EOF
${C_BOLD}$PROG${C_RESET} — list sandboxes, with health flags and copy/paste commands

${C_BOLD}USAGE${C_RESET}
  $PROG [--orphans] [--stopped] [--quiet]

${C_BOLD}OPTIONS${C_RESET}
  --orphans   Show only orphan sandboxes (running, no workspace mount).
  --stopped   Show only stopped sandboxes.
  --quiet     Names only, one per line (script-friendly, no decoration).
  -h, --help  Show this help.

${C_BOLD}LEGEND${C_RESET}
  ${C_GREEN}●${C_RESET} running   ${C_DIM}○${C_RESET} stopped   ${C_RED}⚠ orphan${C_RESET} (no workspace — remove with ${SBX_IDE_PROG:-sbx-ide} clean)
EOF
  }

  local FILTER="" QUIET=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; return 0 ;;
      --orphans) FILTER="orphan"; shift ;;
      --stopped) FILTER="stopped"; shift ;;
      --quiet)   QUIET=1; shift ;;
      *) die "unknown option: $1  (try --help)" ;;
    esac
  done

  sbx_present || die "'$SBX_BIN' not found on PATH."

  local rows; rows="$(sbx_ls_normalized || true)"
  if [[ -z "$rows" ]]; then
    info "No sandboxes. Create one with: ${SBX_IDE_PROG:-sbx-ide} open <path>"
    return 0
  fi

  local n_orphan=0 n_stopped=0 n_ok=0 printed=0
  local name agent status ws kind marker
  while IFS=$'\t' read -r name agent status ws; do
    [[ -n "$name" ]] || continue

    kind="ok"
    if [[ -z "$ws" ]]; then kind="orphan"
    elif [[ "$status" != "running" ]]; then kind="stopped"; fi

    case "$kind" in
      orphan)  n_orphan=$((n_orphan+1)) ;;
      stopped) n_stopped=$((n_stopped+1)) ;;
      *)       n_ok=$((n_ok+1)) ;;
    esac

    if [[ -n "$FILTER" && "$kind" != "$FILTER" ]]; then continue; fi

    if [[ "$QUIET" == 1 ]]; then
      printf '%s\n' "$name"
      continue
    fi

    case "$kind" in
      orphan)  marker="${C_RED}⚠ orphan${C_RESET}" ;;
      stopped) marker="${C_DIM}○ stopped${C_RESET}" ;;
      ok)      marker="${C_GREEN}● running${C_RESET}" ;;
    esac

    printf '%s  %s  %s\n' "$marker" "${C_BOLD}$name${C_RESET}" "${C_DIM}[$agent]${C_RESET}"
    if [[ "$kind" == "orphan" ]]; then
      printf '     %s\n' "${C_DIM}no workspace mount — work here would be lost. Remove it:${C_RESET}"
      printf '     %s\n' "${C_CYAN}\$ ${SBX_IDE_PROG:-sbx-ide} clean${C_RESET}"
    else
      printf '     %s\n' "${C_DIM}$ws${C_RESET}"
      printf '     %s\n' "${C_CYAN}\$ ${SBX_IDE_PROG:-sbx-ide} open '$ws'${C_RESET}"
    fi
    printed=1
  done <<< "$rows"

  if [[ "$QUIET" == 0 ]]; then
    [[ "$printed" == 1 ]] || info "Nothing matched the filter."
    printf '\n%s\n' "${C_DIM}${n_ok} running · ${n_stopped} stopped · ${n_orphan} orphan${C_RESET}" >&2
    if [[ "$n_orphan" -gt 0 ]]; then
      warn "$n_orphan orphan sandbox(es) detected — run: ${SBX_IDE_PROG:-sbx-ide} clean"
    fi
  fi
}
