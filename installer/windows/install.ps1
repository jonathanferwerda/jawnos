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

# Native commands write progress on stderr; under $ErrorActionPreference=Stop a
# redirected stderr becomes a terminating error in PowerShell 5.1. Capture the
# output with Continue in force and judge the exit code instead.
function Invoke-Capture {
    param([string]$FilePath, [string[]]$Arguments)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $text = (& $FilePath @Arguments 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
    return [pscustomobject]@{ Text = $text; Code = $code }
}


function New-JawnShortcut {
    param(
        [string]$LinkPath,
        [string]$Target,
        [string]$Arguments,
        [string]$WorkingDirectory
    )
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($LinkPath)
    $shortcut.TargetPath = $Target
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.Description = 'JawnOS'
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

if ($sourceFull -ne $InstallDir) {
    Write-Step "Copying JawnOS to $InstallDir ..."
    Invoke-Robocopy (Join-Path $SourceDir 'app') (Join-Path $InstallDir 'app')
    Invoke-Robocopy (Join-Path $SourceDir 'runtime') (Join-Path $InstallDir 'runtime')
    foreach ($name in @('install.ps1', 'Install.bat', 'uninstall.ps1', 'README.txt')) {
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

foreach ($required in @($appDir, $runtimeDir, $perl, (Join-Path $appDir 'scripts\jawnos_setup.pl'))) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "The bundle is incomplete: $required is missing. Rebuild it with build-portable.ps1."
    }
}

# The environment every child gets. c\bin is first: Net::SSLeay loads libcrypto
# and libssl from there, while perl.exe and the pure-Perl tools live in
# perl\bin. Both directories are required.
$env:JAWNOS_PORTABLE = '1'
$env:JAWNOS_TRANSPORT = 'tcp'
$env:JAWNOS_DIR = $appDir
$env:PATH = "$InstallDir\runtime\c\bin;$InstallDir\runtime\perl\bin;$env:PATH"

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

# --- launch files -----------------------------------------------------------

$batPath = Join-Path $InstallDir 'launch.bat'
$bat = @"
@echo off
set "JAWNOS_PORTABLE=1"
set "JAWNOS_TRANSPORT=tcp"
set "JAWNOS_DIR=$appDir"
set "PATH=$InstallDir\runtime\c\bin;$InstallDir\runtime\perl\bin;%PATH%"
cd /d "%JAWNOS_DIR%"
"%~dp0runtime\perl\bin\perl.exe" jawn >> "$InstallDir\master.log" 2>&1
"@
Set-Content -LiteralPath $batPath -Value $bat -Encoding ASCII

$vbsPath = Join-Path $InstallDir 'launch.vbs'
$vbs = @"
Set sh = CreateObject("WScript.Shell")
sh.Run Chr(34) & "$batPath" & Chr(34), 0, False
"@
Set-Content -LiteralPath $vbsPath -Value $vbs -Encoding ASCII

# --- shortcuts --------------------------------------------------------------
# Inno Setup owns them when it wraps this bundle; then -SkipShortcuts keeps the
# two from creating (and later uninstalling) the same JawnOS.lnk twice.

$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
if (-not (Test-Path -LiteralPath $wscript)) { $wscript = 'wscript.exe' }
$launchArgs = '"' + $vbsPath + '"'

$startMenu = ''
$desktopShortcut = ''
$startupShortcut = ''
if ($SkipShortcuts) {
    Write-Step 'Skipping shortcuts: the Setup.exe creates them.'
} else {
    $startMenu = Get-ShortcutPath 'Programs'
    if ($startMenu) {
        New-JawnShortcut -LinkPath $startMenu -Target $wscript -Arguments $launchArgs -WorkingDirectory $InstallDir
        Write-Step "Start menu shortcut: $startMenu"
    } else {
        Write-Warning 'Could not create the Start menu shortcut: no Start menu Programs folder was found.'
    }

    if ($Desktop) {
        $desktopShortcut = Get-ShortcutPath 'Desktop'
        if ($desktopShortcut) {
            New-JawnShortcut -LinkPath $desktopShortcut -Target $wscript -Arguments $launchArgs -WorkingDirectory $InstallDir
            Write-Step "Desktop shortcut: $desktopShortcut"
        } else {
            Write-Warning 'Could not create the desktop shortcut: no Desktop folder was found.'
        }
    }

    if (-not $NoAutostart) {
        $startupShortcut = Get-ShortcutPath 'Startup'
        if ($startupShortcut) {
            New-JawnShortcut -LinkPath $startupShortcut -Target $wscript -Arguments $launchArgs -WorkingDirectory $InstallDir
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
    Write-Step 'Starting JawnOS ...'
    Start-Process -FilePath $wscript -ArgumentList $launchArgs | Out-Null

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
    if ($up -and -not $NoBrowser) { Start-Process $url | Out-Null }
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
