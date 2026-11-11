# Remove a per-user JawnOS install.
#
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1 -PurgeData
#
# It stops the master first (the tree's own killer, then the master pid record),
# removes the firewall rule and the three shortcuts, and deletes the install
# folder. -PurgeData also deletes %USERPROFILE%\.president, the per-user
# runtime state and job logs. The house database lives under the install folder,
# so it goes with the folder unless this is a special layout.
#
# The Inno Setup uninstaller owns the files and shortcuts, so it passes
# -KeepFolder -SkipShortcuts -SkipFirewall: this script then only stops the
# house, and Inno and firewall.ps1 remove what they installed.

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'JawnOS'),
    [switch]$PurgeData,
    [switch]$KeepFolder,
    [switch]$SkipShortcuts,
    [switch]$SkipFirewall
)

$ErrorActionPreference = 'Stop'

$InstallDir = [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\')

function Note {
    param([string]$Message)
    Write-Host $Message
}

# The same fallback order install.ps1 uses, but find-only: an uninstall must
# not create an empty Start menu folder just to discover it is empty.
function Get-ShortcutPaths {
    param([string]$Kind)
    $paths = @()
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
        $link = Join-Path $candidate 'JawnOS.lnk'
        if ((Test-Path -LiteralPath $link) -and ($paths -notcontains $link)) {
            $paths += $link
        }
    }
    return $paths
}

if (-not (Test-Path -LiteralPath $InstallDir)) {
    Write-Host "JawnOS is not installed at $InstallDir."
    exit 0
}

$appDir = Join-Path $InstallDir 'app'
$perl = Join-Path $InstallDir 'runtime\perl\bin\perl.exe'

# --- stop the master --------------------------------------------------------
# The tree's own killer knows the master, its workers and the port. It is the
# first answer; the pid record is the fallback when the runtime is already
# damaged or has been removed.

if ((Test-Path -LiteralPath $perl) -and
    (Test-Path -LiteralPath (Join-Path $appDir 'scripts\manager_killer.pl'))) {
    $env:JAWNOS_PORTABLE = '1'
    $env:JAWNOS_TRANSPORT = 'tcp'
    $env:JAWNOS_DIR = $appDir
    $env:PATH = "$InstallDir\runtime\c\bin;$InstallDir\runtime\perl\bin;$env:PATH"
    Push-Location $appDir
    try {
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $perl 'scripts\manager_killer.pl' 'master'
        } finally {
            $ErrorActionPreference = $saved
        }
    } catch {
        Write-Warning "The bundled manager killer did not run: $_"
    } finally {
        Pop-Location
    }
}

$pidFile = Join-Path $env:USERPROFILE '.president\pid'
if (Test-Path -LiteralPath $pidFile) {
    $pidText = (Get-Content -LiteralPath $pidFile -Raw).Trim()
    if ($pidText -match '^[0-9]+$') {
        $masterPid = [int]$pidText
        if (Get-Process -Id $masterPid -ErrorAction SilentlyContinue) {
            try {
                Stop-Process -Id $masterPid -Force
                Note "Stopped the master (pid $masterPid)."
            } catch {
                Write-Warning "Could not stop pid $masterPid : $_"
            }
        }
    }
}

# --- firewall rule ----------------------------------------------------------

if ($SkipFirewall) {
    Note 'Skipping the firewall rule: the Setup.exe removes it.'
} else {
    $ruleScript = Join-Path $PSScriptRoot 'firewall.ps1'
    if (Test-Path -LiteralPath $ruleScript) {
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $savedPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $powershell -NoProfile -ExecutionPolicy Bypass -File $ruleScript -InstallDir $InstallDir -Remove
        } catch {
            Write-Warning "Could not remove the JawnOS firewall rule: $_"
        } finally {
            $ErrorActionPreference = $savedPreference
        }
    } else {
        Write-Warning "The firewall script is missing from the install: $ruleScript"
    }
}

# --- shortcuts --------------------------------------------------------------

if ($SkipShortcuts) {
    Note 'Skipping shortcuts: the Setup.exe removes them.'
} else {
    foreach ($kind in @('Programs', 'Desktop', 'Startup')) {
        $links = @(Get-ShortcutPaths $kind)
        if (-not $links) {
            Note "No $kind shortcut found."
            continue
        }
        foreach ($link in $links) {
            try {
                Remove-Item -LiteralPath $link -Force
                Note "Removed shortcut $link"
            } catch {
                Write-Warning "Could not remove $link : $_"
            }
        }
    }
}

# --- the install folder -----------------------------------------------------

if ($KeepFolder) {
    Note 'Keeping the install folder: the Setup.exe removes it.'
} else {
    # Leave the install folder so Windows does not hold the current directory open.
    Set-Location $env:USERPROFILE
    try {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
        Note "Removed $InstallDir"
    } catch {
        Write-Warning "Could not remove $InstallDir : $_"
        Write-Warning 'Close any JawnOS console or browser tab and run this again.'
    }
}

# --- optional per-user state ------------------------------------------------

if ($PurgeData) {
    $dataDir = Join-Path $env:USERPROFILE '.president'
    if (Test-Path -LiteralPath $dataDir) {
        Write-Host "Removing per-user runtime state and job logs from $dataDir ..."
        try {
            Remove-Item -LiteralPath $dataDir -Recurse -Force
            Note "Removed $dataDir"
        } catch {
            Write-Warning "Could not remove $dataDir : $_"
        }
    } else {
        Note "No per-user state at $dataDir"
    }
}

Write-Host ''
Write-Host 'JawnOS has been uninstalled.'
