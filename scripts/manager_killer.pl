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
use File::Slurp qw(read_file write_file);
use Mojo::JSON qw(decode_json);
use Time::HiRes qw(sleep);

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
#
# --scope keeps only processes whose command line contains DIR. It is how the
# regression suite drives this without touching the live house.

my $kill_master = 0;
my $list_only = 0;
my $scope = '';
foreach my $arg (@ARGV) {
	if ($arg =~ /^master$/i) { $kill_master = 1 }
	elsif ($arg eq '--list' || $arg eq '--dry-run') { $list_only = 1 }
	elsif ($arg =~ /^--scope=(.+)$/) { $scope = $1 }
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
		$port = $config->{'working_port'}
			if $config && $config->{'working_port'} && $config->{'working_port'} =~ /^[0-9]+$/;
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
	# Same invocation Manager.pl uses (subs::sshd_start): the prefix's host keys
	# and an absolute AuthorizedKeysFile. A bare `sshd` here starts with Termux's
	# paths on Android, so key auth fails even though the port answers.
	my $prefix = $ENV{'PREFIX'} || '';
	my $home = $ENV{'HOME'} || '';
	if (length $prefix && length $home) {
		my @host_keys = grep { -f $_ } map { "$prefix/etc/ssh/ssh_host_$_\_key" } qw/ed25519 ecdsa rsa/;
		my @sshd = (
			'sshd', '-f', "$prefix/etc/ssh/sshd_config",
			'-o', "PidFile=$prefix/tmp/sshd.pid",
			'-o', "AuthorizedKeysFile=$home/.ssh/authorized_keys",
			'-o', 'StrictModes=no',
			'-o', "SetEnv=HOME=$home",
		);
		push @sshd, ('-h', $_) foreach @host_keys;
		system(@sshd);
	}
	else {
		system('sshd');
	}
}
