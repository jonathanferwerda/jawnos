package JawnOS::Platform::Paths;

# Where a house keeps its files, answered once. ./jawn, the master, every
# worker and the probe all read these roots, so a tree override or an XDG
# variable is honoured in one place instead of at a dozen call sites.
#
# Two roots, deliberately separate:
#   tree_dir/store_dir   code and the house's writable store (the same place in
#                        a checkout; split by JAWNOS_STORE_DIR for a package)
#   data_dir             per-user runtime state (~/.president)
# Nothing that reads the store requires the tree to be writable.
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
	store_dir config_path database_dir run_dir server_dir voices_dir releases_dir
	database_seed_path database_schema_path
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

# The runtime state (pid, sockets, transport tokens, job logs) lives under
# ~/.president. It is private per-user state, not the house's data store; the
# two roots stay separate because a packaged install can put the store in a
# system location while each user keeps their own runtime state.
sub data_dir {
	my %opt = @_;
	my $dir = _env(%opt)->{'JAWNOS_DATA_DIR'};
	return $dir if defined $dir && length $dir;
	my $home = home(%opt);
	return length($home) ? "$home/.president" : './.president';
}

# The house's writable store: the database and its backups, TLS material, voice
# models, staged app releases and config.json. A checkout keeps all of it in the
# tree (the default, unchanged); a packaged install points JAWNOS_STORE_DIR at
# /var/lib/jawnos or ~/.local/share/jawnos so /usr/share/jawnos stays read-only.
# Docker is the same idea: its volumes mount database/, server/, voices/ and
# releases/ under /app, so JAWNOS_STORE_DIR=/app reproduces the current layout.
#
# `root` is the tree to fall back to; a caller that resolved the tree from its
# own real path (subs::install_dir) passes it so a test sandbox or a symlinked
# checkout is not mistaken for the process's working directory.
sub store_dir {
	my %opt = @_;
	my $dir = _env(%opt)->{'JAWNOS_STORE_DIR'};
	return $dir if defined $dir && length $dir;
	my $root = $opt{'root'};
	return $root if defined $root && length $root;
	return tree_dir(%opt);
}

# The tree a read-only seed lives in: schema.sql and the factory seed stay with
# the code, never in the writable store.
sub _tree_root {
	my %opt = @_;
	my $root = $opt{'root'};
	return $root if defined $root && length $root;
	return tree_dir(%opt);
}

sub config_path {
	my %opt = @_;
	return File::Spec->catfile(store_dir(%opt), 'config.json');
}

sub database_dir {
	my %opt = @_;
	return File::Spec->catdir(store_dir(%opt), 'database');
}

# jawn's own run/ surface: sockets and watch files, not house data. It follows
# the store by default and keeps JAWNOS_RUN_DIR as the whole-path override the
# tests and a packaged install already use.
sub run_dir {
	my %opt = @_;
	my $dir = _env(%opt)->{'JAWNOS_RUN_DIR'};
	return $dir if defined $dir && length $dir;
	return File::Spec->catdir(store_dir(%opt), 'run');
}

sub server_dir {
	my %opt = @_;
	return File::Spec->catdir(store_dir(%opt), 'server');
}

sub voices_dir {
	my %opt = @_;
	return File::Spec->catdir(store_dir(%opt), 'voices');
}

sub releases_dir {
	my %opt = @_;
	return File::Spec->catdir(store_dir(%opt), 'releases');
}

sub database_seed_path {
	my %opt = @_;
	return File::Spec->catfile(_tree_root(%opt), 'database', 'initial.enc');
}

sub database_schema_path {
	my %opt = @_;
	return File::Spec->catfile(_tree_root(%opt), 'database', 'schema.sql');
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
