<#
.SYNOPSIS
  sbx-doctor — diagnose an sbx + Codex setup with pass/fail checks and fixes.
.EXAMPLE
  sbx-doctor
.EXAMPLE
  sbx-doctor -Fix
#>
[CmdletBinding()]
param([switch] $Fix, [switch] $Version, [switch] $Help)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\SbxCodex.psm1') -Force

if ($Help)    { Get-Help $MyInvocation.MyCommand.Path -Detailed; exit 0 }
if ($Version) { "sbx-doctor $(Get-ToolkitVersion)"; exit 0 }

$script:pass = 0; $script:fail = 0; $script:warn = 0
function Ok  { param($m) $script:pass++; Write-Host "OK $m" -ForegroundColor Green }
function No  { param($m, $fix) $script:fail++; Write-Host "X  $m" -ForegroundColor Red; if ($fix) { Write-Host "     fix: $fix" -ForegroundColor Cyan } }
function Meh { param($m, $h) $script:warn++; Write-Host "!  $m" -ForegroundColor Yellow; if ($h) { Write-Host "     $h" -ForegroundColor DarkGray } }

Write-Host "`nsbx + Codex health check" -ForegroundColor White

# 1. sbx present + version
if (Test-SbxPresent) {
    $v = Get-SbxVersion
    if ($v -and (Test-VersionGe $v (Get-SbxMinVersion))) { Ok "sbx $v (>= $(Get-SbxMinVersion))" }
    elseif ($v) { No "sbx $v is older than required $(Get-SbxMinVersion)" "upgrade sbx" }
    else { Meh "sbx present but version could not be parsed" "check: sbx version" }
} else { No "sbx not found on PATH" "install the sbx CLI (v$(Get-SbxMinVersion)+)" }

# 2. Docker running
if (Test-Command 'docker') {
    & docker info 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Ok "Docker is running" } else { No "Docker is installed but not running" "start Docker Desktop" }
} else { Meh "docker CLI not found" "make sure Docker is installed and running" }

# 3. daemon reachable
if (Test-SbxPresent) {
    & sbx ls 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Ok "sbx daemon responding (sbx ls)" } else { No "sbx daemon not responding" "sbx diagnose" }
}

# 4. SSH feature enabled
if (Test-SbxFeaturesEnabled) { Ok "sbx SSH feature enabled (one-time setup done)" }
else { No "sbx SSH feature not enabled yet" "run: sbx-open <path>   (does the one-time setup automatically)" }

# 5. OpenAI secret
if (Test-SbxPresent) {
    if (Test-OpenAiSecret) { Ok "global '$(Get-SbxOpenAiSecret)' secret is set (Codex can authenticate)" }
    else { No "no global '$(Get-SbxOpenAiSecret)' secret (Codex can't run in the sandbox)" "sbx secret set -g $(Get-SbxOpenAiSecret) --oauth" }
}

# 6. Codex desktop app
if (Test-CodexApp) { Ok "Codex desktop app detected" }
else { Meh "Codex desktop app not detected" "install it from OpenAI, then re-run" }

# 7. orphan sandboxes
if (Test-SbxPresent) {
    $orphans = @(Get-SbxList | Where-Object { [string]::IsNullOrEmpty($_.Workspace) } | Select-Object -ExpandProperty Name)
    if ($orphans.Count -eq 0) { Ok "no orphan sandboxes (all have a workspace mount)" }
    else {
        No "$($orphans.Count) orphan sandbox(es): $($orphans -join ', ')" "sbx-clean -OrphansOnly"
        if ($Fix) {
            $ans = Read-Host "Remove the orphan sandbox(es) now? [y/N]"
            if ($ans -match '^(y|yes)$') { foreach ($o in $orphans) { & sbx rm $o 2>$null | Out-Null; Write-Host "removed $o" -ForegroundColor Green } }
        }
    }
}

Write-Host "`nSummary" -ForegroundColor White
Write-Host "OK $($script:pass) passed  !  $($script:warn) warnings  X $($script:fail) failed"
if ($script:fail -gt 0) { Write-Host "Apply the fixes above, then re-run: sbx-doctor" -ForegroundColor DarkGray; exit 1 }
Write-Host "Ready. Open a project with: sbx-open <path>" -ForegroundColor Green
