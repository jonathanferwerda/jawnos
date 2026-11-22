package subs;

# House-wide activity for the away-period detector.
#
# The detector used to read `clothesline_device_liveness`, which is built from
# `websockets` - a local, deliberately unsynced table. A server that was unused
# for a day therefore looked like a quiet house even when the phone and laptop
# were busy. This module reads the synced activity instead: usage sessions,
# window events and appointment writes from every device, plus this machine's
# own sockets. A gap is a stretch with no activity from any of them.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

# The activity intervals from the last `limit` rows of each store, merged.
# A row's end is clipped to now; a future appointment is not activity yet.
my $activity_intervals = sub {
	my ($now, $limit) = @_;
	my @spans;
	my $push = sub {
		my ($start, $end) = @_;
		return unless defined $start && $start =~ /^\s*\d+(?:\.\d+)?\s*$/ && $start > 0;
		$start += 0;
		$end = $start unless defined $end && $end =~ /^\s*\d+(?:\.\d+)?\s*$/;
		$end += 0;
		$end = $start if $end < $start;
		return if $start > $now;
		$end = $now if $end > $now;
		push @spans, [ $start, $end ];
	};

	# A usage session is the strongest signal: it is written by the phone, the
	# laptop and the desk alike, and it carries the device that was used.
	my $usage = eval {
		&db_query(
			'select started_at, ended_at from usage_sessions'
			. ' order by cast(coalesce(ended_at, started_at) as integer) desc limit ?',
			$limit
		)->hashes;
	} || [];
	foreach my $row ( @{$usage} ) {
		my $start = $row->{'started_at'};
		my $end = $row->{'ended_at'};
		$end = $start unless defined $end && $end =~ /^\s*\d/;
		$push->($start, $end);
	}

	# A window open/close is a point in time. Its timestamp is the event's own
	# clock; server_time would make a late peer sync look like fresh use.
	my $windows = eval {
		&db_query(
			'select timestamp from window_events'
			. ' order by cast(timestamp as integer) desc limit ?',
			$limit
		)->hashes;
	} || [];
	foreach my $row ( @{$windows} ) {
		my $at = $row->{'timestamp'};
		$push->($at, $at) if defined $at && $at =~ /^\s*\d/ && $at + 0 <= $now;
	}

	# An appointment is an interval when it carries a stop, otherwise a point.
	# The write itself (server_time) is activity too: a schedule typed for next
	# month still used the house today.
	my $appts = eval {
		&db_query(
			'select timestamp, stop_timestamp, server_time from appointments'
			. ' order by cast(server_time as integer) desc limit ?',
			$limit
		)->hashes;
	} || [];
	foreach my $row ( @{$appts} ) {
		my $ts = $row->{'timestamp'};
		my $stop = $row->{'stop_timestamp'};
		if (defined $ts && $ts =~ /^\s*\d/ && $ts + 0 <= $now) {
			my $end = (defined $stop && $stop =~ /^\s*\d/ && $stop + 0 >= $ts + 0) ? $stop : $ts;
			$push->($ts, $end);
		}
		my $seen = $row->{'server_time'};
		if (defined $seen && $seen =~ /^\s*\d/ && $seen + 0 <= $now
			&& (!defined $ts || $seen + 0 != $ts + 0)) {
			$push->($seen, $seen);
		}
	}

	# This machine's own live sockets. They are local, so they are an extra
	# signal rather than the house-wide answer.
	my $sockets = eval {
		&db_query(
			'select connected, timestamp, server_time, type from websockets'
			. ' order by cast(server_time as integer) desc limit 200'
		)->hashes;
	} || [];
	foreach my $row ( @{$sockets} ) {
		my $start = $row->{'connected'};
		next unless defined $start && $start =~ /^\s*\d/ && $start + 0 > 0;
		my $closed = lc($row->{'type'} // '') eq 'closed';
		my $end = $closed ? $row->{'server_time'} : ($row->{'timestamp'} || $row->{'server_time'});
		$push->($start, $end);
	}

	@spans = sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @spans;
	my @merged;
	foreach my $span ( @spans ) {
		if (@merged && $span->[0] <= $merged[-1][1]) {
			$merged[-1][1] = $span->[1] if $span->[1] > $merged[-1][1];
			next;
		}
		push @merged, [ $span->[0], $span->[1] ];
	}
	return \@merged;
};

# The quiet gaps between house activity, at least `after_ms` long. The prefix
# before the first activity is not a gap: a fresh house has no history to be
# away from. The ongoing gap is marked, so the caller can leave it open ended.
sub vacation_house_gaps($now, $after_ms, %opt) {
	$now = &rightNow() unless defined $now && $now =~ /^\s*\d+(?:\.\d+)?\s*$/;
	$now += 0;
	$after_ms = 0 unless defined $after_ms && $after_ms =~ /^\s*\d+(?:\.\d+)?\s*$/;
	$after_ms += 0;
	return [] unless $after_ms > 0 && $now > 0;
	my $limit = $opt{'limit'} || 1000;
	$limit = 1 if $limit < 1;
	$limit = 5000 if $limit > 5000;
	my $spans = $activity_intervals->($now, $limit);
	return [] unless @{$spans};
	my @gaps;
	my $cursor = $spans->[0][1];
	foreach my $i ( 1 .. $#{$spans} ) {
		my $start = $spans->[$i][0];
		if ($start - $cursor >= $after_ms) {
			push @gaps, { from => $cursor, to => $start, ongoing => 0 };
		}
		$cursor = $spans->[$i][1] if $spans->[$i][1] > $cursor;
	}
	if ($now - $cursor >= $after_ms) {
		push @gaps, { from => $cursor, to => $now, ongoing => 1 };
	}
	return \@gaps;
}

1;
