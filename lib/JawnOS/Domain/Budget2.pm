package subs;

# Budget2: extracted from subroutines.pl (package subs). Loaded on
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
use Minion;
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

our $gb;

# The app's own budget, held against the window the evaluation rolled up. The
# setting is a comma list of <amount>/<scope> entries - 17h/week, 7.0/w,
# $50/M - and each is scaled to the window before it meets its actual, so a
# month of readings of a weekly budget is still the same budget. Before this,
# the report could see how long an app ran but never whether running that
# long was over the line.
sub budget_holding {
	my ($app, $since, $act, $budget) = @_;
	$budget = &subs::setting_grabber({ app => $app, setting => 'budget' }) unless defined $budget;
	return [] unless $budget;
	my $window = &subs::rightNow() - $since;
	return [] unless $window > 0;
	$act = {} unless $act;
	my @out;
	my $money;
	foreach my $entry ( split ',', $budget ) {
		# an entry with no scope says nothing a window can be held against
		my ($amount, $scope) = split '/', $entry;
		next unless defined $amount && defined $scope && $scope =~ /\w/;
		$scope = '1' . $scope unless $scope =~ /[0-9]/;
		my $scope_ms = &subs::time_abbrev_translator($scope);
		next unless $scope_ms && $scope_ms > 0;
		my $scale = $window / $scope_ms;
		if ($amount =~ /^\s*\$/) {
			my $expected = ($amount =~ s/[^0-9.]//gr) * $scale;
			next unless $expected > 0;
			unless (defined $money) {
				$money = &subs::db_query('select sum(abs(coalesce(total,0))) as total from appointments where app = ? and cast(timestamp as integer) >= ?', $app, $since)->hash->{'total'};
				$money = 0 unless defined $money;
			}
			push @out, {
				of => 'total', budget => $entry,
				expected => &subs::price_formatter($expected),
				actual => &subs::price_formatter($money),
				percentage => int(100 * $money / $expected + 0.5),
				over => $money > $expected ? 1 : 0,
			};
		}
		elsif ($amount =~ /[a-zA-Z]/) {
			my $expected = &subs::time_abbrev_translator($amount) * $scale;
			next unless $expected > 0;
			my $actual = $act->{'duration'} || 0;
			push @out, {
				of => 'duration', budget => $entry,
				expected => &subs::duration_sayer($expected / 1000),
				actual => &subs::duration_sayer($actual / 1000),
				percentage => int(100 * $actual / $expected + 0.5),
				over => $actual > $expected ? 1 : 0,
			};
		}
		else {
			my $expected = $amount * $scale;
			next unless $expected > 0;
			my $actual = $act->{'count'} || 0;
			push @out, {
				of => 'occurences', budget => $entry,
				expected => int($expected + 0.5),
				actual => $actual + 0,
				percentage => int(100 * $actual / $expected + 0.5),
				over => $actual > $expected ? 1 : 0,
			};
		}
	}
	return \@out;
}

sub evaluation_agent {
	my ($app, $period) = @_;
	$app = '__president' unless $app && $app ne '';
	my $global = ($app eq '__president');
	my $settings = &subs::settings_grabber({ app => 'mail', settings => [ 'eval_assistant' ] });
	my $model = $settings->{'eval_assistant'};
	my $now = &subs::rightNow();
	my $machine = &subs::setting_grabber({ app => 'me', setting => 'my_name' }) || '';
	# The windows the report reads, shortest first. A change of pace only shows
	# against a longer one, so every run weighs them all rather than one: the
	# per-day rate over a day against the week against the year against all time
	# is what a trend is.
	my @window_defs = (
		{ name => 'day',   span => 86400000,       label => 'the last 24 hours' },
		{ name => 'week',  span => 7 * 86400000,   label => 'the last 7 days' },
		{ name => 'month', span => 30 * 86400000,  label => 'the last 30 days' },
		{ name => 'year',  span => 365 * 86400000, label => 'the last 365 days' },
		{ name => 'all',   span => 0,              label => 'all time' },
	);
	my %roll;
	my %snapshot;
	my $windows = {};
	# the app's own measure definitions carry each reading's unit and the range it
	# is set to expect; read once, so every window speaks its readings the same way
	my $measure_defs = $global ? {} : (eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'app_measures' }) } || {});
	# what the app is, read once: its construct decides whether a speed reading is
	# a movement, and its records decide whether it has occurrences to appraise at
	# all. A weather feed or a currency quote logs a measurement appointment for
	# each reading, so its "occurrences" are just the readings themselves.
	my $app_settings = $global ? {} : &subs::settings_grabber({ app => $app, benign => 1 });
	my $speed_app = (!$global && (($app_settings->{'pos'} || '') eq 'action')) ? 1 : 0;
	my $measure_app = 0;
	unless ($global) {
		my $counts = &subs::db_query("select count(*) as total, sum(case when type = 'measure' then 1 else 0 end) as measured from appointments where app = ?", $app)->hash || {};
		my $total = ($counts->{'total'} || 0) + 0;
		my $measured = ($counts->{'measured'} || 0) + 0;
		$measure_app = ($total && $measured / $total >= 0.9) ? 1 : 0;
	}
	# the last few periods of every clock the inventory graphs - month by month,
	# week by week, day by day, hour by hour, minute by minute - so a trend is read
	# from the shape of the pace, not one span's total. The count is the app's own
	# scope count (how many periods its graph walks). A measurement app has no pace
	# to read, so the clock is left out of its briefing.
	my $trends = ($global || $measure_app) ? {} : &subs::evaluation_period_trends($app, &subs::setting_grabber({ app => $app, setting => 's_scope_count' }));
	# the app's own unit of activity - nights, cups, sessions, walks - read for the
	# report so a day's count does not hide the shape of a single episode. A
	# measurement app's "episodes" are single readings, so it is left out too.
	my $episodes = ($global || $measure_app) ? {} : &subs::evaluation_episodes($app, $now - 90 * 86400000);
	# the schedule this scope is on, so the report knows how often it is asked for
	# on its own and when the next run is due - the configuration the controls show
	my $schedule;
	{
		my $cadence = &subs::evaluation_cadence($app);
		if ($cadence && $cadence ne 'off') {
			my @day_names = qw/sunday monday tuesday wednesday thursday friday saturday/;
			my @days = map { $day_names[$_] } @{ &subs::nightly_evaluation_days($app) };
			my $sch = &subs::nightly_evaluation_schedule($app);
			$schedule = {
				cadence => $cadence,
				(@days ? (days => \@days) : ()),
				($sch && $sch->{'next_run'} ? (next_run => $sch->{'next_run'}) : ()),
			};
		}
	}
	foreach my $wd ( @window_defs ) {
		my $since = $wd->{'span'} ? ($now - $wd->{'span'}) : 0;
		my $r = &appointment_rollup($app, $since);
		$roll{ $wd->{'name'} } = $r;
		my $span_days = $wd->{'span'} ? ($wd->{'span'} / 86400000) : 0;
		# all time has no fixed span, so its days are the app's own history
		my $use_days = sub {
			my ($act) = @_;
			my $d = $span_days;
			$d = ($act->{'first'} && $act->{'first'} > 0) ? ($now - $act->{'first'}) / 86400000 : 1 unless $d;
			return $d < 1 ? 1 : $d;
		};
		if ($global) {
			my @owners = sort { ($r->{'activity'}->{$b}->{'count'} || 0) <=> ($r->{'activity'}->{$a}->{'count'} || 0) } keys %{$r->{'activity'}};
			splice(@owners, 12) if scalar @owners > 12;
			my %apps;
			foreach my $o ( @owners ) {
				my $act = $r->{'activity'}->{$o} || {};
				my @ad = sort keys %{ $r->{'daily'}->{$o} || {} };
				$apps{$o} = {
					occurrences => $act->{'count'} || 0,
					days_active => scalar @ad,
					per_day => &subs::briefing_number(($act->{'count'} || 0) / $use_days->($act)),
					total_duration => &subs::duration_sayer(($act->{'duration'} || 0) / 1000),
				};
				my $quant = $r->{'quantity'}->{$o};
				$apps{$o}->{'quantity_total'} = &subs::briefing_number($quant->{'total'}) if $quant && $quant->{'count'};
			}
			$windows->{ $wd->{'name'} } = { label => $wd->{'label'}, apps => \%apps };
		}
		else {
			my $act = $r->{'activity'}->{$app} || {};
			my @ad = sort keys %{ $r->{'daily'}->{$app} || {} };
			my $days = $use_days->($act);
			# the readings over this window, so the report can speak the numbers
			# (a weight climbing, a pressure falling) and not only the correlations
			# they happen to make. Speed is a movement's reading; leave it out of a
			# scope that is not an action app.
			my $measurements = &subs::evaluation_measures($app, $since, $measure_defs);
			delete $measurements->{'speed'} unless $speed_app;
			if ($measure_app) {
				# the appointments are the readings: there is no occurrence, session,
				# episode or pace to report, only the values and how they moved
				$windows->{ $wd->{'name'} } = {
					label => $wd->{'label'},
					window_days => int($days),
					(scalar keys %{$measurements} ? (measurements => $measurements) : ()),
				};
				$snapshot{ $wd->{'name'} } = { measurements => { map { $_ => $measurements->{$_}->{'latest'} } sort keys %{$measurements} } } if scalar keys %{$measurements};
				next;
			}
			my $entry = {
				label => $wd->{'label'},
				window_days => int($days),
				occurrences => $act->{'count'} || 0,
				days_active => scalar @ad,
				per_day => &subs::briefing_number(($act->{'count'} || 0) / $days),
				total_duration => &subs::duration_sayer(($act->{'duration'} || 0) / 1000),
				average_duration => &subs::duration_sayer(($act->{'count'} ? int(($act->{'duration'} || 0) / $act->{'count'}) : 0) / 1000),
				kinds => &subs::evaluation_kinds($r->{'kinds'}->{$app}, 4),
			};
			my $quant = $r->{'quantity'}->{$app};
			$entry->{'quantity'} = {
				times => $quant->{'count'},
				total => &subs::briefing_number($quant->{'total'}),
				average => &subs::briefing_number($quant->{'average'}),
				unit => $quant->{'unit'},
			} if $quant && $quant->{'count'};
			if ($wd->{'name'} eq 'week' || $wd->{'name'} eq 'month') {
				$entry->{'daily_counts'} = join ' ', map { $_ . ':' . $r->{'daily'}->{$app}->{$_} } @ad;
			}
			if ($wd->{'name'} eq 'month') {
				$entry->{'hour_profile'} = $r->{'hours'}->{$app} || {};
				$entry->{'weekday_profile'} = $r->{'weekdays'}->{$app} || {};
			}
			$entry->{'measurements'} = $measurements if scalar keys %{$measurements};
			# where the app went, from the GPS track the continent table holds: how
			# far and how fast, so a walk reads as a movement, not only a count.
			# The speed is left out where it is not a movement (see speed_app).
			my $continent = &subs::evaluation_continent($app, $since);
			delete $continent->{'speed'} unless $speed_app;
			$entry->{'continent'} = $continent if scalar keys %{$continent};
			$windows->{ $wd->{'name'} } = $entry;
			# the raw numbers, kept so the next run can be handed the change
			$snapshot{ $wd->{'name'} } = {
				occurrences => $act->{'count'} || 0,
				per_day => sprintf('%.2f', ($act->{'count'} || 0) / $days),
				total_duration => int(($act->{'duration'} || 0) / 1000),
				($quant && $quant->{'count'} ? (quantity_total => sprintf('%.1f', $quant->{'total'})) : ()),
				(scalar keys %{$measurements} ? (measurements => { map { $_ => $measurements->{$_}->{'latest'} } sort keys %{$measurements} }) : ()),
			};
		}
	}
	# Correlations need weeks, not hours, so they are read over the month: the
	# shorter windows hold too few days to say anything about a relationship
	my $corr_since = $now - 30 * 86400000;
	my $corr_days = &subs::evaluation_window_days($corr_since);
	my $mroll = $roll{'month'};
	my $app_summary = sub {
		my ($from, $owner) = @_;
		my $act = $from->{'activity'}->{$owner} || {};
		return {
			occurrences => $act->{'count'} || 0,
			days_active => scalar keys %{ $from->{'daily'}->{$owner} || {} },
			total_duration => &subs::duration_sayer(($act->{'duration'} || 0) / 1000),
		};
	};
	# what the app already is: the constructs it carries, so a relationship the
	# model names can be filed under the right one
	my %lives;
	$lives{'pos'} = $app_settings->{'pos'} if $app_settings->{'pos'};
	$lives{'mab'} = $app_settings->{'mab'} if $app_settings->{'mab'};
	# The app's own configuration, so the model reads what the thing is and what it
	# is set to expect - its aliases, category and subcategory, budget, default
	# duration, cost and worth, warranty, schedule and movement - not just how
	# often it ran. The internal and bulky keys are left out and values are
	# shortened: on a free tier or a local model the prompt is the bill.
	my %skip_setting = map { $_ => 1 } qw(uuid model pos mab ci colour dimensions scrollTop main_image nfc clothesline jopen ia operator_door evaluation_report evaluation_headlines chatbot_conversations special_budgets header);
	my $settings_brief = {};
	foreach my $sk ( sort keys %{$app_settings} ) {
		next if $skip_setting{$sk};
		next if $sk =~ /^(?:sc_|s_)/;
		my $sv = $app_settings->{$sk};
		next unless defined $sv && $sv =~ /\S/;
		$sv =~ s/\s+/ /g;
		$sv = substr($sv, 0, 120) . '...' if length($sv) > 120;
		$settings_brief->{$sk} = $sv;
	}
	# Where the app keeps a budget locked to the calendar, the budget is read
	# against a period still running, so the report is handed the pace and not only
	# the whole-period target: how far through the period it is, whether the value
	# has kept its share of it, and what the pace projects by the period's end.
	# Without this a young period is read as a shortfall.
	my $budget_pace;
	# The nightly run is a Minion job in President's worker, where Manager.pl is
	# not loaded. budget_calculator (and father_time under it) live in the domain
	# layer now (lib/JawnOS/Domain/Budget.pm) and load on first call, so the call
	# is safe; provides() keeps the guard without forcing the module to compile.
	# The web Evaluate button still gets the pace; the scheduled run reads the
	# budget figure from settings_brief and leaves the pace out.
	if (!$global && !$measure_app && ($app_settings->{'budget'} || '') =~ /\S/ && ($app_settings->{'s_lock'} || '') eq 'on' && subs::provides('budget_calculator')) {
		foreach my $mode ( sort keys %{$gb::budget_modes} ) {
			my $bp = &subs::budget_calculator({
				app => $app,
				budget => $app_settings->{'budget'},
				circumstance => $mode,
				settings => $app_settings,
			});
			next unless ($bp->{'is_scope'} || '') eq 'yes' && ($bp->{'circumstance'} || '') eq $mode;
			next unless defined $bp->{'elapsed'} && $bp->{'elapsed'} > 0 && $bp->{'elapsed'} < 1;
			$budget_pace->{$mode} = {
				period => $bp->{'scope_name'},
				progress_percent => $bp->{'progress'},
				on_track => $bp->{'on_track'},
				value => $bp->{'formatted_value'},
				budgeted => $bp->{'formatted_budgeted'},
				due_by_now => $bp->{'formatted_on_target'},
				projected => $bp->{'formatted_projected'},
			};
		}
	}
	# what one logged unit is: a logged quantity is already an amount when its own
	# unit is a measure (coffee logs 10 oz, not ten coffees), and the app's serving
	# is the default for the appointments that logged none
	my $serving = ($global || $measure_app) ? undef : &subs::quantity_serving($app_settings->{'quantity'});
	unless ($global || $measure_app) {
		foreach my $wname ( keys %{$windows} ) {
			my $e = $windows->{$wname};
			my $q = $e->{'quantity'} or next;
			my $amount = &subs::evaluation_amount($q, $e->{'occurrences'}, $serving, $e->{'window_days'});
			next unless $amount;
			$q->{'unit'} = $amount->{'unit'};
			$q->{'amount_total'} = $amount->{'total'} . ' ' . $amount->{'unit'};
			$q->{'amount_per_day'} = $amount->{'per_day'} . ' ' . $amount->{'unit'} . '/day';
			$q->{'amount_per_entry'} = &subs::briefing_number($amount->{'total'} / ($e->{'occurrences'} || 1)) . ' ' . $amount->{'unit'};
			$q->{'volume_ml_total'} = $amount->{'ml_total'} if defined $amount->{'ml_total'};
			$q->{'volume_ml_per_day'} = $amount->{'ml_day'} if defined $amount->{'ml_day'};
			$q->{'defaulted_from_serving'} = 1 if $amount->{'filled'};
			# the raw unitless sum and average only invite the model to divide them
			delete @{$q}{qw/total average/};
		}
	}
	my @related;
	unless ($global || $measure_app) {
		foreach my $link ( @{ &relational_family($app) } ) {
			my $lroll = &appointment_rollup($link->{'app'}, $corr_since);
			my ($xs, $ys) = &day_pair_series($mroll->{'daily'}->{$app} || {}, $lroll->{'daily'}->{$link->{'app'}} || {});
			my $c = &series_correlation($xs, $ys);
			$c->{'habit'} = 1 if $c && &subs::daily_habit($mroll->{'daily'}->{$app} || {}, $lroll->{'daily'}->{$link->{'app'}} || {}, $corr_days);
			push @related, { app => $link->{'app'}, link => $link->{'link'}, correlation => $c, activity => $app_summary->($lroll, $link->{'app'}) };
		}
	}
	# what else was happening: every app's day counts and every numeric measure
	# logged, lined up against this app (or the top apps) at the best lag. A
	# source that runs nearly every day is filtered out inside, so a daily fetch
	# (a metal price, the weather, a currency quote) cannot pass as a finding.
	my $all_counts = $global ? $mroll->{'daily'} : &subs::appointment_rollup('__president', $corr_since)->{'daily'};
	my $measures = &subs::measure_series($corr_since);
	my @targets;
	if ($global) {
		my @owners = sort { ($mroll->{'activity'}->{$b}->{'count'} || 0) <=> ($mroll->{'activity'}->{$a}->{'count'} || 0) } keys %{$mroll->{'activity'}};
		splice(@owners, 12) if scalar @owners > 12;
		@targets = map { { app => $_ } } @owners;
	}
	else {
		push @targets, { app => $app };
		foreach my $name ( sort keys %{ $measures->{$app} || {} } ) {
			push @targets, { app => $app, measure => $name };
		}
	}
	my $around;
	if ($global) {
		$around = &subs::context_correlations(\@targets, $corr_days, $all_counts, $measures);
	}
	elsif (!$measure_app) {
		# for one app, read what ran at the same time of day rather than how its
		# daily totals rose and fell: the event read the daily correlation missed
		$around = &subs::evaluation_context_scan($app, &subs::rightNow() - 60 * 86400000, 30 * 60000, 8);
		# and the time each neighbour keeps - the median gap to the nearest episode
		# of this app - so the relationship carries a lag, not only a co-occurrence
		foreach my $entry ( @{$around} ) {
			my $lag = &subs::evaluation_episode_lag($app, $entry->{'app'}, &subs::rightNow() - 90 * 86400000);
			$entry->{'lag_minutes'} = $lag->{'median_minutes'} if defined $lag->{'median_minutes'};
		}
	}
	# the conditions the app runs under: any app's numeric measures read around
	# this app's episodes (walk in the cold, a flare in the damp)
	my $conditions = ($global || $measure_app) ? [] : &subs::evaluation_conditions($app, &subs::rightNow() - 60 * 86400000, 8);
	my ($different, @open);
	unless ($global || $measure_app) {
		$different = &subs::measure_contrasts($app, $corr_days, $all_counts, $measures);
		# the app's own task list: what is still open says what the app is for
		my $tasks = eval { return decode_json(&subs::setting_grabber({ app => $app, setting => 'tasks' }) || '') } || [];
		@open = map { { task => substr($_->{'task'}, 0, 60), priority => ($_->{'priority'} || 0) + 0 } }
			grep { ($_->{'completed'} || '') ne 'on' && $_->{'task'} } @{$tasks};
		@open = sort { $b->{'priority'} <=> $a->{'priority'} } @open;
		splice(@open, 8) if scalar @open > 8;
		# Speed is only read for a scope that is a movement (an action app); a
		# speed riding along from another app's GPS fix is not a condition.
		unless ($speed_app) {
			my $keep = sub { (($_[0]->{'measure'} // '') ne 'speed' || &subs::evaluation_speed_app($_[0]->{'app'})) ? 1 : 0 };
			$different = [ grep { $keep->($_) } @{$different} ] if $different;
			$conditions = [ grep { $keep->($_) } @{$conditions} ] if $conditions;
		}
	}
	# The last report this scope produced, so the model can say what changed
	# instead of describing the same numbers again. Trimmed hard: on a free tier
	# or a local model the prompt is the bill.
	my $prior = &subs::evaluation_report_for($app);
	my $last_report;
	if (($prior->{'text'} || '') =~ /\S/) {
		$last_report = {
			timestamp => $prior->{'timestamp'},
			model => $prior->{'model'},
			text => substr($prior->{'text'}, 0, 1200),
		};
	}
	# A rolling list of the headlines the house has already seen for this scope:
	# long-range continuity for a few tokens each, so the model can tell a new
	# turn from a standing one.
	my @recent = @{ (&subs::evaluation_headline_list($app)) };
	@recent = @recent[0 .. 9] if scalar @recent > 10;
	# The same windows as the last run left them, so even a small model is handed
	# the change rather than left to infer it from prose
	my $since_last;
	if (!$global && $prior->{'snapshot'}) {
		my %delta;
		foreach my $wname ( sort keys %{$windows} ) {
			my $was = $prior->{'snapshot'}->{$wname} or next;
			my $now = $snapshot{$wname} or next;
			if ($measure_app) {
				# only the readings are compared for a measurement app; an older
				# report's occurrence counts are not part of this run's subject
				next unless ref $was eq 'HASH' && $was->{'measurements'};
				$was = { measurements => $was->{'measurements'} };
			}
			elsif (!$speed_app && ref $was eq 'HASH' && ref $was->{'measurements'} eq 'HASH') {
				# a speed an older run happened to record is not a reading this run
				# compares: drop it from the "was" side so its absence says nothing
				delete $was->{'measurements'}->{'speed'};
			}
			$delta{$wname} = { was => $was, now => $now };
		}
		$since_last = { previous_at => $prior->{'timestamp'}, windows => \%delta } if scalar keys %delta;
	}
	# How much the answer should carry: brief is a headline only (cheap, for a
	# daily run), full is the whole report
	my $depth = (&subs::setting_grabber({ app => $app, setting => 'evaluation_depth' }) || '') eq 'brief' ? 'brief' : 'full';
	my $briefing = {
		scope => $global ? 'the whole house' : $app,
		constructs => [ sort keys %{$gb::relationals} ],
		windows => $windows,
		($measure_app ? (measurements_only => 1) : ()),
		($schedule ? (schedule => $schedule) : ()),
		($serving ? (serving => $serving) : ()),
		(scalar keys %{$settings_brief} ? (settings => $settings_brief) : ()),
		($budget_pace && scalar keys %{$budget_pace} ? (budget_pace => $budget_pace) : ()),
		depth => $depth,
		%lives,
		(!$global && !$measure_app ? (related => \@related) : ()),
		(!$measure_app && defined $around ? (around => $around) : ()),
		(!$global && !$measure_app && scalar keys %{$trends} ? (trends => $trends) : ()),
		(!$global && !$measure_app && scalar keys %{$episodes} ? (episodes => $episodes) : ()),
		(!$global && !$measure_app && scalar @{$conditions} ? (conditions => $conditions) : ()),
		(!$global && !$measure_app && $different && scalar @{$different} ? (different => $different) : ()),
		(!$global && !$measure_app && scalar @open ? (tasks => \@open) : ()),
		($last_report && !$measure_app ? (previous => $last_report) : ()),
		(scalar @recent && !$measure_app ? (headlines => \@recent) : ()),
		($since_last ? (since_last => $since_last) : ()),
	};
	my $system = 'You are the evaluation agent of JawnOS, a house that logs its life as timed appointments. A briefing follows for one app (or the whole house). Its windows map measures the same activity over five spans - day (24 hours), week, month, year and all time - each with occurrences, days_active, per_day (occurrences divided by the span in days, so spans can be compared), total_duration and average_duration, and, for a single app, kinds (the appointment types, subtypes and projects that ran and the model or option names they carried, each counted). The week and month windows also carry daily_counts (one count per day as date:count); the month window also carries an hourly profile (hours 0-23) and a weekday profile (0 is Sunday). These five are what a trend is read from: a per_day that climbs from year to month to week is a pace that is rising. For a single app the briefing also says what it is (its pos and mab constructs) and may carry related (the apps the relational window ties to it, each with a Pearson correlation of the daily series over the last 30 days at the best lag; a positive lag_days means the related app trails this one), around (the apps whose occurrences fell within a half hour either side of this app\'s own occurrences more than chance would place them - each with hits (how many of this app\'s occurrences had it nearby), of (how many occurrences were scanned), lift (the multiple over chance) and offset_minutes (negative when it tends to come before this app, positive after) and, when the episode lists allow, lag_minutes (the median gap from this app\'s episodes to that app\'s nearest episode - negative when it usually comes first) - so a thing that consistently happens at the same time stands out where a correlation of daily totals would drown it in the calendar), different (the measures that stood out on the days this app ran, its mean on those days (on_days) against its mean on the other days (off_days), scaled by z) and tasks (what is still open). A pair or entry marked habit runs on nearly every day and its correlation is the calendar, not a cause. A thing need not be linked to be a cause. A previous report may ride along as previous - the text the last run left, with its date and model - headlines is the last ten headlines the house has seen for this scope, and since_last hands you each window as it was (was) and as it is now (now); together they say what has changed. depth says how much to write - brief means one line, full means the whole report. schedule, when it rides along, says how often this report is asked for on its own: cadence is one of hourly, daily, weekly, monthly, yearly or each_run (evaluated whenever the appointment itself runs), with days (the weekdays it runs on, for daily or weekly) and next_run (when a run is queued) when they apply. Each window also carries quantity where entries logged one - times (how many carried a quantity). serving, where the app records one, is the default size of a single unit (coffee logs \'10oz\' a cup) and fills the appointments that logged no quantity of their own; each window\'s quantity carries unit where the appointments logged one and amount_total / amount_per_day in that unit (and volume_ml), with defaulted_from_serving set when that filling happened - so a logged quantity is read as the amount it already is. Where an app logs its own readings (a measure typed in against an appointment), each window may also carry measurements: one entry per measure with readings (how many were logged) and, for a numeric reading, average, min, max, the latest value and latest_at; a text or select reading keeps its latest and the values seen; a measure the app defines also carries its unit and range. These are the numbers themselves, so a measure that drifts - a weight climbing, a pressure falling - is read from its latest against its average and its min and max, not only from the correlations it makes. Where an app recorded a place track (the continent table the GPS fills), each window may also carry continent: points (how many fixes), distance_km, duration_minutes, the bounds (north, south, east, west) and from/to (the first and last fix), and speed (average and max, in km/h; the average is derived from the distance and the time when the fixes carried no speed of their own) - so a walk is read as the movement it was. A run for one app may also carry episodes: the app\'s own activity gathered into the natural unit rather than a count per day - a night, a cup, a session, a walk - with gap_minutes (the gap that split one episode from the next), episodes, days, per_day, median_duration and longest_duration, onset_hours (how many episodes began in each hour of the clock, 0-23) and, where the app logs a quantity, quantity_total, quantity_per_episode, quantity_per_day and unit. Read them where a day\'s count hides the shape: a sleep is a night with an onset hour and a length, a coffee a cup at a time of day - give the typical onset and duration, not only the tally. A run for one app may also carry conditions: for each numeric measure any app logged - a weather app\'s temperature or humidity, a pollen count, a reading of your own - how its value sits against this app\'s activity, read two ways and both given. around weighs the windows around this app\'s episodes against its value everywhere else; day weighs the measure\'s mean on the days the app ran against the days it did not. Each reading carries its ratio, z (how far the shift stands out from the spread), n and direction (higher or lower), and the entry\'s own kind, on, off, ratio, z, n and direction are the stronger of the two. confidence says which readings stand as a condition - both (the two agree), day (only the whole-day reading does) or around (only the window reading does). Weigh them honestly: the day reading sets whole days against whole days, so the hour of the clock cancels and it is the one to trust where the measure follows the sun - a temperature, a humidity, a wind or a pollen count shifts with the hour, so an around that stands alone may be the time of day wearing the app\'s name, while a reading that stands at both is the surest and one that stands at day alone is sound; the measure\'s app is the condition\'s home. A run for one app may also carry trends: for each clock the inventory graphs - minute, hour, day, week, month and year - the counts of the last several periods as label=count pairs, oldest first, so the pace is read period by period (a week that fell away, a month that doubled). The newest pair is the period still running, so its count is written label=count/<percent>%, the percent saying how far through that period the run happened: a small count at a small percent is a period in progress, not a fall, so weigh it against its percent before calling the pace down. A period with nothing rides along as 0, but a scope whose whole window is empty is left out - never read its absence as a fall to nothing. Each scope also carries settings, the app\'s own configuration as it stands - its aliases (aka), its category and subcategory, its budget (what it is meant to run to), its default duration, cost and worth, its warranty, schedule and movement - so what the thing is, and what it expects of itself, is read from how it is set up. Where the app keeps a budget on its own period, budget_pace rides along: one entry per budgeted measure (occurences, duration, total) with the period, progress_percent (how far through it the run is), on_track (whether the value has kept its share of the period so far), value, budgeted (the whole period\'s budget), due_by_now (that share of it) and projected (what the current pace carries to the period\'s end) - so a part-run period is read as a pace, and on track or behind is called from on_track, not from the plain share. Use only the numbers given.';
	# A scope whose appointments are measurements has no occurrence to appraise:
	# the readings are the whole subject, so the model is told plainly not to
	# invent a pace from the count of readings.
	$system .= ' This scope records measurements, not events: each appointment is a reading of a value. Report only the measured values and what changed between them - never occurrences, sessions, episodes, days active, pace, logs or counts of any kind. A window with no readings is a gap in logging, not a fall to zero.' if $measure_app;
	$system .= ' Speed is not a reading of this scope; do not mention it, even if a previous report did.' if !$global && !$speed_app;
	my $measure_instructions = 'Begin with a single headline line - at most twenty words, no label - that names what the values did, then a blank line. Say what changed since the last run using since_last (and previous when it rides along). Then answer under exactly three headings: Trends, Correlations, Predictions. Under Trends, give each measurement\'s latest value against that window\'s average, min and max, and say whether it is rising, falling or steady across the windows; hold the range the app is set to expect against it where the briefing gives one. This scope records measurements, not events: never mention occurrences, sessions, episodes, days active, pace, logs or how often anything was recorded. A window with no readings is a gap in logging, not a fall to zero. Under Correlations, weigh any conditions the briefing carries, or say there is nothing to correlate. Under Predictions give two or three concrete, falsifiable predictions that the readings carry. Plain text.';
	my $instructions = $depth eq 'brief'
		? ($measure_app
			? 'Write one line only - a headline, at most twenty words, no label and no headings - that states what the values did, or that they held if nothing changed. Nothing else.'
			: 'Write one line only - a headline, at most twenty words, no label and no headings - that states what changed in the pace, or that it held if nothing did. Nothing else.')
		: ($measure_app ? $measure_instructions : 'Begin with a single headline line - at most twenty words, no label - that names what the numbers showed, then a blank line. Use previous, headlines and since_last to say what changed since the last run - what the numbers now show that they did not - and leave out what has not changed, since the report is read against the last one. Then answer under exactly three headings: Trends, Correlations, Predictions. Under Trends compare the windows to say how the pace is changing - is per_day rising or falling from all time and year to month and week? - and whether sessions are getting longer or shorter, naming the kinds, models and projects the activity was made of and the tasks it serves, and giving the durations. Say first what this appointment is for - what the activity is - reading it from its name, its constructs and its kinds. Where the appointment measures something consumed or done (water drunk, teeth brushed, cigarettes), the windows\' quantity and its amount_per_day (and volume_ml when the unit converts) are how much actually happened: give the generally recommended or typical daily figure for a person (for water, several glasses to a few litres a day; for coffee, a few cups), then say where the logged amount sits against it - a plain guide, not medical advice. This is where a real change of pace lives, so say it plainly and do not dress a steady habit as a trend. Where the app logs measurements, say where each reading is going - the latest reading against the average and the min and max for that window - and hold the range the app is set to expect against it. Where a window carries continent, say how far the app went and how fast, and whether that is rising or falling across the windows. Read trends too: say whether the recent periods are rising or falling, not only what the aggregate windows show, and name the period a turn began at. Where episodes ride along, give the typical onset hour and the median and longest episode, and say whether the episodes are getting longer, shorter, earlier or later. The newest period is still running - its count carries the percent elapsed - so do not read a part-run period as a fall: call it in progress and judge its pace against the percent. Where budget_pace rides along, say plainly whether the app is on track for its budget - read on_track and progress_percent against value and due_by_now, and give the projected figure - and never call a young period behind. Under Correlations weigh related (a Pearson r of the daily series) and around (things that happened at the same time of day, by lift) together: say what r means here and whether the lag suggests one follows the other, say what around says - what consistently runs beside this app and which way, reading offset_minutes - and treat a measure in different as a suspect even when no pair clears the bar; name what was out of the ordinary on the app\'s own days, and call a habit pair what it is - two daily routines, not a finding. If nothing stands out, say so. Under Predictions give two or three concrete, falsifiable predictions for the coming weeks, ones the windows\' pattern actually carries - never a rule invented from a single day. If, and only if, the Correlations make one relationship certain - a non-habit pair with |r| >= 0.8 - end the answer with one line "Link: <app>" naming the app this one should be related to; otherwise end with "Link: none". A wrong link mislabels what an app is, so name one only when the numbers leave no doubt. Plain text.');
	my $user = $instructions . "\n\n" . encode_json($briefing);
	my ($text, $error);
	if ($model && &evaluation_agent_ready()) {
		($text, $error) = &evaluation_model_call_role('eval_assistant', $system, $user, &subs::ai_role_thinking_effective('eval_assistant'));
	}
	elsif ($model) {
		$error = 'no evaluation agent is reachable from this machine';
	}
	else {
		$error = 'no evaluation model is chosen - pick one in the mailbox configuration';
	}
	my %mentions;
	$mentions{$app} = 1 unless $global;
	if ($global) {
		foreach my $o ( keys %{ $roll{'month'}->{'activity'} } ) { $mentions{$o} = 1 if $o; }
	}
	foreach my $entry ( @related ) { $mentions{ $entry->{'app'} } = 1 if $entry->{'app'}; }
	foreach my $entry ( @{ $around || [] } ) {
		$mentions{ $entry->{'app'} } = 1 if $entry->{'app'};
		$mentions{ $entry->{'vs_app'} } = 1 if $entry->{'vs_app'};
	}
	foreach my $entry ( @{ $different || [] } ) { $mentions{ $entry->{'app'} } = 1 if $entry->{'app'}; }
	# every appointment the report names should be clickable and formatted, even
	# when the briefing did not hand it over: a project or model name can itself be
	# an appointment (vibe_coding), so the text is scanned against the house's apps
	# and any that appear are added to the names the page links
	if ($text) {
		foreach my $name ( keys %{ &subs::appointment_names() } ) {
			next if $mentions{$name};
			my $spaced = $name; $spaced =~ s/_/ /g;
			my $q = quotemeta $name;
			my $qs = quotemeta $spaced;
			$mentions{$name} = 1 if $text =~ /(?<![\w])$q(?![\w])/i || ($spaced ne $name && $text =~ /(?<![\w])$qs(?![\w])/i);
		}
	}
	# the model may name one relationship it is certain of; the naming is checked
	# against the briefing before anything is written
	my $linked;
	if (!$global && !$measure_app && $text) {
		my ($named) = $text =~ /^\s*Link:\s*([A-Za-z0-9_\-\.]+)\s*$/mi;
		if ($named && lc($named) ne 'none') {
			$linked = &subs::evaluation_linker($app, lc($named), $briefing);
		}
	}
	# File the relationships the house is sure of, so they are assembled for the
	# user rather than drawn one at a time; the relational window still takes the
	# rest by hand. The bar is high, so this only ever adds a pair.
	my ($autolinked, $pruned);
	unless ($global || $measure_app) {
		$autolinked = &subs::evaluation_autolink($app, &subs::rightNow() - 60 * 86400000, 8, $around);
		# a condition the app is strongly tied to is a relationship too, but only
		# when the tie stands at the day as well - a thing that merely leans around
		# may be the hour of the clock, not the app
		foreach my $c ( @{$conditions} ) {
			next if (($c->{'confidence'} // '') eq 'around');
			next unless abs($c->{'z'}) >= 2 && defined $c->{'ratio'} && abs($c->{'ratio'} - 1) >= 0.25 && $c->{'n'} >= 8;
			my $rel = &subs::evaluation_relate($app, $c->{'app'});
			push @{$autolinked}, $rel if $rel && !$rel->{'skipped'};
		}
		# and take back the relationships that no longer hold up, the house's own
		# and the ones drawn by hand alike
		$pruned = &subs::evaluation_prune($app, &subs::rightNow() - 60 * 86400000, 4);
	}
	my $report = {
		text => $text || ('The evaluation could not run: ' . $error),
		model => $model,
		machine => $machine,
		depth => $depth,
		windows => [ map { $_->{'name'} } @window_defs ],
		error => $error,
		apps => [ sort keys %mentions ],
		mentions => [ sort keys %mentions ],
		($global ? () : (snapshot => \%snapshot)),
		$linked ? (linked => $linked) : (),
		($autolinked && scalar @{$autolinked} ? (autolinked => [ map { $_->{'app'} } @{$autolinked} ]) : ()),
		($pruned && scalar @{$pruned} ? (pruned => $pruned) : ()),
		timestamp => &subs::rightNow(),
	};
	# a run that could not reach the model must not erase the last report that
	# did: the failed text is still returned to whoever asked, but the house
	# keeps the good report until a run actually answers
	my $previous = &subs::evaluation_report_for($app);
	if (!$error || $previous->{'error'} || !(($previous->{'text'} || '') =~ /\S/)) {
		&subs::cache_set({ app => $app, context => 'evaluation_report', warranty => '-1M' }, $report);
		# the cache lives on the machine that ran the evaluation; a setting is what
		# the rest of the house reads, so the report is written both places
		&subs::setting_setter({ app => $app, setting => 'evaluation_report', value => encode_json($report) });
		# a rolling list of the headlines the house has seen for this scope: a
		# couple of tokens each, and the next run reads it back as continuity
		my $headline = (&subs::evaluation_report_pieces($report))->{'headline'};
		if (($headline || '') =~ /\S/) {
			my @heads = @{ (&subs::evaluation_headline_list($app)) };
			unshift @heads, { timestamp => $report->{'timestamp'}, headline => $headline };
			splice(@heads, 40) if scalar @heads > 40;
			&subs::setting_setter({ app => $app, setting => 'evaluation_headlines', value => encode_json(\@heads) });
		}
	}
	return $report;
}

# the report a scope last produced: the setting is what the whole house can
# read, the cache is where it lived before it travelled
sub evaluation_report_for {
	my ($app) = @_;
	$app = '__president' unless $app && $app ne '';
	my $report = eval { return decode_json(&subs::setting_grabber({ app => $app, setting => 'evaluation_report' }) || '') } || &subs::cache_get({ app => $app, context => 'evaluation_report' }) || {};
	# a run that could not reach the model is not a report, so it is not shown
	# as one: the page reads "no report yet" until a run actually answers (the
	# button still states the error it got live when one is asked for)
	return {} if $report->{'error'};
	return $report;
}

# the rolling headlines a scope has seen, newest first
sub evaluation_headline_list {
	my ($app) = @_;
	$app = '__president' unless $app && $app ne '';
	my $heads = eval { return decode_json(&subs::setting_grabber({ app => $app, setting => 'evaluation_headlines' }) || '') };
	return ref $heads eq 'ARRAY' ? $heads : [];
}

# the report's text, split so that each app name inside it comes back as its
# own piece: the page renders those as links, and format_name drops the
# underscores on the way. The model may write an app the way it is spelled
# (chips_and_granola) or the way it reads (chips and granola), so both forms
# are offered to the match.
sub evaluation_text_chunks {
	my ($report) = @_;
	my $text = ($report->{'text'} || '') . '';
	my @names = grep { $_ && $_ =~ /\w/ } @{ $report->{'mentions'} || [] };
	return [ { text => $text } ] unless scalar @names;
	my %lookup;
	foreach my $name ( @names ) {
		$lookup{ lc $name } = $name;
		my $spaced = $name;
		$spaced =~ s/_/ /g;
		$lookup{ lc $spaced } = $name if $spaced ne $name;
	}
	my $pattern = join '|', map { quotemeta } sort { length($b) <=> length($a) } keys %lookup;
	my @chunks;
	foreach my $piece ( split /(\b(?:$pattern)\b)/i, $text ) {
		next if !defined $piece || $piece eq '';
		if (my $app = $lookup{ lc $piece }) {
			push @chunks, { app => $app, text => &subs::format_name($app) };
		}
		else {
			push @chunks, { text => $piece };
		}
	}
	return \@chunks;
}

# the report as the page wants to show it: a headline first, then the rest -
# split into chunks - that waits behind it. A report told to begin with a
# headline has one on its first line; an older one that opens straight into a
# heading falls back to the first line of that section, shortened.
sub evaluation_report_pieces {
	my ($report) = @_;
	my $text = ($report->{'text'} || '') . '';
	my @lines = split /\n/, $text, -1;
	my ($head_i, $start);
	for my $i (0 .. $#lines) { next if $lines[$i] !~ /\S/; $head_i = $i; last; }
	return { headline => '', chunks => [ { text => $text } ] } unless defined $head_i;
	my $headline = $lines[$head_i];
	$start = $head_i + 1;
	# if the line is nothing but a section heading, a headline was never written
	if ($headline =~ /^\s*(?:trends|correlations|predictions)\s*:?\s*$/i) {
		for my $i ($head_i + 1 .. $#lines) {
			next if $lines[$i] !~ /\S/;
			$headline = $lines[$i];
			$start = $i + 1;
			last;
		}
	}
	# the headline is one glance: hold it to twenty words even when the model
	# writes past the instruction
	my @head_words = split /\s+/, $headline;
	if (scalar @head_words > 20) {
		$headline = join(' ', @head_words[0 .. 19]) . '...';
	}
	if (length($headline) > 200) {
		$headline = substr($headline, 0, 200);
		$headline =~ s/\s+\S*$//;
		$headline .= '...';
	}
	my $body = join "\n", @lines[ $start .. $#lines ];
	return { headline => $headline, chunks => &subs::evaluation_text_chunks({ %{$report}, text => $body }) };
}

1;
