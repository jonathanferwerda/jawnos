# Build the Windows shell: download the Microsoft.Web.WebView2 SDK and compile
# JawnOSShell.cs into webview\JawnOSShell.exe with the .NET Framework compiler.
#
#   powershell -ExecutionPolicy Bypass -File prepare-webview.ps1
#   powershell -ExecutionPolicy Bypass -File prepare-webview.ps1 -Version 1.0.3351.48 -Force
#
# The output folder is gitignored and is staged into the payload as webview\.
# The Evergreen WebView2 Runtime is a prerequisite on the machine (Windows 11
# ships it); the SDK DLLs and WebView2Loader.dll are redistributable.

[CmdletBinding()]
param(
    [string]$Version = '1.0.3351.48',
    [string]$OutDir,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $PSScriptRoot 'webview'
}

$source = Join-Path $PSScriptRoot 'JawnOSShell.cs'
$icon = Join-Path $PSScriptRoot 'jawnos.ico'
$exe = Join-Path $OutDir 'JawnOSShell.exe'

if (-not (Test-Path -LiteralPath $source)) { throw "missing $source" }
if (-not (Test-Path -LiteralPath $icon)) { throw "missing $icon" }

if (-not $Force -and (Test-Path -LiteralPath $exe)) {
    Write-Host "The WebView2 shell is already built: $exe"
    exit 0
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('jawnos-webview-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    $nupkg = Join-Path $tmp 'Microsoft.Web.WebView2.nupkg'
    $zip = Join-Path $tmp 'Microsoft.Web.WebView2.zip'
    $url = "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$Version"
    Write-Host "Downloading $url ..."
    Invoke-WebRequest -Uri $url -OutFile $nupkg -UseBasicParsing
    Copy-Item -LiteralPath $nupkg -Destination $zip -Force
    Expand-Archive -Path $zip -DestinationPath $tmp -Force

    $core = Join-Path $tmp 'lib\net462\Microsoft.Web.WebView2.Core.dll'
    $winforms = Join-Path $tmp 'lib\net462\Microsoft.Web.WebView2.WinForms.dll'
    foreach ($required in @($core, $winforms)) {
        if (-not (Test-Path -LiteralPath $required)) {
            throw "the WebView2 package has no $required"
        }
    }

    $loader = Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'WebView2Loader.dll' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'x64|win-x64' } |
        Select-Object -First 1
    if (-not $loader) {
        throw 'the WebView2 package has no x64 WebView2Loader.dll'
    }

    Copy-Item -LiteralPath $core -Destination (Join-Path $OutDir 'Microsoft.Web.WebView2.Core.dll') -Force
    Copy-Item -LiteralPath $winforms -Destination (Join-Path $OutDir 'Microsoft.Web.WebView2.WinForms.dll') -Force
    Copy-Item -LiteralPath $loader.FullName -Destination (Join-Path $OutDir 'WebView2Loader.dll') -Force

    $csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc)) {
        $csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    }
    if (-not (Test-Path -LiteralPath $csc)) {
        throw 'the .NET Framework C# compiler (csc.exe) is missing'
    }

    Write-Host 'Compiling JawnOSShell.exe ...'
    $args = @(
        '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+',
        ('/out:' + $exe),
        ('/win32icon:' + $icon),
        '/r:System.dll', '/r:System.Core.dll', '/r:System.Drawing.dll',
        '/r:System.Windows.Forms.dll',
        ('/r:' + (Join-Path $OutDir 'Microsoft.Web.WebView2.Core.dll')),
        ('/r:' + (Join-Path $OutDir 'Microsoft.Web.WebView2.WinForms.dll')),
        $source
    )
    & $csc @args
    if ($LASTEXITCODE -ne 0) {
        throw "csc.exe failed (exit $LASTEXITCODE)"
    }
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "csc.exe produced no $exe"
    }

    Write-Host ''
    Write-Host "WebView2 shell: $OutDir"
    Get-ChildItem -LiteralPath $OutDir -File |
        Select-Object Name, Length |
        Format-Table -AutoSize
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}
