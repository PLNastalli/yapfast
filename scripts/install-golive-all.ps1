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
if (-not $SkipAppInstall) {
    # /releases/latest excludes prereleases: enumerate ALL releases so betas
    # and nightlies are considered. Pick the latest published Windows x64
    # release with a downloadable portable ZIP or normal installer.
    Write-Host 'Checking official Yapfast releases (including beta/nightly)...'
    $releases = @(Invoke-RestMethod -Uri 'https://api.github.com/repos/yapfast/yapfast/releases?per_page=100' -Headers @{ 'User-Agent' = 'YapfastGoLiveSetup' })
    $chosenRelease = $null
    $chosenAsset = $null
    foreach ($candidate in @($releases | Where-Object { -not $_.draft } | Sort-Object -Property published_at -Descending)) {
        $windowsZip = @($candidate.assets | Where-Object { $_.name -match '^Yapfast-.*-windows-x64\.zip$' } | Select-Object -First 1)
        $windowsSetup = @($candidate.assets | Where-Object { $_.name -match '^Yapfast-.*-windows-x64-setup\.exe$' } | Select-Object -First 1)
        if ($windowsSetup.Count -gt 0 -or $windowsZip.Count -gt 0) {
            $chosenRelease = $candidate
            # Prefer the standard installer when this SAME release offers one.
            $chosenAsset = if ($windowsSetup.Count -gt 0) { $windowsSetup[0] } else { $windowsZip[0] }
            break
        }
    }
    if (-not $chosenRelease -or -not $chosenAsset) {
        throw 'No Windows x64 asset found in the official Yapfast releases.'
    }
    Write-Host "Selected Yapfast $($chosenRelease.tag_name) (prerelease: $($chosenRelease.prerelease))."
    $package = Join-Path $dir $chosenAsset.name
    Download $chosenAsset.browser_download_url $package

    # Every official package advertises its SHA-256 in SHA256SUMS.txt.
    $sumsAsset = @($chosenRelease.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1)
    if ($sumsAsset.Count -ne 1) { throw 'The selected release has no SHA256SUMS.txt.' }
    $sumsFile = Join-Path $dir 'SHA256SUMS.txt'
    Download $sumsAsset[0].browser_download_url $sumsFile
    $escapedName = [regex]::Escape($chosenAsset.name)
    $checksums = [regex]::Matches(
        [System.IO.File]::ReadAllText($sumsFile),
        "(?im)^([a-f0-9]{64})\s+\*?$escapedName\s*$"
    )
    if ($checksums.Count -ne 1) { throw "No unique SHA-256 checksum for $($chosenAsset.name)." }
    $expected = $checksums[0].Groups[1].Value
    $actual = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
    if ($actual -ine $expected) {
        Remove-Item -LiteralPath $package -Force
        throw 'Yapfast download checksum mismatch. Installation stopped.'
    }
    Write-Host 'SHA-256 verified against the official release.'

    if ($chosenAsset.name -like '*.zip') {
        # Nightlies often ship *only* a portable ZIP, not a setup.exe.
        # Extract into an isolated versioned folder, keeping stable Yapfast
        # installations and their uninstallers untouched.
        $versionName = $chosenRelease.tag_name -replace '[^a-zA-Z0-9_.-]', '_'
        $portableDir = Join-Path $dir (Join-Path 'YapfastPortable' $versionName)
        if (-not (Test-Path -LiteralPath $portableDir -PathType Container)) {
            New-Item -ItemType Directory -Path $portableDir -Force | Out-Null
            Expand-Archive -LiteralPath $package -DestinationPath $portableDir -Force
        }
        $exes = @(Get-ChildItem -LiteralPath $portableDir -Filter 'yapfast.exe' -Recurse -File -ErrorAction Stop)
        if ($exes.Count -ne 1) { throw 'Expected exactly one yapfast.exe inside the portable release.' }
        $app = $exes[0].FullName
        Write-Host "Portable nightly ready: $app"
    } else {
        Write-Host 'Starting the official Yapfast installer; complete its setup wizard.'
        $installerProcess = Start-Process -FilePath $package -PassThru -Wait
        if ($installerProcess.ExitCode -ne 0) {
            throw "Yapfast installer failed with exit code $($installerProcess.ExitCode)."
        }
        if (-not (Test-Path -LiteralPath $app -PathType Leaf)) {
            throw "Yapfast installer finished but the executable was not found at $app"
        }
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

# On reruns with -SkipAppInstall, recover the already-extracted portable
# build rather than falling back to an older stable Yapfast installation.
if ($SkipAppInstall) {
    $portableRoot = Join-Path $dir 'YapfastPortable'
    if (Test-Path -LiteralPath $portableRoot -PathType Container) {
        $portableExe = @(Get-ChildItem -LiteralPath $portableRoot -Filter 'yapfast.exe' -File -Recurse |
            Sort-Object -Property LastWriteTimeUtc -Descending |
            Select-Object -First 1)
        if ($portableExe.Count -eq 1) {
            $app = $portableExe[0].FullName
            Write-Host "Using existing portable Yapfast: $app"
        }
    }
}

if (-not (Test-Path -LiteralPath $app -PathType Leaf)) {
    Write-Warning "No Yapfast executable found. Install Yapfast or rerun without -SkipAppInstall."
} else {
    # Create shortcuts whether vpn.conf exists yet or not. The shortcut
    # launcher validates the config when clicked.
    Write-Host 'Creating the Yapfast GoLive shortcut...'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $shortcutInstaller -Launcher $launcher -WireGuardConfig $vpnConfig -YapfastExe $app -ReplaceStartMenuShortcut
    if ($LASTEXITCODE -ne 0) {
        throw 'Shortcut setup failed. Check the paths and permissions printed above.'
    }
    if (-not (Test-Path -LiteralPath $vpnConfig -PathType Leaf)) {
        Write-Host "To use the new shortcut, place your own WireGuard profile here: $vpnConfig"
    }
}
Write-Host ''
Write-Host 'Setup finished. Start Yapfast GoLive from the Desktop or Start Menu.'
Write-Host 'Note: media-only routing does not guarantee Discord will permit official Go Live in your region.'
