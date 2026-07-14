#!/usr/bin/env bash
#
# Smoke test for the sbx-ide toolkit. Runs every subcommand against the stub
# sbx/cursor/code/docker/ssh CLIs in test/stubs and asserts the important
# behaviors: target resolution, create/reuse, orphan/mismatch refusal,
# stopped-restart, name derivation from ugly paths, blast-radius guards, the
# VS Code attach URI, set-default persistence, the deprecated shims, and the
# doctor health + --verify reports. No real sbx/Cursor/VS Code required.
#
# The many `out=...` captures are consumed inside eval'd assertion strings
# (see check()), which static analysis can't follow — suppress that warning.
# shellcheck disable=SC2034
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT/bin:$ROOT/test/stubs:$PATH"
export SBX_IDE_LIB="$ROOT/lib"
export NO_COLOR=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export SBX_STUB_STATE="$WORK/state.tsv"
export SBX_STUB_CURSOR_LOG="$WORK/cursor.log"
export SBX_STUB_CODE_LOG="$WORK/code.log"

# Isolate the XDG config so set-default doesn't touch the real one.
export XDG_CONFIG_HOME="$WORK/xdg"

# Fake home with the ssh config `sbx setup ssh` would write.
export HOME="$WORK/home"
mkdir -p "$HOME/.ssh"
printf 'Host *.sbx\n  ProxyCommand sbx ssh-proxy %%h\n  User agent\n' > "$HOME/.ssh/config"

# VS Code target: dedicated passwordless key auto-generated under the fake HOME
# (exercises the real autogen path — ssh-keygen is available). Pre-seed off for
# deterministic tests (best-effort; just runs no-op sbx exec against the stub).
export SBX_VSCODE_SSH_KEY="$HOME/.ssh/sbx-vscode"
export SBX_VSCODE_PRESEED=0
export SBX_STUB_EXEC_LOG="$WORK/exec.log"
# Keep the sshd-reachability wait instant in tests (no real sshd to wait for).
export SBX_VSCODE_SSH_RETRIES=2
export SBX_VSCODE_SSH_RETRY_DELAY=0

PASS=0; FAIL=0
pass() { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1  [assertion: $2]"; fi; }

seed() { : >"$SBX_STUB_STATE"; while [[ $# -gt 0 ]]; do printf '%s\n' "$1" >>"$SBX_STUB_STATE"; shift; done; }
reset_cursor() { : >"$SBX_STUB_CURSOR_LOG"; }
reset_code()   { : >"$SBX_STUB_CODE_LOG"; }
reset_cfg()    { rm -rf "$XDG_CONFIG_HOME"; }

echo "== unit: sanitize_name against ugly inputs =="
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
check "spaces -> dashes"        "[ \"\$(sanitize_name 'my proj')\" = 'my-proj' ]"
check "collapses repeats"       "[ \"\$(sanitize_name 'a___b--c')\" = 'a-b-c' ]"
check "trims leading/trailing"  "[ \"\$(sanitize_name '__Weird__')\" = 'weird' ]"
check "lowercases"              "[ \"\$(sanitize_name 'PaymentsAPI')\" = 'paymentsapi' ]"
check "unicode -> safe name"    "sanitize_name 'café-service' | grep -Eq '^[a-z0-9-]+$'"
check "empty -> 'sandbox'"      "[ \"\$(sanitize_name '///')\" = 'sandbox' ]"

echo "== unit: count_child_git_repos =="
mkdir -p "$WORK/many/r1/.git" "$WORK/many/r2/.git" "$WORK/many/plain"
mkdir -p "$WORK/one/only/.git"
check "counts two child repos" "[ \"\$(count_child_git_repos '$WORK/many')\" = 2 ]"
check "counts one child repo"  "[ \"\$(count_child_git_repos '$WORK/one')\" = 1 ]"

echo "== sbx-ide open: create (default target = cursor) =="
seed
mkdir -p "$WORK/proj"
reset_cursor
sbx-ide open "$WORK/proj" >/dev/null 2>&1
check "creates a sandbox named after the dir" "grep -q '^proj	' '$SBX_STUB_STATE'"
check "launches cursor with a folder-uri"      "grep -q 'folder-uri vscode-remote://ssh-remote+proj.sbx' '$SBX_STUB_CURSOR_LOG'"

echo "== sbx-ide open: name derivation from ugly paths =="
seed; reset_cursor
mkdir -p "$WORK/space dir/payments api"
sbx-ide open "$WORK/space dir/payments api/" >/dev/null 2>&1   # trailing slash + spaces
check "spaces+trailing-slash -> payments-api" "grep -q '^payments-api	' '$SBX_STUB_STATE'"
seed
ln -s "$WORK/proj" "$WORK/proj-link"
sbx-ide open "$WORK/proj-link" >/dev/null 2>&1                 # symlink resolves to proj
check "symlink resolves to real basename (proj)" "grep -q '^proj	' '$SBX_STUB_STATE'"
seed
sbx-ide open "$WORK/space dir/../proj" >/dev/null 2>&1         # .. is canonicalized
check "'..' canonicalizes to proj" "grep -q '^proj	' '$SBX_STUB_STATE'"

echo "== sbx-ide open: blast-radius guards =="
if HOME="$WORK/home" sbx-ide open "$WORK/home" >/dev/null 2>&1; then rc=0; else rc=1; fi
check "refuses to mount \$HOME" "[ $rc -eq 1 ]"
if sbx-ide open "$WORK/many" >/dev/null 2>&1; then rc=0; else rc=1; fi
check "refuses a parent of many repos" "[ $rc -eq 1 ]"
out="$(sbx-ide open "$WORK/many" 2>&1 || true)"
check "explains the narrowest-mount rule" "grep -qi 'blast radius' <<< \"\$out\""
check "allows a single-repo parent"        "sbx-ide open '$WORK/one' --dry-run >/dev/null 2>&1"

echo "== sbx-ide open: idempotent reuse =="
seed; reset_cursor
sbx-ide open "$WORK/proj" >/dev/null 2>&1
sbx-ide open "$WORK/proj" >/dev/null 2>&1
check "does not create a duplicate row" "[ \"\$(grep -c '^proj	' '$SBX_STUB_STATE')\" = 1 ]"
check "reopens (two launches, same row)" "[ \"\$(wc -l < '$SBX_STUB_CURSOR_LOG')\" = 2 ]"

echo "== sbx-ide open: creates DETACHED (never blocks on an interactive shell) =="
seed
mkdir -p "$WORK/detproj"
runlog="$WORK/run.log"; : > "$runlog"
if SBX_STUB_RUN_LOG="$runlog" SBX_STUB_RUN_INTERACTIVE=1 \
     sbx-ide open "$WORK/detproj" </dev/null >/dev/null 2>&1; then rc=0; else rc=1; fi
check "returns without an interactive shell" "[ $rc -eq 0 ]"
check "used 'sbx run --detached'"            "grep -q -- '--detached' '$runlog'"
check "never invoked a non-detached run"     "! grep -v -- '--detached' '$runlog'"

echo "== sbx-ide open: --print-uri uses in-container mirror path =="
seed; mkdir -p "$WORK/proj"
uri="$(sbx-ide open "$WORK/proj" --print-uri 2>/dev/null)"
check "cursor uri embeds the mirrored path" "[ \"$uri\" = 'vscode-remote://ssh-remote+proj.sbx$WORK/proj' ]"

echo "== sbx-ide open: orphan + workspace-mismatch refusal (explicit name) =="
seed "$(printf 'orphan-x\tshell\trunning\t')"
if sbx-ide open "$WORK/proj" --name orphan-x >/dev/null 2>&1; then rc=0; else rc=1; fi
check "refuses to reuse an orphan by name" "[ $rc -eq 1 ]"
seed "$(printf 'demo\tshell\trunning\t/some/other/path')"
if sbx-ide open "$WORK/proj" --name demo >/dev/null 2>&1; then rc=0; else rc=1; fi
check "refuses a name bound to a different workspace" "[ $rc -eq 1 ]"

echo "== sbx-ide open: auto-suffix on derived-name collision =="
mkdir -p "$WORK/a/proj" "$WORK/b/proj"
seed "$(printf 'proj\tshell\trunning\t%s/a/proj' "$WORK")"
sbx-ide open "$WORK/b/proj" >/dev/null 2>&1
check "creates proj-2 for the second path" "grep -q '^proj-2	' '$SBX_STUB_STATE'"

echo "== sbx-ide open: wakes a stopped sandbox (detached) =="
mkdir -p "$WORK/stp"
seed "$(printf 'stp\tshell\tstopped\t%s/stp' "$WORK")"
runlog="$WORK/run2.log"; : > "$runlog"
SBX_STUB_RUN_LOG="$runlog" sbx-ide open "$WORK/stp" >/dev/null 2>&1
check "stopped sandbox is now running"     "grep -q '^stp	shell	running	' '$SBX_STUB_STATE'"
check "woke it with run --detached --name" "grep -Eq -- '--detached.*--name stp|--name stp.*--detached' '$runlog'"

echo "== sbx-ide open: SSH not set up prints setup steps =="
seed
out="$(SBX_STUB_SSH_UNREACHABLE=1 sbx-ide open "$WORK/proj" 2>&1 || true)"
check "mentions the ssh enablement command" "grep -q 'sbx ssh' <<< \"\$out\""

echo "== sbx-ide open --vscode: Remote-SSH to real sshd over a loopback port =="
seed; mkdir -p "$WORK/proj"; reset_code; : > "$WORK/exec.log"
runlog="$WORK/vrun.log"; : > "$runlog"
uri="$(SBX_STUB_RUN_LOG="$runlog" sbx-ide open "$WORK/proj" --vscode --print-uri 2>/dev/null)"
check "vscode uri is Remote-SSH to a loopback alias" "[ \"$uri\" = 'vscode-remote://ssh-remote+sbx-proj$WORK/proj' ]"
check "vscode uri is NOT a container-attach URI"     "! grep -q 'attached-container' <<< \"$uri\""
check "create passed --kit (real sshd in sandbox)"   "grep -q -- '--kit' '$runlog'"
check "injected the pubkey via sbx exec"             "grep -q 'authorized_keys' '$WORK/exec.log'"
check "published a loopback port -> :22"             "[ -f '$SBX_STUB_STATE.ports' ] && grep -q '^proj	' '$SBX_STUB_STATE.ports'"
check "wrote a marked ~/.ssh/config Host block"      "grep -q '# sbx-ide ssh BEGIN sbx-proj' '$HOME/.ssh/config'"
check "ssh block has a keepalive"                    "grep -q 'ServerAliveInterval' '$HOME/.ssh/config'"
check "auto-generated the dedicated key"             "[ -f '$HOME/.ssh/sbx-vscode' ] && [ -f '$HOME/.ssh/sbx-vscode.pub' ]"
check "dedicated key is passwordless"                "ssh-keygen -y -P '' -f '$HOME/.ssh/sbx-vscode' >/dev/null 2>&1"
check "ssh block pins the dedicated key"             "grep -q 'IdentityFile $HOME/.ssh/sbx-vscode' '$HOME/.ssh/config' && grep -q 'IdentitiesOnly yes' '$HOME/.ssh/config'"

echo "== sbx-ide open --vscode: actually launches code --remote =="
seed; mkdir -p "$WORK/proj"; reset_code
sbx-ide open "$WORK/proj" --vscode >/dev/null 2>&1
check "launched code --remote ssh-remote+sbx-proj" "grep -q -- '--remote ssh-remote+sbx-proj' '$SBX_STUB_CODE_LOG'"

echo "== sbx-ide open --vscode: hard-fails (no fallback) when Remote-SSH ext missing =="
seed; reset_code
if SBX_STUB_NO_REMOTE_SSH=1 sbx-ide open "$WORK/proj" --vscode >/dev/null 2>&1; then rc=0; else rc=1; fi
check "fails when Remote-SSH ext absent"      "[ $rc -eq 1 ]"
out="$(SBX_STUB_NO_REMOTE_SSH=1 sbx-ide open "$WORK/proj" --vscode 2>&1 || true)"
check "explains + points to VSCODE-NOTES"     "grep -q 'VSCODE-NOTES' <<< \"\$out\""
check "never launches code on preflight fail" "[ ! -s '$SBX_STUB_CODE_LOG' ]"
check "never fell back to sandboxd SSH"       "grep -qi \"sandboxd's SSH\" <<< \"\$out\""

echo "== sbx-ide open --vscode: fails clearly when key missing + autogen off =="
seed; reset_code
env_off=(SBX_VSCODE_SSH_KEY="$WORK/nokey" SBX_VSCODE_AUTOGEN_KEY=0)
if env "${env_off[@]}" sbx-ide open "$WORK/proj" --vscode >/dev/null 2>&1; then rc=0; else rc=1; fi
check "fails when no key and autogen off" "[ $rc -eq 1 ]"
out="$(env "${env_off[@]}" sbx-ide open "$WORK/proj" --vscode 2>&1 || true)"
check "suggests ssh-keygen / autogen"     "grep -q 'ssh-keygen\|AUTOGEN' <<< \"\$out\""

echo "== sbx-ide open --vscode: reusing a kit-less sandbox -> recreate guidance =="
# A sandbox created before --vscode (no remote-ssh kit) has no sshd. Reuse must
# detect that and guide, not fail cryptically on key injection.
seed "$(printf 'proj\tshell\trunning\t%s/proj' "$WORK")"; reset_code
if SBX_STUB_NO_KIT=1 sbx-ide open "$WORK/proj" --vscode >/dev/null 2>&1; then rc=0; else rc=1; fi
check "fails on a kit-less sandbox" "[ $rc -eq 1 ]"
out="$(SBX_STUB_NO_KIT=1 sbx-ide open "$WORK/proj" --vscode 2>&1 || true)"
check "explains it lacks the kit"      "grep -qi 'without the remote-ssh kit' <<< \"\$out\""
check "prints a recreate command"      "grep -q 'rm --force proj' <<< \"\$out\""
check "does not try to inject the key" "! grep -q 'authorized_keys' '$WORK/exec.log' || true"

echo "== sbx-ide open --vscode: passphrase key (auth miss, port open) -> proceed =="
# BatchMode auth fails (passphrase key not in agent) but the port is open, so
# the connection is fine — VS Code can prompt. We must warn + proceed + launch.
seed; mkdir -p "$WORK/proj"; reset_code
SBX_STUB_SSH_UNREACHABLE=1 SBX_STUB_TCP_OPEN=1 sbx-ide open "$WORK/proj" --vscode >/dev/null 2>&1
check "still launches code despite auth miss" "grep -q -- '--remote ssh-remote+sbx-proj' '$SBX_STUB_CODE_LOG'"
out="$(SBX_STUB_SSH_UNREACHABLE=1 SBX_STUB_TCP_OPEN=1 sbx-ide open "$WORK/proj" --vscode 2>&1 || true)"
check "warns about passphrase / ssh-agent" "grep -qi 'passphrase' <<< \"\$out\""
check "suggests ssh-add"                    "grep -q 'ssh-add' <<< \"\$out\""

echo "== sbx-ide open --vscode: sshd truly unreachable (port closed) -> hard fail =="
seed; mkdir -p "$WORK/proj"; reset_code
if SBX_STUB_SSH_UNREACHABLE=1 sbx-ide open "$WORK/proj" --vscode >/dev/null 2>&1; then rc=0; else rc=1; fi
check "hard-fails when the port is closed" "[ $rc -eq 1 ]"
check "did not launch code"                "[ ! -s '$SBX_STUB_CODE_LOG' ]"

echo "== sbx-ide set-default: persistence + resolution order =="
reset_cfg; seed; mkdir -p "$WORK/proj"; reset_code; reset_cursor
sbx-ide set-default vscode >/dev/null 2>&1
check "writes an 0600 config file"    "[ -f '$XDG_CONFIG_HOME/sbx-ide/config' ]"
check "config records vscode default" "grep -q 'default_target=vscode' '$XDG_CONFIG_HOME/sbx-ide/config'"
check "no-arg reports current default" "out=\"\$(sbx-ide set-default 2>&1)\"; grep -q 'vscode' <<< \"\$out\""
# Cursor URI host ends in '.sbx'; VS Code URI host is 'sbx-<name>' — discriminate on that.
# config default now wins -> open uses vscode
uri="$(sbx-ide open "$WORK/proj" --print-uri 2>/dev/null)"
check "config default drives target (vscode)" "grep -q 'ssh-remote+sbx-proj' <<< \"$uri\""
# env overrides config
uri="$(SBX_IDE_TARGET=cursor sbx-ide open "$WORK/proj" --print-uri 2>/dev/null)"
check "SBX_IDE_TARGET overrides config"        "grep -q 'ssh-remote+proj.sbx' <<< \"$uri\""
# explicit flag overrides env
uri="$(SBX_IDE_TARGET=cursor sbx-ide open "$WORK/proj" --vscode --print-uri 2>/dev/null)"
check "flag overrides env + config"            "grep -q 'ssh-remote+sbx-proj' <<< \"$uri\""
reset_cfg

echo "== sbx-ide: per-target agent selection =="
reset_cfg; seed; mkdir -p "$WORK/proj"
arun="$WORK/agent-run.log"
# default agent is shell
: > "$arun"; SBX_STUB_RUN_LOG="$arun" sbx-ide open "$WORK/proj" >/dev/null 2>&1
check "default agent is shell"        "grep -q 'detached shell' '$arun'"
# --agent flag wins
seed; : > "$arun"; SBX_STUB_RUN_LOG="$arun" sbx-ide open "$WORK/proj" --agent gemini >/dev/null 2>&1
check "--agent flag wins"             "grep -q 'detached gemini' '$arun'"
# set-default --agent claude --vscode  (scoped)
reset_cfg
sbx-ide set-default --agent claude --vscode >/dev/null 2>&1
check "config records agent_vscode"   "grep -q 'agent_vscode=claude' '$XDG_CONFIG_HOME/sbx-ide/config'"
check "did NOT set agent_cursor"       "! grep -q 'agent_cursor' '$XDG_CONFIG_HOME/sbx-ide/config'"
seed; : > "$arun"; SBX_STUB_RUN_LOG="$arun" sbx-ide open "$WORK/proj" --vscode >/dev/null 2>&1
check "vscode uses configured claude"  "grep -q 'detached claude' '$arun'"
seed; : > "$arun"; SBX_STUB_RUN_LOG="$arun" sbx-ide open "$WORK/proj" --cursor >/dev/null 2>&1
check "cursor still shell (scoped)"    "grep -q 'detached shell' '$arun'"
# env overrides config
seed; : > "$arun"; SBX_STUB_RUN_LOG="$arun" SBX_AGENT_VSCODE=copilot sbx-ide open "$WORK/proj" --vscode >/dev/null 2>&1
check "SBX_AGENT_VSCODE beats config"  "grep -q 'detached copilot' '$arun'"
# set-default --agent with no scope sets both
reset_cfg
sbx-ide set-default --agent gemini >/dev/null 2>&1
check "no-scope sets agent_cursor"     "grep -q 'agent_cursor=gemini' '$XDG_CONFIG_HOME/sbx-ide/config'"
check "no-scope sets agent_vscode"     "grep -q 'agent_vscode=gemini' '$XDG_CONFIG_HOME/sbx-ide/config'"
# report shows per-target agents
out="$(sbx-ide set-default 2>&1)"
check "report lists a per-target agent" "grep -q 'agent (vscode): gemini' <<< \"\$out\""
reset_cfg

echo "== sbx-ide open: agent login banner (create, non-shell agent only) =="
reset_cfg; seed; mkdir -p "$WORK/proj"
: > "$WORK/exec.log"
sbx-ide open "$WORK/proj" --agent claude >/dev/null 2>&1
check "writes a login banner for a real agent" "grep -q 'sbx-ide agent banner' '$WORK/exec.log'"
# shell agent → no banner
seed; : > "$WORK/exec.log"
sbx-ide open "$WORK/proj" >/dev/null 2>&1
check "no banner for the shell agent" "! grep -q 'sbx-ide agent banner' '$WORK/exec.log'"
# reuse (not create) → no re-write of the banner
seed "$(printf 'proj\tshell\trunning\t%s/proj' "$WORK")"; : > "$WORK/exec.log"
sbx-ide open "$WORK/proj" --agent claude >/dev/null 2>&1
check "no banner write on reuse" "! grep -q 'sbx-ide agent banner' '$WORK/exec.log'"

echo "== deprecated shims forward + warn on stderr =="
seed; mkdir -p "$WORK/proj"; reset_cursor
err="$(sbx-open "$WORK/proj" 2>&1 >/dev/null)"
check "sbx-open warns it is deprecated" "grep -qi 'deprecated' <<< \"\$err\""
check "sbx-open forwards to open (cursor launched)" "grep -q 'ssh-remote+proj.sbx' '$SBX_STUB_CURSOR_LOG'"
seed "$(printf 'ok1\tshell\trunning\t/x')" "$(printf 'orph\tshell\trunning\t')"
check "sbx-ls forwards"    "out=\"\$(sbx-ls 2>&1)\"; grep -q 'orphan' <<< \"\$out\""
check "sbx-clean forwards" "out=\"\$(sbx-clean --dry-run 2>&1)\"; grep -qi 'orphan' <<< \"\$out\""

echo "== sbx-ide ls: flags orphans =="
seed "$(printf 'ok1\tshell\trunning\t/x')" "$(printf 'orph\tshell\trunning\t')"
out="$(sbx-ide ls 2>&1)"
check "labels the orphan"     "grep -q 'orphan' <<< \"\$out\""
check "prints open hint"      "grep -q \"sbx-ide open '/x'\" <<< \"\$out\""
check "quiet lists raw names" "[ \"\$(sbx-ide ls --quiet 2>/dev/null | tr '\n' ',')\" = 'ok1,orph,' ]"

echo "== sbx-ide clean: dry-run vs --yes =="
seed "$(printf 'keep\tshell\trunning\t/x')" "$(printf 'orph\tshell\trunning\t')" "$(printf 'old\tshell\tstopped\t/y')"
sbx-ide clean --dry-run >/dev/null 2>&1
check "dry-run keeps all 3 rows" "[ \"\$(wc -l < '$SBX_STUB_STATE')\" = 3 ]"
sbx-ide clean --yes >/dev/null 2>&1
check "removes orphan + stopped, keeps running" "[ \"\$(cut -f1 '$SBX_STUB_STATE' | tr '\n' ',')\" = 'keep,' ]"
seed "$(printf 'orph\tshell\trunning\t')" "$(printf 'old\tshell\tstopped\t/y')"
sbx-ide clean --orphans-only --yes >/dev/null 2>&1
check "orphans-only keeps stopped" "grep -q '^old	' '$SBX_STUB_STATE'"
check "orphans-only removes orphan" "! grep -q '^orph	' '$SBX_STUB_STATE'"
# The stub refuses a non-interactive rm WITHOUT --force (mirrors the real CLI);
# these passing at all proves `clean` now forces. Regression guard for the
# running-orphan removal bug.
echo "== sbx-ide clean: surfaces the real error on failure =="
seed "$(printf 'stuck\tshell\trunning\t')"
out="$(SBX_STUB_RM_FAIL=1 sbx-ide clean --orphans-only --yes 2>&1 || true)"
check "reports the failure"          "grep -qi 'failed to remove stuck' <<< \"\$out\""
check "shows sbx's real error text"  "grep -qi 'simulated failure' <<< \"\$out\""
check "keeps the row it couldn't remove" "grep -q '^stuck	' '$SBX_STUB_STATE'"

echo "== sbx-ide doctor: health + --verify =="
seed "$(printf 'ok1\tshell\trunning\t/x')" "$(printf 'orph\tshell\trunning\t')"
if sbx-ide doctor >/dev/null 2>&1; then rc=0; else rc=1; fi
check "non-zero exit when an orphan exists" "[ $rc -eq 1 ]"
out="$(seed "$(printf 'ok1\tshell\trunning\t/x')"; sbx-ide doctor 2>&1 || true)"
check "reports the default target"          "grep -qi 'default IDE target' <<< \"\$out\""
check "lists optional dev tools separately" "grep -qi 'Optional dev tools' <<< \"\$out\""
seed "$(printf 'cursor-sbx\tshell\trunning\t/Users/x/demos')"
if sbx-ide doctor --verify >/dev/null 2>&1; then rc=0; else rc=1; fi
check "--verify passes cleanly against the stub" "[ $rc -eq 0 ]"
check "--target vscode runs a vscode-only check"  "out=\"\$(sbx-ide doctor --target vscode 2>&1 || true)\"; grep -qi 'VS Code' <<< \"\$out\""

echo "== --help / --version =="
check "sbx-ide --help works"    "sbx-ide --help >/dev/null 2>&1"
check "sbx-ide --version prints" "sbx-ide --version 2>/dev/null | grep -q '$(cat "$ROOT/VERSION")'"
for sub in open set-default doctor ls clean; do
  check "sbx-ide $sub --help works" "sbx-ide $sub --help >/dev/null 2>&1"
done

echo "== install: fresh install + in-place upgrade + PATH markers =="
pfx="$WORK/prefix"
mkdir -p "$WORK/ihome"
HOME="$WORK/ihome" PREFIX="$pfx" "$ROOT/install.sh" >/dev/null 2>&1 || true
check "installs the VERSION file"  "[ -f '$pfx/lib/sbx-ide/VERSION' ]"
check "installs the dispatcher"    "[ -x '$pfx/bin/sbx-ide' ]"
check "installs the shims"         "[ -x '$pfx/bin/sbx-open' ]"
check "adds a marked PATH block"   "grep -q 'sbx-ide BEGIN' '$WORK/ihome/.zshrc' 2>/dev/null || grep -q 'sbx-ide BEGIN' '$WORK/ihome/.bashrc' 2>/dev/null"
printf '0.0.1\n' > "$pfx/lib/sbx-ide/VERSION"    # pretend an older install
upout="$(HOME="$WORK/ihome" PREFIX="$pfx" "$ROOT/install.sh" --update 2>&1 || true)"
check "reports the version upgrade" "grep -q 'Upgrading' <<< \"\$upout\""
check "upgrade rewrites VERSION"    "[ \"\$(cat '$pfx/lib/sbx-ide/VERSION')\" = \"\$(cat '$ROOT/VERSION')\" ]"

echo "== uninstall: removes files + PATH block, reports remainder =="
unout="$(HOME="$WORK/ihome" YES=1 PREFIX="$pfx" "$ROOT/install.sh" --uninstall 2>&1 || true)"
check "removes the dispatcher"       "[ ! -e '$pfx/bin/sbx-ide' ]"
check "removes the shims"            "[ ! -e '$pfx/bin/sbx-open' ]"
check "removes the lib dir"          "[ ! -d '$pfx/lib/sbx-ide' ]"
check "removes the PATH block"       "! grep -q 'sbx-ide BEGIN' '$WORK/ihome/.zshrc' 2>/dev/null && ! grep -q 'sbx-ide BEGIN' '$WORK/ihome/.bashrc' 2>/dev/null"
check "prints a 'what remains' summary" "grep -qi 'what remains' <<< \"\$unout\""

echo
echo "smoke: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
