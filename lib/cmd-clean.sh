# shellcheck shell=bash
# cmd-clean.sh — `sbx-ide clean`: remove orphan and stopped sandboxes.
#
# Orphans (running, no workspace) are always removal candidates: any work done
# in them lives in a throwaway container. Stopped sandboxes are candidates too
# (their workspace is on the host and survives — only the container is dropped).

cmd_clean() {
  local PROG="${SBX_IDE_PROG:-sbx-ide} clean"

  usage() {
    cat <<EOF
${C_BOLD}$PROG${C_RESET} — remove orphan and stopped sandboxes

${C_BOLD}USAGE${C_RESET}
  $PROG [--orphans-only] [--dry-run] [--yes]

${C_BOLD}OPTIONS${C_RESET}
  --orphans-only  Only remove orphans (skip stopped sandboxes).
  --dry-run       List what would be removed; remove nothing.
  --yes           Do not prompt (required for non-interactive use).
  -h, --help      Show this help.

${C_BOLD}NOTES${C_RESET}
  • Orphans hold work only inside a throwaway container — removing them is safe
    and recommended.
  • A stopped sandbox's files live in its host workspace and are NOT deleted;
    only the container is discarded. Reopen anytime with ${SBX_IDE_PROG:-sbx-ide} open <path>.
EOF
  }

  local ORPHANS_ONLY=0 DRY_RUN=0 ASSUME_YES=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; return 0 ;;
      --orphans-only) ORPHANS_ONLY=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --yes|-y) ASSUME_YES=1; shift ;;
      *) die "unknown option: $1  (try --help)" ;;
    esac
  done

  sbx_present || die "'$SBX_BIN' not found on PATH."

  local candidates="" name _agent status ws
  while IFS=$'\t' read -r name _agent status ws; do
    [[ -n "$name" ]] || continue
    if [[ -z "$ws" ]]; then
      candidates+="orphan"$'\t'"$name"$'\t'"(none)"$'\n'
    elif [[ "$status" != "running" && "$ORPHANS_ONLY" == 0 ]]; then
      candidates+="stopped"$'\t'"$name"$'\t'"$ws"$'\n'
    fi
  done <<< "$(sbx_ls_normalized || true)"

  if [[ -z "$candidates" ]]; then
    success "Nothing to clean. No orphan${ORPHANS_ONLY:+/} $([[ $ORPHANS_ONLY == 0 ]] && echo 'or stopped ')sandboxes found."
    return 0
  fi

  local kind
  heading "Removal candidates"
  while IFS=$'\t' read -r kind name ws; do
    [[ -n "$name" ]] || continue
    if [[ "$kind" == "orphan" ]]; then
      printf '  %s  %-24s %s\n' "${C_RED}⚠ orphan${C_RESET}" "$name" "${C_DIM}no workspace${C_RESET}" >&2
    else
      printf '  %s %-24s %s\n' "${C_DIM}○ stopped${C_RESET}" "$name" "${C_DIM}$ws (host files kept)${C_RESET}" >&2
    fi
  done <<< "$candidates"

  if [[ "$DRY_RUN" == 1 ]]; then
    info "[dry-run] nothing removed. Re-run without --dry-run to proceed."
    return 0
  fi

  if [[ "$ASSUME_YES" != 1 ]]; then
    if ! confirm "Remove the sandboxes listed above?"; then
      info "Aborted. Nothing removed."
      hint "Non-interactive? Pass --yes. Preview only? Pass --dry-run."
      return 1
    fi
  fi

  local removed=0 failed=0 rm_out
  while IFS=$'\t' read -r kind name ws; do
    [[ -n "$name" ]] || continue
    # sbx_rm forces + reads /dev/null (never steals this loop's stdin) and
    # returns sbx's own output so we can show the real reason on failure.
    if rm_out="$(sbx_rm "$name")"; then
      success "removed $name"
      # Also drop any ~/.ssh/config blocks we may have written for it — the VS
      # Code loopback block (its published port goes away with the sandbox) and
      # the Codex concrete alias. Best-effort.
      ssh_config_remove_block "${SBX_VSCODE_HOST_PREFIX}${name}"
      ssh_config_remove_block "${name}${SBX_SSH_SUFFIX}"
      removed=$((removed+1))
    else
      err "failed to remove $name"
      [[ -n "$rm_out" ]] && hint "sbx: ${rm_out//$'\n'/ }"
      failed=$((failed+1))
    fi
  done <<< "$candidates"

  info "Done: $removed removed, $failed failed."
  [[ "$failed" -eq 0 ]]
}
