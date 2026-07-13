<#
.SYNOPSIS
  sbx-clean — remove orphan/stopped sandboxes and prune their Codex SSH aliases.
.EXAMPLE
  sbx-clean -OrphansOnly
.EXAMPLE
  sbx-clean acme-api -Yes
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)] [string[]] $Names,
    [switch] $OrphansOnly,
    [switch] $Stopped,
    [switch] $DryRun,
    [switch] $Yes,
    [switch] $Version,
    [switch] $Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\SbxCodex.psm1') -Force

if ($Help)    { Get-Help $MyInvocation.MyCommand.Path -Detailed; exit 0 }
if ($Version) { "sbx-clean $(Get-ToolkitVersion)"; exit 0 }

if (-not (Test-SbxPresent)) { Stop-WithError "'sbx' not found on PATH." }

$targets = @()
if ($Names -and $Names.Count -gt 0) {
    $targets = $Names
} else {
    foreach ($s in Get-SbxList) {
        $isOrphan  = [string]::IsNullOrEmpty($s.Workspace)
        $isStopped = ($s.Status -eq 'stopped')
        if     ($OrphansOnly) { if ($isOrphan)  { $targets += $s.Name } }
        elseif ($Stopped)     { if ($isStopped) { $targets += $s.Name } }
        else                  { if ($isOrphan -or $isStopped) { $targets += $s.Name } }
    }
}

if ($targets.Count -eq 0) { Write-Success "Nothing to clean."; exit 0 }

Write-Info "Will remove $($targets.Count) sandbox(es) and their Codex SSH aliases:"
$targets | ForEach-Object { Write-Hint $_ }

if ($DryRun) { Write-Info "[dry-run] no changes made."; exit 0 }

if (-not $Yes) {
    $ans = Read-Host "Proceed? [y/N]"
    if ($ans -notmatch '^(y|yes)$') { Write-Info "Aborted."; exit 0 }
}

foreach ($t in $targets) {
    & sbx rm $t 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Remove-CodexSshAlias $t; Write-Success "removed $t (+ SSH alias)" }
    else { Write-ErrMsg "failed to remove $t" }
}
