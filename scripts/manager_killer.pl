#!/usr/bin/perl

# A GUI launch or a bare desktop launcher never sources ~/.zshrc, so this would
# run with only the system @INC and die on 'Can't locate File::Slurp'. Find the
# same local::lib tree the shell would before the first 'use'.
BEGIN {
	my $base = (($ENV{HOME} || (getpwuid $<)[7] || '') . '/perl5/lib/perl5');
	if ($base =~ m{/} && -d $base) {
		my @dirs = ($base);
		if (opendir(my $dh, $base)) {
			for my $name (sort readdir $dh) {
				my $dir = "$base/$name";
				push @dirs, $dir
					if $name ne '.' && $name ne '..' && -d $dir
					&& ($name =~ /-linux-/ || $name =~ /^[0-9]+\.[0-9]+/);
			}
			closedir $dh;
		}
		my %in_inc = map { $_ => 1 } @INC;
		unshift @INC, grep { !$in_inc{$_} } @dirs;
		my $lib = join ':', @dirs;
		$ENV{PERL5LIB} = $ENV{PERL5LIB} ? "$lib:$ENV{PERL5LIB}" : $lib;
	}
}

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Slurp qw(read_file write_file);
use Mojo::JSON qw(decode_json);
use Time::HiRes qw(sleep time);
use JawnOS::Platform::Ports ();

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
my $scope = '';
my $cwd_scope = '';
foreach my $arg (@ARGV) {
	if ($arg =~ /^master$/i) { $kill_master = 1 }
	elsif ($arg eq '--list' || $arg eq '--dry-run') { $list_only = 1 }
	elsif ($arg eq '--ask-tree') { $ask_tree = 1 }
	elsif ($arg =~ /^--scope=(.+)$/) { $scope = $1 }
	elsif ($arg =~ /^--cwd=(.+)$/) { $cwd_scope = $1 }
}

my $self = $$;
my $parent = getppid();
my $android = (-e '/system/bin/init' || defined $ENV{'ANDROID_ROOT'}) ? 1 : 0;
my @SCRIPTS = qw(President.pl Manager.pl Websocket.pl teletype.pl watch.pl Music.pl Alarm.pl);
my %RANK = (master => 0, tree => 1, 'jawn-bt' => 2, ollama => 3, tts => 4, sshpass => 5, ssh => 6);

sub cmdline {
	my ($pid) = @_;
	open(my $fh, '<', "/proc/$pid/cmdline") or return '';
	local $/;
	my $line = <$fh>;
	close $fh;
	$line = '' unless defined $line;
	$line =~ s/\0/ /g;
	return $line;
}

sub exe_path {
	my ($pid) = @_;
	my $link = readlink("/proc/$pid/exe");
	return $link if defined $link && length $link;
	my ($first) = split /\s+/, &cmdline($pid);
	return defined $first ? $first : '';
}

# The checkout a process belongs to, read from its own cwd link. Undefined when
# the kernel will not show it (Android/SELinux, or a box without /proc) - the
# caller then keeps the old behaviour rather than missing its own tree.
sub cwd_of {
	my ($pid) = @_;
	return undef unless $pid && $pid =~ /^[0-9]+$/;
	my $dir = readlink("/proc/$pid/cwd");
	return undef unless defined $dir && length $dir;
	$dir =~ s/ \(deleted\)$//;
	return $dir;
}

sub in_cwd_scope {
	my ($pid) = @_;
	return 1 unless length $cwd_scope;
	my $dir = &cwd_of($pid);
	return 1 unless defined $dir && length $dir;
	return $dir eq $cwd_scope ? 1 : 0;
}

sub base {
	my ($path) = @_;
	$path = '' unless defined $path;
	$path =~ s{.*/}{};
	return $path;
}

sub state {
	my ($pid) = @_;
	open(my $fh, '<', "/proc/$pid/stat") or return '';
	my $line = <$fh>;
	close $fh;
	return '' unless defined $line;
	$line =~ s/^.*\)\s+//;
	my ($state) = split /\s+/, $line;
	return defined $state ? $state : '';
}

sub running {
	my ($pid) = @_;
	return 0 unless $pid && $pid =~ /^[0-9]+$/;
	return 0 unless kill 0, $pid;
	my $s = &state($pid);
	return 0 if $s eq 'Z' || $s eq 'X' || $s eq 'x';
	return 1;
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
	return 1 if $name =~ /^perl[0-9.]*$/;
	return 1 if $name eq 'libbin_perl.so';
	return 0;
}

sub is_master {
	my ($cmd, $exe) = @_;
	return 0 unless &is_perl_exe(&base($exe));
	return 0 if $cmd =~ / (?:-c|-e|-M) /;
	return $cmd =~ m{(?:^|[\s/])jawn(?:\s|$)} ? 1 : 0;
}

sub is_tree {
	my ($cmd, $exe) = @_;
	return 0 if $cmd =~ / (?:-c|-e|-M) /;
	my $perl = &is_perl_exe(&base($exe));
	if ($perl) {
		foreach my $name (@SCRIPTS) {
			return 1 if $cmd =~ m{(?:^|[\s/])\Q$name\E(?:\s|$)};
		}
		return 0;
	}
	# a direct shebang run carries the script as argv[0]
	my ($first) = split /\s+/, $cmd;
	return (defined $first && &base($first)) =~ /^(?:President|Manager|Websocket|teletype|watch|Music|Alarm)\.pl$/
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

# One /proc pass. Only processes that name a jawn program (or one of the few
# helpers the tree starts) are returned, and only when their executable still
# is perl - a shell, editor, compiler probe or a test that merely mentions a
# script in its command line is left alone.
sub scan_processes {
	my @found;
	opendir(my $procs, '/proc') or return @found;
	foreach my $pid (grep { /^[0-9]+$/ } readdir $procs) {
		next if $pid == $self || $pid == $parent;
		next unless &running($pid);
		my $cmd = &cmdline($pid);
		next unless length $cmd;
		next if length $scope && index($cmd, $scope) < 0;
		my $exe = &exe_path($pid);
		my $label = '';
		if ($kill_master && &is_master($cmd, $exe)) { $label = 'master' }
		elsif (&is_tree($cmd, $exe)) { $label = 'tree' }
		else { $label = &extra($cmd, $exe) }
		next unless $label;
		# A tree or master belongs to a checkout; a shared helper belongs to the
		# host. Only the former is held to --cwd.
		next if $label =~ /^(?:master|tree)$/ && !&in_cwd_scope($pid);
		push @found, { pid => $pid, label => $label, cmd => $cmd };
	}
	closedir $procs;
	return @found;
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
		kill 'TERM', $p->{'pid'};
		print "TERM $p->{'pid'} $p->{'label'}\n";
	}
	sleep 0.4;
	foreach my $p (@ordered) {
		next unless &running($p->{'pid'});
		kill 'KILL', $p->{'pid'};
		print "KILL $p->{'pid'} $p->{'label'}\n";
	}
	# A prefork manager can start a spare while it is being stopped. One more
	# pass catches it without the old four rounds of sleeps.
	foreach my $p (&scan_processes()) {
		next if grep { $_->{'pid'} == $p->{'pid'} } @ordered;
		next unless &running($p->{'pid'});
		kill 'KILL', $p->{'pid'};
		print "KILL $p->{'pid'} $p->{'label'} (spawned during the stop)\n";
	}
}

# The web port is the tree's last claim on the machine. If anything still
# listens there, it lost its manager; take the pids the socket names. (Skipped
# under --scope so a test run cannot touch the live tree's port.)
unless ($list_only || $scope) {
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
		next if $pid == $self || $pid == $parent;
		next unless &running($pid);
		next unless &in_cwd_scope($pid);
		kill 'KILL', $pid;
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
