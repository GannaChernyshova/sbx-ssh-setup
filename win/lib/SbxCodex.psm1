# SbxCodex.psm1 — shared helpers for the Windows (PowerShell) sbx-codex toolkit.
#
# Mirrors the bash lib/ (common.sh + sbx-interface.sh + codex.sh). Imported by
# every win/*.ps1 command. PowerShell 5.1+ compatible.

Set-StrictMode -Version Latest

# --- Configurable interface (env overrides, like the bash SBX_* vars) --------
$script:SbxBin        = if ($env:SBX_BIN) { $env:SBX_BIN } else { 'sbx' }
$script:SshBin        = if ($env:SSH_BIN) { $env:SSH_BIN } else { 'ssh' }
$script:SbxMinVersion = if ($env:SBX_MIN_VERSION) { $env:SBX_MIN_VERSION } else { '0.35.0' }
$script:DefaultAgent  = if ($env:SBX_DEFAULT_AGENT) { $env:SBX_DEFAULT_AGENT } else { 'codex' }
$script:SshSuffix     = if ($env:SBX_SSH_SUFFIX) { $env:SBX_SSH_SUFFIX } else { '.sbx' }
$script:MountMirrors  = if ($env:SBX_MOUNT_MIRRORS_HOST) { $env:SBX_MOUNT_MIRRORS_HOST } else { '1' }
$script:FallbackWs    = if ($env:SBX_FALLBACK_CONTAINER_WS) { $env:SBX_FALLBACK_CONTAINER_WS } else { '/home/agent/workspace' }
$script:RunDetachFlag = if ($env:SBX_RUN_DETACH_FLAG) { $env:SBX_RUN_DETACH_FLAG } else { '--detached' }
$script:OpenAiSecret  = if ($env:SBX_OPENAI_SECRET) { $env:SBX_OPENAI_SECRET } else { 'openai' }
$script:FeaturesFlag  = if ($env:SBX_FEATURES_FLAG) { $env:SBX_FEATURES_FLAG } else { (Join-Path $HOME '.sbx_features_enabled') }
$script:SshConfigFile = if ($env:SSH_CONFIG_FILE) { $env:SSH_CONFIG_FILE } else { (Join-Path $HOME '.ssh\config') }

$script:CodexBegin = '# >>> sbx-codex managed (do not edit inside this region) >>>'
$script:CodexEnd   = '# <<< sbx-codex managed <<<'

function Get-SbxDefaultAgent { $script:DefaultAgent }
function Get-SbxSshSuffix     { $script:SshSuffix }
function Get-SbxOpenAiSecret  { $script:OpenAiSecret }
function Get-SbxMinVersion    { $script:SbxMinVersion }
function Get-SshConfigFile    { $script:SshConfigFile }

# --- Output helpers (all to the host / stderr, never to the pipeline) --------
function Write-Info    { param([string]$m) Write-Host "* $m" -ForegroundColor Blue }
function Write-Success { param([string]$m) Write-Host "OK $m" -ForegroundColor Green }
function Write-WarnMsg { param([string]$m) Write-Host "!  $m" -ForegroundColor Yellow }
function Write-ErrMsg  { param([string]$m) Write-Host "X  $m" -ForegroundColor Red }
function Write-Hint    { param([string]$m) Write-Host "     $m" -ForegroundColor DarkGray }
function Write-Cmd     { param([string]$m) Write-Host "     > $m" -ForegroundColor Cyan }
function Stop-WithError { param([string]$m) Write-ErrMsg $m; exit 1 }

# --- Small utilities ---------------------------------------------------------
function Test-Command { param([string]$Name) $null -ne (Get-Command $Name -ErrorAction SilentlyContinue) }

function Get-ToolkitVersion {
    if ($env:SBX_CODEX_VERSION) { return $env:SBX_CODEX_VERSION }
    foreach ($p in @((Join-Path $PSScriptRoot 'VERSION'), (Join-Path $PSScriptRoot '..\VERSION'), (Join-Path $PSScriptRoot '..\..\VERSION'))) {
        if (Test-Path $p) { return (Get-Content $p -Raw).Trim() }
    }
    return 'unknown'
}

function ConvertTo-SbxName {
    param([string]$Raw)
    $out = $Raw.ToLower()
    $out = ($out -replace '[^a-z0-9]', '-')
    $out = ($out -replace '-{2,}', '-')
    $out = ($out -replace '^-', '') -replace '-$', ''
    if ([string]::IsNullOrEmpty($out)) { $out = 'sandbox' }
    return $out
}

function Test-VersionGe {
    param([string]$A, [string]$B)
    $ra = [regex]::Match($A, '[0-9]+(\.[0-9]+)*'); $rb = [regex]::Match($B, '[0-9]+(\.[0-9]+)*')
    if (-not $ra.Success -or -not $rb.Success) { return $false }
    $va = $ra.Value.Split('.') | ForEach-Object { [int]$_ }
    $vb = $rb.Value.Split('.') | ForEach-Object { [int]$_ }
    for ($i = 0; $i -lt $vb.Count; $i++) {
        $ai = if ($i -lt $va.Count) { $va[$i] } else { 0 }
        if ($ai -gt $vb[$i]) { return $true }
        if ($ai -lt $vb[$i]) { return $false }
    }
    return $true
}

function Copy-ToClipboard {
    param([string]$Text)
    try { Set-Clipboard -Value $Text -ErrorAction Stop; return $true } catch { return $false }
}

# --- sbx CLI -----------------------------------------------------------------
function Test-SbxPresent { Test-Command $script:SbxBin }

function Get-SbxVersion {
    if (-not (Test-SbxPresent)) { return $null }
    $raw = (& $script:SbxBin version 2>$null); if (-not $raw) { $raw = (& $script:SbxBin --version 2>$null) }
    $m = [regex]::Match(($raw -join ' '), '[0-9]+(\.[0-9]+)+')
    if ($m.Success) { return $m.Value } else { return $null }
}

# Parse `sbx ls` into objects using header column offsets (PORTS is often empty,
# so naive whitespace-splitting would misalign rows).
function Get-SbxList {
    if (-not (Test-SbxPresent)) { return @() }
    $lines = @(& $script:SbxBin ls 2>$null)
    if ($lines.Count -lt 1) { return @() }
    $header = $lines[0]
    $cols = @{}
    foreach ($name in 'SANDBOX','NAME','AGENT','TEMPLATE','STATUS','STATE','WORKSPACE','PATH','FOLDER','DIR') {
        $idx = $header.IndexOf($name)
        if ($idx -ge 0) { $cols[$name] = $idx }
    }
    function Val([string]$line, [int]$start, [int]$end) {
        if ($start -lt 0 -or $start -ge $line.Length) { return '' }
        if ($end -lt 0 -or $end -gt $line.Length) { $end = $line.Length }
        return $line.Substring($start, $end - $start).Trim()
    }
    $ni = if ($cols.ContainsKey('SANDBOX')) { $cols['SANDBOX'] } elseif ($cols.ContainsKey('NAME')) { $cols['NAME'] } else { 0 }
    $ai = if ($cols.ContainsKey('AGENT')) { $cols['AGENT'] } elseif ($cols.ContainsKey('TEMPLATE')) { $cols['TEMPLATE'] } else { -1 }
    $si = if ($cols.ContainsKey('STATUS')) { $cols['STATUS'] } elseif ($cols.ContainsKey('STATE')) { $cols['STATE'] } else { -1 }
    $wi = if ($cols.ContainsKey('WORKSPACE')) { $cols['WORKSPACE'] } elseif ($cols.ContainsKey('PATH')) { $cols['PATH'] } elseif ($cols.ContainsKey('FOLDER')) { $cols['FOLDER'] } else { -1 }
    # Ordered boundaries for substring extraction.
    $bounds = @($ni, $ai, $si, $wi) | Where-Object { $_ -ge 0 } | Sort-Object
    function NextBound([int]$start) {
        foreach ($b in $bounds) { if ($b -gt $start) { return $b } }
        return -1
    }
    $result = @()
    if ($lines.Count -lt 2) { return $result }
    foreach ($line in $lines[1..($lines.Count-1)]) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $name = Val $line $ni (NextBound $ni)
        if ([string]::IsNullOrEmpty($name)) { continue }
        $agent  = if ($ai -ge 0) { Val $line $ai (NextBound $ai) } else { '' }
        $status = if ($si -ge 0) { Val $line $si (NextBound $si) } else { '' }
        $ws     = if ($wi -ge 0) { Val $line $wi (NextBound $wi) } else { '' }
        if ($ws -eq '-') { $ws = '' }
        $result += [pscustomobject]@{ Name = $name; Agent = $agent; Status = $status; Workspace = $ws }
    }
    return $result
}

function Get-Sbx        { param([string]$Name) Get-SbxList | Where-Object { $_.Name -eq $Name } | Select-Object -First 1 }
function Test-SbxExists  { param([string]$Name) $null -ne (Get-Sbx $Name) }
function Get-SbxStatus   { param([string]$Name) (Get-Sbx $Name).Status }
function Get-SbxWorkspace{ param([string]$Name) $s = Get-Sbx $Name; if ($s) { $s.Workspace } else { '' } }

function Test-SbxFeaturesEnabled { Test-Path $script:FeaturesFlag }

function Enable-SbxSshFeature {
    & $script:SbxBin settings set platform.allowExperimentalFeatures true | Out-Null
    & $script:SbxBin settings set feature.ssh true | Out-Null
    & $script:SbxBin daemon stop  2>$null | Out-Null
    & $script:SbxBin daemon start -d | Out-Null
    & $script:SbxBin ssh setup | Out-Null
    New-Item -ItemType File -Path $script:FeaturesFlag -Force | Out-Null
}

function Get-SbxSshSetupSteps {
    @(
        "$($script:SbxBin) settings set platform.allowExperimentalFeatures true",
        "$($script:SbxBin) settings set feature.ssh true",
        "$($script:SbxBin) daemon stop && $($script:SbxBin) daemon start -d",
        "$($script:SbxBin) ssh setup"
    )
}

function Test-OpenAiSecret {
    if (-not (Test-SbxPresent)) { return $false }
    $out = (& $script:SbxBin secret ls 2>$null) -join "`n"
    return ($out -match "(?im)\b$([regex]::Escape($script:OpenAiSecret))\b")
}

function Invoke-SbxRunDetached {
    param([string[]]$SbxArgs)
    & $script:SbxBin run $script:RunDetachFlag @SbxArgs 2>$null | Out-Null
}

function Confirm-SbxRunning {
    param([string]$Agent, [string]$Name, [string]$Path)
    if (Test-SbxExists $Name) {
        if ((Get-SbxStatus $Name) -eq 'running') { return }
        Invoke-SbxRunDetached @('--name', $Name)   # wake
        return
    }
    Invoke-SbxRunDetached @($Agent, '--name', $Name, $Path)
}

function Get-SshHost { param([string]$Name) "$Name$($script:SshSuffix)" }

function Test-SshReachable {
    param([string]$Name)
    if (-not (Test-Command $script:SshBin)) { return $false }
    & $script:SshBin -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new (Get-SshHost $Name) true 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-ContainerWsPath {
    param([string]$Name, [string]$HostWs)
    if ($script:MountMirrors -eq '1' -and $HostWs) {
        if (Test-SshReachable $Name) {
            & $script:SshBin -o BatchMode=yes (Get-SshHost $Name) "test -d '$HostWs'" 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { return $HostWs }
        }
    }
    $probed = (& $script:SbxBin exec $Name -- pwd 2>$null | Select-Object -Last 1)
    if ($probed -and $probed.StartsWith('/')) { return $probed.Trim() }
    if ($HostWs) { return $HostWs } else { return $script:FallbackWs }
}

# --- Managed SSH config region (concrete aliases Codex auto-discovers) --------
function Get-CodexRegionNames {
    if (-not (Test-Path $script:SshConfigFile)) { return @() }
    $names = @(); $inreg = $false
    foreach ($line in Get-Content $script:SshConfigFile) {
        if ($line -eq $script:CodexBegin) { $inreg = $true; continue }
        if ($line -eq $script:CodexEnd)   { $inreg = $false; continue }
        if ($inreg -and $line -match '^\s*# sbx-codex:\s*(.+)$') { $names += $Matches[1].Trim() }
    }
    return $names
}

function Write-CodexRegion {
    param([string[]]$Names)
    $dir = Split-Path -Parent $script:SshConfigFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # Preserve everything outside our managed region (a List avoids the PowerShell
    # `0..-1` range pitfall when trimming a single-element array).
    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path $script:SshConfigFile) {
        $inreg = $false
        foreach ($line in Get-Content $script:SshConfigFile) {
            if ($line -eq $script:CodexBegin) { $inreg = $true; continue }
            if ($line -eq $script:CodexEnd)   { $inreg = $false; continue }
            if (-not $inreg) { $lines.Add($line) }
        }
    }
    while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count-1])) {
        $lines.RemoveAt($lines.Count-1)
    }

    $uniq = @($Names | Sort-Object -Unique | Where-Object { $_ })
    if ($uniq.Count -gt 0) {
        if ($lines.Count -gt 0) { $lines.Add('') }
        $lines.Add($script:CodexBegin)
        foreach ($n in $uniq) {
            $lines.Add("Host $n$($script:SshSuffix)")
            $lines.Add("    # sbx-codex: $n")
            $lines.Add("    HostName $n$($script:SshSuffix)")
        }
        $lines.Add($script:CodexEnd)
    }
    Set-Content -Path $script:SshConfigFile -Value $lines.ToArray() -Encoding ascii
}

function Test-CodexSshAlias { param([string]$Name) (Get-CodexRegionNames) -contains $Name }

function Add-CodexSshAlias {
    param([string]$Name)
    $names = @(Get-CodexRegionNames) + $Name
    Write-CodexRegion -Names $names
}

function Remove-CodexSshAlias {
    param([string]$Name)
    $names = @(Get-CodexRegionNames | Where-Object { $_ -ne $Name })
    Write-CodexRegion -Names $names
}

# --- Codex desktop app -------------------------------------------------------
function Get-CodexAppPath {
    $candidates = @()
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\Codex\Codex.exe')
        $candidates += (Join-Path $env:LOCALAPPDATA 'Codex\Codex.exe')
    }
    if (${env:ProgramFiles}) { $candidates += (Join-Path ${env:ProgramFiles} 'Codex\Codex.exe') }
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

function Test-CodexApp {
    if (Get-CodexAppPath) { return $true }
    return (Test-Command 'codex')
}

function Start-CodexApp {
    if ($env:CODEX_LAUNCH_OVERRIDE) { Invoke-Expression $env:CODEX_LAUNCH_OVERRIDE; return $true }
    $exe = Get-CodexAppPath
    try {
        if ($exe) { Start-Process -FilePath $exe | Out-Null; return $true }
        Start-Process 'codex:' | Out-Null; return $true      # try URI handler
    } catch { return $false }
}

Export-ModuleMember -Function *
