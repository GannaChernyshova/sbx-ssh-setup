#!/bin/bash
set -euo pipefail

# Ensure Homebrew binaries are on PATH (required on Apple Silicon Macs)
export PATH="/opt/homebrew/bin:$PATH"

MIN_SBX_VERSION="0.38.0"

die() { echo "✗ $*" >&2; exit 1; }

# Quote one value for the POSIX shell used by the remote SSH server.
shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Return 0 if version $1 >= $2 (portable; BSD/macOS sort lacks -V).
version_ge() {
  local IFS=.
  # shellcheck disable=SC2206
  local a=($1) b=($2) i
  for ((i = 0; i < ${#b[@]}; i++)); do
    local ai="${a[i]:-0}" bi="${b[i]}"
    if ((10#$ai > 10#$bi)); then return 0; fi
    if ((10#$ai < 10#$bi)); then return 1; fi
  done
  return 0
}

# ── Argument: AI agent / template (required) ─────────────────────────────────
AGENT="${1:-}"
if [ -z "$AGENT" ]; then
  echo "Usage: $0 <agent>   (e.g. codex, cursor, claude)" >&2
  exit 1
fi

# ── 1. Preflight checks ──────────────────────────────────────────────────────
echo "==> Preflight checks..."

command -v sbx >/dev/null 2>&1 || die "The 'sbx' CLI is not installed or not on PATH.
   Install Docker Sandboxes: https://docs.docker.com/ai/sandboxes/get-started/"
command -v ssh >/dev/null 2>&1 || die "The OpenSSH client ('ssh') is not installed or not on PATH."

SBX_VERSION="$({ sbx version 2>/dev/null || sbx --version 2>/dev/null || true; } \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
if [ -n "$SBX_VERSION" ]; then
  if version_ge "$SBX_VERSION" "$MIN_SBX_VERSION"; then
    echo "    sbx $SBX_VERSION (>= $MIN_SBX_VERSION) ✓"
  else
    die "sbx $SBX_VERSION is too old — this workflow needs sbx >= $MIN_SBX_VERSION.
   Update Docker Sandboxes: https://docs.docker.com/ai/sandboxes/get-started/"
  fi
else
  echo "    ! Could not determine sbx version; continuing (need >= $MIN_SBX_VERSION)."
fi

if command -v docker >/dev/null 2>&1; then
  docker info >/dev/null 2>&1 || die "Docker is installed but not running. Start Docker Desktop and re-run."
  echo "    Docker is running ✓"
else
  echo "    ! 'docker' CLI not found; make sure Docker is installed and running."
fi
echo ""

# ── 4. Derive & sanitize the sandbox name from the current directory ─────────
RAW_NAME="$(basename "$PWD")"
SBX_NAME="$(printf '%s' "$RAW_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed -E 's/^-+//; s/-+$//')"
[ -z "$SBX_NAME" ] && SBX_NAME="sandbox"

echo "==> Project directory : $PWD"
if [ "$SBX_NAME" != "$RAW_NAME" ]; then
  echo "==> Sandbox name      : $SBX_NAME  (sanitized from '$RAW_NAME')"
else
  echo "==> Sandbox name      : $SBX_NAME"
fi
echo "==> AI agent          : $AGENT"
echo ""

# ── One-time setup: Docker login + agent auth + SSH ────────────────────
# A v0.38-specific marker migrates users of the legacy experimental-feature flow.
FLAG_FILE="$HOME/.sbx_0_38_setup_complete"

if [ ! -f "$FLAG_FILE" ]; then
  echo "==> First-time setup: signing in to Docker..."
  sbx login

  echo "==> Authenticating OpenAI with OAuth..."
  sbx secret set openai --oauth

  echo "==> Configuring SSH access..."
  sbx setup ssh

  touch "$FLAG_FILE"
  echo "==> One-time setup complete."
else
  echo "==> Docker login, OpenAI OAuth, and SSH setup already completed; skipping."
fi

# ── 5. Create the sandbox (skip if one with this name already exists) ────────
echo ""
if ! SBX_LIST="$(sbx ls 2>/dev/null)"; then
  die "sbx ls failed; cannot determine whether sandbox '$SBX_NAME' already exists."
fi
if printf '%s\n' "$SBX_LIST" | grep -qw "$SBX_NAME"; then
  echo "==> Sandbox '$SBX_NAME' already exists — skipping creation."
else
  echo "==> Creating sandbox '$SBX_NAME' with the '$AGENT' template..."
  sbx run --name "$SBX_NAME" "$AGENT"
fi

# ── 2. Verify SSH connectivity before handing off to the Codex UI ────────────
HOST="${SBX_NAME}.sbx"
SSH_CONNECTED=false
echo ""
echo "==> Verifying SSH connectivity to $HOST ..."
if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$HOST" true 2>/dev/null; then
  SSH_CONNECTED=true
  echo "✓ SSH to $HOST works."
else
  echo "! Could not reach $HOST over SSH yet."
  echo "  The sandbox may still be starting — wait a few seconds and retry: ssh $HOST"
fi

# ── Register a concrete SSH alias so Codex auto-discovers this sandbox ────────
# Codex enumerates *concrete* Host aliases in ~/.ssh/config and ignores the
# pattern-only 'Host *.sbx' that sbx manages. Adding an (empty) concrete alias
# named after this sandbox makes the connection appear in Codex automatically;
# all connection settings are still inherited from 'Host *.sbx' via `ssh -G`.
SSH_CONFIG="$HOME/.ssh/config"
BEGIN_MARK="# >>> sbx-codex ${HOST} >>>"
END_MARK="# <<< sbx-codex ${HOST} <<<"

mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh" 2>/dev/null || true
touch "$SSH_CONFIG" && chmod 600 "$SSH_CONFIG" 2>/dev/null || true

# Drop any previous block for this host so re-runs stay idempotent.
if grep -qxF "$BEGIN_MARK" "$SSH_CONFIG" 2>/dev/null; then
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0==b {skip=1; next} $0==e {skip=0; next} !skip {print}
  ' "$SSH_CONFIG" >"$SSH_CONFIG.tmp" && mv "$SSH_CONFIG.tmp" "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG" 2>/dev/null || true
fi
# Make sure the file ends with a newline before appending our block.
if [ -s "$SSH_CONFIG" ] && [ -n "$(tail -c1 "$SSH_CONFIG" 2>/dev/null)" ]; then
  printf '\n' >>"$SSH_CONFIG"
fi
{
  echo "$BEGIN_MARK"
  echo "# Concrete alias so Codex auto-discovers this sandbox (it ignores 'Host *.sbx')."
  echo "# Settings are inherited from the sbx-managed 'Host *.sbx' block via 'ssh -G'."
  echo "Host ${HOST}"
  echo "$END_MARK"
} >>"$SSH_CONFIG"
echo ""
echo "==> Registered SSH alias '$HOST' in ~/.ssh/config for Codex auto-discovery."

# ── Pre-provision the project directory (the sandbox's start directory) ──────
# On macOS/Linux the host working tree is mounted at the same path inside the
# sandbox, so the folder Codex should open is this directory. Verify it exists
# in the sandbox; otherwise fall back to the sandbox's default login directory.
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
REMOTE_DIR="$PWD"
REMOTE_DIR_QUOTED="$(shell_quote "$REMOTE_DIR")"
if ! ssh "${SSH_OPTS[@]}" "$HOST" "test -d $REMOTE_DIR_QUOTED" 2>/dev/null; then
  ALT_DIR="$({ ssh "${SSH_OPTS[@]}" "$HOST" 'pwd' 2>/dev/null || true; } | tr -d '\r')"
  [ -n "$ALT_DIR" ] && REMOTE_DIR="$ALT_DIR"
fi
REMOTE_DIR_QUOTED="$(shell_quote "$REMOTE_DIR")"
if ssh "${SSH_OPTS[@]}" "$HOST" "mkdir -p $REMOTE_DIR_QUOTED" 2>/dev/null; then
  echo "==> Project directory ready in sandbox: $REMOTE_DIR"
else
  echo "==> Could not verify the project directory yet; expected path: $REMOTE_DIR"
fi

# ── Register the connection in the Codex app via its supported deep link ─────
# codex://settings/connections/ssh/add?name=<alias> — the name must match the
# Host alias above. This makes the Codex app add the connection without
# a manual Settings → Connections → Refresh.
DEEPLINK="codex://settings/connections/ssh/add?name=${HOST}"
if command -v open >/dev/null 2>&1; then
  open "$DEEPLINK" >/dev/null 2>&1 || true
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$DEEPLINK" >/dev/null 2>&1 || true
fi

# ── Copy the remote project path to the clipboard (pasted into Codex) ────────
CLIP_NOTE=""
if command -v pbcopy >/dev/null 2>&1; then
  printf '%s' "$REMOTE_DIR" | pbcopy && CLIP_NOTE="  (copied to clipboard)"
elif command -v wl-copy >/dev/null 2>&1; then
  printf '%s' "$REMOTE_DIR" | wl-copy && CLIP_NOTE="  (copied to clipboard)"
elif command -v xclip >/dev/null 2>&1; then
  printf '%s' "$REMOTE_DIR" | xclip -selection clipboard >/dev/null 2>&1 && CLIP_NOTE="  (copied to clipboard)"
fi

if [ "$SSH_CONNECTED" = true ]; then
  STATUS_LINE="✓ Sandbox '$SBX_NAME' is ready and registered for Codex."
else
  STATUS_LINE="! Sandbox '$SBX_NAME' is provisioned and registered, but SSH is not ready yet."
fi

cat <<EOF

$STATUS_LINE

In Codex, just create the project:
   1. New project → Remote.
   2. Pick the connection "$HOST". It should already be listed (registered via
      the Codex deep link). If not, click this link or Refresh Settings →
      Connections:  $DEEPLINK
   3. Set the project folder to:
        $REMOTE_DIR$CLIP_NOTE
   4. Click Add project, then start coding.

Terminal access:  ssh $HOST
Full Codex UI walkthrough: docs/codex.md
EOF
