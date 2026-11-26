# JawnOS Windows installer - per-user, double-click friendly.
#
# This is the first-run path for a clean Windows 11 x64 box with no Perl,
# Python, WSL or Docker. The bundle carries a prepared Strawberry Perl tree in
# runtime\ and the application tree in app\; this script copies them under
# %LOCALAPPDATA%\JawnOS, seeds config.json and the database, and arranges the
# shortcuts. Run it through Install.bat.
#
# Two callers share it:
#   - Install.bat (this script owns the shortcuts, the firewall rule and the
#     install folder);
#   - the Inno Setup Setup.exe (Inno owns the files, the shortcuts and the
#     uninstall, so it passes -SkipShortcuts -SkipFirewall and lets firewall.ps1
#     run as its own elevated step).
#
# PowerShell 5.1 is the floor, and nothing here names a fixed Strawberry path:
# the runtime always comes from this bundle's own runtime\ folder.

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'JawnOS'),
    [string]$SourceDir,
    [switch]$NoAutostart,
    [switch]$NoLaunch,
    [switch]$NoBrowser,
    [switch]$Quiet,
    [switch]$Desktop,
    [switch]$SkipShortcuts,
    [switch]$SkipFirewall,
    [string]$Name,
    [string]$Email,
    [string]$Domain,
    [string]$Language,
    [string]$AnswersFile
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    if (-not $Quiet) { Write-Host $Message }
}

function Invoke-Robocopy {
    param([string]$Source, [string]$Destination)
    $rcArgs = @($Source, $Destination, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1')
    & robocopy @rcArgs | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed (exit $LASTEXITCODE) copying $Source to $Destination"
    }
}

# Native commands are captured without a pipeline. Inno runs this script under
# 32-bit PowerShell ({sys} was SysWOW64); a `2>&1 | Out-String` capture of the
# 64-bit perl.exe could block forever there with no child left to wait on,
# freezing the Setup on "Checking the bundled Perl runtime". Both streams are
# drained concurrently instead, so a grandchild inherits no pipe, and the wait
# is bounded so a wedged child is reported instead of waited on.
#
# System.Diagnostics.Process is deliberate. Start-Process -PassThru without
# -Wait returns a process object whose ExitCode is empty on Windows PowerShell
# 5.1 even after WaitForExit; the probe printed "ok" but the installer read no
# exit code and refused the bundled runtime.
function ConvertTo-QuotedArgument {
    param([string]$Value)
    if ($null -eq $Value -or $Value -eq '') { return '""' }
    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

function Invoke-Capture {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 180
    )
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $proc = $null
    try {
        $argLine = (@($Arguments) | ForEach-Object { ConvertTo-QuotedArgument $_ }) -join ' '
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $FilePath
        $startInfo.Arguments = $argLine
        # Start-Process honored the PowerShell location; a bare Process would
        # run the seed's relative scripts\... against the OS current directory.
        $startInfo.WorkingDirectory = $PWD.ProviderPath
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $startInfo
        [void]$proc.Start()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch { }
            throw "$FilePath did not finish within $TimeoutSeconds seconds"
        }
        [void]$proc.WaitForExit()
        $text = [string]$outTask.Result + [string]$errTask.Result
        $code = $proc.ExitCode
    } finally {
        if ($proc) { $proc.Dispose() }
        $ErrorActionPreference = $saved
    }
    return [pscustomobject]@{ Text = $text; Code = $code }
}


function New-JawnShortcut {
    param(
        [string]$LinkPath,
        [string]$Target,
        [string]$Arguments,
        [string]$WorkingDirectory,
        [string]$Icon = ''
    )
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($LinkPath)
    $shortcut.TargetPath = $Target
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.Description = 'JawnOS'
    # The icon is the house mark - the same one the Linux .desktop and the
    # Android launcher use - not wscript.exe's generic script icon.
    if ($Icon -and (Test-Path -LiteralPath $Icon)) {
        $shortcut.IconLocation = "$Icon,0"
    }
    $shortcut.Save()
}

# GetFolderPath answers empty in a SYSTEM or service context with no profile.
# The shell folders are still where Explorer looks, so fall back to the paths
# Windows itself uses and create the directory if it is absent.
function Resolve-ShortcutDirectory {
    param([string]$Kind)
    $candidates = @()
    switch ($Kind) {
        'Programs' {
            $candidates += [Environment]::GetFolderPath('Programs')
            if ($env:APPDATA) {
                $candidates += (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
            }
            if ($env:ProgramData) {
                $candidates += (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
            }
        }
        'Desktop' {
            $candidates += [Environment]::GetFolderPath('Desktop')
            if ($env:USERPROFILE) {
                $candidates += (Join-Path $env:USERPROFILE 'Desktop')
            }
        }
        'Startup' {
            $candidates += [Environment]::GetFolderPath('Startup')
            if ($env:APPDATA) {
                $candidates += (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup')
            }
        }
    }
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            if (-not (Test-Path -LiteralPath $candidate)) {
                New-Item -ItemType Directory -Force -Path $candidate | Out-Null
            }
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        } catch {
            continue
        }
    }
    return ''
}

function Get-ShortcutPath {
    param([string]$Kind)
    $base = Resolve-ShortcutDirectory $Kind
    if ([string]::IsNullOrWhiteSpace($base)) { return '' }
    return (Join-Path $base 'JawnOS.lnk')
}

# --- where this install goes ------------------------------------------------

if ([string]::IsNullOrWhiteSpace($SourceDir)) { $SourceDir = $PSScriptRoot }
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
$sourceFull = [System.IO.Path]::GetFullPath($SourceDir).TrimEnd('\')

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

# A running desktop shell holds its EXE and DLLs open, so replacing the tree
# under it fails. The Setup.exe reaches this same stop through uninstall.ps1;
# Install.bat gets it here. A failure to enumerate is a warning, not a failed
# install. JawnOSShell is the WebView2 window; pythonw is the Qt shell on a
# machine that carries the Python/Qt runtime.
if (Test-Path -LiteralPath $InstallDir) {
    try {
        Get-CimInstance Win32_Process -Filter "Name='JawnOSShell.exe'" -ErrorAction SilentlyContinue |
            ForEach-Object {
                try {
                    Stop-Process -Id $_.ProcessId -Force
                    Write-Step "Stopped the running JawnOS desktop (pid $($_.ProcessId))."
                } catch {
                    Write-Warning "Could not stop the running JawnOS desktop (pid $($_.ProcessId)): $_"
                }
            }
        Get-CimInstance Win32_Process -Filter "Name='pythonw.exe' OR Name='python.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like '*jawnos-desktop*' } |
            ForEach-Object {
                try {
                    Stop-Process -Id $_.ProcessId -Force
                    Write-Step "Stopped the running JawnOS desktop (pid $($_.ProcessId))."
                } catch {
                    Write-Warning "Could not stop the running JawnOS desktop (pid $($_.ProcessId)): $_"
                }
            }
    } catch {
        Write-Warning "Could not look for a running JawnOS desktop: $_"
    }
}

if ($sourceFull -ne $InstallDir) {
    Write-Step "Copying JawnOS to $InstallDir ..."
    Invoke-Robocopy (Join-Path $SourceDir 'app') (Join-Path $InstallDir 'app')
    Invoke-Robocopy (Join-Path $SourceDir 'runtime') (Join-Path $InstallDir 'runtime')
    if (Test-Path -LiteralPath (Join-Path $SourceDir 'webview')) {
        Invoke-Robocopy (Join-Path $SourceDir 'webview') (Join-Path $InstallDir 'webview')
    }
    foreach ($name in @('install.ps1', 'Install.bat', 'uninstall.ps1', 'README.txt', 'jawnos.ico')) {
        $from = Join-Path $SourceDir $name
        if (Test-Path -LiteralPath $from) {
            Copy-Item -LiteralPath $from -Destination $InstallDir -Force
        }
    }
} else {
    Write-Step "Installing in place at $InstallDir"
}

$appDir = Join-Path $InstallDir 'app'
$runtimeDir = Join-Path $InstallDir 'runtime'
$perl = Join-Path $InstallDir 'runtime\perl\bin\perl.exe'
$configPath = Join-Path $appDir 'config.json'
$codePath = Join-Path $InstallDir 'unlock-code.txt'
$webviewShell = Join-Path $InstallDir 'webview\JawnOSShell.exe'
$pythonw = Join-Path $InstallDir 'runtime\python\pythonw.exe'
$desktopScript = Join-Path $appDir 'desktop\jawnos-desktop'
$qtWebEngine = Join-Path $InstallDir 'runtime\python\Lib\site-packages\PySide6\QtWebEngineCore.pyd'
$qtWebWidgets = Join-Path $InstallDir 'runtime\python\Lib\site-packages\PySide6\QtWebEngineWidgets.pyd'
$hasShell = (Test-Path -LiteralPath $pythonw) -and
    (Test-Path -LiteralPath $desktopScript) -and
    (Test-Path -LiteralPath $qtWebEngine) -and
    (Test-Path -LiteralPath $qtWebWidgets)

# The WebView2 Evergreen runtime is the machine's, not ours. Windows 11 ships
# it; an older or stripped Windows may not, and then launch.ps1 falls back to
# the browser. The SDK DLLs and loader travel in webview\.
$webViewRuntime = $false
foreach ($key in @(
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
    'HKCU:\Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}')) {
    if (Test-Path -Path $key) { $webViewRuntime = $true }
}
foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
    if ($base -and (Test-Path -LiteralPath (Join-Path $base 'Microsoft\EdgeWebView\Application'))) {
        $webViewRuntime = $true
    }
}
$hasWebView = (Test-Path -LiteralPath $webviewShell) -and $webViewRuntime

foreach ($required in @($appDir, $runtimeDir, $perl, (Join-Path $appDir 'scripts\jawnos_setup.pl'))) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "The bundle is incomplete: $required is missing. Rebuild it with build-portable.ps1."
    }
}

# Piper and SoX are the Windows voice and the house's audio tool. A bundle
# built with -NoTools lacks them; the house still runs, but speech and the
# synth chime stay silent, so say so once instead of failing the install.
foreach ($tool in @('runtime\tools\piper\piper.exe', 'runtime\tools\sox\sox.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir $tool))) {
        Write-Warning "This bundle has no $tool; speech and the synth chime will be silent."
    }
}

# The environment every child gets. c\bin is first: Net::SSLeay loads libcrypto
# and libssl from there, while perl.exe and the pure-Perl tools live in
# perl\bin. Both directories are required.
$env:JAWNOS_PORTABLE = '1'
$env:JAWNOS_TRANSPORT = 'tcp'
$env:JAWNOS_DIR = $appDir
$env:PATH = "$InstallDir\runtime\c\bin;$InstallDir\runtime\perl\bin;$InstallDir\runtime\tools\piper;$InstallDir\runtime\tools\sox;$env:PATH"

# --- prove the bundled runtime before touching the house --------------------

Write-Step 'Checking the bundled Perl runtime ...'
$probeArgs = @(
    '-MMojolicious', '-MMojo::SQLite', '-MMinion', '-MDBD::SQLite',
    '-MSereal::Encoder', '-MSereal::Decoder', '-MNet::SSLeay', '-MCryptX',
    '-MFile::Slurp', '-MWin32::API', '-MWin32API::File',
    # the seed's own requires and the manager's eager preamble: without these
    # the install looks fine and the first page dies
    '-MCrypt::Simple', '-MTime::Duration', '-MDate::Parse', '-MClone',
    '-MURI::Encode', '-MFile::Type', '-MHTML::Strip', '-MHTML::Parser',
    '-MNumber::Format', '-MSQL::Abstract', '-MData::UUID',
    '-e', 'print qq(ok\n)'
)
$probe = Invoke-Capture -FilePath $perl -Arguments $probeArgs
if ($probe.Code -ne 0) {
    $missing = ''
    if ($probe.Text -match "Can't locate ([A-Za-z0-9_:]+)\.pm") { $missing = $Matches[1] }
    if ($missing) {
        throw "The bundled Perl runtime is incomplete: module $missing is missing. Rebuild the bundle from a complete Strawberry Perl tree.`n$($probe.Text)"
    }
    throw "The bundled Perl runtime failed its module probe (exit $($probe.Code)).`n$($probe.Text)"
}

# --- first run: config.json, the database and the unlock code ---------------

# Both halves are the house. A run that died between them leaves config.json
# behind with no database, and treating that as an existing install would print
# "JawnOS is installed" over a house that has nothing in it.
$code = ''
$dbPath = Join-Path $appDir 'database\jawnos.db'
$needConfig = -not (Test-Path -LiteralPath $configPath)
$needDb = -not (Test-Path -LiteralPath $dbPath)
if ($needConfig -or $needDb) {
    Write-Step 'First run: seeding config.json and the database ...'
    if ($needConfig) {
        Copy-Item -LiteralPath (Join-Path $appDir 'config.json.example') -Destination $configPath -Force

        # The bundle must not pop a browser on the manager's own first boot; the
        # installer opens it once the port answers.
        $configText = Get-Content -LiteralPath $configPath -Raw
        $configText = $configText -replace '"open_browser"\s*:\s*"yes"', '"open_browser": "no"'
        Set-Content -LiteralPath $configPath -Value $configText -Encoding ASCII
    }

    if ($needDb) {
        # the code becomes the house key, so it is drawn once, with the database
        $code = [string](Get-Random -Minimum 100000 -Maximum 999999)
    }
    elseif (Test-Path -LiteralPath $codePath) {
        # the database outlived its config.json: its own code still opens it,
        # and writing a fresh one here would lock the person out of their house
        $match = [regex]::Match((Get-Content -LiteralPath $codePath -Raw), '[0-9]{4,12}')
        if ($match.Success) { $code = $match.Value }
    }

    # The Setup.exe writes the values the person chose into a small key=value
    # file; the script installer can pass the same flags directly. An omitted
    # value keeps the seed's own default, so a silent install still works.
    $answers = @{}
    if ($AnswersFile -and (Test-Path -LiteralPath $AnswersFile)) {
        foreach ($line in Get-Content -LiteralPath $AnswersFile) {
            if ($line -match '^\s*([A-Za-z][A-Za-z0-9_]*)\s*=\s*(.*)$') {
                $answers[$Matches[1]] = $Matches[2].Trim()
            }
        }
    }
    if (-not $Name -and $answers['Name']) { $Name = $answers['Name'] }
    if (-not $Email -and $answers['Email']) { $Email = $answers['Email'] }
    if (-not $Domain -and $answers['Domain']) { $Domain = $answers['Domain'] }
    if (-not $Language -and $answers['Language']) { $Language = $answers['Language'] }
    if (-not $Name) { $Name = 'JawnOS' }
    if (-not $Language) { $Language = 'en' }

    $seedArgs = @(
        'scripts\jawnos_setup.pl', '--seed', '--name', $Name,
        '--device', 'computer', '--language', $Language
    )
    if ($code) { $seedArgs += @('--code', $code) }
    if ($Email) { $seedArgs += @('--email', $Email) }
    if ($Domain) { $seedArgs += @('--domain', $Domain) }

    Push-Location $appDir
    try {
        $setup = Invoke-Capture -FilePath $perl -Arguments $seedArgs
    } finally {
        Pop-Location
    }
    if ($setup.Code -ne 0) {
        throw "jawnos_setup.pl failed (exit $($setup.Code)):`n$($setup.Text)"
    }

    if ($needDb) {
        $codeText = "JawnOS unlock code: $code" + "`r`n`r`n" +
            "Enter this code at the JawnOS login screen. It is the only key to your data; keep it safe." + "`r`n"
        Set-Content -LiteralPath $codePath -Value $codeText -Encoding ASCII
        Write-Step "Unlock code $code (saved to $codePath)"
    }
} else {
    Write-Step 'Existing install found; keeping config.json and the database.'
    if (Test-Path -LiteralPath $codePath) {
        $match = [regex]::Match((Get-Content -LiteralPath $codePath -Raw), '[0-9]{4,12}')
        if ($match.Success) { $code = $match.Value }
    }
    if (-not $code) { $code = '(see unlock-code.txt or your records)' }
}

# --- the desktop's forever ticket -------------------------------------------
# The embedded view signs in by loading a ticket URL; app_ticket.pl reuses an
# active forever ticket and --save writes .shots\ticket.txt, which the shell
# reads on its first launch and then stores with DPAPI. Minting is idempotent,
# so an upgrade does not rotate the running desktop's ticket. A failure leaves
# the Gate usable, so it is a warning rather than a failed install.

Write-Step 'Minting the desktop login ticket ...'
Push-Location $appDir
try {
    $ticket = Invoke-Capture -FilePath $perl -Arguments @(
        'scripts\app_ticket.pl', 'desktop', '--save') -TimeoutSeconds 60
} finally {
    Pop-Location
}
if ($ticket.Code -eq 0) {
    Write-Step 'The desktop ticket is ready.'
} else {
    Write-Warning "Could not mint the desktop ticket; the Gate still signs in.`n$($ticket.Text)"
}

# --- launch files -----------------------------------------------------------
# One job per entry point:
#   launch.bat  starts the house (the service);
#   start.vbs   runs launch.bat hidden, and is all the Startup shortcut does;
#   launch.ps1  opens the web interface, starting the service first if needed;
#   launch.vbs  runs launch.ps1 hidden - the Start menu and desktop icon.
#
# When the payload carries the Qt shell (runtime\python with PySide6/Qt
# WebEngine), launch.ps1 starts that shell, which owns the tray and signs in
# from the minted ticket; the browser path below stays as the fallback for a
# payload built without the shell. The icon used to run launch.bat alone. A
# second click while the house was already serving did nothing at all and no
# browser ever opened, so the icon looked dead.

$batPath = Join-Path $InstallDir 'launch.bat'
$bat = @"
@echo off
set "JAWNOS_PORTABLE=1"
set "JAWNOS_TRANSPORT=tcp"
set "JAWNOS_DIR=$appDir"
set "PATH=$InstallDir\runtime\c\bin;$InstallDir\runtime\perl\bin;$InstallDir\runtime\tools\piper;$InstallDir\runtime\tools\sox;%PATH%"
cd /d "%JAWNOS_DIR%"
"%~dp0runtime\perl\bin\perl.exe" jawn >> "$InstallDir\master.log" 2>&1
"@
Set-Content -LiteralPath $batPath -Value $bat -Encoding ASCII

$startVbsPath = Join-Path $InstallDir 'start.vbs'
$startVbs = @"
Set sh = CreateObject("WScript.Shell")
sh.Run Chr(34) & "$batPath" & Chr(34), 0, False
"@
Set-Content -LiteralPath $startVbsPath -Value $startVbs -Encoding ASCII

$launchPs1Path = Join-Path $InstallDir 'launch.ps1'
$launchPs1 = @'
# Open JawnOS. The WebView2 shell comes first: it owns the window and tray,
# starts the house if it is down, and signs in from the ticket. Then the Qt
# shell, when the payload carries Python/Qt. A payload with neither falls back
# to starting the service and opening the browser, which is the behaviour the
# installer had before a shell was bundled.
$ErrorActionPreference = 'Stop'
$install = $PSScriptRoot
$webview = Join-Path $install 'webview\JawnOSShell.exe'
$webviewRuntime = $false
$wvBase = ${env:ProgramFiles(x86)}
if ($wvBase -and (Test-Path (Join-Path $wvBase 'Microsoft\EdgeWebView\Application'))) { $webviewRuntime = $true }
if (-not $webviewRuntime -and $env:ProgramFiles -and (Test-Path (Join-Path $env:ProgramFiles 'Microsoft\EdgeWebView\Application'))) { $webviewRuntime = $true }
if ((Test-Path -LiteralPath $webview) -and $webviewRuntime) {
    Start-Process -FilePath $webview -ArgumentList ('--install "' + $install + '"') -WorkingDirectory $install | Out-Null
    exit 0
}
$pythonw = Join-Path $install 'runtime\python\pythonw.exe'
$desktop = Join-Path $install 'app\desktop\jawnos-desktop'
$qt = Join-Path $install 'runtime\python\Lib\site-packages\PySide6\QtWebEngineCore.pyd'
$qtw = Join-Path $install 'runtime\python\Lib\site-packages\PySide6\QtWebEngineWidgets.pyd'
if ((Test-Path -LiteralPath $pythonw) -and (Test-Path -LiteralPath $desktop) -and (Test-Path -LiteralPath $qt) -and (Test-Path -LiteralPath $qtw)) {
    Start-Process -FilePath $pythonw -ArgumentList @(('"' + $desktop + '"'), '--tray') -WorkingDirectory (Join-Path $install 'app') | Out-Null
    exit 0
}

$port = 45545
try {
    $cfg = Get-Content -LiteralPath (Join-Path $install 'app\config.json') -Raw | ConvertFrom-Json
    if ($cfg.working_port) { $port = [int]$cfg.working_port }
} catch { }

function Test-JawnPort([int]$candidate) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $client.ConnectAsync('127.0.0.1', $candidate)
        return ($connect.Wait(1000) -and $client.Connected)
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

if (-not (Test-JawnPort $port)) {
    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    Start-Process -FilePath $wscript -ArgumentList ('"' + (Join-Path $install 'start.vbs') + '"') | Out-Null
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline -and -not (Test-JawnPort $port)) {
        Start-Sleep -Seconds 2
    }
}

if (Test-JawnPort $port) {
    Start-Process "https://127.0.0.1:$port/manager"
} else {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $message = "JawnOS did not answer on https://127.0.0.1:$port/manager. See $install\master.log for details."
        [System.Windows.Forms.MessageBox]::Show($message, 'JawnOS', 'OK', 'Warning') | Out-Null
    } catch { }
}
'@
Set-Content -LiteralPath $launchPs1Path -Value $launchPs1 -Encoding UTF8

$vbsPath = Join-Path $InstallDir 'launch.vbs'
$vbs = @"
Set sh = CreateObject("WScript.Shell")
ps = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
sh.Run Chr(34) & ps & Chr(34) & " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & "$launchPs1Path" & Chr(34), 0, False
"@
Set-Content -LiteralPath $vbsPath -Value $vbs -Encoding ASCII

# --- shortcuts --------------------------------------------------------------
# Inno Setup owns them when it wraps this bundle; then -SkipShortcuts keeps the
# two from creating (and later uninstalling) the same JawnOS.lnk twice.

$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
if (-not (Test-Path -LiteralPath $wscript)) { $wscript = 'wscript.exe' }
$launchArgs = '"' + $vbsPath + '"'
$startArgs = '"' + $startVbsPath + '"'
$iconPath = Join-Path $InstallDir 'jawnos.ico'

$startMenu = ''
$desktopShortcut = ''
$startupShortcut = ''
if ($SkipShortcuts) {
    Write-Step 'Skipping shortcuts: the Setup.exe creates them.'
} else {
    $startMenu = Get-ShortcutPath 'Programs'
    if ($startMenu) {
        New-JawnShortcut -LinkPath $startMenu -Target $wscript -Arguments $launchArgs -WorkingDirectory $InstallDir -Icon $iconPath
        Write-Step "Start menu shortcut: $startMenu"
    } else {
        Write-Warning 'Could not create the Start menu shortcut: no Start menu Programs folder was found.'
    }

    if ($Desktop) {
        $desktopShortcut = Get-ShortcutPath 'Desktop'
        if ($desktopShortcut) {
            New-JawnShortcut -LinkPath $desktopShortcut -Target $wscript -Arguments $launchArgs -WorkingDirectory $InstallDir -Icon $iconPath
            Write-Step "Desktop shortcut: $desktopShortcut"
        } else {
            Write-Warning 'Could not create the desktop shortcut: no Desktop folder was found.'
        }
    }

    if (-not $NoAutostart) {
        $startupShortcut = Get-ShortcutPath 'Startup'
        if ($startupShortcut) {
            New-JawnShortcut -LinkPath $startupShortcut -Target $wscript -Arguments $startArgs -WorkingDirectory $InstallDir -Icon $iconPath
            Write-Step "Autostart shortcut: $startupShortcut"
        } else {
            Write-Warning 'Could not create the autostart shortcut: no Startup folder was found.'
        }
    }
}

# --- firewall ---------------------------------------------------------------
# firewall.ps1 is the one implementation of the rule. Elevation is not required
# for a working local install, so a refusal is a warning; the Setup.exe runs the
# same script as its own elevated step.

if ($SkipFirewall) {
    Write-Step 'Skipping the firewall rule: the Setup.exe adds it.'
} else {
    $ruleScript = Join-Path $PSScriptRoot 'firewall.ps1'
    Write-Step 'Adding the JawnOS firewall rule ...'
    if (Test-Path -LiteralPath $ruleScript) {
        # A child PowerShell keeps firewall.ps1's exit from ending this script;
        # its exit code is the verdict.
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $savedPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $powershell -NoProfile -ExecutionPolicy Bypass -File $ruleScript -InstallDir $InstallDir
            $firewallCode = $LASTEXITCODE
        } catch {
            $firewallCode = 1
        } finally {
            $ErrorActionPreference = $savedPreference
        }
        if ($firewallCode -ne 0) {
            Write-Warning 'The JawnOS firewall rule was not added. Administrator rights are needed for other devices to reach this machine; JawnOS still works locally. Re-run from an elevated prompt, or allow perl.exe when Windows asks.'
        }
    } else {
        Write-Warning "The firewall script is missing from the bundle: $ruleScript"
    }
}

# --- start and wait for the port --------------------------------------------

$port = 45545
try {
    $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ($cfg.working_port) { $port = [int]$cfg.working_port }
} catch {
    Write-Step "Could not read working_port; assuming $port."
}
$url = "https://127.0.0.1:$port/manager"

$up = $false
if (-not $NoLaunch) {
    $useWebView = $hasWebView -and (-not $NoBrowser)
    $useQt = $hasShell -and (-not $useWebView) -and (-not $NoBrowser)
    if ($useWebView) {
        Write-Step 'Starting the JawnOS desktop ...'
        Start-Process -FilePath $webviewShell -ArgumentList ('--install "' + $InstallDir + '"') -WorkingDirectory $InstallDir | Out-Null
    } elseif ($useQt) {
        Write-Step 'Starting the JawnOS desktop ...'
        Start-Process -FilePath $pythonw -ArgumentList @(('"' + $desktopScript + '"'), '--tray') -WorkingDirectory $appDir | Out-Null
    } else {
        Write-Step 'Starting JawnOS ...'
        Start-Process -FilePath $wscript -ArgumentList $startArgs | Out-Null
    }

    # Readiness is a TCP connect, not an HTTP request: this box's .NET/SChannel
    # stack fails the house certificate's handshake even though the server
    # answers (curl -k returns 200). The browser owns TLS; the installer only
    # asks whether something is listening on the port.
    Write-Step "Waiting for 127.0.0.1:$port (up to 120 seconds) ..."
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline -and -not $up) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $connect = $client.ConnectAsync('127.0.0.1', $port)
            if ($connect.Wait(1000)) { $up = $client.Connected }
        } catch {
            $up = $false
        } finally {
            $client.Close()
        }
        if (-not $up) { Start-Sleep -Seconds 2 }
    }
    if ($up) {
        Write-Step "JawnOS is listening on 127.0.0.1:$port"
    } else {
        Write-Warning "Nothing is listening on 127.0.0.1:$port after 120 seconds. See $InstallDir\master.log"
    }
    if ($up -and -not $NoBrowser -and -not $useWebView -and -not $useQt) { Start-Process $url | Out-Null }
}

# --- tell the person the one thing they must keep ---------------------------

if (-not $Quiet) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $body = "JawnOS is installed.`r`n`r`n" +
            "Unlock code: $code`r`n" +
            "Install folder: $InstallDir`r`n" +
            "Code file: $codePath`r`n`r`n" +
            "Web interface: $url"
        [System.Windows.Forms.MessageBox]::Show(
            $body, 'JawnOS',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    } catch {
        Write-Step 'Could not show the completion dialog.'
    }
}

Write-Host ''
Write-Host 'JawnOS is installed.'
Write-Host "  app          $appDir"
Write-Host "  runtime      $runtimeDir"
Write-Host "  unlock code  $code"
Write-Host "  code file    $codePath"
Write-Host "  start menu   $startMenu"
if ($desktopShortcut) { Write-Host "  desktop      $desktopShortcut" }
if ($startupShortcut) { Write-Host "  autostart    $startupShortcut" } else { Write-Host '  autostart    (not created)' }
Write-Host "  web          $url"
