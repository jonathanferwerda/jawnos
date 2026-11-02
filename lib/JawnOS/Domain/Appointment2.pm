package subs;

# Appointment2: extracted from subroutines.pl (package subs). Loaded on
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

our %H;
our $database;
our $device;
our $gb;
our %m;

# --- the evaluation agent -------------------------------------------------------
# The evaluate buttons hand an app - or the whole house - to this. The raw
# appointment numbers are rolled up first: counts, durations, an hourly and a
# weekday profile, and one count per calendar day. The relational window's
# links (the sc_ lists, one per construct) are walked to find the apps tied to
# it, and each tied app's daily series is lined up against the app's own and
# correlated - Pearson, tried at a small spread of lags, so a thing that
# follows another can say so. Only then does a model speak: its job is the
# words - trends, correlations, predictions - never the arithmetic, which the
# numbers below it have already done.
sub appointment_rollup {
	my ($app, $since) = @_;
	my $global = ($app eq '__president');
	# one where-clause for every roll-up: the app (unless whole house) and the
	# window the evaluation may read. A shorter window is fewer numbers, and the
	# numbers are the token bill
	my @where;
	my @args;
	unless ($global) { push @where, 'app = ?'; push @args, $app; }
	if ($since) { push @where, 'cast(timestamp as integer) >= ?'; push @args, $since; }
	my $filter = scalar @where ? ' where ' . join(' and ', @where) : '';
	my $roll = { activity => {}, hours => {}, weekdays => {}, daily => {} };
	my $owner_of = sub { $global ? ($_[0]->{'app'} || 'other') : $app };
	# every roll-up is asked of the database in its own grouped form - a life of
	# appointments is far too much to hold in memory just to count it
	my $activity = &subs::db_query(
		'select app, count(*) as count, sum(case when abs(duration) < 604800000 then abs(duration) else 0 end) as duration, min(cast(timestamp as integer)) as first, max(cast(timestamp as integer)) as last from appointments' . $filter . ' group by app',
		@args)->hashes;
	foreach my $row ( @{$activity} ) {
		$roll->{'activity'}->{$owner_of->($row)} = {
			count => $row->{'count'} + 0,
			duration => $row->{'duration'} + 0,
			first => $row->{'first'} + 0,
			last => $row->{'last'} + 0,
		};
	}
	my $bucket_rows = sub {
		my ($rows) = @_;
		my %out;
		foreach my $row ( @{$rows} ) {
			next unless defined $row->{'bucket'} && $row->{'bucket'} ne '';
			$out{$owner_of->($row)}->{$row->{'bucket'}} = $row->{'count'} + 0;
		}
		return \%out;
	};
	$roll->{'hours'} = $bucket_rows->(&subs::db_query(
		"select app, cast(strftime('%H', cast(timestamp as integer) / 1000, 'unixepoch', 'localtime') as integer) as bucket, count(*) as count from appointments" . $filter . ' group by app, bucket',
		@args)->hashes);
	$roll->{'weekdays'} = $bucket_rows->(&subs::db_query(
		"select app, cast(strftime('%w', cast(timestamp as integer) / 1000, 'unixepoch', 'localtime') as integer) as bucket, count(*) as count from appointments" . $filter . ' group by app, bucket',
		@args)->hashes);
	$roll->{'daily'} = $bucket_rows->(&subs::db_query(
		"select app, date(cast(timestamp as integer) / 1000, 'unixepoch', 'localtime') as bucket, count(*) as count from appointments" . $filter . ' group by app, bucket',
		@args)->hashes);
	# what kind of thing ran, not just how often: the categorical columns the
	# appointments carry - type, subtype, project, and the model and option names
	# (those two often hold JSON with a name inside). The database does the
	# counting, so a window that spans a whole life still returns only the
	# distinct combinations instead of every row in it.
	my $categorical = &subs::db_query(
		"select app, type, subtype, project, model, option, count(*) as count from appointments" . $filter . ' group by app, type, subtype, project, model, option',
		@args)->hashes;
	foreach my $row ( @{$categorical} ) {
		my $owner = $owner_of->($row);
		my $count = ($row->{'count'} || 0) + 0;
		foreach my $column ( qw/type subtype project/ ) {
			my $value = $row->{$column};
			next unless defined $value && $value ne '';
			$roll->{'kinds'}->{$owner}->{$column}->{$value} += $count;
		}
		foreach my $column ( qw/model option/ ) {
			my $value = $row->{$column};
			next unless defined $value && $value ne '';
			my $name;
			if ($value =~ /^\s*\{/) {
				my $data = eval { return decode_json($value) } || {};
				$name = ref $data eq 'HASH' ? $data->{'name'} : undef;
			}
			else { $name = $value; }
			next unless defined $name && $name ne '';
			$roll->{'kinds'}->{$owner}->{$column}->{substr($name, 0, 40)} += $count;
		}
	}
	# how much, not just how often: the quantity column is the amount logged (10 oz
	# of coffee, 0.8 tsp of soap). The database sums it per owner and unit, and the
	# busiest unit wins, so a stray label cannot skew the amount.
	my $qconj = length($filter) ? ' and ' : ' where ';
	my $quantities = &subs::db_query(
		"select app, unit, count(*) as n, sum(cast(quantity as real)) as total, avg(cast(quantity as real)) as avg from appointments" . $filter . $qconj . "quantity is not null and quantity != '' group by app, unit",
		@args)->hashes;
	foreach my $row ( @{$quantities} ) {
		my $n = ($row->{'n'} || 0) + 0;
		next unless $n;
		my $owner = $owner_of->($row);
		my $cur = $roll->{'quantity'}->{$owner};
		next if $cur && $cur->{'count'} >= $n;
		$roll->{'quantity'}->{$owner} = {
			count => $n,
			total => ($row->{'total'} || 0) + 0,
			average => ($row->{'avg'} || 0) + 0,
			unit => (defined $row->{'unit'} ? $row->{'unit'} : ''),
		};
	}
	return $roll;
}

# the busiest few values of each kind, so a window says what the activity was
# made of without opening the whole catalogue
sub evaluation_kinds {
	my ($kinds, $cap) = @_;
	$cap ||= 4;
	my $out = {};
	foreach my $column ( sort keys %{ $kinds || {} } ) {
		my $counts = $kinds->{$column};
		my @values = sort { $counts->{$b} <=> $counts->{$a} || $a cmp $b } keys %{$counts};
		splice(@values, $cap) if scalar @values > $cap;
		$out->{$column} = { map { $_ => $counts->{$_} } @values } if scalar @values;
	}
	return $out;
}

# Every appointment the house knows, by its unformatted name. Membership is a
# pos setting (every app carries one), which is broader than the built-in
# known_appts and so catches a project that is really an appointment too.
sub appointment_names {
	my $rows = &subs::db_query("select distinct app from settings where setting = ? and app is not null and app != ''", 'pos')->hashes;
	my %names;
	foreach my $r ( @{$rows} ) { $names{ $r->{'app'} } = 1; }
	return \%names;
}

# What one of a unit is in millilitres (or grams, near enough), when the unit is
# a measure the house uses; undef for a bare count ('each', '', an app name),
# which is a number of things, not an amount.
sub quantity_unit_ml {
	my ($unit) = @_;
	$unit = lc($unit // '');
	my %to_ml = (
		ml => 1, millilitre => 1, cc => 1, l => 1000, litre => 1000, liter => 1000,
		oz => 29.5735, floz => 29.5735, cup => 236.588, glass => 250, tbsp => 14.7868, tsp => 4.92892,
		g => 1, gram => 1, kg => 1000,
	);
	return $to_ml{$unit};
}

# What one logged unit of an appointment is: the app's quantity setting, read as
# an amount and a unit (coffee logs '10oz' a cup, soap '0.25'). A bare number is
# read as millilitres, the house's habit. Undef when the app records no serving.
sub quantity_serving {
	my ($str) = @_;
	return undef unless defined $str && $str =~ /\S/;
	my ($amount, $unit) = $str =~ /^\s*(-?[0-9]*\.?[0-9]+)\s*([A-Za-z]*)\s*$/;
	return undef unless defined $amount;
	$amount = $amount + 0;
	$unit = lc($unit || '');
	my $factor = length($unit) ? &subs::quantity_unit_ml($unit) : 1;
	return {
		raw => $str,
		amount => $amount,
		unit => ($unit || 'ml'),
		(defined $factor ? (ml => $amount * $factor) : ()),
	};
}

# The amount an app's window adds up to, spoken in one unit. A logged quantity is
# already an amount when its own unit is a measure; the app's serving is the
# default for the appointments that logged none, so every one is counted. All of
# it is put in millilitres and then back into the unit the app speaks.
sub evaluation_amount {
	my ($q, $occ, $serving, $days) = @_;
	# the window's quantity counts its entries under 'times' (how many carried a
	# quantity); 'count' is the raw rollup's own key, taken too so either shape works
	my $count = $q ? ($q->{'times'} // $q->{'count'}) : undef;
	return undef unless $count;
	$days = 1 unless $days && $days > 0;
	my $unit = $q->{'unit'} // '';
	my $q_factor = &subs::quantity_unit_ml($unit);
	my $has_serving = $serving && $serving->{'amount'} > 0 && defined $serving->{'ml'};
	my $logged = $q->{'total'};
	# appointments that carried no quantity of their own take the served default
	my $missing = ($occ && $occ > $count) ? $occ - $count : 0;
	my $ml;
	my $filled = 0;
	if (defined $q_factor) {
		$ml = $logged * $q_factor;
		if ($has_serving && $missing) { $ml += $missing * $serving->{'ml'}; $filled = 1; }
	}
	elsif ($has_serving) {
		$ml = ($logged + $missing) * $serving->{'ml'};
		$filled = 1 if $missing;
	}
	else {
		# a bare count with nothing to size it
		return { unit => 'units', total => &subs::briefing_number($logged), per_day => &subs::briefing_number($logged / $days), filled => 0 };
	}
	my ($out_unit, $out_factor);
	if (defined $q_factor) { $out_unit = $unit; $out_factor = $q_factor; }
	else { $out_unit = $serving->{'unit'}; $out_factor = $serving->{'ml'} / $serving->{'amount'}; }
	my $total = $out_factor ? $ml / $out_factor : $ml;
	return {
		unit => $out_unit,
		total => &subs::briefing_number($total),
		per_day => &subs::briefing_number($total / $days),
		ml_total => int($ml),
		ml_day => int($ml / $days),
		filled => $filled,
	};
}

# every app the relational window has tied to this one: the sc_ settings are
# uuid links, one list per construct, and 'all' means every app of it
sub relational_family {
	my ($app) = @_;
	my $settings = &subs::settings_grabber({ app => $app });
	my (@links, %seen);
	foreach my $key ( sort keys %{$settings} ) {
		next unless $key =~ /^sc_/;
		my $construct = $key;
		$construct =~ s/^sc_//;
		my $list = eval { return decode_json $settings->{$key} } || [];
		foreach my $entry ( @{$list} ) {
			my $linked;
			if ($entry eq 'all') {
				$linked = [ map { $_->{'app'} } @{ &subs::db_select('settings', undef, { setting => 'pos', value => $construct, device => &subs::device_setter() })->hashes } ];
			}
			else {
				my $ts = &subs::settings_grabber({ uuid => $entry, benign => 1 });
				$linked = $ts->{'app'} ? [ $ts->{'app'} ] : [];
			}
			foreach my $la ( @{$linked} ) {
				next if !$la || $la eq $app || $seen{$la}++;
				push @links, { app => $la, link => $construct };
			}
		}
	}
	return \@links;
}

# two apps' day counts, lined up over the union of their days
sub day_pair_series {
	my ($da, $db) = @_;
	my %seen;
	my @keys = sort grep { !$seen{$_}++ } ( keys %{$da}, keys %{$db} );
	my @xs = map { $da->{$_} || 0 } @keys;
	my @ys = map { $db->{$_} || 0 } @keys;
	return (\@xs, \@ys, \@keys);
}

# Pearson's r at a small spread of lags; the best fit wins, so a follower can
# be told from a leader. Positive lag means the second series trails the first
# by that many days. Undef when there is too little shared history, when the
# pair is almost all zero days, or when either line never moves
sub series_correlation {
	my ($xs, $ys) = @_;
	my $n = scalar @{$xs};
	return undef if $n < 14;
	my $active = grep { ($xs->[$_] || 0) + ($ys->[$_] || 0) > 0 } ( 0 .. $n - 1 );
	return undef if $active < 7;
	my $corr = sub {
		my ($xa, $ya) = @_;
		my $m = scalar @{$xa};
		return undef if $m < 14;
		my ($sx,$sy,$sxx,$syy,$sxy) = (0,0,0,0,0);
		foreach my $i ( 0 .. $m - 1 ) {
			$sx += $xa->[$i]; $sy += $ya->[$i];
			$sxx += $xa->[$i] ** 2; $syy += $ya->[$i] ** 2; $sxy += $xa->[$i] * $ya->[$i];
		}
		my $den = sqrt(($m * $sxx - $sx ** 2) * ($m * $syy - $sy ** 2));
		return undef unless $den;
		return ($m * $sxy - $sx * $sy) / $den;
	};
	my ($best, $best_lag);
	foreach my $lag ( -2 .. 2 ) {
		my ($xa, $ya) = ([], []);
		foreach my $i ( 0 .. $n - 1 ) {
			my $j = $i + $lag;
			next if $j < 0 || $j > $n - 1;
			push @{$xa}, $xs->[$i];
			push @{$ya}, $ys->[$j];
		}
		my $r = $corr->($xa, $ya);
		next unless defined $r;
		if (!defined $best || abs($r) > abs($best)) { $best = $r; $best_lag = $lag; }
	}
	return undef unless defined $best;
	return { r => sprintf('%.2f', $best), lag_days => $best_lag };
}

# every numeric measure the window's appointments logged, averaged per day:
# { app => { measure => { day => average } } }. A condition word is skipped;
# the measure's own reading time wins over the appointment's, so a humidity
# log lands on the day it was read
sub measure_series {
	my ($since) = @_;
	my $rows = &subs::db_query(
		"select app, timestamp, measures from appointments where measures is not null and measures != '' and cast(timestamp as integer) >= ?",
		$since);
	my $sth = $rows->sth;
	my %sum;
	while (my $row = $sth->fetchrow_arrayref) {
		my ($app, $ts, $jmeasures) = @{$row};
		my $list = eval { return decode_json($jmeasures) } || next;
		foreach my $entry ( @{$list} ) {
			next unless ref $entry eq 'HASH';
			my $when = $entry->{'ts'} || $ts;
			my @lt = localtime($when / 1000);
			my $day = sprintf('%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3]);
			foreach my $name ( keys %{$entry} ) {
				next if $name eq 'ts' || $name eq 'uuid';
				my $value = $entry->{$name};
				next unless defined $value && !ref $value && $value =~ /^-?[0-9]+(\.[0-9]+)?$/;
				$sum{$app}->{$name}->{$day}->{'sum'} += $value;
				$sum{$app}->{$name}->{$day}->{'n'}++;
			}
		}
	}
	$rows->finish;
	my %out;
	foreach my $app ( keys %sum ) {
		foreach my $name ( keys %{$sum{$app}} ) {
			foreach my $day ( keys %{$sum{$app}->{$name}} ) {
				my $cell = $sum{$app}->{$name}->{$day};
				$out{$app}->{$name}->{$day} = $cell->{'sum'} / $cell->{'n'};
			}
		}
	}
	return \%out;
}

# A number as a person writes it: two decimals at most, trailing zeros dropped,
# so a rate reads "3" not "3.00" and "0.03" stays "0.03". The briefing hands
# the model plain figures, and it should not parrot "3.00" back.
sub briefing_number {
	my ($n) = @_;
	return $n unless defined $n && $n =~ /^-?[0-9.]+$/;
	my $s = sprintf('%.2f', $n + 0);
	if ($s =~ /\./) { $s =~ s/0+$//; $s =~ s/\.$//; }
	$s = '' if $s eq '-0';
	return $s;
}

# The readings an app logged against its appointments, so the report can speak
# the numbers themselves and not only the correlations they make. A logged entry
# is a snapshot of every measure the app carried at that moment ({weight => 180,
# pressure => 120, ts, uuid}); the app's own app_measures setting names the unit
# and the range the reading is set to expect. Numeric readings are summarised
# (readings, average, min, max, the latest and when it was read); a text or
# select reading keeps its latest value and the spread of values seen.
# An app's appointments gathered into episodes: walked in order and merged
# wherever the gap from one to the next is small, each an { ts, stop }. A night
# broken by a waking is one episode; a single cup is one. The split gap is read
# from the app itself - a coffee (minutes long) splits from the next by a few
# minutes, a night (hours long) only by a long gap.
sub evaluation_episode_list {
	my ($app, $since) = @_;
	$since ||= &subs::rightNow() - 30 * 86400000;
	my $rows = &subs::db_query('select timestamp, stop_timestamp, duration, quantity, unit from appointments where app = ? and cast(timestamp as integer) >= ? order by timestamp', $app, $since)->hashes;
	my @ev;
	foreach my $r ( @{$rows} ) {
		my $ts = $r->{'timestamp'} + 0;
		my $stop = ($r->{'stop_timestamp'} && $r->{'stop_timestamp'} > $ts) ? $r->{'stop_timestamp'} + 0 : $ts + abs($r->{'duration'} || 0);
		push @ev, { ts => $ts, stop => $stop, q => ($r->{'quantity'} || 0) + 0, unit => $r->{'unit'} };
	}
	return { episodes => [], gap => 60000 } unless scalar @ev;
	my @durs = sort { $a <=> $b } map { $_->{'stop'} - $_->{'ts'} } @ev;
	my $gap = ($durs[int(@durs/2)] || 0) / 2;
	$gap = 60000 if $gap < 60000;
	$gap = 1800000 if $gap > 1800000;
	my @ep;
	foreach my $e ( @ev ) {
		if (@ep && $e->{'ts'} - $ep[-1]{'stop'} <= $gap) {
			$ep[-1]{'stop'} = $e->{'stop'} if $e->{'stop'} > $ep[-1]{'stop'};
			$ep[-1]{'q'} += $e->{'q'};
			$ep[-1]{'unit'} ||= $e->{'unit'};
		}
		else {
			push @ep, { ts => $e->{'ts'}, stop => $e->{'stop'}, q => $e->{'q'}, unit => $e->{'unit'} };
		}
	}
	return { episodes => \@ep, gap => $gap };
}

# An app's natural unit rather than a count per calendar day: a night, a cup, a
# session, a walk. Reports how many episodes there were and how many an active
# day, the median and longest, the hour each began at (so a sleep reads as a
# bedtime, a coffee as a time of day) and, where the app logs a quantity, the
# amount an episode, a day and in all.
sub evaluation_episodes {
	my ($app, $since) = @_;
	return {} unless $app && $app ne '__president';
	my $list = &subs::evaluation_episode_list($app, $since);
	my @ep = @{ $list->{'episodes'} };
	return {} unless scalar @ep;
	my $gap = $list->{'gap'};
	my @edur = sort { $a <=> $b } map { $_->{'stop'} - $_->{'ts'} } @ep;
	my (%onset, %active);
	foreach my $ep ( @ep ) {
		my @lt = localtime($ep->{'ts'} / 1000);
		$onset{$lt[2]}++;
		$active{ sprintf('%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3]) } = 1;
	}
	my $days = scalar keys %active;
	my $qtotal = 0; $qtotal += $_->{'q'} for @ep;
	my ($unit) = map { $_->{'unit'} } grep { $_->{'unit'} } @ep;
	return {
		episodes => scalar @ep,
		days => $days,
		per_day => $days ? sprintf('%.2f', scalar(@ep) / $days) : 0,
		gap_minutes => int($gap / 60000),
		median_duration => &subs::duration_sayer(($edur[int(@edur/2)] || 0) / 1000),
		longest_duration => &subs::duration_sayer(($edur[-1] || 0) / 1000),
		onset_hours => { map { $_ => $onset{$_} } sort { $a <=> $b } keys %onset },
		($qtotal ? (
			quantity_total => sprintf('%.1f', $qtotal),
			quantity_per_episode => sprintf('%.1f', $qtotal / scalar @ep),
			quantity_per_day => $days ? sprintf('%.1f', $qtotal / $days) : 0,
			($unit ? (unit => $unit) : ()),
		) : ()),
	};
}

# The typical gap from an episode of one app to the nearest episode of another -
# the last coffee before a night's sleep, the walk before a meal - so a
# relationship carries a time. Works on episode onsets, so a night is one onset
# and not each record, and the median is signed (negative when the other tends
# to come first).
sub evaluation_episode_lag {
	my ($app, $other, $since) = @_;
	return {} unless $app && $other && $other ne $app;
	my $mine = &subs::evaluation_episode_list($app, $since);
	my $theirs = &subs::evaluation_episode_list($other, $since);
	my @A = map { $_->{'ts'} } @{ $mine->{'episodes'} };
	my @B = sort { $a <=> $b } map { $_->{'ts'} } @{ $theirs->{'episodes'} };
	return {} unless @A && @B;
	my (@gaps, $before, $after);
	foreach my $t ( @A ) {
		my ($bestd);
		foreach my $u ( @B ) {
			my $d = $u - $t;
			$bestd = $d if !defined $bestd || abs($d) < abs($bestd);
		}
		push @gaps, $bestd;
		if ($bestd < 0) { $before++ } else { $after++ }
	}
	my @s = sort { $a <=> $b } @gaps;
	return {
		app => $other,
		n => scalar @A,
		median_minutes => sprintf('%.0f', $s[int(@s/2)] / 60000),
		before => $before || 0,
		after => $after || 0,
	};
}

# What conditions the app runs under: every numeric measure any app logged is
# read against the app's own episodes. Two contrasts are weighed - the reading in
# the windows around the episodes against its value everywhere else (around), and
# its mean on the days the app ran against the days it did not (day) - and both
# are handed over, with confidence saying which stand (both, day or around),
# because a daily thing like weather is honest at the day while a
# moment-to-moment thing is honest around the event, and a condition that only
# leans around may just be the hour of the clock. A walk in the cold, an eczema
# day in the damp, steps that climb with a walk: the measure's app is what
# carries the condition, so a weather app's temperature stands beside the apps.
sub evaluation_conditions {
	my ($app, $since, $cap) = @_;
	return [] unless $app && $app ne '__president';
	$since ||= &subs::rightNow() - 60 * 86400000;
	$cap ||= 8;
	my $list = &subs::evaluation_episode_list($app, $since);
	my @ep = @{ $list->{'episodes'} };
	return [] unless scalar @ep >= 3;
	my $delta = 2 * 3600000;
	my %active;
	foreach my $ep ( @ep ) {
		my @lt = localtime($ep->{'ts'} / 1000);
		$active{ sprintf('%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3]) } = 1;
	}
	my $rows = &subs::db_query("select app, timestamp, measures from appointments where measures is not null and measures != '' and cast(timestamp as integer) >= ?", $since);
	my $sth = $rows->sth;
	my %series;
	while (my $row = $sth->fetchrow_arrayref) {
		my ($mapp, $ts, $j) = @{$row};
		next unless $j;
		my $ms = eval { decode_json $j } || next;
		my @lt = localtime($ts / 1000);
		my $day = sprintf('%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3]);
		foreach my $m ( @{$ms} ) {
			foreach my $k ( keys %{$m} ) {
				next if $k eq 'uuid' || $k eq 'ts';
				my $v = $m->{$k};
				next unless defined $v && $v =~ /^-?[0-9]+(?:\.[0-9]+)?$/;
				my $s = ($series{$mapp . "\t" . $k} ||= { app => $mapp, name => $k, pts => [], days => {} });
				push @{$s->{'pts'}}, [ $ts + 0, $v + 0 ];
				push @{$s->{'days'}->{$day}}, $v + 0;
			}
		}
	}
	my @out;
	# a two-group z: the two means over the standard error of their difference, so
	# a real shift stands out from the day-to-day spread rather than being drowned
	# by it
	my $two_z = sub {
		my ($on, $off) = @_;
		my $n1 = scalar @{$on}; my $n2 = scalar @{$off};
		return undef if $n1 < 4 || $n2 < 4;
		my ($m1, $m2) = (0, 0);
		$m1 += $_ for @{$on}; $m1 /= $n1;
		$m2 += $_ for @{$off}; $m2 /= $n2;
		my ($s1, $s2) = (0, 0);
		$s1 += ($_ - $m1) ** 2 for @{$on};
		$s2 += ($_ - $m2) ** 2 for @{$off};
		$s1 = sqrt($s1 / $n1); $s2 = sqrt($s2 / $n2);
		my $se = sqrt(($s1 ** 2) / $n1 + ($s2 ** 2) / $n2);
		return undef unless $se > 0;
		return { on => $m1, off => $m2, z => ($m1 - $m2) / $se, n => $n1, ratio => ($m2 ? $m1 / $m2 : undef) };
	};
	foreach my $key ( keys %series ) {
		my $s = $series{$key};
		my @pts = sort { $a->[0] <=> $b->[0] } @{ $s->{'pts'} };
		my (@near, @far);
		my $pi = 0;
		foreach my $p ( @pts ) {
			while ($pi < @ep && $ep[$pi]{'stop'} + $delta < $p->[0]) { $pi++ }
			if ($pi < @ep && $p->[0] >= $ep[$pi]{'ts'} - $delta) { push @near, $p->[1] } else { push @far, $p->[1] }
		}
		my (@on_day, @off_day);
		foreach my $d ( keys %{ $s->{'days'} } ) {
			my @v = @{ $s->{'days'}->{$d} };
			my $m = 0; $m += $_ for @v; $m /= @v;
			push @{ $active{$d} ? \@on_day : \@off_day }, $m;
		}
		my $around = $two_z->(\@near, \@far);
		my $day = $two_z->(\@on_day, \@off_day);
		# a contrast stands on its own only if it is both sure (z) and material (the
		# ratio actually moved): a large series makes a 1% shift look certain, so a
		# ratio that truly moved is asked as well
		my $stands = sub {
			my ($c) = @_;
			return 0 unless $c && defined $c->{'ratio'};
			return abs($c->{'z'}) >= 2 && abs($c->{'ratio'} - 1) >= 0.15 ? 1 : 0;
		};
		my $a_ok = $stands->($around);
		my $d_ok = $stands->($day);
		next unless $a_ok || $d_ok;
		my ($best) = sort { abs($b->{'z'}) <=> abs($a->{'z'}) } grep { $stands->($_) } ($around, $day);
		my $dir = sub { $_[0]->{'on'} > $_[0]->{'off'} ? 'higher' : 'lower' };
		# The day contrast weighs whole days against whole days, so the hour of the
		# clock cancels; the around contrast weighs the windows around the app, so a
		# thing that only varies with the hour - weather does - can show there and
		# nowhere else. Both readings ride along and the label says which stand: both
		# agreeing is the honest condition, a day that stands alone is the same, an
		# around that stands alone may be the time of day wearing the app's name.
		my $confidence = ($a_ok && $d_ok && $dir->($around) eq $dir->($day)) ? 'both'
			: $d_ok ? 'day' : 'around';
		push @out, {
			app => $s->{'app'},
			measure => $s->{'name'},
			kind => $best->{'kind'},
			on => sprintf('%.2f', $best->{'on'}),
			off => sprintf('%.2f', $best->{'off'}),
			(defined $best->{'ratio'} ? (ratio => sprintf('%.2f', $best->{'ratio'})) : ()),
			z => sprintf('%.1f', $best->{'z'}),
			n => $best->{'n'},
			direction => $dir->($best),
			confidence => $confidence,
			(defined $around ? (around => {
				(defined $around->{'ratio'} ? (ratio => sprintf('%.2f', $around->{'ratio'})) : ()),
				z => sprintf('%.1f', $around->{'z'}),
				n => $around->{'n'},
				direction => $dir->($around),
			}) : ()),
			(defined $day ? (day => {
				(defined $day->{'ratio'} ? (ratio => sprintf('%.2f', $day->{'ratio'})) : ()),
				z => sprintf('%.1f', $day->{'z'}),
				n => $day->{'n'},
				direction => $dir->($day),
			}) : ()),
		};
	}
	@out = sort { abs($b->{'z'}) <=> abs($a->{'z'}) || $b->{'n'} <=> $a->{'n'} } @out;
	splice(@out, $cap) if scalar @out > $cap;
	return \@out;
}

# Speed is a reading of movement, and an app is a movement only when its own
# construct (its POS) is action. A MAB is a "might also be", and every start or
# stop takes a GPS fix and gets a derived speed whether or not the app moved -
# programming is a service that might also be an action, and its speed came from
# the fix rather than from the work. So a MAB alone does not make speed relevant.
sub evaluation_speed_app {
	my ($app) = @_;
	return 0 unless $app && $app ne '__president';
	my $settings = &subs::settings_grabber({ app => $app, benign => 1 });
	return (($settings->{'pos'} // '') eq 'action') ? 1 : 0;
}

sub evaluation_measures {
	my ($app, $since, $defs) = @_;
	return {} unless $app && $app ne '__president';
	$defs ||= eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'app_measures' }) } || {};
	my $rows = &subs::db_query(
		"select measures from appointments where app = ? and measures is not null and measures != '' and cast(timestamp as integer) >= ?",
		$app, ($since || 0));
	my $sth = $rows->sth;
	my (%num, %txt);
	while (my $row = $sth->fetchrow_arrayref) {
		my ($jmeasures) = @{$row};
		my $list = eval { return decode_json($jmeasures) } || next;
		foreach my $entry ( @{$list} ) {
			next unless ref $entry eq 'HASH';
			my $when = 0 + ($entry->{'ts'} || 0);
			foreach my $name ( keys %{$entry} ) {
				next if $name eq 'ts' || $name eq 'uuid';
				my $value = $entry->{$name};
				next unless defined $value && !ref $value && $value =~ /\S/;
				if ($value =~ /^-?[0-9]+(?:\.[0-9]+)?$/) {
					my $a = $num{$name} ||= { count => 0, sum => 0, min => undef, max => undef, latest => undef, latest_at => 0 };
					$a->{'count'}++;
					$a->{'sum'} += $value;
					$a->{'min'} = $value if !defined $a->{'min'} || $value < $a->{'min'};
					$a->{'max'} = $value if !defined $a->{'max'} || $value > $a->{'max'};
					if (!defined $a->{'latest'} || $when >= $a->{'latest_at'}) {
						$a->{'latest'} = $value + 0;
						$a->{'latest_at'} = $when;
					}
				}
				else {
					my $t = $txt{$name} ||= { count => 0, latest => undef, latest_at => 0, values => {} };
					$t->{'count'}++;
					$t->{'values'}->{$value}++;
					if (!defined $t->{'latest'} || $when >= $t->{'latest_at'}) {
						$t->{'latest'} = $value;
						$t->{'latest_at'} = $when;
					}
				}
			}
		}
	}
	$rows->finish;
	my $out = {};
	foreach my $name ( sort keys %num ) {
		my $a = $num{$name};
		my $e = {
			readings => $a->{'count'},
			average => &subs::briefing_number($a->{'sum'} / $a->{'count'}),
			min => &subs::briefing_number($a->{'min'}),
			max => &subs::briefing_number($a->{'max'}),
			latest => &subs::briefing_number($a->{'latest'}),
		};
		if ($a->{'latest_at'}) {
			my @lt = localtime($a->{'latest_at'} / 1000);
			$e->{'latest_at'} = sprintf('%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3]);
		}
		my $def = $defs->{$name};
		if (ref $def eq 'HASH') {
			$e->{'unit'} = $def->{'unit'} if defined $def->{'unit'} && $def->{'unit'} =~ /\S/;
			$e->{'range'} = ($def->{'min'} // '') . ' to ' . ($def->{'max'} // '') if defined $def->{'min'} || defined $def->{'max'};
		}
		$out->{$name} = $e;
	}
	foreach my $name ( sort keys %txt ) {
		my $t = $txt{$name};
		my @vals = sort { $t->{'values'}->{$b} <=> $t->{'values'}->{$a} || $a cmp $b } keys %{ $t->{'values'} };
		splice(@vals, 5) if scalar @vals > 5;
		$out->{$name} = {
			readings => $t->{'count'},
			latest => &subs::format_name($t->{'latest'}),
			values => { map { &subs::format_name($_) => $t->{'values'}->{$_} } @vals },
		};
	}
	return $out;
}

# Which device was actually with the person over a set of fixes. Every phone,
# tablet and watch writes its own continent rows, so one appointment can hold two
# tracks: the tablet left in the house and the phone that went for the walk. The
# device that covered the most ground is the one that went somewhere. A step
# shorter than the jitter floor is a stationary device shuffling, so it is not
# counted; steps are measured from the last accepted fix, so a walk whose fixes
# are spaced far apart still adds up. Ties fall to the device with more fixes,
# then to its signatorial, so the answer does not change between reads.
#
#   my $carrier = &subs::carrier_device($fixes);
#   # { signatorial, metres, fixes, devices } or undef
sub carrier_device {
	my ($fixes) = @_;
	return undef unless ref $fixes;
	# db_query(...)->hashes hands back a Mojo::Collection, a caller's own list is a
	# plain arrayref; the guard must take both, or a route passes rows and gets
	# nothing back.
	my @list = ref $fixes eq 'ARRAY' ? @{$fixes} : eval { @{ $fixes->to_array } };
	return undef unless scalar @list;
	my $jitter = 25; # metres: below this a device is standing still
	my (%metres, %count, %anchor);
	foreach my $fix ( sort { ($a->{'timestamp'} || 0) <=> ($b->{'timestamp'} || 0) } @list ) {
		next unless ref $fix eq 'HASH';
		my ($lat, $lon) = ( $fix->{'latitude'}, $fix->{'longitude'} );
		next unless defined $lat && defined $lon && length $lat && length $lon
			&& $lat =~ /^-?[0-9]/ && $lon =~ /^-?[0-9]/;
		my $dev = defined $fix->{'signatorial'} ? $fix->{'signatorial'} : '';
		$count{$dev}++;
		my @here = ( deg2rad($lon), deg2rad(90 - $lat) );
		if ( $anchor{$dev} ) {
			my $step = great_circle_distance( @{ $anchor{$dev} }, @here, $gb::planet_radius ) * 1000;
			next if $step < $jitter;
			$metres{$dev} += $step;
		}
		$anchor{$dev} = \@here;
	}
	return undef unless scalar keys %count;
	my ($winner) = sort {
		($metres{$b} || 0) <=> ($metres{$a} || 0)
			|| $count{$b} <=> $count{$a}
			|| $a cmp $b
	} keys %count;
	return {
		signatorial => $winner,
		metres => int( ($metres{$winner} || 0) + 0.5 ),
		fixes => $count{$winner},
		devices => scalar( keys %count ),
	};
}

# A device's signatorial as the name the house knows it by: the first label of
# its house address (phone, tablet, laptop), then a peer's hostname, and this
# machine's own name when neither is known. One place, so a carrier line, the
# movement picker and anything else name a machine the same way.
sub device_labels {
	my %names;
	my $hosts = &device_hosts();
	foreach my $sig ( keys %{$hosts} ) {
		my ($label) = split /\./, ($hosts->{$sig} || '');
		$names{$sig} = &format_name($label) if defined $label && length $label;
	}
	foreach my $d ( @{ &remote_machine_lister() } ) {
		my $sig = $d->{'signatorial'} || '';
		my $host = $d->{'hostname'} || '';
		next if $names{$sig};
		next unless length $sig && length $host && $host !~ /^(?:me|localhost)$/i;
		$names{$sig} = &format_name($host);
	}
	my $mine = &signatorial_designer();
	$names{$mine} ||= &setting_grabber({ app => 'me', setting => 'my_name' }) || 'this device';
	return \%names;
}

1;
