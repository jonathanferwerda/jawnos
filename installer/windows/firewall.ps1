# JawnOS firewall rule - the one place that names it.
#
# A program-scoped rule for the bundled perl.exe on the private profile. Not a
# port rule: the manager and every worker run from that one image, so LAN
# discovery and peer traffic are allowed for this install only.
#
# install.ps1 calls this during a first run, uninstall.ps1 calls it with
# -Remove, and the Inno Setup wrapper calls it with -Elevate because a per-user
# install has no administrator rights. The self-elevation is deliberate: a
# cancelled UAC prompt leaves the install working locally instead of failing it.

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'JawnOS'),
    [switch]$Remove,
    [switch]$Elevate,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function Note {
    param([string]$Message)
    if (-not $Quiet) { Write-Host $Message }
}

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- optional self-elevation ------------------------------------------------

# The Setup.exe is a per-user install (PrivilegesRequired=lowest), so the rule
# is the only machine-wide step. -Elevate re-runs this script through UAC and
# forwards the verdict. A refusal is a warning, never a failed install.

if ($Elevate -and -not (Test-Elevated)) {
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -InstallDir "' + $InstallDir + '"'
    if ($Remove) { $argLine += ' -Remove' }
    if ($Quiet) { $argLine += ' -Quiet' }
    try {
        $child = Start-Process -FilePath $powershell -ArgumentList $argLine -Verb RunAs -Wait -PassThru -ErrorAction Stop
        exit $child.ExitCode
    } catch {
        if (-not $Quiet) {
            Write-Warning 'Administrator rights were not granted; the JawnOS firewall rule was not changed. JawnOS still works on this machine.'
        }
        exit 1
    }
}

# --- the rule ---------------------------------------------------------------

function Invoke-Netsh {
    param([string[]]$NetshArgs)
    try {
        $proc = Start-Process -FilePath 'netsh.exe' -ArgumentList $NetshArgs -Wait -NoNewWindow -PassThru -ErrorAction Stop
        return $proc.ExitCode
    } catch {
        return 1
    }
}

$ruleName = 'JawnOS'

# Delete first so a reinstall or upgrade replaces the program path instead of
# accumulating a second rule. On -Remove this is the removal.
$deleteCode = Invoke-Netsh @('advfirewall', 'firewall', 'delete', 'rule', "name=$ruleName")

if ($Remove) {
    if ($deleteCode -eq 0) {
        Note 'Removed the JawnOS firewall rule.'
    } else {
        Note 'No JawnOS firewall rule was removed (it may already be gone, or an elevated prompt is needed).'
    }
    exit 0
}

$perl = Join-Path $InstallDir 'runtime\perl\bin\perl.exe'
if (-not (Test-Path -LiteralPath $perl)) {
    throw "The firewall rule needs the bundled perl.exe, and it is missing: $perl"
}

$programArg = 'program="' + $perl + '"'
$code = Invoke-Netsh @(
    'advfirewall', 'firewall', 'add', 'rule', "name=$ruleName", 'dir=in',
    'action=allow', $programArg, 'enable=yes', 'profile=private'
)
if ($code -ne 0) {
    throw "Could not add the JawnOS firewall rule (exit $code). Run from an elevated prompt, or allow perl.exe when Windows asks."
}

Note 'Firewall rule added for the private profile.'
exit 0
