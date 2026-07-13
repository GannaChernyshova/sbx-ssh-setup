#Requires -Version 5.1
# Remove a sandbox and all its resources. Pass a name, or run inside a project
# directory to target the sandbox named after it (same sanitizing as setup).
# To only stop (keep) a sandbox instead of removing it, use: sbx stop <name>
param([string]$Name)
$ErrorActionPreference = "Stop"

if (-not (Get-Command sbx -ErrorAction SilentlyContinue)) {
    Write-Host "X 'sbx' is not on PATH. Install: https://docs.docker.com/ai/sandboxes/get-started/" -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrEmpty($Name)) {
    $Name = ((Split-Path -Leaf (Get-Location).Path).ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
}

Write-Host "==> Removing sandbox '$Name' (stops it and deletes its resources)..."
sbx rm $Name
Write-Host "OK Removed '$Name'."
