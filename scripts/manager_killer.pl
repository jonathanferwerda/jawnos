#!/usr/bin/perl

# A GUI launch or a bare desktop launcher never sources ~/.zshrc, so this would
# run with only the system @INC and die on 'Can't locate File::Slurp'. Find the
# same local::lib tree the shell would before the first 'use'.
BEGIN {
	# Windows has no getpwuid - the call dies rather than answering - and a
	# service or a scheduled task has no HOME, so the home is resolved in the
	# same order as scripts/restart.pl: HOME, USERPROFILE, the older
	# HOMEDRIVE+HOMEPATH pair, then a guarded getpwuid. The unguarded getpwuid
	# this script used to call aborted it on Windows.
	my $home = $ENV{HOME};
	$home = $ENV{USERPROFILE} if !defined $home || !length $home;
	if (!defined $home || !length $home) {
		my $drive = $ENV{HOMEDRIVE} || '';
		my $path  = $ENV{HOMEPATH} || '';
		$home = $drive . $path if length $drive || length $path;
	}
	$home = eval { (getpwuid $<)[7] } if !defined $home || !length $home;
	$home = '' unless defined $home;
	my $base = $home . '/perl5/lib/perl5';
	if ($base =~ m{/} && -d $base) {
		my @dirs = ($base);
		# The local::lib subdirectory names differ per platform. Linux keeps
		# exactly the test it has always had, so its seeded @INC cannot move;
		# Windows names its own flavour directory instead.
		my $flavour = $^O eq 'MSWin32'
			? qr/-(?:MSWin32|cygwin)-|^(?:MSWin32|x86_64|i[3-9]86)\b/i
			: qr/-linux-/;
		if (opendir(my $dh, $base)) {
			for my $name (sort readdir $dh) {
				my $dir = "$base/$name";
				push @dirs, $dir
					if $name ne '.' && $name ne '..' && -d $dir
					&& ($name =~ $flavour || $name =~ /^[0-9]+\.[0-9]+/);
			}
			closedir $dh;
		}
		my %in_inc = map { $_ => 1 } @INC;
		unshift @INC, grep { !$in_inc{$_} } @dirs;
		# PERL5LIB is ';'-separated on Windows and ':' elsewhere.
		my $sep = $^O eq 'MSWin32' ? ';' : ':';
		my $lib = join $sep, @dirs;
		$ENV{PERL5LIB} = $ENV{PERL5LIB} ? "$lib$sep$ENV{PERL5LIB}" : $lib;
	}
}

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Slurp qw(read_file write_file);
use Mojo::JSON qw(decode_json);
use Time::HiRes qw(sleep time);
use JawnOS::Platform ();
use JawnOS::Platform::Ports ();
use JawnOS::Platform::Process ();

# Stop everything jawn runs: the tree and its workers, the BLE client, ollama,
# and whatever still holds the web port. This is the clean path behind the
# app's Stop button, a restart, and ./jawn's own shut_down.
#
# It used to run pkill and pgrep four times per name, each of them a process,
# and a match was anything whose command line mentioned the name - an editor
# with Manager.pl open looked exactly like a worker. This scans /proc once,
# reads each command line and executable, and signals the exact pids. In the
# common case the whole stop is two scans and a short TERM-to-KILL grace.
#
#   perl scripts/manager_killer.pl            # the tree (the master caller stays)
#   perl scripts/manager_killer.pl master     # the master too (the app's Stop)
#   perl scripts/manager_killer.pl --list     # what would be signalled
#   perl scripts/manager_killer.pl --scope=DIR --list
#   perl scripts/manager_killer.pl --cwd=DIR  # only this checkout's tree
#   perl scripts/manager_killer.pl --scope=DIR --ask-tree
#
# Before any signal, the stop asks the tree to leave over ~/.president/tree and
# waits up to two seconds for it to go, so the sweep below is only for a tree
# that did not answer. --list never asks, and --scope skips the ask because the
# channel is per-home rather than per-checkout; --ask-tree asks anyway.
#
# --scope keeps only processes whose command line contains DIR. It is how the
# regression suite drives this without touching the live house.
#
# --cwd keeps only tree processes whose working directory is DIR. The master
# chdirs to its own root before it starts a single child, so a child's cwd names
# the checkout it belongs to. Two checkouts on one box (a worktree, a smoke
# house) start Presidents with identical command lines; without this, the
# shutdown of one stops the tree of the other. The shared helpers (ollama, tts,
# ssh) are not scoped: they are the host's, not a checkout's.

my $kill_master = 0;
my $list_only = 0;
my $ask_tree = 0;
my $keep_coding = 0;
my $scope = '';
my $cwd_scope = '';
foreach my $arg (@ARGV) {
	if ($arg =~ /^master$/i) { $kill_master = 1 }
	elsif ($arg eq '--list' || $arg eq '--dry-run') { $list_only = 1 }
	elsif ($arg eq '--ask-tree') { $ask_tree = 1 }
	elsif ($arg eq '--keep-coding') { $keep_coding = 1 }
	elsif ($arg =~ /^--scope=(.+)$/) { $scope = $1 }
	elsif ($arg =~ /^--cwd=(.+)$/) { $cwd_scope = $1 }
}

# The process that started us. Windows has no getppid, and the runner exports
# the answer it already knows as JAWNOS_PARENT_PID; an unknown parent is 0.
my $self = $$;
my $parent = JawnOS::Platform::parent_pid();
my $android = (-e '/system/bin/init' || defined $ENV{'ANDROID_ROOT'}) ? 1 : 0;
# President and the programs it starts. The last three are the ones a Windows
# Stop used to leave behind: each subprocessor job, the utility scheduler and the
# Coding daemon - none of them is in the pty the runner ends.
my @SCRIPTS = qw(President.pl Manager.pl Websocket.pl teletype.pl watch.pl Music.pl Alarm.pl
	subprocessor_worker.pl utility_jobs.pl Coding.pl);
# A direct shebang run carries the script as argv[0] and names no interpreter;
# the same list answers it, so the two can never drift.
my $SCRIPTS_RE = join '|', map { quotemeta } @SCRIPTS;
my %RANK = (master => 0, tree => 1, 'jawn-bt' => 2, ollama => 3, tts => 4, sshpass => 5, ssh => 6);

# The executable for a table row: the link when the kernel shows it, otherwise
# argv[0] (a direct shebang run). Both come from the one scan, so this no longer
# re-reads /proc per pid.
sub exe_path {
	my ($exe, $cmd) = @_;
	return $exe if defined $exe && length $exe;
	my ($first) = split /\s+/, $cmd;
	return defined $first ? $first : '';
}

# The checkout a process belongs to, read from its own cwd link. Undefined when
# the kernel will not show it (Android/SELinux, or a box without /proc) - the
# caller then keeps the old behaviour rather than missing its own tree.
sub cwd_of {
	my ($pid) = @_;
	my $dir = JawnOS::Platform::Process::cwd($pid);
	return undef unless length $dir;
	$dir =~ s/ \(deleted\)$//;
	return $dir;
}

# The same question against a cwd already read by one table pass, so the scan
# does not follow each link twice. An unreadable cwd keeps the old answer
# (in scope): a missed stop wedges the next boot.
sub in_cwd_scope_value {
	my ($dir) = @_;
	return 1 unless length $cwd_scope;
	return 1 unless defined $dir && length $dir;
	$dir =~ s/ \(deleted\)$//;
	return $dir eq $cwd_scope ? 1 : 0;
}

sub in_cwd_scope {
	my ($pid) = @_;
	return 1 unless length $cwd_scope;
	return &in_cwd_scope_value(&cwd_of($pid));
}

sub base {
	my ($path) = @_;
	$path = '' unless defined $path;
	$path =~ s{.*/}{};
	# Windows names a path with backslashes; POSIX treats them as ordinary
	# characters, so only there is a second separator.
	$path =~ s{.*\\}{} if $^O eq 'MSWin32';
	return $path;
}

sub running {
	my ($pid) = @_;
	return 0 unless $pid && $pid =~ /^[0-9]+$/;
	return JawnOS::Platform::Process::running($pid) ? 1 : 0;
}

# The tree also serves ~/.president/tree: one JSON line in, one JSON line out,
# and {"cmd":"stop"} is a request to leave rather than a signal. The client is
# in perl/control.pl, which pulls in JawnOS::Transport and Mojo::JSON, so it is
# loaded here, in an eval: a GUI launch runs this with a thin @INC, and a stop
# must never die because the client could not be loaded.
sub ask_tree_stop {
	my $loaded = eval {
		require "$FindBin::Bin/../perl/control.pl";
		1;
	};
	return 0 unless $loaded;
	return eval { &control::ask_tree_stop(reason => 'the app asked for a stop') } ? 1 : 0;
}

sub is_perl_exe {
	my ($name) = @_;
	# Windows names the interpreter perl.exe; the patterns below are the bare
	# name. Without this the command-line sweep matches nothing there, and a
	# desktop Stop has only the tree's own answer to rely on.
	$name =~ s/\.exe$//i if $^O eq 'MSWin32';
	return 1 if $name =~ /^perl[0-9.]*$/;
	return 1 if $name eq 'libbin_perl.so';
	return 0;
}

sub is_master {
	my ($cmd, $exe) = @_;
	return 0 unless &is_perl_exe(&base($exe));
	return 0 if $cmd =~ / (?:-c|-e|-M) /;
	return $cmd =~ m{(?:^|[\s/\\])jawn(?:\s|$)} ? 1 : 0;
}

sub is_coding {
	my ($cmd) = @_;
	return $cmd =~ m{(?:^|[\s/\\])Coding\.pl(?:\s|$)} ? 1 : 0;
}

sub is_tree {
	my ($cmd, $exe) = @_;
	return 0 if $cmd =~ / (?:-c|-e|-M) /;
	my $perl = &is_perl_exe(&base($exe));
	if ($perl) {
		foreach my $name (@SCRIPTS) {
			return 1 if $cmd =~ m{(?:^|[\s/\\])\Q$name\E(?:\s|$)};
		}
		return 0;
	}
	# a direct shebang run carries the script as argv[0]
	my ($first) = split /\s+/, $cmd;
	return (defined $first && &base($first)) =~ /^(?:$SCRIPTS_RE)$/
		? 1 : 0;
}

sub extra {
	my ($cmd, $exe) = @_;
	my $name = &base($exe);
	return 'ollama' if $name eq 'ollama';
	return 'ollama' if $name =~ /^(?:runsv|runsvdir|sv)$/ && $cmd =~ /(?:^|\s)ollama(?:\s|$)/;
	return 'jawn-bt' if &is_perl_exe($name) && $cmd =~ /jawn-bt\s+listen/;
	return 'tts' if $name =~ /^termux-tts-spea/;
	return 'sshpass' if $name eq 'sshpass';
	return 'ssh' if $android && $name eq 'ssh';
	return '';
}

# One process table pass. Only processes that name a jawn program (or one of the
# few helpers the tree starts) are returned, and only when their executable
# still is perl - a shell, editor, compiler probe or a test that merely mentions
# a script in its command line is left alone. cwd is read in the same pass so a
# tree can be held to its checkout without following the link again.
#
# --keep-coding leaves Coding.pl alone: the master runs this sweep in its own
# tree restart, and the Coding daemon is deliberately not part of the tree there
# (a minutes-long model run must not die in a restart). A desktop Stop or a
# Restart comes in without the flag and takes it.
sub scan_processes {
	my @found;
	foreach my $proc ( @{ JawnOS::Platform::Process::table(cwd => 1, exe => 1) } ) {
		my $pid = $proc->{'pid'};
		next if $pid == $self || ($parent && $pid == $parent);
		next unless &live($proc);
		my $cmd = $proc->{'cmdline'};
		next unless length $cmd;
		next if length $scope && index($cmd, $scope) < 0;
		next if $keep_coding && &is_coding($cmd);
		my $exe = &exe_path($proc->{'exe'}, $cmd);
		my $label = '';
		if ($kill_master && &is_master($cmd, $exe)) { $label = 'master' }
		elsif (&is_tree($cmd, $exe)) { $label = 'tree' }
		else { $label = &extra($cmd, $exe) }
		next unless $label;
		# A tree or master belongs to a checkout; a shared helper belongs to the
		# host. Only the former is held to --cwd.
		next if $label =~ /^(?:master|tree)$/ && !&in_cwd_scope_value($proc->{'cwd'});
		push @found, { pid => $pid, label => $label, cmd => $cmd };
	}
	return @found;
}

# The old scan asked kill(0) before trusting a pid. A row exists only because
# its stat was read, so the only part of that test still worth keeping is the
# one kill(0) on its own cannot answer: a zombie is not something to stop.
sub live {
	my ($proc) = @_;
	my $state = $proc->{'state'} || '';
	return 0 if $state eq 'Z' || $state eq 'X' || $state eq 'x';
	return 1;
}

my @found = &scan_processes();
my @ordered = sort { $RANK{$a->{'label'}} <=> $RANK{$b->{'label'}} || $a->{'pid'} <=> $b->{'pid'} } @found;

if ($list_only) {
	printf "%d\t%s\t%s\n", $_->{'pid'}, $_->{'label'}, $_->{'cmd'} foreach @ordered;
	exit 0;
}

# Ask before signalling. The channel is per-home, not per-checkout, so a scoped
# run stays off it unless the caller opts in; --list never touches it.
my $asked = 0;
if (!$scope || $ask_tree) {
	$asked = &ask_tree_stop();
	print "manager_killer: asked the tree to stop cleanly\n" if $asked;
}

# Give it a bounded moment to go on its own, but only when the scan found tree
# pids to wait for: no tree, no delay.
if ($asked) {
	my @tree_pids = grep { $_->{'label'} eq 'tree' } @ordered;
	if (@tree_pids) {
		my $deadline = time + 2;
		while (time < $deadline) {
			last unless grep { &running($_->{'pid'}) } @tree_pids;
			sleep 0.05;
		}
	}
}

if (@ordered) {
	print "manager_killer: " . scalar(@ordered) . " process(es)\n";
	foreach my $p (@ordered) {
		JawnOS::Platform::Process::signal('TERM', $p->{'pid'});
		print "TERM $p->{'pid'} $p->{'label'}\n";
	}
	sleep 0.4;
	foreach my $p (@ordered) {
		next unless &running($p->{'pid'});
		JawnOS::Platform::Process::signal('KILL', $p->{'pid'});
		print "KILL $p->{'pid'} $p->{'label'}\n";
	}
	# A prefork manager can start a spare while it is being stopped. One more
	# pass catches it without the old four rounds of sleeps.
	foreach my $p (&scan_processes()) {
		next if grep { $_->{'pid'} == $p->{'pid'} } @ordered;
		next unless &running($p->{'pid'});
		JawnOS::Platform::Process::signal('KILL', $p->{'pid'});
		print "KILL $p->{'pid'} $p->{'label'} (spawned during the stop)\n";
	}
}

# The web port is the tree's last claim on the machine. If anything still
# listens there, it lost its manager; take the pids the socket names. (Skipped
# under --scope so a test run cannot touch the live tree's port.)
# `ss` and /dev/null are POSIX, and a listener is held to --cwd, which Windows
# cannot answer. There the command-line sweep above is the whole stop: it names
# the tree and the master by their program, which is the only identity Windows
# exposes. Skipping the port read also keeps a Windows stop from killing an
# unrelated listener on the same port.
unless ($list_only || $scope || $^O eq 'MSWin32') {
	my $working_port = &working_port();
	my %listeners;
	my $ss = `ss -tlnp 2>/dev/null`;
	foreach my $line (split /\n/, $ss) {
		next unless $line =~ /:(\d+)\s/;
		my $port = $1;
		next unless $port == $working_port || $port == 3000;
		while ($line =~ /pid=(\d+)/g) { $listeners{$1} = 1 }
	}
	foreach my $pid (sort { $a <=> $b } keys %listeners) {
		next if $pid == $self || ($parent && $pid == $parent);
		next unless &running($pid);
		next unless &in_cwd_scope($pid);
		JawnOS::Platform::Process::signal('KILL', $pid);
		print "KILL $pid listener\n";
	}
}

sub working_port {
	my $port = 3000;
	my $config_file = -e './config.json' ? './config.json'
		: ($ENV{'HOME'} ? "$ENV{'HOME'}/jawnos/config.json" : '');
	if ($config_file && -e $config_file) {
		my $config = eval { decode_json(scalar read_file($config_file)) };
		if ($config) {
			$port = JawnOS::Platform::Ports::base(
				working_port => $config->{'working_port'},
				default      => 3000,
				ceiling      => 65536,
			);
		}
	}
	return $port;
}

# ollama: jawn spawns its own; on the phone a runit service wants a second one,
# dies on the taken port and runsv retries it forever. Take the service down
# first and leave the down file, or the runsv that runsvdir starts in its place
# brings it straight back. jawn starts its own ollama on the next Start.
unless ($list_only || $scope) {
	my $prefix = $ENV{'PREFIX'}
		|| ( -d '/data/data/com.jawnos/files/usr' ? '/data/data/com.jawnos/files/usr'
			: '/data/data/com.termux/files/usr' );
	my $ollama_service = "$prefix/var/service/ollama";
	if (-x "$prefix/bin/sv" && -d $ollama_service) {
		print "manager_killer: starting the ollama service down\n";
		local $ENV{'SVDIR'} = "$prefix/var/service";
		system("$prefix/bin/sv", 'down', 'ollama');
		eval { write_file("$ollama_service/down", "") };
	}
}

if ($android && !$list_only && !$scope) {
	# Stop takes the tree down, and the daemon it started with it, so what comes
	# back after a Start is this script's own. Same builder the tree uses
	# (subs::sshd_command) so the two cannot drift, and subs::sshd_start's probe
	# so a daemon that outlived the tree is not doubled. No bare `sshd` fallback:
	# with Termux's paths on Android the port answers and every key is refused
	# (the phone, 2026-10-31). The tree is found from this file's path, not the
	# cwd: a restart can run this from anywhere.
	my $tree = $0;
	$tree =~ s{/+[^/]+$}{};
	$tree =~ s{/+scripts$}{};
	if (-f "$tree/perl/subroutines.pl") {
		require "$tree/perl/subroutines.pl";
		&subs::sshd_start();
	}
	else {
		print "manager_killer: no tree at $tree; sshd not started\n";
	}
}
