# One-time Windows setup for the optional Yapfast Go Live media-only shortcut.
# Installs official Yapfast and WireSock CLI releases, then downloads the
# reviewed launcher/shortcut scripts from the PLNastalli/yapfast feature branch.
[CmdletBinding()]
param(
    [string] $Destination,
    [switch] $SkipAppInstall,
    [switch] $SkipWireSockInstall
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') { throw 'Windows 10/11 only.' }
if (-not $Destination) {
    # A second disk isn't universal, so prefer E: when available, otherwise
    # fall back to the current user's Downloads directory.
    $Destination = if (Test-Path 'E:\' -PathType Container) {
        'E:\YapFast GoLive'
    } else {
        Join-Path $env:USERPROFILE 'Downloads\YapFast-GoLive'
    }
}
$dir = [System.IO.Path]::GetFullPath($Destination)
New-Item -Path $dir -ItemType Directory -Force | Out-Null
Write-Host "Yapfast Go Live setup directory: $dir"

function Download([string] $uri, [string] $path) {
    Write-Host "Downloading $([System.IO.Path]::GetFileName($path))..."
    Invoke-WebRequest -Uri $uri -OutFile $path -UseBasicParsing
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Download failed: $uri"
    }
}

$branchRoot = 'https://raw.githubusercontent.com/PLNastalli/yapfast/feat/golive-wiresock-windows/scripts'
$launcher = Join-Path $dir 'start.ps1'
$shortcutInstaller = Join-Path $dir 'setup.ps1'
Download "$branchRoot/launch-golive-wiresock.ps1" $launcher
Download "$branchRoot/install-golive-default-shortcut.ps1" $shortcutInstaller

$app = Join-Path $env:LOCALAPPDATA 'Programs\Yapfast\yapfast.exe'
if (-not $SkipAppInstall -and -not (Test-Path -LiteralPath $app -PathType Leaf)) {
    Write-Host 'Checking the latest official Yapfast Windows release...'
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/yapfast/yapfast/releases/latest' -Headers @{ 'User-Agent' = 'YapfastGoLiveSetup' }
    $asset = @($release.assets | Where-Object { $_.name -match '^Yapfast-.*-windows-x64-setup\.exe$' } | Select-Object -First 1)
    if ($asset.Count -ne 1) { throw 'No official Windows x64 installer was found in the latest Yapfast release.' }
    $installerPath = Join-Path $dir $asset[0].name
    Download $asset[0].browser_download_url $installerPath
    Write-Host 'Starting the official Yapfast installer; complete its setup wizard.'
    $installerProcess = Start-Process -FilePath $installerPath -PassThru -Wait
    if ($installerProcess.ExitCode -ne 0) {
        Write-Warning "Yapfast installer exited with code $($installerProcess.ExitCode)."
    }
}

if (-not $SkipWireSockInstall) {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        Write-Warning 'WinGet is not available; install the official WireSock CLI manually from wiresock.net.'
    } else {
        Write-Host 'Installing the official WireSock Secure Connect CLI via WinGet...'
        & winget.exe install --id NTKERNEL.WireSockVPNClientCLI --exact --source winget --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "WireSock CLI installation returned exit code $LASTEXITCODE. You may need to run WinGet as administrator or repair the driver."
        }
    }
}

$vpnConfig = Join-Path $dir 'vpn.conf'
if (-not (Test-Path -LiteralPath $vpnConfig -PathType Leaf)) {
    Write-Host ''
    Write-Host 'You still need your OWN WireGuard VPN profile (.conf).'
    Write-Host 'Get it from your VPN provider; do not use another person''s private key.'
    $source = Read-Host 'Full path to your WireGuard .conf (Enter to skip for now)'
    $source = $source.Trim().Trim('"')
    if ($source) {
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Profile not found: $source"
        }
        Copy-Item -LiteralPath $source -Destination $vpnConfig -ErrorAction Stop
    }
}

if (-not (Test-Path -LiteralPath $app -PathType Leaf)) {
    Write-Warning 'Yapfast is not installed at the standard path. Install it, then run setup.ps1 with -YapfastExe if your install path differs.'
} elseif (-not (Test-Path -LiteralPath $vpnConfig -PathType Leaf)) {
    Write-Host ''
    Write-Host "Download complete. Place your own WireGuard config at $vpnConfig"
    Write-Host "Then run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""$shortcutInstaller"" -Launcher ""$launcher"" -WireGuardConfig ""$vpnConfig"" -ReplaceStartMenuShortcut"
} else {
    Write-Host 'Creating the default Yapfast GoLive shortcut...'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $shortcutInstaller -Launcher $launcher -WireGuardConfig $vpnConfig -YapfastExe $app -ReplaceStartMenuShortcut
    if ($LASTEXITCODE -ne 0) {
        throw 'Shortcut setup failed. Check the paths and permissions printed above.'
    }
}
Write-Host ''
Write-Host 'Setup finished. Start Yapfast GoLive from the Desktop or Start Menu.'
Write-Host 'Note: media-only routing does not guarantee Discord will permit official Go Live in your region.'
