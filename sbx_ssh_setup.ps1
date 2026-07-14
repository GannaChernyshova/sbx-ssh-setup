#Requires -Version 5.1
# Windows (PowerShell) equivalent of sbx_ssh_setup.sh
param(
    # AI agent / template to provision (e.g. codex, cursor, claude). Required.
    [Parameter(Mandatory = $true)]
    [string]$Agent
)
$ErrorActionPreference = "Stop"

$MinSbxVersion = [version]"0.35.0"

function Die($msg) { Write-Host "X $msg" -ForegroundColor Red; exit 1 }

# ── 1. Preflight checks ──────────────────────────────────────────────────────
Write-Host "==> Preflight checks..."

if (-not (Get-Command sbx -ErrorAction SilentlyContinue)) {
    Die "The 'sbx' CLI is not installed or not on PATH. Install Docker Sandboxes: https://docs.docker.com/ai/sandboxes/get-started/"
}

$verText = (& sbx version 2>$null)
if (-not $verText) { $verText = (& sbx --version 2>$null) }
$m = [regex]::Match((($verText) -join " "), '\d+\.\d+\.\d+')
if ($m.Success) {
    $sbxVer = [version]$m.Value
    if ($sbxVer -lt $MinSbxVersion) {
        Die "sbx $sbxVer is too old — this workflow needs sbx >= $MinSbxVersion. Update: https://docs.docker.com/ai/sandboxes/get-started/"
    }
    Write-Host "    sbx $sbxVer (>= $MinSbxVersion) OK"
} else {
    Write-Host "    ! Could not determine sbx version; continuing (need >= $MinSbxVersion)."
}

if (Get-Command docker -ErrorAction SilentlyContinue) {
    & docker info *> $null
    if ($LASTEXITCODE -ne 0) { Die "Docker is installed but not running. Start Docker Desktop and re-run." }
    Write-Host "    Docker is running OK"
} else {
    Write-Host "    ! 'docker' CLI not found; make sure Docker is installed and running."
}
Write-Host ""

# ── 4. Derive & sanitize the sandbox name from the current directory ─────────
$RawName = Split-Path -Leaf (Get-Location).Path
$SbxName = ($RawName.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
if ([string]::IsNullOrEmpty($SbxName)) { $SbxName = "sandbox" }

Write-Host "==> Project directory : $((Get-Location).Path)"
if ($SbxName -ne $RawName) {
    Write-Host "==> Sandbox name      : $SbxName  (sanitized from '$RawName')"
} else {
    Write-Host "==> Sandbox name      : $SbxName"
}
Write-Host "==> AI agent          : $Agent"
Write-Host ""

# ── One-time setup: enable features + restart daemon ────────────────────────
$FlagFile = Join-Path $HOME ".sbx_features_enabled"

if (-not (Test-Path $FlagFile)) {
    Write-Host "==> First-time setup: enabling experimental features..."
    sbx settings set platform.allowExperimentalFeatures true
    sbx settings set feature.ssh true

    Write-Host "==> Restarting daemon to apply features..."
    sbx daemon stop
    sbx daemon start -d

    Write-Host "==> Running sbx ssh setup..."
    sbx ssh setup

    New-Item -ItemType File -Path $FlagFile -Force | Out-Null
    Write-Host "==> One-time setup complete."
} else {
    Write-Host "==> Experimental features already enabled, skipping one-time setup."
}

# ── 5. Create the sandbox (skip if one with this name already exists) ────────
Write-Host ""
$existing = (& sbx ls 2>$null | Select-String -SimpleMatch $SbxName)
if ($existing) {
    Write-Host "==> Sandbox '$SbxName' already exists — skipping creation."
} else {
    Write-Host "==> Creating sandbox '$SbxName' with the '$Agent' template..."
    sbx run $Agent --name $SbxName
}

# ── 2. Verify SSH connectivity before handing off to the Codex UI ────────────
$sbxHost = "$SbxName.sbx"
Write-Host ""
Write-Host "==> Verifying SSH connectivity to $sbxHost ..."
& ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 $sbxHost true 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "OK SSH to $sbxHost works."
} else {
    Write-Host "! Could not reach $sbxHost over SSH yet."
    Write-Host "  The sandbox may still be starting — wait a few seconds and retry: ssh $sbxHost"
}

# ── Register a concrete SSH alias so Codex auto-discovers this sandbox ───────
# Codex enumerates *concrete* Host aliases in ~/.ssh/config and ignores the
# pattern-only 'Host *.sbx' that sbx manages. Adding an (empty) concrete alias
# named after this sandbox makes the connection appear in Codex automatically;
# all connection settings are still inherited from 'Host *.sbx' via `ssh -G`.
# Windows OpenSSH reads %USERPROFILE%\.ssh\config; fall back to $HOME elsewhere.
$sshHome   = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$sshDir    = Join-Path $sshHome ".ssh"
$sshConfig = Join-Path $sshDir "config"
$beginMark = "# >>> sbx-codex $sbxHost >>>"
$endMark   = "# <<< sbx-codex $sbxHost <<<"

if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }
$lines = @()
if (Test-Path $sshConfig) { $lines = @(Get-Content -LiteralPath $sshConfig) }

# Drop any previous block for this host so re-runs stay idempotent.
$filtered = New-Object System.Collections.Generic.List[string]
$skip = $false
foreach ($line in $lines) {
    if ($line -eq $beginMark) { $skip = $true; continue }
    if ($line -eq $endMark)   { $skip = $false; continue }
    if (-not $skip) { $filtered.Add($line) }
}
$block = @(
    $beginMark,
    "# Concrete alias so Codex auto-discovers this sandbox (it ignores 'Host *.sbx').",
    "# Settings are inherited from the sbx-managed 'Host *.sbx' block via 'ssh -G'.",
    "Host $sbxHost",
    $endMark
)
Set-Content -LiteralPath $sshConfig -Value (@($filtered) + $block) -Encoding ascii
Write-Host ""
Write-Host "==> Registered SSH alias '$sbxHost' in ~/.ssh/config for Codex auto-discovery."

# ── Work out the project directory inside the sandbox (the start directory) ──
# On macOS/Linux the host working tree is mounted at the SAME absolute path in
# the sandbox, so the host path is the remote path. On Windows the host path is
# a C:\ path that does not exist in the Linux sandbox, so we fall back to the
# sandbox's default login directory and tell the user to browse to their mount.
# NOTE: single-quote the remote path — escaped double quotes get mangled by
# PowerShell 5.1 when building the native ssh.exe command line.
$hostPath   = (Get-Location).Path
$remoteDir  = $hostPath
$mountKnown = $true
& ssh -o BatchMode=yes -o ConnectTimeout=10 $sbxHost "test -d '$hostPath'" 2>$null
if ($LASTEXITCODE -ne 0) {
    $mountKnown = $false
    $alt = (& ssh -o BatchMode=yes -o ConnectTimeout=10 $sbxHost 'pwd' 2>$null)
    if ($alt) { $remoteDir = ($alt | Select-Object -First 1).Trim() }
}
if ($mountKnown) {
    & ssh -o BatchMode=yes -o ConnectTimeout=10 $sbxHost "mkdir -p '$remoteDir'" 2>$null
    Write-Host "==> Project directory ready in sandbox: $remoteDir"
} else {
    Write-Host "==> Could not map this Windows path into the sandbox; the sandbox's default"
    Write-Host "    directory is '$remoteDir'. In Codex, browse to your mounted project folder."
}

# ── Register the connection in the Codex app via its supported deep link ─────
# codex://settings/connections/ssh/add?name=<alias> — the name must match the
# Host alias above. This makes the Codex app add/enable the connection without
# a manual Settings -> Connections -> Refresh.
$deepLink = "codex://settings/connections/ssh/add?name=$sbxHost"
try { Start-Process $deepLink } catch {}

# ── Copy the remote project path to the clipboard (pasted into Codex) ────────
$clipNote = ""
try { Set-Clipboard -Value $remoteDir; $clipNote = "  (copied to clipboard)" } catch {}
$folderLine = if ($mountKnown) { "   3. Set the project folder to:" } else { "   3. Set the project folder (browse from the sandbox default below):" }

Write-Host ""
Write-Host "OK Sandbox '$SbxName' is ready and registered for Codex."
Write-Host ""
Write-Host "In Codex, just create the project:"
Write-Host "   1. New project -> Remote."
Write-Host "   2. Pick the connection '$sbxHost'. It should already be listed (registered"
Write-Host "      via the Codex deep link). If not, open this link or Refresh Settings ->"
Write-Host "      Connections:  $deepLink"
Write-Host $folderLine
Write-Host "        $remoteDir$clipNote"
Write-Host "   4. Click Add project, then start coding."
Write-Host ""
Write-Host "Terminal access:  ssh $sbxHost"
Write-Host "Full Codex UI walkthrough: docs/codex.md"
