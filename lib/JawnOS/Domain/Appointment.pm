package subs;

# Appointment: extracted from subroutines.pl (package subs). Loaded on
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

our %app_visibility_cache;
our %app_visibility_own_cache;
our %app_visibility_rank_cache;
our %appointment_visibility_cache;
our $device;
our $gb;
our $internet_site_tick_at;
our $lockdown_enemy_apps_cache;
our $presence_relationship_cache;
our $present_person_apps_cache;
our %private_revealed_cache;
# The screen a request speaks for. media_unlock_store keys a fingerprint grant
# by the paired device uuid, not by the machine's device kind (device_setter),
# so the request boundary records the browser's own uuid here.
our $request_device_uuid;
our $visibility_exposure_cache;
our %visibility_graph_links;
our $visibility_graph_ready;
our %visibility_graph_uuid_app;

# An appointment's level is the strictest of its own app and every social
# construct named on the row. The field names come from $gb::social_constructs,
# so every kind - community, club, team, person, project, institution,
# government, corporation, place, vendor, event - is read, not a fixed list;
# `account` is included too. The lowest number wins, so a private project makes
# the record private even when its app is Public.
sub appointment_visibility_rank {
	my ($row) = @_;
	return 4 unless ref $row eq 'HASH';
	my @apps;
	push @apps, $row->{'app'} if defined $row->{'app'} && length $row->{'app'};
	my %field = ( account => 1 );
	foreach my $scons ( values %{$gb::social_constructs} ) {
		my $sing = $scons->{'sing'} // '';
		$field{$sing} = 1 if length $sing;
		my $name = $scons->{'name'} // '';
		$field{$name} = 1 if length $name;
	}
	foreach my $field ( sort keys %field ) {
		my $value = $row->{$field};
		next unless defined $value && length $value;
		$value = &unformat_name($value);
		next unless length $value && $value ne 'all';
		push @apps, $value;
	}
	return 4 unless scalar @apps;
	my $device = &device_setter();
	my $cache_key = $device . "\x1f" . join("\x1f", @apps);
	return $appointment_visibility_cache{$cache_key} if exists $appointment_visibility_cache{$cache_key};
	my $rank = 4;
	foreach my $app ( @apps ) {
		my $r = &app_visibility_rank_effective($app);
		$rank = $r if $r < $rank;
	}
	$appointment_visibility_cache{$cache_key} = $rank;
	return $rank;
}

sub appointment_private_now {
	my ($row) = @_;
	return &appointment_visibility_rank($row) <= 1 ? 1 : 0;
}

# Private is not a place level any more: it is a lock. A private thing is
# hidden everywhere, including at home, and only a live fingerprint grant on
# this screen can show it - and even then only in a private place with no
# enemy present. The place words stay because a lockdown reads the rating.
sub visibility_hidden_for {
	my ($value) = @_;
	return &visibility_normalize($value) eq 'private' ? 1 : 0;
}

# A private thing may only be located in a private place during no lockdown.
# An unknown place reads as public, so a lost fix denies rather than reveals.
sub private_reachable_now {
	return 0 if &lockdown_active();
	return &visibility_exposure() <= 1 ? 1 : 0;
}

sub app_private_now {
	my ($app) = @_;
	return 0 unless defined $app && length $app;
	return &visibility_normalize(&app_visibility_value($app)) eq 'private' ? 1 : 0;
}

sub private_revealed {
	my ($device) = @_;
	$device = $request_device_uuid unless defined $device && length $device;
	return 0 unless defined $device && $device =~ /^[A-Za-z0-9]{8,64}$/;
	return $private_revealed_cache{$device} if exists $private_revealed_cache{$device};
	my $now = &rightNow();
	my $rows = eval {
		&db_query("select data from cache where context = 'media_unlock' and app = 'private' and device = ? order by server_time desc", $device)->hashes;
	} || [];
	my $open = 0;
	foreach my $row ( @{$rows} ) {
		my $d = eval { decode_json($row->{'data'}) } || {};
		if (($d->{'until'} || 0) > $now) { $open = 1; last; }
	}
	$private_revealed_cache{$device} = $open;
	return $open;
}

sub app_hidden_now {
	my ($app) = @_;
	return 0 unless defined $app && length $app;
	if (&lockdown_active()) {
		return 0 if $app eq 'security';
		my $device = &device_setter();
		if (&lockdown_enemy_apps()->{$app}) {
			return &lockdown_revealed($device) ? 0 : 1;
		}
		return 0 if &visibility_normalize(&app_visibility_value($app)) eq 'dangerous';
		return 1;
	}
	return 0 unless &app_private_now($app);
	return 1 unless &private_reachable_now();
	return &private_revealed() ? 0 : 1;
}

sub app_visible_now {
	my ($app) = @_;
	return &app_hidden_now($app) ? 0 : 1;
}

sub internet_domain_app_map {
	my $value = &setting_grabber({ app => 'internet', setting => 'domain_apps' });
	my $map = eval { decode_json($value || '{}') } || {};
	return ref $map eq 'HASH' ? $map : {};
}

# The host a span was really on. key_name is the registrable domain the totals
# use, so a subdomain only survives in the URL; an empty URL falls back to the
# key, which is what every saved or hand-posted span has.
sub internet_site_host {
	my ($url, $fallback) = @_;
	my $host = '';
	if (defined $url && $url =~ m{^[a-z][a-z0-9+.-]*://([^/?#]+)}i) {
		$host = $1;
		$host =~ s/^.*\@//;      # userinfo
		$host =~ s/:\d+$//;      # port
	}
	$host = lc($host);
	$host =~ s/^\[//;
	$host =~ s/\]$//;
	$host =~ s/\.+$//;
	return length $host ? $host : lc($fallback // '');
}

# The app a host belongs to: the most specific assigned site wins, so an
# explicit marketplace.facebook.com assignment beats the facebook.com one while
# every other facebook subdomain still falls back to facebook.com. A bare TLD
# is never a match.
sub internet_site_app_for_host {
	my ($map, $host) = @_;
	return '' unless $map && ref $map eq 'HASH';
	$host = lc($host // '');
	$host =~ s/^\.+//;
	$host =~ s/\.+$//;
	return '' unless length $host;
	my @labels = split /\./, $host;
	for (my $i = 0; $i <= $#labels - 1; $i++) {
		my $candidate = join '.', @labels[$i .. $#labels];
		my $app = $map->{$candidate};
		return $app if defined $app && length $app;
	}
	return '';
}

# A pause keeps one session, and its length is left out of the appointment.
# The paused milliseconds are accumulated by the row's uuid (the cache lives in
# the house database, so a restart keeps them); a close reads them with peeks,
# and the final stop takes and removes them.
sub session_pause_key {
	my ($uuid) = @_;
	return undef unless defined $uuid && length $uuid;
	return {
		app => '__president',
		context => 'session_pause',
		subcontext => substr($uuid, 0, 24),
		warranty => '-2d',
	};
}

sub session_pause_peek {
	my ($uuid) = @_;
	my $key = &session_pause_key($uuid) or return 0;
	my $row = &subs::cache_get($key);
	return ref $row eq 'HASH' ? int($row->{'ms'} // 0) : 0;
}

sub session_pause_add {
	my ($uuid, $app, $ms) = @_;
	my $key = &session_pause_key($uuid) or return 0;
	$ms = int($ms // 0);
	return 0 unless $ms > 0;
	my $row = &subs::cache_get($key);
	my $total = (ref $row eq 'HASH' ? int($row->{'ms'} // 0) : 0) + $ms;
	&subs::cache_set($key, { ms => $total, app => $app // '', at => &rightNow() });
	return $total;
}

sub session_pause_take {
	my ($uuid) = @_;
	my $key = &session_pause_key($uuid) or return 0;
	my $row = &subs::cache_get($key);
	return 0 unless ref $row eq 'HASH';
	&subs::cache_delete($key);
	return int($row->{'ms'} // 0);
}

sub internet_site_appointment_tick {
	my ($opts) = @_;
	$opts ||= {};
	my $now = &rightNow();
	return 0 if !$opts->{'force'} && defined $internet_site_tick_at && $now - $internet_site_tick_at < 2000;
	$internet_site_tick_at = $now;
	my $map = &internet_domain_app_map();
	return 0 unless scalar keys %{$map};
	# A gap over 30 seconds is a pause, not a second visit. The browsers post a
	# span every 30 seconds, so the stop is written one reporting interval later
	# to avoid racing the flush, and the appointment is reopened - the same row,
	# not a new one - if the next page arrives within five minutes. A longer gap
	# is a real departure and starts a new appointment.
	my $pause = 30_000;
	my $quiet = 40_000;
	my $resume = 5 * 60 * 1000;
	my $from = $now - 15 * 60 * 1000;
	my $rows = eval {
		&db_query(q{
			select key_name, url, started_at, ended_at
			  from usage_sessions
			 where kind = 'site' and cast(ended_at as integer) >= ?
			 order by cast(started_at as integer) asc
		}, $from)->hashes;
	} || [];
	my (%run_start, %run_end, %domains_for_app, %span_starts);
	foreach my $domain ( keys %{$map} ) {
		my $app = $map->{$domain} // next;
		push @{$domains_for_app{$app}}, $domain if length $domain;
	}
	foreach my $row ( @{$rows} ) {
		my $host = &internet_site_host($row->{'url'}, $row->{'key_name'});
		my $app = &internet_site_app_for_host($map, $host) || next;
		my $start = int($row->{'started_at'} // 0);
		my $end = int($row->{'ended_at'} // 0);
		next unless $start > 0 && $end > 0;
		push @{$span_starts{$app}}, $start;
		if (!defined $run_end{$app}) {
			$run_start{$app} = $start;
			$run_end{$app} = $end;
		}
		elsif ($start <= $run_end{$app} + $pause) {
			$run_end{$app} = $end if $end > $run_end{$app};
		}
		else {
			$run_start{$app} = $start;
			$run_end{$app} = $end;
		}
	}
	# Sessions this tick owns: close one whose site is no longer reported, or
	# whose app the visibility rule now hides. Never touch a session the person
	# started themselves.
	my $open_rows = eval {
		&db_query(q{
			select app, uuid, timestamp from appointments
			 where lower(source) = 'internet' and (type = 'start' or type = 'record')
			   and stop_seen is null
		})->hashes;
	} || [];
	foreach my $open ( @{$open_rows} ) {
		my $app = $open->{'app'} || next;
		my $uuid = $open->{'uuid'} || next;
		my $started = int($open->{'timestamp'} // 0);
		my $last = $run_end{$app};
		if (!defined $last) {
			# No span for this app in the last quarter hour: find the newest one
			# this session could have been running on, so the stop lands at the
			# last moment the person was really there rather than at this tick.
			my $domains = $domains_for_app{$app} || [];
			if (scalar @{$domains}) {
				my $recent = eval {
					&db_query(q{
						select url, key_name, ended_at
						  from usage_sessions
						 where kind = 'site' and cast(ended_at as integer) >= ?
						 order by cast(ended_at as integer) desc
						 limit 200
					}, $started)->hashes;
				} || [];
				foreach my $span ( @{$recent} ) {
					my $host = &internet_site_host($span->{'url'}, $span->{'key_name'});
					next unless &internet_site_app_for_host($map, $host) eq $app;
					my $end = int($span->{'ended_at'} // 0);
					$last = $end if $end > ($last // 0);
				}
			}
		}
		my $active = defined $last && ($now - $last) <= $quiet && !&app_hidden_now($app);
		if ($active) {
			# A heartbeat for the housekeeping: a machine that stops writing this
			# (a dead battery, a killed browser) leaves a row a peer can close at
			# the last moment it was heard from.
			&db_update('appointments', { server_time => $now }, { uuid => $uuid, app => $app });
			next;
		}
		my $stop_at = (defined $last && $last > $started) ? $last : $now;
		# A session's duration is the negative accrual (start - stop), the sign
		# every other close path writes; a negative value paints the band before
		# the start dot instead of running from it to the recorded end. Sees the
		# pauses accumulated so far, so a resumed visit leaves them out.
		my $paused = &session_pause_peek($uuid);
		my $duration = $started - $stop_at + $paused;
		$duration = 0 if $duration > 0;
		&db_update('appointments', {
			type => 'stop',
			stop_timestamp => $stop_at,
			stop_seen => 'yes',
			duration => $duration,
			server_time => $now,
		}, { uuid => $uuid, app => $app });
		# Remember that this stop was ours, so a span that resumes it within the
		# resume window can reopen the same appointment. A person's own stop is
		# never marked and never reopened.
		&subs::cache_set({
			app => '__president',
			context => 'internet_site_stop',
			subcontext => $app,
			warranty => '-10m'
		}, { uuid => $uuid, at => $stop_at, app => $app });
		&intelligent_automation_toggle({ appt_uuid => $uuid, app => $app, 'state' => 'off', timestamp => $stop_at });
		&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', $app, $uuid)});
	}
	# Sessions to start: a mapped site that is still being reported and has no
	# session of any kind running for its app.
	foreach my $app ( sort keys %run_end ) {
		next if $now - $run_end{$app} > $quiet;
		next if &app_hidden_now($app);
		next if &open_session_uuid($app);
		my $init = &setting_initializer($app, $run_start{$app});
		my $name = (ref $init eq 'HASH' && $init->{'app'}) ? $init->{'app'} : $app;
		next if $name ne $app && (&open_session_uuid($name) || &app_hidden_now($name));
		my $start_at = $run_start{$app};
		# A stop this tick made, with the site back inside the resume window, was
		# navigation rather than a departure: reopen that appointment instead of
		# starting a second one. The stopped row must still be the one the marker
		# names - a person's own stop or a repair is left alone.
		my $marker_key = $name;
		my $marker = &subs::cache_get({ app => '__president', context => 'internet_site_stop', subcontext => $marker_key });
		if (ref $marker ne 'HASH' && $marker_key ne $app) {
			$marker_key = $app;
			$marker = &subs::cache_get({ app => '__president', context => 'internet_site_stop', subcontext => $marker_key });
		}
		if (ref $marker eq 'HASH' && ($marker->{'uuid'} // '') && $start_at < int($marker->{'at'} // 0) + $resume) {
			my $row_app = $marker->{'app'} || $name;
			my $stopped = &db_query('select uuid, stop_timestamp from appointments where app = ? and uuid = ? and type = ? and stop_seen is not null order by cast(stop_timestamp as integer) desc limit 1', $row_app, $marker->{'uuid'}, 'stop')->hash;
			if ($stopped && $stopped->{'uuid'} && abs(int($stopped->{'stop_timestamp'} // 0) - int($marker->{'at'} // 0)) <= 2000) {
				# The gap between the pause and this page is not play time; add it
				# to the row's ledger so the next close leaves it out. The resume
				# begins at the first span after the stop, not at the run's first
				# span (a gap inside the pause threshold keeps the same run).
				my $resume_at = $start_at;
				foreach my $span_start ( @{$span_starts{$app} || []} ) {
					if ($span_start > int($marker->{'at'} // 0)) { $resume_at = $span_start; last; }
				}
				my $gap = $resume_at - int($marker->{'at'} // 0);
				&session_pause_add($stopped->{'uuid'}, $row_app, $gap) if $gap > 0;
				&db_update('appointments', {
					type => 'start',
					stop_timestamp => undef,
					stop_seen => undef,
					duration => undef,
					server_time => $now,
				}, { app => $row_app, uuid => $stopped->{'uuid'} });
				&subs::cache_delete({ app => '__president', context => 'internet_site_stop', subcontext => $marker_key });
				&intelligent_automation_toggle({ appt_uuid => $stopped->{'uuid'}, app => $row_app, 'state' => 'on', timestamp => $now });
				&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', $row_app, $stopped->{'uuid'})});
				next;
			}
			&subs::cache_delete({ app => '__president', context => 'internet_site_stop', subcontext => $marker_key });
		}
		# A session that just ended (a person starting and stopping by hand while
		# the page was open) must not be counted twice.
		my $prev = eval {
			&db_query("select max(cast(stop_timestamp as integer)) as last_end from appointments where app = ? and stop_timestamp is not null and stop_timestamp != '' and cast(stop_timestamp as integer) <= ?", $name, $now)->hash;
		} || {};
		my $prev_end = int($prev->{'last_end'} // 0);
		# A stop at or after the site's last activity is a person closing the
		# session after the tab went quiet (or stopping it by hand). Do not
		# reopen that same run; wait for a span that ends after the stop.
		next if $prev_end >= $run_end{$app};
		$start_at = $prev_end if $prev_end > $start_at;
		my $settings = &settings_grabber({ app => $name });
		my $uuid = &random_string_creator(90);
		my $row = {
			app => $name,
			uuid => $uuid,
			type => 'start',
			timestamp => $start_at,
			server_time => $now,
			device => &device_setter(),
			source => 'internet',
			seen => 'yes',
			project => $settings->{'t_project'},
			pos => $settings->{'pos'},
		};
		$row->{'warranty'} = &ago_calc(($init->{'warranty'} || '-10y'), $now) if ref $init eq 'HASH';
		&db_insert('appointments', $row);
		my ($model, $options, $jmodel, $joptions) = &usual_appointment_maker($row, $settings);
		$row->{'model'} = $jmodel if $jmodel;
		$row->{'options'} = $joptions if $joptions;
		$row->{'unit'} = $model->{'unit'} if $model->{'unit'} && !$row->{'unit'};
		$row->{'quantity'} = $model->{'quantity'} if $model->{'quantity'} && !$row->{'quantity'};
		&db_update('appointments', { model => $row->{'model'}, options => $row->{'options'}, unit => $row->{'unit'}, quantity => $row->{'quantity'} }, { uuid => $uuid, app => $name })
			if $row->{'model'} || $row->{'options'} || $row->{'unit'} || $row->{'quantity'};
		&intelligent_automation_toggle({ appt_uuid => $uuid, app => $name, 'state' => 'on', timestamp => $start_at });
		&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', $name, $uuid)});
	}
	return 1;
}

# The Gou's game helper writes launch.json (state, at, game, title); its input
# daemon writes activity, the last moment a control was touched. A game session
# is one appointment for the games app on this machine: it starts at the launch,
# pauses after half a minute with no control, and resumes - the same row, with
# the pause left out of the play time - on the next touch within five minutes.
sub game_state_dir {
	my $dir = $ENV{'JAWNOS_GAMES_STATE'};
	return defined $dir && length $dir ? $dir : '/run/jawnos-games';
}

sub game_state_json {
	my $path = &game_state_dir() . '/launch.json';
	return {} unless -f $path;
	my $raw = eval { read_file($path) } || '';
	return {} unless length $raw;
	my $data = eval { decode_json($raw) };
	return ref $data eq 'HASH' ? $data : {};
}

sub game_activity_ms {
	my $path = &game_state_dir() . '/activity';
	return 0 unless -f $path;
	my $raw = eval { read_file($path) } || '';
	$raw =~ s/\s+//g;
	return $raw =~ /^\d+$/ ? int($raw) : 0;
}

sub game_session_close {
	my ($open, $stop_at, $now, $mode) = @_;
	my $uuid = $open->{'uuid'} || return 0;
	my $app = $open->{'app'} || 'games';
	my $started = int($open->{'timestamp'} // 0);
	$stop_at = $started if $stop_at < $started;
	$stop_at = $now if !$stop_at || $stop_at > $now;
	my $paused = ($mode // '') eq 'take' ? &session_pause_take($uuid) : &session_pause_peek($uuid);
	my $duration = $started - $stop_at + $paused;
	$duration = 0 if $duration > 0;
	&db_update('appointments', {
		type => 'stop',
		stop_timestamp => $stop_at,
		stop_seen => 'yes',
		duration => $duration,
		server_time => $now,
	}, { uuid => $uuid, app => $app });
	&intelligent_automation_toggle({ appt_uuid => $uuid, app => $app, 'state' => 'off', timestamp => $stop_at });
	&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', $app, $uuid)});
	return 1;
}

sub game_play_appointment_tick {
	my ($opts) = @_;
	$opts ||= {};
	my $now = &rightNow();
	my $launch = &game_state_json();
	return 0 unless ref $launch eq 'HASH' && scalar keys %{$launch};
	my $state = $launch->{'state'} // '';
	my $app = 'games';
	my $device = &device_setter();
	my $title = $launch->{'title'} // '';
	my $game = $launch->{'game'} // '';
	my $launch_at = int($launch->{'at'} // 0) * 1000;
	$launch_at = $now if $launch_at <= 0;
	my $activity = &game_activity_ms();
	$activity = $launch_at if $activity < $launch_at;
	my $marker_key = { app => '__president', context => 'game_stop', subcontext => $app, warranty => '-10m' };
	my $open = &db_query(q{
		select * from appointments
		 where app = ? and lower(source) = 'game' and device = ?
		   and (type = 'start' or type = 'record') and stop_seen is null
		 order by cast(timestamp as integer) desc limit 1
	}, $app, $device)->hash;
	my $marker = &subs::cache_get($marker_key);
	if ($state eq 'done' || $state eq 'failed') {
		if ($open && $open->{'uuid'}) {
			my $finish = int($launch->{'finished'} // 0) * 1000;
			my $stop_at = $activity > 0 ? $activity : $finish;
			&game_session_close($open, $stop_at, $now, 'take');
		}
		elsif (ref $marker eq 'HASH' && ($marker->{'uuid'} // '')) {
			# the row was already closed as a pause; its ledger is finished
			&session_pause_take($marker->{'uuid'});
		}
		&subs::cache_delete($marker_key);
		return 1;
	}
	return 0 unless $state eq 'starting' || $state eq 'running';
	if ($open && $open->{'uuid'}) {
		my $started = int($open->{'timestamp'} // 0);
		if ($now - $activity <= 30_000) {
			&db_update('appointments', { server_time => $now }, { uuid => $open->{'uuid'}, app => $app });
			return 1;
		}
		my $stop_at = $activity > $started ? $activity : $started;
		&game_session_close($open, $stop_at, $now, 'peek');
		&subs::cache_set($marker_key, { uuid => $open->{'uuid'}, at => $stop_at, app => $app, game => $game, title => $title });
		return 1;
	}
	my $new_start = $launch_at;
	if (ref $marker eq 'HASH' && ($marker->{'uuid'} // '')) {
		my $marker_at = int($marker->{'at'} // 0);
		if (($marker->{'game'} // '') eq $game) {
			if ($activity <= $marker_at) {
				# Still paused: no control since the pause. Leave the session
				# closed and wait; the next touch is what resumes it.
				return 1;
			}
			if ($activity < $marker_at + 5 * 60 * 1000) {
				# A resume inside the window continues the same appointment.
				my $row = &db_query('select uuid, timestamp from appointments where uuid = ? and app = ? limit 1', $marker->{'uuid'}, $app)->hash;
				if ($row && $row->{'uuid'}) {
					my $gap = $activity - $marker_at;
					&session_pause_add($row->{'uuid'}, $app, $gap) if $gap > 0;
					&db_update('appointments', { type => 'start', stop_seen => undef, stop_timestamp => undef, server_time => $now }, { uuid => $row->{'uuid'}, app => $app });
					&subs::cache_delete($marker_key);
					&intelligent_automation_toggle({ appt_uuid => $row->{'uuid'}, app => $app, 'state' => 'on', timestamp => $now });
					&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', $app, $row->{'uuid'})});
					return 1;
				}
			}
			# A touch after the window starts a new session; its first segment
			# begins at the touch, not at the old launch.
			$new_start = $activity;
		}
		&subs::cache_delete($marker_key);
	}
	my $settings = &settings_grabber({ app => $app });
	my $uuid = &random_string_creator(90);
	my $row = {
		app => $app,
		uuid => $uuid,
		type => 'start',
		timestamp => $new_start,
		server_time => $now,
		device => $device,
		source => 'game',
		seen => 'yes',
		project => length $title ? $title : $settings->{'t_project'},
		pos => $settings->{'pos'},
	};
	&db_insert('appointments', $row);
	&intelligent_automation_toggle({ appt_uuid => $uuid, app => $app, 'state' => 'on', timestamp => $new_start });
	&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', $app, $uuid)});
	return 1;
}

# A browser game (Cards' Solitaire, Mahjong and Blackjack, and Twirl) has no
# input daemon to write activity, so the page reports its own touches. The
# session is the Gou's shape: one Games row on this device, named by its game;
# quiet for half a minute closes it at the last touch, a touch within five
# minutes reopens the same row, and a longer gap starts a new one.
# The game is an option of the Games appointment, not a second session: the
# catalog row is what the details view lists, and the parent's options JSON is
# what marks it selected. The row is made on first play and is never a default,
# so a new Games appointment does not collect every game it could have been.
sub browser_game_option {
	my ($game, $now) = @_;
	my $row = &db_select('option', undef, { app => 'games', name => $game })->hashes->[0];
	return $row if $row && ($row->{'uuid'} // '') ne '';
	$now ||= &rightNow();
	$row = {
		app => 'games',
		name => $game,
		uuid => &random_string_creator(40),
		timestamp => $now,
		server_time => $now,
		def => 'off',
		quantity => 1,
		unit => 'games',
		save_app => '',
		description => $game,
	};
	&db_insert('option', $row);
	return $row;
}

sub browser_game_option_attach {
	my ($uuid, $game, $at, $now) = @_;
	return unless ($uuid // '') ne '';
	my $option = &browser_game_option($game, $now);
	return unless $option && ($option->{'uuid'} // '') ne '';
	&source_model_option_add($uuid, 'option', {
		uuid => $option->{'uuid'},
		name => $game,
		timestamp => $at,
		quantity => 1,
		unit => 'games',
		delay_start => $option->{'delay_start'},
		delay_stop => $option->{'delay_stop'},
	});
}

sub browser_game_play {
	my ($opts) = @_;
	$opts ||= {};
	my %allowed = map { $_ => 1 } qw(Solitaire Mahjong Blackjack Twirl);
	my $game = $opts->{'game'} // '';
	$game =~ s/^\s+//;
	$game =~ s/\s+$//;
	return { ok => 0, error => 'That game does not save play time.' } unless $allowed{$game};
	my $state = $opts->{'state'} // 'play';
	return { ok => 0, error => 'That play state is not known.' } unless $state =~ /^(?:play|pause|stop)$/;
	my $now = &rightNow();
	my $device = $opts->{'device'} // &device_setter();
	my $at = int($opts->{'at'} // 0);
	$at = $now if $at <= 0 || $at > $now;
	my $source = 'browser_game';
	my $tag = substr(sha256_hex(join "\0", $source, $device // '', $game), 0, 24);
	my $marker_key = { app => '__president', context => 'game_stop', subcontext => $tag, warranty => '-10m' };
	my $open = &db_query(q{
		select * from appointments
		 where app = 'games' and lower(source) = ? and device = ? and project = ?
		   and (type = 'start' or type = 'record') and stop_seen is null
		 order by cast(timestamp as integer) desc limit 1
	}, $source, $device, $game)->hash;

	if ($state eq 'pause' || $state eq 'stop') {
		if ($open && $open->{'uuid'}) {
			my $started = int($open->{'timestamp'} // 0);
			my $stop_at = $at > $started ? $at : $started;
			&game_session_close($open, $stop_at, $now, $state eq 'pause' ? 'peek' : 'take');
			if ($state eq 'pause') {
				&subs::cache_set($marker_key, {
					uuid => $open->{'uuid'},
					at => $stop_at,
					app => 'games',
					game => $game,
					source => $source,
					device => $device,
				});
			}
		}
		if ($state eq 'stop') { &subs::cache_delete($marker_key); }
		return { ok => 1, state => $state };
	}

	if ($open && $open->{'uuid'}) {
		&db_update('appointments', { server_time => $now }, { uuid => $open->{'uuid'}, app => 'games' });
		return { ok => 1, state => 'running' };
	}

	my $marker = &subs::cache_get($marker_key);
	my $new_start = $at;
	if (ref $marker eq 'HASH' && ($marker->{'uuid'} // '')) {
		my $marker_at = int($marker->{'at'} // 0);
		if (($marker->{'game'} // '') eq $game && ($marker->{'device'} // '') eq $device) {
			if ($at <= $marker_at) { return { ok => 1, state => 'paused' }; }
			if ($at < $marker_at + 5 * 60 * 1000) {
				my $row = &db_query('select uuid, timestamp from appointments where uuid = ? and app = ? limit 1', $marker->{'uuid'}, 'games')->hash;
				if ($row && $row->{'uuid'}) {
					my $gap = $at - $marker_at;
					&session_pause_add($row->{'uuid'}, 'games', $gap) if $gap > 0;
					&db_update('appointments', {
						type => 'start',
						stop_seen => undef,
						stop_timestamp => undef,
						server_time => $now,
					}, { uuid => $row->{'uuid'}, app => 'games' });
					&subs::cache_delete($marker_key);
					&intelligent_automation_toggle({ appt_uuid => $row->{'uuid'}, app => 'games', 'state' => 'on', timestamp => $now });
					&browser_game_option_attach($row->{'uuid'}, $game, $at, $now);
					&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', 'games', $row->{'uuid'})});
					return { ok => 1, state => 'resumed' };
				}
			}
		}
		&subs::cache_delete($marker_key);
	}

	my $settings = &settings_grabber({ app => 'games' });
	my $uuid = &random_string_creator(90);
	my $row = {
		app => 'games',
		uuid => $uuid,
		type => 'start',
		timestamp => $new_start,
		server_time => $now,
		device => $device,
		source => $source,
		seen => 'yes',
		project => $game,
		pos => $settings->{'pos'},
	};
	&db_insert('appointments', $row);
	&browser_game_option_attach($uuid, $game, $new_start, $now);
	&intelligent_automation_toggle({ appt_uuid => $uuid, app => 'games', 'state' => 'on', timestamp => $new_start });
	&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', 'games', $uuid)});
	return { ok => 1, state => 'started' };
}

# An open session whose machine stopped reporting - a Gou whose battery died,
# a browser killed, a manager that was down - is closed at the last moment it
# was heard from, not at this tick. Only the two sources the house writes
# itself are touched; a session a person started is left alone.
sub session_housekeeping_tick {
	my $now = &rightNow();
	my $stale = 10 * 60 * 1000;
	my $rows = eval {
		&db_query(q{
			select app, uuid, timestamp, server_time from appointments
			 where lower(source) in ('internet', 'game', 'browser_game')
			   and (type = 'start' or type = 'record') and stop_seen is null
		})->hashes;
	} || [];
	my $closed = 0;
	foreach my $open ( @{$rows} ) {
		my $uuid = $open->{'uuid'} || next;
		my $app = $open->{'app'} || next;
		my $started = int($open->{'timestamp'} // 0);
		my $beat = int($open->{'server_time'} // 0) || $started;
		next if $now - $beat <= $stale;
		my $stop_at = $beat > $started ? $beat : $started;
		$stop_at = $now if $stop_at > $now;
		my $paused = &session_pause_take($uuid);
		my $duration = $started - $stop_at + $paused;
		$duration = 0 if $duration > 0;
		&db_update('appointments', {
			type => 'stop',
			stop_timestamp => $stop_at,
			stop_seen => 'yes',
			duration => $duration,
			server_time => $now,
		}, { uuid => $uuid, app => $app });
		&intelligent_automation_toggle({ appt_uuid => $uuid, app => $app, 'state' => 'off', timestamp => $stop_at });
		&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', $app, $uuid)});
		$closed++;
	}
	return $closed;
}

# A settings write or a presence change must be seen by the rest of this
# request; a worker serves one request at a time, so these are request caches.
sub visibility_cache_clear {
	%app_visibility_cache = ();
	%app_visibility_own_cache = ();
	%app_visibility_rank_cache = ();
	%appointment_visibility_cache = ();
	%visibility_graph_links = ();
	%visibility_graph_uuid_app = ();
	$visibility_graph_ready = 0;
	%private_revealed_cache = ();
	$visibility_exposure_cache = undef;
	$presence_relationship_cache = undef;
	$present_person_apps_cache = undef;
	$lockdown_enemy_apps_cache = undef;
	return 1;
}

# The plate remembers how its latest navigation stop happened. A departure more
# than three radii away is certain - no ordinary GPS jitter brings a person back
# from there - so a return must start a new session instead of reopening the one
# it closed. A near-boundary stop stays resumable for the reopen window in
# navigation_automation (three navigation intervals, capped at twenty minutes).
# The fact is transient (a cache entry), but it only has to outlive the next fix
# and the resume window.
sub navigation_plate_exit_set {
	my ($app, $duty, $certain) = @_;
	return unless $app && $duty;
	&subs::cache_set({
		app => '__president',
		context => 'navigation_plate_exit',
		subcontext => $app . ':' . $duty,
		warranty => '-1h'
	}, { certain => ($certain ? 1 : 0), at => &subs::rightNow() });
}

sub navigation_plate_exit_certain {
	my ($app, $duty) = @_;
	return 0 unless $app && $duty;
	my $exit = &subs::cache_get({ app => '__president', context => 'navigation_plate_exit', subcontext => $app . ':' . $duty });
	return (ref $exit eq 'HASH' && $exit->{'certain'}) ? 1 : 0;
}

sub navigation_plate_exit_clear {
	my ($app, $duty) = @_;
	return unless $app && $duty;
	&subs::cache_delete({ app => '__president', context => 'navigation_plate_exit', subcontext => $app . ':' . $duty });
}

# A departure more than three radii from a plate is a certain leave: no ordinary
# GPS jitter brings a person back to that plate from there. A loose fix is not
# certainty - 200 m is the house's own bound on a usable place - so a coarse
# reading does not count.
sub navigation_plate_certain_exit {
	my $data = shift || {};
	my $radius = 0 + ($data->{'radius'} || 0);
	return 0 unless $radius > 0;
	my $measured = 0 + ($data->{'measured'} || 0);
	my $accuracy = 0 + ($data->{'accuracy'} || 0);
	return 0 if $accuracy >= 200;
	return $measured > 3 * $radius ? 1 : 0;
}

# The details bar offers autostop only where navigation_automation can act on it:
# a duty needs a radius and an action, and a place for the plate to measure from -
# its own coordinates, or the app's base plate, or the house's. A duty with no
# radius, or with its action left on none, never moves a session, so a switch
# built for it would promise something no fix ever acts on.
sub home_plate_stop_armed {
	my $data = shift || {};
	my $duties = $data->{'duties'};
	return 0 unless ref $duties eq 'ARRAY';
	my $plate = (ref $data->{'plate'} eq 'HASH') ? $data->{'plate'} : {};
	my $house = (ref $data->{'house'} eq 'HASH') ? $data->{'house'} : {};
	my $origin = ($plate->{'latitude'} && $plate->{'longitude'}) || ($house->{'latitude'} && $house->{'longitude'});
	foreach my $duty ( @{$duties} ) {
		next unless ref $duty eq 'HASH';
		next unless (0 + ($duty->{'distance'} || 0)) > 0;
		next unless (($duty->{'action'} || 'none') ne 'none');
		next unless $origin || ($duty->{'latitude'} && $duty->{'longitude'});
		return 1;
	}
	return 0;
}

# How long a stopped plate visit may reopen instead of starting a new session:
# three navigation intervals, so the window follows the pace that produced the
# fixes, never longer than twenty minutes - a slow machine's pace must not keep
# yesterday's visit resumable all evening. The certain-exit cache lives an hour,
# which comfortably outlives this cap.
sub navigation_reopen_window {
	my ($signatorial) = @_;
	my $window = 3 * &navigation_interval($signatorial) * 1000;
	my $cap = 20 * 60 * 1000;
	return $window > $cap ? $cap : $window;
}

sub navigation_automation {
	my ($returner, $provider) = @_;
	$returner->{'signatorial'} = &subs::signatorial_designer() unless $returner->{'signatorial'};
	my $signatorial = $returner->{'signatorial'};

	# Only a fix a real GPS produced may cross a plate. The browser's network
	# estimate and a desktop's home-plate fallback carry no provider, and both
	# are exactly the plausible-looking place that must not move an appointment.
	return unless (($provider || '') eq 'gps');

	my $cache = &subs::cache_get({ app => '__president', context => 'navigation_automation', subcontext => $signatorial });
	return if $cache && ($cache->{'timestamp'} || 0) + 5000 > &subs::rightNow();
	&subs::cache_set({ app => '__president', context => 'navigation_automation', subcontext => $signatorial }, { timestamp => &subs::rightNow() });


	my $device = &subs::device_setter();
	my $hpds = &subs::db_query('select * from settings where setting=? and value is not null and value != ?', 'home_plate_duties', '[]')->hashes;
	foreach my $hpder ( @{$hpds} ) {
		my $home_plate = eval { return decode_json &subs::setting_grabber({ app => $hpder->{'app'}, setting => 'home_plate' }) || &subs::setting_grabber({ app => 'me', setting => 'home_plate' }) } || {};
		if ($home_plate->{'latitude'}) {
			my $hpd = eval { return decode_json $hpder->{'value'} } || [];
			foreach my $hp ( @{$hpd} ) {
				$hp->{'distance'} = 0.2 unless (defined $hp->{'distance'} && length $hp->{'distance'});
				my $plate_device = $hp->{'device'} || '';
				if (!$plate_device || $plate_device eq $signatorial || $plate_device eq $device) {
				my $app = $hpder->{'app'};
				next unless $app;
				# a duty may carry its own ground (one app, many plates); otherwise
				# the app's own home_plate is the plate
				my $plate_lat = $hp->{'latitude'} || $home_plate->{'latitude'};
				my $plate_lon = $hp->{'longitude'} || $home_plate->{'longitude'};
				next unless $plate_lat && $plate_lon;
				my @home_plate = (deg2rad($plate_lon), deg2rad(90 - $plate_lat));
					my @visitor = (deg2rad($returner->{'longitude'}), deg2rad(90 - $returner->{'latitude'}));
					my $distance = sprintf("%.3f", great_circle_distance(@home_plate, @visitor, $gb::planet_radius));
					my $duty_key = $hp->{'uuid'};
					$duty_key = join('|', $hpder->{'app'} || '', $app || '', $hp->{'placement'} || '', $hp->{'distance'} || '', $hp->{'action'} || '') unless $duty_key;
					# A stop-side fix farther than three radii is a certain leave. The
					# comparison only matters when the person comes back: that return
					# starts a new session instead of reopening the closed one.
					my $certain_exit = &subs::navigation_plate_certain_exit({
						radius => $hp->{'distance'},
						measured => $distance,
						accuracy => $returner->{'accuracy'},
					});
					my $actable = 0;
					my $cactable = 0;

					my $hset = &subs::settings_grabber({ app => $app, settings => [ 'warranty', 'toggle', 'site_type'] });
					my $tog = &subs::appt_toggle_checker($app) || $hset->{'toggle'};
					my $hpdata = {
						app => $app,
						timestamp => &subs::rightNow(),
						type => $hp->{'action'},
						subtype => 'navigation',
						uuid => &subs::random_string_creator(22)
					};
					if (($hp->{'placement'} || '') eq 'within') {
						if ($distance <= $hp->{'distance'}) {
							if (($hset->{'site_type'} || '') eq 'dangerous') {
							#	&subs::leave();
							}
							elsif (($tog || '') ne 'on') {
								# A return within the reopen window of a navigation stop is the
								# same visit, so reopen that session rather than starting a new
								# one. The window is three navigation intervals, capped at twenty
								# minutes (see navigation_reopen_window), so it follows the pace
								# that produced the fixes without keeping an old visit resumable
								# all evening. A leave farther than three radii was certain, so
								# its return starts a new session even inside the window. Reopen
								# only the newest stop - the one the person has just come back
								# from - never every stop in the window.
								my $reopen_window = &subs::navigation_reopen_window($signatorial);
								my $lappts = &subs::db_query('select * from appointments where app = ? and subtype = ? and type = ? and stop_timestamp >= ? order by stop_timestamp desc limit 1', $app, 'navigation', 'stop', &subs::rightNow() - $reopen_window)->hashes;
								my $certain_leave = &subs::navigation_plate_exit_certain($app, $duty_key);
								&subs::navigation_plate_exit_clear($app, $duty_key);
								if (scalar @{$lappts} > 0 && !$certain_leave) {
									foreach my $lapp ( @{$lappts} ) {
										$hpdata->{'uuid'} = $lapp->{'uuid'};
										# reopen the session it closed when the plate was left. stop_seen
										# must be cleared too: the stop resolvers (stop_target_row /
										# open_session_uuid) define the open session as one with stop_seen
										# null, so leaving it set left the row open but invisible - the
										# plate's own next leave and return then had nothing to close or
										# reopen (a "returning home" that never logged).
										&subs::db_update('appointments', {
											type => $hp->{'action'},
											stop_timestamp => undef,
											stop_seen => undef,
											server_time => &subs::rightNow(),
											duration => undef
										}, { app => $app, uuid => $lapp->{'uuid'} });
									}
									$actable = 0;
									$cactable = 1;
								} else {
									$actable = 1;
									$cactable = 1;
								}
							}
							else {
								# Back inside with the session still running: the departure is
								# over, so a later stop starts a fresh certainty.
								&subs::navigation_plate_exit_clear($app, $duty_key);
							}
						}
						else {
							# A far fix upgrades the departure even when nothing was running
							# to stop (a near first fix may already have closed the session).
							&subs::navigation_plate_exit_set($app, $duty_key, 1) if $certain_exit;
							if ($tog eq 'on') {
								my $stop_uuid;
								# Newest first, so the session the person is running is the one
								# the plate considers before any older open row.
								my $lappts = &subs::db_query('select uuid,app,type,subtype,timestamp,server_time,autostop from appointments where app=? and (type = ? or type =?) and stop_seen is null and timestamp < ? order by timestamp desc', $app, 'start','record',$returner->{'timestamp'})->hashes;
								foreach my $lappt ( @{$lappts} ) {
									# The details bar can switch autostop off for this run: the
									# plate must leave the session alone for a hand stop.
									next if (($lappt->{'autostop'} || '') eq 'off');
									# an appointment the navigation itself started was started
									# here, so leaving the plate closes it; a hand-started one
									# still needs a recorded in-plate fix before it is touched
									if ($lappt->{'subtype'} eq 'navigation') {
										$stop_uuid = $lappt->{'uuid'};
										last;
									}
									my $locals = &subs::db_query('select * from continent where app=? and uuid like ? and signatorial=?', $app, $lappt->{'uuid'} . '%',$signatorial)->hashes;
									foreach my $local ( @{$locals} ) {
										my @visitor = (deg2rad($local->{'longitude'}), deg2rad(90 - $local->{'latitude'}));
										my $distance = sprintf("%.3f", great_circle_distance(@home_plate, @visitor, $gb::planet_radius));
										if ($distance <= $hp->{'distance'}) {
											$stop_uuid = $lappt->{'uuid'};
											last;
										}
									}
									last if $stop_uuid;
								}
								if ($stop_uuid) {
									$hpdata->{'type'} = 'stop';
									# Name the row the plate checked, so the stop closes exactly it
									# rather than whichever open session is newest.
									$hpdata->{'uuid'} = $stop_uuid;
									$actable = 1;
									$cactable = 1;
									&subs::navigation_plate_exit_set($app, $duty_key, $certain_exit);
								}
							}
						}
					}
					if (($hp->{'placement'} || '') eq 'without') {
						if ($distance >= $hp->{'distance'}) {
							if (($tog || '') ne 'on') {
								$actable = 1;
								$cactable = 1;
							}
						}
						else {
							if ($tog eq 'on') {
								my $stop_uuid;
								my $lappts = &subs::db_query('select uuid,app,type,subtype,timestamp,server_time,autostop from appointments where app=? and (type = ? or type =?) and stop_seen is null and timestamp < ? order by timestamp desc', $app, 'start','record',$returner->{'timestamp'})->hashes;
								foreach my $lappt ( @{$lappts} ) {
									# Autostop off on the details bar keeps this run alive past
									# the plate; the person will stop it by hand.
									next if (($lappt->{'autostop'} || '') eq 'off');
									# an appointment the navigation itself started was started
									# here, so leaving the plate closes it; a hand-started one
									# still needs a recorded in-plate fix before it is touched
									if ($lappt->{'subtype'} eq 'navigation') {
										$stop_uuid = $lappt->{'uuid'};
										last;
									}
									my $locals = &subs::db_query('select * from continent where app=? and uuid like ? and signatorial=?', $app, $lappt->{'uuid'} . '%',$signatorial)->hashes;
									foreach my $local ( @{$locals} ) {
										my @visitor = (deg2rad($local->{'longitude'}), deg2rad(90 - $local->{'latitude'}));
										my $distance = sprintf("%.3f", great_circle_distance(@home_plate, @visitor, $gb::planet_radius));
										if ($distance >= $hp->{'distance'}) {
											$stop_uuid = $lappt->{'uuid'};
											last;
										}
									}
									last if $stop_uuid;
								}
								if ($stop_uuid) {
									$hpdata->{'type'} = 'stop';
									$hpdata->{'uuid'} = $stop_uuid;
									$actable = 1;
									$cactable = 1;
								}
							}
						}
					}

					if ($actable == 1) {
						&Manager::appointment_writer(undef, $hpdata);

					}
					if ($cactable == 1) {
						my $cdata = {
							timestamp => $returner->{'timestamp'},
							latitude => $returner->{'latitude'},
							longitude => $returner->{'longitude'},
							accuracy => sprintf("%.2F", $returner->{'accuracy'}),
							server_time => &subs::rightNow(),
							uuid => $hpdata->{'uuid'} . '-' . &subs::random_string_creator(8),
							type => 'app',
							app => $app,
							warranty => &subs::ago_calc($hset->{'warranty'}, &subs::rightNow()),
							signatorial => $signatorial
						};
						&subs::db_insert('continent', $cdata);
					}
				}
			}
		}
	}

	&subs::navigation_information();
}

# The hour of the day each app most often happens at, over the recent past, in
# one query for every app. The clothesline reads in the order the day does, so
# this gives it that order; it also names the apps whose routine is regular
# enough to hang themselves, and the hour to hang them at. `hour_days` is how
# many of the days the anchor hour was seen on, `days` how many days the app was
# seen at all.
sub clothesline_daily_hours {
	my $days = 14;
	my $now = &rightNow();
	my $since = $now - ($days * 86400 * 1000);
	my $rows = &db_query('select app, timestamp from appointments where timestamp >= ? and timestamp <= ? and type in (?, ?)', $since, $now, 'usual', 'stop')->hashes;
	my (%hour_days, %app_days);
	foreach my $r ( @{$rows} ) {
		next unless $r->{'timestamp'};
		my $time = localtime($r->{'timestamp'} / 1000);
		my ($hour, $yday) = ($time->[2], $time->[7]);
		$hour_days{$r->{'app'}}->{$hour}->{$yday} = 1;
		$app_days{$r->{'app'}}->{$yday} = 1;
	}
	my $out = {};
	foreach my $app ( keys %hour_days ) {
		my ($best, $bestc) = (undef, -1);
		foreach my $h ( keys %{$hour_days{$app}} ) {
			my $c = scalar keys %{$hour_days{$app}->{$h}};
			if ($c > $bestc) { ($best, $bestc) = ($h, $c); }
		}
		$out->{$app} = { hour => $best, hour_days => $bestc, days => scalar keys %{$app_days{$app}} };
	}
	return $out;
}

1;
