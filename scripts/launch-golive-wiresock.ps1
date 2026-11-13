# Optional Windows launcher for official Discord Go Live through WireSock.
# Requires WireSock Secure Connect plus a WireGuard profile supplied by the user.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $WireGuardConfig,
    [string] $YapfastExe,
    [string] $WireSockExe,
    [switch] $CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'This launcher supports Windows only.'
}

function Find-Executable {
    param([string] $Name, [string] $ExplicitPath, [string[]] $Candidates)
    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) {
            throw "$Name was not found: $ExplicitPath"
        }
        return (Resolve-Path -LiteralPath $ExplicitPath).ProviderPath
    }
    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).ProviderPath
        }
    }
    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    throw "Could not find $Name. Install it or pass its full path explicitly."
}

$configFile = (Resolve-Path -LiteralPath $WireGuardConfig -ErrorAction Stop).ProviderPath
if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
    throw 'The WireGuard profile must be a file.'
}
$yapfast = Find-Executable -Name 'yapfast.exe' -ExplicitPath $YapfastExe -Candidates @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Yapfast\yapfast.exe'),
    (Join-Path $PSScriptRoot '..\target\release\yapfast.exe'),
    (Join-Path $PSScriptRoot '..\target\debug\yapfast.exe')
)
# WireSock installs its CLI in a "bin" subdirectory on many versions.
# Check both 64-bit and 32-bit Program Files and preserve the older layouts.
$wireSockCandidates = @()
$programRoots = @($env:ProgramFiles, [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) |
    Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } |
    Select-Object -Unique
foreach ($root in $programRoots) {
    foreach ($folder in @('WireSock Secure Connect', 'WireSock VPN Client', 'WireSock')) {
        foreach ($subpath in @('bin\wiresock-client.exe', 'wiresock-client.exe')) {
            $wireSockCandidates += Join-Path $root (Join-Path $folder $subpath)
        }
    }
}
$wiresock = Find-Executable -Name 'wiresock-client.exe' -ExplicitPath $WireSockExe -Candidates $wireSockCandidates

# Do not execute arbitrary profile hooks. Single-peer full-tunnel profiles only.
$original = [System.IO.File]::ReadAllText($configFile)
$peerCount = [regex]::Matches($original, '(?im)^[ \t]*\[Peer\][ \t]*\r?$').Count
if ($original -notmatch '(?im)^[ \t]*\[Interface\][ \t]*\r?$' -or $peerCount -ne 1) {
    throw 'Expected [Interface] and exactly one [Peer] section.'
}
if ($original -match '(?im)^[ \t]*(PreUp|PostUp|PreDown|PostDown)[ \t]*=') {
    throw 'WireGuard profiles with executable hooks are not accepted.'
}
if ($original -notmatch '(?im)^[ \t]*AllowedIPs[ \t]*=[^\r\n]*0\.0\.0\.0/0([ \t,\r\n]|$)') {
    throw 'Expected AllowedIPs to contain 0.0.0.0/0 in the peer.'
}
foreach ($header in [regex]::Matches($original, '(?im)^[ \t]*\[([^\]\r\n]+)\][ \t]*\r?$')) {
    if ($header.Groups[1].Value -notin @('Interface', 'Peer')) {
        throw "Unsupported profile section: $($header.Groups[1].Value)"
    }
}

# Same executable hosts the main app and --stream-worker, so both use the
# route. Discard any previous app filters. Removing DNS avoids a system-wide
# DNS change. Existing WireGuard keys remain only in the temporary profile.
$lines = New-Object 'System.Collections.Generic.List[string]'
foreach ($line in ($original -split '\r?\n')) {
    if ($line -match '(?i)^[ \t]*(?:#@ws:)?(?:AllowedApps|DisallowedApps|DNS)[ \t]*=') { continue }
    $lines.Add($line)
}
$lines.Add("#@ws:AllowedApps = $yapfast")
$filteredProfile = $lines -join [Environment]::NewLine

Write-Host 'Yapfast official Go Live via WireSock'
Write-Host "  Yapfast: $yapfast"
Write-Host "  WireSock: $wiresock"
Write-Host '  Routing: only Yapfast (main process and stream worker).'
Write-Host '  Network lock: disabled. System-wide DNS: unchanged.'
if ($CheckOnly) {
    Write-Host 'Profile validation succeeded. Nothing was launched.'
    return
}

# The gateway must connect after the tunnel starts. Never modify or steal an
# existing WireSock session, and avoid reusing an untunneled Yapfast session.
if (Get-Process -Name 'yapfast' -ErrorAction SilentlyContinue) {
    throw 'Close Yapfast completely before using this launcher.'
}
if (Get-Process -Name 'wiresock-client' -ErrorAction SilentlyContinue) {
    throw 'A WireSock process is active already. Stop it first.'
}
$services = @(Get-Service -Name @('wiresock-client-service', 'wiresock-pro-client-service') -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' })
if ($services.Count -gt 0) {
    throw 'An existing WireSock service is active. Stop it first.'
}

$folder = Join-Path $env:LOCALAPPDATA 'Yapfast\GoLiveTunnel'
New-Item -ItemType Directory -Path $folder -Force | Out-Null
$temporaryProfile = Join-Path $folder ('wiresock-' + [guid]::NewGuid().ToString('N') + '.conf')
$vpnProcess = $null
$appProcess = $null
try {
    [System.IO.File]::WriteAllText($temporaryProfile, $filteredProfile, ([System.Text.UTF8Encoding]::new($false)))
    # WireGuard private keys should not be readable by other local users.
    $acl = Get-Acl -LiteralPath $temporaryProfile
    $acl.SetAccessRuleProtection($true, $false)
    $owner = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $system = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    foreach ($sid in @($owner, $system)) {
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow
        ))
    }
    Set-Acl -LiteralPath $temporaryProfile -AclObject $acl

    Write-Host 'Starting the VPN before opening Yapfast...'
    $arguments = @('run', '-config', ('"' + $temporaryProfile + '"'), '-log-level', 'error', '-network-lock', 'disabled')
    $vpnProcess = Start-Process -FilePath $wiresock -ArgumentList $arguments -WorkingDirectory (Split-Path -Path $wiresock -Parent) -PassThru
    Start-Sleep -Seconds 3
    $vpnProcess.Refresh()
    if ($vpnProcess.HasExited) {
        throw 'WireSock stopped during startup. Check its driver, profile and permissions.'
    }

    Write-Host 'Starting Yapfast (with the Discord gateway inside the tunnel)...'
    $appProcess = Start-Process -FilePath $yapfast -WorkingDirectory (Split-Path -Path $yapfast -Parent) -PassThru
    while ($true) {
        Start-Sleep -Seconds 1
        $appProcess.Refresh()
        $vpnProcess.Refresh()
        if ($appProcess.HasExited) { break }
        if ($vpnProcess.HasExited) {
            throw 'WireSock stopped unexpectedly. Closing Yapfast to avoid a silent direct reconnect.'
        }
    }
}
finally {
    if ($appProcess) {
        $appProcess.Refresh()
        if (-not $appProcess.HasExited) {
            Stop-Process -Id $appProcess.Id -Force -ErrorAction SilentlyContinue
        }
    }
    if ($vpnProcess) {
        $vpnProcess.Refresh()
        if (-not $vpnProcess.HasExited) {
            # Stop only the process launched here, not other VPN sessions.
            Stop-Process -Id $vpnProcess.Id -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path -LiteralPath $temporaryProfile) {
        Remove-Item -LiteralPath $temporaryProfile -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'The managed WireSock session was stopped.'
}
