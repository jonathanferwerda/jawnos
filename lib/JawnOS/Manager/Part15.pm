package Manager;

# Manager helpers, part 15 of 37. Moved out of Manager.pl so a
# helper can be read and changed without opening 24k lines. The package is
# still Manager, and lib/JawnOS/Manager/Index.pm maps every sub name here to
# this file; Manager.pm loads it on the first call.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'uninitialized';
no warnings 'once';

use Mojo::Promise;
use Mojo::UserAgent;
use Time::Local;
use Time::Piece;
use Time::Duration;
use Date::Parse;
use Clone qw(clone);
use Mojolicious::Static;
use Mojo::Log;
use Mojo::Transaction::WebSocket;
use Mojo::Parameters;
use Mojo::DOM;
use Mojo::URL;
use Mojo::JSON qw(decode_json encode_json);
use URI::Encode qw(uri_encode uri_decode);
use List::Util qw(shuffle);
use Data::Dumper;
use Mojo::Util qw/md5_sum html_unescape xml_escape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use File::Find;
use File::Slurp;
use File::Type;
use File::Copy;
use POSIX ();
use Fcntl qw(:flock O_CREAT O_EXCL O_WRONLY);
use Number::Format qw/:subs/;
use SQL::Abstract;
use Mojo::SQLite;
use Mojo::IOLoop;

use Mojolicious::Sessions;
use Mojo::Server::Daemon;
use Mojolicious::Renderer;
use Crypt::Simple;
use CryptX;
use HTML::Strip;
use HTML::Parser;
use Data::UUID;
use Storable;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use MIME::Base64;
use Sereal::Encoder qw(encode_sereal SRL_SNAPPY SRL_ZSTD);
use Sereal::Decoder qw(decode_sereal);
use Minion;
use IPC::Open2 qw(open2);

our ($APP, $ws_live_window, $encoder, $decoder, $tuuid, $thread_uuid, $universal_splitter, $database, $sql, $remote_input_clipboard, $config_file, $config, $logfile, $log, $environment, $random_caching_string, $duty_file, $main_process, $device, $user_agent, %time_machine_guide_cache, @media_unlock_apps, %help_search_tables, %media_type_for_ext, %file_relay_down, @appointments, @results, %market_payment_family, @manager_bundle_files, $manager_bundle_cache, $js_minifier, %app_release_sha, %folders_desk_not_app, $jg_body, $remote_input_geometry_at, $remote_input_geometry_cache, %remote_input_ua, %remote_input_ws, %remote_input_rm, %remote_input_ws_failed, $public_ip_memo, $coding_protocols, $coding_protocols_mtime, $app_schema_done, $fingerprint_checked_at, $fingerprint_ok, %padlock_time_memo, %credential_browser_app, %app_gate_shadow_seen, $ws_server, %mailws_untrusted_rate);

sub appt_measure_writer($c,$data) {

	my $app = $data->{'app'};
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();

	my $measure = $data->{'measure'};
	my $value = $data->{'value'};
	my $remote_address = $data->{'remote_address'};
	my $location = $data->{'location'};
	# The observer tags a reading with the physical place it belongs to, so
	# History and a place's deletion can find it even when the rule key is a
	# device that travels.
	my $place = $data->{'place'};
	my $setting_only = $c->param('setting_only');
	my $uuid = $data->{'uuid'};
	my $measure_uuid = md5_sum ($app . '-' . $timestamp) . '-' . md5_sum $timestamp . $app . $measure . $value . $uuid;
	my $settings = &subs::settings_grabber({ app => $app, settings => [ 'app_measures', 'duration', 'seen_measures' ] });
	my $app_measure = eval { return decode_json $settings->{'app_measures'} } || {};
	my %appt_measure = %{$app_measure};
	my $appt_measure = \%appt_measure;

	if ($measure) {

		if ($appt_measure->{$measure}->{'unit'} && ($appt_measure->{$measure}->{'type'} eq 'range' || $appt_measure->{$measure}->{'type'} eq 'number')) {
			if ($value =~ /([a-zA-Z])/gi) {
				my $uom = &subs::format_name($1);
				my $formula = $value . ' to ' . $appt_measure->{$measure}->{'unit'};
				my ($fo,$ev,$format);
				($fo,$ev,$uom,$format) = &formula_calculator($formula);
				$value = eval($ev);
				$value =~ s/[a-zA-Z]//gi;
			}
		}
		elsif ($appt_measure->{$measure}->{'type'} eq 'text') {
			$value = &subs::unformat_name($value);
			my $seen_measures = eval { return decode_json $settings->{'seen_measures'} } || [];
			unless ( grep { $_ eq $value } @{$seen_measures} ) {
				push @{$seen_measures}, $value;
				my $jmeas = encode_json $seen_measures;
				&subs::setting_setter({ app => $app, setting => 'seen_measures', value => $jmeas });
				$settings->{'seen_measures'} = $jmeas;
			}
		}
		if ($appt_measure->{$measure}->{'type'} eq 'range' || $appt_measure->{$measure}->{'type'} eq 'number') {
			# Preserve the sign and read a comma decimal / thousands separator.
			# The old strip-everything-but-digits-and-dots turned -0.5 into 0.5.
			my $normalized = &subs::web_measure_number($value, {
				unit => $appt_measure->{$measure}->{'unit'},
				decimals => $appt_measure->{$measure}->{'decimals'},
			});
			$value = $normalized if defined $normalized;
		}
		$app_measure = { $measure => $value, ts => $timestamp };
		$app_measure->{'location'} = $location if defined $location && length $location;
		$app_measure->{'place'} = $place if defined $place && length $place;

		$appt_measure->{$measure}->{'value'} = $value;

		my $ameasure = encode_json $appt_measure;
		&subs::setting_setter({ app => $app, setting => 'app_measures', value => $ameasure });
	}

	if ( scalar keys %{$app_measure} > 0 && $setting_only ne 'yes') {
		if (!$uuid) {
			my $ago_timestamp = &subs::ago_calc($settings->{'duration'}, $timestamp);
			my $after_timestamp = &subs::ago_calc('-5m', $timestamp);
			my $appt = &subs::db_query('select * from appointments where app=? and type=? and timestamp < ? and timestamp >=? order by timestamp desc limit 1', $app, 'measure',
				$after_timestamp, $ago_timestamp)->hashes->[0];
			if ($appt->{'uuid'} =~ /[A-Za-z0-9]/) {
				$uuid = $appt->{'uuid'};
			}
		}
		my $source_warranty = '';
		if ($uuid) {
			foreach my $am ( keys %{$app_measure} ) {
				$app_measure->{$am} = $appt_measure->{$am}->{'value'};
			}
			$app_measure->{'uuid'} = $measure_uuid;
			$app_measure->{'ts'} = $timestamp || &subs::rightNow();
			$app_measure->{'location'} = $location if defined $location && length $location;
			$app_measure->{'place'} = $place if defined $place && length $place;
			my $ca = &subs::db_select('appointments', undef, { uuid => $uuid, app => $app })->hashes->[0];
			$source_warranty = $ca->{'warranty'} if $ca && defined $ca->{'warranty'} && length $ca->{'warranty'};
			my $car = eval { return decode_json $ca->{'measures'} } || [];
			push @{$car}, $app_measure;
			my $jcar = encode_json $car;
			&subs::db_update('appointments', { measures => $jcar, server_time => &subs::rightNow() }, { uuid => $uuid, app => $app });
		}
		else {
			$app_measure->{'uuid'} = $measure_uuid;
			$app_measure->{'ts'} = &subs::rightNow();
			$app_measure->{'location'} = $location if defined $location && length $location;
			$app_measure->{'place'} = $place if defined $place && length $place;
			my $car = [];
			push @{$car}, $app_measure;
			my $jcar = encode_json $car;
			my $data = {
				app => $app,
				timestamp => $timestamp,
				type => 'measure',
				duration => 1000,
				measures => $jcar,
				uuid => $app_measure->{'uuid'}
			};
			my $appt = &appointment_writer($c,$data);
			$uuid = $appt->{'uuid'};
			$source_warranty = $appt->{'warranty'} if $appt && defined $appt->{'warranty'} && length $appt->{'warranty'};
		}
		my $state = $app_measure->{$measure};
		if ($appt_measure->{$measure}->{'min'} && $appt_measure->{$measure}->{'max'}) {
			my $total = $appt_measure->{$measure}->{'max'} - $appt_measure->{$measure}->{'min'};
			my $state_total = $state - $appt_measure->{$measure}->{'min'};
			$state = $state_total / $total * 100;
		}

		if ($data->{'source'} eq 'embedded') {
			&Websocket::send('tab', { console => &Websocket::console_command('setMeasure', $app, $measure, $app_measure->{$measure})});
		}
		my $adata = { appt_uuid => $uuid, app => $app, type => $appt_measure->{$measure}->{'type'}, 'state' => $state, measurement => $app_measure->{$measure}, measure => $measure, timestamp => $timestamp, remote_address => $remote_address, location => $location };
		&subs::intelligent_automation_toggle($adata);
		&appt_measure_action({ appt_uuid => $uuid, uuid => $app_measure->{'uuid'}, appt_measure => $appt_measure->{$measure}, value => $value, 'state' => $state, measure => $measure, timestamp => $timestamp, location => $location, warranty => $source_warranty })
			unless $data->{'skip_actions'};
		&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', $app, $uuid)});
		&Websocket::send('tab', { console => &Websocket::console_command('continentRecord', { uuid => $uuid, app => $app, purpose => 'app', timestamp => $timestamp, navigation => 'once' })});
		&global_appt_measure_writer({
			app => $app,
			measure => $measure,
			value => $value
		});
	}
	return $uuid;
}

sub global_appt_measure_writer($data) {
	my $measures = eval { return decode_json &subs::setting_grabber({ app => 'measures', setting => 'measures' }) };
	foreach my $m ( keys %{$measures} ) {
		if ($measures->{$m}->{'app'} eq $data->{'app'}) {
			if ($measures->{$m}->{'app_measure'} eq $data->{'measure'}) {
				$measures->{$m}->{'pv'} = $data->{'value'};
				&Websocket::send('tab', { console => &Websocket::console_command('setMeasuresPv', $data->{'app'}, $data->{'measure'}, $data->{'value'})});
			}
		}
	}
	my $jmeasures = encode_json $measures;
	&subs::setting_setter({ app => 'measures', setting => 'measures', value => $jmeasures });
}

sub appt_measure_action($data) {
	my $amcm = $data->{'appt_measure'}->{'cm'} || [];
	my $location = $data->{'location'} // '';
	my $warranty = $data->{'warranty'} // '';
	foreach my $cm ( @{$amcm} ) {
#		next unless $cm->{'match'} && $cm->{'action'};
		# A condition rule can name the place it is about. An empty rule location is
		# the old app's global rule; a rule for the cottage must not fire on the
		# phone's reading.
		my $want_location = $cm->{'location'} // '';
		next if length($want_location) && $want_location ne $location;
		my $actable = 0;
		my $chk = $cm->{'match'};
		if ($cm->{'type'} eq 'match') {
			if ($data->{'state'} =~ /\Q$chk/gi) {
				$actable = 1;
			}
		}
		elsif ($cm->{'type'} eq '==') {
			if ($data->{'state'} == $chk) {
				$actable = 1;
			}
		}
		elsif ($cm->{'type'} eq '<') {
			if ($data->{'state'} < $chk) {
				$actable = 1;
			}
		}
		elsif ($cm->{'type'} eq '<=') {
			if ($data->{'state'} <= $chk) {
				$actable = 1;
			}
		}
		elsif ($cm->{'type'} eq '>') {
			if ($data->{'state'} > $chk) {
				$actable = 1;
			}
		}
		elsif ($cm->{'type'} eq '>=') {
			if ($data->{'state'} >= $chk) {
				$actable = 1;
			}
		}
		elsif ($cm->{'type'} eq 'eq') {
			if ($data->{'state'} eq $chk) {
				$actable = 1;
			}
		}
		my $tog = &subs::setting_grabber({ app => $cm->{'app'}, setting => 'toggle' });
		if ($actable == 1) {

			my $awdata = {
				app => $cm->{'app'},
				timestamp => $data->{'timestamp'},
				type => $cm->{'action'},
				source_uuid => $data->{'appt_uuid'},
				subtype => 'measure',
				(length $warranty ? (warranty => $warranty) : ()),
				uuid => $data->{'appt_uuid'} . '-' . $data->{'timestamp'} . '-' . md5_sum $cm->{'app'} . $data->{'timestamp'} . $cm->{'action'}
			};
			if ($tog eq 'off') {
				&subs::setting_setter({ app => $cm->{'app'}, setting => 'toggle', value => 'on', timestamp => $data->{'timestamp'} });
				# The toggle is per machine, but the open session is the house's.
				# A second reading must not start what is already running.
				my $open = eval { &subs::open_session_uuid($cm->{'app'}) } || '';
				&appointment_writer(undef, $awdata) unless $open;
			}
		}
		else {
			if ($cm->{'action'} eq 'start' || $cm->{'action'} eq 'record') {
				my $awdata = {
					app => $cm->{'app'},
					type => 'stop',
					source_uuid => $data->{'appt_uuid'},
					subtype => 'measure',
					(length $warranty ? (warranty => $warranty) : ()),
				};
				if ($tog eq 'on') {
					&appointment_writer(undef, $awdata);
					&subs::setting_setter({ app => $cm->{'app'}, setting => 'toggle', value => 'off', timestamp => $data->{'timestamp'} });
				}
			}
		}
	}
}

sub inventory_cell_summary($data) {
	my $app = $data->{'app'};
	my $scope = &subs::timespan_widener($data->{'scope'} || '') || 'week';
	my $zone = $data->{'zone'} || 'this';
	my $settings = &subs::settings_grabber({ app => $app });
	my $display = $settings->{'s_display'} || 'occurences';
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my ($start, $end) = ($data->{'start'}, $data->{'end'});
	unless ($start && $end) {
		($start, $end) = &father_time({ scope => $scope, ts => $zone, lock => $settings->{'s_lock'}, timestamp => $timestamp });
	}
	my $appts;
	my $value;
	if ($display eq 'duration') {
		# a session that crossed the edge of this window spent part of its time in
		# it even though it started before the window began
		$appts = &subs::db_query("select * from appointments where (app = ? or model = ?) and cast(timestamp as integer) < ? and (cast(timestamp as integer) >= ? or type in ('start','record') or (cast(timestamp as integer) + abs(cast(coalesce(duration,0) as real))) > ?) order by timestamp", $app, $app, $end, $start, $start)->hashes;
		$value = &inventory_window_value($appts, $display, $settings, $start, $end, $timestamp);
	}
	else {
		$appts = &subs::db_query('select * from appointments where (app = ? or model = ?) and cast(timestamp as integer) >= ? and cast(timestamp as integer) < ? order by timestamp', $app, $app, $start, $end)->hashes;
		$value = &inventory_window_value($appts, $display, $settings);
	}
	my $format = sub {
		my $n = shift;
		return '-' unless defined $n;
		return &subs::duration_sayer($n / 1000) if $display eq 'duration';
		return &subs::price_formatter($n) if $display eq 'total';
		return sprintf('%.1f', $n);
	};
	# the budget this cell is held against, and the pace when it is the period now
	# running - the same reading the inventory cell and its colour come from
	my $budget;
	if ($settings->{'budget'} && $settings->{'budget'} =~ /[0-9]/) {
		my $b = &budget_calculator({
			app => $app, budget => $settings->{'budget'}, circumstance => $display,
			value => $value, scope => $scope, ts => $zone, settings => $settings
		});
		if ($b->{'budgeted'} && ($b->{'circumstance'} || '') eq $display) {
			$budget = {
				budgeted => $b->{'formatted_budgeted'},
				status => $b->{'status'},
				($zone eq 'this' && defined $b->{'elapsed'} && $b->{'elapsed'} < 1 ? (
					on_track => $b->{'on_track'},
					progress_percent => $b->{'progress'},
					due_by_now => $b->{'formatted_on_target'},
					projected => $b->{'formatted_projected'},
				) : ()),
			};
		}
	}
	# the recent periods of the same clock, so the reading can say rising or falling
	my $trends = &subs::evaluation_period_trends($app, 8);
	# what the number was made of: the appointment types that ran in the window
	my $made = &subs::db_query('select type, count(*) as c from appointments where (app = ? or model = ?) and cast(timestamp as integer) >= ? and cast(timestamp as integer) < ? group by type order by c desc', $app, $app, $start, $end)->hashes;
	my @made_of = map { { type => ($_->{'type'} || 'record'), count => ($_->{'c'} + 0) } } @{$made}[0 .. ($#{$made} > 4 ? 4 : $#{$made})];
	my $briefing = {
		app => $app,
		scope => $scope,
		period => &subs::formatted_time($start) . ' to ' . &subs::formatted_time($end),
		period_is_current => ($zone eq 'this' ? 1 : 0),
		measure => $display,
		value => $format->($value),
		($budget ? (budget => $budget) : ()),
		($trends->{$scope} ? (recent_periods_counts => $trends->{$scope}) : ()),
		(scalar @made_of ? (made_of => \@made_of) : ()),
	};
	my $system = 'You summarise one period of one app\'s activity for someone glancing at a single statistic in JawnOS, a house that logs its life as timed appointments. A briefing follows: the app, the clock the period is on (scope: minute, hour, day, week, month or year), the period itself and whether it is the one now running (period_is_current), the measure the cell shows (measure) and its value, the budget if the app keeps one (budgeted, plus on_track, progress_percent, due_by_now and projected when the period is current), the recent counts of the same clock (recent_periods_counts, oldest first, the newest written count/percent so a part-run period is not read as a fall), and what the activity was made of (made_of: the appointment types that ran and how many). Write two to four short sentences, plain and specific, no headings, no bullets and no preamble: what the value is; whether it is on track for its budget, reading the pace when the period is current; how it sits against the recent periods (rising, falling, steady), naming the turn if there is one; and what most made up the number. Do not restate the labels or the raw figures as a list - say what they mean. Use only the numbers given.';
	my $model = &subs::setting_grabber({ app => 'mail', setting => 'eval_assistant' });
	my ($text, $error);
	# a cell summary is a glance at a number, not a conversation: a model failure
	# falls back to the plain sentence and must not speak on the device
	local $subs::say_quiet = 1;
	if ($model && &subs::evaluation_agent_ready()) {
		($text, $error) = &subs::evaluation_model_call_role('eval_assistant', $system, encode_json($briefing), &subs::ai_role_thinking_effective('eval_assistant'));
	}
	elsif ($model) {
		$error = 'no evaluation agent is reachable from this machine';
	}
	else {
		$error = 'no evaluation model is chosen';
	}
	unless ($text) {
		# a plain fallback the panel can always show when the model is away
		$text = 'This ' . $scope . ' shows ' . $format->($value) . '.';
		if ($budget) {
			$text .= ' The budget is ' . $budget->{'budgeted'} . '.';
			$text .= ' On track: ' . $budget->{'on_track'} . ' (' . $budget->{'progress_percent'} . '% in; ' . $budget->{'due_by_now'} . ' due, projecting ' . $budget->{'projected'} . ').' if defined $budget->{'on_track'};
		}
		$text .= ' Recent periods, oldest first: ' . $trends->{$scope} . '.' if $trends->{$scope};
		$text .= ' Mostly ' . join(', ', map { $_->{'type'} . ' x' . $_->{'count'} } @made_of) . '.' if scalar @made_of;
	}
	return { summary => $text, error => $error, briefing => $briefing };
}

sub next_local_midnight {
	my $ms = shift;
	my @lt = localtime(int($ms / 1000));
	my ($mday, $mon, $year) = @lt[3, 4, 5];
	my @days = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
	my $y = $year + 1900;
	$days[1] = 29 if ($y % 4 == 0 && ($y % 100 != 0 || $y % 400 == 0));
	$mday++;
	if ($mday > $days[$mon]) {
		$mday = 1;
		$mon++;
		if ($mon > 11) { $mon = 0; $year++; }
	}
	return timelocal(0, 0, 0, $mday, $mon, $year) * 1000;
}

sub allocation_duration_add {
	my ($returner, $appt, $display, $display_options) = @_;
	my $from = ($appt->{'timestamp'} || 0) + 0;
	my $to = $from + abs($appt->{'duration'} || 0);
	return if $to <= $from;

	my $add = sub {
		my ($scope, $key, $amount) = @_;
		return unless defined $key && $amount > 0;
		my $bucket = $returner->{$key}->{$scope} ||= {};
		$bucket->{$display} = ($bucket->{$display} || 0) + $amount;
		$bucket->{'formatted_duration'} = &subs::duration_sayer($bucket->{$display} / 1000) if $display eq 'duration';
		foreach my $d ( @{$display_options || []} ) {
			my $name = $d->{'name'};
			my $value = $bucket->{$name};
			if ($value > $returner->{'highest'}->{$scope}->{$name}) {
				$returner->{'highest'}->{$scope}->{$name} = $value;
			}
			elsif ($returner->{'highest'}->{$scope}->{$name} == undef) {
				$returner->{'highest'}->{$scope}->{$name} = $value;
			}
			if ($value < $returner->{'lowest'}->{$scope}->{$name}) {
				$returner->{'lowest'}->{$scope}->{$name} = $value;
			}
			elsif ($returner->{'lowest'}->{$scope}->{$name} == undef) {
				$returner->{'lowest'}->{$scope}->{$name} = $value;
			}
		}
	};

	if ($to - $from > 366 * 86400000) {
		my @lt = localtime(int($from / 1000));
		my %key = (
			second => $lt[0], minute => $lt[1], hour => $lt[2],
			mday => $lt[3], month => $lt[4] + 1, year => $lt[5] + 1900,
			wday => $lt[6], yday => $lt[7], isdst => $lt[8]
		);
		foreach my $scope ( qw/second minute hour mday month year wday yday isdst/ ) {
			$add->($scope, $key{$scope}, $to - $from);
		}
		return;
	}

	foreach my $cycle ( [ 'second', 60, 1000 ], [ 'minute', 3600, 60000 ] ) {
		my ($scope, $values, $step) = @{$cycle};
		my $period = $values * $step;
		my $full = int(($to - $from) / $period);
		for (my $v = 0; $full > 0 && $v < $values; $v++) {
			$add->($scope, $v, $full * $step);
		}
		my $cursor = $from + $full * $period;
		while ($cursor < $to) {
			my $next = int($cursor / $step) * $step + $step;
			my $end = $next < $to ? $next : $to;
			$add->($scope, int($cursor / $step) % $values, $end - $cursor);
			$cursor = $end;
		}
	}

	# hour of day and daylight saving change at the top of a local hour
	my $cursor = $from;
	while ($cursor < $to) {
		my @lt = localtime(int($cursor / 1000));
		# the time already spent in this local hour, taken off the clock rather
		# than rebuilt with timelocal, so an hour that daylight saving repeats or
		# skips still steps one real hour and never asks for hour 24
		my $elapsed = $lt[1] * 60000 + $lt[0] * 1000 + ($cursor % 1000);
		my $next = $cursor - $elapsed + 3600000;
		$next = $cursor + 3600000 if $next <= $cursor;
		my $end = $next < $to ? $next : $to;
		$add->('hour', $lt[2], $end - $cursor);
		$add->('isdst', $lt[8], $end - $cursor);
		$cursor = $end;
	}

	# the calendar components change at local midnight
	$cursor = $from;
	while ($cursor < $to) {
		my @lt = localtime(int($cursor / 1000));
		my $next = &next_local_midnight($cursor);
		$next = $cursor + 86400000 if $next <= $cursor;
		my $end = $next < $to ? $next : $to;
		$add->('mday', $lt[3], $end - $cursor);
		$add->('month', $lt[4] + 1, $end - $cursor);
		$add->('year', $lt[5] + 1900, $end - $cursor);
		$add->('wday', $lt[6], $end - $cursor);
		$add->('yday', $lt[7], $end - $cursor);
		$cursor = $end;
	}
}

sub inventory_window_value($appts, $display, $settings, $start, $end, $view_now) {
	my $value = 0;
	my $now = $view_now || &subs::rightNow();
	foreach my $a ( @{$appts} ) {
		if ($display eq 'occurences') { $value += 1; }
		elsif ($display eq 'duration') {
			my $d = abs($a->{'duration'} || 0);
			$d = $now - $a->{'timestamp'} if ($a->{'type'} eq 'start' || $a->{'type'} eq 'record') && $a->{'timestamp'} && $a->{'timestamp'} < $now;
			if (defined $start && defined $end) {
				my $copy = { %{$a}, duration => $d };
				$d = &appointment_overlap($copy, $start, $end);
			}
			$value += $d;
		}
		elsif ($display eq 'total') { $value += abs($a->{'total'} || 0); }
		elsif ($display eq 'quantity') { $value += abs($a->{'quantity'} || 0); }
		else {
			my $measures = eval { decode_json $a->{'measures'} } || [];
			foreach my $m ( @{$measures} ) {
				$value += $m->{$display} if defined $m->{$display} && $m->{$display} =~ /[0-9]/;
			}
		}
	}
	return $value;
}

1;
