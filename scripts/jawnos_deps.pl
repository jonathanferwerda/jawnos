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
#   perl scripts/jawnos_deps.pl --freshness --report-file=PATH  # the same JSON,
#                                                    # beside the text report
#                                                    # (the QA panel reads it)
#   perl scripts/jawnos_deps.pl --freshness --only=NAME  # one name (repeatable)
#   perl scripts/jawnos_deps.pl --freshness --fixtures=DIR  # offline, canned
#   perl scripts/jawnos_deps.pl --freshness --android      # also the Android
#                                                    # SDK/NDK components
#   perl scripts/jawnos_deps.pl --freshness --android --android-update
#                                                    # install a newer
#                                                    # build-tools/NDK with
#                                                    # sdkmanager
#   perl scripts/jawnos_deps.pl --freshness --android --android-update --android-keep=1
#                                                    # ...and drop every NDK,
#                                                    # build-tools and platform
#                                                    # but the pinned ones and
#                                                    # the newest N (default 2)
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
use Cwd qw(abs_path);
use File::Copy qw(copy);
use File::Path qw(remove_tree);
use lib "$FindBin::Bin/../lib";
use JawnOS::Packages;

my ($report_only, $json, $sh, $install, $yes, $desktop, $extras_only, $no_extras, $local_lib, $freshness, $strict, $fixtures, $android, $android_update, $android_keep, $report_file);
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
	'android-update' => \$android_update,
	'android-keep=i' => \$android_keep,
	'report-file=s' => \$report_file,
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
my $vosk_dir  = "$home/.local/share/jawnos/vosk";
my @extras = (
	{ id => 'piper', label => 'Piper TTS (natural voice)', check => \&have_piper, install => \&install_piper },
	{ id => 'vosk',  label => 'Vosk speech-to-text (offline)', check => \&have_vosk, install => \&install_vosk },
	{ id => 'rtc',   label => 'WebRTC bridge (Connect me)', check => \&have_rtc, install => \&install_rtc },
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
	{ cmd => 'rsync',     apt => 'rsync',            pacman => 'rsync',          termux => 'rsync',            label => 'rsync' },
	{ cmd => 'ffmpeg',    apt => 'ffmpeg',           pacman => 'ffmpeg',         termux => 'ffmpeg',           label => 'FFmpeg' },
	{ cmd => 'convert',   apt => 'imagemagick',      pacman => 'imagemagick',    termux => 'imagemagick',      label => 'ImageMagick' },
	{ cmd => 'tesseract', apt => 'tesseract-ocr',    pacman => 'tesseract',      termux => 'tesseract',        label => 'Tesseract OCR' },
	{ cmd => 'qrencode',  apt => 'qrencode',         pacman => 'qrencode',       termux => 'libqrencode',      label => 'qrencode' },
	{ cmd => 'espeak',    apt => 'espeak',           pacman => 'espeak-ng',      termux => 'espeak',           label => 'espeak', alt => 'espeak-ng' },
	{ cmd => 'sox',       apt => 'sox',              pacman => 'sox',            termux => 'sox',              label => 'SoX' },
	{ cmd => 'zip',       apt => 'zip',              pacman => 'zip',            termux => 'zip',              label => 'zip' },
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
sub piper_offer {
	# The bundled Piper carries espeak-ng (GPL-3.0-or-later), so the source
	# offer and the GPL text travel with the binary, not only in the repo.
	# Idempotent and non-fatal: a read-only install keeps working without it.
	return unless -d $piper_dir;
	my $source = "$piper_dir/SOURCE.txt";
	unless (-f $source) {
		if (open(my $fh, '>', $source)) {
			my @offer = (
				'Piper 1.2.0 and the libraries bundled with it come from:',
				'  https://github.com/rhasspy/piper/releases/tag/2023.11.14-2',
				'',
				'That release also carries espeak-ng 1.52.0, which is GPL-3.0-or-later.',
				'Its source is:',
				'  https://github.com/espeak-ng/espeak-ng/tree/1.52.0',
				'',
				'The GPL-3.0 text is in COPYING beside this file.',
			);
			print $fh join("\n", @offer), "\n";
			close $fh;
		}
	}
	my $gpl = "$FindBin::Bin/../docs/licenses/runtime/GPL-3.0.txt";
	copy($gpl, "$piper_dir/COPYING") if -f $gpl && !-f "$piper_dir/COPYING";
}

sub have_piper {
	my $have = (which('piper') || -x "$piper_dir/piper" || -x &piper_venv_bin()) ? 1 : 0;
	piper_offer() if $have;
	return $have;
}

sub piper_arch {
	my $m = `uname -m`; chomp $m;
	return 'x86_64'  if $m =~ /^(x86_64|amd64)$/;
	return 'aarch64' if $m =~ /^(aarch64|arm64)$/;
	return '';
}

sub piper_venv_bin { return "$home/.local/share/jawnos/piper18/venv/bin/piper" }

# The wrapper the app runs. It is a file rather than a symlink so the reason it
# exists (and where the old bundle went) travels with the machine.
sub piper_wrapper {
	my $text = <<'WRAP';
#!/bin/sh
# Piper from the pip wheel (piper1-gpl), in its own venv. It reads the newer
# config format (multi-codepoint phonemes) that the current voices use; the
# 2023 bundle is kept at ../piper-2023 for a Termux host and as a rescue.
exec "$HOME/.local/share/jawnos/piper18/venv/bin/piper" "$@"
WRAP
	return $text;
}

# The pip wheel, which is what every desktop voice now needs. The 2023 bundle
# reads a phoneme as one codepoint; the voices that ship use multi-codepoint
# phonemes ("aɪ"), so it answers every phrase with "Phonemes must be one
# codepoint" and the gateway speaks nothing at all. Installing this again
# upgrades it, so a machine that ran an older installer is fixed by re-running
# the installer rather than by hand.
sub install_piper_wheel {
	my $venv = "$home/.local/share/jawnos/piper18/venv";
	run('python3', '-m', 'venv', $venv) unless -x "$venv/bin/python3";
	if (!-x "$venv/bin/pip") {
		print "  piper: no pip in the venv; cannot install the wheel.\n";
		return 0;
	}
	run("$venv/bin/pip", 'install', '--quiet', '--disable-pip-version-check', '--upgrade', 'piper-tts');
	return -x &piper_venv_bin() ? 1 : 0;
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
		install_piper_bundle($arch);
		return;
	}
	if (&install_piper_wheel()) {
		# the 2023 bundle is kept beside the wrapper: a Termux host sharing this
		# machine still needs it, and it is the rescue when the venv is gone
		if (-d "$piper_dir/espeak-ng-data" && !-e "$piper_dir-2023") {
			rename $piper_dir, "$piper_dir-2023";
		}
		system('mkdir', '-p', $piper_dir);
		if (open(my $w, '>', "$piper_dir/piper")) {
			print {$w} &piper_wrapper();
			close $w;
			chmod 0755, "$piper_dir/piper";
		}
		foreach my $f (qw(COPYING SOURCE.txt)) {
			next unless -e "$piper_dir-2023/$f";
			run('cp', "$piper_dir-2023/$f", "$piper_dir/$f");
		}
		print "  piper: installed from the pip wheel to " . &piper_venv_bin() . "\n";
		return;
	}
	print "  piper: the wheel did not install; falling back to the 2023 bundle.\n";
	install_piper_bundle($arch);
}

sub install_piper_bundle {
	my $arch = shift;
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
	piper_offer();
	print "  piper: installed to $piper_dir\n" if -x "$piper_dir/piper";
	print "  piper: installed (no binary produced?)\n" unless -x "$piper_dir/piper";
}

# --- Vosk: the offline recogniser -------------------------------------------
# Vosk's Python package has glibc wheels only, so it cannot run under Termux;
# the gateway machine (desktop or laptop) is where it belongs. The venv keeps it
# out of the system Python and survives a PEP 668 "externally managed" system.
# One small English model comes down with it; another language is a directory
# dropped under models/ and found by subs::vosk_model_dir.
sub vosk_model_name { return 'vosk-model-small-en-us-0.15'; }
sub vosk_model_url  { return 'https://alphacephei.com/vosk/models/' . vosk_model_name() . '.zip'; }
sub vosk_models_dir { return "$vosk_dir/models"; }
sub vosk_model_path { return "$vosk_dir/models/" . vosk_model_name(); }

sub have_vosk {
	my $py = "$vosk_dir/venv/bin/python3";
	return 0 unless -x $py;
	return 0 unless -d vosk_model_path();
	# the directory alone is not proof: an interrupted pip leaves the venv
	return system($py, '-c', 'import vosk') == 0 ? 1 : 0;
}

# The venv every gateway media helper shares: Vosk's model and the WebRTC
# bridge's aiortc. It is checked for pip, not only for the interpreter - a venv
# made before python3-venv was installed has no pip and would fail forever.
sub ensure_venv {
	my $py = which('python3') || which('python');
	return '' unless $py;
	my $venv_py = "$vosk_dir/venv/bin/python3";
	my $has_pip = -x $venv_py && system($venv_py, '-m', 'pip', '--version') == 0;
	unless ($has_pip) {
		remove_tree("$vosk_dir/venv") if -d "$vosk_dir/venv";
		run($py, '-m', 'venv', "$vosk_dir/venv");
	}
	return '' unless -x $venv_py;
	return '' unless system($venv_py, '-m', 'pip', '--version') == 0;
	return $venv_py;
}

sub install_vosk {
	if ($platform eq 'termux') {
		print "  vosk: Termux (Bionic) has no Vosk wheel; the gateway machine runs it.\n";
		return;
	}
	if (!(which('python3') || which('python'))) {
		print "  vosk: python3 is not installed; skipping (transcription falls back to whisper.cpp).\n";
		return;
	}
	system('mkdir', '-p', vosk_models_dir());
	my $venv_py = ensure_venv();
	if (!$venv_py) {
		print "  vosk: could not make a working virtual environment (install python3-venv); skipping.\n";
		return;
	}
	if (run($venv_py, '-m', 'pip', 'install', '--disable-pip-version-check', 'vosk') != 0) {
		print "  vosk: pip could not install the package; leaving the fallback in place.\n";
		return;
	}
	unless (-d vosk_model_path()) {
		my $tmp_dir = ($ENV{'TMPDIR'} && -d $ENV{'TMPDIR'} && -w $ENV{'TMPDIR'}) ? $ENV{'TMPDIR'} : '/tmp';
		$tmp_dir = $vosk_dir unless -w $tmp_dir;
		my $zip = "$tmp_dir/jawnos_vosk_$$.zip";
		if (run('curl', '-L', '--fail', '-o', $zip, vosk_model_url()) != 0) {
			print "  vosk: model download failed; the package is installed but has no model.\n";
			return;
		}
		# python3 -m zipfile needs nothing else installed, and Termux is not a
		# path here anyway; unzip is only preferred because it is quicker.
		my $unzip = which('unzip');
		my $ok = $unzip
			? run($unzip, '-q', '-o', $zip, '-d', vosk_models_dir()) == 0
			: run((which('python3') || which('python')), '-m', 'zipfile', '-e', $zip, vosk_models_dir()) == 0;
		unlink $zip;
		unless ($ok && -d vosk_model_path()) {
			print "  vosk: model extract failed.\n";
			return;
		}
	}
	print "  vosk: installed to $vosk_dir\n" if have_vosk();
	print "  vosk: installed, but the import probe failed\n" unless have_vosk();
}

# The bridge is a WebRTC peer (aiortc) in the same venv. It is what "Connect me"
# runs; without it the face's button has nothing to talk to, so it is an extra
# of its own rather than a surprise at the first call.
sub have_rtc {
	my $py = "$vosk_dir/venv/bin/python3";
	return 0 unless -x $py;
	return system($py, '-c', 'import aiortc') == 0 ? 1 : 0;
}

sub install_rtc {
	if ($platform eq 'termux') {
		print "  webrtc: Termux has no aiortc wheel; the gateway machine runs the bridge.\n";
		return;
	}
	my $venv_py = ensure_venv();
	if (!$venv_py) {
		print "  webrtc: no working Python environment (install python3-venv); skipping.\n";
		return;
	}
	if (run($venv_py, '-m', 'pip', 'install', '--disable-pip-version-check', 'aiortc') != 0) {
		print "  webrtc: pip could not install aiortc; Connect me stays off.\n";
		return;
	}
	print "  webrtc: installed to $vosk_dir/venv\n" if have_rtc();
	print "  webrtc: installed, but the import probe failed\n" unless have_rtc();
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
#
# Each component carries its family and the version actually installed:
# `cmdline-tools;latest` is an alias whose version is only in source.properties,
# so the directory name is enough for the other families but not for that one.
sub sdk_components {
	my ($fixtures) = @_;
	if (defined $fixtures && length $fixtures) {
		my $path = "$fixtures/sdk_installed.txt";
		return () unless -e $path;
		open(my $fh, '<', $path) or return ();
		my @components;
		while (my $line = <$fh>) {
			$line =~ s/^\s+|\s+$//g;
			next unless length $line && $line !~ /^#/;
			my ($family, $version) = $line =~ /^([^;]+);(.*)$/;
			$family = $line unless defined $family;
			$version = undef if defined $version && $version eq 'latest';
			push @components, { id => $line, family => $family, version => $version };
		}
		close $fh;
		return @components;
	}
	my $root = sdk_root();
	return () unless defined $root;
	my @components;
	push @components, { id => 'platform-tools', family => 'platform-tools' }
		if -d "$root/platform-tools";
	for my $family (qw(platforms build-tools ndk cmdline-tools)) {
		opendir(my $dh, "$root/$family") or next;
		for my $name (sort readdir $dh) {
			next if $name eq '.' || $name eq '..';
			next unless -d "$root/$family/$name";
			push @components, {
				id      => "$family;$name",
				family  => $family,
				version => $family eq 'cmdline-tools'
					? sdk_pkg_revision("$root/$family/$name")
					: $name,
			};
		}
		closedir $dh;
	}
	return @components;
}

# sdkmanager writes the real version of an alias directory here.
sub sdk_pkg_revision {
	my ($dir) = @_;
	return undef unless defined $dir && -e "$dir/source.properties";
	open(my $fh, '<', "$dir/source.properties") or return undef;
	my $version;
	while (my $line = <$fh>) {
		next unless $line =~ /^Pkg\.Revision\s*=\s*(.+?)\s*$/;
		$version = $1;
	}
	close $fh;
	return $version;
}

# The sdkmanager this SDK ships. `latest` first: that is the directory the
# install instructions create.
sub sdkmanager_path {
	my $root = sdk_root();
	return undef unless defined $root;
	for my $candidate ("$root/cmdline-tools/latest/bin/sdkmanager",
		(map { "$_/bin/sdkmanager" } sort { $b cmp $a }
			map  { "$root/cmdline-tools/$_" }
			grep { -d "$root/cmdline-tools/$_" } sdk_dir_names("$root/cmdline-tools"))) {
		return $candidate if -x $candidate;
	}
	return undef;
}

sub sdk_dir_names {
	my ($dir) = @_;
	opendir(my $dh, $dir) or return ();
	my @names = grep { !/^\.\.?$/ && -d "$dir/$_" } readdir $dh;
	closedir $dh;
	return @names;
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
	my $android_update = $opt{'android_update'};
	my $android_keep = $opt{'android_keep'} || 2;
	my $report_file = $opt{'report_file'};
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

	my (@module_rows, @debian_rows, @arch_rows, @android_rows, @toolchain_rows);
	my %summary = (current => 0, outdated => 0, available => 0,
		missing => 0, unknown => 0, core => 0, checked => 0,
		android_offered => 0, android_missing => 0, android_unknown => 0,
		android_outdated => 0);
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
			my %wanted = map { $_ => { id => $_, installed => 0 } }
				('platform-tools', 'cmdline-tools;latest');
			my @components = sdk_components($fixtures);
			for my $component (@components) {
				$wanted{$component->{'id'}} = { %$component, installed => 1 };
			}
			for my $component (sort keys %wanted) {
				next unless $want->($component);
				my $row = {
					component => $component,
					installed => $wanted{$component}{'installed'},
				};
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

			# Is there a newer build-tools, NDK or cmdline-tools than the one
			# this machine has? A newer NDK only reaches the build once the
			# app's ndkVersion pin moves, so this is a report, not a verdict.
			my %newest_installed;
			for my $component (@components) {
				next unless defined $component->{'version'};
				next unless $component->{'family'} =~ /^(?:build-tools|ndk|cmdline-tools)$/;
				my $family = $component->{'family'};
				my $current = $newest_installed{$family};
				$newest_installed{$family} = $component->{'version'}
					if !defined $current
					|| JawnOS::Packages::compare_module($component->{'version'}, $current) > 0;
			}
			for my $family (sort keys %newest_installed) {
				next unless $want->($family);
				my $installed = $newest_installed{$family};
				my $newest = JawnOS::Packages::sdk_newest($repo, $family);
				my $row = { tool => $family, installed => $installed, latest => $newest };
				$row->{'status'} = !defined $newest ? 'unknown'
					: JawnOS::Packages::compare_module($installed, $newest) < 0 ? 'outdated'
					: 'current';
				if ($row->{'status'} eq 'outdated') {
					$summary{'android_outdated'}++;
					# cmdline-tools is the sdkmanager this job is about to
					# run; replacing it mid-run is not worth the surprise, so
					# it is reported and left for a person.
					$row->{'update'} = "$family;$newest" if $family ne 'cmdline-tools';
				}
				push @toolchain_rows, $row;
			}
		}
	}

	if (!@module_rows && !@debian_rows && !@arch_rows && !@android_rows && !@toolchain_rows) {
		print "freshness: no requested names matched the installer lists\n";
		return 2;
	}

	my $ok = 1;
	$ok = 0 if $summary{'missing'};
	$ok = 0 if $summary{'android_missing'};
	$ok = 0 if $summary{'android_unknown'};
	$ok = 0 if $strict && $summary{'outdated'};
	$ok = 0 if $strict && $summary{'android_outdated'};
	$ok = 0 if $summary{'checked'} && $summary{'unknown'} == $summary{'checked'};
	$ok = 0 if $curl_missing;

	my $document = {
		ok => $ok,
		metadata_only => 1,
		generated => time,
		summary => \%summary,
		modules => \@module_rows,
		debian => \@debian_rows,
		arch => \@arch_rows,
		android => \@android_rows,
		toolchain => \@toolchain_rows,
		curl_missing => $curl_missing ? 1 : 0,
		strict => $strict ? 1 : 0,
	};

	if ($json_out) {
		print JSON::PP->new->canonical->pretty->encode($document);
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
	if (@toolchain_rows) {
		print "\nAndroid toolchain (newest installed -> newest offered)\n";
		for my $row (@toolchain_rows) {
			printf "  %-30s %-12s -> %-12s %s\n",
				$row->{'tool'},
				defined $row->{'installed'} ? $row->{'installed'} : '-',
				defined $row->{'latest'} ? $row->{'latest'} : '-',
				$row->{'status'};
		}
		print "android toolchain: $summary{'android_outdated'} behind upstream\n";
	}
	if ($android_update && !$json_out && !$simulated) {
		my @todo = map { $_->{'update'} }
			grep { defined $_->{'update'} && ($_->{'status'} || '') eq 'outdated' } @toolchain_rows;
		$ok = 0 if !android_update(@todo);
		android_prune($android_keep);
	}

	# The same document --json prints, for the QA panel to read off disk. Written
	# last so it carries the verdict the check reached, not a guess made earlier.
	if (defined $report_file && length $report_file) {
		$document->{'ok'} = $ok;
		if (open(my $rf, '>', $report_file)) {
			print {$rf} JSON::PP->new->canonical->pretty->encode($document);
			close $rf;
		}
		else {
			print "freshness: could not write the report file ($report_file: $!)\n";
		}
	}
	return $ok ? 0 : 1;
}

# Install the newer components with the SDK's own sdkmanager. This is the one
# place the check writes to the machine, so it only runs when asked
# (--android-update) and never in a fixture or JSON run. A newer NDK is staged,
# not adopted: the build keeps using the app's ndkVersion pin until that moves.
sub android_update {
	my (@ids) = @_;
	if (!@ids) {
		print "android update: nothing behind upstream\n";
		return 1;
	}
	my $sdkmanager = sdkmanager_path();
	if (!defined $sdkmanager) {
		print "android update: no sdkmanager under the SDK; reporting only\n";
		return 1;
	}
	if (!which('java')) {
		print "android update: no java on PATH; sdkmanager cannot run, reporting only\n";
		return 1;
	}
	# sdkmanager refuses an install until the licences are accepted; this is the
	# non-interactive form the SDK's own instructions use.
	system('bash', '-c', 'yes 2>/dev/null | "$1" --licenses >/dev/null 2>&1', 'bash', $sdkmanager);
	my $ok = 1;
	for my $id (@ids) {
		print "android update: sdkmanager --install $id (large; the NDK is hundreds of MB)\n";
		my $rc = system($sdkmanager, '--install', $id);
		my $code = $rc == -1 ? 1 : ($rc >> 8) || ($rc & 127 ? 1 : 0);
		if ($code) {
			print "android update: $id FAILED (exit $code)\n";
			$ok = 0;
		}
		else {
			print "android update: $id installed\n";
		}
	}
	return $ok;
}

# Every pinned version the app declares, as the property name -> value. The
# app repo lives outside this tree; without it there are no pins to protect and
# the keep count alone decides. compileSdkVersion names the platform directory
# (`android-36`), not a package id.
sub app_pins {
	my %pins;
	my $app = $ENV{'JAWNOS_APP_DIR'} || (($ENV{'HOME'} || '') . '/jawnos-app/termux-app');
	if (open(my $props, '<', "$app/gradle.properties")) {
		while (my $line = <$props>) {
			$pins{'ndk'} = $1 if $line =~ /^\s*ndkVersion\s*=\s*(\S+)\s*$/;
			$pins{'platform'} = $1 if $line =~ /^\s*compileSdkVersion\s*=\s*(\S+)\s*$/;
		}
		close $props;
	}
	# buildToolsVersion is optional in the app (AGP bundles aapt2/d8), so it is
	# only a pin when it is written down.
	if (open(my $gradle, '<', "$app/app/build.gradle")) {
		while (my $line = <$gradle>) {
			$pins{'build-tools'} = $1
				if $line =~ /^\s*buildToolsVersion\s*=?\s*["']([\d.]+)["']/;
		}
		close $gradle;
	}
	return \%pins;
}

# The build-tools version the Android Gradle plugin resolves, read from the AGP
# that the app uses (its builder jar carries the default). undef when it cannot
# be read, which means "do not prune build-tools": deleting the one the build
# needs only makes gradle fetch it again at build time.
sub agp_build_tools {
	my $app = $ENV{'JAWNOS_APP_DIR'} || (($ENV{'HOME'} || '') . '/jawnos-app/termux-app');
	open(my $gradle, '<', "$app/build.gradle") or return undef;
	local $/;
	my $text = <$gradle>;
	close $gradle;
	my $agp = JawnOS::Packages::parse_agp_version($text);
	return undef unless defined $agp;
	my $caches = ($ENV{'GRADLE_USER_HOME'} || (($ENV{'HOME'} || '') . '/.gradle'))
		. "/caches/modules-2/files-2.1/com.android.tools.build/builder/$agp";
	my ($jar) = glob("$caches/*/builder-$agp.jar");
	return undef unless defined $jar && -f $jar;
	require IO::Uncompress::Unzip;
	my $zip = IO::Uncompress::Unzip->new($jar) or return undef;
	while (1) {
		my $info = $zip->getHeaderInfo;
		last unless $info && defined $info->{'Name'};
		if ($info->{'Name'} eq 'com/android/builder/core/ToolsRevisionUtils.class') {
			my $class = '';
			while ($zip->read(my $chunk) > 0) { $class .= $chunk }
			return JawnOS::Packages::parse_agp_build_tools($class);
		}
		last unless $zip->nextStream;
	}
	return undef;
}

# Keep the pinned component and the newest $keep of each family; remove the
# rest. It runs with the update, so a report-only night still changes nothing on
# the machine. A failed removal is disk hygiene, not a verdict, so it never
# fails the check.
sub android_prune {
	my ($keep) = @_;
	my $root = sdk_root();
	return 0 unless defined $root;
	my $pins = app_pins();
	my $build_tools_pin = defined $pins->{'build-tools'} ? $pins->{'build-tools'} : agp_build_tools();
	my @families = (
		{ name => 'ndk',         pin => $pins->{'ndk'},      match => qr/^\d+(?:\.\d+)+$/ },
		{ name => 'build-tools', pin => $build_tools_pin,    match => qr/^\d+(?:\.\d+)+$/,
			require_pin => 1 },
		{ name => 'platforms',   pin => (defined $pins->{'platform'} ? "android-$pins->{'platform'}" : undef),
			match => qr/^android-[\d.]+$/, normalize => sub { $_[0] =~ /^android-([\d.]+)$/ ? $1 : $_[0] } },
	);
	require File::Path;
	for my $family (@families) {
		my $dir = "$root/$family->{'name'}";
		next unless -d $dir;
		if ($family->{'require_pin'} && !defined $family->{'pin'}) {
			print "android prune: cannot tell which build-tools AGP resolves; leaving them alone\n";
			next;
		}
		my @versions = grep { /$family->{'match'}/ } sdk_dir_names($dir);
		next unless @versions;
		my @remove = JawnOS::Packages::sdk_prune_plan(
			\@versions, $keep, $family->{'pin'}, $family->{'normalize'});
		for my $version (@remove) {
			my $path = "$dir/$version";
			next unless -d $path && !-l $path;
			if (File::Path::remove_tree($path, { error => \my $errors })) {
				print "android prune: removed $family->{'name'};$version (keeping the newest $keep"
					. (defined $family->{'pin'} ? " and the pinned $family->{'pin'}" : '') . ")\n";
			}
			else {
				print "android prune: could not remove $family->{'name'};$version\n";
			}
		}
	}
	return 0;
}

if ($freshness) {
	exit freshness_report(
		strict   => $strict,
		fixtures => $fixtures,
		only     => \@only,
		platform => $platform,
		json     => $json,
		android  => $android,
		android_update => $android_update,
		android_keep => $android_keep,
		report_file => $report_file,
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
