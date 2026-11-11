package subs;

# Windows self-update: the Windows install is a git-archive copy with no .git,
# so git_watcher_check answers at once and the code watcher can never move it.
# A Windows program updates the way Windows expects: fetch the release
# manifest, download the Setup.exe, verify it, then hand the install to Inno.
# Inno cannot replace a locked perl.exe, and two masters would fight for the
# ports, so the helper stops the house first - the tree's own killer, then the
# master pid record, both bounded - before it runs the Setup, and starts the
# house again only once the installer has left a working tree. The installer
# keeps config.json and the database.
#
# The helper is a detached PowerShell script written under %TEMP%, outside the
# install tree, so replacing that tree cannot delete the program doing the
# replacing. The 279 MB Setup is downloaded by PowerShell, never held in the
# Perl process's memory.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';

use File::Spec ();
use File::Slurp qw(write_file);

our $config;

# The feed is the Android one's shape, under a fixed tag so the URL never moves:
# https://github.com/<repo>/releases/download/<tag>/windows_release.json
# with the Setup.exe beside it. github_release_manifest already enforces the
# fixed asset URL; this module only judges the product it describes.
sub windows_update_manifest {
	my ($repo, $tag) = @_;
	my $cfg = ref $config eq 'HASH' ? $config : {};
	$repo ||= $cfg->{'github_repo'} || 'jonathanferwerda/jawnos';
	$tag  ||= $cfg->{'github_release_tag'} || 'releases';
	return &subs::github_release_manifest($repo, $tag, 'windows_release.json');
}

# True on a Windows host. Kept as a sub so the route and the tests agree on the
# one platform question (LWP's Win32 branch, not a portable mode setting).
sub windows_platform { return ($^O eq 'MSWin32') ? 1 : 0 }

# versionCode = major * 100000000 + minor * 1000000 + patch, the same shape the
# app store uses. VERSION is "0.1.2727"; a leading v is tolerated, and anything
# unreadable is 0 so a malformed file cannot claim to be newer than everything.
sub windows_version_code {
	my ($version) = @_;
	return 0 unless defined $version && $version =~ /^\s*v?(\d+)\.(\d+)\.(\d+)/;
	return $1 * 100000000 + $2 * 1000000 + $3;
}

# The Setup.exe URL: the manifest's own url, or the asset beside the manifest
# when an older feed omits it. Only github.com is accepted - the helper writes
# this into a PowerShell script, so the same-origin rule that makes the manifest
# trustworthy has to hold for the download too.
sub windows_update_url {
	my ($man) = @_;
	return undef unless $man && ref $man eq 'HASH';
	my $url = $man->{'url'};
	if (!defined $url || !length $url) {
		my $base = $man->{'base'} || '';
		$url = $base . '/' . $man->{'filename'}
			if length $base && defined $man->{'filename'} && length $man->{'filename'};
	}
	return undef unless defined $url && $url =~ m{^https://github\.com/};
	return $url;
}

# A manifest is usable only when it is this product, names this Setup, carries
# a download we can verify, and says a versionCode. The product check is what
# stops an app_release.json (or a future feed for another product) from being
# mistaken for a Windows build.
sub windows_release_valid {
	my ($man) = @_;
	return 0 unless $man && ref $man eq 'HASH';
	return 0 unless ($man->{'product'} || '') eq 'windows';
	my $filename = $man->{'filename'} || '';
	return 0 unless $filename =~ /^JawnOS-\d+\.\d+\.\d+-Setup\.exe$/;
	my $vc = $man->{'versionCode'};
	return 0 unless defined $vc && $vc =~ /^\d+$/ && $vc > 0;
	my $sha = $man->{'sha256'} || '';
	return 0 unless $sha =~ /^[A-Fa-f0-9]{64}$/;
	my $size = $man->{'size'};
	return 0 unless defined $size && $size =~ /^\d+$/ && $size > 0;
	return 0 unless &windows_update_url($man);
	return 1;
}

# The release to offer, or undef. $opts lets a test hand in a manifest and a
# running version instead of reaching the network and reading ./VERSION:
#   manifest => {...}   version => '0.1.2724'
sub windows_release_available {
	my ($opts) = @_;
	$opts ||= {};
	my $man = exists $opts->{'manifest'}
		? $opts->{'manifest'}
		: &windows_update_manifest($opts->{'repo'}, $opts->{'tag'});
	return undef unless &windows_release_valid($man);
	my $running = defined $opts->{'version'} ? $opts->{'version'} : &subs::jawn_version();
	my $running_code = &windows_version_code($running);
	return undef unless ($man->{'versionCode'} + 0) > $running_code;
	my $offer = { %$man };
	$offer->{'running'} = $running;
	$offer->{'runningCode'} = $running_code;
	$offer->{'url'} = &windows_update_url($man);
	return $offer;
}

# One PowerShell single-quoted literal. Values that reach the helper (a URL, a
# filename, a sha, a path) are embedded, not passed through a shell, so a quote
# in one cannot end the string and start a command.
sub _ps_quote {
	my ($value) = @_;
	$value = '' unless defined $value;
	$value =~ s/'/''/g;
	return "'" . $value . "'";
}

# The detached helper. It is a plain script with the manifest's numbers already
# in it, so it does not need Perl, the house, or a readable manifest once the
# install has begun. The placeholders keep Perl from interpolating PowerShell's
# own $variables.
sub windows_update_helper_script {
	my ($man, $opts) = @_;
	$opts ||= {};
	my $url      = &windows_update_url($man) || '';
	my $sha      = lc($man->{'sha256'} || '');
	my $size     = $man->{'size'} + 0;
	my $filename = $man->{'filename'} || '';

	# The install root is the running tree's parent: on a Windows install
	# subs::install_dir() answers the app tree, <root>\app, and launch.vbs and
	# runtime\ sit beside it. An explicit option wins (a caller, or a test that
	# cannot load the tree); when neither answers, the helper falls back to the
	# Setup.exe's own default under %LOCALAPPDATA%.
	my $install_root = '';
	if (defined $opts->{'install_dir'} && length $opts->{'install_dir'}) {
		$install_root = $opts->{'install_dir'};
	}
	else {
		my $tree = eval { &subs::install_dir() };
		if (defined $tree && length $tree) {
			require File::Basename;
			$install_root = File::Basename::dirname($tree);
		}
	}
	$install_root = '' unless defined $install_root;

	my $script = <<'POWERSHELL';
# JawnOS Windows self-updater. Written under %TEMP% so replacing the install
# tree cannot delete it. It downloads the release Setup.exe and verifies its
# size and sha256. Then, in this order: ask the running house to stop and wait
# for the master pid and the ports; terminate the master pid if the polite stop
# did not finish; run the Setup.exe; prove the install left a working tree;
# start the house once from that tree. Every step and its duration is logged.
$ErrorActionPreference = 'Stop'
$log = Join-Path $env:TEMP 'jawnos-update.log'
function Write-UpdateLog([string]$line) {
	$stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
	Add-Content -LiteralPath $log -Value ($stamp + ' ' + $line) -Encoding UTF8
}
$url = __URL__
$wantSha = __SHA__
$wantSize = [int64]__SIZE__
$setup = Join-Path $env:TEMP __FILENAME__
$installed = __INSTALLDIR__

# Never stand in the tree this script is about to replace.
if (Test-Path -LiteralPath $env:TEMP) { Set-Location -LiteralPath $env:TEMP }

function Test-InstallRoot([string]$root) {
	if (-not $root) { return $false }
	return ((Test-Path -LiteralPath (Join-Path $root 'app')) -and
		(Test-Path -LiteralPath (Join-Path $root 'runtime')))
}

# The install the running manager came from; the Setup.exe's own default is the
# fallback, for a helper that cannot answer or a tree that is not an install.
if (-not (Test-InstallRoot $installed)) {
	$installed = Join-Path $env:LOCALAPPDATA 'JawnOS'
}
Write-UpdateLog ('install root: ' + $installed)
$appDir = Join-Path $installed 'app'

function Get-HousePorts {
	$ports = @(3000, 45545)
	$config = Join-Path $appDir 'config.json'
	if (Test-Path -LiteralPath $config) {
		try {
			$cfg = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
			if ($cfg.port) { $ports[0] = [int]$cfg.port }
			if ($cfg.working_port) { $ports[1] = [int]$cfg.working_port }
			if ($cfg.ws_port) { $ports += [int]$cfg.ws_port }
		}
		catch {
			Write-UpdateLog ('could not read the ports from ' + $config + '; using 3000 and 45545')
		}
	}
	return @($ports | Select-Object -Unique)
}

function Get-MasterPid {
	$file = Join-Path $env:USERPROFILE '.president\pid'
	if (-not (Test-Path -LiteralPath $file)) { return 0 }
	$text = Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue
	if (-not $text) { return 0 }
	$text = $text.Trim()
	if ($text -match '^[0-9]+$') { return [int]$text }
	return 0
}

# A recycled pid is not the master: only a perl.exe is worth signalling.
function Get-MasterProcess([int]$masterPid) {
	if ($masterPid -le 0) { return $null }
	$proc = Get-Process -Id $masterPid -ErrorAction SilentlyContinue
	if (-not $proc) { return $null }
	if ($proc.ProcessName -notmatch '^perl') { return $null }
	return $proc
}

function Test-PortBusy([int]$port) {
	$client = $null
	try {
		$client = New-Object System.Net.Sockets.TcpClient
		$task = $client.ConnectAsync('127.0.0.1', $port)
		if (-not $task.Wait(500)) { return $false }
		return $client.Connected
	}
	catch {
		return $false
	}
	finally {
		if ($client) { $client.Close() }
	}
}

function Test-HouseStopped([int]$masterPid, [int[]]$ports) {
	if (Get-MasterProcess $masterPid) { return $false }
	foreach ($port in $ports) {
		if (Test-PortBusy $port) { return $false }
	}
	return $true
}

function Wait-HouseStopped([int]$masterPid, [int[]]$ports, [int]$seconds) {
	$deadline = (Get-Date).AddSeconds($seconds)
	while ((Get-Date) -lt $deadline) {
		if (Test-HouseStopped $masterPid $ports) { return $true }
		Start-Sleep -Milliseconds 250
	}
	return (Test-HouseStopped $masterPid $ports)
}

# config.json and the database are what the installer seeds and what the house
# needs to boot; perl.exe is the runtime it runs on. All three, or no start.
function Test-InstallTree([string]$root) {
	if (-not $root) { return $false }
	$app = Join-Path $root 'app'
	$perl = Join-Path $root 'runtime\perl\bin\perl.exe'
	$config = Join-Path $app 'config.json'
	$db = Join-Path $app 'database\jawnos.db'
	return ((Test-Path -LiteralPath $perl) -and
		(Test-Path -LiteralPath $config) -and
		(Test-Path -LiteralPath $db))
}

try {
	Write-UpdateLog ('downloading ' + $url)
	$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
	if ($curl) {
		& $curl.Source -L --fail --silent --show-error -o $setup $url
		if ($LASTEXITCODE -ne 0) { throw ('curl exited ' + $LASTEXITCODE) }
	}
	else {
		Invoke-WebRequest -Uri $url -OutFile $setup -UseBasicParsing
	}
	$item = Get-Item -LiteralPath $setup
	if ($item.Length -ne $wantSize) {
		throw ('size mismatch: got ' + $item.Length + ', want ' + $wantSize)
	}
	$gotSha = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()
	if ($gotSha -ne $wantSha) {
		throw ('sha256 mismatch: got ' + $gotSha)
	}
	Write-UpdateLog ('verified ' + $item.Length + ' bytes, sha256 ' + $gotSha)

	# --- stop the house, and prove it is gone -------------------------------
	# Inno cannot replace a locked perl.exe, and a second master would fight for
	# the ports. The tree's own killer knows the master, the workers and the
	# port; the pid record is the fallback when the runtime cannot run it.
	$masterPid = Get-MasterPid
	$ports = @(Get-HousePorts)
	$perl = Join-Path $installed 'runtime\perl\bin\perl.exe'
	$killer = Join-Path $appDir 'scripts\manager_killer.pl'
	$stopStarted = Get-Date
	if ((Test-Path -LiteralPath $perl) -and (Test-Path -LiteralPath $killer)) {
		Write-UpdateLog ('asking the house to stop (master pid ' + $masterPid + ', ports ' + ($ports -join ', ') + ')')
		Push-Location -LiteralPath $appDir
		try {
			$env:JAWNOS_PORTABLE = '1'
			$env:JAWNOS_TRANSPORT = 'tcp'
			$env:JAWNOS_DIR = $appDir
			$env:PATH = "$installed\runtime\c\bin;$installed\runtime\perl\bin;$env:PATH"
			$saved = $ErrorActionPreference
			$ErrorActionPreference = 'Continue'
			try {
				& $perl 'scripts\manager_killer.pl' 'master' 2>&1 | Out-Null
				Write-UpdateLog ('manager_killer exited ' + $LASTEXITCODE)
			}
			catch {
				Write-UpdateLog ('manager_killer did not run: ' + $_.Exception.Message)
			}
			finally {
				$ErrorActionPreference = $saved
			}
		}
		finally {
			Pop-Location
		}
	}
	else {
		Write-UpdateLog ('no bundled killer at ' + $killer + '; using the master pid record')
	}

	$stopped = Wait-HouseStopped $masterPid $ports 30
	Write-UpdateLog ('waited for master pid ' + $masterPid + ' and ports ' + ($ports -join ', ') + ': stopped=' + $stopped + ' after ' + [math]::Round(((Get-Date) - $stopStarted).TotalSeconds, 1) + 's')

	if (-not $stopped -and (Get-MasterProcess $masterPid)) {
		Write-UpdateLog ('the polite stop did not finish; terminating master pid ' + $masterPid)
		try {
			Stop-Process -Id $masterPid -Force
		}
		catch {
			Write-UpdateLog ('could not terminate pid ' + $masterPid + ': ' + $_.Exception.Message)
		}
		$stopped = Wait-HouseStopped $masterPid $ports 10
		Write-UpdateLog ('after the forced stop: stopped=' + $stopped + ' after ' + [math]::Round(((Get-Date) - $stopStarted).TotalSeconds, 1) + 's')
	}
	if (-not $stopped) {
		# A tree that will not leave must not wedge the update: the installer
		# runs against it and the result is recorded, not guessed at.
		Write-UpdateLog 'warning: the house did not stop; the installer will run against a tree still in use'
	}

	# --- install, then prove the tree ---------------------------------------
	$setupLog = Join-Path $env:TEMP 'jawnos-setup.log'
	Write-UpdateLog ('running the installer ' + $setup)
	$installStarted = Get-Date
	$proc = Start-Process -FilePath $setup -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/MERGETASKS=!lanaccess',('/LOG="' + $setupLog + '"') -Wait -PassThru
	$installSeconds = [math]::Round(((Get-Date) - $installStarted).TotalSeconds, 1)
	Write-UpdateLog ('installer exited ' + $proc.ExitCode + ' after ' + $installSeconds + 's')
	if ($proc.ExitCode -ne 0) {
		throw ('the installer failed with exit code ' + $proc.ExitCode + ' after ' + $installSeconds + 's; see ' + $setupLog)
	}

	$root = $installed
	if (-not (Test-InstallTree $root)) {
		$fallback = Join-Path $env:LOCALAPPDATA 'JawnOS'
		if (($fallback -ne $root) -and (Test-InstallTree $fallback)) {
			Write-UpdateLog ('the install is at ' + $fallback + ', not ' + $root)
			$root = $fallback
		}
		else {
			throw ('the installer did not produce a working tree at ' + $root + '; config.json, the database and perl.exe are required')
		}
	}
	Write-UpdateLog ('install verified at ' + $root)

	# --- start the house exactly once ---------------------------------------
	$launch = Join-Path $root 'launch.vbs'
	if (-not (Test-Path -LiteralPath $launch)) {
		$fallback = Join-Path (Join-Path $env:LOCALAPPDATA 'JawnOS') 'launch.vbs'
		if (Test-Path -LiteralPath $fallback) { $launch = $fallback }
	}
	if (-not (Test-Path -LiteralPath $launch)) {
		throw ('the install has no launch.vbs at ' + $launch + '; the house was not started')
	}
	Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $launch + '"')
	Write-UpdateLog ('started the house again from ' + $launch)
	exit 0
}
catch {
	Write-UpdateLog ('failed: ' + $_.Exception.Message)
	exit 1
}
POWERSHELL

	my $quoted_url      = &_ps_quote($url);
	my $quoted_sha      = &_ps_quote($sha);
	my $quoted_filename = &_ps_quote($filename);
	my $quoted_install  = &_ps_quote($install_root);
	$script =~ s/__URL__/$quoted_url/;
	$script =~ s/__SHA__/$quoted_sha/;
	$script =~ s/__SIZE__/$size/;
	$script =~ s/__FILENAME__/$quoted_filename/;
	$script =~ s/__INSTALLDIR__/$quoted_install/;
	return $script;
}

# Where the helper lives. %TEMP% is the per-user temp folder on Windows; TMP is
# its older spelling. On a host without either, File::Spec names the platform's
# temp root. A path from the manifest is never used here - only a fixed name.
sub windows_update_temp_dir {
	my ($opts) = @_;
	$opts ||= {};
	my $dir = $opts->{'temp'};
	$dir = $ENV{'TEMP'} if !defined $dir || !length $dir;
	$dir = $ENV{'TMP'}  if !defined $dir || !length $dir;
	$dir = File::Spec->tmpdir if !defined $dir || !length $dir;
	return $dir;
}

# The PowerShell that ships with Windows. The full path avoids a PATH lookup
# picking up a shim; the bare name is the fallback for a host whose SystemRoot
# is not set.
sub windows_powershell_path {
	my $root = $ENV{'SystemRoot'} || $ENV{'WINDIR'} || 'C:\\Windows';
	my $path = File::Spec->catfile($root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
	return -f $path ? $path : 'powershell.exe';
}

# Start the updater. Returns {ok, version, log} or {ok => 0, error}. The
# manifest download is small and stays here; the Setup is fetched by the
# helper, so the manager never buffers 279 MB.
sub windows_update_start {
	my ($opts) = @_;
	$opts ||= {};
	return { ok => 0, error => 'not this platform' } unless &windows_platform();

	my $man = $opts->{'manifest'} || &windows_release_available($opts);
	return { ok => 0, error => 'no newer release' } unless $man;

	my $temp = &windows_update_temp_dir($opts);
	unless (defined $temp && length $temp && -d $temp) {
		return { ok => 0, error => 'no writable temp folder' };
	}

	require File::Temp;
	my ($fh, $script_path) = File::Temp::tempfile(
		'jawnos-update-XXXXXX', DIR => $temp, SUFFIX => '.ps1', UNLINK => 0);
	unless ($script_path) {
		return { ok => 0, error => 'could not write the update helper' };
	}
	close $fh if $fh;
	write_file($script_path, &windows_update_helper_script($man));

	my $log = File::Spec->catfile($temp, 'jawnos-update.log');
	my $powershell = &windows_powershell_path();
	my $argument = &_ps_quote('"' . $script_path . '"');
	# Start-Process gives the helper its own hidden console. The outer
	# PowerShell only starts it, so the house being stopped a moment later
	# cannot take the helper with it.
	my $command = 'Start-Process -FilePath ' . &_ps_quote($powershell)
		. " -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"
		. $argument . ' -WindowStyle Hidden';
	my $ok = eval {
		system(1, $powershell, '-NoProfile', '-ExecutionPolicy', 'Bypass',
			'-WindowStyle', 'Hidden', '-Command', $command);
		1;
	};
	unless ($ok) {
		return { ok => 0, error => 'could not start the update helper' };
	}
	return { ok => 1, version => $man->{'version'}, log => $log };
}

1;
