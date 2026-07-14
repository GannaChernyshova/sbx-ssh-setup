# shellcheck shell=bash
# cmd-open.sh — `sbx-ide open`: the golden path.
#
# Creates (or reuses) exactly one Docker Sandbox for a project directory, mounts
# only that directory, verifies SSH reachability, and launches the chosen IDE
# already connected and already in the right folder. Idempotent.
#
# The IDE-specific bits (which CLI, which folder-URI scheme, which preflight)
# live entirely in the per-target table (lib/targets.sh). This command is
# target-agnostic: it resolves a target, runs its preflight, and drives its
# hooks. Launching is `<bin> --folder-uri <uri>` for every target we ship.

cmd_open() {
  local PROG="${SBX_IDE_PROG:-sbx-ide} open"

  usage() {
    cat <<EOF
${C_BOLD}$PROG${C_RESET} — open a project in an IDE, isolated in a Docker Sandbox

${C_BOLD}USAGE${C_RESET}
  $PROG <path> [--cursor|--vscode] [--name <name>] [options]

${C_BOLD}ARGUMENTS${C_RESET}
  <path>              Project directory to mount (the ONLY shared surface).

${C_BOLD}OPTIONS${C_RESET}
  --cursor            Open in Cursor (default unless a different default is set).
  --vscode            Open in VS Code (via Dev Containers attach, never SSH).
  --name <name>       Sandbox name (default: derived from the directory name).
  --agent <agent>     sbx agent/template the sandbox runs (e.g. shell, claude).
                      Per-target default via '${SBX_IDE_PROG:-sbx-ide} set-default --agent'.
  --no-open           Prepare/verify the sandbox but do not launch the IDE.
  --print-uri         Print the IDE folder URI and exit.
  --dry-run           Show what would happen; make no changes.
  -h, --help          Show this help.

${C_BOLD}EXAMPLES${C_RESET}
  $PROG /path/to/proj
  cd /path/to/proj && $PROG ./
  $PROG /path/to/proj --vscode --name proj-review

${C_BOLD}RULES${C_RESET}
  • One sandbox per project. Mount the repo — never \$HOME, /, or a parent of
    many repos. The mount is the entire blast radius of the agent.
  • Never type a new name into the IDE's "Connect via SSH" box — that can spawn
    an empty, workspace-less sandbox. Always start from $PROG.
EOF
  }

  # --- argument parsing ----------------------------------------------------
  local PATH_ARG="" NAME="" AGENT_FLAG=""
  local NO_OPEN=0 PRINT_URI=0 DRY_RUN=0 TARGET_FLAG=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; return 0 ;;
      --cursor)  TARGET_FLAG="cursor"; shift ;;
      --vscode)  TARGET_FLAG="vscode"; shift ;;
      --name)    NAME="${2:?--name needs a value}"; shift 2 ;;
      --agent)   AGENT_FLAG="${2:?--agent needs a value}"; shift 2 ;;
      --no-open|--no-cursor) NO_OPEN=1; shift ;;   # --no-cursor: back-compat
      --print-uri) PRINT_URI=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --) shift; break ;;
      -*) die "unknown option: $1  (try --help)" ;;
      *)  [[ -z "$PATH_ARG" ]] || die "unexpected extra argument: $1"; PATH_ARG="$1"; shift ;;
    esac
  done
  [[ -n "$PATH_ARG" ]] || { usage; return 2; }

  # --- resolve the IDE target ----------------------------------------------
  local TARGET
  IFS=$'\t' read -r TARGET _ < <(resolve_target "$TARGET_FLAG")
  target_known "$TARGET" || die "unknown IDE target: '$TARGET' (known: $SBX_IDE_TARGETS)"
  local label; label="$("target_${TARGET}_label")"

  # Resolve which sbx agent the sandbox runs for THIS target (flag > env >
  # config > SBX_DEFAULT_AGENT). Applied on CREATE only (a wake reuses the spec).
  local AGENT AGENT_SRC
  IFS=$'\t' read -r AGENT AGENT_SRC < <(resolve_agent "$TARGET" "$AGENT_FLAG")

  # --- preflight -----------------------------------------------------------
  sbx_present || die "'$SBX_BIN' not found on PATH. Install the sbx CLI, then run: ${SBX_IDE_PROG:-sbx-ide} doctor"

  # --- canonicalize the path FIRST, then derive everything from it ---------
  # realpath resolves symlinks, '..', trailing slashes and './' so the sandbox
  # name comes from the real project directory — never 'sandbox', never '..'.
  local WS; WS="$(abspath "$PATH_ARG")"
  [[ -d "$WS" ]] || die "not a directory: $WS"

  # --- blast-radius guards (mount narrowly; the mount IS the blast radius) --
  if [[ "$WS" == "$HOME" ]]; then
    die "refusing to mount your entire home directory ($HOME). Mount a specific project."
  fi
  if [[ "$WS" == "/" ]]; then
    die "refusing to mount the filesystem root (/). Mount a specific project."
  fi
  local child_repos; child_repos="$(count_child_git_repos "$WS")"
  if [[ "$child_repos" -gt 1 ]]; then
    err "refusing to mount '$WS': it contains $child_repos git repos at the top level."
    hint "That would hand the agent every repo under it. Mount the narrowest"
    hint "directory that is the ONE project — the mount is the entire blast radius."
    hint "Open a single repo instead, e.g.:"
    cmd "$PROG '$WS/<one-repo>'"
    return 1
  fi

  # --- name derivation + collision handling --------------------------------
  # Auto-derived names that collide with a DIFFERENT workspace get suffixed
  # (-2, -3, …) after telling the user. An explicit --name is never silently
  # renamed: reuse on match, refuse on mismatch/orphan.
  local name_explicit=0
  if [[ -n "$NAME" ]]; then
    name_explicit=1
    NAME="$(sanitize_name "$NAME")"
  else
    NAME="$(sanitize_name "$(basename "$WS")")"
  fi

  classify() {
    local n="$1" existing_ws
    existing_ws="$(sbx_workspace "$n")"
    if [[ -z "$existing_ws" ]]; then echo "orphan"
    elif [[ "$existing_ws" == "$WS" ]]; then echo "reuse"
    else echo "mismatch"; fi
  }

  resolve_name() {
    local base="$NAME" n="$NAME" i=1
    while sbx_exists "$n"; do
      case "$(classify "$n")" in
        reuse) NAME="$n"; return 0 ;;
        orphan)
          if [[ "$name_explicit" == 1 ]]; then
            err "Sandbox '$n' exists but has NO workspace mount (orphan)."
            hint "This is the empty-sandbox trap. Remove it, then retry:"
            cmd "${SBX_IDE_PROG:-sbx-ide} clean            # interactive"
            cmd "$SBX_BIN $SBX_CMD_RM $n   # or remove just this one"
            exit 1
          fi
          n="${base}-$((++i))" ;;
        mismatch)
          if [[ "$name_explicit" == 1 ]]; then
            err "Sandbox '$n' already exists for a DIFFERENT workspace:"
            hint "existing: $(sbx_workspace "$n")"
            hint "you asked for: $WS"
            hint "Pick another name, or reuse the existing project directory:"
            cmd "$PROG '$(sbx_workspace "$n")'        # open the existing one"
            cmd "$PROG '$WS' --name ${base}-2         # new sandbox for this path"
            exit 1
          fi
          warn "Name '$n' is taken by a different workspace; using '${base}-$((i+1))'."
          n="${base}-$((++i))" ;;
      esac
    done
    NAME="$n"
  }
  resolve_name

  # --- IDE preflight (fail fast BEFORE creating a sandbox) -----------------
  # Every target's hard requirements are checked here. On any fail we stop —
  # and for VS Code we NEVER fall back to sandboxd's SSH (it retry-loops); the
  # working path is a real sshd on a published loopback port (see targets.sh).
  local checks failed=0
  checks="$("target_${TARGET}_check" open)"
  while IFS=$'\t' read -r level msg fix; do
    [[ -n "$level" ]] || continue
    case "$level" in
      ok)   info "$msg" ;;
      warn) warn "$msg"; [[ -n "$fix" ]] && hint "$fix" ;;
      fail) err "$msg"; [[ -n "$fix" ]] && cmd "$fix"; failed=1 ;;
    esac
  done <<< "$checks"
  if [[ "$failed" == 1 ]]; then
    if [[ "$TARGET" == "vscode" ]]; then
      die "VS Code can't be opened on this host — the check(s) above failed. Fix them and retry; sbx-ide will never fall back to sandboxd's SSH (it retry-loops). See docs/VSCODE-NOTES.md."
    fi
    die "$label preflight failed — see the fix(es) above."
  fi

  # --- per-target extra `sbx run` args, applied on CREATE only -------------
  # (e.g. VS Code passes `--kit <remote-ssh kit>` so a real sshd runs inside.)
  local -a run_extra=()
  local a
  while IFS= read -r a; do [[ -n "$a" ]] && run_extra+=("$a"); done < <("target_${TARGET}_run_args")

  # --- create or reuse (always DETACHED; control returns immediately) ------
  local created=0 status
  if sbx_exists "$NAME"; then
    status="$(sbx_status "$NAME")"
    info "Reusing sandbox ${C_BOLD}$NAME${C_RESET} (workspace: $WS)"
    if [[ "$status" != "running" ]]; then
      if [[ "$DRY_RUN" == 1 ]]; then
        info "[dry-run] would wake stopped sandbox: $SBX_BIN $SBX_CMD_RUN $SBX_RUN_DETACH_FLAG --name $NAME"
      else
        info "Waking stopped sandbox (detached)…"
        sbx_ensure_running "" "$NAME" ""
      fi
    fi
  else
    if [[ "$DRY_RUN" == 1 ]]; then
      info "[dry-run] would create (detached): $(sbx_ensure_running_cmd "$AGENT" "$NAME" "$WS" ${run_extra[@]+"${run_extra[@]}"})"
    else
      info "Creating sandbox ${C_BOLD}$NAME${C_RESET} (agent: $AGENT [$AGENT_SRC], workspace: $WS, detached)"
      sbx_ensure_running "$AGENT" "$NAME" "$WS" ${run_extra[@]+"${run_extra[@]}"}
      created=1
    fi
  fi

  # --- connect + launch: fully owned by the target ------------------------
  # Cursor: sandboxd SSH + folder-URI. VS Code: inject key, publish loopback
  # port, write ~/.ssh/config, Remote-SSH to our own sshd. Both honor
  # --print-uri / --no-open / --dry-run.
  "target_${TARGET}_launch" "$NAME" "$WS" "$created" "$DRY_RUN" "$NO_OPEN" "$PRINT_URI"
}
