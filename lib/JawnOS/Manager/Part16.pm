package Manager;

# Manager helpers, part 16 of 37. Moved out of Manager.pl so a
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
use Mojo::IOLoop::ReadWriteFork;
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
use IO::Socket::UNIX;
use IPC::Open2 qw(open2);

our ($APP, $ws_live_window, $encoder, $decoder, $tuuid, $thread_uuid, $universal_splitter, $database, $sql, $remote_input_clipboard, $config_file, $config, $logfile, $log, $environment, $random_caching_string, $duty_file, $main_process, $device, $user_agent, %time_machine_guide_cache, @media_unlock_apps, %help_search_tables, %media_type_for_ext, %file_relay_down, @appointments, @results, %market_payment_family, @manager_bundle_files, $manager_bundle_cache, $js_minifier, %app_release_sha, %folders_desk_not_app, $jg_body, $remote_input_geometry_at, $remote_input_geometry_cache, %remote_input_ua, %remote_input_ws, %remote_input_rm, %remote_input_ws_failed, $public_ip_memo, $coding_protocols, $coding_protocols_mtime, $app_schema_done, $fingerprint_checked_at, $fingerprint_ok, %padlock_time_memo, %credential_browser_app, %app_gate_shadow_seen, $ws_server, %mailws_untrusted_rate);

sub inventory_details($c,$settings) {
	my $app = $c->param('app');
	my $server_time = &subs::rightNow();
	my $timestamp = $c->param('timestamp');
	# The windows are built from this request's moment, so a running session is
	# read to that moment too. Using the later server time left a sliver of the
	# session past every "Nnext" window's opening edge, which put a second or so
	# of duration on every future scope.
	my $view_now = ($timestamp && $timestamp =~ /^[0-9]+$/) ? $timestamp : $server_time;
	my $appts = [];
	if ($c->param('display')) {
		$settings->{'s_display'} = $c->param('display');
		$settings->{'s_movement'} = $c->param('movement');
		$settings->{'s_scope_count'} = $c->param('scope_count');
		$settings->{'s_visual'} = $c->param('visual');
		$settings->{'s_calc'} = $c->param('calc');
		$settings->{'s_lock'} = $c->param('lock');
	}
	# the canvas a walk happened on lends its unit to the page button: the fresh
	# gesture carries it on the request, the setting keeps it for the loads after
	my $page_scope = $c->param('page_scope') || $settings->{'s_page_scope'} || '';

	unless ($settings->{'s_display'}) {
		&subs::setting_setter({ app => $app, setting => 's_display', value => 'occurences'});
		$settings->{'s_display'} = 'occurences';
	}
	my $s_display = $settings->{'s_display'};
	$settings->{'s_movement'} = eval { decode_json $settings->{'s_movement'} } || ['all'];
	$appts = &subs::db_query('select * from appointments where app = ? or model = ? order by timestamp', $app, $app)->hashes;
	my $movements = [ 'all' ];
	my %movement_seen = ( all => 1 );
	foreach my $a ( @{$appts} ) {
		push @{$movements}, $a->{'type'} unless $movement_seen{$a->{'type'}}++;
	}
	push @{$movements}, 'start' unless $movement_seen{'start'};
	if ($settings->{'s_movement'} == undef || grep { $_ eq 'all' } @{$settings->{'s_movement'}} ) {
	}
	else {
		my $new_appts = [];
		foreach my $sm ( @{$settings->{'s_movement'}} ) {
			push @{$new_appts}, grep { $_->{'type'} eq $sm } @{$appts};
		}
		$appts = $new_appts;
	}
	my @display_options;
	foreach my $k ( keys %{$gb::budget_modes} ) {
		my $formatted_name = &subs::format_name($k);
		if ($k eq 'quantity') {
			$formatted_name = $formatted_name . ' (' . $settings->{'unit'} . ')';
		}
		my $bm = { name => $k, formatted_name => $formatted_name };
		push @display_options, $bm;

	}
	my $am = eval { return decode_json $settings->{'app_measures'} } || {};
	foreach my $ameas ( keys %{$am} ) {
		my $formatted_name = &subs::format_name($ameas);
		if ($am->{$ameas}->{'unit'}) {
			$formatted_name = $formatted_name . ' (' . $am->{$ameas}->{'unit'} . ')';
		}
		push @display_options, { name => $ameas, formatted_name => $formatted_name } unless grep { $_->{'name'} eq $ameas } @display_options;
	}
	# A measure remembers its own reading: steps is summed, weight averaged. The
	# app's s_calc is only the fallback for one that was never set, and while a
	# measure is displayed its own calc is the one in force - so the statistic, the
	# budget and the panel all agree without re-picking. measure_calc_json rides
	# out to the calc select, so the client knows which ones are measures.
	my %measure_calc;
	foreach my $ameas ( keys %{$am} ) {
		my $mc = &subs::setting_grabber({ app => $app, setting => 'measure_calc', subsetting => $ameas });
		$mc = $settings->{'s_calc'} unless (defined $mc && length $mc);
		$mc = 'sum' unless (defined $mc && length $mc);
		$measure_calc{$ameas} = $mc;
	}
	$settings->{'s_calc'} = $measure_calc{$s_display} if defined $measure_calc{$s_display};
	my $is_measure = defined $measure_calc{$s_display};
	my $measure_calc_json = encode_json(\%measure_calc);

	my @time_scopes;
	my @time_widths;
	my $scope_page = 0;
	my $scope_page_max = 24;

	my @time_lengths = qw/minute hour day week month year/;
	if ($settings->{'s_visual'} eq 'allocation') {
		@time_scopes = undef;
		for (my $n = 0; $n <= 366; $n++) {
			push @time_scopes, $n;
		}
		@time_lengths = qw/second minute hour mday month year wday yday isdst/;
		@time_widths = ( 60, 60, 24, 31, 12, 150, 7, 365, 2 );
	}
	else {
		# the page of periods the rows cover: now first, then the blocks before
		# it (or the ones past next) as a graph is scrolled sideways
		$scope_page = $settings->{'s_scope_page'} || 0;
		$scope_page = $scope_page_max if $scope_page > $scope_page_max;
		$scope_page = -$scope_page_max if $scope_page < -$scope_page_max;
		@time_scopes = &subs::time_scope_page({ count => $settings->{'s_scope_count'} || 30, page => $scope_page });
	}

	if ($c->param('scope')) {
		my $scope = &subs::unformat_name($c->param('scope'));
		my $return_n = 0;
		for ( my $n = 0; $n <= scalar @time_lengths; $n++ ) {
			if ( $time_lengths[$n] eq $scope ) { $return_n = $n - 1; }
			if ($c->param('zone')) {
				if ($return_n > 1) {
					my @timey_widths = ( 60, 24, 7, 30, 12, 10 );
					@time_scopes = ('this','last');
					push @time_widths, $timey_widths[$return_n];
					for (my $n = 2; $n <= $timey_widths[$return_n]; $n++) {
						push @time_scopes, $n . 'last';
					}

				}
			}
		}
		@time_lengths = grep { $_ eq $time_lengths[$return_n] } @time_lengths;
	}
	# when the app happens, as profiles for the "when" wheel: by the hour of the
	# day and by the day of the week, read off the appointments themselves
	my @hour_profile = (0) x 24;
	my @weekday_profile = (0) x 7;
	foreach my $a ( @{$appts} ) {
		next unless ($a->{'timestamp'} || '') =~ /[0-9]/;
		my @lt = localtime( ($a->{'timestamp'} + 0) / 1000 );
		$hour_profile[$lt[2]]++;
		$weekday_profile[$lt[6]]++;
	}
	my @revised_time_scopes = @time_scopes;
	my $returner = {
		longest => $appts->[0],
		shortest => $appts->[0],
		betweens => [],
		between_total => 0,
		between_average => 0,
		longest_between => {},
		shortest_between => {},
		first_seen => $appts->[0],
		'last_seen' => $appts->[0],
		first_recorded => {},
		last_recorded => {},
		average_duration => 0,
		total_duration => 0,
		total_occurences => 0,
		settings => $settings,
		scopes => \@time_scopes,
		time_lengths => \@time_lengths,
		time_widths => \@time_widths,
		timestamp => $timestamp,
		scope_page => $scope_page,
		scope_page_max => $scope_page_max,
		page_scope => $page_scope,
		app => $app,
		hour_profile => \@hour_profile,
		weekday_profile => \@weekday_profile,
		budget_status => {},
	};
	my $bmt = scalar grep { $_ eq $s_display } keys %{$gb::budget_modes};
	# duration_sayer re-parses and re-formats its argument on every call, but the
	# window loops ask for the same handful of values thousands of times
	my %duration_sayer_cache;
	my $duration_sayer = sub {
		my $value = shift;
		my $key = defined $value ? $value : '';
		return $duration_sayer_cache{$key} if exists $duration_sayer_cache{$key};
		return $duration_sayer_cache{$key} = &subs::duration_sayer($value);
	};
	# measures only feed the two custom-measure paths below, so the JSON decode can
	# be skipped entirely for the budget-mode displays
	my $measures_required = ($settings->{'s_visual'} eq 'allocation') || ($bmt == 0);

	if ( scalar @{$appts} > 0 ) {
		# the time windows only depend on the request timestamp, so they are computed
		# once here instead of calling father_time for every appointment
		my @time_windows;
		if ($settings->{'s_visual'} eq 'historical' || $settings->{'s_visual'} eq '') {
			foreach my $ts (@time_scopes) {
				foreach my $scope (@time_lengths) {
					my ($bt, $temp_timestamp) = &father_time({
						scope => $scope,
						ts => $ts,
						lock => $settings->{'s_lock'},
						timestamp => $timestamp
					});
					push @time_windows, [ $ts, $scope, $bt, $temp_timestamp ];
				}
			}
		}
		# constant time membership test for measures promoted to their own appointment
		my %appt_uuids;
		$appt_uuids{$_->{'uuid'}} = 1 for @{$appts};
		foreach my $a ( @{$appts} ) {
			if ($measures_required && $a->{'measures'} && !$a->{'measure_dejsonified'}) {
				$a->{'measures'} = eval { return decode_json $a->{'measures'} } || [];
				$a->{'measure_dejsonified'} = 1;
			}
			if (($a->{'type'} eq 'start' || $a->{'type'} eq 'record')) {
				if ($a->{'timestamp'} < $view_now) {
					$a->{'duration'} = $view_now - $a->{'timestamp'};
				}
				else {
					$a->{'duration'} = &subs::time_abbrev_translator($settings->{'duration'});
				}
			}
			$a->{'duration'} = abs $a->{'duration'};
			# where the session ends: read once so a window that cannot overlap it
			# costs only the two comparisons below
			my $ends_at = ($a->{'timestamp'} || 0) + ($a->{'duration'} || 0);
			if (($s_display eq 'total') && ($a->{'total'} == 0 || $a->{'total'} == undef)) {
				next;
			}
			if ($settings->{'s_visual'} eq 'historical' || $settings->{'s_visual'} eq '') {
				foreach my $window (@time_windows) {
					# half open [bt, tt): an instant on an edge belongs to the window
					# it opens, so the windows never overlap and never leave a gap
					my $starts_here = ($a->{'timestamp'} >= $window->[2] && $a->{'timestamp'} < $window->[3]);
					# A session that runs over a period's edge belongs to both periods:
					# its occurrence stays with the one it started in, but its time is
					# counted where it was actually spent. Other readings are instants and
					# stay in the window they open.
					my $overlap = 0;
					if ($s_display eq 'duration' && $a->{'timestamp'} < $window->[3] && $ends_at > $window->[2]) {
						$overlap = &appointment_overlap($a, $window->[2], $window->[3]);
					}
					next unless $starts_here || $overlap > 0;
					{
						# only unpack the matching windows: unpacking all of them is most of
						# what this loop spends its time on
						my ($ts, $scope, $bt, $temp_timestamp) = @{$window};
						# ||= creates the bucket: a plain read of the chain would leave it undef
						my $bucket = $returner->{$ts}->{$scope} ||= {};
						if ($a->{'measures'} && $bmt == 0 ) {

							foreach my $measure ( @{$a->{'measures'}} ) {
								unless ($measure->{$s_display} || $measure->{$s_display} == 0) {
									last;
								}
								foreach my $mk ( grep { $_ ne 'uuid' } keys %{$measure} ) {

									if ($measure->{'ts'} && $measure->{'ts'} ne '') {
										$measure->{'timestamp'} = $measure->{'ts'};
										delete $measure->{'ts'};
									}
									# out once tt arrives, to match the appointment test above
									if (($measure->{'timestamp'} < $bt || $measure->{'timestamp'} >= $temp_timestamp) && $s_display eq $mk) {

										unless ($appt_uuids{$measure->{'uuid'}}) {
											my $new_measure = {
												app => $a->{'app'},
												timestamp => $measure->{'timestamp'} || $measure->{'ts'},
												type => 'measure',
												uuid => $measure->{'uuid'},
												measures => encode_json [ $measure ],
											};
											push @{$appts}, $new_measure;
											$appt_uuids{$new_measure->{'uuid'}} = 1;
										#	@{$a->{'measures'}} = grep { $_->{'uuid'} ne $measure->{'uuid'} } @{$a->{'measures'}};
											next;
										}
										$measure = undef;
									}
									else {
										if (($measure->{$mk} || $measure->{$mk} == 0) && $measure->{$s_display}  eq $measure->{$mk}) {

											$bucket->{$mk . '_occurences'} += 1;
											if ($settings->{'s_calc'} eq 'average' ) {
												$bucket->{'t_' . $mk} += $measure->{$mk};
												my $sprinter = "%.2f";
												if ($measure->{$mk} < 1 && $measure->{$mk} > -1) {
													$sprinter = "%.4f";
												}

												# a zero measure is an average like any other: the divisor
												# is how many it has seen, never the measure itself
												$bucket->{$mk} = sprintf($sprinter, $bucket->{'t_' . $mk} / $bucket->{$mk . '_occurences'});
												$bucket->{$mk} = 0 unless defined $bucket->{$mk};
											}
											elsif ($settings->{'s_calc'} eq 'high') {
												$bucket->{$mk} = $measure->{$mk} unless $bucket->{$mk};

												if ($measure->{$mk} > $bucket->{$mk}) {
													$bucket->{$mk} = $measure->{$mk};
												}
											}
											elsif ($settings->{'s_calc'} eq 'low') {
												$bucket->{$mk} = $measure->{$mk} unless $bucket->{$mk};
												if ($measure->{$mk} < $bucket->{$mk}) {
													$bucket->{$mk} = $measure->{$mk};
												}
											}
											else {
												$bucket->{$mk} += $measure->{$mk};# if $measure->{$mk} != undef;

											}
											$returner->{'total'}->{$scope}->{$mk} += 1;
										}
									}
								}
							}
						}
						elsif ($bmt > 0) {

							if ($s_display eq 'quantity') {
								if ($a->{'unit'} ne $settings->{'unit'}) {
									my $neg = 0;
									if ($a->{'quantity'} < 0) { $neg = 1; }
									$a->{'quantity'} = abs $a->{'quantity'};
									my ($formula,$evaluation,$uom,$format) = &formula_calculator($a->{'quantity'} . $a->{'unit'} . ' to ' . $settings->{'unit'});
									$a->{'quantity'} = $evaluation unless $evaluation == 0;
									$a->{'quantity'} = (abs $a->{'quantity'}) * -1 if $neg == 1;
									$a->{'unit'} = $settings->{'unit'} unless $evaluation == 0;
								}
							}

							my $amount = ($s_display eq 'duration') ? $overlap : $a->{$s_display};

							if ($settings->{'s_calc'} eq 'average' ) {
								$bucket->{'t_' . $s_display} += $amount;
								$bucket->{'c_' . $s_display} += 1;
								my $sprinter = "%.2f";
								if ($amount < 1 && $amount > -1) {
									$sprinter = "%.4f";
								}
								$bucket->{$s_display} = sprintf($sprinter, $bucket->{'t_' . $s_display} / $bucket->{'c_' . $s_display});
								if ($bucket->{$s_display} == 0) {
									$bucket->{$s_display} = 0;
								}
							}
							elsif ($settings->{'s_calc'} eq 'high') {
								$bucket->{$s_display} = 0 unless $bucket->{$s_display};
								if ($amount > $bucket->{$s_display}) {
									$bucket->{$s_display} = $amount;
								}
							}
							elsif ($settings->{'s_calc'} eq 'low') {
								$bucket->{$s_display} = $amount unless $bucket->{$s_display};
								if ($amount < $bucket->{$s_display}) {
									$bucket->{$s_display} = $amount;
								}
							}
							else {
								$bucket->{$s_display} += $amount unless $s_display eq 'occurences';
							}
						}
						$bucket->{'timestamp'} = $a->{'timestamp'} if $starts_here;
						$bucket->{'occurences'} += 1 if $starts_here;# unless $s_display eq 'occurences';
						$a->{'occurences'} = 1;

						$bucket->{'formatted_duration'} = $duration_sayer->((abs $bucket->{'duration'}) / 1000);
				#		$bucket->{'total'} += abs $a->{'total'} if $a->{'total'};
				#		$bucket->{'amount'} += abs $a->{'amount'} if $a->{'amount'};
						# the "Nnext" windows reach past this period from the request on,
						# so they hold what it and "next" hold again, and the per period
						# totals and average leave them out
						if ($ts !~ /^[0-9]+next/) {
							my $contribution = ($s_display eq 'duration') ? $overlap : abs $a->{$s_display};
							$returner->{'total'}->{$scope}->{$s_display} += $contribution;
							$returner->{'count'}->{$scope}->{$s_display} += 1;
							$returner->{'average'}->{$scope}->{$s_display} = sprintf("%.2f", $returner->{'total'}->{$scope}->{$s_display} / $returner->{'count'}->{$scope}->{$s_display});
						}
						# a measure reads its budget value from its own calc (sum or average),
						# not only when the display is summed; a base reading still wants sum
						if ($settings->{'budget'} && $bucket->{$s_display} != 0 && ($settings->{'s_calc'} eq 'sum' || $is_measure)) {
							unless ($returner->{'autocalc'}) {
								$returner->{'autocalc'} = &subs::cache_get({ app => $returner->{'app'}, context => 'autocalc', subcontext => $s_display });
							}
							my $budget = &budget_calculator({
								app => $returner->{'app'},
								budget => $settings->{'budget'},
								circumstance => $s_display,
								value => $bucket->{$s_display},
								scope => $scope,
								ts => $ts,
								appts => $appts,
								settings => $settings
							});

							if ($bucket->{$s_display} && $ts eq 'this' &&
								&subs::timespan_widener($budget->{'scope_name'}) eq &subs::timespan_widener($scope) && $budget->{'is_scope'} eq 'yes' &&
									$s_display eq $budget->{'circumstance'}) {

								$returner->{'cachable'} = $budget if $budget->{'colour'};
							}


							$bucket->{'budget'} = $budget;
							$returner->{'budgets'} = $budget->{'budgets'};
							$returner->{'budget_status'}->{$scope}->{$s_display}->{'expected'} += $budget->{'expected'};
							$returner->{'budget_status'}->{$scope}->{$s_display}->{'actual'} += $budget->{'actual'};

							$returner->{'budget_status'}->{$scope}->{$s_display} = &budget_status_maker($returner->{'budget_status'}->{$scope}->{$s_display});
						}

						if ($s_display eq 'occurences') {
							$returner->{'average'}->{$scope}->{$s_display} = sprintf("%.2f", $returner->{'total'}->{$scope}->{$s_display} / scalar grep { $_ !~ /^[0-9]+next/ } @time_scopes);
						}
						foreach my $d ( @display_options ) {
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
							$bucket->{'start_timestamp'} = $bt;
							$bucket->{'end_timestamp'} = $temp_timestamp;

						}
					}
				}
			}
			elsif ($settings->{'s_visual'} eq 'allocation') {
				my @localtime = localtime($a->{'timestamp'} / 1000);
				if ($a->{'measures'}) {
					foreach my $measure ( @{$a->{'measures'}} ) {
						foreach my $mk ( keys %{$measure} ) {
							unless ($measure->{$s_display} || $measure->{$s_display} == 0) {
								last;
							}

							if (!$measure->{'uuid'}) {
								$measure->{'uuid'} = &subs::random_string_creator(15);
							}
							if ($measure->{'ts'} && $measure->{'ts'} ne '') {
								$measure->{'timestamp'} = $measure->{'ts'};
								delete $measure->{'ts'};
							}

							if ($s_display eq $mk) {
								unless ($appt_uuids{$measure->{'uuid'}}) {
									my $new_measure = {
										app => $a->{'app'},
										timestamp => $measure->{'timestamp'} || $measure->{'ts'},
										type => 'measure',
										uuid => $measure->{'uuid'} || &subs::random_string_creator(8),
										$mk => $measure->{$s_display},
										measures => encode_json [ $measure ],
									};
									push @{$appts}, $new_measure;
									$appt_uuids{$new_measure->{'uuid'}} = 1;
									undef $a;
								}
								$measure = undef;
							}
						}
					}
				}
				next unless $a->{'uuid'};
				# a split duration has already been added to every component the
				# session touched, so the start bucket takes only its occurrence
				my $split_duration = ($s_display eq 'duration' && ($settings->{'s_calc'} || 'sum') eq 'sum');
				&allocation_duration_add($returner, $a, $s_display, \@display_options) if $split_duration;
				for (my $n = 0; $n <= scalar @time_lengths; $n++) {
					if (($a->{$s_display} || $a->{$s_display} == 0) || ( $bmt > 0 )) {
						my $scope = $time_lengths[$n];
						my $ts = $localtime[$n];
						if ($scope eq 'month') { $ts += 1; }
						if ($scope eq 'year') { $ts += 1900; }
						my $bucket = $returner->{$ts}->{$scope} ||= {};
					#	if ($scope eq 'wday') { $ts += 1; }
						$bucket->{'occurences'} += 1;
						if ($settings->{'s_calc'} eq 'average' ) {
							$bucket->{'t_' . $s_display} += $a->{$s_display};
							$bucket->{$s_display} = sprintf("%.2f", $bucket->{'t_' . $s_display} / $bucket->{'occurences'});
							if ($bucket->{$s_display} == 0) {
								$bucket->{$s_display} = 0;
							}
						}
						elsif ($settings->{'s_calc'} eq 'high') {
							$bucket->{$s_display} = $a->{$s_display} unless $bucket->{$s_display};
							if ($a->{$s_display} > $bucket->{$s_display}) {
								$bucket->{$s_display} = $a->{$s_display};
							}
						}
						elsif ($settings->{'s_calc'} eq 'low') {
							$bucket->{$s_display} = $a->{$s_display} unless $bucket->{$s_display};
							if ($a->{$s_display} < $bucket->{$s_display}) {
								$bucket->{$s_display} = $a->{$s_display};
							}
						}
						else {
							$bucket->{$s_display} += $a->{$s_display} unless $split_duration;

						}
						$bucket->{'formatted_duration'} = $duration_sayer->((abs $bucket->{'duration'}) / 1000);
						$bucket->{'total'} += $a->{'total'};
						unless ($bmt > 0) {
							#$bucket->{$s_display} += $a->{$s_display};
						}

						foreach my $d ( @display_options ) {
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
					}
				}
			}
			if (abs $a->{'duration'} > abs $returner->{'longest'}->{'duration'}) {
				$returner->{'longest'} = $a;
			}
			if (abs $a->{'duration'} < abs $returner->{'shortest'}->{'duration'}) {
				$returner->{'shortest'} = $a;
			}
			my $between = $a->{'timestamp'} - $returner->{'last_seen'}->{'timestamp'};
			if ($between > $returner->{'longest_between'}->{'duration'}) {
				$returner->{'longest_between'} = clone $a;
				$returner->{'longest_between'}->{'duration'} = $between;
			}
			if ($between < $returner->{'shortest_between'}->{'duration'} || $returner->{'shortest_between'}->{'duration'} == undef) {
				$returner->{'shortest_between'} = clone $a;
				$returner->{'shortest_between'}->{'duration'} = $between;
			}
			push @{$returner->{'betweens'}}, $between;
			$returner->{'last_seen'} = $a;

			if ($a->{'server_time'} > $returner->{'last_recorded'}->{'server_time'}) {
				$returner->{'last_recorded'} = $a;
			}
			if ($a->{'server_time'} < $returner->{'first_recorded'}->{'server_time'} || $returner->{'first_recorded'}->{'server_time'} == undef) {
				$returner->{'first_recorded'} = $a;
			}
			$returner->{'total_duration'} += abs $a->{'duration'};
			$returner->{'total_occurences'} += 1;

		}
		$returner->{'average_duration'} = eval { $returner->{'total_duration'} / $returner->{'total_occurences'} } || undef;

		foreach my $betweens ( @{$returner->{'betweens'}} ) {
			$returner->{'between_total'} += $betweens;
		}
		$returner->{'between_average'} = eval { $returner->{'between_total'} / $returner->{'total_occurences'} } || undef;
	}
	# The share wheel is one scope's own parts rather than the page of periods
	# beside it: this week splits into its days, this day into its hours. The
	# readings come from the appointments already gathered above, so six shares
	# cost a walk over that list, never a query of their own.
	my $allocation = {};
	foreach my $scope ( qw/minute hour day week month year/ ) {
		my ($bt, $tt) = &father_time({
			scope => $scope,
			ts => 'this',
			lock => $settings->{'s_lock'},
			timestamp => $view_now
		});
		$allocation->{$scope} = &inventory_allocation($appts, $s_display, $scope, $bt, $tt);
	}
	$returner->{'allocation'} = $allocation;
	# A row stays only if it holds something for what is on screen. A period that
	# reaches past now can catch a stray future-dated appointment and come back as
	# a bucket that carries no value for the chosen display - a note dated years
	# ahead lands in the year rows that reach it - and that empty row should not
	# take up space in the table or the graph.
	foreach my $ts ( @time_scopes ) {
		my $row = $returner->{$ts};
		my $holds = 0;
		if ($row) {
			foreach my $scope ( @time_lengths ) {
				next unless $row->{$scope} && ref $row->{$scope} eq 'HASH';
				if (defined $row->{$scope}->{$s_display}) { $holds = 1; last; }
			}
		}
		@revised_time_scopes = grep { $_ ne $ts } @revised_time_scopes unless $holds;
	}
	my @sb;
	foreach my $s ( @display_options ) {
		push @sb, $s->{'name'} unless grep { $_ eq $s->{'name'} } keys %{$gb::budget_modes};
	}
	my $jsb = encode_json \@sb;

	@time_scopes = @revised_time_scopes;
	push @time_scopes, qw/average total/;
	if ($returner->{'budgets'}->{$s_display}) {
		&subs::cache_set({ app => $returner->{'app'}, context => 'budget', subcontext => $returner->{'cachable'}->{'circumstance'} },$returner->{'cachable'});
	}
	&Websocket::send('tab', $returner->{'sendable'});
	&subs::appt_header_printer({ app => $returner->{'app'} });
	undef $returner->{'sendable'};
	undef $returner->{'cachable'};
	$returner->{'evaluation'} = &subs::cache_get({ app => $app, context => 'evaluation' });

	$returner->{'content'} = $c->render_to_string(
		template => 'apps/inventory',
		app => $app,
		returner => $returner,
		appts => $appts,
		settings => $settings,
		time_scopes => \@time_scopes,
		time_lengths => \@time_lengths,
		movements => $movements,
		display_options => \@display_options,
		measure_calc_json => $measure_calc_json,
		evaluation => $returner->{'evaluation'}
	);
	return $returner;
}

# One scope's parts as shares of the whole scope: a week is seven days, a day
# is its hours, a month its days, a year its months, an hour its minutes. The
# reading is the raw amount each part holds - a session split where it was
# spent - rather than the grid's averaged statistic, which has no share to
# give. Percentages are whole numbers handed out by largest remainder, so the
# wheel's labels always add up to 100 instead of to 99 or 101.
sub inventory_allocation($appts, $display, $scope, $start, $end) {
	my $empty = {
		scope => $scope,
		start => $start,
		end => $end,
		total => 0,
		empty => 1,
		slices => []
	};
	return $empty unless $appts && $scope && defined $start && defined $end && $end > $start;

	# Where one part ends and the next begins. Minutes, hours and seconds step at
	# the clock's own pace; days and months step at local midnight, so a daylight
	# saving change never makes a day 23.4 hours long.
	my @edges = ($start);
	if ($scope eq 'minute' || $scope eq 'hour' || $scope eq 'day') {
		my $step = $scope eq 'minute' ? 1000 : $scope eq 'hour' ? 60000 : 3600000;
		my $t = $start;
		while (scalar @edges < 400) {
			$t += $step;
			last if $t >= $end;
			push @edges, $t;
		}
		push @edges, $end;
	}
	elsif ($scope eq 'week' || $scope eq 'month') {
		my $t = $start;
		while (scalar @edges < 400) {
			my @lt = localtime(int($t / 1000));
			# step through noon, which no daylight saving change can push onto
			# another calendar day, then take that day's midnight
			my $noon = timelocal(12, 0, 0, $lt[3], $lt[4], $lt[5]);
			my @nx = localtime($noon + 86400);
			my $next = timelocal(0, 0, 0, $nx[3], $nx[4], $nx[5]) * 1000;
			$next = $t + 86400000 if $next <= $t;
			last if $next >= $end;
			push @edges, $next;
			$t = $next;
		}
		push @edges, $end;
	}
	elsif ($scope eq 'year') {
		my @lt = localtime(int($start / 1000));
		my ($year, $month) = ($lt[5] + 1900, $lt[4]);
		while (scalar @edges < 400) {
			$month++;
			if ($month > 11) { $month = 0; $year++; }
			my $next = timelocal(0, 0, 0, 1, $month, $year) * 1000;
			last if $next >= $end;
			push @edges, $next;
		}
		push @edges, $end;
	}
	else {
		return $empty;
	}
	return $empty if scalar @edges < 2;

	my $label_for = sub {
		my $t = shift;
		my @lt = localtime(int($t / 1000));
		return sprintf('%02ds', $lt[0]) if $scope eq 'minute';
		return sprintf('%02d:%02d', $lt[2], $lt[1]) if $scope eq 'hour' || $scope eq 'day';
		return sprintf('%d/%d', $lt[4] + 1, $lt[3]) if $scope eq 'week' || $scope eq 'month';
		# the month's own name where gb carries one, its number where it does not
		my $name = eval { $gb::months->[$lt[4]]->{'name'} };
		return (defined $name && length $name) ? $name : sprintf('%02d', $lt[4] + 1);
	};

	my @value = (0) x (scalar(@edges) - 1);
	my $buckets = scalar @value;

	# A span is split by how much of it falls in each part, so a session that
	# crosses midnight gives each day the time it actually spent there.
	my $add_span = sub {
		my ($from, $to, $amount) = @_;
		my $span = $to - $from;
		return unless $amount > 0 && $span > 0;
		for my $i (0 .. $buckets - 1) {
			my $b_from = $edges[$i];
			my $b_to = $edges[$i + 1];
			next if $b_to <= $from;
			last if $b_from >= $to;
			my $over = ($to < $b_to ? $to : $b_to) - ($from > $b_from ? $from : $b_from);
			$value[$i] += $amount * ($over / $span) if $over > 0;
		}
	};
	# A reading that is a moment, not a span, belongs to the part it opens.
	my $add_instant = sub {
		my ($at, $amount) = @_;
		return unless $amount > 0 && $at >= $start && $at < $end;
		for my $i (0 .. $buckets - 1) {
			next if $at < $edges[$i];
			if ($at < $edges[$i + 1]) { $value[$i] += $amount; last; }
		}
	};

	foreach my $a ( @{$appts} ) {
		# a measure promoted to its own row is the same reading its parent still
		# carries; counting both would double its share
		next if ($a->{'type'} || '') eq 'measure';
		my $at = ($a->{'timestamp'} || 0) + 0;
		next unless $at;

		if ($display eq 'duration') {
			my $to = $at + abs($a->{'duration'} || 0);
			my $from = $at;
			next if $to <= $start || $from >= $end;
			$from = $start if $from < $start;
			$to = $end if $to > $end;
			$add_span->($from, $to, $to - $from);
		}
		elsif ($display eq 'occurences') {
			$add_instant->($at, 1);
		}
		else {
			my $amount = $a->{$display};
			$add_instant->($at, abs($amount)) if defined $amount && $amount =~ /^-?[0-9.]+$/ && $amount;
		}

		# a measure's readings live on the appointment, each stamped with its own
		# moment rather than the appointment's
		next if $display eq 'occurences' || !$a->{'measures'};
		my $measures = $a->{'measures'};
		$measures = eval { decode_json $measures } unless ref $measures;
		next unless ref $measures eq 'ARRAY';
		foreach my $m ( @{$measures} ) {
			next unless ref $m eq 'HASH';
			my $amount = $m->{$display};
			next unless defined $amount && $amount =~ /^-?[0-9.]+$/ && $amount;
			my $when = ($m->{'timestamp'} || $m->{'ts'} || $at) + 0;
			if ($display eq 'duration') {
				my $to = $when + abs($amount);
				my $from = $when;
				next if $to <= $start || $from >= $end;
				$from = $start if $from < $start;
				$to = $end if $to > $end;
				$add_span->($from, $to, $to - $from);
			}
			else {
				$add_instant->($when, abs($amount));
			}
		}
	}

	my $total = 0;
	$total += $_ for @value;
	return $empty unless $total > 0;

	my @rows;
	for my $i (0 .. $#value) {
		next unless $value[$i] > 0;
		my $exact = 100 * $value[$i] / $total;
		my $percent = int($exact);
		push @rows, {
			start => $edges[$i],
			end => $edges[$i + 1],
			label => $label_for->($edges[$i]),
			value => $value[$i],
			percent => $percent,
			remainder => $exact - $percent,
			order => $i
		};
	}
	# The parts are rounded down and the leftover points go to the largest
	# fractions, so the wheel's labels add up to exactly 100.
	my $leftover = 100;
	$leftover -= $_->{'percent'} for @rows;
	foreach my $row ( sort { $b->{'remainder'} <=> $a->{'remainder'} || $a->{'order'} <=> $b->{'order'} } @rows ) {
		last if $leftover <= 0;
		$row->{'percent'}++;
		$leftover--;
	}
	if ($leftover > 0) {
		my ($biggest) = sort { $b->{'value'} <=> $a->{'value'} } @rows;
		$biggest->{'percent'} += $leftover if $biggest;
	}
	delete $_->{'remainder'} for @rows;
	delete $_->{'order'} for @rows;

	return {
		scope => $scope,
		start => $start,
		end => $end,
		total => $total,
		empty => 0,
		slices => \@rows
	};
}

1;
