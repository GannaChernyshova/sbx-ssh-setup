# shellcheck shell=bash
# cmd-set-default.sh — `sbx-ide set-default`: persist the default IDE target and
# the per-target sbx agent.
#
#   sbx-ide set-default                          show current defaults + source
#   sbx-ide set-default <cursor|vscode>          set the default IDE target
#   sbx-ide set-default --agent <name> [--cursor|--vscode]
#                                                set the agent the sandbox runs
#                                                (scoped to one IDE, or all)
#
# Why the agent matters: Cursor brings its own in-IDE agent, so a plain `shell`
# sandbox is fine; vanilla VS Code doesn't, so you may want an sbx agent (e.g.
# `claude`) running IN the sandbox — `set-default --agent claude --vscode`.

cmd_set_default() {
  local PROG="${SBX_IDE_PROG:-sbx-ide} set-default"

  usage() {
    cat <<EOF
${C_BOLD}$PROG${C_RESET} — set (or show) the default IDE target and per-target agent

${C_BOLD}USAGE${C_RESET}
  $PROG                                  Show current defaults and their source.
  $PROG <cursor|vscode>                  Persist the default IDE target.
  $PROG --agent <name> [--cursor|--vscode]
                                         Persist the sbx agent the sandbox runs
                                         (scoped to one IDE, or all if no scope).

${C_BOLD}NOTES${C_RESET}
  • Target resolution:  --cursor/--vscode flag > \$SBX_IDE_TARGET > config > cursor
  • Agent resolution:   --agent flag > \$SBX_AGENT_<TARGET> > config > ${SBX_DEFAULT_AGENT}
  • Cursor has its own agent (so \`shell\` is fine); vanilla VS Code doesn't, so
    e.g. \`$PROG --agent claude --vscode\` runs Claude in the sandbox.

Config file: $(config_file)
EOF
  }

  local agent="" scope="" target_arg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; return 0 ;;
      --agent)   agent="${2:?--agent needs a value}"; shift 2 ;;
      --cursor)  scope="cursor"; shift ;;
      --vscode)  scope="vscode"; shift ;;
      -*)        die "unknown option: $1  (try --help)" ;;
      *)         [[ -z "$target_arg" ]] || die "unexpected extra argument: $1"; target_arg="$1"; shift ;;
    esac
  done

  # --- set the agent -------------------------------------------------------
  if [[ -n "$agent" ]]; then
    [[ -z "$target_arg" ]] || die "with --agent, scope with --cursor/--vscode (not a bare '$target_arg')"
    local known=0 a
    for a in $SBX_KNOWN_AGENTS; do [[ "$a" == "$agent" ]] && known=1; done
    [[ "$known" == 1 ]] || warn "'$agent' isn't a known agent ($SBX_KNOWN_AGENTS) — setting it anyway (confirm with 'sbx run --help')."
    if [[ -n "$scope" ]]; then
      config_set "agent_$scope" "$agent"
      success "Agent for ${C_BOLD}$scope${C_RESET} set to ${C_BOLD}$agent${C_RESET}."
    else
      config_set "agent_cursor" "$agent"; config_set "agent_vscode" "$agent"
      success "Agent for ${C_BOLD}all IDE targets${C_RESET} set to ${C_BOLD}$agent${C_RESET}."
    fi
    hint "written to: $(config_file)"
    hint "Override per-run with --agent, or \$SBX_AGENT_CURSOR / \$SBX_AGENT_VSCODE."
    return 0
  fi

  # --- set the default target ---------------------------------------------
  if [[ -n "$target_arg" ]]; then
    [[ -z "$scope" ]] || die "a bare target and --cursor/--vscode can't be combined; use one."
    target_known "$target_arg" || die "unknown IDE target: '$target_arg' (known: $SBX_IDE_TARGETS)"
    config_set default_target "$target_arg"
    success "Default IDE target set to ${C_BOLD}$target_arg${C_RESET}."
    hint "written to: $(config_file)"
    hint "Override per-run with --cursor/--vscode or \$SBX_IDE_TARGET."
    return 0
  fi

  # --- a lone --cursor/--vscode is ambiguous ------------------------------
  if [[ -n "$scope" ]]; then
    die "did you mean '$PROG $scope' (set target) or '$PROG --agent <name> --$scope' (set agent)?"
  fi

  # --- no args: report -----------------------------------------------------
  local target source
  IFS=$'\t' read -r target source < <(resolve_target "")
  printf '%sDefault IDE target:%s %s\n' "$C_BOLD" "$C_RESET" "$target" >&2
  hint "source: $(source_label "$source")"
  local t asrc
  for t in $SBX_IDE_TARGETS; do
    IFS=$'\t' read -r a asrc < <(resolve_agent "$t" "")
    hint "agent ($t): $a [$asrc]"
  done
  hint "Set target: $PROG cursor|vscode    ·    set agent: $PROG --agent <name> [--vscode]"
}
