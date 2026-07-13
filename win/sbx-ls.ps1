<#
.SYNOPSIS
  sbx-ls — a human-friendly list of sandboxes; flags orphans and stopped ones.
#>
[CmdletBinding()]
param([switch] $Version, [switch] $Help)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\SbxCodex.psm1') -Force

if ($Help)    { Get-Help $MyInvocation.MyCommand.Path -Detailed; exit 0 }
if ($Version) { "sbx-ls $(Get-ToolkitVersion)"; exit 0 }

if (-not (Test-SbxPresent)) { Stop-WithError "'sbx' not found on PATH." }

$rows = @(Get-SbxList)
if ($rows.Count -eq 0) { Write-Info "No sandboxes yet. Create one with: sbx-open <path>"; exit 0 }

$orphans = 0; $stopped = 0
$rows | ForEach-Object {
    $ws = $_.Workspace; $tag = ''
    if ([string]::IsNullOrEmpty($ws)) { $tag = ' (orphan)'; $orphans++; $ws = '-' }
    if ($_.Status -eq 'stopped') { $stopped++ }
    [pscustomobject]@{ SANDBOX = $_.Name; AGENT = $_.Agent; STATUS = $_.Status; WORKSPACE = "$ws$tag" }
} | Format-Table -AutoSize

$rows | Where-Object { $_.Workspace } | ForEach-Object { Write-Hint "reopen: sbx-open '$($_.Workspace)'" }
if ($orphans -gt 0) { Write-WarnMsg "$orphans orphan sandbox(es) — reclaim them with: sbx-clean -OrphansOnly" }
if ($stopped -gt 0) { Write-Hint "$stopped stopped — reopen with sbx-open, or remove with: sbx-clean -Stopped" }
