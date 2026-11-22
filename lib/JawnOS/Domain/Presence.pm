package subs;

# Presence simulation: while an accepted away period is active, replay a learned
# IR remote at a jittered "on" time and a jittered "off" time each local day, so
# the house looks lived in. It is opt-in and house-wide, reads the same away
# periods the budget and the notice gate read, and does nothing at all until a
# person chooses a board and a remote. The actuator is Domain::Remotes'
# remote_send(); this module only owns when to call it.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'uninitialized';
no warnings 'once';

use Digest::SHA qw(sha256_hex);
use Mojo::JSON qw(decode_json encode_json);
use POSIX ();
use Time::Local qw(timelocal);

our $presence_app = '__president';
our $presence_setting = 'presence';
our $PRESENCE_WINDOW_MS = 3 * 60 * 60 * 1000;
our $PRESENCE_KEEP_DAYS = 7;

# The stored shape. A missing or malformed row reads as these values, never as
# an error: the tick runs on a background clock and a broken row must not take
# the worker down with it.
sub presence_defaults {
	return {
		version => 1,
		enabled => 'no',
		chip_id => '',
		remote  => '',
		on      => '19:00',
		off     => '23:00',
		jitter  => 20,
		# The machine that owns the tick. Slow loops run on every non-controller,
		# and an IR remote is often a toggle, so two machines firing the same
		# evening would turn the light on and straight back off. The card records
		# the machine that saved it; an empty value (an older row, or a save from
		# a controller) falls back to the server.
		machine => '',
		last    => {},
	};
}

sub presence_settings {
	my $raw = eval { &setting_grabber({ app => $presence_app, setting => $presence_setting, device => 'all' }) };
	return &presence_normalize($raw);
}

# Accept the stored JSON, a hash a caller already decoded, or nothing. Only the
# fields this module owns are normalized; everything is copied into a fresh
# hash so a later write cannot mutate the defaults in place.
sub presence_normalize($raw = undef) {
	my $defaults = &presence_defaults();
	my $data = $raw;
	if (!ref $data) {
		$data = eval { decode_json($raw // '') };
	}
	$data = {} unless ref $data eq 'HASH';
	my $out = { %{$defaults}, %{$data} };
	$out->{'version'} = 1;
	$out->{'enabled'} = &_presence_bool($data->{'enabled'}) ? 'yes' : 'no';
	$out->{'chip_id'} = &_presence_text($data->{'chip_id'});
	$out->{'remote'} = &_presence_text($data->{'remote'});
	$out->{'on'} = &_presence_time($data->{'on'}, $defaults->{'on'});
	$out->{'off'} = &_presence_time($data->{'off'}, $defaults->{'off'});
	$out->{'jitter'} = &_presence_jitter_value($data->{'jitter'});
	$out->{'machine'} = &_presence_text($data->{'machine'});
	$out->{'last'} = &_presence_last_clean($data->{'last'});
	return $out;
}

# The card saves every field, but a caller may send only the one it changed, so
# start from what is stored. `last` is the tick's own ledger and is preserved
# unless a caller explicitly replaces it.
sub presence_save($params = undef) {
	my $current = &presence_settings();
	my %merged = %{$current};
	if (ref $params eq 'HASH') {
		foreach my $key (qw(enabled chip_id remote on off jitter machine last)) {
			$merged{$key} = $params->{$key} if exists $params->{$key};
		}
	}
	# The card is house-wide, but the replay is one machine's. A controller runs
	# no slow loops, so it leaves the gate empty for the server to own.
	if (ref $params ne 'HASH' || !exists $params->{'machine'}) {
		$merged{'machine'} = &_presence_own_machine();
	}
	my $data = &presence_normalize(\%merged);
	&_presence_write($data);
	return $data;
}

# A board a person can choose: the chips the house has seen, one option per id,
# named the way the embedded picker names them.
sub presence_boards {
	my @boards;
	my %seen;
	my $rows = eval { &db_select('devices')->hashes } || [];
	foreach my $row ( @{$rows} ) {
		next unless ref $row eq 'HASH';
		my $chips = eval { decode_json($row->{'chip_ids'} || '') } || [];
		next unless ref $chips eq 'ARRAY';
		foreach my $chip ( @{$chips} ) {
			next unless ref $chip eq 'HASH';
			my $id = $chip->{'id'} // '';
			next unless length $id;
			next if $seen{$id}++;
			push @boards, {
				id      => $id,
				name    => ($chip->{'name'} // ''),
				purpose => ($chip->{'purpose'} // ''),
			};
		}
	}
	return [ sort { (($a->{'name'} || $a->{'id'}) cmp ($b->{'name'} || $b->{'id'})) || ($a->{'id'} cmp $b->{'id'}) } @boards ];
}

# The minute offset this action gets on this date. It is derived from the date,
# the board, the remote and the action, so every tick that day computes the same
# value; the ± bound is the setting's jitter.
sub presence_jitter($date = undef, $chip_id = undef, $remote = undef, $action = undef, $jitter = undef) {
	$jitter = &_presence_jitter_value($jitter);
	return 0 unless $jitter > 0;
	my $digest = sha256_hex(join "\x1f", ($date // ''), ($chip_id // ''), ($remote // ''), ($action // ''));
	my $span = 2 * $jitter + 1;
	my $value = hex(substr($digest, 0, 8));
	return ($value % $span) - $jitter;
}

# One pass of the background job. It fires at most one on and one off per local
# session, only inside the three-hour window after a due time, and marks an
# action done only when the board accepted the send. A failed send is retried on
# the next tick while the window is still open.
sub presence_tick($now = undef) {
	$now = &rightNow() unless defined $now && $now =~ /^\s*\d+(?:\.\d+)?\s*$/;
	my $settings = &presence_settings();
	my $result = { ok => 1, fired => [] };
	return $result unless ($settings->{'enabled'} // 'no') eq 'yes';
	# One machine fires: the one that saved the card, or the server when the
	# row predates the gate or a controller saved it. A duplicate send would
	# toggle a light twice.
	my $owner = $settings->{'machine'} // '';
	if (length $owner) {
		my $me = eval { &signatorial_designer() } || '';
		return $result unless length $me && $me eq $owner;
	}
	else {
		return $result unless (&device_setter() // '') eq 'server';
	}
	return $result unless &vacation_active($now);

	my $chip_id = $settings->{'chip_id'} // '';
	my $remote = $settings->{'remote'} // '';
	return $result unless length $chip_id && length $remote;

	my $remotes = &remote_store_read('microcontroller', $chip_id);
	return $result unless ref $remotes->{$remote} eq 'HASH';

	my $on_base = &_presence_minutes($settings->{'on'});
	my $off_base = &_presence_minutes($settings->{'off'});
	my $jitter = &_presence_jitter_value($settings->{'jitter'});
	my $today = &_presence_local_date($now);
	my $last = { %{ $settings->{'last'} || {} } };
	my $changed = 0;

	# An overnight off belongs to the session that began the day before, and a
	# late tick just after midnight may still be inside yesterday's on window,
	# so the last three local dates are the only candidates.
	foreach my $offset (0, -1, -2) {
		my $date = $offset == 0 ? $today : &_presence_shift_date($today, $offset);

		my $on_minute = &_presence_clamp_minute($on_base + &presence_jitter($date, $chip_id, $remote, 'on', $jitter));
		my $on_due = &_presence_date_ms($date, $on_minute);
		if (defined $on_due && !&_presence_done($last, $date, 'on') && &_presence_window($now, $on_due)) {
			if (&_presence_fire($chip_id, $remote)) {
				$last->{$date} ||= {};
				$last->{$date}->{'on'} = 1;
				$changed = 1;
				push @{ $result->{'fired'} }, 'on';
			}
		}

		my $off_date = ($off_base < $on_base) ? &_presence_shift_date($date, 1) : $date;
		my $off_minute = &_presence_clamp_minute($off_base + &presence_jitter($off_date, $chip_id, $remote, 'off', $jitter));
		my $off_due = &_presence_date_ms($off_date, $off_minute);
		if (defined $off_due && !&_presence_done($last, $date, 'off') && &_presence_window($now, $off_due)) {
			if (&_presence_fire($chip_id, $remote)) {
				$last->{$date} ||= {};
				$last->{$date}->{'off'} = 1;
				$changed = 1;
				push @{ $result->{'fired'} }, 'off';
			}
		}
	}

	if ($changed) {
		$settings->{'last'} = &_presence_last_clean($last);
		&_presence_write($settings);
		$result->{'last'} = $settings->{'last'};
	}
	return $result;
}

# --- internals ---------------------------------------------------------------

sub _presence_write($data) {
	&setting_setter({
		app     => $presence_app,
		setting => $presence_setting,
		device  => 'all',
		value   => encode_json({
			version => 1,
			enabled => (($data->{'enabled'} // 'no') eq 'yes' ? 'yes' : 'no'),
			chip_id => ($data->{'chip_id'} // ''),
			remote  => ($data->{'remote'} // ''),
			on      => ($data->{'on'} // '19:00'),
			off     => ($data->{'off'} // '23:00'),
			jitter  => &_presence_jitter_value($data->{'jitter'}),
			machine => ($data->{'machine'} // ''),
			last    => (ref $data->{'last'} eq 'HASH' ? $data->{'last'} : {}),
		}),
	});
	return 1;
}

sub _presence_bool($value = undef) {
	return 0 unless defined $value && !ref $value;
	return $value =~ /^(?:yes|on|true|1)$/i ? 1 : 0;
}

sub _presence_text($value = undef) {
	return '' unless defined $value;
	return '' if ref $value;
	my $text = "$value";
	$text =~ s/^\s+//;
	$text =~ s/\s+$//;
	return $text;
}

sub _presence_time($value = undef, $fallback = undef) {
	return $fallback unless defined $value && !ref $value;
	if ($value =~ /^\s*(\d{1,2}):(\d{2})\s*$/) {
		my ($hour, $minute) = ($1 + 0, $2 + 0);
		return sprintf('%02d:%02d', $hour, $minute) if $hour <= 23 && $minute <= 59;
	}
	return $fallback;
}

sub _presence_minutes($hhmm = undef) {
	return 0 unless defined $hhmm && $hhmm =~ /^\s*(\d{1,2}):(\d{2})\s*$/;
	return ($1 + 0) * 60 + ($2 + 0);
}

sub _presence_jitter_value($value = undef) {
	return 20 unless defined $value && !ref $value && $value =~ /^\s*-?\d+\s*$/;
	my $jitter = int($value + 0);
	$jitter = 0 if $jitter < 0;
	$jitter = 120 if $jitter > 120;
	return $jitter;
}

sub _presence_clamp_minute($minute = undef) {
	$minute = 0 unless defined $minute;
	$minute = 0 if $minute < 0;
	$minute = 1439 if $minute > 1439;
	return int($minute);
}

# The ledger is a date -> { on => 1, off => 1 } hash. Only real dates survive,
# and only the newest seven are kept: a month of ticks cannot grow the row.
sub _presence_last_clean($raw = undef) {
	my $out = {};
	return $out unless ref $raw eq 'HASH';
	foreach my $date ( keys %{$raw} ) {
		next unless defined $date && $date =~ /^\d{4}-\d{2}-\d{2}$/;
		my $entry = $raw->{$date};
		next unless ref $entry eq 'HASH';
		my %flags;
		$flags{'on'} = 1 if $entry->{'on'};
		$flags{'off'} = 1 if $entry->{'off'};
		$out->{$date} = \%flags if %flags;
	}
	my @dates = sort { $b cmp $a } keys %{$out};
	if (@dates > $PRESENCE_KEEP_DAYS) {
		delete $out->{$_} for @dates[$PRESENCE_KEEP_DAYS .. $#dates];
	}
	return $out;
}

sub _presence_done($last = undef, $date = undef, $action = undef) {
	return 0 unless ref $last eq 'HASH';
	my $entry = $last->{$date};
	return 0 unless ref $entry eq 'HASH';
	return $entry->{$action} ? 1 : 0;
}

sub _presence_local_date($ms = undef) {
	return POSIX::strftime('%Y-%m-%d', localtime(int(($ms || 0) / 1000)));
}

# A local date shifted by whole civil days. Noon is used so a daylight-saving
# step at midnight cannot turn the shift into the same date twice.
sub _presence_shift_date($date = undef, $days = undef) {
	return $date unless defined $date && $date =~ /^(\d{4})-(\d{1,2})-(\d{1,2})$/;
	my ($year, $month, $day) = ($1 + 0, $2 + 0, $3 + 0);
	my $noon = eval { timelocal(0, 0, 12, $day, $month - 1, $year - 1900) };
	return $date unless defined $noon;
	return POSIX::strftime('%Y-%m-%d', localtime($noon + ($days || 0) * 86400));
}

# A local date and a minute of that day as epoch milliseconds.
sub _presence_date_ms($date = undef, $minute = undef) {
	return undef unless defined $date && $date =~ /^(\d{4})-(\d{1,2})-(\d{1,2})$/;
	my ($year, $month, $day) = ($1 + 0, $2 + 0, $3 + 0);
	my $clock = $minute || 0;
	my $seconds = eval {
		timelocal(0, $clock % 60, int($clock / 60), $day, $month - 1, $year - 1900)
	};
	return undef unless defined $seconds;
	return $seconds * 1000;
}

# The due time has arrived and is no older than the three-hour window. That is
# what stops a machine that was off all day from firing last night's remote.
sub _presence_window($now = undef, $due = undef) {
	return 0 unless defined $now;
	return 0 unless defined $due;
	return 0 if $now < $due;
	return ($now - $due) <= $PRESENCE_WINDOW_MS ? 1 : 0;
}

# This machine's signatorial, unless it is a controller: a controller runs no
# slow loops, so it leaves the tick to the server.
sub _presence_own_machine {
	my $device = eval { &device_setter() } || '';
	return '' if $device eq 'controller';
	return eval { &signatorial_designer() } || '';
}

sub _presence_fire($chip_id = undef, $remote = undef) {
	my $answer = eval { &remote_send({ chip_id => $chip_id, name => $remote, edt => 'microcontroller' }) };
	return 0 unless ref $answer eq 'HASH';
	return ($answer->{'ok'} && $answer->{'sent'}) ? 1 : 0;
}

1;
