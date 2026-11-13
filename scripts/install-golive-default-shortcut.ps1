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
# Windows Script Host launches the existing PowerShell script without showing
# a console window. Unlike -WindowStyle Minimized, this is actually hidden.
$hiddenScript = Join-Path (Split-Path -Path $Launcher -Parent) 'launch-golive-hidden.vbs'

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
    if (Test-Path -LiteralPath $hiddenScript -PathType Leaf) {
        Remove-Item -LiteralPath $hiddenScript -Force
    }
    Write-Host 'Removed the Yapfast GoLive shortcuts. WireSock and Yapfast are unchanged.'
    return
}

# The VPN profile is intentionally optional during shortcut installation.
# It contains a private key, and the user may obtain it only later.
# The shortcut points to that expected location and the launcher validates it
# when opened, rather than silently skipping shortcut creation.
foreach ($path in @($Launcher, $YapfastExe)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file not found: $path"
    }
}
$config = [System.IO.Path]::GetFullPath($WireGuardConfig)
if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
    Write-Warning "vpn.conf not found yet. The shortcut will exist but cannot connect until the profile is placed here: $config"
}
$script = (Resolve-Path -LiteralPath $Launcher).ProviderPath
$app = (Resolve-Path -LiteralPath $YapfastExe).ProviderPath
$hostExe = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $hostExe)) {
    throw 'Windows PowerShell was not found.'
}

# The shortcut launches a tiny local VBScript using wscript.exe, which
# starts PowerShell completely hidden. No WireGuard keys are written here,
# only executable/script paths and the location of the profile.
$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
if (-not (Test-Path -LiteralPath $wscript -PathType Leaf)) {
    throw 'Windows Script Host (wscript.exe) is not available.'
}
$arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -WireGuardConfig "{1}" -YapfastExe "{2}" -MediaOnly' -f $script, $config, $app
$command = '"' + $hostExe + '" ' + $arguments
$errorLog = Join-Path $env:LOCALAPPDATA 'Yapfast\GoLiveTunnel\last-error.log'
$vbs = @(
    'Option Explicit'
    'Dim shell, command, exitCode'
    'Set shell = CreateObject("WScript.Shell")'
    # WireSock packet filtering may require elevation. The visible UAC prompt
    # authorizes the tunnel; the elevated second launch stays console-free.
    'If WScript.Arguments.Count = 0 Then'
    '  On Error Resume Next'
    '  CreateObject("Shell.Application").ShellExecute WScript.FullName, "//B //Nologo """ & WScript.ScriptFullName & """ elevated", "", "runas", 0'
    '  If Err.Number <> 0 Then'
    '    shell.Popup "Permissao de administrador necessaria para WireSock." & vbCrLf & Err.Description, 0, "Yapfast GoLive", 16'
    '  End If'
    '  WScript.Quit 0'
    'End If'
    ('command = "' + $command.Replace('"', '""') + '"')
    'exitCode = shell.Run(command, 0, True)'
    'If exitCode <> 0 Then'
    ('  shell.Popup "Yapfast GoLive nao iniciou. A VPN pode ter falhado." & vbCrLf & "Consulte: ' + $errorLog.Replace('"', '""') + '", 0, "Yapfast GoLive", 16')
    'End If'
) -join [Environment]::NewLine
# VBScript reads UTF-16LE with BOM, including Windows paths with accents.
[System.IO.File]::WriteAllText($hiddenScript, $vbs, [System.Text.Encoding]::Unicode)

$shell = New-Object -ComObject WScript.Shell
function Save-Shortcut([string] $destination) {
    $link = $shell.CreateShortcut($destination)
    $link.TargetPath = $wscript
    $link.Arguments = ('//B //Nologo "{0}"' -f $hiddenScript)
    $link.WorkingDirectory = Split-Path -Path $script -Parent
    $link.IconLocation = "$app,0"
    $link.WindowStyle = 1
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
    if ((Test-Path -LiteralPath $original -PathType Leaf) -and
        -not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $original -Destination $backup
    }
    Save-Shortcut $original
    Write-Host "The Start Menu's Yapfast shortcut now starts media-only VPN mode."
    Write-Host 'Taskbar-pinned shortcuts may need to be unpinned and pinned again.'
}

Write-Host 'Done. Open "Yapfast GoLive" from the Desktop or Start Menu.'
Write-Host 'The VPN route is media-only, not a guarantee of Discord Go Live eligibility.'
