package subs;

# Windows self-update: the Windows install is a git-archive copy with no .git,
# so git_watcher_check answers at once and the code watcher can never move it.
# A Windows program updates the way Windows expects: fetch the release
# manifest, download the Setup.exe, verify it, run it silently, and let the
# installer stop the house (PrepareToInstall) and keep config.json and the
# database. One more step is ours: the helper starts the house again with the
# same launch.vbs the shortcuts use, after the installer exits.
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
	my ($man) = @_;
	my $url      = &windows_update_url($man) || '';
	my $sha      = lc($man->{'sha256'} || '');
	my $size     = $man->{'size'} + 0;
	my $filename = $man->{'filename'} || '';

	my $script = <<'POWERSHELL';
# JawnOS Windows self-updater. Written under %TEMP% so replacing the install
# tree cannot delete it. It downloads the release Setup.exe, verifies its size
# and sha256, runs it silently, then starts the house again.
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

	$setupLog = Join-Path $env:TEMP 'jawnos-setup.log'
	Write-UpdateLog 'running the installer'
	$proc = Start-Process -FilePath $setup -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/MERGETASKS=!lanaccess',('/LOG="' + $setupLog + '"') -Wait -PassThru
	Write-UpdateLog ('installer exited ' + $proc.ExitCode)

	$launch = Join-Path $env:LOCALAPPDATA 'JawnOS\launch.vbs'
	if (Test-Path -LiteralPath $launch) {
		Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $launch + '"')
		Write-UpdateLog ('started the house again from ' + $launch)
	}
	else {
		Write-UpdateLog ('launch.vbs not found at ' + $launch)
	}
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
	$script =~ s/__URL__/$quoted_url/;
	$script =~ s/__SHA__/$quoted_sha/;
	$script =~ s/__SIZE__/$size/;
	$script =~ s/__FILENAME__/$quoted_filename/;
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
