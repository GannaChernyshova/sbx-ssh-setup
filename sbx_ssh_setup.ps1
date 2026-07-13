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

# ── 3. Print copy-paste-ready Codex values (and copy hostname to clipboard) ──
$clipNote = ""
try { Set-Clipboard -Value $sbxHost; $clipNote = "  (copied to clipboard)" } catch {}

Write-Host ""
Write-Host "OK Sandbox '$SbxName' is ready."
Write-Host ""
Write-Host "Add this connection in Codex (Settings -> Connections -> Add -> Add manually):"
Write-Host "   Display name:  $SbxName"
Write-Host "   Hostname:      $sbxHost$clipNote"
Write-Host ""
Write-Host "Or connect from a terminal:  ssh $sbxHost"
Write-Host "Full Codex UI walkthrough: docs/codex.md"
