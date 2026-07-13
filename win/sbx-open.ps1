<#
.SYNOPSIS
  sbx-open — open a project in the Codex desktop app, isolated in a Docker Sandbox.
.DESCRIPTION
  Creates (or reuses) exactly one Docker Sandbox for a project directory, makes
  the Codex GUI auto-discover it over SSH, launches the app, and hands you the
  exact values for the one remaining supported click. Idempotent.
.EXAMPLE
  sbx-open ~\src\acme-api
.EXAMPLE
  sbx-open codex ~\src\acme-api
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $First,
    [Parameter(Position = 1)] [string] $Second,
    [string] $Name,
    [switch] $NoLaunch,
    [switch] $DryRun,
    [switch] $Version,
    [switch] $Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\SbxCodex.psm1') -Force

if ($Help)    { Get-Help $MyInvocation.MyCommand.Path -Detailed; exit 0 }
if ($Version) { "sbx-open $(Get-ToolkitVersion)"; exit 0 }

# Resolve which positional is the agent and which is the path:
#   sbx-open <path>            -> agent defaults to codex
#   sbx-open codex <path>      -> agent explicit
$agent = Get-SbxDefaultAgent
$pathArg = $null
if ($First -and $Second) { $agent = $First; $pathArg = $Second }
elseif ($First)          { $pathArg = $First }

if (-not $pathArg) { Get-Help $MyInvocation.MyCommand.Path; exit 2 }

# --- preflight ---------------------------------------------------------------
if (-not (Test-SbxPresent)) { Stop-WithError "'sbx' not found on PATH. Install the sbx CLI, then run: sbx-doctor" }
$v = Get-SbxVersion
if ($v -and -not (Test-VersionGe $v (Get-SbxMinVersion))) {
    Stop-WithError "sbx $v is older than required $(Get-SbxMinVersion) — update Docker Sandboxes."
}
if (Test-Command 'docker') {
    & docker info 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-WithError "Docker is installed but not running. Start Docker Desktop and re-run." }
}

$ws = (Resolve-Path -LiteralPath $pathArg -ErrorAction SilentlyContinue)
if (-not $ws) { Stop-WithError "not a directory: $pathArg" }
$ws = $ws.Path
if (-not (Test-Path -LiteralPath $ws -PathType Container)) { Stop-WithError "not a directory: $ws" }
if ($ws -eq $HOME) { Stop-WithError "refusing to mount your entire home directory ($HOME). Mount a specific project." }

# --- name derivation + collision handling ------------------------------------
$nameExplicit = [bool]$Name
if ($Name) { $sbxName = ConvertTo-SbxName $Name }
else       { $sbxName = ConvertTo-SbxName (Split-Path -Leaf $ws) }

function Resolve-Name {
    param([string]$Base)
    $n = $Base; $i = 1
    while (Test-SbxExists $n) {
        $existingWs = Get-SbxWorkspace $n
        if     ([string]::IsNullOrEmpty($existingWs)) { $cls = 'orphan' }
        elseif ($existingWs -eq $ws)                  { return $n }        # reuse
        else                                          { $cls = 'mismatch' }
        if ($nameExplicit) {
            if ($cls -eq 'orphan') {
                Write-ErrMsg "Sandbox '$n' exists but has NO workspace mount (orphan)."
                Write-Cmd "sbx-clean"; Write-Cmd "sbx rm $n"
            } else {
                Write-ErrMsg "Sandbox '$n' already exists for a DIFFERENT workspace: $existingWs"
            }
            exit 1
        }
        $i++; $n = "$Base-$i"
    }
    return $n
}
$sbxName = Resolve-Name $sbxName
$sshHost = Get-SshHost $sbxName

Write-Host ''
Write-Info "Project : $ws"
Write-Info "Sandbox : $sbxName   (agent: $agent, host: $sshHost)"

# --- one-time SSH enablement -------------------------------------------------
if (-not (Test-SbxFeaturesEnabled)) {
    if ($DryRun) {
        Write-Info "[dry-run] would enable the SSH feature (one-time):"
        Get-SbxSshSetupSteps | ForEach-Object { Write-Cmd $_ }
    } else {
        Write-Info "First-time setup: enabling the sbx SSH feature (one-time, ~20s)…"
        Enable-SbxSshFeature
        Write-Success "SSH feature enabled."
    }
}

# --- OpenAI credentials ------------------------------------------------------
if (-not $DryRun -and -not (Test-OpenAiSecret)) {
    Write-WarnMsg "No global '$(Get-SbxOpenAiSecret)' secret found — Codex needs OpenAI credentials inside the sandbox."
    Write-Cmd "sbx secret set -g $(Get-SbxOpenAiSecret) --oauth"
    Write-Hint "Do this now in another terminal, then re-run. Continuing anyway…"
}

# --- create or reuse ---------------------------------------------------------
$created = $false
if (Test-SbxExists $sbxName) {
    if ((Get-SbxStatus $sbxName) -ne 'running') {
        if ($DryRun) { Write-Info "[dry-run] would wake stopped sandbox '$sbxName'" }
        else { Write-Info "Waking stopped sandbox (detached)…"; Confirm-SbxRunning '' $sbxName '' }
    } else { Write-Info "Reusing running sandbox." }
} else {
    if ($DryRun) { Write-Info "[dry-run] would create (detached): sbx run --detached $agent --name $sbxName $ws" }
    else { Write-Info "Creating sandbox (detached)…"; Confirm-SbxRunning $agent $sbxName $ws; $created = $true }
}

# --- SSH reachability --------------------------------------------------------
if ($DryRun) {
    Write-Info "[dry-run] would verify SSH: ssh $sshHost"
} else {
    if (-not (Test-SshReachable $sbxName)) {
        Write-ErrMsg "Sandbox '$sbxName' is not reachable over SSH ($sshHost)."
        Write-Hint "It may still be starting — wait a few seconds and retry, or run: sbx-doctor"
        exit 1
    }
    Write-Success "SSH reachable: $sshHost"
}

# --- make Codex auto-discover the host ---------------------------------------
if ($DryRun) {
    Write-Info "[dry-run] would add a concrete Host alias for '$sshHost' to $(Get-SshConfigFile)"
} else {
    Add-CodexSshAlias $sbxName
    Write-Success "Codex will now auto-discover this host ($sshHost)."
}

# --- resolve in-container folder path ----------------------------------------
if ($DryRun) { $cpath = $ws } else { $cpath = Get-ContainerWsPath $sbxName $ws }

# --- launch Codex + hand off the final supported click -----------------------
$launchNote = 'the Codex desktop app'
if (-not $NoLaunch -and -not $DryRun) {
    if (Test-CodexApp) {
        if (-not (Start-CodexApp)) { Write-WarnMsg "Could not auto-launch Codex — open it yourself." }
    } else {
        Write-WarnMsg "Codex desktop app not detected — install it, then open it yourself."
        $launchNote = 'Codex (once installed)'
    }
}

$clipNote = ''
if (-not $DryRun -and (Copy-ToClipboard $cpath)) { $clipNote = '   (copied to clipboard)' }

Write-Host ''
Write-Success "Sandbox '$sbxName' is ready."
Write-Host ''
Write-Host "Last step in $launchNote — New remote project:"
Write-Host "   1. Pick the host from the list:   $sshHost"
Write-Host "   2. Choose the project folder:     $cpath$clipNote"
Write-Host "   3. Click Add project and start working."
Write-Host ''
Write-Host "Screenshots for these clicks: docs\codex.md"

if (-not $DryRun -and $created) { Write-Success "New sandbox '$sbxName' created." }
