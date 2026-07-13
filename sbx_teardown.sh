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
