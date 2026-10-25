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
#   perl scripts/jawnos_deps.pl --no-extras # skip the optional apps
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

my ($report_only, $json, $sh, $install, $yes, $desktop, $extras_only, $no_extras);
GetOptions(
	'report'      => \$report_only,
	'json'        => \$json,
	'sh'          => \$sh,
	'install'     => \$install,
	'yes|y'       => \$yes,
	'desktop'     => \$desktop,
	'extras-only' => \$extras_only,
	'no-extras'   => \$no_extras,
) or die "bad options\n";

$install = 1 if $yes;

my $platform = detect_platform();

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
	return 'termux' if $ENV{'TERMUX_VERSION'} || -d '/data/data/com.termux';
	return 'debian' if -x '/usr/bin/apt-get' || -x '/usr/bin/apt';
	return 'arch'   if -x '/usr/bin/pacman';
	return 'unknown';
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
	return () if $platform eq 'termux';
	return ('sudo') if -x '/usr/bin/sudo';
	return ();
}

{
	# Core tools and any opted-in desktop extras in one transaction.
	my @pkgs = grep { defined $_ && $_ ne '' } map { pkg_for($_) } (@missing_tools, @missing_desktop);
	if (@pkgs) {
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
	my @cmd = ($cpanm, '--notest', '--force', @missing_modules);
	unshift @cmd, sudo() unless $platform eq 'termux';
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
	if (@pkgs) {
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
		unshift @cpanm, sudo() unless $platform eq 'termux';
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
