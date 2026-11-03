package subs;

# Process: the warranty a subprocessor stamps on its record and the reaper that
# enforces it. Loaded on demand by lib/JawnOS/Domain/Loader.pm, and required
# directly by ./jawn (the master owns the process-watch socket and the records).
#
# A warranty is the house's usual unit: an absolute epoch-millisecond moment, or
# subs::forever_warranty(). A finite warranty is a deadline from the moment the
# child started. A resident loop or a server is 'forever' because its own stop
# path - or the master's death - is what ends it. A one-shot job gets the time
# its work should take, and the reaper is the backstop when it wedges.
#
# Nothing here reads the database or the filesystem except /proc, so the master
# can require it before President or the domain loader exists.
use strict;
use warnings;

# The seed map, keyed by the name a caller passes to subs::subprocessor. Values
# are a compact duration ('5s', '30m', '2h') or 'forever'. An unmapped name is
# 'forever': a new call must never be killed on its first slow run just because
# nobody listed it. Names with a dynamic suffix (a port count, a signatorial
# prefix) match the longest key that is a prefix of the name.
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
	'appt_header_printer'            => '5s',
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
	'teletype backup'                => '10m',
	'remote upgrade'                 => '30m',
	'merge database'                 => '30m',
	'remote snapshot'                => '30m',
	'qa install'                     => '30m',
);

# Resolve a warranty spec to an absolute moment. The sign is ignored because a
# warranty is always ahead of now - the house already writes '-1d' to mean a day
# ahead for a cache row or a ticket. An unreadable spec is 'forever', never a
# deadline that kills work nobody meant to bound.
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

# The warranty spec the seed map holds for a subprocessor name, or undef when
# the name is not listed. Exact first, then the longest key the name starts
# with, so 'tunnel holder wss 4 ports' finds 'tunnel holder wss'.
sub subprocessor_warranty_for {
	my ($name) = @_;
	return undef unless defined $name && length $name;
	return $WARRANTY{$name} if exists $WARRANTY{$name};
	my $best;
	foreach my $key (keys %WARRANTY) {
		next unless index($name, $key) == 0;
		$best = $key if !defined $best || length($key) > length($best);
	}
	return defined $best ? $WARRANTY{$best} : undef;
}

# One reaper pass over %subprocesses (the shape ./jawn keeps:
# { parent_pid => { subprocesses => { pid => record } } }).
#
# - A record whose pid is gone is forgotten. A child killed with SIGKILL never
#   writes its stop record, so that entry used to live for the master's lifetime.
# - A finite warranty past its moment gets one TERM, then a KILL after the grace,
#   then the record goes. A 'forever' warranty is never expired.
# - start_ticks (from /proc/<pid>/stat) is the pid-reuse guard: a pid the OS has
#   handed to another process is forgotten, never signalled.
#
# alive/kill/starttime are injectable so the rules are testable without forking.
sub subprocessor_reap {
	my ($tracked, %opt) = @_;
	my $report = { reaped => 0, expired => 0, killed => 0 };
	return $report unless ref $tracked eq 'HASH';
	my $now = defined $opt{'now'} ? $opt{'now'} : time() * 1000;
	my $grace = defined $opt{'grace_ms'} ? $opt{'grace_ms'} : 5000;
	my $forever = defined $opt{'forever'} ? $opt{'forever'} : 32503680000000;

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
	my $kill = $opt{'kill'} || sub {
		my ($signal, $pid) = @_;
		return kill($signal, $pid);
	};
	my $on_expire = $opt{'on_expire'} || sub { };

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
					# The pid now belongs to another process. Forget the record;
					# never signal a stranger that reused the number.
					delete $kids->{$pid};
					$report->{'reaped'}++;
					next;
				}
			}

			unless ($alive->($pid)) {
				delete $kids->{$pid};
				$report->{'reaped'}++;
				next;
			}

			my $warranty = $record->{'warranty'};
			next unless defined $warranty && $warranty =~ /^\d+$/ && $warranty < $forever;

			if (!defined $record->{'expired_at'}) {
				next if $now <= $warranty;
				$record->{'expired_at'} = $now;
				$record->{'expired_reason'} = 'warranty';
				$report->{'expired'}++;
				$on_expire->($record, 'warranty expired; sent TERM');
				$kill->('TERM', $pid);
				next;
			}

			next if $now - $record->{'expired_at'} < $grace;
			$report->{'killed'}++;
			$on_expire->($record, 'warranty grace over; sent KILL');
			$kill->('KILL', $pid);
			delete $kids->{$pid};
		}
		delete $tracked->{$parent} unless keys %{$kids};
	}

	return $report;
}

1;
