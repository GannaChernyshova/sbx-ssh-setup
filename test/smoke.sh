#!/usr/bin/env bash
#
# smoke.sh — exercise the golden path end-to-end against stub sbx/ssh/codex,
# with no real Docker Sandboxes required. Runs hermetically in a temp HOME.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sbx-codex-smoke.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"; mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
export PATH="$ROOT/test/stubs:$PATH"
export SBX_STUB_STATE="$WORK/state.tsv"
export SBX_CODEX_LIB="$ROOT/lib"
export SSH_CONFIG_FILE="$HOME/.ssh/config"
export NO_COLOR=1

PROJ="$WORK/acme-api"; mkdir -p "$PROJ"
MARKER="$WORK/launched"
export CODEX_LAUNCH_OVERRIDE="touch '$MARKER'"
TAB=$'\t'

pass=0; fail=0
# want <desc> <cmd...>    : passes when <cmd> succeeds
# wantnot <desc> <cmd...> : passes when <cmd> fails
want()    { if "${@:2}"; then pass=$((pass+1)); printf '  ✅ %s\n' "$1"; else fail=$((fail+1)); printf '  ❌ %s\n' "$1"; fi; }
wantnot() { if "${@:2}"; then fail=$((fail+1)); printf '  ❌ %s\n' "$1"; else pass=$((pass+1)); printf '  ✅ %s\n' "$1"; fi; }

# Named predicates (keep compound logic out of quoted strings).
row_present()   { grep -q "^acme-api${TAB}" "$SBX_STUB_STATE"; }
alias_present() { grep -qF "# sbx-codex: acme-api" "$SSH_CONFIG_FILE"; }
one_row()       { [[ "$(grep -c "^acme-api${TAB}" "$SBX_STUB_STATE" 2>/dev/null || echo 0)" -eq 1 ]]; }
one_alias()     { [[ "$(grep -c "# sbx-codex: acme-api" "$SSH_CONFIG_FILE" 2>/dev/null || echo 0)" -eq 1 ]]; }
no_dryrun_ssh() { [[ ! -f "$SSH_CONFIG_FILE" ]] || ! grep -q sbx-codex "$SSH_CONFIG_FILE"; }
out_has()       { printf '%s' "$OUT" | grep -qF "$1"; }
run_ls()        { "$ROOT/bin/sbx-ls" >/dev/null 2>&1; }
run_doctor()    { "$ROOT/bin/sbx-doctor" >/dev/null 2>&1; }

echo "== dry-run makes no changes =="
"$ROOT/bin/sbx-open" codex "$PROJ" --dry-run >/dev/null 2>&1 || true
want    "dry-run created no sandbox"   test ! -s "$SBX_STUB_STATE"
want    "dry-run wrote no ssh config"  no_dryrun_ssh

echo "== golden path: create + discover + launch =="
OUT="$("$ROOT/bin/sbx-open" codex "$PROJ" 2>&1)"
want    "sandbox 'acme-api' created"   row_present
want    "workspace recorded"           grep -qF "$PROJ" "$SBX_STUB_STATE"
want    "concrete Host alias written"  grep -qF "Host acme-api.sbx" "$SSH_CONFIG_FILE"
want    "managed region marker present" grep -qF ">>> sbx-codex managed" "$SSH_CONFIG_FILE"
want    "per-name marker present"      alias_present
want    "Codex was launched"           test -f "$MARKER"
want    "one-time flag recorded"       test -f "$HOME/.sbx_features_enabled"
want    "folder path shown in output"  out_has "$PROJ"
want    "host name shown in output"    out_has "acme-api.sbx"

echo "== idempotent: second run reuses, no duplicate =="
"$ROOT/bin/sbx-open" codex "$PROJ" >/dev/null 2>&1
want    "still exactly one sandbox row" one_row
want    "still exactly one ssh alias"   one_alias

echo "== sbx-ls + sbx-doctor run cleanly =="
want    "sbx-ls exits 0"                run_ls
want    "sbx-doctor exits 0 (all green)" run_doctor

echo "== sbx-clean removes sandbox AND prunes alias =="
"$ROOT/bin/sbx-clean" acme-api --yes >/dev/null 2>&1
wantnot "sandbox row removed"          row_present
wantnot "ssh alias pruned"             alias_present

echo ""
printf 'smoke: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
