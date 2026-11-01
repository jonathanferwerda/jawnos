package Manager;

# Manager helpers, part 20 of 37. Moved out of Manager.pl so a
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

sub budget_runner($app) {
	&subs::subprocessor(sub {
		my ($db) = &subs::database_grabber();
		my $scope;
		my $timestamp = &subs::rightNow();
		my $budgets = &subs::db_query('select distinct(app) as app,* from settings where app=? and setting = ? and device = ? and value is not null',$app,'budget', $device)->hashes;
		my $sb = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'special_budgets' }) } || [];
		my $am = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'app_measures' }) } || {};
		# the base readings, any special budgets, and the app's measures: a measure
		# budget (19869steps/week, 175weight/month) is a budget like any other and
		# gets its light the same way
		my @budget_modes = ( @{$sb}, keys %{$gb::budget_modes}, keys %{$am} );
		foreach my $b ( @{$budgets} ) {
			my $app = $b->{'app'};
			my @buds = split /,/, $b->{'value'};
			foreach my $circumstance ( @budget_modes ) {
				my $cache_budget = &subs::cache_get({ app => $app, context => 'budget', subcontext => $circumstance });
				if ($cache_budget->{'scope'}) {
					$scope = $cache_budget->{'scope'};
				}
				foreach my $bud ( @buds ) {
					my @bt = split '/', $bud;
					$scope = $bt[-1];

					my $budget = &Manager::budget_calculator({
						app => $app,
						circumstance => $circumstance,
						scope => $scope,
						budget => $bud
					});
					if ($budget->{'is_scope'} && $circumstance eq $budget->{'circumstance'}) {
						&subs::cache_set({ app => $app, context => 'budget', subcontext => $circumstance }, $budget);
						my $msg = {
							app => $app,
							type => 'budget',
							budget => {
								colour => $budget->{'colour'},
								circumstance => $budget->{'circumstance'},
							}
						};
						&Websocket::send('tab', $msg);
						my $ci = &budget_current_information($app,$circumstance,$timestamp);
						&Websocket::send('tab', {
							type => 'html',
							content => $ci->{'template'},
							selector => '.budget_current_information[app="' . $app .'"][circumstance="' . $circumstance . '"]'
						});

					}
				}
			}
		}
		&centre_view_grabber({ app => &subs::unformat_name($app), timestamp => &subs::rightNow(), cached => 'no' });

	}, { name => 'budget runner' });
}

sub budget_entry_parse {
	my $entry = shift;
	my $direction = 'floor';
	my $e = $entry;
	if ($e =~ s/^<=//) { $direction = 'ceiling'; }
	elsif ($e =~ s/^>=//) { $direction = 'floor'; }
	my ($body, $scope) = split '/', $e, 2;
	my ($value, $measure);
	if ($body =~ /^\$(.*)$/) { $measure = '$'; $value = $1; }
	elsif ($body =~ /^([0-9.\-]+)([a-zA-Z_]*)$/) { $value = $1; $measure = $2; }
	else { $value = $body; $measure = ''; }
	return { raw => $entry, direction => $direction, value => $value, measure => $measure, scope => $scope, fixed => (defined $scope ? 0 : 1) };
}

sub measure_trend($app, $measure, $floor_days) {
	my $floor = ($floor_days || 90) * 86400000;
	my $appts = &subs::db_query('select timestamp,measures from appointments where app = ? and measures is not null order by timestamp desc limit 600', $app)->hashes;
	my @pts;
	foreach my $a ( @{$appts} ) {
		my $ms = eval { return decode_json $a->{'measures'} } || [];
		foreach my $m ( @{$ms} ) {
			next unless defined $m->{$measure} && $m->{$measure} =~ /[0-9]/;
			push @pts, [ ($a->{'timestamp'} + 0), ($m->{$measure} + 0) ];
		}
	}
	@pts = sort { $a->[0] <=> $b->[0] } @pts;
	return (undef, undef, scalar @pts) if scalar @pts < 2;
	# how often it is recorded: the median gap over the recent readings
	my @gaps;
	for (my $i = $#pts; $i > 0 && scalar @gaps < 50; $i--) {
		my $g = $pts[$i][0] - $pts[$i-1][0];
		push @gaps, $g if $g > 0;
	}
	my $window = $floor;
	if (scalar @gaps) {
		my @sorted = sort { $a <=> $b } @gaps;
		my $gap = $sorted[int($#sorted / 2)];
		my $span = $gap * 12;
		$window = $span if $span > $window;
	}
	# fit the readings the window reaches back over, so a sparsely kept level is
	# read over the long stretch it needs and a dense one stays on its recent pace
	my $cut = $pts[-1][0] - $window;
	my @fit = grep { $_->[0] >= $cut } @pts;
	@fit = @pts if scalar @fit < 2;
	my $t0 = $fit[0][0];
	my ($n, $sx, $sy, $sxx, $sxy) = (0, 0, 0, 0, 0);
	foreach my $p ( @fit ) {
		my $x = $p->[0] - $t0;
		$n++; $sx += $x; $sy += $p->[1]; $sxx += $x * $x; $sxy += $x * $p->[1];
	}
	my $denom = $n * $sxx - $sx * $sx;
	return (undef, $fit[-1][1], scalar @pts) if $denom == 0;
	my $slope = ($n * $sxy - $sx * $sy) / $denom;
	return ($slope * 86400000, $fit[-1][1], scalar @pts);
}

sub goal_reading($app, $circumstance) {
	my $raw = &subs::setting_grabber({ app => $app, setting => 'goals' });
	return undef unless ($raw || '') =~ /\S/;
	my $entry;
	foreach my $e ( split ',', $raw ) {
		my $p = &budget_entry_parse($e);
		if ($p->{'measure'} eq $circumstance) { $entry = $e; last; }
	}
	return undef unless defined $entry;
	my $reading = &budget_calculator({ app => $app, circumstance => $circumstance, budget => $entry });
	my $target = $reading->{'budgeted'};
	my $current = $reading->{'value'};
	my $dir = $reading->{'direction'} || 'floor';
	my ($slope, $last, $samples) = &measure_trend($app, $circumstance, 90);
	my ($eta_days, $reached);
	# a scoped goal is a rate and already has a period pace; the date-to-goal is
	# what a fixed (scopeless) level is missing
	if ($reading->{'fixed'} && defined $target) {
		my $need = ($dir eq 'ceiling') ? ($current - $target) : ($target - $current);
		if ($need <= 0) { $reached = 1; $eta_days = 0; }
		elsif ($slope) {
			my $toward = ($dir eq 'ceiling') ? -$slope : $slope;
			$eta_days = ($toward > 0) ? ($need / $toward) : undef;
		}
	}
	my $eta_text;
	if ($reached) { $eta_text = 'reached'; }
	elsif (defined $eta_days) { $eta_text = localtime((&subs::rightNow() + $eta_days * 86400000) / 1000)->strftime('%b %d, %Y at %l:%M%P'); $eta_text =~ s/\s+/ /g; }
	return {
		entry => $entry,
		direction => $dir,
		target => $target,
		current => $current,
		slope => $slope,
		samples => ($samples || 0),
		eta_days => $eta_days,
		eta_text => $eta_text,
	};
}

sub budget_autocalc($data) {
	my $app = $data->{'app'};
	my $scope = $data->{'scope'};
	my $circumstance = $data->{'circumstance'};
	my $timestamp = $data->{'timestamp'};
	my $server_time = &subs::rightNow();
	if (my $cache = &subs::cache_get({ app => $app, context => 'autocalc', subcontext => $circumstance })) {
		return $cache;
	}
	my $returner = {
		minute => { symbol => 'm' },
		hour => { symbol => 'h' },
		day => { symbol => 'd' },
		week => { symbol => 'w' },
		month => { symbol => 'M' },
		year => { symbol => 'y' },
	};
	my $settings = &subs::settings_grabber({ app => $app });
	# The six windows this reads, named once so 'data' (added below) is never
	# mistaken for one of them.
	my @windows = keys %{$returner};
	# A measure is any circumstance the base modes do not name (the same test
	# budget_calculator uses), so 'quantity' reads as the base mode it is; a measure
	# reads with its own calc (steps summed, weight averaged).
	my $is_measure = ( scalar grep { $_ eq $circumstance } keys %{$gb::budget_modes} ) == 0;
	my $mcalc = $is_measure ? &measure_calc_for($app, $circumstance, $settings->{'s_calc'}) : undef;
	# The whole history, not the last thousand: a window can reach a year back, and
	# the cap left the long scopes reading only the recent stretch. Read by
	# timestamp (app,timestamp is indexed) and only the columns the sum needs.
	my $cols = 'timestamp,type';
	$cols .= ',duration' if $circumstance eq 'duration';
	$cols .= ',total' if $circumstance eq 'total';
	$cols .= ',quantity' if $circumstance eq 'quantity';
	$cols .= ',measures' if $is_measure;
	my $appts = $data->{'appts'} || &subs::db_query("select $cols from appointments where app = ? order by timestamp ASC", $app)->hashes;
	if ($scope && $timestamp) {
		my $duration = &subs::time_abbrev_translator(1 . $scope, $server_time);
		my $beginning = $server_time - ( $duration * ($settings->{'s_scope_count'} || 1) );
		@{$appts} = grep { $_->{'timestamp'} > $beginning } @{$appts};
	}
	# The app's own movement filter names the stream a budget reads (beer's poured
	# amount, not its purchases), so the recommendation reads that same stream -
	# 'all', or no filter at all, keeps every appointment.
	my $movement = $settings->{'s_movement'} ? ( eval { return decode_json $settings->{'s_movement'} } || [] ) : [];
	if (scalar @{$movement} && !grep { $_ eq 'all' } @{$movement}) {
		my %wanted = map { $_ => 1 } @{$movement};
		@{$appts} = grep { $wanted{ $_->{'type'} || '' } } @{$appts};
	}

	# Sum the value each appointment offers the reading, and note the span it was
	# offered over: the typical amount in a window is that sum spread over the span,
	# so a 'week' reading is what a week holds. An appointment that carries no such
	# measure offers a measure's reading nothing, and does not stretch its span.
	my $total = 0;
	my $samples = 0;
	my ($first, $last);
	foreach my $appt ( @{$appts} ) {
		my ($value, $count) = (0, 0);
		if ($circumstance eq 'occurences') {
			$value = 1;
		}
		elsif ($circumstance eq 'duration') {
			$value = abs( $appt->{'duration'} || 0 );
		}
		elsif ($circumstance eq 'total') {
			$value = $appt->{'total'} + 0;
		}
		elsif ($circumstance eq 'quantity') {
			$value = abs( $appt->{'quantity'} || 0 );
		}
		elsif ($is_measure) {
			next unless $appt->{'measures'};
			unless ($appt->{'measured'}) {
				$appt->{'measures'} = eval { return decode_json $appt->{'measures'} } || [];
				$appt->{'measured'} = 'yes';
			}
			foreach my $m ( @{$appt->{'measures'}} ) {
				next unless defined $m->{$circumstance};
				$value += $m->{$circumstance};
				$count++;
			}
			next unless $count;
		}
		$total += $value;
		$samples += $count;
		my $ts = $appt->{'timestamp'} + 0;
		$first = $ts if !defined $first || $ts < $first;
		$last = $ts if !defined $last || $ts > $last;
	}
	my $span = (defined $first && defined $last) ? ($last - $first) : 0;

	foreach my $r ( @windows ) {
		my $width = &subs::time_abbrev_translator(1 . $returner->{$r}->{'symbol'}, $server_time);
		$returner->{$r}->{'duration'} = $width;
		# The reading is the sum spread over the span, not the average of the
		# overlapping per-appointment windows the walk used to take. That average
		# read the short scopes far too high - a window centred on an appointment
		# is never empty, so the count could not fall below one a window - and the
		# long ones too low, since a window wider than the history can only hold
		# the whole of it. Spreading the sum holds all six scopes in step, which is
		# what a typical scope is.
		my $result;
		if ($is_measure && $mcalc eq 'average') {
			# an averaged measure is a level, not a rate: the reading is the mean of
			# its samples, so it stands the same at every window
			$result = $samples ? ($total / $samples) : 0;
		}
		elsif ($span > 0) {
			$result = $total * $width / $span;
		}
		else {
			# a lone reading (or none) has no span to rate against; it is its own
			# whole history
			$result = $total;
		}
		$returner->{$r}->{'result'} = $result;
		if ($circumstance eq 'occurences') {
			$returner->{$r}->{'formatted_result'} = sprintf("%.3f", $result) . '/' . $r;
		}
		elsif ($circumstance eq 'total') {
			$returner->{$r}->{'formatted_result'} = &subs::price_formatter( $result ) . '/' . $returner->{$r}->{'symbol'};
		}
		elsif ($circumstance eq 'duration') {
			$returner->{$r}->{'formatted_result'} = &subs::duration_sayer($result / 1000) . '/' . $r;
		}
		else {
			$returner->{$r}->{'formatted_result'} = sprintf("%.3f", $result) . $circumstance . '/' . $r;
		}
	}

	$returner->{'data'} = {};

	$returner->{'data'}->{'circumstance'} = $circumstance;
	$returner->{'data'}->{'app'} = $app;
	$returner->{'data'}->{'formatted_app'} = &subs::format_name($app);
	$returner->{'data'}->{'timestamp'} = &subs::rightNow();

	&subs::cache_set({app => $app, context => 'autocalc', subcontext => $circumstance }, $returner);
	return $returner;
}

sub people_citizen {
	my ($c) = @_;
	return (($c->session('privilege') || '') eq 'citizen') ? 1 : 0;
}

sub people_link_sync {
	my $index = &people_index();
	my %person = map { $_ => 1 } @{ $index->{'person_apps'} };
	my %known = map { $_ => 1 } keys %{ $index->{'apps'} };
	my $now = &subs::rightNow();
	my $rows = eval { &subs::db_select('people', undef, {})->hashes } || [];
	my %have;
	foreach my $person ( @{$rows} ) {
		my $app = $person->{'app'} // '';
		next unless length $app;
		$have{$app} = 1;
		if ($person{$app}) {
			unless (($person->{'status'} || '') eq 'active') {
				&subs::db_update('people', { status => 'active', server_time => $now }, { uuid => $person->{'uuid'} });
			}
		}
		elsif (!$known{$app}) {
			# every settings row for that app is gone, so the construct was
			# removed rather than reclassified
			&subs::db_update('people', { status => 'removed', server_time => $now }, { uuid => $person->{'uuid'} });
		}
	}
	foreach my $app ( keys %person ) {
		next if $have{$app};
		&subs::db_insert('people', {
			uuid => &subs::random_string_creator(25),
			app => $app,
			name => &subs::format_name($app),
			privilege => '',
			status => 'active',
			created => $now,
			server_time => $now,
		});
	}
	return $index;
}

sub people_crest_image {
	my ($app) = @_;
	return &people_crest_entry_image(&subs::crest_contact_entry($app));
}

sub people_crest_entry_image {
	my ($entry) = @_;
	return '' unless $entry && ref $entry->{'crest'} eq 'HASH';
	return $entry->{'image_data'} if defined $entry->{'image_data'} && length $entry->{'image_data'};
	my $uuid = $entry->{'crest'}->{'uuid'} || '';
	return '' unless length $uuid;
	return &subs::crest_peer_image_file($entry) ? '/manager/people/crest_image?peer=' . $uuid . '&stamp=' . &subs::rightNow() : '';
}

sub people_main_image {
	my ($app) = @_;
	return '' unless defined $app && length $app;
	my $row = eval { &subs::db_query("select value from settings where app=? and setting='main_image' and value<>'' order by server_time desc limit 1", $app)->hashes->[0] };
	return '' unless $row && length($row->{'value'} || '');
	my $value = $row->{'value'};
	return $value if $value =~ /^data:image\//i;
	return '/file_open?file=' . &subs::url_escape_utf8($value) . '&app=' . &subs::url_escape_utf8($app) . '&thumb=ya&timestamp=' . &subs::rightNow();
}

sub people_crest_state {
	my ($entry) = @_;
	my $own = &subs::crest_record_read();
	my $incoming = ref $entry->{'crest'} eq 'HASH' ? $entry->{'crest'} : {};
	my $state = { met => 0, met_at => '', introduced_by => '' };
	if (ref $entry->{'vouch'} eq 'HASH'
		&& &subs::crest_vouch_verify($entry->{'vouch'})
		&& ($entry->{'vouch'}->{'from_uuid'} || '') eq ($own->{'uuid'} || '')
		&& ($entry->{'vouch'}->{'to_uuid'} || '') eq ($incoming->{'uuid'} || '')
		&& ($entry->{'vouch'}->{'to_pubkey'} || '') eq ($incoming->{'pubkey'} || '')) {
		$state->{'met'} = 1;
		$state->{'met_at'} = $entry->{'vouch'}->{'at'} || $entry->{'met_at'} || '';
	}
	my $peer_list = &subs::crest_peer_list_read();
	foreach my $vouch ( @{ $entry->{'vouches'} || [] } ) {
		next unless ref $vouch eq 'HASH';
		next unless ($vouch->{'to_uuid'} || '') eq ($incoming->{'uuid'} || '');
		next unless ($vouch->{'to_pubkey'} || '') eq ($incoming->{'pubkey'} || '');
		my $issuer = &subs::crest_vouch_introducer($vouch, $own, $peer_list);
		next unless $issuer;
		next if ($issuer->{'uuid'} || '') eq ($own->{'uuid'} || '');
		$state->{'introduced_by'} = $issuer->{'name'} || '';
		last;
	}
	return $state;
}

sub people_crest_scan_dir {
	my $folder = &subs::setting_grabber({ app => 'misc', setting => 'scan_location', device => &subs::device_setter() }) || 'Scans';
	my $dir = &subs::home($folder) . '/people';
	unless (-d $dir) { eval { require File::Path; File::Path::make_path($dir) }; }
	return $dir;
}

sub people_construct_kind {
	my ($app) = @_;
	return '' unless defined $app && length $app;
	foreach my $construct ( @{ &people_index()->{'constructs'} } ) {
		foreach my $row ( @{ $construct->{'rows'} } ) {
			next if $row->{'foreign'};
			return $construct->{'sing'} if ($row->{'app'} || '') eq $app;
		}
	}
	return '';
}

sub people_app_foreign {
	my ($app) = @_;
	return 0 unless defined $app && length $app;
	my $house = &subs::setting_grabber({ app => $app, setting => 'house_uuid', device => 'all' });
	return (defined $house && length $house) ? 1 : 0;
}

sub construct_crest_find_by_uuid {
	my ($uuid) = @_;
	return undef unless defined $uuid && length $uuid;
	foreach my $construct ( @{ &people_index()->{'constructs'} } ) {
		foreach my $row ( @{ $construct->{'rows'} } ) {
			my $crest = &subs::construct_crest_record_read($row->{'app'});
			if (($crest->{'uuid'} || '') ne $uuid && $row->{'foreign'} && ($row->{'crest_uuid'} || '') eq $uuid) {
				# an imported construct keeps its signed record, not a local crest
				my $raw = &subs::setting_grabber({ app => $row->{'app'}, setting => 'peer_construct', device => 'all' });
				$crest = eval { decode_json($raw) } || {};
			}
			next unless ($crest->{'uuid'} || '') eq $uuid;
			return {
				app => $row->{'app'},
				crest => $crest,
				type => $construct->{'name'},
				sing => $construct->{'sing'},
				foreign => $row->{'foreign'} || 0,
			};
		}
	}
	return undef;
}

sub people_construct_public {
	my ($app) = @_;
	return 0 unless defined $app && length $app;
	my $row = eval { &subs::db_query("select value from settings where app=? and setting='public' order by server_time desc limit 1", $app)->hashes->[0] };
	return ($row && ($row->{'value'} || '') eq 'on') ? 1 : 0;
}

sub foreign_construct_import {
	my ($record) = @_;
	return { ok => 0, error => 'no construct crest' }
		unless ref $record eq 'HASH' && ($record->{'uuid'} || '') ne '';
	return { ok => 0, error => 'that is not a construct crest' }
		unless length($record->{'construct'} || '');
	return { ok => 0, error => 'the construct crest does not verify' }
		unless &subs::crest_verify_record($record);
	my $house_uuid = $record->{'house_uuid'} || '';
	my $house_pub = $record->{'house_pubkey'} || $record->{'pubkey'} || '';
	return { ok => 0, error => 'the construct crest names no house' }
		unless length($house_uuid) && length($house_pub);
	my $own = &subs::crest_record_read();
	return { ok => 0, error => 'that is this house\'s own construct' }
		if ($own->{'uuid'} || '') eq $house_uuid;
	my $entry = &subs::crest_peer_find($house_uuid);
	my $house_crest = $entry ? ($entry->{'crest'} || {}) : undef;
	return { ok => 0, error => 'import that house\'s crest first' }
		unless $house_crest && (($house_crest->{'pubkey'} || '') eq $house_pub);
	my $sing = $record->{'construct_type'} || '';
	my %sings = map { $_->{'sing'} => 1 } values %{$gb::social_constructs};
	return { ok => 0, error => 'the construct crest has no known kind' } unless $sings{$sing};
	my $their_name = $record->{'name'} || &subs::format_name($record->{'construct'});
	my $house_name = $house_crest->{'name'} || '';
	my $index = &people_index();
	my $app = '';
	foreach my $construct ( @{ $index->{'constructs'} || [] } ) {
		foreach my $row ( @{ $construct->{'rows'} || [] } ) {
			next unless $row->{'foreign'};
			next unless ($row->{'crest_uuid'} || '') eq $record->{'uuid'};
			$app = $row->{'app'};
			last;
		}
		last if length $app;
	}
	unless (length $app) {
		my %taken = map { $_ => 1 } keys %{ $index->{'apps'} || {} };
		my $base = &subs::unformat_name($record->{'construct'} || $their_name);
		$base = 'construct' unless length $base;
		$app = $base;
		if ($taken{$app}) {
			$app = $base . '_' . substr($house_uuid, 0, 6);
			my $n = 2;
			while ($taken{$app}) { $app = $base . '_' . substr($house_uuid, 0, 6) . '_' . $n++; }
		}
	}
	my %set = (
		pos => $sing,
		construct_uuid => $record->{'uuid'},
		crest_uuid => $record->{'uuid'},
		house_uuid => $house_uuid,
		house_pubkey => $house_pub,
		house_name => $house_name,
		peer_name => $their_name,
		peer_construct => encode_json($record),
	);
	my $origin = $record->{'origin'} || $house_crest->{'origin'} || &subs::crest_entry_origin({ crest => $house_crest, endpoints => $house_crest->{'endpoints'} });
	$origin =~ s{/+$}{};
	$set{'web'} = $origin if $origin =~ m{^https?://[A-Za-z0-9.:\[\]-]+$};
	foreach my $setting ( keys %set ) {
		&subs::setting_setter({ app => $app, setting => $setting, device => 'all', value => $set{$setting} });
	}
	return {
		ok => 1,
		app => $app,
		name => $their_name,
		house_name => $house_name,
		house_uuid => $house_uuid,
	};
}

sub people_crest_profile {
	my $crest = &subs::crest_record_read();
	return undef unless $crest->{'uuid'} && $crest->{'pubkey'};
	my $suds = &subs::suds_grabber();
	my $priv = $suds ? &subs::crest_key_read($suds) : undef;
	return undef unless defined $priv && length $priv == 32;
	my $index = &people_index();
	my @constructs;
	foreach my $construct ( @{ $index->{'constructs'} } ) {
		foreach my $row ( @{ $construct->{'rows'} } ) {
			my $app = $row->{'app'} || '';
			next unless length $app;
			# another house's construct is not ours to publish
			next if $row->{'foreign'};
			next unless &people_construct_public($app);
			push @constructs, {
				type => $construct->{'name'},
				name => &subs::format_name($app),
				members => [ map { $_->{'name'} } @{ $row->{'members'} || [] } ],
			};
		}
	}
	@constructs = sort { lc($a->{'name'}) cmp lc($b->{'name'}) } @constructs;
	my $profile = {
		format => 'jawnos-crest-profile',
		profile_version => 1,
		uuid => $crest->{'uuid'},
		name => $crest->{'name'} || '',
		fingerprint => $crest->{'fingerprint'} || '',
		pubkey => $crest->{'pubkey'},
		origin => &subs::crest_origin(),
		issued => &subs::rightNow(),
		constructs => \@constructs,
		# the machines that back this crest, named by their own signatures; the
		# full statements travel on the card, this list is what a lookup shows
		cosignatures => [ map {
			{ signatorial => $_->{'signatorial'}, hostname => $_->{'hostname'}, at => $_->{'at'} }
		} @{ &subs::crest_member_cosig_list($crest, { include_local => 1 }) } ],
	};
	return &subs::crest_sign_record($profile, $priv);
}

1;
