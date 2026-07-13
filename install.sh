#!/usr/bin/env bash
#
# install.sh — install the sbx-codex toolkit (macOS / Linux).
#
# Copies the bin/ commands and lib/ helpers to a prefix (default ~/.local),
# checks that the bin dir is on PATH, and runs sbx-doctor at the end.
#
#   ./install.sh                     # install (or upgrade) in ~/.local
#   ./install.sh --update            # same thing; explicit "upgrade in place"
#   PREFIX=/usr/local ./install.sh   # brew-style prefix (may need sudo)
#   ./install.sh --uninstall         # remove what we installed
#   ./install.sh --version           # print the version of this source tree
#
# Install is idempotent and version-aware. For fleet deployment (Jamf/Intune),
# run non-interactively: it makes no prompts and exits non-zero only on a real
# install failure (a failing doctor is reported but does not fail the install).
#
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/lib/sbx-codex"
COMMANDS=(sbx-open sbx-ls sbx-clean sbx-doctor)
SRC_VERSION="$(tr -d '[:space:]' < "$SRC/VERSION" 2>/dev/null || echo unknown)"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; Z=$'\033[0m'
else B=''; G=''; Y=''; R=''; D=''; Z=''; fi
say()  { printf '%s\n' "$*"; }
good() { printf '%s✅%s %s\n' "$G" "$Z" "$*"; }
warnx(){ printf '%s⚠️ %s %s\n' "$Y" "$Z" "$*"; }
bad()  { printf '%s❌%s %s\n' "$R" "$Z" "$*" >&2; }

usage() {
  cat <<EOF
${B}install.sh${Z} — install / upgrade the sbx-codex toolkit (v$SRC_VERSION)

USAGE
  ./install.sh [--update | --uninstall | --version]

OPTIONS
  --update     Upgrade an existing install in place.
  --uninstall  Remove installed commands + libs.
  --version    Print the version of this source tree and exit.

ENV
  PREFIX   install prefix (default: \$HOME/.local)
           binaries -> \$PREFIX/bin, libraries -> \$PREFIX/lib/sbx-codex
EOF
}

installed_version() { [[ -f "$LIB_DIR/VERSION" ]] && tr -d '[:space:]' < "$LIB_DIR/VERSION"; }

# ── macOS Finder "Quick Action" (right-click → Open in Codex Sandbox) ────────
QA_DIR="$HOME/Library/Services/Open in Codex Sandbox.workflow"

is_macos() { [[ "$(uname -s)" == "Darwin" ]]; }

remove_macos_quickaction() {
  is_macos || return 0
  [[ -d "$QA_DIR" ]] && rm -rf "$QA_DIR" && say "  removed Finder Quick Action" || true
}

install_macos_quickaction() {
  is_macos || return 0
  local sbxopen="$BIN_DIR/sbx-open" qa_script wflow

  # Runs when the user right-clicks a folder. inputMethod=1 => selected folder
  # paths arrive as arguments ($@). We open Terminal so the user SEES progress
  # and the final "pick host + folder" instructions (and Codex launches).
  qa_script=$(cat <<'EOS'
for f in "$@"; do
  /usr/bin/osascript -e "tell application \"Terminal\" to do script \"'__SBXOPEN__' codex '$f'\"" -e "tell application \"Terminal\" to activate"
done
EOS
)
  qa_script="${qa_script//__SBXOPEN__/$sbxopen}"

  mkdir -p "$QA_DIR/Contents"

  cat > "$QA_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Open in Codex Sandbox</string>
	<key>CFBundleIdentifier</key>
	<string>com.docker.sbxcodex.openincodex</string>
	<key>NSServices</key>
	<array>
		<dict>
			<key>NSMenuItem</key>
			<dict>
				<key>default</key>
				<string>Open in Codex Sandbox</string>
			</dict>
			<key>NSMessage</key>
			<string>runWorkflowAsService</string>
			<key>NSRequiredContext</key>
			<dict>
				<key>NSApplicationIdentifier</key>
				<string>com.apple.finder</string>
			</dict>
			<key>NSSendFileTypes</key>
			<array>
				<string>public.folder</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
PLIST

  wflow=$(cat <<'WF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AMApplicationBuild</key>
	<string>523</string>
	<key>AMApplicationVersion</key>
	<string>2.10</string>
	<key>AMDocumentVersion</key>
	<string>2</string>
	<key>actions</key>
	<array>
		<dict>
			<key>action</key>
			<dict>
				<key>AMAccepts</key>
				<dict>
					<key>Container</key>
					<string>List</string>
					<key>Optional</key>
					<true/>
					<key>Types</key>
					<array>
						<string>com.apple.cocoa.string</string>
					</array>
				</dict>
				<key>AMActionVersion</key>
				<string>2.0.3</string>
				<key>AMApplication</key>
				<array>
					<string>Automator</string>
				</array>
				<key>AMParameterProperties</key>
				<dict>
					<key>COMMAND_STRING</key>
					<dict/>
					<key>CheckedForUserDefaultShell</key>
					<dict/>
					<key>inputMethod</key>
					<dict/>
					<key>shell</key>
					<dict/>
					<key>source</key>
					<dict/>
				</dict>
				<key>AMProvides</key>
				<dict>
					<key>Container</key>
					<string>List</string>
					<key>Types</key>
					<array>
						<string>com.apple.cocoa.string</string>
					</array>
				</dict>
				<key>ActionBundlePath</key>
				<string>/System/Library/Automator/Run Shell Script.action</string>
				<key>ActionName</key>
				<string>Run Shell Script</string>
				<key>ActionParameters</key>
				<dict>
					<key>COMMAND_STRING</key>
					<string>__COMMAND_STRING__</string>
					<key>CheckedForUserDefaultShell</key>
					<true/>
					<key>inputMethod</key>
					<integer>1</integer>
					<key>shell</key>
					<string>/bin/bash</string>
					<key>source</key>
					<string></string>
				</dict>
				<key>BundleIdentifier</key>
				<string>com.apple.RunShellScript</string>
				<key>CFBundleVersion</key>
				<string>2.0.3</string>
				<key>CanShowSelectedItemsWhenRun</key>
				<false/>
				<key>CanShowWhenRun</key>
				<true/>
				<key>Category</key>
				<array>
					<string>AMCategoryUtilities</string>
				</array>
				<key>Class Name</key>
				<string>RunShellScriptAction</string>
				<key>InputUUID</key>
				<string>A1000000-0000-0000-0000-000000000001</string>
				<key>Keywords</key>
				<array>
					<string>Shell</string>
				</array>
				<key>OutputUUID</key>
				<string>A1000000-0000-0000-0000-000000000002</string>
				<key>UUID</key>
				<string>A1000000-0000-0000-0000-000000000003</string>
				<key>UnlocalizedApplications</key>
				<array>
					<string>Automator</string>
				</array>
				<key>arguments</key>
				<dict/>
				<key>isViewVisible</key>
				<integer>1</integer>
				<key>location</key>
				<string>309.000000:253.000000</string>
				<key>nibPath</key>
				<string>/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib</string>
			</dict>
			<key>isViewVisible</key>
			<integer>1</integer>
		</dict>
	</array>
	<key>connectors</key>
	<dict/>
	<key>workflowMetaData</key>
	<dict>
		<key>applicationBundleIDsByPath</key>
		<dict/>
		<key>applicationPaths</key>
		<array/>
		<key>inputTypeIdentifier</key>
		<string>com.apple.Automator.fileSystemObject</string>
		<key>outputTypeIdentifier</key>
		<string>com.apple.Automator.nothing</string>
		<key>presentationMode</key>
		<integer>11</integer>
		<key>processesInput</key>
		<false/>
		<key>serviceApplicationBundleID</key>
		<string>com.apple.finder</string>
		<key>serviceApplicationPath</key>
		<string>/System/Library/CoreServices/Finder.app</string>
		<key>serviceInputTypeIdentifier</key>
		<string>com.apple.Automator.fileSystemObject</string>
		<key>serviceOutputTypeIdentifier</key>
		<string>com.apple.Automator.nothing</string>
		<key>serviceProcessesInput</key>
		<integer>0</integer>
		<key>systemImageName</key>
		<string>NSActionTemplate</string>
		<key>useAutomaticInputType</key>
		<integer>0</integer>
		<key>workflowTypeIdentifier</key>
		<string>com.apple.Automator.servicesMenu</string>
	</dict>
</dict>
</plist>
WF
)
  wflow="${wflow//__COMMAND_STRING__/$qa_script}"
  printf '%s\n' "$wflow" > "$QA_DIR/Contents/document.wflow"

  # Ask the Services system to re-scan so the menu item appears without logout.
  /System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true
  good "installed Finder Quick Action: right-click a folder → Open in Codex Sandbox"
  say "  ${D}If it doesn't show yet: System Settings → Keyboard → Keyboard Shortcuts → Services,${Z}"
  say "  ${D}enable 'Open in Codex Sandbox', or log out and back in once.${Z}"
}

uninstall() {
  say "Removing sbx-codex from $PREFIX …"
  local c
  for c in "${COMMANDS[@]}"; do rm -f "$BIN_DIR/$c" && say "  removed $BIN_DIR/$c" || true; done
  rm -rf "$LIB_DIR" && say "  removed $LIB_DIR" || true
  remove_macos_quickaction
  good "Uninstalled."
  exit 0
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  -V|--version) say "$SRC_VERSION"; exit 0 ;;
  --update|--upgrade) ;;   # same code path as install
  --uninstall) uninstall ;;
  "") ;;
  *) bad "unknown option: $1"; usage; exit 2 ;;
esac

OLD_VERSION="$(installed_version || true)"
if [[ -n "$OLD_VERSION" ]]; then
  if [[ "$OLD_VERSION" == "$SRC_VERSION" ]]; then
    say "${B}Reinstalling sbx-codex v$SRC_VERSION${Z} (already installed)"
  else
    say "${B}Upgrading sbx-codex${Z} $OLD_VERSION ${B}→${Z} $SRC_VERSION"
  fi
else
  say "${B}Installing sbx-codex v$SRC_VERSION${Z}"
fi
say "  from: $SRC"
say "  bin:  $BIN_DIR"
say "  lib:  $LIB_DIR"

mkdir -p "$BIN_DIR" "$LIB_DIR"

install -m 0644 "$SRC/lib/common.sh"        "$LIB_DIR/common.sh"
install -m 0644 "$SRC/lib/sbx-interface.sh" "$LIB_DIR/sbx-interface.sh"
install -m 0644 "$SRC/lib/codex.sh"         "$LIB_DIR/codex.sh"
install -m 0644 "$SRC/VERSION"              "$LIB_DIR/VERSION"
good "installed libraries"

for c in "${COMMANDS[@]}"; do
  install -m 0755 "$SRC/bin/$c" "$BIN_DIR/$c"
  good "installed $c"
done

case ":$PATH:" in
  *":$BIN_DIR:"*) good "$BIN_DIR is on your PATH" ;;
  *)
    warnx "$BIN_DIR is NOT on your PATH."
    shell_rc="$HOME/.zshrc"; [[ "${SHELL:-}" == *bash ]] && shell_rc="$HOME/.bashrc"
    say "  Add it with:"
    say "    ${D}echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> $shell_rc${Z}"
    say "    ${D}exec \$SHELL -l${Z}"
    ;;
esac

install_macos_quickaction

say
say "${B}Running sbx-doctor …${Z}"
if "$BIN_DIR/sbx-doctor"; then :; else
  warnx "sbx-doctor reported issues above — fix them before using sbx-open."
fi

say
good "Done — sbx-codex v$SRC_VERSION. Open your first project with:  ${B}sbx-open ~/src/acme-api${Z}"
say "  ${D}Upgrade later: pull the latest source, then re-run ./install.sh (or: make update).${Z}"
