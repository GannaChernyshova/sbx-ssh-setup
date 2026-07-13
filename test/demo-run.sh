#!/usr/bin/env bash
#
# demo-run.sh — a narrated dry-run of the demo flow against the STUB CLIs.
# Safe to run anywhere: no real sbx, Cursor, or SSH is touched. Use it to
# rehearse docs/DEMO.md without a live daemon.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT/bin:$ROOT/test/stubs:$PATH"
export SBX_CURSOR_LIB="$ROOT/lib"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export SBX_STUB_STATE="$WORK/state.tsv"
export SBX_STUB_CURSOR_LOG="$WORK/cursor.log"
export HOME="$WORK/home"; mkdir -p "$HOME/.ssh"
printf 'Host *.sbx\n  ProxyCommand sbx ssh-proxy %%h\n' > "$HOME/.ssh/config"
: > "$SBX_STUB_STATE"
mkdir -p "$WORK/acme-api"

if [[ -t 1 ]]; then B=$'\033[1m'; C=$'\033[36m'; D=$'\033[2m'; Z=$'\033[0m'; else B='';C='';D='';Z=''; fi
step() { printf '\n%s>>> %s%s\n' "$B" "$*" "$Z"; }
run()  { printf '%s$ %s%s\n' "$C" "$*" "$Z"; eval "$@"; }
pause(){ [[ "${DEMO_NOPAUSE:-0}" == 1 || ! -t 0 ]] && return 0; read -r -p "${D}(enter)${Z}" _ || true; }

printf '%s== sbx-cursor demo (stubbed rehearsal) ==%s\n' "$B" "$Z"
printf '%sThis uses fake sbx/cursor/ssh so you can practice the patter safely.%s\n' "$D" "$Z"

step "1. Health check — is the host ready?"
run "sbx-doctor" || true
pause

step "2. Open a project. One command. Sandbox created, Cursor launched, right folder."
run "sbx-open '$WORK/acme-api'"
pause

step "3. What just happened — a sandbox exists, mounted to exactly that dir."
run "sbx-ls"
pause

step "4. Run it again. Idempotent: same sandbox, no duplicate."
run "sbx-open '$WORK/acme-api'"
pause

step "5. The anti-pattern: someone typed a name into Cursor's SSH box -> orphan."
printf '%s(simulating the empty sandbox that trap creates)%s\n' "$D" "$Z"
printf 'typo-sandbox\tshell\trunning\t\n' >> "$SBX_STUB_STATE"
run "sbx-ls --orphans" || true
pause

step "6. Clean it up safely."
run "sbx-clean --yes"
pause

step "Done. The whole developer loop is just: sbx-open <repo>."
printf '%sSee docs/DEMO.md for the full 10-minute prospect script.%s\n' "$D" "$Z"
