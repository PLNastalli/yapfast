# Creates a normal Windows shortcut that starts Yapfast with the optional
# WireSock -MediaOnly route. Does not modify Yapfast or require a Rust rebuild.
[CmdletBinding()]
param(
    [string] $WireGuardConfig = (Join-Path $env:USERPROFILE 'Downloads\YapFast-GoLive\vpn.conf'),
    [string] $Launcher = (Join-Path $env:USERPROFILE 'Downloads\YapFast-GoLive\start.ps1'),
    [string] $YapfastExe = (Join-Path $env:LOCALAPPDATA 'Programs\Yapfast\yapfast.exe'),
    [switch] $ReplaceStartMenuShortcut,
    [switch] $Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Windows only.' }

$menu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$desktop = [Environment]::GetFolderPath('Desktop')
$shortcuts = @(
    (Join-Path $menu 'Yapfast GoLive.lnk'),
    (Join-Path $desktop 'Yapfast GoLive.lnk')
)
$original = Join-Path $menu 'Yapfast.lnk'
$backup = Join-Path $menu 'Yapfast.before-golive.lnk'

if ($Remove) {
    foreach ($link in $shortcuts) {
        if (Test-Path -LiteralPath $link) {
            Remove-Item -LiteralPath $link -Force
        }
    }
    if (Test-Path -LiteralPath $backup) {
        if (Test-Path -LiteralPath $original) {
            Remove-Item -LiteralPath $original -Force
        }
        Move-Item -LiteralPath $backup -Destination $original
        Write-Host 'Restored the original Start Menu shortcut.'
    }
    Write-Host 'Removed the Yapfast GoLive shortcuts. WireSock and Yapfast are unchanged.'
    return
}

foreach ($path in @($WireGuardConfig, $Launcher, $YapfastExe)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file not found: $path"
    }
}
$config = (Resolve-Path -LiteralPath $WireGuardConfig).ProviderPath
$script = (Resolve-Path -LiteralPath $Launcher).ProviderPath
$app = (Resolve-Path -LiteralPath $YapfastExe).ProviderPath
$hostExe = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $hostExe)) {
    throw 'Windows PowerShell was not found.'
}

# The shortcut invokes the already-installed, tested launcher; it does not
# embed WireGuard private keys or duplicate the user's configuration.
$arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File "{0}" -WireGuardConfig "{1}" -MediaOnly' -f $script, $config
$shell = New-Object -ComObject WScript.Shell
function Save-Shortcut([string] $destination) {
    $link = $shell.CreateShortcut($destination)
    $link.TargetPath = $hostExe
    $link.Arguments = $arguments
    $link.WorkingDirectory = Split-Path -Path $script -Parent
    $link.IconLocation = "$app,0"
    $link.WindowStyle = 7
    $link.Description = 'Yapfast with a VPN route for the Go Live media worker only'
    $link.Save()
}

# Always create separate, easy-to-remove GoLive shortcuts first.
foreach ($link in $shortcuts) {
    Save-Shortcut $link
    Write-Host "Created: $link"
}

# Replacing the existing Start Menu icon is opt-in, with one backup to
# restore the original. Never overwrite an older saved backup.
if ($ReplaceStartMenuShortcut) {
    if (Test-Path -LiteralPath $original -PathType Leaf -and
        -not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $original -Destination $backup
    }
    Save-Shortcut $original
    Write-Host "The Start Menu's Yapfast shortcut now starts media-only VPN mode."
    Write-Host 'Taskbar-pinned shortcuts may need to be unpinned and pinned again.'
}

Write-Host 'Done. Open "Yapfast GoLive" from the Desktop or Start Menu.'
Write-Host 'The VPN route is media-only, not a guarantee of Discord Go Live eligibility.'
