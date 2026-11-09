package Manager;

# Manager helpers, part 27 of 37. Moved out of Manager.pl so a
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

sub handbook_today {
	my ($day, $timestamp) = @_;
	# "today" is the server's day, not a client timestamp: the clock's time
	# machine is not allowed to move the line that says what today is
	my $now = &subs::rightNow();
	my $bounds = &handbook_day_bounds($day, $now);
	my ($start, $end, $today) = ($bounds->{'start'}, $bounds->{'end'}, $bounds->{'today'});
	my $is_today = ($start == $today) ? 1 : 0;
	my $is_future = ($start > $today) ? 1 : 0;
	my $day_diff = int(($today - $start) / 86400000 + 0.5);
	my $relative = $is_today ? &subs::ui('Today') : $day_diff == 1 ? &subs::ui('Yesterday') : $day_diff == -1 ? &subs::ui('Tomorrow') : '';
	my $date_label = localtime($start / 1000)->strftime('%A, %B %d, %Y');
	my $short_date = localtime($start / 1000)->strftime('%Y-%m-%d');

	my $appts = &subs::db_query(
		'select app,type,timestamp,duration,status,project,uuid,stop_timestamp,stop_seen,source,notes from appointments where cast(timestamp as integer) >= ? and cast(timestamp as integer) < ? order by cast(timestamp as integer) limit 500',
		$start, $end
	)->hashes || [];

	my @timeline;
	my %apps_seen;
	foreach my $appt ( @{$appts} ) {
		next unless defined $appt->{'app'} && length $appt->{'app'};
		my $type = $appt->{'type'} || '';
		# money and measures have their own cards; the timeline is the day's
		# shape, not a second copy of them
		next if $type eq 'stop' || $type eq 'transaction' || $type eq 'purchase' || $type eq 'measure';
		$apps_seen{$appt->{'app'}} = 1;
		my $duration = '';
		if (defined $appt->{'duration'} && $appt->{'duration'} =~ /[0-9]/) {
			$duration = &subs::duration_sayer(abs($appt->{'duration'}) / 1000);
		}
		# an entry the Guide planted carries its own title in notes; without this
		# every planted thing would read as the app's name, "Journal"
		my $planted = (($appt->{'source'} || '') eq 'handbook' && $type =~ /^(idea|plan|dream)$/) ? 1 : 0;
		my $name = &subs::format_name($appt->{'app'});
		if ($planted) {
			my $planted_text = $appt->{'notes'} || '';
			$planted_text =~ s/\s+/ /g;
			$planted_text =~ s/^\s+|\s+$//g;
			$name = length $planted_text ? substr($planted_text, 0, 180) . (length($planted_text) > 180 ? '...' : '') : $name;
		}
		push @timeline, {
			app => $appt->{'app'},
			name => $name,
			type => &subs::format_name($type || 'event'),
			timestamp => $appt->{'timestamp'},
			duration => $duration,
			duration_ms => (defined $appt->{'duration'} ? abs($appt->{'duration'}) : 0),
			project => $appt->{'project'} || '',
			uuid => $appt->{'uuid'} || '',
			planted => $planted,
		};
	}

	# --- predicted habits -------------------------------------------------
	# The ghost appointments the desktop draws, read for this one day: the events
	# an app's own history says are likely, faded rather than written. Only ahead
	# of now, so a past day is a record and not a guess.
	my @ghosts;
	if ($is_today || $is_future) {
		my %have = map { $_->{'app'} => 1 } @timeline;
		my $recent = eval { &subs::db_query("select app, count(*) as c from appointments where cast(timestamp as integer) >= ? and app is not null and app != '' and app != 'journal' group by app having c >= 3 order by c desc limit 10", $now - 30 * 86400000)->hashes } || [];
		my @apps = map { $_->{'app'} } @{$recent};
		push @apps, grep { !$have{$_}++ } map { $_->{'app'} } @timeline;
		my %seen;
		@apps = grep { defined $_ && length $_ && !$seen{$_}++ } @apps;
		@apps = @apps[0 .. 15] if scalar @apps > 16;
		my %met = map { ($_->{'app'} . '|' . $_->{'timestamp'}) => 1 } @timeline;
		my %ghost_seen;
		foreach my $app ( @apps ) {
			my $rows = eval { &subs::ghost_rows_for($app, $now, $end) } || [];
			foreach my $ghost ( @{$rows} ) {
				my $stamp = $ghost->{'timestamp'} || 0;
				next unless $stamp >= $start && $stamp < $end;
				next if $met{$app . '|' . $stamp};
				next if $ghost_seen{$app . '|' . $stamp}++;
				my $duration = '';
				$duration = &subs::duration_sayer(abs($ghost->{'duration'}) / 1000) if $ghost->{'duration'};
				push @ghosts, { app => $app, name => &subs::format_name($app), timestamp => $stamp, duration => $duration, duration_ms => (defined $ghost->{'duration'} ? abs($ghost->{'duration'}) : 0) };
			}
			last if scalar @ghosts >= 12;
		}
		@ghosts = sort { ($a->{'timestamp'} || 0) <=> ($b->{'timestamp'} || 0) } @ghosts;
		@ghosts = @ghosts[0 .. 9] if scalar @ghosts > 10;
	}

	# --- money ------------------------------------------------------------
	my $money_rows = &subs::db_query(
		"select * from warehouse where kind='money' and type='transaction' and cast(timestamp as integer) >= ? and cast(timestamp as integer) < ? order by cast(timestamp as integer)",
		$start, $end
	)->hashes || [];
	my $money = { spent => 0, income => 0, due => 0, rows => [], due_rows => [] };
	my @due_bills;
	foreach my $row ( @{$money_rows} ) {
		my $movement = $row->{'movement'} || '';
		if ($movement eq 'expense' || $movement eq 'payment') {
			my $signed = &handbook_money_number($row);
			my $amount = abs($signed);
			# expenses and bill payments are written as negatives, so the net
			# outflow is the negated sum; a positive line is a refund and reduces it
			$money->{'spent'} += -$signed;
			push @{$money->{'rows'}}, {
				app => $row->{'app'} || '',
				name => &subs::format_name($row->{'app'} || $row->{'vendor'} || 'money'),
				vendor => $row->{'vendor'} || '',
				item => $row->{'item'} || '',
				amount => $amount,
				movement => $movement,
				timestamp => $row->{'timestamp'} || 0,
			};
		}
		elsif ($movement eq 'income') {
			$money->{'income'} += &handbook_money_number($row);
		}
		elsif ($movement eq 'payable') {
			push @due_bills, $row;
		}
	}
	if (scalar @due_bills) {
		my $payments = &subs::db_query("select source_uuid, coalesce(sum(abs(cast(total as real))),0) as paid from warehouse where kind='money' and type='transaction' and movement='payment' and cast(timestamp as integer) < ? group by source_uuid", $end)->hashes || [];
		my %paid = map { ($_->{'source_uuid'} || '') => ($_->{'paid'} || 0) } @{$payments};
		foreach my $bill ( @due_bills ) {
			my $total = &handbook_money_value($bill);
			my $balance = $total - ($paid{$bill->{'uuid'} || ''} || 0);
			next if $balance <= 0.005;
			$money->{'due'} += $balance;
			push @{$money->{'due_rows'}}, {
				app => $bill->{'app'} || '',
				name => &subs::format_name($bill->{'vendor'} || $bill->{'app'} || 'bill'),
				item => $bill->{'item'} || '',
				amount => $balance,
				timestamp => $bill->{'timestamp'} || 0,
			};
		}
	}
	@{$money->{'rows'}} = sort { ($a->{'timestamp'} || 0) <=> ($b->{'timestamp'} || 0) } @{$money->{'rows'}};
	@{$money->{'due_rows'}} = sort { ($a->{'timestamp'} || 0) <=> ($b->{'timestamp'} || 0) } @{$money->{'due_rows'}};

	# --- journal ----------------------------------------------------------
	my $journal = &handbook_journal_entries($start, $end, 50);

	# --- measures ---------------------------------------------------------
	# The person's own readings matter more than the machine's feeds (a currency
	# table and a weather station are also appointments with measures). Score the
	# streams so steps and weight lead, habits follow, and a quote screen waits at
	# the back rather than filling the journal.
	my $index = &people_index();
	my %person_app = map { $_ => 1 } @{ $index->{'person_apps'} || [] };
	my $feed_app = qr/(?:^|_)(?:weather|markets?|metals?|moon|dollars?|euro|pounds?|yen|francs?|rupees?|pesos?|kron(?:e|a)|zloty|lira|rand|yuan|won|baht|ringgit|shekel|dirham|rial|hryvnia|tenge|shilling|naira|cedi|forint|lev|leu|taka|dong|sol)$/i;
	my $feed_measure = qr/^(?:temperature|humidity|condition|pressure|wind|illumination|moon_angle|sun_angle|sun_distance|dow|nasdaq|tsx|stoxx|nikkei)$/i;
	my $measure_rows = &subs::db_query(
		'select app,timestamp,measures from appointments where measures is not null and cast(timestamp as integer) >= ? and cast(timestamp as integer) < ? order by cast(timestamp as integer) desc limit 400',
		$start, $end
	)->hashes || [];
	my $recent_measure_rows = &subs::db_query(
		'select app,timestamp,measures from appointments where measures is not null order by cast(timestamp as integer) desc limit 400'
	)->hashes || [];
	my %measure_latest;
	my %measure_unit;
	my $measure_reader = sub {
		my ($row, $latest) = @_;
		my $parsed = eval { decode_json($row->{'measures'} || '[]') } || [];
		return unless ref $parsed eq 'ARRAY';
		my $app = $row->{'app'} || '';
		return unless length $app;
		foreach my $entry ( @{$parsed} ) {
			next unless ref $entry eq 'HASH';
			foreach my $measure ( keys %{$entry} ) {
				next if $measure =~ /^(uuid|ts|timestamp|server_time|ost|app|measure)$/;
				my $value = $entry->{$measure};
				next unless defined $value && $value =~ /^-?[0-9]+(?:\.[0-9]+)?$/;
				my $key = $app . "\0" . $measure;
				my $stamp = (defined $entry->{'ts'} && $entry->{'ts'} =~ /[0-9]/) ? $entry->{'ts'} : $row->{'timestamp'};
				if ($latest) {
					my $slot = $measure_latest{$key} ||= {};
					if (!defined $slot->{'value'}) { $slot->{'value'} = $value + 0; $slot->{'timestamp'} = $stamp; }
					elsif (!defined $slot->{'previous'}) { $slot->{'previous'} = $value + 0; }
				}
				else {
					push @{$measure_latest{$key}->{'today'}}, { value => $value + 0, timestamp => $stamp, measure => $measure, app => $app };
				}
				unless (defined $measure_unit{$key}) {
					my $settings = &subs::setting_grabber({ app => $app, setting => 'app_measures' });
					my $defs = eval { decode_json($settings || '{}') } || {};
					my $definition = (ref $defs eq 'HASH') ? $defs->{$measure} : undef;
					$measure_unit{$key} = (ref $definition eq 'HASH') ? ($definition->{'unit'} || '') : '';
				}
			}
		}
	};
	foreach my $row ( @{$recent_measure_rows} ) { $measure_reader->($row, 1); }
	foreach my $row ( @{$measure_rows} ) { $measure_reader->($row, 0); }
	my @measures;
	foreach my $key ( keys %measure_latest ) {
		my $slot = $measure_latest{$key};
		next unless defined $slot->{'value'};
		my ($app, $measure) = split /\0/, $key, 2;
		my $delta;
		$delta = $slot->{'value'} - $slot->{'previous'} if defined $slot->{'previous'};
		my $entry = $index->{'apps'}->{$app} || {};
		my $score = 0;
		$score += 100 if $person_app{$app};
		$score += 40 if (($entry->{'pos'} || '') =~ /^(?:action|feel)$/ || ($entry->{'mab'} || '') =~ /^(?:action|feel)$/);
		$score += 25 if $measure =~ /^(?:weight|steps|sleep|heart|pulse|mood|energy|pain|blood|water|food|vape|cigarette|alcohol)$/i;
		$score -= 15 if $measure eq 'speed';
		$score -= 60 if $app =~ $feed_app;
		$score -= 40 if $measure =~ $feed_measure;
		$score += 10 if scalar @{ $slot->{'today'} || [] };
		push @measures, {
			app => $app,
			score => $score,
			measure => $measure,
			label => &subs::format_name($measure),
			value => $slot->{'value'},
			unit => $measure_unit{$key} || '',
			previous => $slot->{'previous'},
			delta => $delta,
			timestamp => $slot->{'timestamp'},
			today => $slot->{'today'} || [],
		};
	}
	@measures = sort { ($b->{'score'} || 0) <=> ($a->{'score'} || 0) || ($b->{'timestamp'} || 0) <=> ($a->{'timestamp'} || 0) } @measures;
	my @measures_shown = @measures[0 .. ($#measures < 5 ? $#measures : 5)];
	my @today_measures;
	foreach my $measure ( @measures_shown ) {
		foreach my $reading ( @{$measure->{'today'}} ) { push @today_measures, $reading; }
	}
	@today_measures = sort { ($a->{'timestamp'} || 0) <=> ($b->{'timestamp'} || 0) } @today_measures;

	# --- open sessions ----------------------------------------------------
	my $running;
	if ($is_today) {
		$running = &subs::db_query(
			"select app,uuid,timestamp from appointments where (type='start' or type='record') and stop_seen is null and cast(timestamp as integer) >= ? and cast(timestamp as integer) <= ? order by cast(timestamp as integer) desc limit 1",
			$start, $now
		)->hashes->[0];
	}
	# a future day has no "earlier" state to read: open sessions belong to the
	# present and the days already behind it. For today the running session is
	# shown on its own, so the list is what came before; a past day reads every
	# session opened up to its own end
	my $open_before = $is_today ? $start : $end;
	my $open = $is_future ? [] : ( &subs::db_query(
		"select app,uuid,timestamp from appointments where (type='start' or type='record') and stop_seen is null and cast(timestamp as integer) < ? order by cast(timestamp as integer) desc limit 8",
		$open_before
	)->hashes || [] );
	if ($running) { @{$open} = grep { ($_->{'uuid'} || '') ne ($running->{'uuid'} || '') } @{$open}; }

	# --- projects ---------------------------------------------------------
	my $project_type = ( grep { ($_->{'name'} || '') eq 'projects' } @{ $index->{'constructs'} || [] } )[0];
	my $project_rows = $project_type ? $project_type->{'rows'} : [];
	my %project_last;
	my @project_apps = map { $_->{'app'} } @{$project_rows};
	if (scalar @project_apps) {
		my $placeholders = join(',', map { '?' } @project_apps);
		my $by_project = &subs::db_query("select project as linked, max(cast(timestamp as integer)) as last from appointments where project in ($placeholders) group by project", @project_apps)->hashes || [];
		foreach my $row ( @{$by_project} ) {
			next unless defined $row->{'linked'} && length $row->{'linked'};
			$project_last{$row->{'linked'}} = $row->{'last'} if ($row->{'last'} || 0) > ($project_last{$row->{'linked'}} || 0);
		}
		my $by_app = &subs::db_query("select app as linked, max(cast(timestamp as integer)) as last from appointments where app in ($placeholders) group by app", @project_apps)->hashes || [];
		foreach my $row ( @{$by_app} ) {
			next unless defined $row->{'linked'} && length $row->{'linked'};
			$project_last{$row->{'linked'}} = $row->{'last'} if ($row->{'last'} || 0) > ($project_last{$row->{'linked'}} || 0);
		}
	}
	my %project_today;
	foreach my $appt ( @{$appts} ) {
		my $project = $appt->{'project'} || '';
		$project_today{$project}++ if length $project;
		$project_today{$appt->{'app'}}++ if defined $appt->{'app'} && length $appt->{'app'};
	}
	my @projects;
	foreach my $row ( @{$project_rows} ) {
		my $app = $row->{'app'} || '';
		next unless length $app;
		my $last = $project_last{$app} || 0;
		my $count = $project_today{$app} || 0;
		next unless $count || ($last && $last >= $now - 30 * 86400000);
		my @names = map { $_->{'name'} } @{ $row->{'members'} || [] };
		@names = @names[0 .. 2] if scalar @names > 3;
		push @projects, {
			app => $app,
			name => $row->{'name'} || &subs::format_name($app),
			count => $count,
			last => $last,
			members => $row->{'member_count'} || 0,
			member_names => \@names,
		};
	}
	my $projects_active = scalar @projects;
	@projects = sort { ($b->{'count'} || 0) <=> ($a->{'count'} || 0) || ($b->{'last'} || 0) <=> ($a->{'last'} || 0) } @projects;
	@projects = @projects[0 .. 5] if scalar @projects > 6;
	# when nothing has moved, name the projects that exist rather than leave the
	# card empty - a quiet month is still part of the state of things
	unless (scalar @projects) {
		foreach my $row ( @{$project_rows} ) {
			my $app = $row->{'app'} || '';
			next unless length $app;
			my @names = map { $_->{'name'} } @{ $row->{'members'} || [] };
			@names = @names[0 .. 2] if scalar @names > 3;
			push @projects, {
				app => $app,
				name => $row->{'name'} || &subs::format_name($app),
				count => 0,
				last => $project_last{$app} || 0,
				members => $row->{'member_count'} || 0,
				member_names => \@names,
			};
			last if scalar @projects >= 5;
		}
	}

	# --- people -----------------------------------------------------------
	# An appointment names people in two ways: its app can be a person construct,
	# or it can belong to a project/construct whose members are people. Both are
	# read, so "lunch" filed under a project still brings the project's people in.
	my $person_members = $index->{'member'}->{'person'} || {};
	my %people_seen;
	foreach my $appt ( @{$appts} ) {
		my $app = $appt->{'app'} || '';
		next unless length $app;
		my @candidates;
		push @candidates, $app if $person_app{$app};
		push @candidates, keys %{ $person_members->{$app} || {} };
		my $project = $appt->{'project'} || '';
		push @candidates, keys %{ $person_members->{$project} || {} } if length $project;
		my %done;
		foreach my $person ( @candidates ) {
			next unless length $person && $person_app{$person} && !$done{$person}++;
			$people_seen{$person} ||= { app => $person, name => &subs::format_name($person), rows => [] };
			push @{$people_seen{$person}->{'rows'}}, {
				app => $app,
				name => &subs::format_name($app),
				timestamp => $appt->{'timestamp'} || 0,
				type => &subs::format_name($appt->{'type'} || 'event'),
			};
		}
	}
	my @people = sort { lc($a->{'name'}) cmp lc($b->{'name'}) } values %people_seen;
	foreach my $person ( @people ) {
		my %done;
		@{$person->{'rows'}} = grep { !$done{ ($_->{'app'} || '') . '|' . ($_->{'timestamp'} || 0) }++ }
			sort { ($a->{'timestamp'} || 0) <=> ($b->{'timestamp'} || 0) } @{$person->{'rows'}};
	}

	# --- the journal ------------------------------------------------------
	my @journal;
	if (scalar @{$appts}) {
		my $first = $appts->[0];
		my $last = $appts->[-1];
		my $first_time = localtime(($first->{'timestamp'} || 0) / 1000)->strftime('%I:%M%p');
		my $last_time = localtime(($last->{'timestamp'} || 0) / 1000)->strftime('%I:%M%p');
		push @journal, sprintf(&subs::ui('The day holds %s records; it began with %s at %s and the last is %s at %s.'),
			scalar @{$appts}, &subs::format_name($first->{'app'}), $first_time, &subs::format_name($last->{'app'}), $last_time);
	}
	else {
		push @journal, $is_future ? &subs::ui('Nothing is planned for this day yet.') : &subs::ui('Nothing was recorded on this day.');
	}
	if ($money->{'spent'} || $money->{'income'}) {
		push @journal, sprintf(&subs::ui('%s went out and %s came in.'), &subs::price_formatter($money->{'spent'}), &subs::price_formatter($money->{'income'}));
	}
	if ($money->{'due'}) {
		push @journal, sprintf(&subs::ui('%s in bills is due.'), &subs::price_formatter($money->{'due'}));
	}
	if ($running) {
		push @journal, sprintf(&subs::ui('%s has been running since %s.'),
			&subs::format_name($running->{'app'}), localtime(($running->{'timestamp'} || 0) / 1000)->strftime('%I:%M%p'));
	}
	if (scalar @{$open} == 1) {
		push @journal, &subs::ui('A session is still open.');
	}
	elsif (scalar @{$open} > 1) {
		push @journal, sprintf(&subs::ui('%s sessions are still open.'), scalar @{$open});
	}
	my @journal_measures = scalar @measures_shown > 2 ? @measures_shown[0, 1] : @measures_shown;
	foreach my $measure ( @journal_measures ) {
		push @journal, sprintf(&subs::ui('Your latest %s is %s%s.'),
			$measure->{'label'}, $measure->{'value'}, $measure->{'unit'} ? ' ' . $measure->{'unit'} : '');
	}
	if (scalar @{$journal}) {
		push @journal, &subs::ui('Something was written in the journal on this day.');
	}
	if ($projects_active) {
		my $touched = grep { ($_->{'count'} || 0) > 0 } @projects;
		push @journal, &subs::ui('One project saw activity.') if $touched == 1;
		push @journal, sprintf(&subs::ui('%s projects saw activity.'), $touched) if $touched > 1;
	}
	if (scalar @people == 1) {
		push @journal, &subs::ui('One person is named in the day.');
	}
	elsif (scalar @people > 1) {
		push @journal, sprintf(&subs::ui('%s people are named in the day.'), scalar @people);
	}

	return {
		start => $start,
		end => $end,
		now => $now,
		today => $today,
		is_today => $is_today,
		is_future => $is_future,
		relative => $relative,
		date_label => $date_label,
		short_date => $short_date,
		day_value => localtime($start / 1000)->strftime('%Y-%m-%d'),
		unread => $bounds->{'unread'} || 0,
		prev_day => localtime(&subs::calendar_shift($start, -1, 'day') / 1000)->strftime('%Y-%m-%d'),
		next_day => localtime(&subs::calendar_shift($start, 1, 'day') / 1000)->strftime('%Y-%m-%d'),
		appointments => \@timeline,
		ghosts => \@ghosts,
		record_count => scalar @{$appts},
		money => $money,
		journal => $journal,
		measures => \@measures_shown,
		today_measures => \@today_measures,
		running => $running,
		open => $open,
		projects => \@projects,
		projects_active => $projects_active,
		people => \@people,
		journal_lines => \@journal,
	};
}

sub help_distance_km($lat1, $lon1, $lat2, $lon2) {
	return 0 unless defined $lat1 && defined $lon1 && defined $lat2 && defined $lon2;
	return great_circle_distance(deg2rad($lon1), deg2rad(90 - $lat1), deg2rad($lon2), deg2rad(90 - $lat2), $gb::planet_radius);
}

sub help_site_rating {
	my $sig = &subs::signatorial_designer();
	my $nav = eval { &subs::navigation_information({ signatorial => $sig, cache => 'yes' }) } || {};
	return $nav->{$sig}->{'site_rating'} // 2;
}

sub help_at_home { return help_site_rating() <= 1 ? 1 : 0; }

sub media_unlock_device($c) {
	my $device = ($c && ($c->session('device_uuid') || '')) || '';
	$device = '' unless $device =~ /^[A-Za-z0-9]{8,64}$/;
	unless (length $device) {
		$device = ($c && ($c->param('device_uuid') || '')) || '';
		$device = '' unless $device =~ /^[A-Za-z0-9]{8,64}$/;
	}
	unless (length $device) {
		$device = $c->session('app_device') || '' if $c;
		$device = '' unless $device =~ /^[A-Za-z0-9]{8,64}$/;
	}
	return $device;
}

sub media_unlock_tab($c) {
	return '' unless $c;
	my $tab = $c->param('browser_tab_id') || $c->session('browser_tab_id') || '';
	$tab = '' unless $tab =~ /^[A-Za-z0-9_-]{1,64}$/;
	return $tab;
}

sub media_unlock_clear {
	my ($device, $app) = @_;
	return 0 unless defined $device && length $device;
	if (defined $app && length $app) {
		my $q = &subs::db_query('delete from cache where context = ? and app = ? and device = ?', 'media_unlock', $app, $device);
		return $q ? $q->rows : 0;
	}
	my $q = &subs::db_query('delete from cache where context = ? and device = ?', 'media_unlock', $device);
	return $q ? $q->rows : 0;
}

sub private_relock {
	my ($c, $tab, $opts) = @_;
	$opts ||= {};
	my $skip_app = $opts->{'skip_app'};
	$tab = '' unless defined $tab && $tab =~ /^[A-Za-z0-9_-]{1,64}$/;
	my @private_open;
	if (length $tab) {
		my $rows = eval {
			&subs::db_query("select distinct app from websockets where type = 'stayingAlive' and browser_tab_id = ?", $tab)->hashes;
		} || [];
		foreach my $row ( @{$rows} ) {
			my $open_app = $row->{'app'} // next;
			next if $open_app =~ /^(?:server|tab|manager)$/;
			next if defined $skip_app && length $skip_app && $open_app eq $skip_app;
			next unless &subs::app_private_now($open_app);
			push @private_open, $open_app;
		}
	}
	# A manual close is not a lock while another private window is still open.
	return 1 if $opts->{'only_if_last'} && scalar @private_open;
	my $device = &media_unlock_device($c);
	&media_unlock_clear($device, 'private') if length $device;
	if ($opts->{'close_windows'}) {
		foreach my $open_app ( @private_open ) {
			&subs::window_closer($open_app, $tab);
		}
	}
	&Websocket::send('server', { console => &Websocket::console_command('jawnosPrivateRefresh', 0), browser_tab_id => $tab }) if length $tab;
	return 1;
}

sub media_unlock_store {
	my ($app, $device, $tab) = @_;
	return '' unless $app && $device;
	my $suds = &subs::suds_grabber() || $gb::suds;
	return '' unless $suds;
	my $token = &subs::note_encrypter($suds, &subs::random_string_creator(255));
	return '' unless defined $token && length $token;
	my $now = &subs::rightNow();
	my $window = &subs::setting_grabber({ app => 'me', setting => 'activity_timeout' }) || '-2h';
	$window = eval { abs &subs::time_abbrev_translator($window) } || 7200000;
	my $until = $now + $window;
	&media_unlock_clear($device, $app);
	&subs::db_query('delete from cache where context = ? and server_time < ?', 'media_unlock', $now - 604800000);
	&subs::db_insert('cache', {
		uuid => &subs::random_string_creator(25),
		context => 'media_unlock',
		app => $app,
		device => $device,
		data => encode_json({ token => $token, tab => ($tab || ''), until => $until }),
		timestamp => $now,
		server_time => $now,
	});
	return $token;
}

sub media_unlock_token {
	my ($app, $device) = @_;
	return '' unless defined $app && length $app && defined $device && length $device;
	my $now = &subs::rightNow();
	my $rows = &subs::db_query('select data from cache where context = ? and app = ? and device = ? order by server_time desc', 'media_unlock', $app, $device)->hashes || [];
	foreach my $r ( @{$rows} ) {
		my $d = eval { decode_json $r->{'data'} } || {};
		next unless ($d->{'until'} || 0) > $now;
		my $token = $d->{'token'} || '';
		return $token if length $token;
	}
	return '';
}

sub help_media_unlocked($device) {
	$device = '' unless defined $device;
	return 0 unless $device =~ /^[A-Za-z0-9]{8,64}$/;
	my $sightings = eval { decode_json &subs::setting_grabber({ app => '__president', setting => 'padlock_contexts' }) } || [];
	my $now = &subs::rightNow();
	my $rows = &subs::db_query('select app, data from cache where context = ? and device = ? order by server_time desc', 'media_unlock', $device)->hashes || [];
	foreach my $r ( @{$rows} ) {
		my $ctx = $r->{'app'} || '';
		next unless grep { $_ eq $ctx } @{$sightings};
		my $d = eval { decode_json $r->{'data'} } || {};
		return 1 if ($d->{'until'} || 0) > $now;
	}
	return 0;
}

sub help_media_revealed {
	my ($device) = @_;
	return help_media_unlocked($device) ? 1 : 0;
}

sub media_grant_open($c) {
	return 1 if &subs::private_revealed();
	return 0 unless $c;
	my $device = &media_unlock_device($c) || $subs::request_device_uuid;
	return 0 unless defined $device && length $device;
	return &help_media_unlocked($device) ? 1 : 0;
}

sub media_unlock_open($c, $app, $max_age = undef) {
	return 0 unless ($c && defined $app && length $app);
	my $token = $c->param('unlock');
	return 0 unless (defined $token && length $token);
	my $sightings = eval { decode_json &subs::setting_grabber({ app => '__president', setting => 'padlock_contexts' }) } || [];
	return 0 unless grep { $_ eq $app } @{$sightings};
	my $device = &media_unlock_device($c);
	return 0 unless (length $device);
	my $suds = &subs::session_suds($c);
	return 0 unless $suds;
	my $given = &subs::note_decrypter($suds, $token);
	return 0 unless (defined $given && length $given);
	my $now = &subs::rightNow();
	my $tab = &media_unlock_tab($c);
	my $rows = &subs::db_query('select data, server_time from cache where context = ? and app = ? and device = ? order by server_time desc', 'media_unlock', $app, $device)->hashes || [];
	foreach my $r ( @{$rows} ) {
		my $d = eval { decode_json $r->{'data'} } || {};
		next unless ($d->{'until'} || 0) > $now;
		# A grant can also be required to be young: the Security app unlocks
		# once for browsing, but replacing the key asks for a fresh print.
		next if (defined $max_age && $max_age > 0 && (($r->{'server_time'} || 0) + $max_age) < $now);
		# a grant names the one window it was minted for; another tab of the
		# same screen, or a reopened one after a crash, holds no way in
		my $grant_tab = $d->{'tab'} || '';
		next if (length $grant_tab && $grant_tab ne $tab);
		my $known = &subs::note_decrypter($suds, $d->{'token'} || '');
		next unless (defined $known && length $known);
		return 1 if secure_compare($given, $known);
	}
	return 0;
}

sub help_app_visible($app, $device = undef) {
	return 0 if &subs::lockdown_active() && &subs::app_hidden_now($app);
	# A private app is not even readable by the Guide outside a private place, and
	# inside one only after the private fingerprint grant (an app's own media
	# padlock is not the same door).
	if (&subs::app_private_now($app)) {
		return 0 unless &subs::private_reachable_now();
		return &subs::private_revealed($device) ? 1 : 0;
	}
	return 1 unless help_app_hidden($app);
	return help_media_revealed($device);
}

1;
