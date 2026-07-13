#!/usr/bin/env bash
#
# Smoke test for the sbx-cursor toolkit. Runs every command against the stub
# sbx/cursor/ssh CLIs in test/stubs and asserts the important behaviors:
# create, idempotent reuse, orphan/mismatch refusal, stopped-restart, and the
# doctor health + --verify reports. No real sbx/Cursor required.
#
# The many `out=...` captures are consumed inside eval'd assertion strings
# (see check()), which static analysis can't follow — suppress that warning.
# shellcheck disable=SC2034
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT/bin:$ROOT/test/stubs:$PATH"
export SBX_CURSOR_LIB="$ROOT/lib"
export NO_COLOR=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export SBX_STUB_STATE="$WORK/state.tsv"
export SBX_STUB_CURSOR_LOG="$WORK/cursor.log"

# Fake home with the ssh config `sbx setup ssh` would write.
export HOME="$WORK/home"
mkdir -p "$HOME/.ssh"
printf 'Host *.sbx\n  ProxyCommand sbx ssh-proxy %%h\n  User agent\n' > "$HOME/.ssh/config"

PASS=0; FAIL=0
pass() { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1  [assertion: $2]"; fi; }

seed() { : >"$SBX_STUB_STATE"; while [[ $# -gt 0 ]]; do printf '%s\n' "$1" >>"$SBX_STUB_STATE"; shift; done; }
reset_cursor() { : >"$SBX_STUB_CURSOR_LOG"; }

echo "== sbx-open: create =="
seed
mkdir -p "$WORK/proj"
reset_cursor
sbx-open "$WORK/proj" >/dev/null 2>&1
check "creates a sandbox named after the dir" "grep -q '^proj	' '$SBX_STUB_STATE'"
check "launches cursor with a folder-uri"      "grep -q 'folder-uri vscode-remote://ssh-remote+proj.sbx' '$SBX_STUB_CURSOR_LOG'"

echo "== sbx-open: idempotent reuse =="
reset_cursor
sbx-open "$WORK/proj" >/dev/null 2>&1
check "does not create a duplicate row" "[ \"\$(grep -c '^proj	' '$SBX_STUB_STATE')\" = 1 ]"
check "reopens (one cursor launch)"     "[ \"\$(wc -l < '$SBX_STUB_CURSOR_LOG')\" = 1 ]"

echo "== sbx-open: creates DETACHED (never blocks on an interactive shell) =="
seed
mkdir -p "$WORK/detproj"
runlog="$WORK/run.log"; : > "$runlog"
# SBX_STUB_RUN_INTERACTIVE=1 makes a NON-detached `run` block on stdin. sbx-open
# must pass --detached, so it returns promptly even with that set.
if SBX_STUB_RUN_LOG="$runlog" SBX_STUB_RUN_INTERACTIVE=1 \
     sbx-open "$WORK/detproj" </dev/null >/dev/null 2>&1; then rc=0; else rc=1; fi
check "returns without an interactive shell" "[ $rc -eq 0 ]"
check "used 'sbx run --detached'"            "grep -q -- '--detached' '$runlog'"
check "never invoked a non-detached run"     "! grep -v -- '--detached' '$runlog'"

echo "== sbx-open: --print-uri uses in-container mirror path =="
uri="$(sbx-open "$WORK/proj" --print-uri 2>/dev/null)"
check "uri embeds the mirrored workspace path" "[ \"$uri\" = 'vscode-remote://ssh-remote+proj.sbx$WORK/proj' ]"

echo "== sbx-open: orphan refusal (explicit name) =="
seed "$(printf 'orphan-x\tshell\trunning\t')"
if sbx-open "$WORK/proj" --name orphan-x >/dev/null 2>&1; then rc=0; else rc=1; fi
check "refuses to reuse an orphan by name" "[ $rc -eq 1 ]"

echo "== sbx-open: workspace-mismatch refusal (explicit name) =="
seed "$(printf 'demo\tshell\trunning\t/some/other/path')"
if sbx-open "$WORK/proj" --name demo >/dev/null 2>&1; then rc=0; else rc=1; fi
check "refuses a name bound to a different workspace" "[ $rc -eq 1 ]"

echo "== sbx-open: auto-suffix on derived-name collision =="
mkdir -p "$WORK/a/proj" "$WORK/b/proj"
seed "$(printf 'proj\tshell\trunning\t%s/a/proj' "$WORK")"
sbx-open "$WORK/b/proj" >/dev/null 2>&1
check "creates proj-2 for the second path" "grep -q '^proj-2	' '$SBX_STUB_STATE'"

echo "== sbx-open: wakes a stopped sandbox (detached, via run --detached) =="
mkdir -p "$WORK/stp"
seed "$(printf 'stp\tshell\tstopped\t%s/stp' "$WORK")"
runlog="$WORK/run2.log"; : > "$runlog"
SBX_STUB_RUN_LOG="$runlog" sbx-open "$WORK/stp" >/dev/null 2>&1
check "stopped sandbox is now running"     "grep -q '^stp	shell	running	' '$SBX_STUB_STATE'"
check "woke it with run --detached --name" "grep -Eq -- '--detached.*--name stp|--name stp.*--detached' '$runlog'"

echo "== sbx-open: SSH not set up prints setup steps =="
seed
out="$(SBX_STUB_SSH_UNREACHABLE=1 sbx-open "$WORK/proj" 2>&1 || true)"
check "mentions the ssh enablement command" "grep -q 'sbx ssh' <<< \"\$out\""

echo "== sbx-ls: flags orphans =="
seed "$(printf 'ok1\tshell\trunning\t/x')" "$(printf 'orph\tshell\trunning\t')"
out="$(sbx-ls 2>&1)"
check "labels the orphan"     "grep -q 'orphan' <<< \"\$out\""
check "prints sbx-open hint"  "grep -q \"sbx-open '/x'\" <<< \"\$out\""
check "quiet lists raw names" "[ \"\$(sbx-ls --quiet 2>/dev/null | tr '\n' ',')\" = 'ok1,orph,' ]"

echo "== sbx-clean: dry-run removes nothing, --yes removes candidates =="
seed "$(printf 'keep\tshell\trunning\t/x')" "$(printf 'orph\tshell\trunning\t')" "$(printf 'old\tshell\tstopped\t/y')"
sbx-clean --dry-run >/dev/null 2>&1
check "dry-run keeps all 3 rows" "[ \"\$(wc -l < '$SBX_STUB_STATE')\" = 3 ]"
sbx-clean --yes >/dev/null 2>&1
check "removes orphan + stopped, keeps running" "[ \"\$(cut -f1 '$SBX_STUB_STATE' | tr '\n' ',')\" = 'keep,' ]"

echo "== sbx-clean: --orphans-only spares stopped =="
seed "$(printf 'orph\tshell\trunning\t')" "$(printf 'old\tshell\tstopped\t/y')"
sbx-clean --orphans-only --yes >/dev/null 2>&1
check "keeps the stopped sandbox" "grep -q '^old	' '$SBX_STUB_STATE'"
check "removes the orphan"        "! grep -q '^orph	' '$SBX_STUB_STATE'"

echo "== sbx-doctor: health detects orphan =="
seed "$(printf 'ok1\tshell\trunning\t/x')" "$(printf 'orph\tshell\trunning\t')"
if sbx-doctor >/dev/null 2>&1; then rc=0; else rc=1; fi
check "non-zero exit when an orphan exists" "[ $rc -eq 1 ]"

echo "== sbx-doctor: --verify matches all assumptions against the stub =="
seed "$(printf 'cursor-sbx\tshell\trunning\t/Users/x/demos')"
if sbx-doctor --verify >/dev/null 2>&1; then rc=0; else rc=1; fi
check "--verify passes cleanly against the stub" "[ $rc -eq 0 ]"

echo "== --help / --version on every command =="
for c in sbx-open sbx-ls sbx-clean sbx-doctor; do
  check "$c --help works"    "$c --help >/dev/null 2>&1"
  check "$c --version prints" "$c --version 2>/dev/null | grep -q '$(cat "$ROOT/VERSION")'"
done

echo "== install: fresh install + in-place upgrade =="
pfx="$WORK/prefix"
PREFIX="$pfx" "$ROOT/install.sh" >/dev/null 2>&1 || true
check "installs the VERSION file"        "[ -f '$pfx/lib/sbx-cursor/VERSION' ]"
check "installs the commands"            "[ -x '$pfx/bin/sbx-open' ]"
printf '0.0.1\n' > "$pfx/lib/sbx-cursor/VERSION"    # pretend an older install
upout="$(PREFIX="$pfx" "$ROOT/install.sh" --update 2>&1 || true)"
check "reports the version upgrade"      "grep -q 'Upgrading' <<< \"\$upout\""
check "upgrade rewrites VERSION"         "[ \"\$(cat '$pfx/lib/sbx-cursor/VERSION')\" = \"\$(cat '$ROOT/VERSION')\" ]"

echo
echo "smoke: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
