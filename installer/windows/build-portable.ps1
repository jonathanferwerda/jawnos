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
# The staged payload is <OutDir>\JawnOS-<version>\ (app\, runtime\ and the
# install scripts). The zip beside it holds that same folder. Nothing is
# signed yet.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RuntimeDir,
    [string]$TreeDir,
    [string]$OutDir,
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
    & robocopy @rcArgs | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed (exit $LASTEXITCODE) copying $Source to $Destination"
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
            (Join-Path $TreeDir 'qa\docker'),
            (Join-Path $TreeDir 'desktop\mkosi\.stage'),
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

    # --- the installer scripts and the note a person reads -----------------
    Write-Host 'Copying the installer scripts ...'
    foreach ($name in @('install.ps1', 'Install.bat', 'uninstall.ps1')) {
        $from = Join-Path $PSScriptRoot $name
        if (-not (Test-Path -LiteralPath $from)) { throw "missing installer file: $from" }
        Copy-Item -LiteralPath $from -Destination $stage -Force
    }

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
  4. JawnOS opens in your browser. A Start menu shortcut is created, and
     JawnOS starts with Windows unless you installed with -NoAutostart.

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
