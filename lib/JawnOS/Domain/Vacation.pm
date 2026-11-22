package subs;

# Away periods: a house-wide span in which the person was not living their
# normal routine. Vacation is the first kind, but a hospital stay, a work trip
# or a dead machine is the same fact to the budget and the routine.
#
# The period is a lens on time, not a switch that turns the house off. Real
# appointments and measurements still record; consumers ask this module whether
# a window was away, how much of it was, and whether a budget should prorate,
# freeze, pause or ignore the span. The setting is house-wide (device "all"),
# the same shape the holidays and clothesline settings use, so every machine
# reads one answer.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Mojo::JSON qw(decode_json encode_json);
use POSIX ();
use Time::Local qw(timelocal);

our $vacation_setting = 'vacation';
our $vacation_app = '__president';
our %vacation_memo;
our $VACATION_MEMO_MS = 5000;

# The house's defaults. A floor rate budget shrinks by the away share; a
# ceiling or a fixed level keeps its target. Security, calls and access are the
# notices that still speak while the person is away.
sub vacation_defaults {
	return {
		version => 1,
		periods => [],
		policy => {
			budgets => 'prorate',
			notifications => 'hold',
			routines => 'skip',
			keep_apps => {
				budgets => [],
				routines => [],
				notifications => [ 'security', 'customs', 'phone', 'access', 'gate', 'box_office' ],
			},
		},
		auto => { detect => 0, after_hours => 24 },
	};
}

sub vacation_forget {
	%vacation_memo = ();
	return 1;
}

# The setting as one normalized hash. A missing or malformed row reads as the
# defaults, never as an error: every budget asks this, and a broken row must not
# take the budget light down with it.
sub vacation_settings {
	my $now = &rightNow();
	if ($vacation_memo{'data'} && defined $vacation_memo{'at'}
		&& $now - $vacation_memo{'at'} < $VACATION_MEMO_MS) {
		return $vacation_memo{'data'};
	}
	my $raw = eval { &setting_grabber({ app => $vacation_app, setting => $vacation_setting, device => 'all' }) };
	my $data = &vacation_normalize($raw);
	$vacation_memo{'data'} = $data;
	$vacation_memo{'at'} = $now;
	return $data;
}

# Accept the stored JSON, a hash a caller already decoded, or nothing. Only the
# fields this module owns are copied; an unknown field is left for a newer
# version rather than dropped on the next write (the raw write keeps it).
sub vacation_normalize($raw) {
	my $defaults = &vacation_defaults();
	my $data = $raw;
	if (!ref $data) {
		$data = eval { decode_json($raw // '') };
	}
	$data = {} unless ref $data eq 'HASH';
	my $out = { %{$defaults}, %{$data} };
	$out->{'periods'} = [] unless ref $out->{'periods'} eq 'ARRAY';
	my @periods;
	my %seen;
	foreach my $p ( @{ $out->{'periods'} } ) {
		next unless ref $p eq 'HASH';
		my $from = _vacation_number($p->{'from'});
		next unless defined $from && $from > 0;
		my $to = _vacation_number($p->{'to'});
		$to = undef if defined $to && $to <= $from;
		my $uuid = defined $p->{'uuid'} && length $p->{'uuid'} ? $p->{'uuid'} : "$from|" . ($to // 'open');
		next if $seen{$uuid}++;
		my $state = $p->{'state'} // 'active';
		$state = 'active' unless $state =~ /^(?:planned|active|ended|proposed|dismissed)$/;
		push @periods, {
			%{$p},
			uuid => $uuid,
			from => $from,
			($to ? (to => $to) : ()),
			state => $state,
			kind => (defined $p->{'kind'} && length $p->{'kind'} ? $p->{'kind'} : 'vacation'),
			note => (defined $p->{'note'} ? "$p->{'note'}" : ''),
			place => (defined $p->{'place'} ? "$p->{'place'}" : ''),
		};
	}
	@periods = sort { $a->{'from'} <=> $b->{'from'} } @periods;
	$out->{'periods'} = \@periods;
	$out->{'policy'} = { %{ $defaults->{'policy'} }, (ref $out->{'policy'} eq 'HASH' ? %{ $out->{'policy'} } : ()) };
	my $keep = ref $out->{'policy'}->{'keep_apps'} eq 'HASH' ? $out->{'policy'}->{'keep_apps'} : {};
	$out->{'policy'}->{'keep_apps'} = {
		budgets => (ref $keep->{'budgets'} eq 'ARRAY' ? [ grep { defined $_ && length $_ } @{ $keep->{'budgets'} } ] : []),
		routines => (ref $keep->{'routines'} eq 'ARRAY' ? [ grep { defined $_ && length $_ } @{ $keep->{'routines'} } ] : []),
		notifications => (ref $keep->{'notifications'} eq 'ARRAY'
			? [ grep { defined $_ && length $_ } @{ $keep->{'notifications'} } ]
			: [ @{ $defaults->{'policy'}->{'keep_apps'}->{'notifications'} } ]),
	};
	$out->{'auto'} = { %{ $defaults->{'auto'} }, (ref $out->{'auto'} eq 'HASH' ? %{ $out->{'auto'} } : ()) };
	return $out;
}

sub _vacation_number {
	my ($v) = @_;
	return undef unless defined $v && $v =~ /^\s*\d+(?:\.\d+)?\s*$/;
	return 0 + $v;
}

# Proposed periods are a question, not an away span: they must not pause a
# budget before the person answers. A dismissed proposal is kept in the list so
# the same quiet gap is not proposed again.
sub vacation_accepted($p) {
	return 0 unless ref $p eq 'HASH';
	return 0 if ($p->{'state'} // '') eq 'proposed' || ($p->{'state'} // '') eq 'dismissed';
	return 1;
}

sub vacation_periods {
	my $data = &vacation_settings();
	return [ @{ $data->{'periods'} || [] } ];
}

sub vacation_period($uuid) {
	return undef unless defined $uuid && length $uuid;
	my ($p) = grep { ($_->{'uuid'} // '') eq $uuid } @{ &vacation_periods() };
	return $p;
}

# The accepted span covering this moment, latest start wins when two overlap.
sub vacation_now($ts) {
	$ts = &rightNow() unless defined $ts && $ts =~ /^\s*\d+(?:\.\d+)?\s*$/;
	my $best;
	foreach my $p ( @{ &vacation_periods() } ) {
		next unless &vacation_accepted($p);
		next if $p->{'from'} > $ts;
		next if defined $p->{'to'} && $p->{'to'} <= $ts;
		$best = $p if !defined $best || $p->{'from'} >= $best->{'from'};
	}
	return $best;
}

sub vacation_active($ts) {
	return &vacation_now($ts) ? 1 : 0;
}

# The away time inside a window, merged so two overlapping periods are counted
# once. The caller does the clipping; a window with no away time is 0.
sub vacation_overlap($from, $to) {
	return 0 unless defined $from && defined $to && $from =~ /^\s*\d+(?:\.\d+)?\s*$/ && $to =~ /^\s*\d+(?:\.\d+)?\s*$/;
	return 0 unless $to > $from;
	my @spans;
	foreach my $p ( @{ &vacation_periods() } ) {
		next unless &vacation_accepted($p);
		my $lo = $p->{'from'} > $from ? $p->{'from'} : $from;
		my $hi = defined $p->{'to'} && $p->{'to'} < $to ? $p->{'to'} : $to;
		push @spans, [ $lo, $hi ] if $hi > $lo;
	}
	return 0 unless @spans;
	@spans = sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @spans;
	my $sum = 0;
	my ($lo, $hi) = @{ $spans[0] };
	foreach my $span ( @spans[1 .. $#spans] ) {
		if ($span->[0] <= $hi) {
			$hi = $span->[1] if $span->[1] > $hi;
			next;
		}
		$sum += $hi - $lo;
		($lo, $hi) = @{$span};
	}
	$sum += $hi - $lo;
	return $sum;
}

sub vacation_active_ms($from, $to) {
	return 0 unless defined $from && defined $to && $to > $from;
	my $away = &vacation_overlap($from, $to);
	my $active = ($to - $from) - $away;
	return $active > 0 ? $active : 0;
}

sub vacation_day_key($ms) {
	return POSIX::strftime('%Y-%m-%d', localtime(int(($ms || 0) / 1000)));
}

# A local day's bounds. timelocal normalizes the day arithmetic, so a day that
# gains or loses an hour is still one day and the next midnight is exact.
sub vacation_day_bounds($key) {
	return undef unless defined $key && $key =~ /^(\d{4})-(\d{1,2})-(\d{1,2})$/;
	my ($y, $m, $d) = ($1 + 0, $2 + 0, $3 + 0);
	return undef unless $m >= 1 && $m <= 12 && $d >= 1 && $d <= 31;
	my $start = eval { timelocal(0, 0, 0, $d, $m - 1, $y - 1900) * 1000 };
	my $next = eval { timelocal(0, 0, 0, $d + 1, $m - 1, $y - 1900) * 1000 };
	return undef unless defined $start && defined $next && $next > $start;
	return ($start, $next);
}

# Each local day the window touches, with the away milliseconds inside it.
sub vacation_day_mask($from, $to) {
	my %mask;
	return \%mask unless defined $from && defined $to && $to > $from;
	my $cursor = $from;
	my $guard = 0;
	while ($cursor < $to && $guard++ < 2000) {
		my $key = &vacation_day_key($cursor);
		my ($ds, $de) = &vacation_day_bounds($key);
		last unless defined $de && $de > $cursor;
		my $lo = $from > $ds ? $from : $ds;
		my $hi = $to < $de ? $to : $de;
		my $away = &vacation_overlap($lo, $hi);
		$mask{$key} = $away if $away > 0;
		$cursor = $de;
	}
	return \%mask;
}

# A day is away when at least half of it was. A departure at five in the
# evening is a partial day for a budget's milliseconds, but it is not a day the
# routine should learn as missing.
sub vacation_day_away($key) {
	my ($ds, $de) = &vacation_day_bounds($key);
	return 0 unless defined $ds && defined $de && $de > $ds;
	my $away = &vacation_overlap($ds, $de);
	return $away >= (($de - $ds) / 2) ? 1 : 0;
}

sub vacation_away_days($from, $to) {
	my $mask = &vacation_day_mask($from, $to);
	return scalar grep { &vacation_day_away($_) } keys %{$mask};
}

# Which way a budget treats an away window. A floor rate is prorated; a ceiling
# or a fixed level keeps its target, because spending less is not a failure and
# a weight is not a rate. "pause" and "count" are the person's own choices.
sub vacation_policy_for($app, $circumstance, $direction, $fixed) {
	my $data = &vacation_settings();
	my $policy = $data->{'policy'} || {};
	my $global = $policy->{'budgets'} || 'prorate';
	return 'count' if $global eq 'count';
	my $keep = $policy->{'keep_apps'}->{'budgets'} || [];
	return 'count' if defined $app && length $app && grep { $_ eq $app } @{$keep};
	return 'pause' if $global eq 'pause';
	return 'freeze' if $fixed || (($direction || 'floor') eq 'ceiling');
	return 'prorate';
}

# Security, calls and access still speak while the person is away. Everything
# else is stored but held: no sound, no phone push, no live desk card.
sub vacation_notify_allowed($app, $type, $urgent, $at) {
	$at = &rightNow() unless defined $at;
	return 1 unless &vacation_active($at);
	return 1 if $urgent;
	my $data = &vacation_settings();
	return 1 unless (($data->{'policy'}->{'notifications'} || 'hold') eq 'hold');
	my $keep = $data->{'policy'}->{'keep_apps'}->{'notifications'} || [];
	foreach my $name ( @{$keep} ) {
		return 1 if defined $app && $name eq $app;
		return 1 if defined $type && $name eq $type;
	}
	return 0;
}

# A repeat made by a schedule is a routine step, not a one-off the person set
# for this day. The Alarm asks this before it runs a command or announces it.
sub vacation_routine_skip($app, $at) {
	$at = &rightNow() unless defined $at;
	return 0 unless &vacation_active($at);
	my $data = &vacation_settings();
	return 0 unless (($data->{'policy'}->{'routines'} || 'skip') eq 'skip');
	my $keep = $data->{'policy'}->{'keep_apps'}->{'routines'} || [];
	return 0 if defined $app && length $app && grep { $_ eq $app } @{$keep};
	return 1;
}

# Close the open sessions that began before the boundary at their boundary. A
# session's length is the negative accrual every other close path writes. This
# is a repair, not a person's stop: it only runs when an away period is made or
# ended, and the budget math excludes the away span a second time.
sub vacation_close_open_sessions($at) {
	$at = &rightNow() unless defined $at && $at =~ /^\s*\d+(?:\.\d+)?\s*$/;
	$at += 0;
	my $now = &rightNow();
	my $rows = eval {
		&db_query(
			"select uuid, app, timestamp, server_time from appointments"
			. " where (type = 'start' or type = 'record') and stop_seen is null"
			. " and cast(timestamp as integer) < cast(? as integer)",
			$at
		)->hashes;
	} || [];
	my $closed = 0;
	foreach my $row ( @{$rows} ) {
		my $uuid = $row->{'uuid'} // next;
		my $app = $row->{'app'} // next;
		my $started = int($row->{'timestamp'} // 0);
		next unless $started > 0 && $started < $at;
		my $paused = eval { &session_pause_peek($uuid) } || 0;
		my $duration = $started - $at + $paused;
		$duration = 0 if $duration > 0;
		&db_update('appointments', {
			type => 'stop',
			stop_timestamp => $at,
			stop_seen => 'yes',
			seen => 'yes',
			duration => $duration,
			server_time => $now,
		}, { uuid => $uuid, app => $app });
		eval { &session_pause_take($uuid) };
		$closed++;
	}
	return $closed;
}

# Start an away period. A future period is planned; one that has already begun
# closes the sessions that were open at its boundary. `to` may be omitted for
# an open-ended "until I am home".
sub vacation_start($data) {
	$data = {} unless ref $data eq 'HASH';
	my $now = &rightNow();
	my $from = _vacation_number($data->{'from'});
	$from = $now unless defined $from && $from > 0;
	my $to = _vacation_number($data->{'to'});
	$to = undef if defined $to && $to <= $from;
	my $place = $data->{'place'} // '';
	unless (length $place) {
		my $current = eval { &clothesline_current_place($from) };
		$place = (ref $current eq 'HASH' && $current->{'home'}) ? 'home' : 'away';
	}
	my $period = {
		uuid => &random_string_creator(24),
		from => $from,
		($to ? (to => $to) : ()),
		state => $from > $now ? 'planned' : 'active',
		kind => ($data->{'kind'} // 'vacation'),
		note => ($data->{'note'} // ''),
		place => $place,
		created => $now,
	};
	my $settings = &vacation_settings();
	my @periods = @{ $settings->{'periods'} || [] };
	push @periods, $period;
	$settings->{'periods'} = \@periods;
	&vacation_save($settings);
	&vacation_close_open_sessions($from) if $from <= $now;
	return $period;
}

sub vacation_end($uuid, $at) {
	my $now = &rightNow();
	$at = $now unless defined $at && $at =~ /^\s*\d+(?:\.\d+)?\s*$/;
	$at += 0;
	my $settings = &vacation_settings();
	my @periods = @{ $settings->{'periods'} || [] };
	my $found;
	foreach my $p ( @periods ) {
		next unless &vacation_accepted($p);
		next if defined $uuid && length $uuid && ($p->{'uuid'} // '') ne $uuid;
		next if $p->{'from'} > $at;
		next if defined $p->{'to'} && $p->{'to'} <= $at;
		if (!defined $found || $p->{'from'} >= $found->{'from'}) { $found = $p; }
	}
	return undef unless $found;
	$found->{'to'} = $at;
	$found->{'state'} = 'ended';
	$found->{'ended'} = $now;
	$settings->{'periods'} = \@periods;
	&vacation_save($settings);
	&vacation_close_open_sessions($at);
	return $found;
}

sub vacation_extend($uuid, $to) {
	my $period = &vacation_period($uuid);
	return undef unless $period;
	my $at = _vacation_number($to);
	return undef unless defined $at && $at > $period->{'from'};
	$period->{'to'} = $at;
	$period->{'state'} = $period->{'from'} > &rightNow() ? 'planned' : 'active';
	my $settings = &vacation_settings();
	$settings->{'periods'} = &vacation_periods();
	&vacation_save($settings);
	return $period;
}

sub vacation_cancel($uuid) {
	return undef unless defined $uuid && length $uuid;
	my $period = &vacation_period($uuid);
	return undef unless $period;
	# A period that has begun is ended, not erased: its away time is already part
	# of the budget's denominator and the history must keep it.
	return undef unless ($period->{'state'} // '') eq 'planned' || ($period->{'state'} // '') eq 'proposed';
	my $settings = &vacation_settings();
	my @kept = grep { ($_->{'uuid'} // '') ne $uuid } @{ $settings->{'periods'} || [] };
	$settings->{'periods'} = \@kept;
	&vacation_save($settings);
	return 1;
}

# A quiet gap the house noticed. It is kept as a question until the person
# answers; a proposal never pauses a budget. An ongoing gap has no `to`, so the
# card can say "until you are home"; a gap that has ended keeps its end. A later
# pass extends or closes the same proposal instead of stacking another.
sub vacation_propose($data) {
	$data = {} unless ref $data eq 'HASH';
	my $from = _vacation_number($data->{'from'});
	my $to = _vacation_number($data->{'to'});
	return undef unless defined $from && $from > 0;
	return undef if defined $to && $to <= $from;
	my $now = &rightNow();
	my $end = defined $to ? $to : $now;
	my $changed = 0;
	foreach my $p ( @{ &vacation_periods() } ) {
		my $p_to = $p->{'to'};
		next if $p->{'from'} > $end;
		next if defined $p_to && $p_to < $from;
		# An accepted span already covers this quiet time: nothing to ask.
		return $p if &vacation_accepted($p);
		return $p unless ($p->{'state'} // '') eq 'proposed';
		# One proposal, kept current: an ongoing gap opens it, a finished gap
		# closes it, and the earliest start is the one the person remembers.
		$p->{'from'} = $from if $from < $p->{'from'};
		if (!defined $to) {
			if (defined $p->{'to'}) { delete $p->{'to'}; $changed = 1; }
		}
		elsif (!defined $p->{'to'} || $to > $p->{'to'}) {
			$p->{'to'} = $to;
			$changed = 1;
		}
		if ($changed) {
			my $settings = &vacation_settings();
			$settings->{'periods'} = &vacation_periods();
			&vacation_save($settings);
		}
		return $p;
	}
	my $period = {
		uuid => &random_string_creator(24),
		from => $from,
		(defined $to ? (to => $to) : ()),
		state => 'proposed',
		kind => ($data->{'kind'} // 'away'),
		note => ($data->{'note'} // ''),
		place => ($data->{'place'} // ''),
		created => $now,
	};
	my $settings = &vacation_settings();
	push @{ $settings->{'periods'} }, $period;
	&vacation_save($settings);
	return $period;
}

sub vacation_proposal_answer($uuid, $accept) {
	my $period = &vacation_period($uuid);
	return undef unless $period && ($period->{'state'} // '') eq 'proposed';
	my $now = &rightNow();
	if ($accept) {
		my $to = $period->{'to'};
		if (!defined $to || $to >= $now - 5 * 60 * 1000) {
			# Still away (or only just back): the period is open ended until the
			# person presses I am home, so the budget does not resume mid-gap.
			delete $period->{'to'};
			$period->{'state'} = $period->{'from'} > $now ? 'planned' : 'active';
		}
		else {
			# A finished quiet spell is history: accepted, but not active now.
			$period->{'state'} = 'ended';
		}
		$period->{'accepted'} = $now;
		&vacation_close_open_sessions($period->{'from'}) if $period->{'from'} <= $now;
	}
	else {
		$period->{'state'} = 'dismissed';
		$period->{'dismissed'} = $now;
	}
	my $settings = &vacation_settings();
	$settings->{'periods'} = &vacation_periods();
	&vacation_save($settings);
	return $period;
}

# Save the opt-in detector. The hours are the quiet length that becomes a
# proposal; nothing is applied until the person confirms it.
sub vacation_auto_save($data) {
	$data = {} unless ref $data eq 'HASH';
	my $raw = $data->{'detect'} // '';
	my $detect = ($raw =~ /^(?:on|yes|true|1)$/i) ? 1 : 0;
	my $hours = _vacation_number($data->{'after_hours'});
	$hours = 24 unless defined $hours && $hours >= 1 && $hours <= 720;
	my $settings = &vacation_settings();
	$settings->{'auto'} = { detect => $detect, after_hours => $hours };
	&vacation_save($settings);
	return $settings->{'auto'};
}

# One pass over the house's own liveness: a quiet gap longer than the setting
# becomes a question. A server or computer runs it; a phone leaves the pass to
# the house. `live` and `force` are for the test, not for the job.
sub vacation_detect_tick($opts) {
	$opts ||= {};
	my $now = $opts->{'now'} || &rightNow();
	my $settings = &vacation_settings();
	my $auto = $settings->{'auto'} || {};
	return 0 unless ($auto->{'detect'} || 0) || $opts->{'force'};
	my $hours = _vacation_number($auto->{'after_hours'});
	$hours = 24 unless defined $hours && $hours >= 1 && $hours <= 720;
	my $after_ms = $hours * 3600000;
	# The activity is house-wide and synced: a day on the phone and the laptop
	# is not a quiet day just because the desk or the tablet was closed. Every
	# machine runs the pass; the proposal is de-duplicated in the setting.
	my $gaps = $opts->{'gaps'};
	$gaps = &vacation_house_gaps($now, $after_ms, limit => $opts->{'limit'})
		unless ref $gaps eq 'ARRAY';
	my $made = 0;
	foreach my $gap ( @{$gaps} ) {
		next unless ref $gap eq 'HASH';
		my $from = $gap->{'from'};
		my $to = $gap->{'to'};
		next unless defined $from && $from =~ /^\s*\d+(?:\.\d+)?\s*$/ && $from > 0;
		my $ongoing = $gap->{'ongoing'} || (defined $to && $to >= $now - 5 * 60 * 1000);
		my $proposal = &vacation_propose({
			from => $from,
			($ongoing ? () : (to => $to)),
			kind => 'away',
			note => 'quiet period',
		});
		$made++ if $proposal;
	}
	return $made;
}

# What a card or a status call needs, without every caller reading the JSON.
sub vacation_status($ts) {
	$ts = &rightNow() unless defined $ts;
	my $current = &vacation_now($ts);
	my ($next, $last);
	foreach my $p ( @{ &vacation_periods() } ) {
		next unless &vacation_accepted($p);
		if ($p->{'from'} > $ts) {
			$next = $p if !defined $next || $p->{'from'} < $next->{'from'};
			next;
		}
		next unless defined $p->{'to'} && $p->{'to'} <= $ts;
		$last = $p if !defined $last || $p->{'to'} > $last->{'to'};
	}
	my $digest;
	if ($last && ($ts - $last->{'to'}) < 7 * 86400000) {
		my $notices = eval {
			&db_query(
				'select count(*) as n from notifications where cast(timestamp as integer) >= cast(? as integer) and cast(timestamp as integer) < cast(? as integer)',
				$last->{'from'}, $last->{'to'}
			)->hash->{'n'};
		} || 0;
		$digest = {
			from => $last->{'from'},
			to => $last->{'to'},
			days => ($last->{'to'} - $last->{'from'}) / 86400000,
			notices => $notices + 0,
		};
	}
	my $data = &vacation_settings();
	my @proposals = sort { $a->{'from'} <=> $b->{'from'} }
		grep { ($_->{'state'} // '') eq 'proposed' } @{ $data->{'periods'} || [] };
	return {
		active => $current ? 1 : 0,
		current => $current,
		next => $next,
		last => $last,
		digest => $digest,
		proposals => \@proposals,
		periods => $data->{'periods'} || [],
		policy => $data->{'policy'},
		auto => $data->{'auto'},
	};
}

sub vacation_save($data) {
	$data = &vacation_normalize($data);
	&setting_setter({
		app => $vacation_app,
		setting => $vacation_setting,
		device => 'all',
		value => encode_json({
			version => ($data->{'version'} || 1),
			periods => $data->{'periods'} || [],
			policy => $data->{'policy'},
			auto => $data->{'auto'},
		}),
	});
	&vacation_forget();
	return 1;
}

1;
