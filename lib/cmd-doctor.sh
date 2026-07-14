# shellcheck shell=bash
# cmd-doctor.sh — `sbx-ide doctor`: diagnose an sbx + IDE setup, verify the
# toolkit's host assumptions, and report user preferences / leftovers.
#
#   sbx-ide doctor                    health checks with ✅/❌ and the exact fix
#   sbx-ide doctor --target vscode    check a specific IDE target strictly
#   sbx-ide doctor --verify           check every VERIFY-ON-HOST assumption
#   sbx-ide doctor --fix              offer to remove orphan sandboxes

cmd_doctor() {
  local PROG="${SBX_IDE_PROG:-sbx-ide} doctor"

  usage() {
    cat <<EOF
${C_BOLD}$PROG${C_RESET} — health checks and assumption verification for sbx + IDEs

${C_BOLD}USAGE${C_RESET}
  $PROG [--verify] [--fix] [--target cursor|vscode]

${C_BOLD}OPTIONS${C_RESET}
  --verify           Check every VERIFY-ON-HOST assumption against the real CLI.
  --fix              Offer to remove any orphan sandboxes found (prompts).
  --target <t>       Check only IDE target <t> (cursor|vscode), strictly.
  -h, --help         Show this help.
EOF
  }

  local MODE="health" DO_FIX=0 ONLY_TARGET=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; return 0 ;;
      --verify) MODE="verify"; shift ;;
      --fix) DO_FIX=1; shift ;;
      --target) ONLY_TARGET="${2:?--target needs a value}"; shift 2 ;;
      *) die "unknown option: $1  (try --help)" ;;
    esac
  done
  [[ -z "$ONLY_TARGET" ]] || target_known "$ONLY_TARGET" \
    || die "unknown IDE target: '$ONLY_TARGET' (known: $SBX_IDE_TARGETS)"

  local PASS=0 FAIL=0 WARN=0
  ok()  { printf '%s %s\n' "${C_GREEN}✅${C_RESET}" "$1"; PASS=$((PASS+1)); }
  no()  { printf '%s %s\n' "${C_RED}❌${C_RESET}" "$1"; [[ -n "${2:-}" ]] && printf '   %sfix:%s %s%s%s\n' "$C_DIM" "$C_RESET" "$C_CYAN" "$2" "$C_RESET"; FAIL=$((FAIL+1)); }
  meh() { printf '%s %s\n' "${C_YELLOW}⚠️ ${C_RESET}" "$1"; [[ -n "${2:-}" ]] && printf '   %s%s%s\n' "$C_DIM" "$2" "$C_RESET"; WARN=$((WARN+1)); }

  ssh_config_has_suffix() {
    local f
    for f in "$HOME/.ssh/config" "$HOME/.ssh/config.d"/* "$HOME/.ssh"/*.conf; do
      [[ -f "$f" ]] || continue
      grep -qiE "Host .*\\${SBX_SSH_SUFFIX}([[:space:]]|$)" "$f" 2>/dev/null && return 0
      grep -qF "$SBX_SSH_SUFFIX" "$f" 2>/dev/null && return 0
    done
    return 1
  }

  # ==========================================================================
  # HEALTH MODE
  # ==========================================================================
  run_health() {
    heading "sbx + IDE health check"

    # 1. sbx present + version
    if sbx_present; then
      local v; v="$(sbx_version || true)"
      if [[ -n "$v" ]] && version_ge "$v" "$SBX_MIN_VERSION"; then
        ok "sbx $v (>= $SBX_MIN_VERSION)"
      elif [[ -n "$v" ]]; then
        no "sbx $v is older than required $SBX_MIN_VERSION" "upgrade sbx to >= $SBX_MIN_VERSION"
      else
        meh "sbx present but version could not be parsed" "check: $SBX_BIN version"
      fi
    else
      no "sbx not found on PATH" "install the sbx CLI (v$SBX_MIN_VERSION+)"
    fi

    # 2. daemon reachable
    if sbx_present; then
      if "$SBX_BIN" "$SBX_CMD_LS" >/dev/null 2>&1; then
        ok "sbx daemon responding ($SBX_BIN $SBX_CMD_LS)"
      else
        no "sbx daemon not responding" "$SBX_BIN $SBX_CMD_DIAGNOSE   # diagnose daemon/install issues"
      fi
    fi

    # Resolve the default target early — it decides how strict some checks are.
    local default_target default_source
    IFS=$'\t' read -r default_target default_source < <(resolve_target "")

    # 3. sandboxd SSH config — REQUIRED by Cursor, IRRELEVANT to VS Code (which
    #    uses its own sshd on a published port, not sandboxd's *.sbx endpoint).
    #    So it's a hard check only when Cursor is (or is being) used.
    local sbxssh_strict=0
    if [[ "$default_target" == "cursor" || " $SBX_IDE_TARGETS " == *" cursor "* && -z "$ONLY_TARGET" ]]; then
      [[ "$default_target" == "cursor" ]] && sbxssh_strict=1
    fi
    [[ "$ONLY_TARGET" == "vscode" ]] && sbxssh_strict=-1   # skip entirely
    if [[ "$sbxssh_strict" != "-1" ]]; then
      if ssh_config_has_suffix; then
        ok "SSH config references *${SBX_SSH_SUFFIX} sandboxes (Cursor path)"
      elif [[ "$sbxssh_strict" == 1 ]]; then
        no "no SSH config for *${SBX_SSH_SUFFIX} sandboxes (Cursor needs it)" \
           "$SBX_BIN setup ssh   # after enabling experimental + feature.ssh"
        hint "Full one-time setup:"
        while IFS= read -r step; do cmd "$step"; done < <(sbx_ssh_setup_steps)
      else
        meh "no SSH config for *${SBX_SSH_SUFFIX} sandboxes (only the Cursor target needs it)" \
            "$SBX_BIN setup ssh   # run if you use --cursor"
      fi
    fi

    # 4. IDE targets — the default target is strict; others are informational.
    #    With --target, that one target is checked strictly.
    heading "IDE targets"
    local targets_to_check strict_target
    if [[ -n "$ONLY_TARGET" ]]; then
      targets_to_check="$ONLY_TARGET"; strict_target="$ONLY_TARGET"
    else
      targets_to_check="$SBX_IDE_TARGETS"; strict_target="$default_target"
    fi
    local t label lines level msg fix strict tag
    for t in $targets_to_check; do
      label="$("target_${t}_label")"
      [[ "$t" == "$strict_target" ]] && strict=1 || strict=0
      tag="$label"
      [[ "$t" == "$default_target" ]] && tag="$label ${C_DIM}(default)${C_RESET}"
      printf '%s%s%s\n' "$C_BOLD" "$tag" "$C_RESET"
      lines="$("target_${t}_check" doctor)"
      while IFS=$'\t' read -r level msg fix; do
        [[ -n "$level" ]] || continue
        case "$level" in
          ok)   ok "$msg" ;;
          warn) meh "$msg" "${fix:-}" ;;
          fail)
            if [[ "$strict" == 1 ]]; then no "$msg" "${fix:-}"
            else meh "$msg (not your default target)" "${fix:-}"; fi ;;
        esac
      done <<< "$lines"
    done

    # 5. orphan sandboxes
    if sbx_present; then
      local orphans; orphans="$(sbx_ls_normalized 2>/dev/null | awk -F'\t' '$4==""{print $1}')"
      heading "Sandboxes"
      if [[ -z "$orphans" ]]; then
        ok "no orphan sandboxes (all have a workspace mount)"
      else
        local count; count="$(printf '%s\n' "$orphans" | grep -c .)"
        no "$count orphan sandbox(es): $(echo "$orphans" | paste -sd, -)" "${SBX_IDE_PROG:-sbx-ide} clean --orphans-only"
        if [[ "$DO_FIX" == 1 ]]; then
          if confirm "Remove the orphan sandbox(es) now?"; then
            local o rm_out
            # Snapshot into an array first: sbx_rm reads /dev/null, but building
            # the list up front also keeps the here-string out of the rm calls.
            local -a orphan_list=()
            while IFS= read -r o; do [[ -n "$o" ]] && orphan_list+=("$o"); done <<< "$orphans"
            for o in "${orphan_list[@]}"; do
              if rm_out="$(sbx_rm "$o")"; then success "removed $o"
              else err "failed to remove $o"; [[ -n "$rm_out" ]] && hint "sbx: ${rm_out//$'\n'/ }"; fi
            done
          fi
        fi
      fi
    fi

    # 6. user preference (config)
    heading "Preferences"
    ok "default IDE target: $default_target ${C_DIM}($(source_label "$default_source"))${C_RESET}"
    local cf; cf="$(config_file)"
    if [[ -f "$cf" ]]; then hint "config file: $cf"; else hint "config file: $cf (not created yet; run '${SBX_IDE_PROG:-sbx-ide} set-default')"; fi

    # 7. deprecated shims installed?
    local shim shims_found=""
    local bindir="${_bindir:-}"   # set by the dispatcher that sources us
    for shim in sbx-open sbx-doctor sbx-ls sbx-clean; do
      if [[ -n "$bindir" && -f "$bindir/$shim" ]] && grep -q 'DEPRECATED SHIM' "$bindir/$shim" 2>/dev/null; then
        shims_found+="$shim "
      fi
    done
    if [[ -n "$shims_found" ]]; then
      meh "deprecated shims present: ${shims_found% }" "these forward to '${SBX_IDE_PROG:-sbx-ide} <cmd>'. 'make uninstall' removes them."
    fi

    # 8. optional dev tools (separate from hard requirements — never fail here)
    heading "Optional dev tools (for contributors; not required to use the toolkit)"
    local tool hintmsg
    for tool in shellcheck shfmt; do
      case "$tool" in
        shellcheck) hintmsg="brew install shellcheck   # or: apt-get install shellcheck" ;;
        shfmt)      hintmsg="brew install shfmt" ;;
      esac
      if have "$tool"; then ok "$tool present"; else meh "$tool not installed (optional)" "$hintmsg"; fi
    done

    heading "Summary"
    printf '%s %d passed · %s %d warnings · %s %d failed\n' \
      "${C_GREEN}✅${C_RESET}" "$PASS" "${C_YELLOW}⚠️${C_RESET}" "$WARN" "${C_RED}❌${C_RESET}" "$FAIL"
    if [[ "$FAIL" -gt 0 ]]; then
      hint "Apply the fixes above, then re-run: $PROG"
      return 1
    fi
    success "Ready. Open a project with: ${SBX_IDE_PROG:-sbx-ide} open <path>"
    hint "Confirm the toolkit's assumptions match this host with: $PROG --verify"
  }

  # ==========================================================================
  # VERIFY MODE — expected (assumed) vs detected (what the CLI shows)
  # ==========================================================================
  local DIFFS=0
  verrow() {
    local label="$1" exp="$2" det="$3" good="$4" mark
    if [[ "$good" == 1 ]]; then mark="${C_GREEN}match${C_RESET}"; else mark="${C_RED}DIFF${C_RESET}"; DIFFS=$((DIFFS+1)); fi
    printf '  %-26s %s\n' "$label" "$mark"
    printf '      %sexpected:%s %s\n' "$C_DIM" "$C_RESET" "$exp"
    printf '      %sdetected:%s %s\n' "$C_DIM" "$C_RESET" "$det"
  }
  vnote() { printf '  %-26s %s\n' "$1" "${C_YELLOW}VERIFY-ON-HOST${C_RESET}"; printf '      %s%s%s\n' "$C_DIM" "$2" "$C_RESET"; }

  run_verify() {
    heading "Verifying VERIFY-ON-HOST assumptions against the installed sbx"
    sbx_present || die "sbx not found on PATH — run --verify on the host with sbx installed."

    local help; help="$("$SBX_BIN" --help 2>&1 || true)"
    local sub good det
    for sub in "$SBX_CMD_LS" "$SBX_CMD_RUN" "$SBX_CMD_CREATE" "$SBX_CMD_EXEC" "$SBX_CMD_STOP" "$SBX_CMD_RM"; do
      if grep -qwF "$sub" <<<"$help"; then good=1; det="present in 'sbx --help'"; else good=0; det="NOT found in 'sbx --help'"; fi
      verrow "subcommand: $sub" "exists" "$det" "$good"
    done

    local runhelp; runhelp="$("$SBX_BIN" "$SBX_CMD_RUN" --help 2>&1 || true)"
    if grep -qF "$SBX_RUN_DETACH_FLAG" <<<"$runhelp" || grep -qwE '\-d' <<<"$runhelp"; then
      good=1; det="'$SBX_RUN_DETACH_FLAG' present in 'sbx run --help'"
    else good=0; det="'$SBX_RUN_DETACH_FLAG' not seen — open would attach a shell; check 'sbx run --help'"; fi
    verrow "detached create flag" "$SBX_RUN_DETACH_FLAG" "$det" "$good"

    if grep -qwF "$SBX_DEFAULT_AGENT" <<<"$runhelp"; then good=1; det="'$SBX_DEFAULT_AGENT' referenced by 'sbx run --help'"; else good=0; det="'$SBX_DEFAULT_AGENT' not seen in 'sbx run --help'"; fi
    verrow "SBX_DEFAULT_AGENT" "$SBX_DEFAULT_AGENT" "$det" "$good"

    # rm force flag — `sbx rm` requires confirmation; clean/doctor pass --force to
    # remove running/in-use orphans non-interactively. Catch drift in the flag.
    if [[ -n "$SBX_RM_FORCE_FLAG" ]]; then
      local rmhelp; rmhelp="$("$SBX_BIN" "$SBX_CMD_RM" --help 2>&1 || true)"
      if grep -qF "$SBX_RM_FORCE_FLAG" <<<"$rmhelp" || grep -qwE '\-f' <<<"$rmhelp"; then
        good=1; det="'$SBX_RM_FORCE_FLAG' present in 'sbx rm --help'"
      else good=0; det="'$SBX_RM_FORCE_FLAG' not seen — clean can't remove running orphans; check 'sbx rm --help'"; fi
      verrow "rm force flag" "$SBX_RM_FORCE_FLAG" "$det" "$good"
    fi

    local header; header="$("$SBX_BIN" "$SBX_CMD_LS" 2>/dev/null | head -n1)"
    local missing="" tok
    for tok in SANDBOX AGENT STATUS WORKSPACE; do
      grep -qiwF "$tok" <<<"$header" || missing+="$tok "
    done
    if [[ -z "$missing" ]]; then good=1; det="$header"; else good=0; det="missing: ${missing}| header was: ${header:-<empty>}"; fi
    verrow "ls column format" "cols incl SANDBOX/AGENT/STATUS/WORKSPACE" "$det" "$good"

    local detected_suffix="" f line
    for f in "$HOME/.ssh/config" "$HOME/.ssh/config.d"/* "$HOME/.ssh"/*.conf; do
      [[ -f "$f" ]] || continue
      line="$(grep -iE '^[[:space:]]*Host[[:space:]]+\*\.' "$f" 2>/dev/null | head -n1 || true)"
      [[ -n "$line" ]] && { detected_suffix=".${line##*\*.}"; detected_suffix="${detected_suffix%% *}"; break; }
    done
    if [[ -z "$detected_suffix" ]]; then good=0; det="no 'Host *.<suffix>' line found in ssh config (setup ssh not run?)"
    elif [[ "$detected_suffix" == "$SBX_SSH_SUFFIX" ]]; then good=1; det="$detected_suffix"
    else good=0; det="$detected_suffix"; fi
    verrow "SBX_SSH_SUFFIX" "$SBX_SSH_SUFFIX" "$det" "$good"

    local sample sname swss cpath
    sample="$(sbx_ls_normalized 2>/dev/null | awk -F'\t' '$4!=""{print $1"\t"$4; exit}')"
    if [[ -z "$sample" ]]; then
      verrow "mount mirrors host path" "container path == host path" "no sandbox with a workspace to probe — create one and re-run" 0
    else
      sname="${sample%%$'\t'*}"; swss="${sample#*$'\t'}"
      cpath="$(exec_ws_probe "$sname" 2>/dev/null || true)"
      if [[ -z "$cpath" ]] && ssh_reachable "$sname" \
         && "$SSH_BIN" -o BatchMode=yes "$(ssh_host "$sname")" "test -d '$swss'" >/dev/null 2>&1; then
        cpath="$swss"
      fi
      if [[ "$cpath" == "$swss" ]]; then good=1; det="container workspace == host path ($swss) on '$sname'"
      elif [[ -n "$cpath" ]]; then good=0; det="container=$cpath host=$swss (NOT mirrored — set SBX_MOUNT_MIRRORS_HOST=0, SBX_FALLBACK_CONTAINER_WS=$cpath)"
      else good=0; det="could not probe container path for '$sname' (tried 'sbx exec' + ssh test -d)"; fi
      verrow "mount mirrors host path" "container path == host path" "$det" "$good"
    fi

    # VS Code (real sshd + published port) — host-only checks, flagged not diffed.
    heading "VS Code Remote-SSH (real sshd + published loopback port)"
    if grep -qwF "$SBX_CMD_PORTS" <<<"$help"; then good=1; det="'$SBX_CMD_PORTS' present in 'sbx --help'"
    else good=0; det="'$SBX_CMD_PORTS' not found — needed to publish the sshd port"; fi
    verrow "sbx ports subcommand" "exists" "$det" "$good"
    vnote "Remote-SSH ext id" "expected '$SBX_VSCODE_EXT'; confirm with: $CODE_BIN --list-extensions"
    vnote "loopback publish form" "confirm 'sbx $SBX_CMD_PORTS <name> --publish 127.0.0.1:<port>:22/tcp' binds loopback only"
    vnote "kit installs sshd" "confirm the remote-ssh kit boots sshd on :22 (ssh <alias> true succeeds) — see docs/VSCODE-NOTES.md"

    heading "Verification summary"
    if [[ "$DIFFS" -eq 0 ]]; then
      success "All auto-checkable assumptions match this host. Complete the VS Code items above manually."
    else
      warn "$DIFFS assumption(s) differ. Update lib/sbx-interface.sh (or export the"
      hint "corresponding SBX_* variable) so the detected value is used, then re-run."
      return 1
    fi
  }

  case "$MODE" in
    health) run_health ;;
    verify) run_verify ;;
  esac
}
