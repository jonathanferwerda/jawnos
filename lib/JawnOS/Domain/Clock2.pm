package subs;

# Clock2: extracted from subroutines.pl (package subs). Loaded on
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

our $device;
our %m;

sub clock_alarm_cmd {
	my ($alarm, $fire_at, $now) = @_;
	my $payload = {
		uuid => $alarm->{'uuid'},
		label => $alarm->{'label'},
		hour => $alarm->{'hour'},
		minute => $alarm->{'minute'},
		sound => $alarm->{'sound'},
		volume => $alarm->{'volume'},
		ramp => $alarm->{'ramp'},
		snooze => int($alarm->{'snooze'} || 5),
		play => ($alarm->{'play'} || ''),
		nfc => (($alarm->{'nfc'} || 0) && &clock_app_has_nfc_start($alarm->{'app'})) ? 1 : 0,
		nfc_action => ($alarm->{'nfc_action'} || 'snooze'),
		app => $alarm->{'app'},
		fired_at => $fire_at,
	};
	my $json = encode_json($payload);
	$json =~ s/\x{2028}/\\u2028/g;
	$json =~ s/\x{2029}/\\u2029/g;
	&clock_send_console('jawnosClockAlarmRing(' . $json . ');');
	return $payload;
}

sub clock_alarm_ring {
	my ($alarm, $fire_at, $now) = @_;
	$now = &rightNow() unless defined $now;
	# The ring begins here and is repeated by the firing loop until Dismiss or
	# Snooze clears it (or the five-minute guard runs out).
	$alarm->{'ringing'} = 1;
	$alarm->{'ring_started'} = $now;
	$alarm->{'ring_last'} = $now;
	&clock_alarm_cmd($alarm, $fire_at, $now);
	&clock_device_ring($alarm, $fire_at);
	# The ring is local to the machines that carry the alarm, but the answer is
	# not. Tell every peer now, so a Manager window open anywhere can draw the
	# ring card and dismiss the sound everywhere. The push above only reaches
	# this machine's tabs; a peer draws its card from the shared row.
	eval {
		my @peers = map { $_->{'value'} } @{ &subs::clock_machines() };
		&clock_relay('ring_notice', ($alarm->{'uuid'} || ''), \@peers, at => ($fire_at || $now));
	};

	my $label = $alarm->{'label'} || 'Alarm';
	my $app = $alarm->{'app'} || '';
	my $message = $app ? $label . ' - ' . &format_name($app) : $label;
	my $sound_path = &clock_valid_alarm_sound($alarm->{'sound'}) || 'notifications/ring.mp3';
	my $sound = $sound_path;
	$sound =~ s{.*/}{};
	# On a phone the app sounds the alarm on the alarm channel; the Perl player
	# would talk over it on the media stream.
	my $mobile = (&device_setter() eq 'mobile') ? 1 : 0;
	my $play = $mobile ? '' : &clock_alarm_play_command($alarm, 0);

	# The alarm turns its linked appointment on. A session already running is the
	# same activity and is left alone, so a late tick cannot open a second one.
	# The uuid is derived from the alarm and the fire, so two machines that both
	# ring the same alarm write the one start row instead of two.
	if ($app && !&open_session_uuid($app)) {
		my $start_uuid = 'clockalarm' . ($alarm->{'uuid'} || '') . int(($fire_at || $now) / 60000);
		eval {
			&Manager::appointment_writer(undef, {
				app => $app,
				type => 'start',
				uuid => $start_uuid,
				timestamp => $now,
				server_time => $now,
			});
		};
	}

	eval {
		my %note = (
			app => 'clock',
			role => 'all',
			type => 'clock',
			title => $label,
			message => $message,
			image => '/icons/alarm.svg',
			words => ' ',
		);
		if ($mobile) { $note{'silent'} = 1; }
		else { $note{'sound'} = $sound; $note{'synth'} = $play; }
		&subs::notification_sender(\%note, undef);
	};
	return 1;
}

sub clock_timer_finish {
	my ($timer, $now) = @_;
	$now = &rightNow() unless defined $now;
	my $label = $timer->{'label'} || 'Timer';
	my $app = $timer->{'app'} || '';
	# The countdown's own end is when the activity ended, even when the alarm
	# worker was asleep and reads it a little late; the server_time stays now so
	# every machine takes the row in the usual order.
	my $ended = $timer->{'ends_at'} || $now;

	if ($app && $timer->{'appt_uuid'}) {
		eval {
			&Manager::appointment_writer(undef, {
				app => $app,
				type => 'stop',
				uuid => $timer->{'appt_uuid'},
				timestamp => $ended,
				server_time => $now,
			});
		};
	}

	my $payload = {
		uuid => $timer->{'uuid'},
		label => $label,
		app => $app,
		seconds => $timer->{'seconds'},
		ended_at => $timer->{'ends_at'},
	};
	my $json = encode_json($payload);
	$json =~ s/\x{2028}/\\u2028/g;
	$json =~ s/\x{2029}/\\u2029/g;
	&clock_send_console('jawnosClockTimerDone(' . $json . ');');

	my $sound_path = &clock_valid_timer_sound($timer->{'sound'});
	my $sound = $sound_path;
	$sound =~ s{.*/}{};
	my $file = &clock_sound_file($sound_path);
	my $play = 'play -q -v 0.7 ' . &quote($file);
	# A phone sounds the timer on the alarm channel through the app.
	my $mobile = (&device_setter() eq 'mobile') ? 1 : 0;
	&clock_device_timer($timer) if $mobile;
	eval {
		my %note = (
			app => 'clock',
			role => 'all',
			type => 'clock',
			title => &lang('timer'),
			message => $label . ($app ? ' - ' . &format_name($app) : '') . ' finished',
			image => '/icons/timer.svg',
			words => ' ',
		);
		if ($mobile) { $note{'silent'} = 1; }
		else { $note{'sound'} = $sound; $note{'synth'} = $play; }
		&subs::notification_sender(\%note, undef);
	};
	return 1;
}

# One pass of the clock's own clock. Called by Alarm.pl; returns the next moment
# it should be woken for, or undef when there is nothing waiting.
# --------------------------------------------------------------------------
# Per-machine ring state
#
# The alarm list is shared, but the sound is local. Each machine remembers the
# fire it has already handled and when its own ring began, so a peer syncing
# the row mid-ring cannot make it ring twice. A dismiss or snooze is carried on
# the shared row (`stop_at`, `snooze_until`) and, for speed, relayed to the
# machines the alarm names.
sub clock_ring_file {
	my $dir = &home('~/.president');
	eval { File::Path::make_path($dir); } unless -d $dir;
	$dir = '/tmp' unless -d $dir;
	return $dir . '/clock_rings.json';
}

sub clock_rings_read {
	my $file = &clock_ring_file();
	return {} unless -e $file;
	my $raw = eval { &read_file($file) } // '';
	my $rings = eval { decode_json($raw) };
	return ref $rings eq 'HASH' ? $rings : {};
}

sub clock_rings_write {
	my $rings = shift || {};
	eval { write_file(&clock_ring_file(), encode_json($rings)) };
	return $rings;
}

# Hand a dismiss/snooze/stop_all to the machines that carry the alarm. The
# shared settings row reaches them as well; this is what makes the stop
# immediate rather than whenever the next sync runs. Quiet about a peer that is
# away - the row will still catch it up.
sub clock_relay {
	my ($action, $uuid, $machines, %extra) = @_;
	my $self = &signatorial_designer() || '';
	my @want = grep { defined $_ && length $_ && $_ ne $self } @{ $machines || [] };
	return 0 unless scalar @want;
	# Resolve each target through the peer lister, not the raw roster row: a
	# phone advertises its own 127.0.0.1 as the manager, which is unreachable
	# from the machine pressing Dismiss. The lister swaps it for the LAN address.
	my @peers;
	foreach my $sig (@want) {
		my $rm = &clock_alarm_peer_row($sig);
		push @peers, [ $sig, $rm ] if $rm && $rm->{'manager'};
	}
	return 0 unless scalar @peers;
	my %form = ( action => $action, relayed => 'yes', signatorial => ($self || ''), uuid => ($uuid || '') );
	foreach my $key ( keys %extra ) {
		next unless defined $extra{$key};
		$form{$key} = $extra{$key};
	}
	eval {
		&subprocessor(sub {
			foreach my $peer (@peers) {
				my ($sig, $rm) = @{$peer};
				eval {
					# remote_useragent_maker returns the peer row with a 'ua' and
					# the tunnel-aware 'manager' url, not a bare agent.
					my $hop = &subs::remote_useragent_maker({ rm => $rm, signatorial => $sig });
					if ($hop && $hop->{'ua'} && $hop->{'manager'}) {
						$hop->{'ua'}->insecure(1)->post($hop->{'manager'} . '/manager/clock/alarm' => form => \%form)->result;
					}
				};
			}
		}, { name => 'clock relay' });
	};
	return 1;
}

# ---- confirmed, immediate alarm sharing -------------------------------------
# The shared settings row carries an alarm to the other machines eventually, on
# the normal sync pass. These helpers push a single edit now, wait for the peer
# to answer, and record who confirmed. A peer that does not answer directly is
# offered the edit through another reachable machine, one hop only.
sub clock_alarm_ack_file {
	my $dir = &home('~/.president');
	eval { File::Path::make_path($dir); } unless -d $dir;
	$dir = '/tmp' unless -d $dir;
	return $dir . '/clock_acks.json';
}

sub clock_alarm_acks_read {
	my $file = &clock_alarm_ack_file();
	return {} unless -e $file;
	my $raw = eval { &read_file($file) } // '';
	my $acks = eval { decode_json($raw) };
	return ref $acks eq 'HASH' ? $acks : {};
}

sub clock_alarm_acks_write {
	my $acks = shift || {};
	eval { write_file(&clock_alarm_ack_file(), encode_json($acks)) };
	return $acks;
}

sub clock_alarm_mark_ack {
	my ($uuid, $sig, $now) = @_;
	return 0 unless defined $uuid && length $uuid && defined $sig && length $sig;
	$now = &rightNow() unless defined $now;
	my $acks = &clock_alarm_acks_read();
	$acks->{$uuid} = {} unless ref $acks->{$uuid} eq 'HASH';
	$acks->{$uuid}->{$sig} = int($now);
	# keep the little file from growing; a ring older than a week is history
	foreach my $u ( keys %{$acks} ) {
		next unless ref $acks->{$u} eq 'HASH';
		my $newest = 0;
		foreach my $s ( keys %{ $acks->{$u} } ) {
			$newest = $acks->{$u}->{$s} if ($acks->{$u}->{$s} || 0) > $newest;
		}
		delete $acks->{$u} if !$newest || ($now - $newest) > 604800000;
	}
	&clock_alarm_acks_write($acks);
	return 1;
}

# The roster rows a push can reach, by signatorial. A same-LAN row may carry no
# manager URL; the lister builds one when the push finds it missing.
sub clock_alarm_peers {
	my $rows = eval { &db_query('select hostname, signatorial, manager, ip, port, device, network from remote_machines')->hashes } || [];
	my %by_sig;
	foreach my $rm (@{ $rows || [] }) {
		my $sig = $rm->{'signatorial'} || '';
		next unless length $sig;
		$by_sig{$sig} = $rm;
	}
	return \%by_sig;
}

# One target's row, resolved the way the rest of the peer rail resolves a peer.
# A machine advertises the manager it answers on, which on an Android handset is
# its own 127.0.0.1: using that verbatim made every alarm push to the phone fail
# with "Connection refused" and no confirmation was ever recorded. The lister
# swaps a loopback or dead tailnet manager for the LAN address the peer
# advertised, so a phone on the house network is reached directly.
sub clock_alarm_peer_row {
	my ($sig) = @_;
	return undef unless defined $sig && length $sig;
	my $row = eval {
		&remote_machine_lister({ signatorial => $sig, limit => 1, mirrors => 'none', self => 'no' });
	};
	if (ref $row eq 'HASH' && ($row->{'signatorial'} || '') eq $sig && ($row->{'manager'} || '') =~ m{^https?://}) {
		return $row;
	}
	my $fallback = eval {
		&db_query('select hostname, signatorial, manager, ip, port, device, network from remote_machines where signatorial = ?', $sig)->hash;
	};
	return ref $fallback eq 'HASH' ? $fallback : undef;
}

# Push one alarm edit. Returns { delivered => [...], failed => [...] }. The
# ack file is written here, so the next /manager/clock/state already shows the ✓.
sub clock_alarm_push {
	my ($alarm, $op, $machines, $now, $allow_forward) = @_;
	$alarm = {} unless ref $alarm eq 'HASH';
	my $uuid = $alarm->{'uuid'} || '';
	my $result = { delivered => [], failed => [] };
	return $result unless length $uuid;
	$op = ($op || '') eq 'delete' ? 'delete' : 'upsert';
	$now = &rightNow() unless defined $now;
	# An acknowledgement belongs to one edit, so stamp it with the row's own
	# `updated` value. A ✓ from an earlier edit must not outlive the change.
	my $stamp = int($alarm->{'updated'} || $now);
	$allow_forward = 1 unless defined $allow_forward;
	my $self = &signatorial_designer() || '';
	my %want;
	foreach my $sig ( @{ $machines || [] } ) {
		next unless defined $sig && length $sig && $sig ne $self;
		$want{$sig} = 1;
	}
	return $result unless scalar keys %want;
	my $rows = &clock_alarm_peers();
	my %form = (
		action => 'remote_apply',
		relayed => 'yes',
		signatorial => ($self || ''),
		op => $op,
		uuid => $uuid,
		server_time => $now,
	);
	if ($op eq 'upsert') { $form{'alarm'} = encode_json($alarm); }
	else { $form{'updated'} = int($alarm->{'updated'} || $now); }

	my @failed;
	foreach my $sig ( sort keys %want ) {
		# Always resolve through the lister: a stored manager can be the peer's
		# own loopback (Android) or a tailnet name whose node is away.
		my $rm = &clock_alarm_peer_row($sig);
		if (!$rm || !$rm->{'manager'}) { push @failed, $sig; next; }
		my $ok = 0;
		my $err = '';
		eval {
			# The maker hands back the peer row (with 'ua' and the
			# tunnel-aware 'manager' url); using it as an agent meant every
			# immediate push died and no confirmation was ever possible.
			my $hop = &subs::remote_useragent_maker({ rm => $rm, signatorial => $sig });
			die "no agent\n" unless $hop && $hop->{'ua'} && $hop->{'manager'};
			my $ua = $hop->{'ua'}->insecure(1);
			$ua->inactivity_timeout(4)->request_timeout(4);
			my $res = $ua->post($hop->{'manager'} . '/manager/clock/alarm' => form => \%form)->result;
			die "no answer\n" unless $res && $res->is_success;
			my $body = eval { decode_json($res->body) } || {};
			$ok = 1 if $body->{'ok'};
			if ($body->{'ok'} && ref $body->{'forwarded'} eq 'ARRAY') {
				foreach my $fs ( @{ $body->{'forwarded'} } ) {
					next unless defined $fs && length $fs;
					&clock_alarm_mark_ack($uuid, $fs, $stamp);
				}
			}
		};
		$err = $@;
		if ($ok) {
			push @{ $result->{'delivered'} }, $sig;
			&clock_alarm_mark_ack($uuid, $sig, $stamp);
		}
		else {
			warn 'clock alarm push ' . $sig . ' failed: ' . ($err =~ s/\s+/ /gr) . "\n" if $err;
			push @failed, $sig unless grep { $_ eq $sig } @failed;
		}
	}

	# A machine that did not answer directly may still be reachable from another
	# peer. Ask a reachable third machine to hand the same edit on, and trust its
	# own delivered list. One hop only, so two disconnected machines cannot loop.
	if ($allow_forward && scalar @failed) {
		my %failed = map { $_ => 1 } @failed;
		# Candidates are the peers that are not targets and did not fail. Ask the
		# server first: when two machines cannot see each other (different
		# networks, a phone whose LAN address a peer cannot route), the server is
		# the one place both can reach, so it forwards the edit for us.
		my @relays = grep { !$failed{$_} && !$want{$_} && $_ ne $self } keys %{ $rows };
		@relays = sort {
			my $ad = (($rows->{$a} || {})->{'device'} || '') eq 'server' ? 0 : 1;
			my $bd = (($rows->{$b} || {})->{'device'} || '') eq 'server' ? 0 : 1;
			$ad <=> $bd || $a cmp $b;
		} @relays;
		my $tries = 0;
		my @still = @failed;
		foreach my $relay_sig (@relays) {
			last if !scalar @still || $tries >= 3;
			$tries++;
			my $rm = &clock_alarm_peer_row($relay_sig);
			next unless $rm && $rm->{'manager'};
			eval {
				my $hop = &subs::remote_useragent_maker({ rm => $rm, signatorial => $relay_sig });
				die "no agent\n" unless $hop && $hop->{'ua'} && $hop->{'manager'};
				my $ua = $hop->{'ua'}->insecure(1);
				$ua->inactivity_timeout(5)->request_timeout(5);
				my %fwd = %form;
				$fwd{'forward_to'} = join(',', @still);
				my $res = $ua->post($hop->{'manager'} . '/manager/clock/alarm' => form => \%fwd)->result;
				die "no answer\n" unless $res && $res->is_success;
				my $body = eval { decode_json($res->body) } || {};
				die "not ok\n" unless $body->{'ok'} && ref $body->{'forwarded'} eq 'ARRAY';
				my %done = map { $_ => 1 } @{ $body->{'forwarded'} };
				foreach my $fs ( keys %done ) {
					&clock_alarm_mark_ack($uuid, $fs, $stamp);
					push @{ $result->{'delivered'} }, $fs;
				}
				@still = grep { !$done{$_} } @still;
			};
		}
		@failed = @still;
	}
	$result->{'failed'} = [ @failed ];
	return $result;
}

# Apply an edit that arrived from a peer. A per-alarm `updated` stamp decides
# between two copies; the shared row still converges later either way.
sub clock_apply_remote_alarm {
	my ($alarm, $op, $now) = @_;
	return 0 unless ref $alarm eq 'HASH' && length($alarm->{'uuid'} || '');
	my $uuid = $alarm->{'uuid'};
	$op = ($op || '') eq 'delete' ? 'delete' : 'upsert';
	$now = &rightNow() unless defined $now;
	my $incoming = int($alarm->{'updated'} || $now);
	my $lock = &clock_lock_take();
	my $alarms = &clock_alarms_read();
	my ($idx) = grep { ($alarms->[$_] || {})->{'uuid'} eq $uuid } 0 .. $#$alarms;
	my $changed = 0;
	my $kept;
	if ($op eq 'delete') {
		if (defined $idx && int($alarms->[$idx]->{'updated'} || 0) <= $incoming) {
			splice(@{$alarms}, $idx, 1);
			$changed = 1;
		}
	}
	else {
		my $next = &clock_normalize_alarm($alarm);
		$next->{'updated'} = $incoming;
		if (defined $idx) {
			if (int($alarms->[$idx]->{'updated'} || 0) <= $incoming) {
				$alarms->[$idx] = $next;
				$changed = 1;
			}
			$kept = $alarms->[$idx];
		}
		else {
			push @{$alarms}, $next;
			$kept = $next;
			$changed = 1;
		}
	}
	if ($changed) {
		&clock_alarms_write($alarms);
		# a stop that arrived on the peer rail must end this machine's sound now
		if ($op eq 'delete' || !$kept || !$kept->{'ringing'}) {
			my $rings = &clock_rings_read();
			if (ref $rings->{$uuid} eq 'HASH' && $rings->{$uuid}->{'ringing'}) {
				$rings->{$uuid}->{'ringing'} = 0;
				$rings->{$uuid}->{'stopped'} = $now;
				&clock_rings_write($rings);
			}
		}
	}
	&clock_lock_drop($lock);
	if ($changed) {
		&clock_alarm_stop_sound($uuid) if ($op eq 'delete' || !$kept || !$kept->{'ringing'});
		&clock_device_dismissed($uuid) if ($op eq 'delete' || !$kept || !$kept->{'ringing'});
		&clock_write_device_alarm($alarms, $now);
		&clock_poke($now);
		&clock_send_console('jawnosClockRefresh();');
	}
	return $changed;
}

# The phone's notification buttons and the lock-screen gestures cannot call the
# manager, so they leave a small request here; the alarm worker applies it within
# a couple of seconds. The file holds one request and is removed as it is read.
sub clock_control_file {
	my $dir = &home('~/.president');
	eval { File::Path::make_path($dir); } unless -d $dir;
	$dir = '/tmp' unless -d $dir;
	return $dir . '/clock_control.json';
}

sub clock_control_apply {
	my $file = &clock_control_file();
	return 0 unless -e $file;
	my $raw = eval { read_file($file) } // '';
	unlink $file;
	my $data = eval { decode_json($raw) };
	return 0 unless ref $data eq 'HASH';
	my $action = lc($data->{'action'} || '');
	return 0 unless $action =~ /^(?:dismiss|snooze|stop_all)$/;
	my $uuid = $data->{'uuid'} || '';
	my $now = &rightNow();
	my $lock = &clock_lock_take();
	my $alarms = &clock_alarms_read();
	my $relay_machines = [];
	my $changed = 0;
	if ($action eq 'stop_all') {
		foreach my $a ( @{$alarms} ) {
			$a->{'snooze_until'} = 0;
			$a->{'ringing'} = 0;
			$a->{'ring_started'} = 0;
			$a->{'ring_last'} = 0;
			$a->{'stop_at'} = $now;
			$a->{'updated'} = $now;
			$changed = 1;
		}
		$relay_machines = [ map { $_->{'value'} } @{ &clock_machines() } ];
	}
	elsif (length $uuid) {
		my ($alarm) = grep { ($_->{'uuid'} || '') eq $uuid } @{$alarms};
		if ($alarm) {
			# An alarm can hand its snooze/dismiss to the NFC tag assigned to the
			# linked app. The phone writes the tag's uuid with the request; a tag
			# that is not assigned, or is assigned to another control, leaves the
			# alarm ringing. The ring payload only asks for NFC when a start tag
			# exists, so a deleted tag cannot strand the alarm.
			my $nfc_required = ($alarm->{'nfc'} || 0) && &clock_app_has_nfc_start($alarm->{'app'});
			if ($nfc_required) {
				my $tag_uuid = $data->{'nfc_uuid'} || '';
				my ($tag) = grep {
					($_->{'uuid'} || '') eq $tag_uuid && &clock_nfc_control_starts($_->{'control'})
				} @{ &clock_app_nfc_tags($alarm->{'app'}) };
				unless ($tag) {
					&clock_lock_drop($lock);
					&clock_device_broadcast(&app_action('JAWN_CLOCK_REJECT'), uuid => $uuid);
					return 0;
				}
			}
			$relay_machines = $alarm->{'machines'} || [];
			$alarm->{'snooze_until'} = 0;
			$alarm->{'ringing'} = 0;
			$alarm->{'ring_started'} = 0;
			$alarm->{'ring_last'} = 0;
			$alarm->{'stop_at'} = $now;
			if ($action eq 'snooze') {
				my $minutes = $data->{'minutes'};
				$minutes = $alarm->{'snooze'} unless defined $minutes && "$minutes" =~ /^\d+$/;
				$minutes = 5 unless defined $minutes && "$minutes" =~ /^\d+$/;
				$minutes = 1 if $minutes < 1;
				$minutes = 60 if $minutes > 60;
				$alarm->{'snooze_until'} = $now + ($minutes * 60000);
				$data->{'minutes'} = $minutes;
			}
			$alarm->{'updated'} = $now;
			$changed = 1;
		}
	}
	&clock_alarms_write($alarms) if $changed;
	&clock_lock_drop($lock);
	return 0 unless $changed;
	if ($action eq 'stop_all') { foreach my $a (@{$alarms}) { &clock_alarm_stop_sound($a->{'uuid'}); } }
	else { &clock_alarm_stop_sound($uuid); }
	&clock_write_device_alarm($alarms, $now);
	&clock_send_console('jawnosClockAlarmStop();');
	&clock_device_dismissed($action eq 'stop_all' ? '' : $uuid);
	&clock_relay($action eq 'snooze' ? 'snooze' : 'dismiss', ($action eq 'stop_all' ? '' : $uuid), $relay_machines,
		($action eq 'snooze' ? (minutes => $data->{'minutes'} || 5) : ()));
	my @push = grep { $action eq 'stop_all' || ($_->{'uuid'} || '') eq $uuid } @{$alarms};
	if (scalar @push) {
		&subprocessor(sub {
			foreach my $a (@push) { eval { &clock_alarm_push($a, 'upsert', $relay_machines, $now); }; }
		}, { name => 'clock control push' });
	}
	&clock_poke($now);
	return 1;
}

# A future appointment in an app whose notification panel has Alarm on becomes
# one Clock alarm, linked back to that appointment. Re-saving the appointment
# moves the same Clock row; the next future one replaces it, so an app never
# collects a pile of stale alarms.
sub clock_appointment_sync {
	my ($appt) = @_;
	my $row = ref $appt eq 'HASH' ? $appt : {};
	my $app = $row->{'app'} || (defined $appt && !ref $appt ? "$appt" : '');
	$app =~ s/^\s+|\s+$//g if defined $app;
	return 0 unless defined $app && length $app;
	my $want = eval { &setting_grabber({ app => $app, setting => 'alarm' }) };
	$want = (defined $want && $want =~ /^(?:on|yes|1|checked)$/i) ? 1 : 0;
	my $now = &rightNow();
	my $lock = &clock_lock_take();
	my $alarms = &clock_alarms_read();
	my ($auto) = grep { ($_->{'source'} || '') eq 'appointment' && ($_->{'app'} || '') eq $app } @{$alarms};
	my $next;
	if ($want) {
		$next = eval { &db_query('select uuid, timestamp from appointments where app = ? and timestamp > ? order by timestamp asc limit 1', $app, $now)->hash };
	}
	if (!$want || !$next || !($next->{'timestamp'} || 0)) {
		if ($auto && ($auto->{'enabled'} || $auto->{'appt_uuid'})) {
			$auto->{'enabled'} = 0;
			$auto->{'appt_uuid'} = '';
			$auto->{'ringing'} = 0;
			$auto->{'ring_started'} = 0;
			$auto->{'ring_last'} = 0;
			$auto->{'updated'} = $now;
			&clock_alarms_write($alarms);
			&clock_lock_drop($lock);
			&clock_write_device_alarm($alarms, $now);
			my $disabled = $auto;
			&subprocessor(sub { eval { &clock_alarm_push($disabled, 'upsert', $disabled->{'machines'}, $now); }; }, { name => 'clock appointment push' });
			&clock_poke($now);
			return 1;
		}
		&clock_lock_drop($lock);
		return 0;
	}
	my @lt = localtime(int($next->{'timestamp'} / 1000));
	my ($hour, $minute) = ($lt[2], $lt[3]);
	my $label = &format_name($app) || $app;
	$label = substr($label, 0, 20);
	$label = 'Alarm' unless length $label;
	if ($auto) {
		# nothing moved: leave the row (and its confirmation stamps) alone
		if (int($auto->{'hour'}) == $hour && int($auto->{'minute'}) == $minute
			&& ($auto->{'appt_uuid'} || '') eq ($next->{'uuid'} || '') && $auto->{'enabled'}) {
			&clock_lock_drop($lock);
			return 0;
		}
	}
	else {
		if (scalar @{$alarms} >= 10) { &clock_lock_drop($lock); return 0; }
		$auto = &clock_normalize_alarm({
			uuid => &random_string_creator(24),
			snooze => 5,
			volume => 70,
			ramp => 60,
			sound => 'notifications/ring.mp3',
			machines => [ &signatorial_designer() || '' ],
			created => $now,
		});
		push @{$alarms}, $auto;
	}
	$auto->{'hour'} = $hour;
	$auto->{'minute'} = $minute;
	$auto->{'days'} = [];
	$auto->{'enabled'} = 1;
	$auto->{'label'} = $label;
	$auto->{'app'} = $app;
	$auto->{'appt_uuid'} = $next->{'uuid'} || '';
	$auto->{'source'} = 'appointment';
	$auto->{'snooze_until'} = 0;
	$auto->{'ringing'} = 0;
	$auto->{'ring_started'} = 0;
	$auto->{'ring_last'} = 0;
	$auto->{'updated'} = $now;
	$auto->{'machines'} = [ &signatorial_designer() || '' ] unless scalar @{ $auto->{'machines'} || [] };
	&clock_alarms_write($alarms);
	&clock_lock_drop($lock);
	&clock_write_device_alarm($alarms, $now);
	&subprocessor(sub { eval { &clock_alarm_push($auto, 'upsert', $auto->{'machines'}, $now); }; }, { name => 'clock appointment push' });
	&clock_poke($now);
	return 1;
}

1;
