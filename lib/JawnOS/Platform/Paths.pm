package JawnOS::Platform::Paths;

# Where a house keeps its files, answered once. ./jawn, the master, every
# worker and the probe all read these roots, so a tree override or an XDG
# variable is honoured in one place instead of at a dozen call sites.
#
# Linux is the only backend implemented today. macOS (Application Support,
# /var/folders temp) and Windows (LOCALAPPDATA, %TEMP%) differ in the roots
# but not in the questions, and land with docs/platform-roadmap.md P2/P3.
# Nothing here starts a process, opens a socket or reads the database.
#
# Every function takes a %opt list. `env` may carry a hashref in place of
# %ENV, which is how a test exercises an override without touching the
# process environment; any other key is ignored. tmp_dir also takes `root`
# to name the temp candidate under test.
#
# JawnOS::Platform keeps thin wrappers over these names so the existing
# callers (JawnOS::Platform::home, ::tree_dir, ::data_dir, ::tool_path)
# compile and behave exactly as before.

use strict;
use warnings;

use Cwd ();
use File::Spec ();

use Exporter 'import';
our @EXPORT_OK = qw(
	home tree_dir data_dir config_dir state_dir tmp_dir
	log_path tool_path
);

# The environment a call reads: the injected one, or the process's own.
sub _env {
	my (%opt) = @_;
	my $env = $opt{'env'};
	return ref $env eq 'HASH' ? $env : \%ENV;
}

# Windows has no getpwuid at all - the call dies rather than returning nothing
# - and its home is USERPROFILE, with HOMEDRIVE+HOMEPATH as the older pair. One
# answer here serves the probe, the master and every worker, so the lookup is
# guarded in one place instead of at each caller.
sub home {
	my %opt = @_;
	my $env = _env(%opt);
	my $home = $env->{'HOME'};
	$home = $env->{'USERPROFILE'} if !defined $home || !length $home;
	if (!defined $home || !length $home) {
		my $drive = $env->{'HOMEDRIVE'} || '';
		my $path  = $env->{'HOMEPATH'} || '';
		$home = $drive . $path if length $drive || length $path;
	}
	if (!defined $home || !length $home) {
		$home = eval { (getpwuid($<))[7] } || '';
	}
	return defined $home ? $home : '';
}

# The tree is cwd-relative; a bundled app passes JAWNOS_DIR instead.
sub tree_dir {
	my %opt = @_;
	my $dir = _env(%opt)->{'JAWNOS_DIR'};
	return $dir if defined $dir && length $dir;
	my $cwd = eval { Cwd::getcwd() };
	return (defined $cwd && length $cwd) ? $cwd : '.';
}

# The runtime state (database, pid, sockets, logs) lives under ~/.president.
sub data_dir {
	my %opt = @_;
	my $dir = _env(%opt)->{'JAWNOS_DATA_DIR'};
	return $dir if defined $dir && length $dir;
	my $home = home(%opt);
	return length($home) ? "$home/.president" : './.president';
}

# XDG roots. Nothing reads config_dir yet; both are the answer the P2/P3
# backends will need, and today they match the paths the desktop already
# writes by hand (jawn's own XDG_STATE_HOME log seed, ~/.local/state/jawnos).
sub config_dir {
	my %opt = @_;
	my $xdg = _env(%opt)->{'XDG_CONFIG_HOME'};
	return File::Spec->catdir($xdg, 'jawnos') if defined $xdg && length $xdg;
	my $home = home(%opt);
	return length($home) ? File::Spec->catdir($home, '.config', 'jawnos') : './.config/jawnos';
}

sub state_dir {
	my %opt = @_;
	my $xdg = _env(%opt)->{'XDG_STATE_HOME'};
	return File::Spec->catdir($xdg, 'jawnos') if defined $xdg && length $xdg;
	my $home = home(%opt);
	return length($home)
		? File::Spec->catdir($home, '.local', 'state', 'jawnos')
		: './.local/state/jawnos';
}

# Android's root /tmp exists on an emulator but belongs to the shell user, so a
# writable check matters as much as the directory check. When it fails the
# house uses its own data dir, which is what the mobile tree already does.
# TMPDIR is deliberately not consulted: every worker must agree on one dir, and
# teaching gb::tmp_dir to follow TMPDIR is a separate decision.
sub tmp_dir {
	my %opt = @_;
	my $root = $opt{'root'};
	$root = '/tmp' unless defined $root && length $root;
	return $root if -d $root && -w $root;
	return data_dir(%opt);
}

# A named log under the state dir. An absolute name is already the answer.
sub log_path {
	my ($name, %opt) = @_;
	return undef unless defined $name && length $name;
	return $name if File::Spec->file_name_is_absolute($name);
	return File::Spec->catfile(state_dir(%opt), $name);
}

# The first executable named $name on PATH, or undef. Windows also tries the
# PATHEXT spellings because a command there is rarely the bare name.
sub tool_path {
	my ($name) = @_;
	return undef unless defined $name && length $name;
	my @names = ($name);
	push @names, "$name.exe", "$name.bat", "$name.cmd" if $^O eq 'MSWin32';
	foreach my $dir (File::Spec->path) {
		next unless defined $dir && length $dir;
		foreach my $candidate (@names) {
			my $path = File::Spec->catfile($dir, $candidate);
			return $path if -f $path && -x $path;
		}
	}
	return undef;
}

1;
