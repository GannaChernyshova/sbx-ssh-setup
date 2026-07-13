<#
.SYNOPSIS
  install.ps1 — install the sbx-codex toolkit on Windows.
.DESCRIPTION
  Copies the PowerShell commands, the shared module, and the .cmd shims to a
  per-user program directory and adds it to the user PATH, then runs sbx-doctor.
  Idempotent and version-aware. Safe for silent MDM (Intune) deployment:

    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1

.PARAMETER Uninstall
  Remove the installed files and the PATH entry.
.PARAMETER Prefix
  Install location (default: %LOCALAPPDATA%\Programs\sbx-codex).
.EXAMPLE
  .\install.ps1
.EXAMPLE
  .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string] $Prefix = (Join-Path $env:LOCALAPPDATA 'Programs\sbx-codex'),
    [switch] $Uninstall,
    [switch] $Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcVersion = (Get-Content (Join-Path $src 'VERSION') -Raw).Trim()

function Add-UserPath {
    param([string]$Dir)
    $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $cur) { $cur = '' }
    if (($cur -split ';') -notcontains $Dir) {
        $new = if ($cur.TrimEnd(';')) { "$($cur.TrimEnd(';'));$Dir" } else { $Dir }
        [Environment]::SetEnvironmentVariable('Path', $new, 'User')
        $env:Path = "$env:Path;$Dir"
        Write-Host "OK added $Dir to your user PATH (restart your terminal to pick it up)" -ForegroundColor Green
    } else {
        Write-Host "OK $Dir already on your user PATH" -ForegroundColor Green
    }
}

function Remove-UserPath {
    param([string]$Dir)
    $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($cur) {
        $new = (($cur -split ';') | Where-Object { $_ -and $_ -ne $Dir }) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $new, 'User')
    }
}

if ($Version) { $srcVersion; exit 0 }

if ($Uninstall) {
    Write-Host "Removing sbx-codex from $Prefix …"
    if (Test-Path $Prefix) { Remove-Item -Recurse -Force $Prefix }
    Remove-UserPath $Prefix
    Write-Host "OK Uninstalled." -ForegroundColor Green
    exit 0
}

$installedVersionFile = Join-Path $Prefix 'VERSION'
$old = if (Test-Path $installedVersionFile) { (Get-Content $installedVersionFile -Raw).Trim() } else { $null }
if ($old) {
    if ($old -eq $srcVersion) { Write-Host "Reinstalling sbx-codex v$srcVersion (already installed)" }
    else { Write-Host "Upgrading sbx-codex $old -> $srcVersion" }
} else { Write-Host "Installing sbx-codex v$srcVersion" }
Write-Host "  from: $src"
Write-Host "  to:   $Prefix"

New-Item -ItemType Directory -Path (Join-Path $Prefix 'lib') -Force | Out-Null

Copy-Item (Join-Path $src 'win\*.ps1') $Prefix -Force
Copy-Item (Join-Path $src 'win\*.cmd') $Prefix -Force
Copy-Item (Join-Path $src 'win\lib\SbxCodex.psm1') (Join-Path $Prefix 'lib') -Force
Copy-Item (Join-Path $src 'VERSION') $Prefix -Force
# Also drop a VERSION next to the module so Get-ToolkitVersion resolves it.
Copy-Item (Join-Path $src 'VERSION') (Join-Path $Prefix 'lib') -Force
Write-Host "OK installed commands + module" -ForegroundColor Green

Add-UserPath $Prefix

Write-Host ''
Write-Host "Running sbx-doctor …"
try { & (Join-Path $Prefix 'sbx-doctor.cmd') } catch { Write-Host "!  sbx-doctor reported issues — fix them before using sbx-open." -ForegroundColor Yellow }

Write-Host ''
Write-Host "OK Done — sbx-codex v$srcVersion. Open your first project with:  sbx-open C:\src\acme-api" -ForegroundColor Green
