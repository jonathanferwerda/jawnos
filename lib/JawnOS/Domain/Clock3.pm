package subs;

# Clock3: extracted from subroutines.pl (package subs). Loaded on
# demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Clone qw(clone);
use Data::Dumper;
use Date::Parse;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use Fcntl qw(:flock);
use File::Copy;
use File::Find;
use File::Path;
use File::Slurp;
use IPC::Open2;
use JSON::PP ();
use List::Util qw(shuffle);
use MIME::Base64;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

sub clock_tick {
	my $now = &rightNow();
	my $lock = &clock_lock_take();
	my ($next, $changed) = (undef, 0);
	my @actions;
	eval {
		my $alarms = &clock_alarms_read();
		my $timers = &clock_timers_read();
		my $rings = &clock_rings_read();
		my $alarms_changed = 0;
		my $timers_changed = 0;
		my $rings_changed = 0;

		foreach my $alarm (@{ $alarms }) {
			my $uuid = $alarm->{'uuid'} || '';
			next unless length $uuid;
			my $targeted = &clock_alarm_targets_me($alarm);
			my $ring = ref $rings->{$uuid} eq 'HASH' ? $rings->{$uuid} : undef;

			# Already sounding on this machine: repeat a chime, and stop when the
			# ring guard runs out or a dismiss/snooze reached the shared row.
			if ($ring && $ring->{'ringing'}) {
				my $elapsed = $now - ($ring->{'started'} || $now);
				my $long = &clock_sound_is_long($alarm->{'sound'});
				my $stop_at = $alarm->{'stop_at'} || 0;
				my $stopped = !$targeted || !$alarm->{'ringing'} || ($stop_at != ($ring->{'base'} || 0));
				if ($stopped || $elapsed >= &clock_alarm_ring_length($alarm)) {
					# Restore the sink even for a chime: a chime has no player to
					# kill, but the ring still raised the machine's volume.
					push @actions, [ 'stop_sound', $uuid ];
					$ring->{'ringing'} = 0;
					$ring->{'stopped'} = $now;
					$rings_changed = 1;
					$changed = 1;
					# Only the machine whose guard has run out clears the shared
					# flag, so a peer that started a moment later is not cut short.
					if ($alarm->{'ringing'} && $elapsed >= &clock_alarm_ring_length($alarm)) {
						$alarm->{'ringing'} = 0;
						$alarm->{'ring_started'} = 0;
						$alarm->{'ring_last'} = 0;
						$alarms_changed = 1;
						push @actions, [ 'device_dismiss', $uuid ];
					}
				}
				elsif (!$long && (!$ring->{'last'} || ($now - $ring->{'last'}) >= 15000)) {
					push @actions, [ 'sound', $alarm, $elapsed ];
					$ring->{'last'} = $now;
					$rings_changed = 1;
				}
				next;
			}

			next unless $targeted;
			next unless $alarm->{'enabled'} || $alarm->{'snooze_until'};
			# A snooze waiting in the future means the regular time is not due.
			next if $alarm->{'snooze_until'} && $alarm->{'snooze_until'} > $now;
			my $fire_at;
			if ($alarm->{'snooze_until'} && $alarm->{'snooze_until'} <= $now && $now - $alarm->{'snooze_until'} <= 120000) {
				$fire_at = $alarm->{'snooze_until'};
			}
			elsif ($alarm->{'enabled'}) {
				my $candidate = &clock_alarm_next_ms($alarm, $now - 120000);
				$fire_at = $candidate if $candidate && $candidate <= $now;
			}
			next unless $fire_at;
			# A skipped occurrence stays in the schedule but does not sound.
			next if $alarm->{'skip_fire'} && $fire_at <= $alarm->{'skip_fire'};
			# A fire that was dismissed (or snoozed) elsewhere before this machine
			# got there does not ring late.
			next if $alarm->{'stop_at'} && $fire_at <= $alarm->{'stop_at'};
			# The local record is the guard, not the shared last_fire: every
			# targeted machine rings the same fire once.
			next if $ring && ($ring->{'fire'} || 0) >= $fire_at;
			$rings->{$uuid} = {
				fire => $fire_at,
				started => $now,
				last => $now,
				base => ($alarm->{'stop_at'} || 0),
				ringing => 1,
			};
			$rings_changed = 1;
			$alarm->{'last_fire'} = int($fire_at / 60000);
			$alarm->{'snooze_until'} = 0;
			$alarm->{'enabled'} = 0 unless scalar @{ $alarm->{'days'} || [] };
			$alarm->{'ringing'} = 1;
			$alarm->{'ring_started'} = $now;
			$alarm->{'ring_last'} = $now;
			$alarms_changed = 1;
			$changed = 1;
			push @actions, [ 'ring', $alarm, $fire_at, $now ];
		}

		# Forget ring records a few days old so the little file cannot grow.
		foreach my $u ( keys %{$rings} ) {
			my $r = $rings->{$u};
			next unless ref $r eq 'HASH';
			my $when = $r->{'started'} || $r->{'fire'} || 0;
			next unless $when && ($now - $when) > 259200000;
			delete $rings->{$u};
			$rings_changed = 1;
		}

		foreach my $timer (@{ $timers }) {
			next unless ($timer->{'state'} || '') eq 'running';
			next unless $timer->{'ends_at'} && $timer->{'ends_at'} <= $now + 500;
			$timer->{'state'} = 'done';
			$timer->{'ended_at'} = $timer->{'ends_at'};
			$timers_changed = 1;
			$changed = 1;
			push @actions, [ 'timer', $timer, $now ];
		}

		&clock_alarms_write($alarms) if $alarms_changed;
		&clock_timers_write($timers) if $timers_changed;
		&clock_rings_write($rings) if $rings_changed;
		push @actions, [ 'device_sync', $alarms, $now ];
		$next = &clock_next_wake($alarms, $timers, $now, $rings);
	};
	warn 'clock tick: ' . $@ if $@;
	&clock_lock_drop($lock);

	# The ring, the repeated OS sound and the appointment stop all fork their
	# own players; they run after the lock is released so a two-second chime
	# cannot hold a save out of the alarm list.
	foreach my $action (@actions) {
		my $kind = $action->[0];
		if ($kind eq 'ring') {
			eval { &clock_alarm_ring($action->[1], $action->[2], $action->[3]); };
		}
		elsif ($kind eq 'sound') {
			eval { &clock_alarm_sound($action->[1], $action->[2]); };
		}
		elsif ($kind eq 'stop_sound') {
			eval { &clock_alarm_stop_sound($action->[1]); };
		}
		elsif ($kind eq 'device_dismiss') {
			eval { &clock_device_dismissed($action->[1]); };
		}
		elsif ($kind eq 'device_sync') {
			eval { &clock_write_device_alarm($action->[1], $action->[2]); };
		}
		elsif ($kind eq 'timer') {
			eval { &clock_timer_finish($action->[1], $action->[2]); };
		}
		warn 'clock action: ' . $@ if $@;
	}
	&clock_send_console('jawnosClockRefresh();') if $changed;
	return $next;
}

1;
