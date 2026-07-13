#!/bin/bash
set -e

# Ensure Homebrew binaries are on PATH (required on Apple Silicon Macs)
export PATH="/opt/homebrew/bin:$PATH"

# AI agent / template to provision (e.g. codex, cursor, claude). Required.
AGENT="$1"
if [ -z "$AGENT" ]; then
  echo "Usage: $0 <agent>   (e.g. codex, cursor, claude)" >&2
  exit 1
fi

# Derive sandbox name from the current project directory (use as-is, no suffix)
PROJECT_DIR=$(basename "$PWD")
SBX_NAME="${PROJECT_DIR}"

echo "==> Project directory : $PWD"
echo "==> Sandbox name      : $SBX_NAME"
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

# ── Create the sandbox ───────────────────────────────────────────────────────
echo ""
echo "==> Creating sandbox '$SBX_NAME' with the '$AGENT' template..."
sbx run "$AGENT" --name "$SBX_NAME"

echo ""
echo "✓ Sandbox '$SBX_NAME' is ready. Connect with:"
echo "  ssh ${SBX_NAME}.sbx"