package subs;

# Device2: extracted from subroutines.pl (package subs). Loaded on
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

# A provider that has answered "no credit" is stood down for a while, so the panel
# can hide its paid models and chat can step down to a free one.
our $AI_UNAVAILABLE_FOR;
our %PERIOD_TREND;
our $SPEED_MEASURE_CAP;
# The speed a GPS fix carried, saved where the evaluator's measurements live: an
# entry on the appointment's own measures ({speed => 5.0, ts => ...}), so every
# reading counts in the readings, averages and trends the same way a typed-in
# measure does. The house reads speed in km/h (the fix carries m/s). The app's
# measure table gets a name for it the first time, so it is a measure the house
# knows rather than a stray key. A fix with no speed (the device gave none) is
# left alone.
#
# Volume is the worry on a walk: a fix every few seconds would pile hundreds of
# readings on one appointment. So a reading is kept at most once a gap, and a
# long track keeps its most recent readings, not all of them. Both knobs are here.
our $SPEED_MEASURE_GAP_MS;
our $device;
our $gb;
our %m;

sub device_label {
	my ($sig) = @_;
	return '' unless defined $sig && length $sig;
	my $names = &device_labels();
	return $names->{$sig} || substr($sig, 0, 8);
}

# Which device records an appointment's movement. Two machines carried together
# would each file their own fixes and the appointment's distance would be
# counted twice; one device records and the rest keep their own current place
# and their home plates, they just do not file the appointment's movement.
#
#   my $sig = &subs::movement_recorder({ app => $app, appt => $uuid, signatorial => $me, timestamp => $t });
#
# The house setting movement_device answers: a signatorial names that machine,
# 'every' lets them all record (the old way), and 'auto' (the default) takes the
# device that has actually covered ground in the last hour, preferring the one
# that has been recording the appointment longest. A device standing still never
# wins over one that is moving, so a tablet left in the house cannot take a trip
# away from the phone that went for the walk.
sub movement_recorder {
	my ($p) = @_;
	$p ||= {};
	my $sig = $p->{'signatorial'} || '';
	my $choice = &setting_grabber({ app => '__president', setting => 'movement_device', device => 'all' });
	$choice = 'auto' unless defined $choice && length $choice;
	return &movement_choice({ choice => $choice, signatorial => $sig }) if $choice ne 'auto';
	my $appt = $p->{'appt'} || '';
	return $sig unless length $appt && length $p->{'app'};
	my $now = $p->{'timestamp'} || &rightNow();
	my $rows = &db_query(
		'select latitude, longitude, timestamp, signatorial from continent where app = ? and uuid like ? and cast(timestamp as integer) >= ? order by cast(timestamp as integer)',
		$p->{'app'}, $appt . '-%', $now - 3600000)->hashes;
	return &movement_choice({ choice => 'auto', signatorial => $sig, rows => $rows, now => $now });
}

# The decision behind movement_recorder with the rows already read, so it can be
# tested without a database. An explicit choice answers at once; 'auto' reads
# the appointment's fixes from the last hour and picks the device that went
# somewhere, the longest-recording one first.
sub movement_choice {
	my ($p) = @_;
	$p ||= {};
	my $sig = $p->{'signatorial'} || '';
	my $choice = $p->{'choice'} || 'auto';
	return $sig if $choice eq 'every' || $choice eq 'all';
	return $choice if $choice ne 'auto';
	my @rows = grep { ref $_ eq 'HASH' } @{ $p->{'rows'} || [] };
	return $sig unless scalar @rows;
	my $now = 0 + ( $p->{'now'} || 0 );
	my (%first, %last, %devs);
	foreach my $r ( @rows ) {
		my $dev = defined $r->{'signatorial'} ? $r->{'signatorial'} : '';
		my $ts = 0 + ( $r->{'timestamp'} || 0 );
		$first{$dev} = $ts if !defined $first{$dev} || $ts < $first{$dev};
		$last{$dev} = $ts if !defined $last{$dev} || $ts > $last{$dev};
		push @{ $devs{$dev} }, $r;
	}
	my %metres;
	foreach my $dev ( keys %devs ) {
		my $carrier = &carrier_device( $devs{$dev} );
		$metres{$dev} = $carrier ? $carrier->{'metres'} : 0;
	}
	# A device is travelling only when it has gone somewhere. The jitter floor in
	# carrier_device takes the small shuffles out, but a device parked for hours
	# can still creep a hundred metres, so a mover must also be a real share of
	# the furthest one: a tablet left at home never takes a 1 km walk from the
	# phone that recorded it.
	my $furthest = 0;
	foreach my $dev ( keys %metres ) {
		$furthest = $metres{$dev} if ( $metres{$dev} || 0 ) > $furthest;
	}
	my @movers = grep {
		( $metres{$_} || 0 ) >= 100 && ( $metres{$_} || 0 ) >= $furthest * 0.25
	} keys %devs;
	my @pool = scalar @movers ? @movers : keys %devs;
	my ($win) = sort {
		( $first{$a} || 0 ) <=> ( $first{$b} || 0 )
			|| ( $metres{$b} || 0 ) <=> ( $metres{$a} || 0 )
			|| $a cmp $b
	} @pool;
	return $sig unless defined $win;
	# a recorder that has gone quiet for a quarter of an hour has left: the device
	# that is here takes the trip over rather than losing it
	return $sig if $win ne $sig && $now && ( $now - ( $last{$win} || 0 ) ) > 900000;
	return $win;
}

# The places an app went, read from the continent table the GPS fills. A walk's
# track is a run of latitude/longitude rows tied to the appointment; summed here
# into what a report can use: how many places, how far (km), for how long, the
# box they fall in, where it started and ended, and the speed in km/h - from the
# speed the readings carried (the fix gives m/s), or the average worked out from
# the distance and the time when the readings carried no speed of their own.
sub evaluation_continent {
	my ($app, $since) = @_;
	return {} unless $app && $app ne '__president';
	my $rows = &subs::db_query(
		"select latitude, longitude, speed, timestamp from continent where app = ? and latitude is not null and latitude != '' and cast(timestamp as integer) >= ? order by cast(timestamp as integer)",
		$app, ($since || 0));
	return {} unless $rows;
	my ($points, $distance, $first, $last) = (0, 0, undef, undef);
	my ($north, $south, $east, $west);
	my ($sp_sum, $sp_n, $sp_max);
	my ($prev_lat, $prev_lon, $from, $to);
	foreach my $r ( @{ $rows->hashes } ) {
		next unless defined $r->{'latitude'} && $r->{'latitude'} =~ /^-?[0-9]/ && defined $r->{'longitude'} && $r->{'longitude'} =~ /^-?[0-9]/;
		my ($lat, $lon) = ($r->{'latitude'} + 0, $r->{'longitude'} + 0);
		my $ts = 0 + ($r->{'timestamp'} || 0);
		$points++;
		$first = $ts if !defined $first || $ts < $first;
		$last = $ts if !defined $last || $ts > $last;
		$north = $lat if !defined $north || $lat > $north;
		$south = $lat if !defined $south || $lat < $south;
		$east = $lon if !defined $east || $lon > $east;
		$west = $lon if !defined $west || $lon < $west;
		$from ||= [ $lat, $lon ];
		$to = [ $lat, $lon ];
		$distance += great_circle_distance(deg2rad($prev_lon), deg2rad(90 - $prev_lat), deg2rad($lon), deg2rad(90 - $lat), $gb::planet_radius) if defined $prev_lat;
		($prev_lat, $prev_lon) = ($lat, $lon);
		if (defined $r->{'speed'} && $r->{'speed'} =~ /^-?[0-9.]+$/) {
			$sp_sum += $r->{'speed'};
			$sp_n++;
			$sp_max = $r->{'speed'} if !defined $sp_max || $r->{'speed'} > $sp_max;
		}
	}
	return {} unless $points;
	my $out = {
		points => $points,
		distance_km => &subs::briefing_number($distance),
		bounds => { north => sprintf('%.4f', $north), south => sprintf('%.4f', $south), east => sprintf('%.4f', $east), west => sprintf('%.4f', $west) },
		from => { latitude => sprintf('%.4f', $from->[0]), longitude => sprintf('%.4f', $from->[1]) },
		to => { latitude => sprintf('%.4f', $to->[0]), longitude => sprintf('%.4f', $to->[1]) },
	};
	if ($last && $first && $last > $first) {
		$out->{'duration_minutes'} = &subs::briefing_number(($last - $first) / 60000);
	}
	if ($sp_n) {
		# the fix carries m/s; the house reads km/h
		$out->{'speed'} = { readings => $sp_n, average => &subs::briefing_number(($sp_sum / $sp_n) * 3.6), max => &subs::briefing_number($sp_max * 3.6), unit => 'km/h' };
	}
	elsif ($last && $first && $last > $first) {
		my $hours = ($last - $first) / 3600000;
		$out->{'speed'} = { average => &subs::briefing_number($distance / $hours), unit => 'km/h' } if $hours > 0;
	}
	return $out;
}

sub continent_speed_measure {
	my ($app, $uuid, $speed, $timestamp) = @_;
	return unless $app && $app ne '' && $uuid;
	return unless defined $speed && $speed =~ /^-?[0-9]+(?:\.[0-9]+)?$/;
	my $row = &subs::db_select('appointments', undef, { uuid => $uuid, app => $app })->hashes->[0];
	return unless $row->{'uuid'};
	my $measures = eval { return decode_json $row->{'measures'} } || [];
	my $when = defined $timestamp ? $timestamp : &subs::rightNow();
	# the throttle: the last reading wins a gap, and an out-of-order fix is skipped
	my $last;
	foreach my $entry ( @{$measures} ) {
		next unless defined $entry->{'speed'} && defined $entry->{'ts'};
		$last = $entry->{'ts'} if !defined $last || $entry->{'ts'} > $last;
	}
	return if defined $last && ($when - $last) < $SPEED_MEASURE_GAP_MS;
	push @{$measures}, { speed => sprintf('%.2f', $speed * 3.6), ts => $when };
	# the cap: drop the oldest speed readings once there are too many
	my @speed_idx = grep { defined $measures->[$_]->{'speed'} } 0 .. $#{$measures};
	if (scalar @speed_idx > $SPEED_MEASURE_CAP) {
		my %drop;
		$drop{$_} = 1 for @speed_idx[0 .. (scalar(@speed_idx) - $SPEED_MEASURE_CAP - 1)];
		$measures = [ map { $drop{$_} ? () : $measures->[$_] } 0 .. $#{$measures} ];
	}
	&subs::db_update('appointments', { measures => encode_json($measures), server_time => &subs::rightNow() }, { uuid => $uuid, app => $app });
	my $defs = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'app_measures' }) } || {};
	unless (ref $defs eq 'HASH' && $defs->{'speed'}) {
		$defs->{'speed'} = { type => 'number', unit => 'km/h' };
		&subs::setting_setter({ app => $app, setting => 'app_measures', value => encode_json $defs });
	}
	return 1;
}

# Where the moment sits in the calendar period it is in: the start, the start of
# the next period, and the fraction between them (0 at the opening instant, 1 as
# the next period begins). The periods come off the calendar - a month is however
# many days it holds, and daylight saving is honoured - the same way father_time
# builds a locked window, so a pace read here and a window drawn there agree.
# $week_start is the weekday a week begins on (0 Sunday, 1 Monday): the budget's
# locked window and the trend buckets start their weeks on different days, so
# each caller says which. This is what lets a part-run period be read as a pace
# rather than a fall.
sub period_bounds {
	my ($unit, $now, $week_start) = @_;
	$now = &rightNow() unless defined $now;
	$week_start = 0 unless defined $week_start;
	my $at = localtime($now / 1000);
	# The minute/hour windows come off the instant, not timelocal(): the local
	# minute and second are the same in both occurrences of the hour the clocks
	# repeat at fall-back, and timelocal() always resolves to the first one. This
	# gives each occurrence its own window and keeps a half-hour zone's :30 start.
	my $base = int($now);
	my $start = sub {
		my $offset = shift;
		if ($unit eq 'minute') {
			return $base - ($at->sec * 1000 + $base % 1000) + $offset * 60000;
		}
		if ($unit eq 'hour') {
			return $base - (($at->min * 60 + $at->sec) * 1000 + $base % 1000) + $offset * 3600000;
		}
		if ($unit eq 'year') {
			return timelocal(0, 0, 0, 1, 0, $at->year + $offset) * 1000;
		}
		if ($unit eq 'month') {
			my $index = $at->year * 12 + ($at->mon - 1) + $offset;
			return timelocal(0, 0, 0, 1, $index % 12, int($index / 12)) * 1000;
		}
		if ($unit eq 'week') {
			my $back = ($at->strftime('%w') - $week_start + 7) % 7;
			my $opens = timegm(0, 0, 0, $at->mday, $at->mon - 1, $at->year) - $back * 86400;
			my @date = gmtime($opens + 7 * $offset * 86400);
			return timelocal(0, 0, 0, $date[3], $date[4], $date[5]) * 1000;
		}
		my @date = gmtime(timegm(0, 0, 0, $at->mday, $at->mon - 1, $at->year) + $offset * 86400);
		return timelocal(0, 0, 0, $date[3], $date[4], $date[5]) * 1000;
	};
	my $begin = $start->(0);
	my $end = $start->(1);
	my $fraction = ($end > $begin) ? ($now - $begin) / ($end - $begin) : 1;
	$fraction = 0 if $fraction < 0;
	$fraction = 1 if $fraction > 1;
	return ($begin, $end, $fraction);
}

# the label of each of the last $n periods of a scope, oldest first, in the same
# form the SQL bucket produces
sub period_trend_labels {
	my ($unit, $n, $now) = @_;
	my @labels;
	if ($unit eq 'minute') {
		for (my $i = $n - 1; $i >= 0; $i--) {
			my @lt = localtime(($now - $i * 60000) / 1000);
			push @labels, sprintf('%04d-%02d-%02dT%02d:%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3], $lt[2], $lt[1]);
		}
	}
	elsif ($unit eq 'hour') {
		for (my $i = $n - 1; $i >= 0; $i--) {
			my @lt = localtime(($now - $i * 3600000) / 1000);
			push @labels, sprintf('%04d-%02d-%02dT%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3], $lt[2]);
		}
	}
	elsif ($unit eq 'day') {
		for (my $i = $n - 1; $i >= 0; $i--) {
			my @lt = localtime(($now - $i * 86400000) / 1000);
			push @labels, sprintf('%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3]);
		}
	}
	elsif ($unit eq 'week') {
		my $dow = (localtime($now / 1000))[6];
		my $monday = $now - (($dow + 6) % 7) * 86400000;
		for (my $i = $n - 1; $i >= 0; $i--) {
			my @m = localtime(($monday - $i * 7 * 86400000) / 1000);
			push @labels, sprintf('%04d-%02d-%02d', $m[5] + 1900, $m[4] + 1, $m[3]);
		}
	}
	elsif ($unit eq 'month') {
		my @lt = localtime($now / 1000);
		my ($y, $mo) = ($lt[5] + 1900, $lt[4]);
		my @rev;
		for (my $i = 0; $i < $n; $i++) {
			my $mm = $mo - $i;
			my $yy = $y;
			while ($mm < 0) { $mm += 12; $yy--; }
			push @rev, sprintf('%04d-%02d', $yy, $mm + 1);
		}
		@labels = reverse @rev;
	}
	elsif ($unit eq 'year') {
		my $y = (localtime($now / 1000))[5] + 1900;
		for (my $i = $n - 1; $i >= 0; $i--) { push @labels, sprintf('%04d', $y - $i); }
	}
	return @labels;
}

# The last few periods of every scope, oldest first, as "label=count ..." - the
# same compact shape as a window's daily_counts, but for month, week, day, hour
# and minute as well, so the model reads the pace period by period. $count is the
# app's own scope count (how many periods its graph walks), capped per scope so
# the short clocks do not swamp the prompt.
sub evaluation_period_trends {
	my ($app, $count) = @_;
	return {} unless $app && $app ne '__president';
	$count = 30 unless $count && $count =~ /^[0-9]+$/ && $count > 0;
	my $now = &subs::rightNow();
	my $out = {};
	foreach my $unit ( qw/minute hour day week month year/ ) {
		my $spec = $PERIOD_TREND{$unit};
		my $n = $count < $spec->{'cap'} ? $count : $spec->{'cap'};
		my @labels = &subs::period_trend_labels($unit, $n, $now);
		next unless scalar @labels;
		# a period ahead of the oldest label can still start within a week/month
		# of it, so the scan reaches back one period further than the labels
		my $since = $now - ($n + 1) * $spec->{'seconds'} * 1000;
		my $rows = &subs::db_query(
			'select ' . $spec->{'bucket'} . ' as bucket, count(*) as c from appointments where app = ? and cast(timestamp as integer) >= ? group by bucket',
			$app, $since)->hashes;
		my %c = map { $_->{'bucket'} => ($_->{'c'} + 0) } @{$rows};
		# a scope with nothing at all in its window says nothing a trend can use - an
		# hourly app is quiet across the last thirty minutes by design - so it is left
		# out rather than handed over as a row of zeros the model might remark on
		next unless grep { $c{$_} } @labels;
		# the newest period is the one still running, so its count is a part of a
		# period, not a whole one. It is handed over as label=count/percent, the
		# percent saying how far through that period the run happened, so a low count
		# early in the period reads as a period in progress rather than a pace falling
		# away. The label buckets start their weeks on Monday, so the fraction is read
		# from the same Monday.
		my $newest = $labels[-1];
		my (undef, undef, $elapsed) = &period_bounds($unit, $now, 1);
		my $percent = int($elapsed * 100 + 0.5);
		$out->{$unit} = join ' ', map {
			$_ eq $newest ? $_ . '=' . ($c{$_} || 0) . '/' . $percent . '%' : $_ . '=' . ($c{$_} || 0)
		} @labels;
	}
	return $out;
}

# every day of the window, so a lag stays a lag in calendar days even when a
# series has holes in it
sub evaluation_window_days {
	my ($since) = @_;
	my $now = &subs::rightNow();
	my @days;
	for (my $t = $since; $t <= $now + 86400000; $t += 86400000) {
		my @lt = localtime($t / 1000);
		push @days, sprintf('%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3]);
	}
	my %seen;
	return [ grep { !$seen{$_}++ } @days ];
}

# Pearson over day maps that may have holes - a day without a reading is not a
# zero reading - joined on the window's days, so the best lag is in days
sub day_map_correlation {
	my ($da, $db, $days) = @_;
	my $n = scalar @{$days};
	my ($best, $best_lag);
	foreach my $lag ( -2 .. 2 ) {
		my ($sx,$sy,$sxx,$syy,$sxy,$m) = (0,0,0,0,0,0);
		foreach my $i ( 0 .. $n - 1 ) {
			my $j = $i + $lag;
			next if $j < 0 || $j > $n - 1;
			my $xa = $da->{ $days->[$i] };
			my $yb = $db->{ $days->[$j] };
			next unless defined $xa && defined $yb;
			$sx += $xa; $sy += $yb; $sxx += $xa ** 2; $syy += $yb ** 2; $sxy += $xa * $yb; $m++;
		}
		next if $m < 14;
		my $den = sqrt(($m * $sxx - $sx ** 2) * ($m * $syy - $sy ** 2));
		next unless $den;
		my $r = ($m * $sxy - $sx * $sy) / $den;
		if (!defined $best || abs($r) > abs($best)) { $best = $r; $best_lag = $lag; }
	}
	return undef unless defined $best;
	return { r => sprintf('%.2f', $best), lag_days => $best_lag };
}

# Two series that both run on nearly every day of the window correlate by
# construction - the calendar, not a cause. The maps that can have holes
# (measured readings) count a day by being defined, the others by being non-zero.
sub daily_habit {
	my ($da, $db, $days, $da_holes, $db_holes) = @_;
	my $n = scalar @{$days};
	return 0 unless $n;
	my $a = $da_holes ? (grep { defined $da->{$_} } @{$days}) : (grep { ($da->{$_} || 0) != 0 } @{$days});
	my $b = $db_holes ? (grep { defined $db->{$_} } @{$days}) : (grep { ($db->{$_} || 0) != 0 } @{$days});
	return 0 unless $a >= 0.8 * $n && $b >= 0.8 * $n;
	return 1;
}

# what else was happening: every app's daily counts and every numeric measure
# any app logged, correlated against the targets. The relational window only
# knows the apps it was shown, so a headache never gets to blame the humidity
# unless it is asked to look at the whole house.
sub context_correlations {
	my ($targets, $days, $counts, $measures) = @_;
	my @candidates;
	foreach my $capp ( sort keys %{$counts} ) {
		push @candidates, { app => $capp, measure => undef, day_map => $counts->{$capp} };
	}
	foreach my $capp ( sort keys %{$measures} ) {
		foreach my $name ( sort keys %{$measures->{$capp}} ) {
			push @candidates, { app => $capp, measure => $name, day_map => $measures->{$capp}->{$name} };
		}
	}
	# a source that shows up on nearly every day is a schedule, not a signal: a
	# metal price, a weather reading or a currency quote fetched every day
	# correlates with everything by construction. Its presence is filtered out
	# before it can be offered as a finding; a reading that actually comes and
	# goes (fewer days, real movement) still gets its chance.
	my $n_days = scalar @{$days};
	foreach my $cand ( @candidates ) {
		my $holes = defined $cand->{'measure'};
		my $present = $holes ? (grep { defined $cand->{'day_map'}->{$_} } @{$days}) : (grep { ($cand->{'day_map'}->{$_} || 0) != 0 } @{$days});
		$cand->{'presence'} = $n_days ? $present / $n_days : 1;
	}
	my @out;
	foreach my $target ( @{$targets} ) {
		my $tseries = $target->{'measure'} ? ($measures->{ $target->{'app'} }->{ $target->{'measure'} } || {}) : ($counts->{ $target->{'app'} } || {});
		next unless scalar keys %{$tseries};
		my @tx = $target->{'measure'} ? () : map { $tseries->{$_} || 0 } @{$days};
		# a target that barely ran cannot carry a count correlation - the pair
		# would be the target's one day wearing the candidate's habits. Sparse
		# days are the different list's business instead.
		my $target_active = grep { ($tseries->{$_} || 0) > 0 } @{$days};
		foreach my $cand ( @candidates ) {
			# a series is not a story against itself
			next if $cand->{'app'} eq $target->{'app'} && !defined $cand->{'measure'} && !defined $target->{'measure'};
			next if $cand->{'app'} eq $target->{'app'} && defined $cand->{'measure'} && defined $target->{'measure'} && $cand->{'measure'} eq $target->{'measure'};
			next if $cand->{'presence'} >= 0.8;
			my $c;
			if (!defined $cand->{'measure'} && !defined $target->{'measure'}) {
				my @cx = map { $cand->{'day_map'}->{$_} || 0 } @{$days};
				$c = ($target_active >= 7) ? &subs::series_correlation(\@cx, \@tx) : undef;
			}
			else {
				# a count of nothing on a day is zero, but a missing reading is a hole
				my $cmap = defined $cand->{'measure'} ? $cand->{'day_map'} : { map { $_ => ($cand->{'day_map'}->{$_} || 0) } @{$days} };
				my $tmap = defined $target->{'measure'} ? $tseries : { map { $_ => ($tseries->{$_} || 0) } @{$days} };
				$c = &subs::day_map_correlation($cmap, $tmap, $days);
			}
			next unless $c && abs($c->{'r'}) >= 0.6;
			my $entry = { app => $cand->{'app'}, vs_app => $target->{'app'}, r => $c->{'r'}, lag_days => $c->{'lag_days'} };
			$entry->{'measure'} = $cand->{'measure'} if defined $cand->{'measure'};
			$entry->{'vs_measure'} = $target->{'measure'} if defined $target->{'measure'};
			$entry->{'habit'} = 1 if &subs::daily_habit($cand->{'day_map'}, $tseries, $days, defined $cand->{'measure'}, defined $target->{'measure'});
			push @out, $entry;
		}
	}
	# the arms-length list leads with the pairs that are not just two daily
	# habits; the habits still trail it, flagged, so the report can name them
	@out = sort { ($a->{'habit'} || 0) <=> ($b->{'habit'} || 0) || abs($b->{'r'}) <=> abs($a->{'r'}) } @out;
	splice(@out, 10) if scalar @out > 10;
	return \@out;
}

# What ran around this app's own occurrences: for each occurrence, the other
# apps whose occurrences fall within a window either side of it, so a thing that
# consistently happens at the same time of day - the coffee after waking, the
# walk after lunch, the code right after the coffee - stands out. A correlation
# of daily totals drowns that in the calendar (two daily routines move together
# by construction); an event read asks instead how often the thing was actually
# there when this one happened, against how often chance would put it there.
# Returns the apps that co-occur more than chance, each with how many of this
# app's occurrences had it nearby (hits), how many were scanned (of), the lift
# over chance, and the average offset in minutes (negative when it tends to come
# before this app, positive after).
sub evaluation_context_scan {
	my ($app, $since, $delta, $cap) = @_;
	return [] unless $app && $app ne '__president';
	$since = &subs::rightNow() - 60 * 86400000 unless $since;
	$delta = 30 * 60000 unless $delta && $delta > 0;
	$cap ||= 8;
	my $rows = &subs::db_query('select app, cast(timestamp as integer) as ts from appointments where cast(timestamp as integer) >= ? order by ts', $since)->hashes;
	my @all = map { { ts => $_->{'ts'} + 0, app => $_->{'app'} } } @{$rows};
	return [] unless scalar @all;
	my $span = &subs::rightNow() - $since;
	$span = 1 unless $span > 0;
	my (%total, @targets);
	foreach my $e ( @all ) {
		$total{ $e->{'app'} }++;
		push @targets, $e->{'ts'} if $e->{'app'} eq $app;
	}
	return [] unless scalar @targets >= 3;
	# a sliding window over the sorted events: as the occurrence walks forward,
	# events enter at the far edge and leave at the near one, so one pass counts
	# the co-occurrences and their signed offsets
	my (%hits, %offset, %count, %tsum);
	my ($lo, $hi) = (0, 0);
	my $N = scalar @all;
	foreach my $t ( @targets ) {
		while ($hi < $N && $all[$hi]{'ts'} <= $t + $delta) { my $a = $all[$hi]{'app'}; $count{$a}++; $tsum{$a} += $all[$hi]{'ts'}; $hi++; }
		while ($lo < $hi && $all[$lo]{'ts'} < $t - $delta) { my $a = $all[$lo]{'app'}; $count{$a}--; $tsum{$a} -= $all[$lo]{'ts'}; $lo++; }
		foreach my $y ( keys %count ) {
			next if $y eq $app || !$count{$y};
			$hits{$y} += $count{$y};
			$offset{$y} += $tsum{$y} - $t * $count{$y};
		}
	}
	my $nX = scalar @targets;
	my @out;
	foreach my $y ( keys %hits ) {
		next unless $total{$y};
		my $expect = $nX * $total{$y} * (2 * $delta) / $span;
		next if $expect <= 0;
		my $lift = $hits{$y} / $expect;
		next if $hits{$y} < 4 || $lift < 1.5;
		push @out, {
			app => $y,
			hits => $hits{$y},
			of => $nX,
			lift => sprintf('%.1f', $lift),
			offset_minutes => sprintf('%.0f', $offset{$y} / $hits{$y} / 60000),
		};
	}
	@out = sort { $b->{'lift'} <=> $a->{'lift'} || $b->{'hits'} <=> $a->{'hits'} } @out;
	splice(@out, $cap) if scalar @out > $cap;
	return \@out;
}

# what was out of the ordinary on the days this app ran: every measure's
# average on those days against its average on the window's other days, scaled
# by how spread the measure is. A sparse app can still point at a reading this
# way, which a correlation needs too many days to do.
sub measure_contrasts {
	my ($app, $days, $counts, $measures) = @_;
	my %active = map { $_ => 1 } keys %{ $counts->{$app} || {} };
	my @out;
	foreach my $capp ( sort keys %{$measures} ) {
		foreach my $name ( sort keys %{$measures->{$capp}} ) {
			my (@on, @off);
			foreach my $day ( @{$days} ) {
				my $v = $measures->{$capp}->{$name}->{$day};
				next unless defined $v;
				if ($active{$day}) { push @on, $v; } else { push @off, $v; }
			}
			# one day with the app is the case this list exists for - a single
			# headache against the rest of the month - so only the other side
			# needs some width to it
			next if scalar @on < 1 || scalar @off < 3;
			my ($sum_all, $sum_on, $n_all) = (0, 0, 0);
			foreach my $v ( @on ) { $sum_on += $v; $sum_all += $v; $n_all++; }
			foreach my $v ( @off ) { $sum_all += $v; $n_all++; }
			my $mean_on = $sum_on / scalar @on;
			my $mean_off = ($sum_all - $sum_on) / scalar @off;
			my $mean = $sum_all / $n_all;
			my $var = 0;
			$var += ($_ - $mean) ** 2 foreach ( @on, @off );
			my $sd = sqrt($var / $n_all);
			next unless $sd;
			# a measure that barely moves (a currency quote) turns a cent into a
			# large z: the list is for readings that actually vary
			next unless $sd >= 0.03 * abs($mean);
			my $z = ($mean_on - $mean_off) / $sd;
			next unless abs($z) >= 0.8;
			push @out, {
				app => $capp, measure => $name,
				on_days => &subs::briefing_number($mean_on),
				off_days => &subs::briefing_number($mean_off),
				z => &subs::briefing_number($z),
				days_on => scalar @on, days_off => scalar @off,
			};
		}
	}
	@out = sort { abs($b->{'z'}) <=> abs($a->{'z'}) } @out;
	splice(@out, 8) if scalar @out > 8;
	return \@out;
}

# Every AI provider the Platform panel can point a model at, and the models each
# offers. A model is chosen by id: a bare name goes to the local Ollama,
# @cf/... to Cloudflare, and everything else is "provider:model".
sub ai_providers {
	return [
		{ id => 'ollama',     label => 'Ollama (local)',        keys => [ [ 'ollama_key', 'API key (optional)' ] ] },
		{ id => 'cloudflare', label => 'Cloudflare Workers AI', keys => [ [ 'cloudflare_account', 'Account ID' ], [ 'cloudflare_token', 'API token' ] ] },
		{ id => 'openai',     label => 'OpenAI',                keys => [ [ 'openai_key', 'API key' ] ],
			models => [ qw/gpt-4o gpt-4o-mini gpt-4.1 gpt-4.1-mini o3-mini o1/ ] },
		{ id => 'anthropic',  label => 'Anthropic (Claude)',    keys => [ [ 'anthropic_key', 'API key' ] ],
			models => [ qw/claude-sonnet-4-20250514 claude-opus-4-20250514 claude-3-7-sonnet-latest claude-3-5-sonnet-latest claude-3-5-haiku-latest/ ] },
		{ id => 'google',     label => 'Google (Gemini)',       keys => [ [ 'google_key', 'API key' ] ],
			models => [ qw/gemini-2.5-pro gemini-2.5-flash gemini-2.0-flash veo-3.0-generate-preview veo-3.1-generate-preview/ ] },
		{ id => 'xai',        label => 'xAI (Grok)',            keys => [ [ 'xai_key', 'API key' ] ],
			models => [ qw/grok-3 grok-3-mini grok-2-1212/ ] },
		{ id => 'deepseek',   label => 'DeepSeek',              keys => [ [ 'deepseek_key', 'API key' ] ],
			# The ids must match DeepSeek's API exactly; its /models lists these two
			# (deepseek-flash is V4.1 Flash, deepseek-v4-pro the pro).
			models => [ qw/deepseek-flash deepseek-v4-pro/ ] },
		{ id => 'mistral',    label => 'Mistral',               keys => [ [ 'mistral_key', 'API key' ] ],
			models => [ qw/mistral-large-latest mistral-small-latest codestral-latest/ ] },
		{ id => 'cohere',     label => 'Cohere',                keys => [ [ 'cohere_key', 'API key' ] ],
			# compatibility API chat ids; check /models before bumping
			models => [ qw/command-a-plus-05-2026 command-a-03-2025/ ] },
		{ id => 'groq',       label => 'Groq',                  keys => [ [ 'groq_key', 'API key' ] ],
			models => [ qw/llama-3.3-70b-versatile llama-3.1-8b-instant mixtral-8x7b-32768 whisper-large-v3-turbo playai-tts/ ] },
		{ id => 'openrouter', label => 'OpenRouter',            keys => [ [ 'openrouter_key', 'API key' ] ],
			models => [ qw{openai/gpt-4o anthropic/claude-3.5-sonnet meta-llama/llama-3.3-70b-instruct google/gemini-2.0-flash-001} ] },
	];
}

# Every setting name that holds a secret, so a panel can tell a key from a value.
sub ai_key_settings {
	return map { $_->[0] } map { @{ $_->{'keys'} } } @{ &subs::ai_providers() };
}

# Whether a provider can answer here at all: the key (or account) it needs is
# entered, and for the local Ollama the daemon is actually running. "Valid"
# beyond that is only knowable by calling it - the bucket tracker already stands
# down an account that answered with no credit, and the Plat panel hides those
# paid models. The model lists only offer providers that pass this.
sub ai_provider_ready {
	my ($id) = @_;
	return 0 unless defined $id && length $id;
	# a peer's own Ollama we hold a cached model list for is offered by its device
	return 1 if $id =~ /^ollama:/;
	my ($p) = grep { ($_->{'id'} || '') eq $id } @{ &subs::ai_providers() };
	return 0 unless $p;
	if ($id eq 'ollama') {
		my $ua = Mojo::UserAgent->new(connect_timeout => 2, inactivity_timeout => 3, request_timeout => 4);
		my $res = eval { $ua->get('http://localhost:11434/api/tags')->result };
		return ($res && $res->is_success) ? 1 : 0;
	}
	my $values = &subs::settings_grabber({ app => 'mail', settings => [ map { $_->[0] } @{ $p->{'keys'} || [] } ] });
	foreach my $k ( @{ $p->{'keys'} || [] } ) {
		my $v = $values->{ $k->[0] };
		return 0 unless defined $v && length $v;
	}
	return 1;
}

# A provider with an account on file: at least one of the settings it needs is
# filled in. Ollama's key is optional, so a bare local daemon has no account and
# does not count; passing $values avoids re-reading the settings per provider.
sub ai_provider_registered {
	my ($provider, $values) = @_;
	return 0 unless ref $provider eq 'HASH';
	$values ||= &subs::settings_grabber({ app => 'mail', settings => [ map { $_->[0] } @{ $provider->{'keys'} || [] } ] });
	foreach my $k ( @{ $provider->{'keys'} || [] } ) {
		my $v = $values->{ $k->[0] };
		return 1 if defined $v && length $v;
	}
	return 0;
}

# The model choices, grouped by provider, for the dropdowns. Ollama and
# Cloudflare are read live; the rest are the fixed lists above.
#
# Which of chat / vision / image / audio a model can serve, so a role only offers
# models that fit it: a text chatbot is not offered a vision-only model, and the
# Vision role is not offered a plain text one. A name is the only signal for most
# providers, so this is a heuristic and errs toward 'chat'.
sub ai_model_caps_by_name {
	my ($name) = @_;
	my $n = lc($name || '');
	return ('image') if $n =~ /(dall-e|gpt-image|stable-?diffusion|sdxl|sd3|flux|imagen|playground-v2|kandinsky|dreamshaper|lucid|phoenix|text-to-image|text2image)/;
	return ('video-gen') if $n =~ /(veo|runway|sora|video-?gen|text-?to-?video|image-?to-?video|stable-?video|kling|luma|mochi|pika|wan-?video|haiper|flux-?video)/;
	return ('audio-gen') if $n =~ /(musicgen|audio-?gen|music-?gen|audio-?lm|suno|riffusion|stable-?audio|bark|elevenlabs|melod|melotts|aura-|\btts\b|speech-?synth)/;
	return ('audio') if $n =~ /(whisper|asr|transcri|speech-to-text|\bstt\b|deepgram|nova-?2|parakeet)/;
	return ('other') if $n =~ /(embed|rerank|\bbge\b|resnet|distilbert|sst-2|translat|m2m100|indictrans|guard|smart-turn|moderation)/;
	return ('vision') if $n =~ /(llava|bakllava|moondream|minicpm-?v|cogvlm|pixtral|qwen2-?vl|qwen2\.5-?vl|qwen2\.5vl|internvl|llama-?3\.2-vision|vision)/;
	return ('chat', 'vision') if $n =~ /(gpt-4o|gpt-4\.1|claude|gemini|gemma3|gemma4|grok-2-vision|grok-vision)/;
	return ('chat');
}

sub ai_model_caps_by_task {
	my ($task) = @_;
	my $t = lc($task || '');
	return ('image') if $t =~ /text-to-image|image generation|image-to-image|inpaint|image editing/;
	return ('video-gen') if $t =~ /text-to-video|video generation|image-to-video/;
	return ('audio-gen') if $t =~ /audio generation|text-to-audio|music/;
	return ('vision') if $t =~ /image-to-text|visual question|image classification|object detection|vision/;
	return ('audio') if $t =~ /speech|audio|asr|text-to-speech|tts/;
	return ('chat') if $t =~ /text generation|conversational|summariz|chat/;
	return ('other');
}

sub ai_model_caps {
	my ($provider, $name, $meta) = @_;
	my $task = '';
	if (ref $meta eq 'HASH' && defined $meta->{'task'}) {
		# Cloudflare's search returns task as an object { id, name } in some versions
		$task = ref $meta->{'task'} eq 'HASH' ? ($meta->{'task'}->{'name'} || $meta->{'task'}->{'id'} || '') : $meta->{'task'};
		$task = '' if ref $task;
	}
	if ($provider eq 'cloudflare' && $task) {
		return &ai_model_caps_by_task($task);
	}
	my $family = (ref $meta eq 'HASH' && ref $meta->{'details'} eq 'HASH') ? ($meta->{'details'}->{'family'} || '') : '';
	return &ai_model_caps_by_name($family ? ($name . ' ' . $family) : $name);
}

# Which provider a model id points at. A bare name (and a :cloud one) goes to
# Ollama; @cf/... to Cloudflare; the rest are "provider:model".
sub ai_model_provider {
	my ($model) = @_;
	return 'cloudflare' if $model =~ /^\@cf/;
	# a peer's own Ollama: @<device>/<model>, so a model can be picked by the
	# machine that runs it
	return 'ollama_remote' if $model =~ /^\@[^\/]+\/.+$/;
	return $1 if $model =~ /^([a-z]+):/ && grep { $_ eq $1 } qw/openai anthropic google xai mistral cohere groq openrouter deepseek/;
	return 'ollama';
}

# The machine a @<device>/<model> names, or ''.
sub ai_model_device {
	my ($model) = @_;
	return $1 if $model =~ /^\@([^\/]+)\/.+$/;
	return '';
}

# The billing bucket a model draws on. Local Ollama and Cloudflare (its plan is
# included) are free; an Ollama :cloud model and every third-party provider cost.
sub ai_model_bucket {
	my ($model) = @_;
	my $provider = &ai_model_provider($model);
	return 'ollama_cloud' if ($provider eq 'ollama' || $provider eq 'ollama_remote') && $model =~ /:cloud\b/i;
	return $provider;
}

sub ai_model_paid {
	my ($model) = @_;
	my $bucket = &ai_model_bucket($model);
	return 0 if $bucket eq 'cloudflare' || $bucket eq 'ollama' || $bucket eq 'ollama_remote';
	return 1;
}

sub ai_bucket_available {
	my ($bucket) = @_;
	return 1 unless $bucket;
	my $until = &subs::setting_grabber({ app => '__president', setting => 'ai_' . $bucket . '_unavailable' });
	return 1 unless $until && $until > &subs::rightNow();
	return 0;
}

sub ai_bucket_mark_unavailable {
	my ($bucket, $reason, $ms) = @_;
	return unless $bucket;
	$ms = $AI_UNAVAILABLE_FOR unless defined $ms && $ms > 0;
	&subs::setting_setter({ app => '__president', setting => 'ai_' . $bucket . '_unavailable', value => &subs::rightNow() + $ms });
	my $for = $ms >= 60000 ? int($ms / 60000 + 0.5) . ' min' : int($ms / 1000) . 's';
	&subs::say_it('AI: ' . $bucket . ' is paused for ' . $for . ' (' . substr($reason || '', 0, 80) . ')');
}

1;
