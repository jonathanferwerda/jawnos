#!/usr/bin/perl
#
# JawnOS dependency checker / installer.
#
#   perl scripts/jawnos_deps.pl            # report, then offer to install
#   perl scripts/jawnos_deps.pl --report   # report only, exit 1 if anything missing
#   perl scripts/jawnos_deps.pl --json     # machine-readable status
#   perl scripts/jawnos_deps.pl --sh       # print the install commands as a shell script
#   perl scripts/jawnos_deps.pl --install  # install without prompting
#
# Deliberately uses only core Perl so it runs before any CPAN module is present.

use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use JSON::PP ();

my ($report_only, $json, $sh, $install, $yes);
GetOptions(
	'report'  => \$report_only,
	'json'    => \$json,
	'sh'      => \$sh,
	'install' => \$install,
	'yes|y'   => \$yes,
) or die "bad options\n";

$install = 1 if $yes;

my $platform = detect_platform();

# --- required command line tools --------------------------------------------
# command => { apt => pkg, pacman => pkg, termux => pkg, label => "..." }
my @tools = (
	{ cmd => 'perl',      apt => 'perl',             pacman => 'perl',           termux => 'perl',             label => 'Perl' },
	{ cmd => 'openssl',   apt => 'openssl',          pacman => 'openssl',        termux => 'openssl',          label => 'OpenSSL' },
	{ cmd => 'sqlite3',   apt => 'sqlite3',          pacman => 'sqlite',         termux => 'sqlite',           label => 'SQLite' },
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
	WebService::Ollama
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

my (@missing_tools, @missing_modules);
foreach my $t (@tools) {
	push @missing_tools, $t unless have_command($t);
}
foreach my $m (@modules) {
	push @missing_modules, $m unless have_module($m);
}

if ($json) {
	my $data = {
		platform        => $platform,
		ok              => (@missing_tools + @missing_modules == 0) ? 1 : 0,
		missing_tools   => [ map { { cmd => $_->{'cmd'}, label => $_->{'label'}, package => pkg_for($_) } } @missing_tools ],
		missing_modules => [ @missing_modules ],
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

my $everything = (@missing_tools + @missing_modules == 0);
if ($everything) {
	print "\nEverything is installed. You're good to go.\n";
	exit 0;
}
exit 1 if $report_only;
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

if (@missing_tools) {
	my @pkgs = map { pkg_for($_) } @missing_tools;
	@pkgs = grep { defined $_ && $_ ne '' } @pkgs;
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

# --- final verdict -----------------------------------------------------------
my @still_tools = grep { !have_command($_) } @tools;
my @still_modules = grep { !have_module($_) } @modules;
if (!@still_tools && !@still_modules) {
	print "\nAll dependencies installed.\n";
	exit 0;
}
print "\nStill missing " . scalar(@still_tools) . " tool(s) and " . scalar(@still_modules) . " module(s).\n";
print "You may need to install them by hand (see the README).\n";
exit 1;

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

	my @pkgs = grep { defined $_ && $_ ne '' } map { pkg_for($_) } @missing_tools;
	if (@pkgs) {
		push @lines, '# command line tools';
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

	if (!@pkgs && !@missing_modules) {
		push @lines, 'echo "Every JawnOS dependency is already installed."';
	}

	return join("\n", @lines) . "\n";
}
