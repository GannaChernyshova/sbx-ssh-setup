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
if ($LASTEXITCODE -ne 0) {
    Write-Host "X Failed to remove '$Name' (sbx exit code $LASTEXITCODE)." -ForegroundColor Red
    exit $LASTEXITCODE
}
Write-Host "OK Removed '$Name'."

# Remove the concrete SSH alias the setup script added for Codex discovery.
# Match the setup script: Windows OpenSSH reads %USERPROFILE%\.ssh\config.
$sshHome   = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$sshConfig = Join-Path (Join-Path $sshHome ".ssh") "config"
$sbxHost   = "$Name.sbx"
$beginMark = "# >>> sbx-codex $sbxHost >>>"
$endMark   = "# <<< sbx-codex $sbxHost <<<"
if (Test-Path $sshConfig) {
    $lines = @(Get-Content -LiteralPath $sshConfig)
    if ($lines -contains $beginMark) {
        $filtered = New-Object System.Collections.Generic.List[string]
        $skip = $false
        foreach ($line in $lines) {
            if ($line -eq $beginMark) { $skip = $true; continue }
            if ($line -eq $endMark)   { $skip = $false; continue }
            if (-not $skip) { $filtered.Add($line) }
        }
        Set-Content -LiteralPath $sshConfig -Value $filtered -Encoding ascii
        Write-Host "OK Removed Codex SSH alias '$sbxHost' from ~/.ssh/config."
    }
}
