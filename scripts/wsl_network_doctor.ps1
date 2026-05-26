# wsl_network_doctor.ps1 — diagnose & repair WSL2 mirrored networking for the browser tool.
#
# Designed to be invoked from inside WSL via:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File <win-path-to-this-script> <subcommand>
#
# Subcommands:
#   status   Check whether mirrored networking is configured.
#   enable   Write networkingMode=mirrored to %USERPROFILE%\.wslconfig.
#   repair   Restart Windows Host Network Service (HNS) via UAC elevation.
#
# Exit codes (status only):
#   0   OK              — mirrored configured, OR running on WSL1 (no config needed)
#   10  NEED_ENABLE     — mirrored not configured, run `enable`
#   20  NEED_REPAIR     — configured but suspected broken, run `repair`
#   1   unexpected error
#
# `enable` and `repair` exit 0 on success, 1 on failure.

param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'enable', 'repair')]
    [string]$Command
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-WslConfigPath {
    return (Join-Path $env:USERPROFILE '.wslconfig')
}

function Test-MirroredConfigured {
    $cfg = Get-WslConfigPath
    if (-not (Test-Path $cfg)) { return $false }
    $content = Get-Content $cfg -Raw -ErrorAction SilentlyContinue
    if ($null -eq $content) { return $false }
    return ($content -match '(?im)^\s*networkingMode\s*=\s*mirrored\s*$')
}

# Returns 1 or 2 if Ubuntu is registered, $null otherwise.
# Parses `wsl.exe -l -v` output (UTF-16, may contain a star marker on default distro).
function Get-UbuntuWslVersion {
    try {
        $raw = & wsl.exe -l -v 2>$null
    } catch {
        return $null
    }
    if (-not $raw) { return $null }

    foreach ($line in $raw) {
        $clean = ($line -replace '\s+', ' ').Trim().TrimStart('*').Trim()
        if ($clean -match '^Ubuntu(?:-[\w\.]+)?\s+\S+\s+(\d+)\s*$') {
            return [int]$matches[1]
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Subcommand: status
# ---------------------------------------------------------------------------

function Invoke-Status {
    $wslVer = Get-UbuntuWslVersion
    if ($wslVer -eq 1) {
        Write-Host "OK: Ubuntu is running on WSL1 — shares the Windows network stack directly."
        Write-Host "No mirrored configuration needed. The browser tool can connect to 127.0.0.1 as-is."
        exit 0
    }

    if (Test-MirroredConfigured) {
        Write-Host "OK: mirrored networking is configured in .wslconfig."
        Write-Host "If the browser tool still cannot connect, run: wsl_network_doctor.ps1 repair"
        exit 0
    }

    Write-Host "NEED_ENABLE: mirrored networking is not configured."
    Write-Host "Run: wsl_network_doctor.ps1 enable"
    exit 10
}

# ---------------------------------------------------------------------------
# Subcommand: enable
# ---------------------------------------------------------------------------

function Invoke-Enable {
    if (Test-MirroredConfigured) {
        Write-Host "OK: already enabled. No changes needed."
        Write-Host "If the browser tool still cannot connect, run: wsl_network_doctor.ps1 repair"
        exit 0
    }

    $cfg = Get-WslConfigPath
    Write-Host "Writing networkingMode=mirrored to $cfg ..."

    if (-not (Test-Path $cfg)) {
        New-Item -ItemType File -Path $cfg -Force | Out-Null
    }

    $content = Get-Content $cfg -Raw -ErrorAction SilentlyContinue
    if ($null -eq $content) { $content = '' }

    if ($content -match '(?im)^\s*networkingMode\s*=') {
        $new = [regex]::Replace($content, '(?im)^\s*networkingMode\s*=.*$', 'networkingMode=mirrored')
        Set-Content -Path $cfg -Value $new -NoNewline
    } else {
        if ($content -notmatch '(?im)^\[wsl2\]') {
            if ($content.Length -gt 0 -and -not $content.EndsWith([char]10)) {
                Add-Content -Path $cfg -Value ''
            }
            Add-Content -Path $cfg -Value '[wsl2]'
        }
        Add-Content -Path $cfg -Value 'networkingMode=mirrored'
    }

    Write-Host "WROTE: .wslconfig updated."
    Write-Host ""
    Write-Host "Next step (cannot be done from inside WSL):"
    Write-Host "  1. Open Windows PowerShell"
    Write-Host "  2. Run: wsl --shutdown"
    Write-Host "  3. Reopen Clacky and run /browser-setup again"
    exit 0
}

# ---------------------------------------------------------------------------
# Subcommand: repair
# ---------------------------------------------------------------------------
# Restart Windows Host Network Service (HNS). Requires admin → triggers UAC.
# Does NOT call `wsl --shutdown` here — the user must run it manually after
# the elevated window finishes, otherwise our own WSL session would be killed.

function Invoke-Repair {
    Write-Host "Repairing Windows Host Network Service (HNS) ..."
    Write-Host ""
    Write-Host "A Windows User Account Control (UAC) dialog will appear."
    Write-Host "Please click 'Yes' to allow the repair script to run."
    Write-Host ""

    $inner = @'
try {
    Stop-Service hns -Force -ErrorAction SilentlyContinue
    Start-Service hns -ErrorAction Stop
    Write-Host "HNS restarted successfully."
} catch {
    Write-Host "Repair failed: $_"
    Start-Sleep 5
    exit 1
}
Write-Host ""
Write-Host "Repair complete. Please run 'wsl --shutdown' in PowerShell, then reopen Clacky."
Start-Sleep 4
'@

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))

    try {
        Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile', '-EncodedCommand', $encoded
    } catch {
        Write-Host "FAILED: could not trigger UAC prompt: $_"
        Write-Host ""
        Write-Host "You can run the repair manually:"
        Write-Host "  1. Open PowerShell as Administrator"
        Write-Host "  2. Run: net stop hns; net start hns"
        Write-Host "  3. Run: wsl --shutdown"
        Write-Host "  4. Reopen Clacky"
        exit 1
    }

    Write-Host "Repair script launched in an elevated PowerShell window."
    Write-Host ""
    Write-Host "After the elevated window finishes:"
    Write-Host "  1. Run in regular PowerShell: wsl --shutdown"
    Write-Host "  2. Reopen Clacky and run /browser-setup again"
    exit 0
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

switch ($Command) {
    'status' { Invoke-Status }
    'enable' { Invoke-Enable }
    'repair' { Invoke-Repair }
    default {
        Write-Host "Usage: wsl_network_doctor.ps1 {status|enable|repair}"
        Write-Host ""
        Write-Host "  status  Check whether WSL2 mirrored networking is configured."
        Write-Host "  enable  Write networkingMode=mirrored to %USERPROFILE%\.wslconfig."
        Write-Host "  repair  Restart Windows Host Network Service (HNS) via UAC."
        exit 2
    }
}
