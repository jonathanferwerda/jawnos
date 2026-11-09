package subs;

# Budget half of the domain layer: functions subroutines.pl calls that used
# to live in Manager.pl. Same package (subs) so every call site and the
# Manager:: aliases keep working; the Loader in lib/JawnOS/Domain/Loader.pm
# requires this file on the first call that needs it.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';

use Mojo::JSON qw(decode_json encode_json);
use Time::Local qw(timegm timelocal);

# File-scope state owned by subroutines.pl, in this same package.
our $config;
our $device;
our $log;
our $logfile;

sub budget_calculator($data) {
	my $app = $data->{'app'};

	my $circumstance = $data->{'circumstance'};
	# A measure is any circumstance that is not one of the base budget modes,
	# worked out once with a key test that never autovivifies a measure into the
	# modes (which would make this very test, and later ones, read it wrong).
	my $is_measure = ( scalar grep { $_ eq $circumstance } keys %{$gb::budget_modes} ) == 0;
	my $value = $data->{'value'};
	my $scope = $data->{'scope'};
	# the window the reading is for: the caller says when it is one of the blocks
	# before or after now, so a pace is only read off the one now running
	my $ts = $data->{'ts'} || 'this';
	my $settings = $data->{'settings'} || &subs::settings_grabber({ app => $app });
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $returner = { app => $app, scope_name => &subs::timespan_widener($scope), value => $value };
	my $budget = $data->{'budget'};
	my $server_time = &subs::rightNow();
	$budget = $data->{'budget'} || &subs::setting_grabber({ 'app' => $app, setting => 'budget' }) unless $data->{'budget'} =~ /[0-9]/gi;
	my @budgets = split ',', $budget;
	foreach my $b ( @budgets ) {
		$returner->{'app'} = $app;
		$returner->{'budget'} = $b;
		# A leading "<=" or ">=" says which way the goal runs: under is good (a
		# ceiling, like a weight to hold at or below) or over is good (a floor, like
		# steps to reach). Nothing, and a bare number, is a floor.
		my $direction = 'floor';
		if ($b =~ s/^<=//) { $direction = 'ceiling'; }
		elsif ($b =~ s/^>=//) { $direction = 'floor'; }
		$returner->{'direction'} = $direction;
		my @bud = split '/', $b;
		next unless $bud[-1];
		# No "/scope" is a fixed level, not a rate: a weight sits at a target, it
		# does not accumulate, so it is read against the column's own window and is
		# never prorated (the pace is what made a 160 lb budget project 756 lb).
		my $fixed = scalar(@bud) == 1 ? 1 : 0;
		$returner->{'fixed'} = $fixed;
		if ($fixed) {
			# A fixed entry ("180weight") has no "/scope"; the only scope it can
			# honour is the caller's, and only when it names a time span. The old
			# test accepted any number+letters, so `180weight` became the window
			# `weight`; timespan_widener then stripped the digits and father_time
			# asked time_span for 'weight', which dies and killed every pull after
			# its merge.
			my $window = 'month';
			if ($scope && $scope =~ /^[0-9]*[a-zA-Z]+$/ && &subs::time_span_length($scope)) {
				$window = $scope;
			}
			$window = 1 . $window unless $window =~ /^[0-9]/;
			$returner->{'scope_name'} = &subs::timespan_widener($window);
			$returner->{'duration'} = &subs::time_abbrev_translator($window, $server_time);
			$returner->{'scope'} = $returner->{'duration'};
		}
		else {
			$bud[-1] = 1 . $bud[-1] unless $bud[-1] =~ /[0-9]/;
			# time_span_length knows the word spans; an abbreviated scope ("1w",
			# "3d", "1M") is widened to its word with its count kept first, so a
			# weekly budget is not silently read as a month. A scope that still
			# does not resolve must not reach time_span either.
			unless (&subs::time_span_length($bud[-1])) {
				my $count = $bud[-1];
				$count =~ s/[^0-9]//g;
				$count = 1 unless length $count;
				my $widened = $count . &subs::timespan_widener($bud[-1]);
				$bud[-1] = &subs::time_span_length($widened) ? $widened : '1month';
			}
			$returner->{'scope_name'} = &subs::timespan_widener($bud[-1]);
			$returner->{'duration'} = &subs::time_abbrev_translator($bud[-1],&subs::rightNow());
			# The scope is the column the caller read, not the budget's own period:
			# the value handed in is that column's total, so the target and the actual
			# are held per millisecond of that column. A bare word ("week") needs its
			# count before the translator sees it.
			my $caller_span = $scope ? (($scope =~ /[0-9]/) ? $scope : 1 . $scope) : '';
			unless ($scope) {
				$returner->{'scope'} = $returner->{'duration'} ;
			}
			else {
				$returner->{'scope'} = &subs::time_abbrev_translator($caller_span, &subs::rightNow()) || $returner->{'duration'};
			}
		}
		# A fixed quantity budget is a level to keep on hand, not a rate of the
		# appointment stream (the scoped form reads that stream): read the warehouse's
		# signed stock for the item, so its light says whether the shelf holds what it
		# should.
		my $handled;
		if ($circumstance eq 'quantity' && $fixed) {
			$value = &subs::warehouse_on_hand($app, $settings);
			$returner->{'value'} = $value;
			$handled = 1;
		}
		unless ($value || $handled) {
			my ($db) = &subs::database_grabber();
			my $appts = $data->{'appts'};
			# A duration is read over the budget's own window even when the caller
			# passed the appointments, so a session that crossed the window's edge
			# offers only the time spent inside it.
			my ($window_bt, $window_end);
			if (!$appts || $circumstance eq 'duration') {
				my $ft_data = {
					scope => $returner->{'scope_name'},
					ts => 'this',
					lock => $settings->{'s_lock'},
					timestamp => $timestamp
				};
				($window_bt, $window_end) = &father_time($ft_data);
			}
			unless ($appts) {
				my @params = ( $app, $window_end );
				my $query = 'select * from appointments where app = ? and timestamp < ? ';
				if ($circumstance eq 'duration') {
					# a session overlaps this window when it starts before the window
					# ends and stops after it begins; a running session has no stored
					# duration, so it is read to now and always overlaps a past window.
					# The ends-at test is a number against the window bound: the bound
					# must be cast, or DBD::SQLite binds it as text and SQLite ranks a
					# number below text, so every session that began before the window
					# and ran into it was dropped.
					$query .= "and (timestamp >= ? or type in ('start','record') or (cast(timestamp as integer) + abs(cast(coalesce(duration,0) as real))) > cast(? as integer)) ";
					push @params, $window_bt, $window_bt;
				}
				else {
					$query .= 'and timestamp >= ? ';
					push @params, $window_bt;
				}

				if ($settings->{'s_movement'}) {
					my $bail = 0;
					unless ($settings->{'sss_movement'}) {
						$settings->{'sss_movement'} = eval { return decode_json $settings->{'s_movement'} } || [];
					}
					$bail = 1 if grep { $_ eq 'all' } @{$settings->{'sss_movement'}};
					if ($bail == 0) {
						if (scalar @{$settings->{'sss_movement'}} > 0 ) { $query .= 'and ( '; }
						my $first_movement = 1;
						foreach my $sm ( @{$settings->{'sss_movement'}} ) {
							$query .= $first_movement ? 'type = ? ' : ' or type = ? ';
							$first_movement = 0;
							push @params, $sm;
						}
						if (scalar @{$settings->{'sss_movement'}} > 0 ) { $query .= ' ) '; }
					}
				}
				$query .= ' order by timestamp DESC';
				$appts = &subs::db_query($query, @params)->hashes;
				# a duration list is not reused for the next budget entry, since that
				# entry may name a different window; a caller's own list is left alone
				$data->{'appts'} = $appts unless $circumstance eq 'duration';
			}

			my ($m_sum, $m_count) = (0, 0);
			foreach my $appt ( @{$appts} ) {
				if ($circumstance eq 'duration') {
					if ($appt->{'type'} eq 'start' || $appt->{'type'} eq 'record') {
						$appt->{'duration'} = $server_time - $appt->{'timestamp'};
					}
					my $spent = abs($appt->{'duration'} || 0);
					if (defined $window_bt && defined $window_end) {
						$spent = &appointment_overlap($appt, $window_bt, $window_end);
					}
					$value += $spent;
				}
				elsif ($circumstance eq 'occurences') {
					$value += 1;
				}
				elsif ($circumstance eq 'total') {
					# the block above is only entered when no value was passed in, so
					# there is nothing to guard against here: starting from zero, every
					# row's total is added, the way the display reads the column
					$value += abs( $appt->{'total'} || 0 );
				}
				elsif ($circumstance eq 'quantity') {
					# the stream the app's movement filter names - beer's poured amount,
					# not its purchases - read as a magnitude, the way a total budget
					# reads the money
					$value += abs( $appt->{'quantity'} || 0 );
				}
				else {
					# a measure: sum, or average, it across the window's appointments -
					# the measure decides (steps summed, weight averaged), so its
					# budget reads right whatever the display is showing.
					next unless $appt->{'measures'};
					unless ($appt->{'measured'}) {
						$appt->{'measures'} = eval { return decode_json $appt->{'measures'} } || [];
						$appt->{'measured'} = 'yes';
					}
					foreach my $m ( @{$appt->{'measures'}} ) {
						next unless defined $m->{$circumstance};
						$m_sum += $m->{$circumstance};
						$m_count++;
					}
				}
			}
			# a measure is not a base mode: its value is the summed or averaged
			# measure, per the measure's own calc
			if ($is_measure) {
				# a fixed level (no scope) is a level, so it reads as an average whatever
				# the measure's own calc is; a rate reads with the measure's calc
				my $mcalc = $fixed ? 'average' : &measure_calc_for($app, $circumstance, $settings->{'s_calc'});
				$value = ( $mcalc eq 'average' && $m_count ) ? ($m_sum / $m_count) : $m_sum;
			}
			$value = 0 if scalar @{$appts} == 0;
			$returner->{'value'} = $value;
		}
		if ($bud[0] =~ /^\$/gi) {
			my $bu = $bud[0];
			$bu =~ s/\$//gi;
			$returner->{'budgets'}->{'total'} = $b;
			if ($circumstance eq 'total') {
				$returner->{'circumstance'} = 'total';
				$returner->{'budgeted'} = abs $bu;
				$returner->{'formatted_value'} = abs $value;
				last;
			}
		}
		elsif ($bud[0] =~ /[a-zA-Z]/gi) {

			if ($circumstance eq 'duration') {
				$returner->{'budgets'}->{'duration'} = $b;
				$returner->{'circumstance'} = 'duration';
				$bud[0] = 1 . $bud[0] unless $bud[0] =~ /[0-9]/;
				$returner->{'budgeted'} = &subs::time_abbrev_translator($bud[0],&subs::rightNow());
				if ($value != 0) {
					$returner->{'formatted_value'} = &subs::duration_sayer($value / 1000);
				}
				else {
					$returner->{'formatted_value'} = 0;
				}
				last;
			}
			elsif ($is_measure) {
				$returner->{'budget_name'} = $bud[0];
				$returner->{'budget_name'} =~ s/[0-9.]//gi;
				next unless $returner->{'budget_name'} eq $circumstance;
				$returner->{'budgeted'} = $bud[0];
				$returner->{'budgets'}->{$circumstance} = $b;
				$returner->{'circumstance'} = $circumstance;

				$returner->{'budgeted'} =~ s/[^0-9.]//gi;
				$returner->{'formatted_value'} = sprintf("%.3f", $value) . $circumstance;
				last;
			}
			elsif ($circumstance eq 'quantity') {
				# a quantity budget names itself the way a measure does
				# ("3.400quantity/week"), so a bare number stays an occurences budget
				my $quantity_name = $bud[0];
				$quantity_name =~ s/[^a-zA-Z]//gi;
				next unless $quantity_name eq 'quantity';
				$returner->{'budgets'}->{'quantity'} = $b;
				$returner->{'circumstance'} = 'quantity';
				$returner->{'budgeted'} = $bud[0];
				$returner->{'budgeted'} =~ s/[^0-9.]//gi;
				$returner->{'formatted_value'} = sprintf("%.3f", $value) . $circumstance;
				last;
			}
		}
		else {
			$returner->{'budgets'}->{'occurences'} = $b;

			if ($circumstance eq 'occurences') {
				$returner->{'circumstance'} = 'occurences';
				$returner->{'budgeted'} = $bud[0];
				$returner->{'formatted_value'} = abs $value;
				last;
			}
		}
	}

	if ($returner->{'budget'} && $returner->{'budgeted'}) {
		my $nominal_scope = $returner->{'scope'};
		my $same_width = ($returner->{'duration'} eq $nominal_scope) ? 1 : 0;
		# A locked day or week can be 25 hours or 169 hours long when the clocks
		# change. The value is already read over the real window; the rate is per
		# the nominal period, so the target for this column is that rate times the
		# real window. Only a duration: a count, a sum or a measure is not a rate of
		# time and must not grow with an hour the clock gained.
		my $actual_scope;
		if ($circumstance eq 'duration' && !$returner->{'fixed'} && ($settings->{'s_lock'} || '') eq 'on') {
			my $caller_scope = $scope || $returner->{'scope_name'};
			my $unit = &subs::timespan_widener($caller_scope) || '';
			if ($unit eq 'day' || $unit eq 'week') {
				my ($cb, $ce) = &father_time({
					scope => $caller_scope,
					ts => $ts,
					lock => $settings->{'s_lock'},
					timestamp => $timestamp
				});
				$actual_scope = $ce - $cb if defined $ce && defined $cb && $ce > $cb;
			}
		}
		if ($same_width && $returner->{'circumstance'} eq $circumstance) {
			$returner->{'is_scope'} = 'yes';
		}

		$returner->{'expected'} = sprintf("%.19f",$returner->{'budgeted'} / $returner->{'duration'});
		if ($circumstance eq 'duration') {
			# the own period wears the real window; another column keeps the nominal
			# rate as its label, while its threshold below is scaled to the column
			my $display_span = $same_width ? ($actual_scope || $returner->{'duration'}) : $returner->{'duration'};
			$returner->{'budgeted_display_ms'} = $returner->{'expected'} * $display_span;
			$returner->{'formatted_budgeted'} = &subs::duration_sayer($returner->{'expected'} * $display_span / 1000) . '/' . $returner->{'scope_name'};
		}
		else {
			$returner->{'formatted_budgeted'} = sprintf("%.3f", $returner->{'expected'} * $returner->{'scope'}) . ($is_measure ? $circumstance : '') . '/' . $returner->{'scope_name'};
		}
		if ($actual_scope) { $returner->{'scope'} = $actual_scope; }
		$returner->{'actual'} = sprintf("%.19f", $returner->{'value'} / $returner->{'scope'});
		$returner->{'threshold'} = $returner->{'expected'} * $returner->{'scope'};
		$returner->{'eval'} = $returner->{'actual'} - $returner->{'expected'};
		$returner->{'timestamp'} = $timestamp;
		if ($scope && !$returner->{'fixed'} && !$same_width && $returner->{'circumstance'} eq $circumstance) {
			# The caller read a column of another width. The reading is still held
			# against that column - the expected and the actual are rates per
			# millisecond, so they compare across windows - but it is not the
			# budget's own period, so the panel must not cache it as one.
			$returner->{'is_scope'} = 'no';
		}
		# A budget locked to the calendar is read against a period still running:
		# on Monday a week holds a seventh of its value, so holding that part against
		# the whole week's target would call an on-pace start a collapse and leave
		# nothing meaningful to read until the week is done. The pace is read
		# instead - the part of the period the moment stands at - and the target is
		# prorated by that same part, so being on track means the value has reached
		# its share of the period so far, and the projection carries the pace to the
		# period's end. An unlocked window rolls a whole period back from now, so it
		# is already run and its pace is 1, as is any block before or after now.
		# Every column is read this way, not only the one the budget is set to: a
		# weekly budget graphed over the month is still a part-run month, and its
		# column reads the same way (the target was scaled to the column above).
		#
		# The first stretch of a period carries no target, since so little is due that
		# a single blip reads as far ahead of pace, and that stretch is often spent
		# asleep or otherwise away from it. The budget is spread over what is left: a
		# day's first two fifths are the night (so its target only starts around nine
		# in the morning), an hour's first quarter, and the longer clocks their first
		# tenth. The projection keeps the exact elapsed, so it still reads the whole
		# period rather than only the part not slept through.
		my %pace_floor = ( hour => 0.25, day => 0.4, week => 0.1, month => 0.1, year => 0.1 );
		my $unit = $scope ? &subs::timespan_widener($scope) : $returner->{'scope_name'};
		my $elapsed = 1;
		if ($ts eq 'this' && ($settings->{'s_lock'} || '') eq 'on' && $unit =~ /^(?:hour|day|week|month|year)$/) {
			(undef, undef, $elapsed) = &subs::period_bounds($unit, $timestamp);
		}
		# a fixed level is not a period being run: it is not prorated, and its pace
		# is not carried anywhere
		$elapsed = 1 if $returner->{'fixed'};
		my $floor = $pace_floor{$unit} // 0.1;
		my $early = ($elapsed > 0 && $elapsed <= $floor) ? 1 : 0;
		my $pace_elapsed = $early ? 0 : (($elapsed - $floor) / (1 - $floor));
		$pace_elapsed = 0 if $pace_elapsed < 0;
		$pace_elapsed = 1 if $pace_elapsed > 1;
		# the whole target the column's value is held against - already scaled to the
		# column's own period when the budget is set to a different one
		my $full_target = $returner->{'expected'} * $returner->{'scope'};
		$returner->{'elapsed'} = $elapsed;
		$returner->{'early'} = $early;
		$returner->{'pace_floor'} = $floor;
		$returner->{'progress'} = sprintf('%.0f', $elapsed * 100);
		$returner->{'on_target'} = sprintf('%.19f', $full_target * $pace_elapsed);
		$returner->{'on_track'} = ($returner->{'value'} >= $returner->{'on_target'}) ? 'yes' : 'no';
		$returner->{'projected'} = $elapsed > 0 ? sprintf('%.19f', $returner->{'value'} / $elapsed) : $returner->{'value'};
		my $pace_format = sub {
			my $n = shift;
			return '-' unless defined $n;
			return &subs::duration_sayer($n / 1000) if $circumstance eq 'duration';
			return &subs::price_formatter($n) if $circumstance eq 'total';
			return sprintf('%.1f', $n);
		};
		$returner->{'formatted_projected'} = $pace_format->($returner->{'projected'});
		$returner->{'formatted_on_target'} = $early ? '0' : $pace_format->($returner->{'on_target'});
		# The status and the graph line are held against the share of the target due
		# by now, not the whole of it, so an on-pace start reads as on pace rather
		# than a collapse; formatted_budgeted still names the whole period.
		$returner->{'full_expected'} = $returner->{'expected'};
		$returner->{'threshold'} = $full_target * $pace_elapsed;
		if ($early) {
			$returner->{'expected'} = 0;
		}
		elsif ($elapsed > 0 && $elapsed < 1 && $returner->{'expected'} > 0) {
			$returner->{'expected'} = sprintf('%.19f', $returner->{'expected'} * $pace_elapsed);
		}
		$returner->{'eval'} = $returner->{'actual'} - $returner->{'expected'};
		$returner = &budget_status_maker($returner);
		# A ceiling reads the mirror of the floor the status table is written for:
		# at or under the target is settled, over it is the alarm. Re-read the status
		# from the value against the target, not from the ratio.
		if (($returner->{'direction'} || 'floor') eq 'ceiling') {
			# a duration target wears the same real-window widening as a floor
			my $target = ($circumstance eq 'duration' && defined $returner->{'full_expected'} && defined $returner->{'scope'})
				? $returner->{'full_expected'} * $returner->{'scope'}
				: ($returner->{'budgeted'} || 0);
			my $value = $returner->{'value'} || 0;
			# a hair of float noise either side of the target is still the target
			my $epsilon = $target * .0000000001;
			$returner->{'on_track'} = ($value <= $target + $epsilon) ? 'yes' : 'no';
			my $ceiling = 'budgeted';
			if ($target > 0 && $value > $target * 1.2) { $ceiling = 'overkill'; }
			elsif ($target > 0 && $value > $target + $epsilon) { $ceiling = 'burnt_out'; }
			# landing exactly on the target spends the whole allowance without
			# passing it - an accomplishment, not merely within budget
			elsif ($target > 0 && $value >= $target - $epsilon) { $ceiling = 'accomplished'; }
			$returner = &{$gb::budget_statuses->{$ceiling}->{'notifier'}}($returner);
		}
	}
	else {
	#	$returner = {};
	}
	return $returner;
}

sub father_time($data) {
	my $start_time = &subs::rightNow();

	my $scope = $data->{'scope'};
	my $ts = $data->{'ts'};
	my $lock = $data->{'lock'} || 'off';
	my $timestamp = $data->{'timestamp'};
	my ($bt, $temp_timestamp);
	# how many periods an "Nnext" window spans, zero for the other ts values
	my $reach = 0;
	# a caller can ask for a window that many periods wide instead of one,
	# keeping its far edge (the budget's multiplier)
	my $periods = $data->{'periods'} || 1;
	# Months and years are calendar periods: their length is whichever month is
	# being crossed, February included. The others keep the plain span below.
	my $widener = &subs::timespan_widener($scope) || '';
	my $calendar_unit = $widener =~ /^months?$/i ? 'month' : $widener =~ /^years?$/i ? 'year' : undef;
	my $scope_count = $scope;
	$scope_count =~ s/[^0-9.]//g;
	$scope_count = 1 unless length $scope_count;
	$scope_count += 0;

	# A window is only good for the timestamp it was built from: handing the
	# same one to a later request is what put January's month on screen just
	# after midnight on the first.
	if (($gb::father_time->{$scope}->{$ts}->{$lock}->{$periods}->{'timestamp'} || 0) == $timestamp &&
		($gb::father_time->{$scope}->{$ts}->{$lock}->{$periods}->{'st'} || 0) > $start_time - 10000) {
		$bt = $gb::father_time->{$scope}->{$ts}->{$lock}->{$periods}->{'bt'};
		$temp_timestamp = $gb::father_time->{$scope}->{$ts}->{$lock}->{$periods}->{'tt'};
		$gb::father_time->{$scope}->{$ts}->{$lock}->{$periods}->{'st'} = $start_time;
	}
	else {
		if ($ts eq 'this') {
			$temp_timestamp = $timestamp;
		}
		elsif ($ts =~ 'last') {
			if ($calendar_unit) {
				my $back = 1;
				$back = $1 if $ts =~ /^(\d+)/;
				$temp_timestamp = &subs::calendar_shift($timestamp, -$back * $scope_count, $calendar_unit);
			}
			else {
				$temp_timestamp = &subs::time_span($scope, $timestamp);
				if ($ts =~ /(^[0-9])/) {
					my $tas = $ts;
					$tas =~ s/last//gi;
					# the number itself: the words run out at forty, and the pages
					# of periods walk well past that
					$temp_timestamp = &subs::time_span($tas . $scope, $timestamp);
				}
			}
		}
		elsif ($ts =~ 'next') {
			if ($calendar_unit) {
				my $ahead = 1;
				if ($ts =~ /^(\d+)/) { $reach = $1 + 0; $ahead = $reach; }
				$temp_timestamp = &subs::calendar_shift($timestamp, $ahead * $scope_count, $calendar_unit);
			}
			else {
				# the span this scope is worth: "next" is the span after this one,
				# "Nnext" is the next N spans counting this one, so 2next in week is
				# this week plus next week
				my $span_bt = &subs::time_span($scope, $timestamp);
				my $span = $timestamp - $span_bt;
				$temp_timestamp = $span + $timestamp;
				if ($ts =~ /(^[0-9])/) {
					my $tas = $ts;
					$tas =~ s/next//gi;
					$reach = $tas + 0;
					$temp_timestamp = $timestamp + $span * $reach;
				}
			}
		}

		if ($lock eq 'on' && grep { &subs::timespan_widener($scope) =~ /\Q$_\E/i } qw/minute hour day week month year/) {
			# Locked windows are counted in whole periods off the one the request
			# is in: "last" is the period before this one, "2next" is this one and
			# the next, and the number in a scope such as "3day" widens them.  The
			# periods come off the calendar, since a day is not always 24 hours
			# long and millisecond steps drift across daylight saving.
			my $unit = lc $scope;
			$unit =~ s/[^a-zA-Z]//gi;
			my $multiplier = $scope;
			$multiplier =~ s/[^0-9.]//gi;
			$multiplier = 1 unless $multiplier;
			my $shift = 0;
			my $units = $multiplier;
			if ($ts =~ 'last') {
				$shift = -1;
				$shift = -$1 if $ts =~ /^(\d+)/;
			}
			elsif ($ts =~ 'next') {
				if ($ts =~ /^(\d+)/ && $1 > 1) { $units = $multiplier * $1 }
				else { $shift = 1 }
			}
			if ($periods > 1) {
				$shift -= ($periods - 1) * $units;
				$units *= $periods;
			}
			my $at = localtime($timestamp / 1000);
			# The local minute and second into the hour, taken off the instant, are
			# the same in both occurrences of the repeated hour when the clocks go
			# back; timelocal() cannot tell them apart and always resolves to the
			# first. Stepping back from the instant itself gives the second 01:00
			# its own hour, and the half-hour zones their own :30 start.
			my $base = int($timestamp);
			my $period_start = sub {
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
					# weeks start on Sunday, so step off the Sunday of this week
					my $sunday = timegm(0, 0, 0, $at->mday, $at->mon - 1, $at->year) - $at->strftime('%w') * 86400;
					my @date = gmtime($sunday + 7 * $offset * 86400);
					return timelocal(0, 0, 0, $date[3], $date[4], $date[5]) * 1000;
				}
				my @date = gmtime(timegm(0, 0, 0, $at->mday, $at->mon - 1, $at->year) + $offset * 86400);
				return timelocal(0, 0, 0, $date[3], $date[4], $date[5]) * 1000;
			};
			$bt = $period_start->($shift);
			# A window that names periods ahead counts from the request: the part
			# of this period already spent is behind the row and belongs to "this",
			# not to the rows past it.  The far edge stays the period the name
			# counts to, and the unlocked windows already start here.
			$bt = $timestamp if ($ts =~ /next/ && $bt < $timestamp);
			$temp_timestamp = $period_start->($shift + $units);
		}
		else {
			if ($calendar_unit) {
				$bt = $reach > 1 ? $timestamp : &subs::calendar_shift($temp_timestamp, -$scope_count, $calendar_unit);
				$bt = &subs::calendar_shift($temp_timestamp, -$scope_count * $periods, $calendar_unit) if $periods > 1;
			}
			else {
				$bt = $reach > 1 ? $timestamp : &subs::time_span($scope, $temp_timestamp);
				$bt = $temp_timestamp - ($temp_timestamp - $bt) * $periods if $periods > 1;
			}
		}
	}

	$gb::father_time->{$scope}->{$ts}->{$lock}->{$periods} = { bt => $bt, tt => $temp_timestamp, st => $start_time, timestamp => $timestamp };

	return ($bt,$temp_timestamp);
}

sub budget_status_maker($returner) {
	# a target of nothing - a period only just opened, or a budget of zero - has
	# nothing to fall behind: the value is read as on track, rather than the
	# ratio's 0 >= 0 landing on "overkill"
	if (!defined $returner->{'expected'} || $returner->{'expected'} <= 0) {
		return &{$gb::budget_statuses->{'budgeted'}->{'notifier'}}($returner);
	}
	my $status;
	if ($returner->{'actual'} < $returner->{'expected'} - ( $returner->{'expected'} * .0000000001) && $returner->{'actual'} >= $returner->{'expected'} - ($returner->{'expected'} * .2)) {
		$status = 'budgeted';
		$returner->{'synth'} = 'play -v .3 "| sox -n -p synth .51 sine 391 && play | sox -n -p synth .51 triangle 500"';
	}
	elsif ($returner->{'actual'} >= $returner->{'expected'} * 2) {
		$status = 'overkill';
		$returner->{'synth'} = 'play -v .15 "| sox -n -p synth .51 pinknoise 1125 && play | sox -n -p synth .51 whitenoise 100"';
	}
	elsif ($returner->{'actual'} >= $returner->{'expected'} * 1.2) {
		$status = 'burnt_out';
		$returner->{'synth'} = 'play -v .15 "| sox -n -p synth .51 square 125 && play | sox -n -p synth .51 square 100"';
	}
	elsif ($returner->{'actual'} >= $returner->{'expected'}) {
		$status = 'accomplished';
		$returner->{'synth'} = 'play -v .15 "| sox -n -p synth .26 pluck 329.64 && play | sox -n -p synth .26 pluck 391.99 && play | sox -n -p synth .26 pluck 369.99 && play | sox -n -p synth .26 pluck 293.672"';
	}
	elsif ($returner->{'actual'} <= $returner->{'expected'} / 4) {
		$status = 'abandoned';
		$returner->{'synth'} = 'play -v .15 "| sox -n -p synth .51 triangle 261.64 && play | sox -n -p synth .51 triangle 261.64"';
	}
	elsif ($returner->{'actual'} <= $returner->{'expected'} / 2) {
		$status = 'neglected';
		$returner->{'synth'} = 'play -v .15 "| sox -n -p synth .26 saw 349.23 && play | sox -n -p synth .26 saw 329.63 && play | sox -n -p synth .26 saw 415.3 && play | sox -n -p synth .26 saw 439.99"';
	}
	elsif ($returner->{'actual'} <= $returner->{'expected'}) {
		$status = 'achievable';
		$returner->{'synth'} = 'play -v .15 "| sox -n -p synth .26 pluck 293.67 && play | sox -n -p synth .26 pluck 349.23 && play | sox -n -p synth .26 pluck 349.23 && play | sox -n -p synth .26 pluck 311.13"';
	}
	$returner = &{$gb::budget_statuses->{$status}->{'notifier'}}($returner);

	return $returner;
}

sub measure_calc_for {
	my ($app, $measure, $fallback) = @_;
	my $calc = &subs::setting_grabber({ app => $app, setting => 'measure_calc', subsetting => $measure });
	$calc = $fallback unless (defined $calc && length $calc);
	return (defined $calc && length $calc) ? $calc : 'sum';
}

# The panel names the window a budget reading was taken over. A locked budget
# sits on the calendar period its scope names ("This week"); an unlocked one
# rolls that length back from the moment it is read ("Last 7 days"). Returns
# the label and the phrase the pace sentence uses ("week" or "last 7 days").
sub budget_window_label($budget, $locked) {
	my $scope = &subs::format_name($budget->{'scope_name'} // '');
	return (&subs::ui('This') . ' ' . $scope, $scope)
		if $locked || $budget->{'fixed'} || !($budget->{'duration'} || 0);
	my $ms = &subs::time_span_length($budget->{'scope_name'} // '') || int($budget->{'duration'} || 0);
	my ($n, $unit);
	if ($ms % 86400000 == 0) { $n = $ms / 86400000; $unit = $n == 1 ? 'day' : 'days'; }
	elsif ($ms % 3600000 == 0) { $n = $ms / 3600000; $unit = $n == 1 ? 'hour' : 'hours'; }
	elsif ($ms % 60000 == 0) { $n = $ms / 60000; $unit = $n == 1 ? 'minute' : 'minutes'; }
	else { $n = int($ms / 1000); $unit = $n == 1 ? 'second' : 'seconds'; }
	my $label = &subs::ui('Last') . ' ' . $n . ' ' . &subs::ui($unit);
	return ($label, lc $label);
}

sub appointment_overlap {
	my ($appt, $start, $end) = @_;
	my $from = ($appt->{'timestamp'} || 0) + 0;
	my $to = $from + abs($appt->{'duration'} || 0);
	my $lo = $from > $start ? $from : $start;
	my $hi = $to < $end ? $to : $end;
	return $hi > $lo ? $hi - $lo : 0;
}

1;
