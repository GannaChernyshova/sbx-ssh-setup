#!/bin/bash
# Remove a sandbox and all its resources. Pass a name, or run inside a project
# directory to target the sandbox named after it (same sanitizing as setup).
# To only stop (keep) a sandbox instead of removing it, use: sbx stop <name>
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

command -v sbx >/dev/null 2>&1 || {
  echo "✗ 'sbx' is not on PATH. Install: https://docs.docker.com/ai/sandboxes/get-started/" >&2
  exit 1
}

NAME="${1:-}"
if [ -z "$NAME" ]; then
  NAME="$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed -E 's/^-+//; s/-+$//')"
fi

echo "==> Removing sandbox '$NAME' (stops it and deletes its resources)..."
sbx rm "$NAME"
echo "✓ Removed '$NAME'."

# Remove the concrete SSH alias the setup script added for Codex discovery.
SSH_CONFIG="$HOME/.ssh/config"
HOST="${NAME}.sbx"
BEGIN_MARK="# >>> sbx-codex ${HOST} >>>"
END_MARK="# <<< sbx-codex ${HOST} <<<"
if [ -f "$SSH_CONFIG" ] && grep -qxF "$BEGIN_MARK" "$SSH_CONFIG" 2>/dev/null; then
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0==b {skip=1; next} $0==e {skip=0; next} !skip {print}
  ' "$SSH_CONFIG" >"$SSH_CONFIG.tmp" && mv "$SSH_CONFIG.tmp" "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG" 2>/dev/null || true
  echo "✓ Removed Codex SSH alias '$HOST' from ~/.ssh/config."
fi
