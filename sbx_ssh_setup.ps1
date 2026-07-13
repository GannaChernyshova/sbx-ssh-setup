#Requires -Version 5.1
# Windows (PowerShell) equivalent of sbx_ssh_setup.sh
$ErrorActionPreference = "Stop"

# Derive sandbox name from the current directory (use as-is, no suffix)
$SbxName = Split-Path -Leaf (Get-Location).Path

Write-Host "==> Project directory : $((Get-Location).Path)"
Write-Host "==> Sandbox name      : $SbxName"
Write-Host ""

# One-time setup: enable features + restart daemon
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

# Create the sandbox
Write-Host ""
Write-Host "==> Creating sandbox '$SbxName' with the Codex template..."
sbx run codex --name $SbxName

Write-Host ""
Write-Host "OK Sandbox '$SbxName' is ready. Connect with:"
Write-Host "  ssh $SbxName.sbx"
