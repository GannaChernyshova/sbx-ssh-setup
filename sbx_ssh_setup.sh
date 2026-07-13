#!/bin/bash
set -euo pipefail

# Ensure Homebrew binaries are on PATH (required on Apple Silicon Macs)
export PATH="/opt/homebrew/bin:$PATH"

MIN_SBX_VERSION="0.35.0"

die() { echo "✗ $*" >&2; exit 1; }

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

# ── One-time setup: enable features + restart daemon ────────────────────────
FLAG_FILE="$HOME/.sbx_features_enabled"

if [ ! -f "$FLAG_FILE" ]; then
  echo "==> First-time setup: enabling experimental features..."
  sbx settings set platform.allowExperimentalFeatures true
  sbx settings set feature.ssh true

  echo "==> Restarting daemon to apply features..."
  sbx daemon stop
  sbx daemon start -d

  echo "==> Running sbx ssh setup..."
  sbx ssh setup

  touch "$FLAG_FILE"
  echo "==> One-time setup complete."
else
  echo "==> Experimental features already enabled, skipping one-time setup."
fi

# ── 5. Create the sandbox (skip if one with this name already exists) ────────
echo ""
if sbx ls 2>/dev/null | grep -qw "$SBX_NAME"; then
  echo "==> Sandbox '$SBX_NAME' already exists — skipping creation."
else
  echo "==> Creating sandbox '$SBX_NAME' with the '$AGENT' template..."
  sbx run "$AGENT" --name "$SBX_NAME"
fi

# ── 2. Verify SSH connectivity before handing off to the Codex UI ────────────
HOST="${SBX_NAME}.sbx"
echo ""
echo "==> Verifying SSH connectivity to $HOST ..."
if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$HOST" true 2>/dev/null; then
  echo "✓ SSH to $HOST works."
else
  echo "! Could not reach $HOST over SSH yet."
  echo "  The sandbox may still be starting — wait a few seconds and retry: ssh $HOST"
fi

# ── 3. Print copy-paste-ready Codex values (and copy hostname to clipboard) ──
CLIP_NOTE=""
if command -v pbcopy >/dev/null 2>&1; then
  printf '%s' "$HOST" | pbcopy && CLIP_NOTE="  (copied to clipboard)"
elif command -v wl-copy >/dev/null 2>&1; then
  printf '%s' "$HOST" | wl-copy && CLIP_NOTE="  (copied to clipboard)"
elif command -v xclip >/dev/null 2>&1; then
  printf '%s' "$HOST" | xclip -selection clipboard >/dev/null 2>&1 && CLIP_NOTE="  (copied to clipboard)"
fi

cat <<EOF

✓ Sandbox '$SBX_NAME' is ready.

Add this connection in Codex (Settings → Connections → Add → Add manually):
   Display name:  $SBX_NAME
   Hostname:      $HOST$CLIP_NOTE

Or connect from a terminal:  ssh $HOST

Full Codex UI walkthrough: docs/codex.md
EOF
