#!/bin/bash
# List all sbx sandboxes (name, agent, status, workspace) so you can reconnect.
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

command -v sbx >/dev/null 2>&1 || {
  echo "✗ 'sbx' is not on PATH. Install: https://docs.docker.com/ai/sandboxes/get-started/" >&2
  exit 1
}

echo "==> Sandboxes:"
sbx ls
echo ""
echo "Connect to one over SSH with:  ssh <sandbox-name>.sbx"
