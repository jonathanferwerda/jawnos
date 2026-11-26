# Build the portable Windows bundle for JawnOS.
#
#   powershell -ExecutionPolicy Bypass -File installer\windows\build-portable.ps1 `
#       -RuntimeDir C:\path\to\strawberry-perl
#
# -RuntimeDir is a prepared Strawberry Perl tree (the one you cpanm'd the app's
# modules into). It is copied as runtime\, not built here: the reproducible
# path - download the portable Strawberry build and cpanm the pinned module
# set, as .github/workflows/platform-p0.yml does on a runner - is the next
# slice. Until then a bundle is only as complete as the runtime it was given.
#
# -PythonDir is the desktop shell's runtime: a relocatable CPython with PySide6
# (Qt WebEngine) installed. It is copied as runtime\python\. Without it the
# bundle still works, but the shortcut opens the web interface in the default
# browser instead of the desktop window and tray.
#
# Piper (the house's voice) and SoX (the house's audio tool) are downloaded at
# build time into runtime\tools\, or copied from -ToolsDir. The public-domain
# default voice is copied from -VoiceDir (default <TreeDir>\voices) so a fresh
# Windows house can speak before voice_sync reaches a peer. SoX's Windows build
# has no MP3 decoder, so the browser remains the player for the shipped chimes
# (docs/platform-roadmap.md). -NoTools builds without any of this.
#
# The staged payload is <OutDir>\JawnOS-<version>\ (app\, runtime\ and the
# install scripts). The zip beside it holds that same folder. Nothing is
# signed yet.
#
# The bundle does not build OpenStreetMap basemaps: there is no reliable native
# Windows tilemaker/osmium build, and the house reads the .pmtiles archive its
# Unix box serves at /manager/travel/basemap. Nothing here adds those tools.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RuntimeDir,
    [string]$PythonDir,
    [string]$TreeDir,
    [string]$OutDir,
    [string]$ToolsDir,
    [string]$VoiceDir,
    [switch]$NoTools,
    [switch]$NoZip
)

$ErrorActionPreference = 'Stop'

function Invoke-Robocopy {
    param(
        [string]$Source,
        [string]$Destination,
        [string[]]$ExcludeDirs,
        [string[]]$ExcludeFiles
    )
    $rcArgs = @($Source, $Destination, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1')
    if ($ExcludeDirs) {
        $rcArgs += '/XD'
        $rcArgs += $ExcludeDirs
    }
    if ($ExcludeFiles) {
        $rcArgs += '/XF'
        $rcArgs += $ExcludeFiles
    }
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& robocopy @rcArgs 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
    if ($code -ge 8) {
        $detail = @($output | Where-Object { $_ -match 'ERROR|error|could not|Access is denied' } | Select-Object -First 5)
        if (-not $detail) { $detail = @("no detail; source $Source, destination $Destination") }
        throw "robocopy failed (exit $code) copying $Source to ${Destination}: " + ($detail -join ' | ')
    }
}

function Test-GitWorkTree {
    param([string]$Path)
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $false }
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & git -C $Path rev-parse --is-inside-work-tree 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $saved
    }
}

function Get-TreeSize {
    param([string]$Path)
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return [int64]0 }
    return [int64]$sum
}

# --- defaults ---------------------------------------------------------------
# This script lives at <tree>\installer\windows\, so the tree is two levels up.

if ([string]::IsNullOrWhiteSpace($TreeDir)) {
    $TreeDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$TreeDir = [System.IO.Path]::GetFullPath($TreeDir).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $TreeDir 'dist' }
$OutDir = [System.IO.Path]::GetFullPath($OutDir).TrimEnd('\')

if (-not (Test-Path -LiteralPath (Join-Path $RuntimeDir 'perl\bin\perl.exe'))) {
    throw "RuntimeDir is not a Strawberry Perl tree (no perl\bin\perl.exe): $RuntimeDir"
}
if (-not (Test-Path -LiteralPath (Join-Path $RuntimeDir 'c\bin'))) {
    throw "RuntimeDir is missing c\bin, where Net::SSLeay's DLLs live: $RuntimeDir"
}

$versionPath = Join-Path $TreeDir 'VERSION'
if (-not (Test-Path -LiteralPath $versionPath)) { throw "VERSION not found under $TreeDir" }
$version = (Get-Content -LiteralPath $versionPath -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($version)) { throw "VERSION is empty: $versionPath" }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stage = Join-Path $OutDir "JawnOS-$version"
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('jawnos-build-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    # --- app\ comes from the tree ------------------------------------------
    # A git checkout is archived from HEAD: tracked files only, no .git, no
    # config.json, no database, no untracked leftovers from the build machine.
    # VM200 has no git, and a staged tree is often an extracted archive with no
    # .git at all, so the fallback copies the tree and excludes the same local
    # state by name. Exclusions are relative to the tree root.
    $appDir = Join-Path $stage 'app'
    $appSource = 'plain copy'
    if (Test-GitWorkTree $TreeDir) {
        $appSource = 'git archive'
        $appZip = Join-Path $tmp 'app.zip'
        Write-Host 'Archiving the tracked application tree with git ...'
        & git -C $TreeDir archive --format=zip --prefix=app/ -o $appZip HEAD
        if ($LASTEXITCODE -ne 0) { throw "git archive failed (exit $LASTEXITCODE) in $TreeDir" }
        Expand-Archive -Path $appZip -DestinationPath $stage -Force
    } else {
        Write-Host 'No git work tree here; copying the application tree ...'
        $excludeDirs = @(
            (Join-Path $TreeDir '.git'),
            (Join-Path $TreeDir '.worktrees'),
            (Join-Path $TreeDir 'dist'),
            (Join-Path $TreeDir 'releases'),
            (Join-Path $TreeDir '.shots'),
            (Join-Path $TreeDir 'installer\windows\webview'),
            (Join-Path $TreeDir 'qa\docker'),
            (Join-Path $TreeDir 'desktop\mkosi'),
            'node_modules',
            '__pycache__'
        )
        # Robocopy rejects a wildcard in a full path under /XF ("Invalid
        # Parameter", exit 16), so the database sidecars go in by bare name:
        # jawnos.db-wal, -shm and -journal live only under database\ anyway.
        $excludeFiles = @(
            (Join-Path $TreeDir 'config.json'),
            (Join-Path $TreeDir 'database\jawnos.db'),
            'jawnos.db-*',
            (Join-Path $TreeDir 'server\fullchain.pem'),
            (Join-Path $TreeDir 'server\privkey.pem'),
            '*.pyc',
            '*.log'
        )
        Invoke-Robocopy $TreeDir $appDir -ExcludeDirs $excludeDirs -ExcludeFiles $excludeFiles
    }

    $appFiles = @(Get-ChildItem -LiteralPath $appDir -Recurse -File).Count
    Write-Host "App source: $appSource"
    Write-Host "App payload: $appFiles files"

    # --- runtime\ is the prepared Strawberry tree --------------------------
    Write-Host 'Copying the Perl runtime ...'
    Invoke-Robocopy $RuntimeDir (Join-Path $stage 'runtime')

    # --- runtime\tools is the house's own audio ----------------------------
    # Piper renders the voice; SoX is the house's audio tool. Both are Windows
    # binaries fetched here (or copied from -ToolsDir), so nothing large lives
    # in git and a clean machine still speaks. Pinned checksums mean a changed
    # upstream archive fails the build instead of shipping quietly.
    if (-not $NoTools) {
        $toolsRoot = Join-Path $stage 'runtime\tools'
        New-Item -ItemType Directory -Force -Path $toolsRoot | Out-Null

        function Get-ToolArchive {
            param([string]$Name, [string]$Url, [string]$Sha256)
            $dest = Join-Path $tmp $Name
            $local = if ([string]::IsNullOrWhiteSpace($ToolsDir)) { $null } else { Join-Path $ToolsDir $Name }
            if ($local -and (Test-Path -LiteralPath $local)) {
                Copy-Item -LiteralPath $local -Destination $dest -Force
            } else {
                Write-Host "Downloading $Name ..."
                # curl.exe is the fetch Windows ships. Invoke-WebRequest can be
                # handed a different body by a mirror interstitial, which then
                # fails the checksum; curl gets the same bytes every time.
                $curl = Get-Command curl.exe -ErrorAction SilentlyContinue;
                if ($curl) {
                    & $curl.Source -sSL --fail --retry 2 -o $dest $Url;
                    if ($LASTEXITCODE -ne 0) { throw "curl failed for $Url (exit $LASTEXITCODE)" }
                } else {
                    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $dest
                }
            }
            $hash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLower()
            if ($Sha256 -and $hash -ne $Sha256) {
                throw "$Name checksum mismatch: got $hash, expected $Sha256"
            }
            return $dest
        }

        # Piper 1.2.0 (2023.11.14-2) carries espeak-ng 1.52.0 and its data, so
        # the voice needs no espeak install. The 2023 build reads the voices
        # whose phonemes are one codepoint; the house's own Jonathan fine-tune
        # needs the newer piper, which stays a Linux/phone install.
        $piperZip = Get-ToolArchive 'piper_windows_amd64.zip' `
            'https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_windows_amd64.zip' `
            'f3c58906402b24f3a96d92145f58acba6d86c9b5db896d207f78dc80811efcea'
        $piperTmp = Join-Path $tmp 'piper-expand'
        Expand-Archive -LiteralPath $piperZip -DestinationPath $piperTmp -Force
        $piperSrc = Join-Path $piperTmp 'piper'
        if (-not (Test-Path -LiteralPath (Join-Path $piperSrc 'piper.exe'))) {
            throw "the Piper archive has no piper.exe at $piperSrc"
        }
        Invoke-Robocopy $piperSrc (Join-Path $toolsRoot 'piper')
        $piperOffer = @"
Piper 1.2.0 and the libraries bundled with it come from:
  https://github.com/rhasspy/piper/releases/tag/2023.11.14-2

That release also carries espeak-ng 1.52.0, which is GPL-3.0-or-later.
Its source is:
  https://github.com/espeak-ng/espeak-ng/tree/1.52.0

The GPL-3.0 text is in COPYING beside this file.
"@
        Set-Content -LiteralPath (Join-Path $toolsRoot 'piper\SOURCE.txt') -Value $piperOffer -Encoding ASCII
        $gpl = Join-Path $TreeDir 'docs\licenses\runtime\GPL-3.0.txt'
        if (Test-Path -LiteralPath $gpl) {
            Copy-Item -LiteralPath $gpl -Destination (Join-Path $toolsRoot 'piper\COPYING') -Force
        }

        # SoX 14.4.2 for Windows: the official build. No MP3 decoder, so the
        # house's MP3 chimes keep going to the browser; the synth and any WAV
        # work use this binary.
        $soxZip = Get-ToolArchive 'sox-14.4.2-win32.zip' `
            'https://sourceforge.net/projects/sox/files/sox/14.4.2/sox-14.4.2-win32.zip/download' `
            '8072cc147cf1a3b3713b8b97d6844bb9389e211ab9e1101e432193fad6ae6662'
        $soxTmp = Join-Path $tmp 'sox-expand'
        Expand-Archive -LiteralPath $soxZip -DestinationPath $soxTmp -Force
        $soxSrc = Join-Path $soxTmp 'sox-14.4.2'
        if (-not (Test-Path -LiteralPath (Join-Path $soxSrc 'sox.exe'))) {
            throw "the SoX archive has no sox.exe at $soxSrc"
        }
        Invoke-Robocopy $soxSrc (Join-Path $toolsRoot 'sox')
        $soxOffer = @"
SoX 14.4.2 for Windows comes from:
  https://sourceforge.net/projects/sox/files/sox/14.4.2/

SoX is GPL-2.0; the licence text is LICENSE.GPL.txt beside this file.

This Windows build has no MP3 decoder, so the house's MP3 chimes are played
by the browser, not by SoX.
"@
        Set-Content -LiteralPath (Join-Path $toolsRoot 'sox\SOURCE.txt') -Value $soxOffer -Encoding ASCII

        foreach ($tool in @('piper\piper.exe', 'sox\sox.exe')) {
            if (-not (Test-Path -LiteralPath (Join-Path $toolsRoot $tool))) {
                throw "the tools stage is missing $tool"
            }
        }
        Write-Host 'Bundled Piper and SoX in runtime\tools.'
    } else {
        Write-Warning 'No -NoTools: the bundle has no Piper or SoX, so speech and the synth chime stay silent.'
    }

    # --- the default voice ---------------------------------------------------
    # Piper without a model says nothing. The default is LJSpeech, public
    # domain. The rest arrive by voice_sync from a peer, so a lone machine can
    # start with one voice and grow.
    $voiceSource = $VoiceDir
    if ([string]::IsNullOrWhiteSpace($voiceSource)) { $voiceSource = Join-Path $TreeDir 'voices' }
    $voiceTarget = Join-Path (Join-Path $stage 'app') 'voices'
    if (-not $NoTools -and (Test-Path -LiteralPath $voiceSource)) {
        New-Item -ItemType Directory -Force -Path $voiceTarget | Out-Null
        $defaultStem = 'en_US-ljspeech-medium'
        $copied = $false
        foreach ($suffix in @('.onnx', '.onnx.json')) {
            $from = Join-Path $voiceSource ($defaultStem + $suffix)
            if (Test-Path -LiteralPath $from) {
                Copy-Item -LiteralPath $from -Destination $voiceTarget -Force
                $copied = $true
            }
        }
        $attribution = Join-Path $voiceSource 'ATTRIBUTION.md'
        if (Test-Path -LiteralPath $attribution) {
            Copy-Item -LiteralPath $attribution -Destination $voiceTarget -Force
        }
        if ($copied) {
            Write-Host 'Bundled the default voice (LJSpeech, public domain).'
        } else {
            Write-Warning "no $defaultStem.onnx under $voiceSource; the Windows house starts without a voice."
        }
    } elseif (-not $NoTools) {
        Write-Warning "no voice folder at $voiceSource; the Windows house starts without a voice. Pass -VoiceDir with en_US-ljspeech-medium.onnx{,.json}."
    }

    # --- runtime\python is the desktop shell -------------------------------
    # PySide6's Qt WebEngine is the one UI engine; pythonw.exe runs the shell
    # without a console. Validate the two modules the shell imports before the
    # copy, so a broken PythonDir fails the build rather than the shortcut.
    if (-not [string]::IsNullOrWhiteSpace($PythonDir)) {
        $pythonDir = [System.IO.Path]::GetFullPath($PythonDir).TrimEnd('\')
        foreach ($required in @(
            'python.exe', 'pythonw.exe',
            'Lib\site-packages\PySide6\QtWebEngineCore.pyd',
            'Lib\site-packages\PySide6\QtWebEngineWidgets.pyd')) {
            if (-not (Test-Path -LiteralPath (Join-Path $pythonDir $required))) {
                throw "PythonDir is not a Python + PySide6 tree ($required missing): $pythonDir"
            }
        }
        Write-Host 'Copying the Python/Qt desktop runtime ...'
        Invoke-Robocopy $pythonDir (Join-Path $stage 'runtime\python')
    } else {
        Write-Warning 'No -PythonDir: the bundle has no desktop shell or tray; its shortcut opens the web interface in a browser.'
    }

    # --- the installer scripts and the note a person reads -----------------
    Write-Host 'Copying the installer scripts ...'
    foreach ($name in @('install.ps1', 'Install.bat', 'uninstall.ps1', 'firewall.ps1', 'jawnos.ico')) {
        $from = Join-Path $PSScriptRoot $name
        if (-not (Test-Path -LiteralPath $from)) { throw "missing installer file: $from" }
        Copy-Item -LiteralPath $from -Destination $stage -Force
    }

    # --- webview\ is the Windows shell -------------------------------------
    # A small C# WebView2 window plus tray, compiled here. The SDK DLLs and the
    # native loader travel with it; the Evergreen runtime is the machine's.
    $webview = Join-Path $PSScriptRoot 'webview'
    if (-not (Test-Path -LiteralPath (Join-Path $webview 'JawnOSShell.exe'))) {
        Write-Host 'Building the WebView2 shell ...'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'prepare-webview.ps1')
        if ($LASTEXITCODE -ne 0) { throw "prepare-webview.ps1 failed (exit $LASTEXITCODE)" }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $webview 'JawnOSShell.exe'))) {
        throw "the WebView2 shell was not built at $webview"
    }
    Invoke-Robocopy $webview (Join-Path $stage 'webview')

    $readme = @"
JawnOS $version

This folder is a complete Windows install of JawnOS. You do not need Perl,
Python, WSL or Docker.

INSTALL
  1. Double-click Install.bat.
  2. If Windows SmartScreen warns, choose "More info" then "Run anyway"
     (the installer is not code-signed yet).
  3. Keep the unlock code it shows. It is also saved as
     %LOCALAPPDATA%\JawnOS\unlock-code.txt.
  4. JawnOS opens in its desktop window and tray (WebView2, the same Chromium
     engine the Edge browser uses). The Start menu and desktop shortcuts open
     it, starting JawnOS first if it is not running. It needs the Microsoft
     Edge WebView2 runtime, which Windows 11 ships; without it the shortcut
     opens the interface in your default browser instead. The Startup entry
     only starts the service in the background.

THE UNLOCK CODE
  The six-digit code opens the web interface and is the only key to your
  data. There is no recovery. Write it down.

STOP AND UNINSTALL
  JawnOS keeps running in the background so the web interface stays
  reachable. To stop it, end perl.exe in Task Manager, or uninstall it.
  To remove the install:
      powershell -ExecutionPolicy Bypass -File uninstall.ps1
  Add -PurgeData to also delete the per-user runtime state in
  %USERPROFILE%\.president.

  The web interface is https://127.0.0.1:45545/manager (the port is
  working_port in config.json).
"@
    Set-Content -LiteralPath (Join-Path $stage 'README.txt') -Value $readme -Encoding ASCII

    $payload = Get-TreeSize $stage

    $zipPath = ''
    $zipSize = 0
    if (-not $NoZip) {
        $zipPath = Join-Path $OutDir "JawnOS-$version.zip"
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
        Write-Host 'Compressing ...'
        Compress-Archive -Path $stage -DestinationPath $zipPath -CompressionLevel Optimal
        $zipSize = (Get-Item -LiteralPath $zipPath).Length
    }

    Write-Host ''
    Write-Host "JawnOS $version"
    Write-Host "  payload  $stage"
    Write-Host ("  size     {0:N1} MB ({1} bytes)" -f ($payload / 1MB), $payload)
    if ($zipPath) {
        Write-Host ("  zip      {0} ({1:N1} MB)" -f $zipPath, ($zipSize / 1MB))
    } else {
        Write-Host '  zip      (skipped: -NoZip)'
    }
    Write-Host ''
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}
