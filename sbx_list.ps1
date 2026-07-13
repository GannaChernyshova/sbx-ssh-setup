#Requires -Version 5.1
# List all sbx sandboxes (name, agent, status, workspace) so you can reconnect.
$ErrorActionPreference = "Stop"

if (-not (Get-Command sbx -ErrorAction SilentlyContinue)) {
    Write-Host "X 'sbx' is not on PATH. Install: https://docs.docker.com/ai/sandboxes/get-started/" -ForegroundColor Red
    exit 1
}

Write-Host "==> Sandboxes:"
sbx ls
Write-Host ""
Write-Host "Connect to one over SSH with:  ssh <sandbox-name>.sbx"
