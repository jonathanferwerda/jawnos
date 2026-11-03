package subs;

# Process: the warranty and heartbeat a subprocessor stamps on its record, and
# the reaper that enforces them. Loaded on demand by
# lib/JawnOS/Domain/Loader.pm, and required directly by ./jawn (the master owns
# the process-watch socket and the records).
#
# A warranty is the house's usual unit: an absolute epoch-millisecond moment, or
# subs::forever_warranty(). A finite warranty is a deadline from the moment the
# child started. A resident loop or a server is 'forever' because its own stop
# path - or the master's death - is what ends it.
#
# 'Forever' alone cannot tell a working loop from a wedged one, so a resident
# loop also carries a heartbeat lease: it calls subs::subprocessor_heartbeat()
# once per turn, and a lease older than the gap in %HEARTBEAT is a wedge.
#
# A wrapper that runs a command (ffmpeg, rec, play) has a grandchild in its
# process group. The reaper will not expire an ancestor while a descendant is
# still alive - it pushes the ancestor's deadline and heartbeat forward for the
# descendant's run - and when it does kill, it signals the group, so the
# grandchild leaves with its wrapper instead of being orphaned.
#
# 'run_p' does not fork at the call. It queues the fork on the next tick of the
# caller's loop, so the child starts when the request that asked for it finally
# returns - on a phone under load that is seconds later, and every job queued in
# the same request starts then too. The warranty was stamped at the ask, so a 5s
# header render was already half spent before its process existed, and a busy
# request spent all of it: the reaper TERM'd the child seconds into its work, no
# header came back, and the models queued behind it waited out their own lease in
# a worker the fork had closed. A job asked for that way starts its warranty when
# its process does (Deferred), so the clock it is judged by is the one it runs on.
#
# Nothing here reads the database, so the master can require it before President
# or the domain loader exists. /proc is read for the pid-reuse guard, the
# descendant scan and a deferred start.
use strict;
use warnings;
no warnings 'once';
use File::Temp qw(tempfile);
use POSIX ();

# The warranty seed map, keyed by the name a caller passes to
# subs::subprocessor. Values are a compact duration ('5s', '30m', '2h') or
# 'forever'. An unmapped name is 'forever': a new call must never be killed on
# its first slow run just because nobody listed it. Names with a dynamic suffix
# (a port count, a signatorial prefix) match the longest key that is a prefix of
# the name.
our %WARRANTY = (
	# Resident supervisors: the master's death, not a deadline, ends these.
	'Dev Locker Server'              => 'forever',
	'Dev WS Server'                  => 'forever',
	'Dev Main Server'                => 'forever',
	'Pro Locker Server'              => 'forever',
	'Pro WS Server'                  => 'forever',
	'Pro Main Server'                => 'forever',
	'Pro Alarm Server'               => 'forever',
	'Watch Server'                   => 'forever',
	'TTY Server'                     => 'forever',
	'TTY WS Server'                  => 'forever',
	'utility functions'              => 'forever',
	'Minion Worker'                  => 'forever',
	'whisper server'                 => 'forever',
	'ollama serve'                   => 'forever',
	'slow loops'                     => 'forever',
	'house levels'                   => 'forever',
	'device mdns sync'               => 'forever',
	'house advertise'                => 'forever',
	'lan presence beacon'            => 'forever',
	'lan presence listener'          => 'forever',
	'lan mesh wake'                  => 'forever',
	'ble adopt scan'                 => 'forever',
	'wake schedule'                  => 'forever',
	'address directory'              => 'forever',
	'app release sync'               => 'forever',
	'evaluation schedules'           => 'forever',
	'evaluation dispatch'            => 'forever',
	# Starts sshd and probes for it every minute; nothing in it can outlive a turn,
	# so a wedge in the loop is the only thing that can outlive the warranty.
	'sshd watcher'                   => 'forever',

	# Holders and players that run until someone stops them.
	'tunnel holder wss'              => 'forever',
	'music play'                     => 'forever',
	'Video file converter'           => 'forever',
	'Audio file converter'           => 'forever',
	'audio player'                   => 'forever',

	# One-shot jobs: the time the work should take, with room for a busy box.
	# A header render is the fast half (the window render is the fork).
	'address report'                 => '120s',
	'remote availability'            => '120s',
	'appt_header_printer'            => '10s',
	'folders open with'              => '10s',
	'thumb shredder'                 => '10s',
	'padlock time extender'          => '10s',
	'centre view'                    => '60s',
	'db cache updater'               => '60s',
	'clothesline centreview cacher'  => '120s',
	'reset remote relay'             => '30s',
	'utility remote relay'           => '30s',
	'nfc remote relay'               => '30s',
	'delete app remote relay'        => '30s',
	'app measures remote relay'      => '30s',
	'task remote relay'              => '30s',
	'go approval relay'              => '30s',
	'go approval clear relay'        => '30s',
	'padlock biometric relay'        => '30s',
	'padlock unlock relay'           => '30s',
	'padlock open relay'             => '30s',
	'padlock key show relay'         => '30s',
	'padlock key show relay onward'  => '30s',
	'mail message processor'         => '60s',
	'embedded mail msg'              => '60s',
	'Mail Assistant'                 => '120s',
	'Assistant'                      => '120s',
	'lorawan send'                   => '60s',
	'lora embedded sender'           => '60s',
	'appointment models'             => '60s',
	'schedule repeats'               => '30s',
	'budget runner'                  => '60s',
	'continent record anyway'        => '60s',
	'embedded toggle sender'         => '30s',
	'embedded toggle push'           => '30s',
	'Watch notification sender'      => '30s',
	'ble button press'               => '30s',
	'ble switch press'               => '30s',
	'ble measure press'              => '30s',
	'ble send'                       => '30s',
	'ble yield'                      => '30s',
	'ble host connect'               => '60s',
	'ble adopt connect'              => '60s',
	'clock relay'                    => '30s',
	'clock control push'             => '30s',
	'clock appointment push'         => '30s',
	'clock alarm push'               => '30s',
	'clock alarm sound'              => '60s',
	'clock preview'                  => '30s',
	'clock device broadcast'         => '30s',
	'sms msg send'                   => '30s',
	'send telephone'                 => '30s',
	'now me push'                    => '30s',
	'embedded app deleter'           => '60s',
	'system monitor'                 => '60s',
	'tunnel peer enrol'              => '30s',
	'tls issue'                      => '5m',
	'voice sync'                     => '10m',
	'voice ingest'                   => '2m',
	'document scanner'               => '2m',
	'backup shredder'                => '2m',
	'synth ws player'                => '10m',
	'Synth player'                   => '10m',
	'Audio file player'              => '10m',
	'say it'                         => '10m',
	'watch reply wifi'               => '10m',
	'watch reply audio'              => '10m',
	'app release sync (on demand)'   => '30m',
	'crew advert (on demand)'        => '60s',
	'manual ble adopt scan'          => '60s',
	'reset file encrypt'             => '5m',
	'run command'                    => '5m',
	'network helper'                 => '5m',
	'teletype backup'                => '10m',
	'remote upgrade'                 => '30m',
	'merge database'                 => '30m',
	'remote snapshot'                => '30m',
	'qa install'                     => '30m',
);

# The longest a resident loop may go without proving it is alive. Each value is
# comfortably longer than the loop's own longest sleep plus its slowest turn, so
# a normal cycle never misses; a wedge does. A name with no entry has no lease
# and is only bounded by its warranty (servers and the Minion worker have their
# own liveness machinery).
our %HEARTBEAT = (
	'app release sync'      => '30m',
	'slow loops'            => '15m',
	'house levels'          => '10m',
	'device mdns sync'      => '5m',
	'house advertise'       => '5m',
	'lan presence beacon'   => '2m',
	'lan presence listener' => '2m',
	'lan mesh wake'         => '2m',
	'ble adopt scan'        => '20m',
	'wake schedule'         => '10m',
	'address directory'     => '10m',
	'evaluation schedules'  => '20m',
	'evaluation dispatch'   => '10m',
	'utility functions'     => '5m',
	'whisper server'        => '10m',
	'sshd watcher'          => '5m',
);

# The seed lookup both maps share: exact first, then the longest key the name
# starts with, so 'tunnel holder wss 4 ports' finds 'tunnel holder wss'.
my $seed_for = sub {
	my ($map, $name) = @_;
	return undef unless defined $name && length $name;
	return $map->{$name} if exists $map->{$name};
	my $best;
	foreach my $key (keys %{$map}) {
		next unless index($name, $key) == 0;
		$best = $key if !defined $best || length($key) > length($best);
	}
	return defined $best ? $map->{$best} : undef;
};

# Resolve a warranty spec to an absolute moment. The sign is ignored because a
# warranty is always ahead of now - the house already writes '-1d' to mean a day
# ahead for a cache row or a ticket. An unreadable spec is 'forever', never a
# deadline that kills work nobody meant to bound. $now = 0 returns the span
# itself, which is how a heartbeat lease is read.
sub subprocessor_warranty_at {
	my ($spec, $now) = @_;
	$now = time() * 1000 unless defined $now && $now =~ /^\d+$/;
	return 32503680000000 unless defined $spec;
	$spec =~ s/^\s+|\s+$//g;
	return 32503680000000 if $spec eq '' || $spec =~ /^forever$/i;
	return $spec + 0 if $spec =~ /^\d{12,}$/;
	my %unit = (
		s => 1000,
		m => 60_000,
		h => 3_600_000,
		d => 86_400_000,
		w => 604_800_000,
		y => 31_536_000_000,
	);
	if ($spec =~ /^[-+]?(\d+(?:\.\d+)?)\s*([smhdwy])$/i) {
		my ($count, $which) = ($1, lc $2);
		return $now + $count * $unit{$which};
	}
	return 32503680000000;
}

# The warranty spec the seed map holds for a subprocessor name, or undef.
sub subprocessor_warranty_for {
	return $seed_for->(\%WARRANTY, $_[0]);
}

# The heartbeat lease spec for a name, or undef when it has none.
sub subprocessor_heartbeat_for {
	return $seed_for->(\%HEARTBEAT, $_[0]);
}

# Prove this subprocessor is still working. A resident loop calls this once per
# turn; the master stamps heartbeat_at on the record and the reaper expires a
# lease that has gone quiet. Throttled to once a second, so a tight loop does not
# flood the socket. The wrapper sets $gb::subprocessor_uuid/name for the child.
our $heartbeat_sent_at;
sub subprocessor_heartbeat {
	my ($name) = @_;
	my $now = &subs::rightNow();
	return 0 if defined $heartbeat_sent_at && $now - $heartbeat_sent_at < 1000;
	$heartbeat_sent_at = $now;
	my $file = &subs::home('~/.process_watch');
	return 0 unless $file && -e $file;
	$name = $gb::subprocessor_name unless defined $name && length $name;
	&subs::unix_socket_sender($file, {
		status => 'heartbeat',
		parent => getppid(),
		pid    => $$,
		uuid   => defined $gb::subprocessor_uuid ? $gb::subprocessor_uuid : '',
		name   => defined $name ? $name : '',
		at     => $now,
	});
	return 1;
}

# Run a command as a tracked child with its own warranty. The wrapper that calls
# this (a subprocessor child) is waiting on the command, so the command is a
# grandchild; without its own record the reaper could only see it as an unnamed
# process-group member and would extend the wrapper for as long as it lived - a
# hung ffmpeg kept its ancestor alive forever. With this record the reaper bounds
# the command itself, extends the wrapper only to the command's deadline, and
# kills the command by pid (its pgid is 0, so the wrapper's group is untouched).
#
# $command is an arrayref (exec list, no shell) or a string (run by /bin/sh -c).
# $params:
#   name        the record name and, unless warranty is given, its seed key
#   warranty    a spec or absolute moment; default 60s
#   stdout      'capture' (default) or a path to write
#   stderr      'stdout' (default), 'inherit', or a path
#   stdin       data to write to the command; stdin_path names a file instead
#   cwd, env    optional
#   record      0 to skip the process-watch record and heartbeats (tests)
# Returns { ok, status, exit, signal, timed_out, output, pid, error }.
sub subprocessor_command {
	my ($command, $params) = @_;
	$params ||= {};
	my $name = (defined $params->{'name'} && length $params->{'name'}) ? $params->{'name'} : 'command';
	my $spec = defined $params->{'warranty'}
		? $params->{'warranty'}
		: &subs::subprocessor_warranty_for($name);
	$spec = '60s' unless defined $spec && length $spec;
	my $started = &subs::rightNow();
	my $warranty = &subs::subprocessor_warranty_at($spec, $started);
	my $forever = &subs::forever_warranty();
	my $record = defined $params->{'record'} ? $params->{'record'} : 1;

	my $out_setting = defined $params->{'stdout'} ? $params->{'stdout'} : 'capture';
	my $capture = ($out_setting eq 'capture') ? 1 : 0;
	my $out_path = $out_setting;
	my $out_tmp;
	if ($capture) {
		my ($out_fh, $tmp) = tempfile('jawnos-command-XXXXXX', TMPDIR => 1, UNLINK => 0);
		close $out_fh if $out_fh;
		$out_path = $out_tmp = $tmp;
	}

	my $stdin_path = $params->{'stdin_path'} || '/dev/null';
	my $in_tmp;
	if (!defined $params->{'stdin_path'} && defined $params->{'stdin'}) {
		my ($in_fh, $tmp) = tempfile('jawnos-command-in-XXXXXX', TMPDIR => 1, UNLINK => 0);
		if ($in_fh) {
			print {$in_fh} $params->{'stdin'};
			close $in_fh;
			$stdin_path = $in_tmp = $tmp;
		}
	}

	my $stderr = defined $params->{'stderr'} ? $params->{'stderr'} : 'stdout';

	my $pid = fork();
	if (!defined $pid) {
		unlink $out_tmp if defined $out_tmp;
		unlink $in_tmp if defined $in_tmp;
		return { ok => 0, error => "could not fork: $!" };
	}
	if (!$pid) {
		open(STDIN, '<', $stdin_path) or POSIX::_exit(127);
		open(STDOUT, '>', $out_path) or POSIX::_exit(127);
		if ($stderr eq 'stdout' || $stderr eq 'capture') {
			open(STDERR, '>&', \*STDOUT) or POSIX::_exit(127);
		}
		elsif ($stderr ne 'inherit') {
			open(STDERR, '>', $stderr) or POSIX::_exit(127);
		}
		if (defined $params->{'cwd'}) {
			chdir $params->{'cwd'} or POSIX::_exit(127);
		}
		if (ref $params->{'env'} eq 'HASH') {
			foreach my $key (keys %{$params->{'env'}}) {
				$ENV{$key} = $params->{'env'}->{$key};
			}
		}
		if (ref $command eq 'ARRAY') { exec(@{$command}); }
		else { exec('/bin/sh', '-c', $command); }
		POSIX::_exit(127);
	}

	# The command inherits the wrapper's process group (pgid 0 here), so a group
	# kill of the wrapper still takes it, while its own expiry kills only it.
	my $start_ticks = '';
	if (open(my $stat_fh, '<', "/proc/$pid/stat")) {
		my $stat_line = <$stat_fh>;
		close $stat_fh;
		if (defined $stat_line && (my $close = rindex($stat_line, ')')) >= 0) {
			my @stat_field = split ' ', substr($stat_line, $close + 2);
			$start_ticks = $stat_field[19] // '';
		}
	}
	my $child = {
		parent => $$,
		pid => $pid,
		name => $name,
		status => 'start',
		timestamp => $started,
		start_timestamp => $started,
		uuid => &subs::random_string_creator(10),
		warranty => $warranty,
		warranty_spec => $spec,
		start_ticks => $start_ticks,
		pgid => 0,
	};
	my $watch;
	if ($record) {
		$watch = &subs::home('~/.process_watch');
		&subs::unix_socket_sender($watch, $child) if $watch && -e $watch;
	}

	my $status;
	my $timed_out = 0;
	my $deadline = ($warranty < $forever) ? $warranty : 0;
	while (1) {
		my $done = waitpid($pid, POSIX::WNOHANG);
		if ($done == $pid) { $status = $?; last; }
		if ($done == -1 && $!{ECHILD}) { $status = -1; last; }
		if ($deadline && &subs::rightNow() > $deadline) {
			$timed_out = 1;
			kill 'TERM', $pid;
			my $give_up = time + 2;
			while (1) {
				my $reaped = waitpid($pid, POSIX::WNOHANG);
				if ($reaped == $pid) { $status = $?; last; }
				if ($reaped == -1 && $!{ECHILD}) { $status = -1; last; }
				last if time > $give_up;
				select(undef, undef, undef, 0.1);
			}
			if (!defined $status) {
				kill 'KILL', $pid;
				waitpid($pid, 0);
				$status = $?;
			}
			last;
		}
		&subs::subprocessor_heartbeat() if $record;
		select(undef, undef, undef, 0.25);
	}

	if ($record) {
		$child->{'status'} = 'stop';
		$child->{'stop_timestamp'} = &subs::rightNow();
		$child->{'exit'} = (defined $status && $status >= 0) ? ($status >> 8) : 127;
		&subs::unix_socket_sender($watch, $child) if $watch && -e $watch;
	}

	my $output = '';
	if ($capture && defined $out_tmp && -e $out_tmp) {
		if (open(my $fh, '<', $out_tmp)) {
			local $/;
			$output = <$fh> // '';
			close $fh;
		}
	}
	unlink $out_tmp if defined $out_tmp;
	unlink $in_tmp if defined $in_tmp;

	my $exit = (defined $status && $status >= 0) ? ($status >> 8) : 127;
	my $signal = (defined $status && $status > 0) ? ($status & 127) : 0;
	my $error;
	$error = "the command did not finish within $spec" if $timed_out;
	$error = 'the command was reaped before it returned' if !$error && defined $status && $status < 0;
	return {
		ok => (!$timed_out && defined $status && $status == 0) ? 1 : 0,
		status => defined $status ? $status : 127,
		exit => $exit,
		signal => $signal,
		timed_out => $timed_out,
		output => $output,
		pid => $pid,
		error => $error,
	};
}

# One reaper pass over %subprocesses (the shape ./jawn keeps:
# { parent_pid => { subprocesses => { pid => record } } }).
#
# - A record whose pid is gone is forgotten. A child killed with SIGKILL never
#   writes its stop record, so that entry used to live for the master's lifetime.
# - A live descendant keeps its ancestors alive: while a process in the record's
#   process group is still running, the record's deadline and heartbeat are
#   pushed forward, and a tracked child extends its parent chain. That is the
#   grandchild's run being added to its parent's and grandparent's warranty.
# - A finite warranty or a stale heartbeat lease past its moment gets one TERM,
#   then a KILL after the grace, then the record goes. 'Forever' with no lease
#   is never expired. A kill signals the record's process group when the wrapper
#   became its own group leader, so the grandchildren leave with it.
# - start_ticks (from /proc/<pid>/stat) is the pid-reuse guard: a pid the OS has
#   handed to another process is forgotten, never signalled.
#
# alive/kill/starttime/descendants are injectable so the rules are testable
# without forking. The options arrive as a plain hash: as one hashref the
# even-sized list warning (printed on this line) made every call a no-op.
sub subprocessor_reap {
	my $tracked = shift;
	my %opt = (ref $_[0] eq 'HASH') ? %{ $_[0] } : @_;
	my $report = { reaped => 0, expired => 0, killed => 0, extended => 0, capped => 0 };
	return $report unless ref $tracked eq 'HASH';
	my $now = defined $opt{'now'} ? $opt{'now'} : time() * 1000;
	my $grace = defined $opt{'grace_ms'} ? $opt{'grace_ms'} : 5000;
	my $forever = defined $opt{'forever'} ? $opt{'forever'} : 32503680000000;
	my $step = defined $opt{'descendant_step'} ? $opt{'descendant_step'} : 30_000;
	my $max_descendant = defined $opt{'max_descendant_ms'} ? $opt{'max_descendant_ms'} : 900_000;

	my $alive = $opt{'alive'} || sub {
		my ($pid) = @_;
		return 0 unless defined $pid && $pid =~ /^\d+$/;
		return kill(0, $pid) ? 1 : 0;
	};
	my $starttime = $opt{'starttime'} || sub {
		my ($pid) = @_;
		return '' unless defined $pid && $pid =~ /^\d+$/;
		open(my $fh, '<', "/proc/$pid/stat") or return '';
		my $line = <$fh>;
		close $fh;
		return '' unless defined $line;
		my $close = rindex($line, ')');
		return '' if $close < 0;
		my @field = split ' ', substr($line, $close + 2);
		return defined $field[19] ? $field[19] : '';
	};
	# The group's other members: state is field 3, ppid 4, pgrp 5, so after the
	# "(comm)" cut, pgrp is index 2. A zombie is already gone for our purpose.
	my $descendants = $opt{'descendants'} || sub {
		my ($pid, $pgid) = @_;
		my @found;
		return \@found unless defined $pgid && $pgid =~ /^\d+$/ && $pgid > 1;
		opendir(my $dh, '/proc') or return \@found;
		foreach my $entry (readdir $dh) {
			next unless $entry =~ /^\d+$/;
			next if $entry == $pid;
			open(my $fh, '<', "/proc/$entry/stat") or next;
			my $line = <$fh>;
			close $fh;
			next unless defined $line;
			my $close = rindex($line, ')');
			next if $close < 0;
			my @field = split ' ', substr($line, $close + 2);
			next if defined $field[0] && $field[0] eq 'Z';
			push @found, $entry if defined $field[2] && $field[2] == $pgid;
		}
		closedir $dh;
		return \@found;
	};
	my $kill = $opt{'kill'} || sub {
		my ($signal, $target) = @_;
		return kill($signal, $target);
	};
	my $on_expire = $opt{'on_expire'} || sub { };

	# The signal target: the wrapper's own group when it is the leader, else the
	# pid alone. Never our own group.
	my $target_for = sub {
		my ($record) = @_;
		my $pgid = $record->{'pgid'};
		return -$pgid
			if defined $pgid && $pgid =~ /^\d+$/ && $pgid > 1
			&& $pgid == $record->{'pid'} && $pgid != getpgrp();
		return $record->{'pid'};
	};

	# 1. Keep the live, still-ours records; forget a dead pid or a reused number.
	my %live;
	foreach my $parent (grep { /^\d+$/ } keys %{$tracked}) {
		my $kids = $tracked->{$parent} && $tracked->{$parent}->{'subprocesses'};
		next unless ref $kids eq 'HASH';
		foreach my $pid (keys %{$kids}) {
			my $record = $kids->{$pid};
			next unless ref $record eq 'HASH';
			my $recorded_start = $record->{'start_ticks'};
			if (defined $recorded_start && length $recorded_start) {
				my $current_start = $starttime->($pid);
				if (length $current_start && $current_start ne $recorded_start) {
					delete $kids->{$pid};
					$report->{'reaped'}++;
					next;
				}
			}
			# A job asked for through run_p starts its warranty here, when its
			# process first appears, not when the request asked for it. Once, on the
			# pass that sees it: re-stamping every pass would move the deadline it is
			# being judged by. A child that never forks keeps its last moment and is
			# expired then, so a fork that never lands is still reaped.
			if ($record->{'deferred_warranty_spec'} && !$record->{'warranty_started_at'}) {
				$record->{'warranty'} = &subprocessor_warranty_at($record->{'deferred_warranty_spec'}, $now);
				$record->{'warranty_started_at'} = $now;
				# This pass is the job's start, so it also has to be the one that may
				# judge it - a spec of no length would otherwise get one pass of grace
				# it never asked for.
				delete $record->{'extended_at'};
			}
			unless ($alive->($pid)) {
				delete $kids->{$pid};
				$report->{'reaped'}++;
				next;
			}
			$live{$pid} = $record;
		}
	}

	# 2. A live descendant extends its ancestor for the descendant's run. Only
	#    scan near a deadline, so a healthy pass stays a hash walk.
	foreach my $pid (keys %live) {
		my $record = $live{$pid};
		my $pgid = $record->{'pgid'};
		next unless defined $pgid && $pgid =~ /^\d+$/ && $pgid == $pid;
		my $warranty = $record->{'warranty'};
		my $lease = $record->{'heartbeat_lease'};
		my $near = 0;
		if (defined $warranty && $warranty =~ /^\d+$/ && $warranty < $forever && $now >= $warranty - $step) {
			$near = 1;
		}
		if (defined $lease && $lease =~ /^\d+$/ && $lease > 0) {
			my $last = $record->{'heartbeat_at'} || $record->{'start_timestamp'} || 0;
			$near = 1 if $now - $last >= $lease - $step;
		}
		next unless $near;
		my $found = $descendants->($pid, $pgid);
		next unless ref $found eq 'ARRAY' && @{$found};
		my $deadline = $now + $step;
		my $untracked = 0;
		foreach my $kid (@{$found}) {
			my $child = $live{$kid};
			my $child_warranty = $child ? $child->{'warranty'} : undef;
			if (defined $child_warranty && $child_warranty =~ /^\d+$/ && $child_warranty < $forever) {
				$deadline = $child_warranty + $step if $child_warranty + $step > $deadline;
			}
			else {
				$untracked = 1;
			}
		}
		# A tracked child has its own deadline, so it may extend the ancestor for
		# as long as it is allowed to run. An untracked grandchild has none, so
		# cap the extension: past the cap the ancestor expires and the group kill
		# takes the hung descendant with it instead of extending forever.
		if ($untracked) {
			$record->{'descendant_since'} = $now unless defined $record->{'descendant_since'};
			my $cap = $record->{'descendant_since'} + $max_descendant;
			if ($deadline > $cap) {
				$deadline = $cap;
				$report->{'capped'}++;
			}
		}
		next if $deadline <= $now;
		if (defined $warranty && $warranty =~ /^\d+$/ && $warranty < $forever && $deadline > $warranty) {
			$record->{'warranty'} = $deadline;
		}
		$record->{'heartbeat_at'} = $now if defined $lease && $lease =~ /^\d+$/ && $lease > 0;
		$record->{'extended_at'} = $now;
		$record->{'extended_for'} = [ @{$found} ];
		$report->{'extended'}++;
	}

	# 3. A tracked child extends its parent chain: the parents and the parents'
	#    parents keep their deadline for as long as the child is running. Only a
	#    pid that is itself a tracked record can be walked; a request worker is
	#    not reaped by this pass, so the chain correctly stops there. Largest
	#    deadline first, so a grandchild reaches the grandparent in one pass.
	foreach my $pid (sort {
		my $a_warranty = $live{$a}{'warranty'}; $a_warranty = 0 unless defined $a_warranty && $a_warranty =~ /^\d+$/;
		my $b_warranty = $live{$b}{'warranty'}; $b_warranty = 0 unless defined $b_warranty && $b_warranty =~ /^\d+$/;
		$b_warranty <=> $a_warranty || $b <=> $a
	} keys %live) {
		my $record = $live{$pid};
		my $warranty = $record->{'warranty'};
		my $deadline = (defined $warranty && $warranty =~ /^\d+$/ && $warranty < $forever) ? $warranty : 0;
		my $lease = $record->{'heartbeat_lease'};
		next unless $deadline > 0 || (defined $lease && $lease =~ /^\d+$/ && $lease > 0);
		my $cursor = $record->{'parent'};
		my %seen;
		while ($cursor && $cursor =~ /^\d+$/ && $cursor != $pid && $live{$cursor} && !$seen{$cursor}++) {
			my $ancestor = $live{$cursor};
			my $ancestor_warranty = $ancestor->{'warranty'};
			if ($deadline > 0 && defined $ancestor_warranty && $ancestor_warranty =~ /^\d+$/ && $ancestor_warranty < $forever
				&& $deadline + $step > $ancestor_warranty) {
				$ancestor->{'warranty'} = $deadline + $step;
				$report->{'extended'}++;
			}
			$ancestor->{'heartbeat_at'} = $now
				if defined $ancestor->{'heartbeat_lease'} && $ancestor->{'heartbeat_lease'} =~ /^\d+$/ && $ancestor->{'heartbeat_lease'} > 0;
			$ancestor->{'extended_at'} = $now;
			$cursor = $ancestor->{'parent'};
		}
	}

	# 4. Expire what is still past its deadline or its lease.
	foreach my $pid (keys %live) {
		my $record = $live{$pid};
		next if defined $record->{'extended_at'} && $record->{'extended_at'} == $now;
		my $why;
		my $warranty = $record->{'warranty'};
		if (defined $warranty && $warranty =~ /^\d+$/ && $warranty < $forever && $now > $warranty) {
			$why = 'warranty';
		}
		my $lease = $record->{'heartbeat_lease'};
		if (!$why && defined $lease && $lease =~ /^\d+$/ && $lease > 0) {
			my $last = $record->{'heartbeat_at'} || $record->{'start_timestamp'} || 0;
			$why = 'heartbeat' if $now - $last > $lease;
		}
		next unless $why || defined $record->{'expired_at'};

		if (!defined $record->{'expired_at'}) {
			$record->{'expired_at'} = $now;
			$record->{'expired_reason'} = $why || 'warranty';
			$report->{'expired'}++;
			$on_expire->($record, ($why || 'warranty') . ' expired; sent TERM');
			$kill->('TERM', $target_for->($record));
			next;
		}

		next if $now - $record->{'expired_at'} < $grace;
		$report->{'killed'}++;
		$on_expire->($record, 'grace over; sent KILL');
		$kill->('KILL', $target_for->($record));
		my $parent = $record->{'parent'};
		if (defined $parent && ref $tracked->{$parent} eq 'HASH'
			&& ref $tracked->{$parent}->{'subprocesses'} eq 'HASH') {
			delete $tracked->{$parent}->{'subprocesses'}->{$pid};
		}
	}

	# A parent key with no children left is no longer part of the map.
	foreach my $parent (grep { /^\d+$/ } keys %{$tracked}) {
		my $kids = $tracked->{$parent} && $tracked->{$parent}->{'subprocesses'};
		delete $tracked->{$parent} if ref $kids eq 'HASH' && !keys %{$kids};
	}

	return $report;
}

1;
