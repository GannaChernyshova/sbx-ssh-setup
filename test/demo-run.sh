#!/usr/bin/env bash
#
# demo-run.sh — a narrated dry-run of the demo flow against the STUB CLIs.
# Safe to run anywhere: no real sbx, Cursor, or SSH is touched. Use it to
# rehearse docs/DEMO.md without a live daemon.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT/bin:$ROOT/test/stubs:$PATH"
export SBX_IDE_LIB="$ROOT/lib"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export SBX_STUB_STATE="$WORK/state.tsv"
export SBX_STUB_CURSOR_LOG="$WORK/cursor.log"
export SBX_STUB_CODE_LOG="$WORK/code.log"
export XDG_CONFIG_HOME="$WORK/xdg"
export HOME="$WORK/home"; mkdir -p "$HOME/.ssh"
printf 'Host *.sbx\n  ProxyCommand sbx ssh-proxy %%h\n' > "$HOME/.ssh/config"
# VS Code target: dedicated key auto-generates under the fake HOME; pre-seed off.
export SBX_VSCODE_SSH_KEY="$HOME/.ssh/sbx-vscode"
export SBX_VSCODE_PRESEED=0
: > "$SBX_STUB_STATE"
mkdir -p "$WORK/acme-api"

if [[ -t 1 ]]; then B=$'\033[1m'; C=$'\033[36m'; D=$'\033[2m'; Z=$'\033[0m'; else B='';C='';D='';Z=''; fi
step() { printf '\n%s>>> %s%s\n' "$B" "$*" "$Z"; }
# The command is a single display string with intentional quoting, so eval is
# deliberate here (we want the pretty, copy-pasteable form to actually run).
# shellcheck disable=SC2294
run()  { printf '%s$ %s%s\n' "$C" "$*" "$Z"; eval "$@"; }
pause(){ [[ "${DEMO_NOPAUSE:-0}" == 1 || ! -t 0 ]] && return 0; read -r -p "${D}(enter)${Z}" _ || true; }

printf '%s== sbx-ide demo (stubbed rehearsal) ==%s\n' "$B" "$Z"
printf '%sThis uses fake sbx/cursor/code/ssh so you can practice the patter safely.%s\n' "$D" "$Z"

step "1. Health check — is the host ready?"
run "sbx-ide doctor" || true
pause

step "2. Open a project. One command. Sandbox created, IDE launched, right folder."
run "sbx-ide open '$WORK/acme-api'"
pause

step "3. What just happened — a sandbox exists, mounted to exactly that dir."
run "sbx-ide ls"
pause

step "4. Run it again. Idempotent: same sandbox, no duplicate."
run "sbx-ide open '$WORK/acme-api'"
pause

step "5. Prefer VS Code? Set it once and drop the flag (real sshd + Remote-SSH)."
run "sbx-ide set-default vscode"
run "sbx-ide open '$WORK/acme-api' --print-uri" || true
run "sbx-ide set-default cursor"
pause

step "6. The anti-pattern: someone typed a name into the IDE's SSH box -> orphan."
printf '%s(simulating the empty sandbox that trap creates)%s\n' "$D" "$Z"
printf 'typo-sandbox\tshell\trunning\t\n' >> "$SBX_STUB_STATE"
run "sbx-ide ls --orphans" || true
pause

step "7. Clean it up safely."
run "sbx-ide clean --yes"
pause

step "Done. The whole developer loop is just: sbx-ide open <repo>."
printf '%sSee docs/DEMO.md for the full 10-minute prospect script.%s\n' "$D" "$Z"
