#!/bin/bash
# Open in Codex.command — double-click launcher for macOS.
#
# For the least-technical users: double-click in Finder, drag your project
# folder into the window, press Enter. Wraps `sbx-open codex <folder>`.

clear
printf '=== Open a project in Codex (safely sandboxed) ===\n\n'
printf 'Drag your project folder into this window, then press Enter:\n> '
read -r raw

# Unescape a path dragged from Finder/Terminal (handles spaces + quotes) and
# expand a leading ~. xargs parses one shell-quoted token without eval.
folder="$(printf '%s' "$raw" | xargs 2>/dev/null || printf '%s' "$raw")"
folder="${folder/#\~/$HOME}"

if [ -z "$folder" ]; then
  echo "No folder given. Close this window and try again."
  read -r _; exit 1
fi

# Prefer the installed command; fall back to the copy next to this launcher.
if command -v sbx-open >/dev/null 2>&1; then
  sbx-open codex "$folder"
else
  DIR="$(cd "$(dirname "$0")/.." && pwd)"
  "$DIR/bin/sbx-open" codex "$folder"
fi

printf '\nDone. You can close this window.\n'
read -r _
