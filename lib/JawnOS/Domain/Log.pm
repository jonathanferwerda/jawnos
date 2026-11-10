package subs;

# Log half of the domain layer: functions subroutines.pl calls that used
# to live in Manager.pl. Same package (subs) so every call site and the
# Manager:: aliases keep working; the Loader in lib/JawnOS/Domain/Loader.pm
# requires this file on the first call that needs it.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';

use Mojo::JSON qw(decode_json encode_json);
use Number::Format qw(unformat_number);

# File-scope state owned by subroutines.pl, in this same package.
our $config;
our $device;
our $log;
our $logfile;
our @appointments;
our @results;

sub log_reader {
	my $disallowable = [];

	# Per-request memo for the pure transforms the per-row loop hammers: app names
	# repeat for every row of the same app and setting values repeat across rows.
	# None of these has side effects, so cached results are identical.
	my (%nmemo, %tmemo, %dmemo);
	my $fname = sub { my $k = $_[0] // ''; $nmemo{f}{$k} //= &subs::format_name($k) };
	my $uname = sub { my $k = $_[0] // ''; $nmemo{u}{$k} //= &subs::unformat_name($k) };
	my $hname = sub { my $k = $_[0] // ''; $nmemo{h}{$k} //= &subs::html_name($k) };
	my $pname = sub { my $k = $_[0] // ''; $nmemo{p}{$k} //= &subs::http_name($k) };
	my $sname = sub { my $k = $_[0] // ''; $nmemo{s}{$k} //= &subs::apostrophe_escape($k) };
	my $tabbr = sub { $tmemo{$_[0] // ''} //= &subs::time_abbrev_translator($_[0]) };
	my $dsay  = sub { $dmemo{$_[0] // ''} //= &subs::duration_sayer($_[0]) };
	my $data = $_[0] || {};
	my ($db,$database,$sql) = &subs::database_grabber();
	my $chosen_app = $data->{'app'};
	my $scope = $data->{'scope'} || '';
	my $timestamp = $data->{'timestamp'} || 0;
	my $timeshift_max = $data->{'timeshift_max'};
	my $search = $data->{'search'};
	my $stats = $data->{'stats'};
	#my $misc_settings = &misc_setting_list();
	my $open_appts = $data->{'appts'};
	my $appt_toggle = $data->{'appt_view_toggle'} || '';
	my $sorts = $data->{'sorts'};
	my $account = $data->{'account'};
	my $project = $data->{'project'};
	my $timestamp_selector = $data->{'sorts'} || 'timestamp';
	$timestamp_selector = 'timestamp' if $timestamp_selector eq 'occurrences';
	if (($sorts || '') eq 'server_time') {
		$timestamp_selector = 'server_time';
	}
	my $time_definition = &subs::rightNow();
	my $server_time = $time_definition;
#	$time_definition = $timestamp unless $timestamp_selector eq 'server_time';
	undef @appointments;
	my ($results,$appointments);
	my $original_timestamp = &subs::db_query('select timestamp from security LIMIT 1');
	my $ts = $original_timestamp->hashes;


	my $signatorial = &subs::signatorial_designer();
	my $navigation_information = &subs::navigation_information({ signatorial => $signatorial, cache => 'yes' });
	my $birthday = &subs::duration_sayer(  ($timestamp / 1000 ) - &subs::ago_calc( $config->{'birthday'},$timestamp) / 1000) || (($timestamp / 1000 ) - (&original_timestamp() / 1000 ) );
	my $json;
	my $jdata = encode_json $data;
	my $appts = {
		'__specs' => {
			birthday => $birthday,
			timestamp => $timestamp,
			formatted_timestamp => localtime($timestamp / 1000 )->strftime('%a %D %I:%M:%S%P'),
			server_time => &subs::rightNow(),
			data => $jdata,
			site_type => $gb::site_types->{$navigation_information->{$signatorial}->{'site_type'}}
		},
		'__params' => $data,
	};

	if ($scope && $timestamp && $data->{'view'} eq 'appointment_viewer') {
		# appointment_viewer
		my $t = &subs::time_span($scope, $timestamp); #timestamp at beginning
		my $t1 = ($timestamp - $t);
		my $t2 = ($t1 + $timestamp + $t1);
		# The view is drawn from $t out to the centre and as far again, so anything
		# fetched beyond that right edge sticks to the right edge. Nothing is fetched
		# behind the left edge that could not still be seen from inside the view: a
		# row that stopped within it, which comes in with the span it ran, and a row
		# that never stopped at all - that last is pure presence: its row may be
		# older than anything else fetched, and its band is what the left half of the
		# view is holding on to. The keyboard's checkbox asks for the older view
		# instead: rows whose timestamp is inside the view, and nothing fetched
		# beyond either edge.
		my $in_view_only = (&subs::setting_grabber({ app => 'keyboard', setting => 'timestamp_in_view' }) || '') eq 'checked';
		my $fetch_end = $in_view_only ? ($timestamp + $t1) : $t2;
		# the client prunes by this; the oldest row carried settles it below
		my $fetch_start = $in_view_only ? $t : $t - $t1;
		# the column is text, so a numeric compare is lexicographic and finds nothing
		# once the window is before 1970 (a negative timestamp): cast only then, so the
		# common modern-range queries keep their index
		my $tint = (($t || 0) < 0 || ($fetch_end || 0) < 0) ? "cast($timestamp_selector as integer)" : $timestamp_selector;
		my $stopint = (($t || 0) < 0) ? 'cast(stop_timestamp as integer)' : 'stop_timestamp';
		# A finished appointment behind the view is left alone: it was over before
		# anything on screen, so its dot would pile against the edge with no band to
		# explain it. The line is "stopped inside the window" or "still running".
		# Written as one OR the planner optimizes each branch by one index, and the
		# second branch's "stop_timestamp is null" became a walk over every
		# never-stopped appointment in the table - the one query the poll could not
		# get cheap. Asked as two queries, the first rides the stop_timestamp index
		# and the second reaches the few start/record rows by type. The merge below
		# already de-duplicates and re-sorts whatever both hands back.
		my @stick_clauses = (
			[ 'appointments', "($stopint between ? and ?)", [ $t, $fetch_end ] ],
			# the still-running line wants the type index: left to choose, the planner
			# takes "stop_timestamp is null" for an equality and walks every
			# never-stopped row (tens of thousands) instead of the dozen start/record
			# rows. idx12_appts (type,app) is the one it should use.
			[ 'appointments indexed by idx12_appts', '(stop_timestamp is null and type in (?,?) and ' . $tint . ' <= ?)', [ 'start', 'record', $fetch_end ] ],
		);
		my $stick_suffix = '';
		my @stick_suffix_variables;
		if ($data->{'filter'} && $data->{'filter'} ne 'all') {
			$stick_suffix .= " and type = ?";
			push @stick_suffix_variables, $data->{'filter'};
		}
		if ($project && $project ne 'all') {
			$stick_suffix .= " and project = ?";
			push @stick_suffix_variables, $project;
		}
		if ($account && $account ne 'all') {
			$stick_suffix .= " and account = ?";
			push @stick_suffix_variables, $account;
		}
		my $stick_run = sub {
			my ($for_app, $app) = @_;
			foreach my $clause (@stick_clauses) {
				my ($from, $where, $vars) = @{$clause};
				my $q = "select * from $from where " . ($for_app ? "app = ? and " : '')
					. $where . $stick_suffix . " order by timestamp";
				$results = &subs::db_raw($q, ($for_app ? ($app) : ()), @{$vars}, @stick_suffix_variables);
				push @{$appointments}, @{$results};
			}
		};

		$appts->{'__specs'}->{'start'} = $t;
		$appts->{'__specs'}->{'end'} = $fetch_end;
		$appts->{'__specs'}->{'fetch_start'} = $fetch_start;
		if ($appt_toggle eq 'on') {
			my $temp_appointments;

			foreach my $a (@{$open_appts}) {
				my @query_variables = ( $a, $t, $fetch_end );

				my $query;
				if ($data->{'filter'} && $data->{'filter'} ne 'all') {
					$query = "select timestamp,app,server_time,type,duration from appointments where app = ? AND $tint between ? and ? and type = ?";
					push @query_variables, $data->{'filter'};
				}
				else {
					$query = "select timestamp,app,server_time,type,duration from appointments where app = ? AND $tint between ? and ?";
				}
				if ($project && $project ne 'all') {
					$query .= " and project = ? ";
					push @query_variables, $project;
				}
				if ($account && $account ne 'all') {
					$query .= " and account = ? ";
					push @query_variables, $account;
				}
				$query .=  " order by $timestamp_selector";
				$results = &subs::db_raw($query, @query_variables);
				$temp_appointments = $results;
				push @{$appointments}, @{$temp_appointments};
				unless ($in_view_only) {
					$stick_run->(1, $a);
				}
			}
		}
		else {
			my $query;
			my @query_variables = ( $t, $fetch_end );
			if ($data->{'filter'} && $data->{'filter'} ne 'all') {
				$query = "select distinct(app) as app,* from appointments where $tint between ? and ? and type = ?";
				push @query_variables, $data->{'filter'};
			}
			else {
				$query = "select distinct(app) as app,* from appointments where $tint between ? and ?";

			}
			if ($project && $project ne 'all') {
				$query .= " and project = ? ";
				push @query_variables, $project;
			}
			if ($account && $account ne 'all') {
				$query .= " and account = ? ";
				push @query_variables, $account;
			}
			$query .= " order by $timestamp_selector LIMIT 500";

			$appointments = &subs::db_raw($query, @query_variables);
			unless ($in_view_only) {
				$stick_run->();
			}
		}
		# a row inside the view can be a stop or a presence too, so both queries
		# can find it: keep the first of each row, and put the list back in time
		# order - last_event, the status and the formatted times all read off its
		# tail. The key cannot be the uuid alone: the per-appointment query does
		# not fetch one.
		$appointments = [] unless $appointments;
		my %seen_row;
		my @merged_rows;
		foreach my $row (sort { ($a->{$timestamp_selector} || 0) <=> ($b->{$timestamp_selector} || 0) } @{$appointments}) {
			my $row_key = join '|', ($row->{'app'} // ''), ($row->{'timestamp'} // ''), ($row->{'type'} // ''), ($row->{'duration'} // '');
			next if $seen_row{$row_key}++;
			push @merged_rows, $row;
		}
		$appointments = \@merged_rows;
		# the payload reaches back as far as the rows it carries, so the client
		# prunes by what it was actually handed
		foreach my $row (@merged_rows) {
			if ($row->{'timestamp'} && $row->{'timestamp'} < $appts->{'__specs'}->{'fetch_start'}) {
				$appts->{'__specs'}->{'fetch_start'} = $row->{'timestamp'};
			}
		}
#		my $resulters = &subs::db_query('select * from continent where timestamp >= ? and timestamp <= ?',$t,$t2);
		my $continent = [];#$resulters->hashes;
		my ($last,$next);
		my $n = 0;
		foreach my $con ( @{$continent }) {

			$n = $n + 1;
			my $last = $continent->[$n - 1];
			my $next = $continent->[$n + 1];

			if ($con->{'latitude'} ) {
				push @{$appts->{'__continent'}}, { latitude => $con->{'latitude'}, longitude => $con->{'longitude'} };
			}
		}
	}
	elsif ($search) {
		#search
		my @search_split = split ' ', $search;
		my $searchable = join '%', @search_split;

		my $s = "%" . $searchable . "%";
		my $temp_appointments = &subs::db_raw('select * from appointments where app like ?', $s);
		my (@n,@perfect_n);
		foreach my $a (reverse @{$temp_appointments}) {
			if ($a->{'app'} eq $searchable) {
				unshift @n, $a unless grep { $_->{'app'} eq $a->{'app'} } @n;
			}
			else {
				push @n, $a unless grep { $_->{'app'} eq $a->{'app'} } @n;
			}
		}
		push @{$appointments}, @n;

	}
	elsif ($chosen_app && $data->{'view'} eq 'centre_view') {
		#centre_view
		# The bound here is "now", which is positive, so a plain text compare keeps
		# the (app,timestamp) index and reads one row instead of sorting the app's
		# whole history - the cast in both the compare and the order forced a temp
		# B-tree over every row of the app, on every header render. Only a pre-1970
		# stamp needs the numeric cast: "-441..." reads above "-315...", so if the
		# newest candidate is negative, ask again numerically. The oldest-at-or-after-
		# now query needs no fallback, since a negative stamp can never qualify.
		$appointments = &subs::db_raw("select timestamp,stop_timestamp,file,server_time,app,duration,type,status,amount,unit,project,club,account,vendor from appointments where app is not null and app=? and $timestamp_selector <=? order by $timestamp_selector DESC limit 1", $chosen_app,$time_definition);
		if ($appointments->[0] && ($appointments->[0]->{$timestamp_selector} || '') =~ /^-/) {
			$appointments = &subs::db_raw("select timestamp,stop_timestamp,file,server_time,app,duration,type,status,amount,unit,project,club,account,vendor from appointments where app is not null and app=? and cast($timestamp_selector as integer) <=? order by cast($timestamp_selector as integer) DESC limit 1", $chosen_app,$time_definition);
		}
		push @{$appointments}, @{&subs::db_raw("select timestamp,stop_timestamp,file,server_time,app,duration,type,status,amount,unit,project,club,account,vendor from appointments where app is not null and app=? and $timestamp_selector >=? order by $timestamp_selector limit 1", $chosen_app,$time_definition)};


		@{$appointments} = grep { $_->{'app'} eq $chosen_app } @{$appointments};
		if (scalar @{$appointments} == 0) {
			push @{$appointments}, { app => $chosen_app };
		}
	}
	elsif ($chosen_app && $data->{'view'} eq 'appointment_details') {
		#appointment_details;
		# a scope is required for the window: without one the request used to
		# fall through to the final else below, whose body returns a bare 0, so
		# every row vanished and the details panel read "0 apps" when it was
		# opened without a scope in the request (the client always sends one, but
		# the watch, the boards and hand-made requests do not)
		$scope = 'hour' unless $scope;
		my $t = &subs::time_span($scope, $timestamp); #timestamp at beginning
		my $t1 = ($timestamp - $t);
		my $t2 = ($t1 + $timestamp);
		# the panel's own header says which window it is reading
		$appts->{'__specs'}->{'view_start'} = $t;
		$appts->{'__specs'}->{'view_end'} = $t2;
		# the window is drawn from the travelled time, so it can be before 1970 (a
		# negative timestamp): the text column then compares lexicographically and
		# finds nothing. Cast only when the window is pre-epoch, so the common modern
		# range keeps its index (the same choice the appointment_viewer makes above).
		my $pre_epoch = (($t || 0) < 0 || ($t2 || 0) < 0);
		my $tint = $pre_epoch ? "cast($timestamp_selector as integer)" : $timestamp_selector;
		my $stopint = $pre_epoch ? 'cast(stop_timestamp as integer)' : 'stop_timestamp';
		# Show every appointment that has any presence in the period, using the same
		# three tests the appointment_viewer draws its bands with: its own moment
		# (its start, for a span) lands inside the period; it stopped inside it; or it
		# is a span still running (a start/record row with no stop) that had already
		# begun by the period's end. A completed span is a 'stop' row whose timestamp
		# is its start and whose stop_timestamp is its stop, so the middle test is
		# what catches a span that began before the period and was still going when it
		# opened; the old test only ever looked at start/record rows and so missed
		# them.
		my $presence = "(($tint >= ? AND $tint <= ?) OR ($stopint >= ? AND $stopint <= ?) OR (stop_timestamp IS NULL AND type IN (?,?) AND $tint <= ?))";
		my @presence = ($t, $t2, $t, $t2, 'start', 'record', $t2);
		if ($data->{'uuid'}) {
			$results = &subs::db_raw("select * from appointments where app=? and uuid=? order by server_time DESC", $chosen_app, $data->{'uuid'});
		}
		elsif ($data->{'filter'} ne 'all') {
			$results = &subs::db_raw("select * from appointments where app=? and type=? and $presence order by timestamp DESC", $chosen_app, $data->{'filter'}, @presence);
		}
		else {
			$results = &subs::db_raw("select * from appointments where app=? and $presence order by timestamp DESC", $chosen_app, @presence);
		}
		$appointments = $results;
	}
	elsif ($chosen_app && $data->{'view'} eq 'appointment_display') {
		# appointment_display (configure)
		$appointments = &subs::db_raw("select * from appointments where app=? order by $timestamp_selector limit 1", $chosen_app,$timestamp_selector);
		if (scalar @{$appointments} == 0) {
			push @{$appointments}, { app => $chosen_app };
		}

	}
	else {
		# Just give it all to me.
#		$results = &subs::db_query("select distinct(app) as app,* from appointments order by $timestamp_selector");
#		$appointments = $results->hashes;
		return 0;
	}

	# An appointment inherits the strictest visibility of its app and the
	# social constructs named on the row (project, club, account, vendor). The
	# timeline never shows a private record, even while the fingerprint grant is
	# live; every other view hides it unless this is a private place and the
	# screen holds the grant. Configure's own card is the exception below, so the
	# level can be changed.
	if (($data->{'view'} || '') ne 'appointment_display') {
		my $timeline = (($data->{'view'} || '') eq 'appointment_viewer');
		my $private_open = &subs::private_reachable_now() && &subs::private_revealed();
		@{$appointments} = grep {
			!&subs::appointment_private_now($_) || (!$timeline && $private_open);
		} @{$appointments};
	}

	# The pos/mab markers are the app's place in the world (idea, product, ...).
	# They build __accounts/__projects, which only the details/wrapper windows
	# draw: the JSON viewer never uses them, and a header-only fetch does not
	# either. Skip the ~1600-row read for those, and let the centre view build
	# them once before it renders the wrapper.
	my $settings = [];
	unless (($data->{'view'} || '') eq 'appointment_viewer' || $data->{'header'}) {
		&appts_marker_builder($appts);
	}
	my @app_names = ( &subs::device_setter() );
	my %seen_app = ( $app_names[0] => 1 );
	my $s_query = 'select * from settings where device = ? and (';
	foreach my $a ( @{$appointments} ) {
		my $an = $a->{'app'};
		unless ( $seen_app{$an} ) {
			$seen_app{$an} = 1;
			push @app_names, $an;
			$s_query .= ' or' if scalar @app_names > 2;
			$s_query .= ' app = ?';
		}
	}
	$s_query .= ')';
	# The subcategory selectors (sc_idea, sc_service, ...) belong to the POS
	# person, and every browser reads them from the POS window itself when it
	# needs them. In this window they are pure weight: two of them alone were
	# 535 KB of the payload the centre view was re-fetching every second. The
	# viewer never looks at them, so here they are neither read nor sent.
	$s_query .= " and substr(setting,1,3) <> 'sc_'" if ($data->{'view'} || '') eq 'appointment_viewer';
	if (scalar @app_names > 1) {
		my @app_settings = @{&subs::db_raw($s_query, @app_names)};

		if ($data->{'view'} eq 'appointment_viewer') {
			if (my @invisible = grep { $_->{'setting'} eq 'visible' && (&subs::app_private_now($_->{'app'}) || &help_app_hidden($_->{'app'})) } @app_settings) {
				foreach my $invisible ( @invisible ) {
					@{$appointments} = grep { $_->{'app'} ne $invisible->{'app'} } @{$appointments};
					@app_settings = grep { $_->{'app'} ne $invisible->{'app'} } @app_settings;
				}
			}
		}
		push @{$settings}, @app_settings;
	}

	my ($settings_server_first, $settings_server_last) = (0, 0);
	foreach my $s (@{$settings}) {
		my $st = $s->{'server_time'};
		next unless defined $st && $st =~ /[0-9]/;
		$settings_server_first = $st if !$settings_server_first || $st < $settings_server_first;
		$settings_server_last  = $st if $st > $settings_server_last;
	}
	$appts->{'__specs'}->{'stats'}->{'settings'}->{'first'} = $settings_server_first;
	$appts->{'__specs'}->{'stats'}->{'settings'}->{'last'}  = $settings_server_last;
	# The markers the client echoes back so an unchanged tick can be answered
	# "nothing new": how many rows the window holds and the span of server_time in
	# them. min/max rather than the first and last of the list, because a row
	# edited in the middle bumps its server_time without moving - that is a change
	# too. Zero when the window is empty, so they are always there to be echoed.
	# They are read here, after the visible filter above, because that is the set
	# the client draws: counting the raw window instead made the echoed count
	# disagree whenever an invisible appointment was in the window, so the
	# nothing-new short-circuit could never fire then.
	my ($appt_server_first, $appt_server_last) = (0, 0);
	foreach my $a (@{$appointments}) {
		my $st = $a->{'server_time'};
		next unless defined $st && $st =~ /[0-9]/;
		$appt_server_first = $st if !$appt_server_first || $st < $appt_server_first;
		$appt_server_last  = $st if $st > $appt_server_last;
	}
	$appts->{'__specs'}->{'stats'}->{'appts'}->{'first'} = $appt_server_first;
	$appts->{'__specs'}->{'stats'}->{'appts'}->{'last'}  = $appt_server_last;
	$appts->{'__specs'}->{'stats'}->{'appts'}->{'count'} = scalar @{$appointments};
	if ($stats) {
		# The client echoes the markers above while its view is fresh. When every
		# one of them still matches, the rows and settings the window draws are
		# exactly the ones it is already showing, and the whole per-app build below -
		# the work a one-second poll would otherwise redo - can be skipped. Markers
		# it did not send stay undefined, so a half-known request never reads as "no".
		my $same =
			   !&subs::private_revealed()
			&& defined $stats->{'appts'}->{'count'} && defined $stats->{'appts'}->{'first'} && defined $stats->{'appts'}->{'last'}
			&& defined $stats->{'settings'}->{'first'} && defined $stats->{'settings'}->{'last'}
			&& scalar @{$appointments} == $stats->{'appts'}->{'count'}
			&& $appt_server_last  <= $stats->{'appts'}->{'last'}
			&& $appt_server_first >= $stats->{'appts'}->{'first'}
			&& $settings_server_last  <= $stats->{'settings'}->{'last'}
			&& $settings_server_first >= $stats->{'settings'}->{'first'};
		if ($same) {
			return { updateable => 'no', '__specs' => $appts->{'__specs'} };
		}
	}

	# The three little per-app tables below (model, option, option_category) were
	# read for *every row*, and every row of the same app asked the same three
	# questions again. The centre view polls once a second, so that was ~45
	# SQL::Abstract round trips on every tick, each rebuilding its own statement -
	# the single largest cost of the view. One query per table, asked once for the
	# whole set of apps in the window, answers them all; the rows are grouped by
	# app here and handed back to the loop below.
	my %appt_table_lookup;
	{
		my (%seen_app, @lookup_apps);
		foreach my $a (@{$appointments}) {
			next unless $a->{'app'};
			my $lookup_app = $uname->($a->{'app'});
			next if $seen_app{$lookup_app}++;
			push @lookup_apps, $lookup_app;
		}
		if (@lookup_apps) {
			my $placeholders = join ',', ('?') x scalar @lookup_apps;
			foreach my $at ( qw/model option option_category/ ) {
				my $rows = &subs::db_query("select * from $at where app in ($placeholders)", @lookup_apps);
				foreach my $row ( @{ $rows->hashes } ) {
					push @{ $appt_table_lookup{$at}->{$row->{'app'}} }, $row;
				}
			}
		}
	}

	# The per-row loop below used to re-scan the whole settings list (the pos/mab
	# markers plus every app in the window - better than two thousand rows) once or
	# twice for every appointment. Bucketing by app once answers each lookup with
	# its own short list, which is what the loop actually wanted.
	my %settings_by_app;
	foreach my $s (@{$settings}) {
		push @{ $settings_by_app{$s->{'app'}} }, $s;
	}

	# one archive scan for the whole view: the settings, the machine list and
	# each location's manifest are shared by every row's files
	my $archive_cache = {};

	foreach my $a (@{$appointments}) {
		next unless $a->{'app'};
	#	$a->{'file'} = undef if $data->{'view'} eq 'appointment_viewer';
		#unless ($data->{'view'} eq 'appointment_viewer') {
		#	my $cache_check = &subs::cache_get({ app => $a->{'app'}, context => $data->{'view'} });
		#	if ($cache_check) {
		#	#	$appts->{$a->{'app'}} = $cache_check;
		#	#	next;
		#	}
		#}
		$a->{'app'} = $uname->($a->{'app'});
		my @a_settings = @{ $settings_by_app{$a->{'app'}} || [] };
		foreach my $s (@{ $settings_by_app{$a->{'app'}} || [] }) {
			if ($s->{'setting'} eq 'colour' && !length $s->{'value'}) {
				# blank only - an appointment keeps the colour it was given until the
				# user re-themes them from configure/misc_setting_list
				$s->{'value'} = &subs::theme_colour_for_app($s->{'app'}, $s->{'value'}, $s->{'device'});
			}
			$appts->{$a->{'app'}}->{'setting'}->{$s->{'setting'}} = $s->{'value'};
			foreach my $oi ( ($scope) ) {
				if (($s->{'setting'} || '') =~ /warranty|duration/gi) {
					$appts->{$a->{'app'}}->{'setting'}->{$oi . '_' . $s->{'setting'}} = $tabbr->($s->{'value'});
					if ((($a->{'type'} || '') eq 'start' || ($a->{'type'} || '') eq 'record') && $a->{'timestamp'} < $timestamp) {# && (!$a->{'duration'} || ($a->{'duration'} >= $a->{'timestamp'} - $timestamp))) {
						$a->{'duration'} = $a->{'timestamp'} - $timestamp;
					}
					unless (($a->{'type'} || '') =~ /record|start/) {
						if (my $dur = $a->{'duration'} || $appts->{$a->{'app'}}->{'setting'}->{$oi . '_' . $s->{'setting'}}) {
							$a->{'formatted_' . $s->{'setting'}} = $dsay->(($dur / 1000));
						}
					}
				}
			}

		}
		# an app born before dark_colour existed has no row for it, and one born on
		# a dark desktop stored that cut as its colour: give the viewers the same
		# light/dark pair the settings getter hands them
		($appts->{$a->{'app'}}->{'setting'}->{'colour'}, $appts->{$a->{'app'}}->{'setting'}->{'dark_colour'}) =
			&subs::appointment_colours($appts->{$a->{'app'}}->{'setting'}->{'colour'}, $appts->{$a->{'app'}}->{'setting'}->{'dark_colour'});
	# A private appointment never appears on the timeline, even while the
	# private fingerprint grant is live and even at home. Configure's own card is
	# the deliberate exception: it must stay readable so the level can be changed.
	# Every other view (a centre view, a header) reads the ordinary rule, so a
	# private app opened from the start menu in a private place still opens.
	if ($data->{'view'} ne 'appointment_display') {
		if (($data->{'view'} || '') eq 'appointment_viewer' && &subs::app_private_now($a->{'app'})) {
			push @{$disallowable}, $a->{'app'};
		}
		elsif (&subs::app_hidden_now($a->{'app'})) {
			push @{$disallowable}, $a->{'app'};
		}
	}

		foreach my $at ( qw/model option option_category/ ) {
			$appts->{$a->{'app'}}->{$at} = $appt_table_lookup{$at}->{$a->{'app'}} || [];
		}
		if ($data->{'view'} eq 'centre_view') {
			my @bm = sort keys %{$gb::budget_modes};

			$appts->{$a->{'app'}}->{'setting'}->{'budget_modes'} = \@bm;
			foreach my $br ( @bm ) {
				if (my $cache = &subs::cache_get({ app => $a->{'app'}, context => 'budget', subcontext => $br })) {
					$appts->{$a->{'app'}}->{'budget'}->{$br} = $cache;
				}
			}
		}

		if (($a->{'duration'} || '') !~ /[0-9]/) { $a->{'duration'} = 0; }
		$appts->{$a->{'app'}}->{'timestamp'} = $a->{'timestamp'};
		$appts->{$a->{'app'}}->{'name'} = $uname->($a->{'app'});
		$appts->{$a->{'app'}}->{'html_name'} = $hname->($a->{'app'});
		$appts->{$a->{'app'}}->{'http_name'} = $pname->($a->{'app'});
		$appts->{$a->{'app'}}->{'apostrophe_escape'} = $sname->($a->{'app'});
		$appts->{$a->{'app'}}->{'setting'}->{'wiki'} = 'https://en.wikipedia.org/wiki/' . &subs::wiki_name($a->{'app'});
		unless ($data->{'notes'} && $data->{'notes'} eq 'on') {
			$a->{'start_notes'} = 'redacted' if $a->{'start_notes'};
			$a->{'notes'} = 'redacted' if $a->{'notes'};
			$a->{'end_notes'} = 'redacted' if $a->{'end_notes'};
		}
		$appts->{$a->{'app'}}->{'formatted_name'} = $fname->($a->{'app'});
		$appts->{$a->{'app'}}->{'shorthand_name'} = &subs::shorthand_name($appts->{$a->{'app'}}->{'formatted_name'});
		my $lt = localtime($a->{'timestamp'} / 1000 );
		$a->{'formatted_time'} = $lt->strftime('%a %b %d %Y - %I:%M:%S%P');
		$a->{'formatted_server_time'} = localtime($a->{'server_time'} / 1000 )->strftime('%a %b %d %Y - %I:%M:%S%P %Z');
		$appts->{$a->{'app'}}->{'just_time'} = $lt->strftime('%I:%M%P');
		$appts->{$a->{'app'}}->{'just_date'} = $lt->strftime('%a %b %d %Y');

		if (!$a->{'duration'} && grep { 'duration' eq $_->{'setting'} } @a_settings ) {
			$a->{'duration'} = $tabbr->($appts->{$a->{'app'}}->{'setting'}->{'duration'});
		}
		if ($a->{'timestamp'} < $timestamp && ($a->{'type'} eq 'start' || $a->{'type'} eq 'record')) {
			$a->{'duration'} = $a->{'timestamp'} - $timestamp;
		}
		$appts->{$a->{'app'}}->{'duration'} = $a->{'duration'};

		$a->{'formatted_duration'} = $dsay->(abs(($a->{'duration'} || 0)) / 1000);
		$a->{'warranty'} = $a->{'warranty'} || $appts->{$a->{'app'}}->{'setting'}->{'warranty'};
		$appts->{$a->{'app'}}->{'formatted_duration'} = $dsay->($a->{'duration'});
		$appts->{$a->{'app'}}->{'formatted_duration'} = $dsay->((time()  - $a->{'timestamp'})) unless $a->{'duration'};
		$appts->{$a->{'app'}}->{'file'} = $a->{'file'};
		if ($a->{'file'} ) {
			if ($a->{'type'} eq 'snapshot') {
				push @{$a->{'files'}}, { file => $a->{'file'}, file_type => 'img' };
			}
			else {
				my $files = eval { return decode_json $a->{'file'} } || [];
				if (eval { $files->{'f'} }) {
					$files = [ $files ];
				}
				foreach my $file (@{$files}) {
					push @{$a->{'files'}}, &subs::log_reader_file_preparer($file);
				}
			}
			# A file whose local copy has gone may still be on the archive
			# drive. Only this view shows the file itself, so only it pays for
			# the lookup; a listing never waits on an archive machine.
			if (($data->{'view'} || '') eq 'appointment_details' && $a->{'files'} && scalar @{$a->{'files'}}) {
				&subs::archive_file_attach($a->{'files'}, { cache => $archive_cache });
			}
		}

		# the old write-only @appointments grep/unshift here grew O(n^2) per view;
		# nothing ever read it, so it is gone
		if ($appts->{$a->{'app'}}->{'total'} || $appts->{$a->{'app'}}->{'amount'}) {
			$a->{'label'} = "transaction";
			$a->{'type'} = "transaction";
			$appts->{$a->{'app'}}->{'total_amount'} += unformat_number($a->{'amount'});
			$appts->{$a->{'app'}}->{'total_tax'} += unformat_number($a->{'tax'});
			$appts->{$a->{'app'}}->{'total_total'} += unformat_number($a->{'total'});
			$appts->{$a->{'app'}}->{'total_quantity'} += unformat_number($a->{'quantity'});
			$appts->{$a->{'app'}}->{'formatted_time'} = localtime($a->{'timestamp'} / 1000 )->strftime('%a %b %d %Y - %I:%M:%S%P');
			push @{$appts->{$a->{'app'}}->{'vendors'}}, $a->{'vendor'};

			$appts->{$a->{'app'}}->{'last_transaction'} = $appts->{$a->{'app'}}->{'timestamp'};
			$appts->{$a->{'app'}}->{'vendor_list'} = encode_json $appts->{$a->{'app'}}->{'vendors'};
		}
		if ($a->{'amount'}) {
			$appts->{$a->{'app'}}->{'total_amount'} -= $a->{'amount'} if $a->{'amount'} < 0;
		}
		my $timestamp = $a->{'timestamp'};
		my $type = $a->{'type'};
		$a->{'formatted_name'} = $fname->($a->{'app'});
		push @{$appts->{$a->{'app'}}->{'list'}}, $a;
		$appts->{$a->{'app'}}->{'last_event'} = $timestamp;
		$a->{'formatted_account'} = $fname->($a->{'account'});
		$a->{'formatted_type'} = $fname->($a->{'type'});
		$a->{'formatted_project'} = $fname->($a->{'project'});
		if ($project && $project ne 'all') {
			$appts->{$a->{'app'}}->{'last_project'} = $project;
		}
		else {
			$appts->{$a->{'app'}}->{'last_project'} = $a->{'project'};
		}
		if ($account && $account ne 'all') {
			$appts->{$a->{'app'}}->{'last_account'} = $account;
		}
		else {
			$appts->{$a->{'app'}}->{'last_account'} = $a->{'account'};
		}
	#	if ($type =~ 'start|record|pause|transaction|reset|note') {
			$appts->{$a->{'app'}}->{'last_reset'} = $timestamp;
	#	}
		if ($json->{'type'} && $json->{'type'} eq 'inventory') {
			$appts->{$a->{'app'}}->{'invs'} += $json->{'inv'};
			$appts->{$a->{'app'}}->{'inv'} = $appts->{$a->{'app'}}->{'resets'} ;
		}
		$a->{'duration'} = '' if ($a->{'duration'} || '') eq 'NaN';
		if ($a->{'type'} =~ /start|record/) {
			$appts->{$a->{'app'}}->{'formatted_start_time'} = $a->{'formatted_time'};
			$appts->{$a->{'app'}}->{'formatted_end_time'} = &subs::formatted_time($a->{'timestamp'} + ($a->{'duration'} || 0));
		}
		else {
			$appts->{$a->{'app'}}->{'formatted_end_time'} = $a->{'formatted_time'};
			$appts->{$a->{'app'}}->{'formatted_start_time'} = &subs::formatted_time($a->{'timestamp'} - ($a->{'duration'} || 0));
		}
		push @{$appts->{$a->{'app'}}->{'transactions'}}, grep { $_->{'type'} eq 'transaction' && $_->{'app'} eq $a->{'app'} } @{$appointments};
		$appts->{$a->{'app'}}->{'setting'}->{'status'} = $appts->{$a->{'app'}}->{'list'}->[-1]->{'type'} unless $appts->{$a->{'app'}}->{'setting'}->{'status'} && $appts->{$a->{'app'}}->{'setting'}->{'status'} =~ /record|start|paused|resumed|completed|transaction/;

		#&subs::cache_set({app => $a->{'app'}, context => $data->{'view'} }, $appts->{$a->{'app'}});
	}

	foreach my $disallowed ( @{$disallowable} ) {
		delete $appts->{$disallowed};
	}

	return $appts;
}

# The row a capture taken from an app (not a named appointment) belongs to.
# Kept pure so the rule can be pinned without a database: an open start/record
# row wins over a newer, already-stopped row, because that is the session the
# person is in; with no open row the newest row is the one the details view
# shows. Takes the rows and returns the target uuid ('' when there are none).
sub capture_target_uuid($rows) {
	# db_query(...)->hashes returns a Mojo::Collection, not a plain arrayref; treat
	# any array-like the caller has as the row list. A Mojo::Collection happens to
	# overload @{}, but to_array() is the dependable way to get the plain list.
	my $list = $rows;
	if (ref $rows && ref $rows ne 'ARRAY' && eval { $rows->can('to_array') }) {
		$list = $rows->to_array;
	}
	return '' unless ref $list eq 'ARRAY' && scalar @{$list};
	my @rows = grep {
		ref $_ eq 'HASH' && defined $_->{'uuid'} && length $_->{'uuid'}
	} @{$list};
	return '' unless @rows;
	my @open = grep {
		($_->{'type'} || '') =~ /^(?:start|record)$/
			&& !(defined $_->{'stop_seen'} && length $_->{'stop_seen'})
			&& !(defined $_->{'stop_timestamp'} && length $_->{'stop_timestamp'})
	} @rows;
	my @pool = @open ? @open : @rows;
	my @sorted = sort {
		($b->{'server_time'} || 0) <=> ($a->{'server_time'} || 0)
			|| ($b->{'timestamp'} || 0) <=> ($a->{'timestamp'} || 0)
	} @pool;
	return $sorted[0]->{'uuid'};
}

sub appts_marker_builder {
	my $appts = shift;
	return $appts unless ref $appts eq 'HASH';
	my $settings = &subs::db_raw('select app, setting, value, server_time from settings where setting=? or setting=?', 'pos', 'mab');
	# A wallet account carries its coin beside its name, so the transaction form
	# can read an amount in that coin. One small read covers every account.
	my $crypto_rows = &subs::db_raw("select app, setting, value from settings where setting in ('payment_type','crypto_asset')");
	my %crypto;
	foreach my $c ( @{$crypto_rows} ) {
		$crypto{ $c->{'app'} }->{ $c->{'setting'} } = $c->{'value'};
	}
	foreach my $s ( @{$settings} ) {
		next unless ($s->{'setting'} || '') eq 'pos' || ($s->{'setting'} || '') eq 'mab';
		my $bucket = ($s->{'value'} || '') eq 'account' ? '__accounts'
			: ($s->{'value'} || '') eq 'project' ? '__projects' : '';
		next unless $bucket;
		my $wallet = '';
		my $cs = $crypto{ $s->{'app'} };
		if ($cs && lc($cs->{'payment_type'} || '') eq 'crypto') {
			my $asset = &subs::crypto_asset($cs->{'crypto_asset'});
			$wallet = $asset ? $asset->{'code'} : 'BTC';
		}
		push @{$appts->{$bucket}}, { formatted_name => &subs::format_name($s->{'app'}), app => $s->{'app'}, crypto_asset => $wallet, payment_type => ($bucket eq '__accounts' && $cs ? ($cs->{'payment_type'} || '') : '') }
			unless grep { $_->{'app'} eq $s->{'app'} } @{$appts->{$bucket} || []};
	}
	$appts->{'__specs'}->{'markers'} = 'yes' if ref $appts->{'__specs'} eq 'HASH';
	return $appts;
}

sub original_timestamp {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $original_timestamp = &subs::db_query('select timestamp from security LIMIT 1');
	my $ts = $original_timestamp->hashes;
	return $ts->[0]->{'timestamp'} ;
}

sub help_app_hidden($app) {
	return 0 unless defined $app && length $app;
	return &subs::app_hidden_now($app) ? 1 : 0;
}

1;
