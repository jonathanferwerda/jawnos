#!/usr/bin/perl
#
# JawnOS dependency checker / installer.
#
#   perl scripts/jawnos_deps.pl            # report, then offer to install
#   perl scripts/jawnos_deps.pl --report   # report only, exit 1 if anything is missing
#   perl scripts/jawnos_deps.pl --json     # machine-readable status
#   perl scripts/jawnos_deps.pl --sh       # print the install commands as a shell script
#   perl scripts/jawnos_deps.pl --install  # install without prompting
#   perl scripts/jawnos_deps.pl --desktop  # also check/install the desktop app's
#                                          # WebKitGTK + GStreamer media packages
#                                          # and a colour emoji font (optional:
#                                          # their absence is not fatal)
#   perl scripts/jawnos_deps.pl --extras-only --install  # only the optional apps
#                                          # (Piper); run after a code update
#   perl scripts/jawnos_deps.pl --local-lib DIR --install
#                                          # install missing modules into DIR
#                                          # (a local::lib, e.g. ~/perl5) as the
#                                          # current user; never runs sudo
#   perl scripts/jawnos_deps.pl --no-extras # skip the optional apps
#
# Freshness (no install, no download): does upstream still offer what the
# installer asks for, and is an installed copy far behind?
#   perl scripts/jawnos_deps.pl --freshness          # metadata only; exit 1 if
#                                                    # anything is missing
#   perl scripts/jawnos_deps.pl --freshness --desktop  # include the desktop
#                                                    # app's packages
#   perl scripts/jawnos_deps.pl --freshness --strict # also fail on outdated
#   perl scripts/jawnos_deps.pl --freshness --json   # machine-readable
#   perl scripts/jawnos_deps.pl --freshness --only=NAME  # one name (repeatable)
#   perl scripts/jawnos_deps.pl --freshness --fixtures=DIR  # offline, canned
#   perl scripts/jawnos_deps.pl --freshness --android      # also the Android
#                                                    # SDK/NDK components
#
# --freshness asks MetaCPAN, Debian's madison and Arch's package API for the
# candidate version and compares it with what is installed here. It downloads
# no package, tarball or distribution and runs no `apt-get update`/`pacman -Sy`:
# the whole check is a few kilobytes per name, so it is safe to run nightly
# against upstream hosts that pay for their bandwidth.
#
# It also reports which key-derivation features OpenSSL offers (Argon2id,
# scrypt). Those are never fatal: a recovery share falls back and records the
# KDF it used, so an older OpenSSL on a phone still works.
#
# Deliberately uses only core Perl so it runs before any CPAN module is present.

use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use JSON::PP ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use JawnOS::Packages;

my ($report_only, $json, $sh, $install, $yes, $desktop, $extras_only, $no_extras, $local_lib, $freshness, $strict, $fixtures, $android);
my @only;
GetOptions(
	'report'      => \$report_only,
	'json'        => \$json,
	'sh'          => \$sh,
	'install'     => \$install,
	'yes|y'       => \$yes,
	'desktop'     => \$desktop,
	'extras-only' => \$extras_only,
	'no-extras'   => \$no_extras,
	'local-lib=s' => \$local_lib,
	'freshness'   => \$freshness,
	'strict'      => \$strict,
	'fixtures=s'  => \$fixtures,
	'android'     => \$android,
	'only=s@'     => \@only,
) or die "bad options\n";

$install = 1 if $yes;

# Arch keeps cpanm in /usr/bin/vendor_perl, which is not on a login PATH and is
# certainly not on a systemd service's; the update path has modules to install
# and must be able to find it. PATH is only used for command lookup here.
$ENV{'PATH'} = join(':', grep { defined && length } $ENV{'PATH'}, '/usr/bin/vendor_perl');

# --local-lib is the self-update path: a person installing only for themselves,
# into the local::lib `jawn` already puts on @INC. The modules there count as
# present for the checks, and the arch subdirectories match what jawn adds.
if (defined $local_lib && length $local_lib) {
	my $base = "$local_lib/lib/perl5";
	my @dirs = ($base);
	if (opendir(my $dh, $base)) {
		for my $name (sort readdir $dh) {
			next if $name eq '.' || $name eq '..';
			my $dir = "$base/$name";
			push @dirs, $dir if -d $dir && ($name =~ /-linux-/ || $name =~ /-linux$/ || $name =~ /^[0-9]+\.[0-9]+/);
		}
		closedir $dh;
	}
	unshift @INC, @dirs;
	my $lib = join ':', @dirs;
	$ENV{'PERL5LIB'} = $ENV{'PERL5LIB'} ? "$lib:$ENV{'PERL5LIB'}" : $lib;
}

my $platform = detect_platform();

# The app's own runtime (docs/roadmap-handoff.md M3) already carries every
# module and tool the tree loads, and it has no package manager at all: the
# app writes this marker when it unpacks the archive, and an install is then a
# no-op rather than a `pkg` call that cannot exist. Piper (the one extra) ships
# as TextToSpeech through the device bridge on such a device.
my $runtime_marker = ($ENV{'PREFIX'} || '') . '/etc/jawnos-runtime.json';
if ($install && -f $runtime_marker) {
	my $version = '?';
	if (open(my $rf, '<', $runtime_marker)) {
		local $/;
		my $text = <$rf>;
		close $rf;
		($version) = $text =~ /"version"\s*:\s*"([^"]*)"/;
		$version = '?' unless defined $version && length $version;
	}
	print "JawnOS runtime $version supplies every module and tool; nothing to install.\n";
	exit 0;
}

# --- optional applications (extras) -----------------------------------------
# Tools JawnOS wants that are not a distribution package, so the installer
# fetches them itself. Idempotent (present => skipped) and non-fatal (a device
# that cannot install one keeps working with its fallback). Piper is the first;
# add another by pushing one more row. `--extras-only` is what the update hook
# runs, so a new version's new app lands without a hand.
my $home = $ENV{'HOME'} || (getpwuid $<)[7] || '';
my $piper_dir = "$home/.local/share/jawnos/piper";
my @extras = (
	{ id => 'piper', label => 'Piper TTS (natural voice)', check => \&have_piper, install => \&install_piper },
);

if ($extras_only) {
	my @want = grep { !$_->{'check'}->() } @extras;
	if (!@want) { print "Optional applications: all present.\n"; exit 0; }
	print "Optional applications missing:\n";
	print "  - " . $_->{'label'} . "\n" for @want;
	exit 1 if $report_only;
	unless ($install) {
		print "\nInstall them now? [Y/n] ";
		my $a = <STDIN>; $a = 'y' if !defined $a;
		exit 1 if $a =~ /^n/i;
	}
	foreach my $e (@want) { $e->{'install'}->(); }
	exit( (grep { !$_->{'check'}->() } @want) ? 1 : 0 );
}

# --- required command line tools --------------------------------------------
# command => { apt => pkg, pacman => pkg, termux => pkg, label => "..." }
my @tools = (
	{ cmd => 'perl',      apt => 'perl',             pacman => 'perl',           termux => 'perl',             label => 'Perl' },
	{ cmd => 'openssl',   apt => 'openssl',          pacman => 'openssl',        termux => 'openssl',          label => 'OpenSSL' },
	{ cmd => 'sqlite3',   apt => 'sqlite3',          pacman => 'sqlite',         termux => 'sqlite',           label => 'SQLite' },
	{ cmd => 'argon2',    apt => 'argon2',           pacman => 'argon2',         termux => 'argon2',           label => 'argon2 (recovery KDF)' },
	{ cmd => 'curl',      apt => 'curl',             pacman => 'curl',           termux => 'curl',             label => 'curl' },
	{ cmd => 'ssh',       apt => 'openssh-client',   pacman => 'openssh',        termux => 'openssh',          label => 'OpenSSH' },
	{ cmd => 'sshpass',   apt => 'sshpass',          pacman => 'sshpass',        termux => 'sshpass',          label => 'sshpass' },
	{ cmd => 'autossh',   apt => 'autossh',          pacman => 'autossh',        termux => 'autossh',          label => 'autossh' },
	{ cmd => 'rsync',     apt => 'rsync',            pacman => 'rsync',          termux => 'rsync',            label => 'rsync' },
	{ cmd => 'ffmpeg',    apt => 'ffmpeg',           pacman => 'ffmpeg',         termux => 'ffmpeg',           label => 'FFmpeg' },
	{ cmd => 'convert',   apt => 'imagemagick',      pacman => 'imagemagick',    termux => 'imagemagick',      label => 'ImageMagick' },
	{ cmd => 'tesseract', apt => 'tesseract-ocr',    pacman => 'tesseract',      termux => 'tesseract',        label => 'Tesseract OCR' },
	{ cmd => 'qrencode',  apt => 'qrencode',         pacman => 'qrencode',       termux => 'libqrencode',      label => 'qrencode' },
	{ cmd => 'zbarimg',   apt => 'zbar-tools',       pacman => 'zbar',           termux => 'zbar',             label => 'zbar' },
	{ cmd => 'espeak',    apt => 'espeak',           pacman => 'espeak-ng',      termux => 'espeak',           label => 'espeak', alt => 'espeak-ng' },
	{ cmd => 'sox',       apt => 'sox',              pacman => 'sox',            termux => 'sox',              label => 'SoX' },
	{ cmd => 'zip',       apt => 'zip',              pacman => 'zip',            termux => 'zip',              label => 'zip' },
	{ cmd => 'tmux',      apt => 'tmux',             pacman => 'tmux',           termux => 'tmux',             label => 'tmux' },
	{ cmd => 'cpanm',     apt => 'cpanminus',        pacman => 'cpanminus',      termux => 'perl',             label => 'cpanminus', cpanm => 'App::cpanminus' },
	{ cmd => 'git',       apt => 'git',              pacman => 'git',            termux => 'git',              label => 'git' },
	{ cmd => 'node',      apt => 'nodejs',           pacman => 'nodejs',         termux => 'nodejs',           label => 'Node.js', alt => 'nodejs' },
);

# --- required perl modules ---------------------------------------------------
my @modules = qw(
	Mojolicious::Lite
	Mojo::SQLite
	Minion
	Minion::Backend::SQLite
	Mojo::IOLoop::ReadWriteFork
	Sereal::Encoder
	Sereal::Decoder
	Crypt::Simple
	CryptX
	Crypt::KeyDerivation
	Crypt::AuthEnc::GCM
	Crypt::PK::X25519
	Crypt::PK::Ed25519
	Crypt::PRNG
	Digest::SHA
	Math::BigInt
	Net::SSLeay
	WWW::Mechanize
	Time::Piece
	Time::Duration
	Date::Parse
	Hash::Merge
	Encode
	File::Slurp
	Number::Format
	SQL::Abstract
	Data::UUID
	Mojolicious::Plugin::RenderFile
	LWP::UserAgent
	LWP::Protocol::https
	File::Type
	HTML::Strip
	URI::Encode
	URI::Escape
	Net::IMAP::Client
	MIME::Parser
	Email::Stuffer
	Authen::SASL
);

# --- capabilities (features, not packages) -----------------------------------
# What the house-key work prefers is a feature of OpenSSL, not a new module or
# another package to install. These are reported, never fatal: the recovery
# share falls back to scrypt and then to PBKDF2, so an older Termux OpenSSL
# still works, and the blob records the KDF that sealed it. Nothing here asks
# for libsodium: the Ed25519 -> X25519 conversion is plain Perl on top of
# CryptX, so it installs anywhere CryptX does.
my @capabilities = (
	{
		id       => 'argon2id',
		label    => 'Argon2id key derivation (OpenSSL 3.2+ or the argon2 tool)',
		check    => sub { perl_kdf('argon2id') },
		fallback => 'scrypt, then PBKDF2 at 600k',
	},
	{
		id       => 'scrypt',
		label    => 'scrypt key derivation',
		check    => sub { perl_kdf('scrypt') },
		fallback => 'PBKDF2 at 600k',
	},
);

	sub perl_kdf {
		my ($kind) = @_;
		return 0 unless have_module('Crypt::KeyDerivation');
		# the smallest parameters that still exercise the KDF: this is a capability
		# probe, not a password hash, and it must stay fast on a phone
		if ($kind eq 'argon2id') {
			my $call = 'Crypt::KeyDerivation::argon2_pbkdf("argon2id", "p", "s", 1, 8, 1, 8, "", "")';
			my $out = `perl -MCrypt::KeyDerivation -e '$call; print "ok"' 2>/dev/null`;
			return 1 if defined $out && $out eq 'ok';
			# the reference tool, for an OpenSSL older than 3.2: same parameters,
			# same bytes (the app's probe asserts the two agree)
			my $cli = which('argon2') ? `printf p | argon2 s -id -t 1 -m 3 -p 1 -l 8 -r 2>/dev/null` : '';
			return 1 if defined $cli && length $cli;
			return 0;
		}
		my $call = 'Crypt::KeyDerivation::scrypt_pbkdf("p", "s", 16, 1, 1, 8)';
		my $out = `perl -MCrypt::KeyDerivation -e '$call; print "ok"' 2>/dev/null`;
		return (defined $out && $out eq 'ok') ? 1 : 0;
	}

# --- desktop extras (opt-in: --desktop) -------------------------------------
# The Linux desktop app's embedded view needs WebKitGTK, it decodes media
# through system GStreamer (without a VA-API plugin, HD video is software-
# decoded and choppy), and Chat draws SMS emoji with a colour emoji font. These
# are optional -- a headless server or the phone does not need them -- so a
# missing extra never fails the check. They are only checked where there is a
# desktop and a package manager to install them.
my @desktop = (
	{ label => 'WebKitGTK 4.1 (embedded view)', check => \&have_webkit,
	  apt => 'gir1.2-webkit2-4.1', pacman => 'webkit2gtk-4.1', termux => '' },
	{ label => 'GStreamer VA-API plugin (GPU video decode)', check => \&have_gst_va,
	  apt => 'gstreamer1.0-vaapi', pacman => 'gst-plugin-va', termux => '' },
	{ label => 'GStreamer tools', check => \&have_gst_tools,
	  apt => 'gstreamer1.0-tools', pacman => 'gstreamer', termux => '' },
	{ label => 'Colour emoji font (Chat, SMS and the interface)', check => \&have_emoji_font,
	  apt => 'fonts-noto-color-emoji', pacman => 'noto-fonts-emoji', termux => '' },
);

# --- checks ------------------------------------------------------------------
sub which {
	my $cmd = shift;
	my $path = `command -v $cmd 2>/dev/null`;
	chomp $path;
	return $path;
}

sub have_command {
	my $t = shift;
	return 1 if which($t->{'cmd'});
	return 1 if $t->{'alt'} && which($t->{'alt'});
	return 0;
}

# --- extras: checks and installers ------------------------------------------
sub have_piper {
	return 1 if which('piper');
	return 1 if -x "$piper_dir/piper";
	return 0;
}

sub piper_arch {
	my $m = `uname -m`; chomp $m;
	return 'x86_64'  if $m =~ /^(x86_64|amd64)$/;
	return 'aarch64' if $m =~ /^(aarch64|arm64)$/;
	return '';
}

sub install_piper {
	my $arch = piper_arch();
	if (!$arch) {
		print "  piper: no prebuilt binary for this architecture; skipping.\n";
		return;
	}
	if ($platform eq 'termux') {
		# Termux is bionic, so it cannot run the glibc build directly: glibc-runner
		# (from the glibc-repo / tur-repo) is the launcher say_piper_argv uses. The
		# Python piper-tts builds but ships without its espeakbridge extension there.
		run('pkg', 'install', '-y', 'glibc-repo');
		run('pkg', 'install', '-y', 'glibc-runner');
	}
	system('mkdir', '-p', $piper_dir);
	my $url = "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_$arch.tar.gz";
	# a writable scratch dir: /tmp is not writable on a Termux/Android host, where
	# TMPDIR points into the prefix. Downloading to /tmp there failed with
	# "Permission denied" and left the fallback in place forever.
	my $tmp_dir = ($ENV{'TMPDIR'} && -d $ENV{'TMPDIR'} && -w $ENV{'TMPDIR'}) ? $ENV{'TMPDIR'} : '/tmp';
	$tmp_dir = $piper_dir unless -w $tmp_dir;
	my $tmp = "$tmp_dir/jawnos_piper_$$.tgz";
	if (run('curl', '-L', '--fail', '-o', $tmp, $url) != 0) {
		print "  piper: download failed; leaving the fallback in place.\n";
		return;
	}
	if (run('tar', 'xzf', $tmp, '-C', $piper_dir, '--strip-components=1') != 0) {
		print "  piper: extract failed.\n";
		unlink $tmp;
		return;
	}
	unlink $tmp;
	print "  piper: installed to $piper_dir\n" if -x "$piper_dir/piper";
	print "  piper: installed (no binary produced?)\n" unless -x "$piper_dir/piper";
}

# --- desktop extra probes ----------------------------------------------------
sub have_webkit {
	my $py = which('python3') || which('python');
	return 0 unless $py;
	my $code = 'import gi; gi.require_version("WebKit2", "4.1")';
	return system("$py -c '$code' >/dev/null 2>&1") == 0 ? 1 : 0;
}

sub have_gst_tools {
	return which('gst-inspect-1.0') ? 1 : 0;
}

sub have_gst_va {
	return 0 unless have_gst_tools();
	# 'vaapi' is the older plugin name, 'va' the newer one; either means GPU decode.
	return 1 if system('gst-inspect-1.0 vaapi >/dev/null 2>&1') == 0;
	return 1 if system('gst-inspect-1.0 va >/dev/null 2>&1') == 0;
	return 0;
}

# A colour emoji font is what draws Chat's SMS emoji, the emoji picker and every
# emoji in the interface. Fontconfig knows every installed face and an emoji
# family always says "Emoji" in its name; the file globs cover a stale cache or a
# fontconfig that is not installed at all.
sub have_emoji_font {
	my $out = `fc-list 2>/dev/null`;
	return 1 if defined $out && $out =~ /emoji/i;
	my $home = $ENV{'HOME'} || '';
	foreach my $pat ( "$home/.local/share/fonts/*Emoji*", '/usr/share/fonts/*/*Emoji*', '/usr/share/fonts/*/*/*Emoji*' ) {
		my @hit = glob($pat);
		return 1 if scalar @hit;
	}
	return 0;
}

sub have_module {
	my $m = shift;
	my $ok = system("perl", "-M$m", "-e1", "2>/dev/null") == 0 ? 1 : 0;
	return $ok;
}

sub detect_platform {
	# M4: the app is com.jawnos; com.termux is the old fork, still accepted so a
	# device on the older build keeps working.
	return 'termux' if $ENV{'TERMUX_VERSION'} || -d '/data/data/com.jawnos' || -d '/data/data/com.termux';
	return 'debian' if -x '/usr/bin/apt-get' || -x '/usr/bin/apt';
	return 'arch'   if -x '/usr/bin/pacman';
	return 'unknown';
}

# --- freshness: availability and versions, metadata only --------------------
# The install lists above are the contract: every module in @modules and every
# package in @tools/@desktop must still be offered by CPAN, Debian and Arch, and
# an installed package should not be behind its candidate. All requests are
# small JSON/text metadata (MetaCPAN, Debian madison, archlinux.org); nothing is
# downloaded, installed, `apt-get update`d or `pacman -Sy`d.

# An absent package is the normal answer to this question, and every one of
# `perl -M`, `dpkg-query` and `pacman -Q` explains the absence on stderr. The
# report prints the row itself, so the explanation is suppressed: a nightly log
# with one CPAN or dpkg complaint per absent package buries the result.
sub query_first_line {
	my (@cmd) = @_;
	my $pid = open(my $fh, '-|');
	return (undef, 1) unless defined $pid;
	if (!$pid) {
		open STDERR, '>', '/dev/null';
		exec @cmd;
		exit 127;
	}
	my $value = <$fh>;
	close $fh;
	return ($value, $?);
}

sub module_version {
	my ($module) = @_;
	my $code = 'no strict "refs"; print ${"' . $module . '::VERSION"} // "";';
	my ($value, $status) = query_first_line('perl', "-M$module", '-e', $code);
	return undef if $status != 0;
	$value = '' unless defined $value;
	$value =~ s/\s+//g;
	return length $value ? $value : '';
}

sub module_is_core {
	my ($module) = @_;
	return 0 unless eval { require Module::CoreList; 1 };
	return Module::CoreList::is_core($module, $]) ? 1 : 0;
}

sub dpkg_version {
	my ($package) = @_;
	return undef unless which('dpkg-query');
	my ($value, $status) = query_first_line('dpkg-query', '-W', '-f=${Version}', $package);
	return undef if $status != 0;
	$value = '' unless defined $value;
	$value =~ s/\s+//g;
	return length $value ? $value : undef;
}

sub pacman_version {
	my ($package) = @_;
	return undef unless which('pacman');
	my ($line, $status) = query_first_line('pacman', '-Q', $package);
	return undef if $status != 0;
	my (undef, $version) = split /\s+/, (defined $line ? $line : '');
	return defined $version && length $version ? $version : undef;
}

sub debian_lt {
	my ($installed, $latest) = @_;
	return undef unless defined $installed && defined $latest;
	return undef unless which('dpkg');
	my $rc = system('dpkg', '--compare-versions', $installed, 'lt', $latest);
	return undef if $rc == -1 || $rc == 2 || ($rc >> 8) > 1;
	return (($rc >> 8) == 0) ? 1 : 0;
}

sub arch_lt {
	my ($installed, $latest) = @_;
	return undef unless defined $installed && defined $latest;
	my $vercmp = which('vercmp');
	return JawnOS::Packages::compare_arch($installed, $latest) < 0 ? 1 : 0
		unless $vercmp;
	open(my $fh, '-|', $vercmp, $installed, $latest) or return undef;
	my $value = <$fh>;
	close $fh;
	return undef if $? != 0;
	$value = '' unless defined $value;
	$value =~ s/\s+//g;
	return undef unless $value =~ /^-?\d+$/;
	return $value < 0 ? 1 : 0;
}

# A fixture run describes a whole simulated host, so the installed version
# comes from the fixture tree too (an absent file means "not installed here").
# That keeps the test deterministic on any machine instead of reading whatever
# this box happens to have. The ecosystem is part of the name: Debian `tmux`
# and Arch `tmux` are different installed versions.
sub fixture_version {
	my ($fixtures, $kind, $key) = @_;
	return undef unless defined $fixtures && length $fixtures;
	(my $safe = $key) =~ s/[^A-Za-z0-9_.-]/_/g;
	my $path = "$fixtures/installed_${kind}_$safe.txt";
	return undef unless -e $path;
	open(my $fh, '<', $path) or return undef;
	my $value = <$fh>;
	close $fh;
	return undef unless defined $value;
	$value =~ s/\s+//g;
	return length $value ? $value : undef;
}

sub sdk_root {
	for my $candidate ($ENV{'ANDROID_SDK_ROOT'}, $ENV{'ANDROID_HOME'},
		($ENV{'HOME'} || '') . '/android-sdk') {
		next unless defined $candidate && length $candidate;
		return $candidate if -d $candidate;
	}
	return undef;
}

# The SDK components this machine has, as the package ids sdkmanager uses
# (`platforms;android-36`, `build-tools;36.0.0`, `ndk;22.1.7171670`, ...). The
# directory layout is the id with the `;` replaced by a `/`. A fixture run
# reads a list instead, so the test does not depend on the SDK here.
sub sdk_components {
	my ($fixtures) = @_;
	if (defined $fixtures && length $fixtures) {
		my $path = "$fixtures/sdk_installed.txt";
		return () unless -e $path;
		open(my $fh, '<', $path) or return ();
		my @list;
		while (my $line = <$fh>) {
			$line =~ s/^\s+|\s+$//g;
			next unless length $line && $line !~ /^#/;
			push @list, $line;
		}
		close $fh;
		return @list;
	}
	my $root = sdk_root();
	return () unless defined $root;
	my @list;
	push @list, 'platform-tools' if -d "$root/platform-tools";
	for my $family (qw(platforms build-tools ndk cmdline-tools)) {
		opendir(my $dh, "$root/$family") or next;
		for my $name (sort readdir $dh) {
			next if $name eq '.' || $name eq '..';
			next unless -d "$root/$family/$name";
			push @list, "$family;$name";
		}
		closedir $dh;
	}
	return @list;
}

# Two attempts: a nightly check should not report `unknown` because one
# upstream reset the connection. Only a transport failure (code 0) is retried;
# 200 and 404 are answers. The Arch endpoint in particular resets a burst, so
# the second attempt waits a moment rather than knocking again at once.
sub meta_fetch {
	my ($fixtures, $kind, $key, $url) = @_;
	if (defined $fixtures && length $fixtures) {
		(my $safe = $key) =~ s/[^A-Za-z0-9_.-]/_/g;
		my $ext = $kind eq 'debian' ? '.txt' : $kind eq 'sdk' ? '.xml' : '.json';
		my $path = "$fixtures/${kind}_$safe$ext";
		# A name the simulated repositories do not offer has no file at all;
		# an empty file is an answer with nothing in it (a 404 too, since
		# none of the three endpoints sends an empty body for a live package).
		return (undef, 404) unless -e $path;
		open(my $fh, '<', $path) or return (undef, 0);
		local $/;
		my $text = <$fh>;
		close $fh;
		return (undef, 404) unless defined $text && length $text;
		return ($text, 200);
	}
	return (undef, -1) unless which('curl');
	my ($body, $code) = ('', 0);
	for my $attempt (1 .. 2) {
		open(my $fh, '-|', 'curl', '-sS', '--connect-timeout', '3', '--max-time', '8',
			'-w', "\n%{http_code}", $url) or return (undef, 0);
		local $/;
		my $raw = <$fh>;
		close $fh;
		if ($? != 0) {
			($body, $code) = ('', 0);
			select undef, undef, undef, 1 if $attempt == 1;
			next;
		}
		($body, $code) = (defined $raw ? $raw : '') =~ /^(.*)\n(\d{3})\s*$/s;
		$code = defined $code ? $code + 0 : 0;
		last if $code;
	}
	return (defined $body ? $body : '', $code);
}

sub freshness_report {
	my (%opt) = @_;
	my $strict = $opt{'strict'};
	my $fixtures = $opt{'fixtures'};
	my $json_out = $opt{'json'};
	my $android = $opt{'android'};
	my $platform = $opt{'platform'} || 'unknown';
	my @only = @{ $opt{'only'} || [] };
	my %only = map { $_ => 1 } @only;
	my $want = sub {
		return 1 unless %only;
		for my $name (@_) {
			return 1 if defined $name && length $name && $only{$name};
		}
		return 0;
	};

	my (@module_rows, @debian_rows, @arch_rows, @android_rows);
	my %summary = (current => 0, outdated => 0, available => 0,
		missing => 0, unknown => 0, core => 0, checked => 0,
		android_offered => 0, android_missing => 0, android_unknown => 0);
	my $curl_missing = !defined $fixtures && !which('curl');
	# A fixture run simulates every platform at once, so its rows compare even
	# when the machine doing the checking is the other distribution.
	my $simulated = defined $fixtures && length $fixtures;

	for my $module (@modules) {
		next unless $want->($module);
		my $installed = $simulated
			? fixture_version($fixtures, 'metacpan', $module)
			: module_version($module);
		my $row = { name => $module, installed => $installed };
		if (module_is_core($module)) {
			$row->{'status'} = 'core';
			$summary{'core'}++;
			push @module_rows, $row;
			next;
		}
		my ($body, $code) = meta_fetch($fixtures, 'metacpan', $module,
			"https://fastapi.metacpan.org/v1/module/$module");
		my $meta = defined $body && length $body
			? JawnOS::Packages::parse_metacpan($body) : undef;
		if ($meta) {
			$row->{'latest'} = $meta->{'latest'};
			$row->{'release'} = $meta->{'release'};
			if (!defined $installed) {
				$row->{'status'} = 'available';
			}
			else {
				$row->{'status'} = JawnOS::Packages::compare_module($installed, $meta->{'latest'}) < 0
					? 'outdated' : 'current';
			}
		}
		elsif (defined $code && $code == 404) {
			$row->{'status'} = 'missing';
		}
		else {
			$row->{'status'} = 'unknown';
		}
		$summary{'checked'}++;
		$summary{ $row->{'status'} }++;
		push @module_rows, $row;
	}

	my (%seen_deb, %seen_arch);
	my @deb_packages;
	for my $tool (@tools) {
		my $package = $tool->{'apt'};
		next unless defined $package && length $package;
		next if $seen_deb{$package}++;
		next unless $want->($tool->{'cmd'}, $tool->{'apt'}, $tool->{'pacman'}, $tool->{'label'});
		push @deb_packages, [ $package, $tool->{'label'} || $tool->{'cmd'} ];
	}
	for my $extra (@desktop) {
		my $package = $extra->{'apt'};
		next unless defined $package && length $package;
		next if $seen_deb{$package}++;
		next unless $want->($extra->{'apt'}, $extra->{'pacman'}, $extra->{'label'});
		push @deb_packages, [ $package, $extra->{'label'} ];
	}

	for my $entry (@deb_packages) {
		my ($package, $label) = @$entry;
		my $row = { package => $package, label => $label };
		my ($body, $code) = meta_fetch($fixtures, 'debian', $package,
			"https://api.ftp-master.debian.org/madison?package=$package&table=all");
		my $parsed = defined $body && length $body
			? JawnOS::Packages::parse_madison($body) : undef;
		my $latest = $parsed ? JawnOS::Packages::debian_latest($parsed) : undef;
		if ($latest) {
			$row->{'latest'} = $latest->{'version'};
			$row->{'suite'} = $latest->{'suite'};
			if ($platform eq 'debian' || $simulated) {
				my $installed = $simulated
					? fixture_version($fixtures, 'debian', $package)
					: dpkg_version($package);
				$row->{'installed'} = $installed;
				if (defined $installed) {
					my $lt = debian_lt($installed, $latest->{'version'});
					$row->{'status'} = !defined $lt ? 'unknown' : ($lt ? 'outdated' : 'current');
				}
				else {
					$row->{'status'} = 'available';
				}
			}
			else {
				$row->{'status'} = 'available';
			}
		}
		elsif (defined $code && $code == 200) {
			$row->{'status'} = 'missing';
		}
		else {
			$row->{'status'} = 'unknown';
		}
		$summary{'checked'}++;
		$summary{ $row->{'status'} }++;
		push @debian_rows, $row;
	}

	my @arch_packages;
	for my $tool (@tools) {
		my $package = $tool->{'pacman'};
		next unless defined $package && length $package;
		next if $seen_arch{$package}++;
		next unless $want->($tool->{'cmd'}, $tool->{'apt'}, $tool->{'pacman'}, $tool->{'label'});
		push @arch_packages, [ $package, $tool->{'label'} || $tool->{'cmd'} ];
	}
	for my $extra (@desktop) {
		my $package = $extra->{'pacman'};
		next unless defined $package && length $package;
		next if $seen_arch{$package}++;
		next unless $want->($extra->{'apt'}, $extra->{'pacman'}, $extra->{'label'});
		push @arch_packages, [ $package, $extra->{'label'} ];
	}

	for my $entry (@arch_packages) {
		my ($package, $label) = @$entry;
		my $row = { package => $package, label => $label };
		my ($body, $code) = meta_fetch($fixtures, 'arch', $package,
			"https://archlinux.org/packages/search/json/?name=$package");
		my $parsed = defined $body && length $body
			? JawnOS::Packages::parse_arch($body) : undef;
		my $latest = $parsed ? JawnOS::Packages::arch_version($parsed) : undef;
		if (defined $latest) {
			$row->{'latest'} = $latest;
			$row->{'repo'} = $parsed->{'repo'};
			if ($platform eq 'arch' || $simulated) {
				my $installed = $simulated
					? fixture_version($fixtures, 'arch', $package)
					: pacman_version($package);
				$row->{'installed'} = $installed;
				if (defined $installed) {
					my $lt = arch_lt($installed, $latest);
					$row->{'status'} = !defined $lt ? 'unknown' : ($lt ? 'outdated' : 'current');
				}
				else {
					$row->{'status'} = 'available';
				}
			}
			else {
				$row->{'status'} = 'available';
			}
		}
		elsif (defined $code && $code == 200) {
			$row->{'status'} = 'missing';
		}
		else {
			$row->{'status'} = 'unknown';
		}
		$summary{'checked'}++;
		$summary{ $row->{'status'} }++;
		push @arch_rows, $row;
	}

	if ($android) {
		# sdkmanager reads this same index; the paths in it are the package ids.
		my $sdk_url = 'https://dl.google.com/android/repository/repository2-3.xml';
		my ($body, $code) = meta_fetch($fixtures, 'sdk', 'repository', $sdk_url);
		my $repo = defined $body && length $body
			? JawnOS::Packages::parse_sdk_repository($body) : undef;
		if (!$repo) {
			# The index is one request, so "we could not read it" is not a
			# detail to pass over: with --android the caller asked this
			# question, and a silent pass would hide an unreachable Google.
			my $row = { component => 'repository index' };
			if (defined $code && $code == 404) {
				$row->{'status'} = 'missing';
				$summary{'android_missing'}++;
			}
			else {
				$row->{'status'} = 'unknown';
				$summary{'android_unknown'}++;
			}
			push @android_rows, $row;
		}
		else {
			# The two every build needs whether or not an SDK is installed
			# here, then whatever this machine already has: a component the
			# build depends on must not silently disappear from the index.
			my %wanted = map { $_ => 0 } ('platform-tools', 'cmdline-tools;latest');
			$wanted{$_} = 1 for sdk_components($fixtures);
			for my $component (sort keys %wanted) {
				next unless $want->($component);
				my $row = { component => $component };
				$row->{'installed'} = $wanted{$component};
				if ($repo->{'packages'}{$component}) {
					$row->{'status'} = 'offered';
					$summary{'android_offered'}++;
				}
				else {
					$row->{'status'} = 'missing';
					$summary{'android_missing'}++;
				}
				push @android_rows, $row;
			}
		}
	}

	if (!@module_rows && !@debian_rows && !@arch_rows && !@android_rows) {
		print "freshness: no requested names matched the installer lists\n";
		return 2;
	}

	my $ok = 1;
	$ok = 0 if $summary{'missing'};
	$ok = 0 if $summary{'android_missing'};
	$ok = 0 if $summary{'android_unknown'};
	$ok = 0 if $strict && $summary{'outdated'};
	$ok = 0 if $summary{'checked'} && $summary{'unknown'} == $summary{'checked'};
	$ok = 0 if $curl_missing;

	if ($json_out) {
		print JSON::PP->new->canonical->pretty->encode({
			ok => $ok,
			metadata_only => 1,
			summary => \%summary,
			modules => \@module_rows,
			debian => \@debian_rows,
			arch => \@arch_rows,
			android => \@android_rows,
			curl_missing => $curl_missing ? 1 : 0,
			strict => $strict ? 1 : 0,
		});
		return $ok ? 0 : 1;
	}

	print "package freshness: metadata only; no package, tarball or distribution is downloaded\n";
	print "FAIL: curl is required for the metadata checks; nothing was fetched\n" if $curl_missing;
	print "\nPerl modules (CPAN)\n";
	for my $row (@module_rows) {
		printf "  %-30s %-12s -> %-12s %s\n",
			$row->{'name'},
			defined $row->{'installed'} ? $row->{'installed'} : '-',
			defined $row->{'latest'} ? $row->{'latest'} : '-',
			$row->{'status'};
	}
	print "\nDebian packages (stable/testing; installed -> candidate)\n";
	for my $row (@debian_rows) {
		printf "  %-30s %-12s -> %-12s %s%s\n",
			$row->{'package'},
			defined $row->{'installed'} ? $row->{'installed'} : '-',
			defined $row->{'latest'} ? $row->{'latest'} : '-',
			$row->{'status'},
			defined $row->{'suite'} ? " ($row->{'suite'})" : '';
	}
	print "\nArch packages (official; installed -> latest)\n";
	for my $row (@arch_rows) {
		printf "  %-30s %-12s -> %-12s %s%s\n",
			$row->{'package'},
			defined $row->{'installed'} ? $row->{'installed'} : '-',
			defined $row->{'latest'} ? $row->{'latest'} : '-',
			$row->{'status'},
			defined $row->{'repo'} ? " ($row->{'repo'})" : '';
	}
	print "\nsummary: $summary{'current'} current, $summary{'outdated'} outdated, "
		. "$summary{'available'} available, $summary{'missing'} missing, "
		. "$summary{'unknown'} unknown, $summary{'core'} core\n";
	print "missing upstream: ", join(', ', map { $_->{'package'} || $_->{'name'} }
		grep { ($_->{'status'} || '') eq 'missing' } (@module_rows, @debian_rows, @arch_rows)), "\n"
		if $summary{'missing'};
	if (@android_rows) {
		print "\nAndroid SDK components (repository2-3.xml; installed here?)\n";
		for my $row (@android_rows) {
			printf "  %-30s %s%s\n",
				$row->{'component'},
				$row->{'status'},
				$row->{'installed'} ? ' (installed)' : '';
		}
		print "android: $summary{'android_offered'} offered, $summary{'android_missing'} missing"
			. ($summary{'android_unknown'} ? ", $summary{'android_unknown'} unknown" : '') . "\n";
		print "android missing: ", join(', ', map { $_->{'component'} }
			grep { ($_->{'status'} || '') eq 'missing' } @android_rows), "\n"
			if $summary{'android_missing'};
		print "android: the index could not be read; the Android check did not run\n"
			if $summary{'android_unknown'};
	}
	return $ok ? 0 : 1;
}

if ($freshness) {
	exit freshness_report(
		strict   => $strict,
		fixtures => $fixtures,
		only     => \@only,
		platform => $platform,
		json     => $json,
		android  => $android,
	);
}

my (@missing_tools, @missing_modules, @missing_desktop, @missing_extras);
foreach my $t (@tools) {
	push @missing_tools, $t unless have_command($t);
}
foreach my $m (@modules) {
	push @missing_modules, $m unless have_module($m);
}
my @missing_caps = grep { !$_->{'check'}->() } @capabilities;
if ($desktop && ($platform eq 'arch' || $platform eq 'debian')) {
	foreach my $d (@desktop) {
		push @missing_desktop, $d unless $d->{'check'}->();
	}
}
unless ($no_extras) {
	foreach my $e (@extras) {
		push @missing_extras, $e unless $e->{'check'}->();
	}
}

if ($json) {
	my $data = {
		platform        => $platform,
		ok              => (@missing_tools + @missing_modules == 0) ? 1 : 0,
		missing_tools   => [ map { { cmd => $_->{'cmd'}, label => $_->{'label'}, package => pkg_for($_) } } @missing_tools ],
		missing_modules => [ @missing_modules ],
		missing_desktop => [ map { { label => $_->{'label'}, package => pkg_for($_) } } @missing_desktop ],
		missing_extras  => [ map { { id => $_->{'id'}, label => $_->{'label'} } } @missing_extras ],
		capabilities    => { map { $_->{'id'} => ($_->{'check'}->() ? 1 : 0) } @capabilities },
	};
	print JSON::PP->new->canonical->pretty->encode($data);
	exit((@missing_tools + @missing_modules == 0) ? 0 : 1);
}

if ($sh) {
	print install_script();
	exit 0;
}

print "JawnOS dependency check (platform: $platform)\n";
print '-' x 48, "\n";

if (!@missing_tools) {
	print "command line tools: all present\n";
}
else {
	print "command line tools missing:\n";
	foreach my $t (@missing_tools) {
		printf "  - %-16s (%s)\n", $t->{'label'}, pkg_for($t);
	}
}
if (!@missing_modules) {
	print "perl modules: all present\n";
}
else {
	print "perl modules missing (" . scalar(@missing_modules) . "):\n";
	foreach my $m (@missing_modules) {
		print "  - $m\n";
	}
}
my @have_caps = grep { $_->{'check'}->() } @capabilities;
print "key derivation: " . (@have_caps ? join(', ', map { $_->{'id'} } @have_caps) : 'none (PBKDF2 at 600k)') . "\n";
foreach my $c (@missing_caps) {
	print "  - " . $c->{'label'} . " unavailable; recovery shares use " . $c->{'fallback'} . "\n";
}
if ($desktop && ($platform eq 'arch' || $platform eq 'debian')) {
	if (!@missing_desktop) {
		print "desktop extras: all present\n";
	}
	else {
		print "desktop extras missing (optional -- the dashboard works without the view,\n";
		print "video merely decodes in software, and emoji fall back to the system):\n";
		foreach my $d (@missing_desktop) {
			printf "  - %-44s (%s)\n", $d->{'label'}, pkg_for($d);
		}
	}
}
if (!$no_extras) {
	if (!@missing_extras) {
		print "optional applications: all present\n";
	}
	else {
		print "optional applications missing (the eSpeak fallback is used until installed):\n";
		foreach my $e (@missing_extras) {
			print "  - " . $e->{'label'} . "\n";
		}
	}
}

my $core_missing = (@missing_tools + @missing_modules) > 0;
my $desktop_missing = @missing_desktop > 0;
if (!$core_missing && !$desktop_missing) {
	print "\nEverything is installed. You're good to go.\n";
	exit 0;
}
if ($report_only) {
	# The desktop extras are optional: only a missing core dependency fails --report.
	exit($core_missing ? 1 : 0);
}
exit 1 if $platform eq 'unknown';

unless ($install) {
	print "\nInstall the missing dependencies now? [Y/n] ";
	my $answer = <STDIN>;
	$answer = 'y' if !defined $answer;
	exit 1 if $answer =~ /^n/i;
	$install = 1;
}

# --- install -----------------------------------------------------------------
sub run {
	my @cmd = @_;
	print "\$ " . join(' ', @cmd) . "\n";
	system(@cmd);
	return $? >> 8;
}

sub sudo {
	# --local-lib is a user-scoped install by contract: no package manager and
	# no sudo, whatever the caller's privileges.
	return () if defined $local_lib && length $local_lib;
	return () if $platform eq 'termux';
	return ('sudo') if -x '/usr/bin/sudo';
	return ();
}

{
	# Core tools and any opted-in desktop extras in one transaction.
	my @pkgs = grep { defined $_ && $_ ne '' } map { pkg_for($_) } (@missing_tools, @missing_desktop);
	if (@pkgs && defined $local_lib && length $local_lib) {
		print "Skipping system packages in --local-lib mode: " . join(' ', @pkgs) . "\n";
	}
	elsif (@pkgs) {
		if ($platform eq 'debian') {
			run( sudo(), 'apt-get', 'update' );
			run( sudo(), 'apt-get', 'install', '-y', @pkgs );
		}
		elsif ($platform eq 'arch') {
			run( sudo(), 'pacman', '-Sy', '--noconfirm' );
			run( sudo(), 'pacman', '-S', '--noconfirm', @pkgs );
		}
		elsif ($platform eq 'termux') {
			run( 'pkg', 'install', '-y', @pkgs );
		}
	}
}

# cpanminus may have just been installed; make sure it is visible.
unless (which('cpanm')) {
	print "cpanm is not available; trying to bootstrap App::cpanminus\n";
	run( 'perl', '-MApp::cpanminus', '-e', '1' ) == 0 or run( 'curl', '-L', 'https://cpanmin.us', '|', 'perl', '-', 'App::cpanminus' );
}

if (@missing_modules) {
	my $cpanm = which('cpanm') || 'cpanm';
	my @cmd = ($cpanm, '--notest', '--force');
	if (defined $local_lib && length $local_lib) {
		push @cmd, '--local-lib', $local_lib;
	}
	else {
		unshift @cmd, sudo() unless $platform eq 'termux';
	}
	push @cmd, @missing_modules;
	run(@cmd);
}

unless ($no_extras) {
	if (@missing_extras) {
		print "\nOptional applications:\n";
		foreach my $e (@missing_extras) { $e->{'install'}->(); }
	}
}

# --- final verdict -----------------------------------------------------------
my @still_tools = grep { !have_command($_) } @tools;
my @still_modules = grep { !have_module($_) } @modules;
my @still_desktop = grep { !$_->{'check'}->() } @missing_desktop;
if (!@still_tools && !@still_modules && !@still_desktop) {
	print "\nAll dependencies installed.\n";
	exit 0;
}
print "\nStill missing " . scalar(@still_tools) . " tool(s) and " . scalar(@still_modules) . " module(s).\n";
if (@still_desktop) {
	print "Desktop extras still missing (optional): " . join(', ', map { $_->{'label'} } @still_desktop) . ".\n";
}
print "You may need to install them by hand (see the README).\n";
exit( (@still_tools || @still_modules) ? 1 : 0 );

sub pkg_for {
	my $t = shift;
	my %key_for = ( debian => 'apt', arch => 'pacman', termux => 'termux' );
	my $key = $key_for{$platform} || 'apt';
	return $t->{$key} || $t->{'apt'} || $t->{'cmd'};
}

# The commands this script would run, as a copy/pasteable (or downloadable)
# shell script. Used by --sh, and by the setup wizard's dependency step.
sub install_script {
	my @lines;
	push @lines, '#!/bin/sh';
	push @lines, "# JawnOS missing dependencies (platform: $platform)";
	push @lines, '# Generated by scripts/jawnos_deps.pl --sh';
	push @lines, '';

	my @pkgs = grep { defined $_ && $_ ne '' } map { pkg_for($_) } (@missing_tools, @missing_desktop);
	if (@pkgs && defined $local_lib && length $local_lib) {
		push @lines, '# system packages skipped: --local-lib installs for this user only';
		push @lines, '';
	}
	elsif (@pkgs) {
		push @lines, '# command line tools' . (@missing_desktop ? ' and desktop extras' : '');
		if ($platform eq 'debian') {
			push @lines, join(' ', sudo(), 'apt-get', 'update');
			push @lines, join(' ', sudo(), 'apt-get', 'install', '-y', @pkgs);
		}
		elsif ($platform eq 'arch') {
			push @lines, join(' ', sudo(), 'pacman', '-Sy', '--noconfirm');
			push @lines, join(' ', sudo(), 'pacman', '-S', '--noconfirm', @pkgs);
		}
		elsif ($platform eq 'termux') {
			push @lines, join(' ', 'pkg', 'install', '-y', @pkgs);
		}
		else {
			push @lines, '# unknown platform -- install these by hand: ' . join(' ', @pkgs);
		}
		push @lines, '';
	}

	if (@missing_modules) {
		push @lines, '# perl modules';
		push @lines, 'command -v cpanm >/dev/null 2>&1 || curl -L https://cpanmin.us | perl - App::cpanminus';
		my @cpanm = ( which('cpanm') || 'cpanm' );
		if (defined $local_lib && length $local_lib) {
			push @cpanm, '--local-lib', $local_lib;
		}
		else {
			unshift @cpanm, sudo() unless $platform eq 'termux';
		}
		push @lines, join(' ', @cpanm, '--notest', '--force', @missing_modules);
		push @lines, '';
	}

	my @missing_caps_sh = grep { !$_->{'check'}->() } @capabilities;
	if (@missing_caps_sh) {
		push @lines, '# key derivation: no package to install -- these are OpenSSL features';
		push @lines, '# missing: ' . join(', ', map { $_->{'id'} } @missing_caps_sh) . '; recovery shares fall back automatically';
		push @lines, '';
	}

	unless ($no_extras) {
		my @want_extras = grep { !$_->{'check'}->() } @extras;
		if (@want_extras) {
			push @lines, '# optional applications (Piper, the natural speech voice)';
			push @lines, 'perl scripts/jawnos_deps.pl --extras-only --install';
			push @lines, '';
		}
	}

	if (!@pkgs && !@missing_modules) {
		push @lines, 'echo "Every JawnOS dependency is already installed."';
	}

	return join("\n", @lines) . "\n";
}
