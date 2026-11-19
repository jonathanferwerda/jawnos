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

# A game session shorter than a minute is not time the person played: opening
# the app and leaving it, or a launch that failed, would otherwise leave a
# record in the day.
our $GAME_MIN_PLAY_MS = 60 * 1000;
# Half a minute without a control is the quiet the tick pauses at, and also the
# longest gap a browser game may report as play in one step.
our $GAME_QUIET_MS = 30 * 1000;

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

# A model or option session is a child linked by source_uuid. A game session
# written from the browser carries the game's own app too - the `solitaire`
# option writes a `solitaire` row - so that app's history follows the play.
# The child takes the parent's span and its duration: the pause the parent
# leaves out of its play time is left out of the child's too.
sub game_session_child_close {
	my ($uuid, $stop_at, $duration, $now) = @_;
	return 0 unless ($uuid // '') ne '';
	my $children = &db_select('appointments', undef, { source_uuid => $uuid })->hashes || [];
	my $closed = 0;
	foreach my $child ( @{$children} ) {
		next unless ($child->{'type'} // '') =~ /^(?:start|record)$/;
		&db_update('appointments', {
			type => 'stop',
			stop_timestamp => $stop_at,
			stop_seen => 'yes',
			duration => $duration,
			server_time => $now,
		}, { uuid => $child->{'uuid'}, app => $child->{'app'} });
		$closed++;
	}
	return $closed;
}

# A touch that resumes the Games row reopens the children it closed, so a game
# paused for half a minute comes back on the same session rather than a second
# row in its own app.
sub game_session_child_reopen {
	my ($uuid, $now) = @_;
	return 0 unless ($uuid // '') ne '';
	my $children = &db_select('appointments', undef, { source_uuid => $uuid })->hashes || [];
	my $reopened = 0;
	foreach my $child ( @{$children} ) {
		next unless ($child->{'type'} // '') =~ /^(?:stop|cancel|pause)$/;
		&db_update('appointments', {
			type => 'start',
			stop_seen => undef,
			stop_timestamp => undef,
			server_time => $now,
		}, { uuid => $child->{'uuid'}, app => $child->{'app'} });
		$reopened++;
	}
	return $reopened;
}

# A game the person opened but did not play is not a record. Drop the row, the
# game's own app child and the pause ledger, and tombstone the deletion so every
# machine drops its copy too. A real stop under a minute comes here; a pause is
# left for its resume window (session_housekeeping_tick discards it if the person
# never comes back).
sub game_session_discard {
	my ($open, $now) = @_;
	my $uuid = $open->{'uuid'} || return 0;
	my $app = $open->{'app'} || 'games';
	$now ||= &rightNow();
	my $children = &db_select('appointments', undef, { source_uuid => $uuid })->hashes || [];
	foreach my $child ( @{$children} ) {
		next unless ($child->{'uuid'} // '') ne '' && ($child->{'app'} // '') ne '';
		&subs::records_tombstone($child->{'app'}, $child->{'uuid'});
	}
	&subs::records_tombstone($app, $uuid);
	&session_pause_take($uuid);
	&subs::cache_delete(&browser_game_beat_key($uuid)) if &browser_game_beat_key($uuid);
	&intelligent_automation_toggle({ appt_uuid => $uuid, app => $app, 'state' => 'off', timestamp => $now });
	&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', $app, $uuid)});
	return 1;
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
	# A stop with no measured play is a glance at the game or a failed launch, not
	# a session: drop it rather than keeping a record of nothing. The Gou's launch
	# tick opens a session at the launch, so a short stop there is still a glance;
	# a browser game starts only when the person touches the table (12_cards.js),
	# so any play it measured, however short, is real and stays in the day.
	my $browser_play = lc($open->{'source'} // '') eq 'browser_game';
	my $no_play = $browser_play ? ($duration == 0) : (abs($duration) < $GAME_MIN_PLAY_MS);
	return &game_session_discard($open, $now)
		if ($mode // '') eq 'take' && $no_play;
	&db_update('appointments', {
		type => 'stop',
		stop_timestamp => $stop_at,
		stop_seen => 'yes',
		duration => $duration,
		server_time => $now,
	}, { uuid => $uuid, app => $app });
	&subs::cache_delete(&browser_game_beat_key($uuid)) if &browser_game_beat_key($uuid);
	&game_session_child_close($uuid, $stop_at, $duration, $now);
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
					&game_session_child_reopen($row->{'uuid'}, $now);
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
	# The first run of an app takes its born settings - the warranty included -
	# from the house's `me` defaults; later runs read the row it adopted. This is
	# the initializer appointment_writer uses. A spec that does not resolve to a
	# moment ahead of now falls back to the writer's -10y rather than the row's
	# own stamp, which the next cull would take as already expired.
	my $init = &setting_initializer($app, $new_start);
	my $warranty = &ago_calc(($init->{'warranty'} || '-10y'), $now);
	$warranty = &ago_calc('-10y', $now) unless defined $warranty && $warranty =~ /^\d{12,}$/ && $warranty > $now;
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
		warranty => $warranty,
	};
	&db_insert('appointments', $row);
	&intelligent_automation_toggle({ appt_uuid => $uuid, app => $app, 'state' => 'on', timestamp => $new_start });
	&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', $app, $uuid)});
	return 1;
}

# A browser game (Cards' Solitaire, Spider Solitaire, Mahjong and Blackjack, and
# Twirl) has no input daemon to write activity, so the page reports its own
# touches. The session is the Gou's shape: one Games row on this device, named
# by its game;
# quiet for half a minute closes it at the last touch, a touch within five
# minutes reopens the same row, and a longer gap starts a new one.
# The game is an option of the Games appointment and is also its own app: the
# catalog row is what the details view lists, the parent's options JSON marks it
# selected, and save_app on makes the game's own app (the `solitaire` the person
# already has) a child row over the same span. The row is made on first play and
# is never a default, so a new Games appointment does not collect every game it
# could have been.
# A game option is filed under one option category named Games: the details
# view groups its rows by category, and an option with none draws no heading,
# so the played game would not show under the appointment it belongs to. The
# category's uuid is fixed so every machine that receives this code agrees on
# the row it syncs.
sub browser_game_option_category {
	my ($now) = @_;
	$now ||= &rightNow();
	my $uuid = 'games_option_category_v1';
	my $row = &db_select('option_category', undef, { app => 'games', uuid => $uuid })->hashes->[0];
	return $row if $row && ($row->{'uuid'} // '') ne '';
	$row = {
		app => 'games',
		name => 'Games',
		uuid => $uuid,
		timestamp => $now,
		server_time => $now,
	};
	&db_insert('option_category', $row);
	return $row;
}

# The characteristics a game option carries: the Games category, and whatever
# other characteristics the row already had. A fixed characteristic uuid and
# the row's own first stamp keep the JSON stable across the every-touch call,
# so a resume does not rewrite the catalog row just to say the same thing.
sub browser_game_option_characteristics {
	my ($option_uuid, $existing, $now) = @_;
	my $chars = eval { decode_json($existing // '') };
	$chars = [] unless ref $chars eq 'ARRAY';
	my ($prior) = grep { ref $_ eq 'HASH' && ($_->{'name'} // '') eq 'option_category' } @{$chars};
	my @others = grep { ref $_ eq 'HASH' && ($_->{'name'} // '') ne 'option_category' } @{$chars};
	my $stamp = (ref $prior eq 'HASH' && defined $prior->{'timestamp'}) ? $prior->{'timestamp'} : $now;
	return encode_json([
		{
			name => 'option_category',
			value => 'games_option_category_v1',
			timestamp => $stamp,
			uuid => 'games_option_category_' . $option_uuid,
		},
		@others,
	]);
}

sub browser_game_option {
	my ($game, $now) = @_;
	$now ||= &rightNow();
	&browser_game_option_category($now);
	# The hand-made option for a game wrote its name in whatever case the person
	# chose (`solitaire`), so an exact-name lookup made a second row (`Solitaire`)
	# the first time the browser played it. Match the name without case, prefer
	# the browser's own row, and reuse that one row from then on.
	my $row = &db_query(q{
		select * from option
		 where app = 'games' and lower(trim(name)) = lower(?)
		 order by case when name = ? then 0 else 1 end,
		          case when save_app = '' or save_app is null then 0 else 1 end,
		          cast(timestamp as integer) desc
		 limit 1
	}, $game, $game)->hash;
	if (!$row || ($row->{'uuid'} // '') eq '') {
		my $uuid = &random_string_creator(40);
		$row = {
			app => 'games',
			name => $game,
			uuid => $uuid,
			timestamp => $now,
			server_time => $now,
			def => 'off',
			quantity => 1,
			unit => 'games',
			save_app => 'on',
			description => $game,
			characteristics => &browser_game_option_characteristics($uuid, '', $now),
		};
		&db_insert('option', $row);
		return $row;
	}
	# Save app on: the game also records its own app, whose key is
	# unformat_name(name), so `Solitaire` lands on the existing `solitaire` app
	# with its earlier recordings and not on a second `Solitaire` app.
	my $want = &browser_game_option_characteristics($row->{'uuid'}, $row->{'characteristics'}, $now);
	my %up;
	$up{'name'} = $game if ($row->{'name'} // '') ne $game;
	$up{'description'} = $game if ($row->{'description'} // '') ne $game;
	$up{'unit'} = 'games' if ($row->{'unit'} // '') ne 'games';
	$up{'def'} = 'off' if ($row->{'def'} // '') ne 'off';
	$up{'save_app'} = 'on' if ($row->{'save_app'} // '') ne 'on';
	$up{'characteristics'} = $want if ($row->{'characteristics'} // '') ne $want;
	if (scalar keys %up) {
		$up{'server_time'} = $now;
		&db_update('option', \%up, { uuid => $row->{'uuid'}, app => 'games' });
		$row->{$_} = $up{$_} foreach keys %up;
	}
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
	# The game is also its own app. source_appt_writer writes the child once,
	# linked by source_uuid, and unformats the option name so `Solitaire`'s
	# child is the existing `solitaire` app; the session's pause, resume and stop
	# then carry it along (game_session_child_close/reopen).
	if (($option->{'save_app'} // '') eq 'on') {
		my $parent = &db_select('appointments', undef, { uuid => $uuid })->hashes->[0];
		if ($parent && ($parent->{'uuid'} // '') ne '') {
			&source_appt_writer($option, {
				app => $parent->{'app'},
				uuid => $parent->{'uuid'},
				type => $parent->{'type'},
				quantity => 1,
				unit => 'games',
				duration => $parent->{'duration'},
				timestamp => $parent->{'timestamp'},
				project => $parent->{'project'},
			}, 'option');
		}
	}
}

# A browser game's window is alive while its tab beats. The beat is a liveness
# mark, not play: writing it to the appointment's server_time would defeat the
# quiet-gap pause (a fresh beat would make an idle gap look like play), so it
# lives in the cache and the play time still ends at the last touch.
sub browser_game_beat_key {
	my ($uuid) = @_;
	return undef unless defined $uuid && length $uuid;
	return {
		app => '__president',
		context => 'game_beat',
		subcontext => substr($uuid, 0, 24),
		warranty => '-1d',
	};
}

sub browser_game_heartbeat {
	my ($opts) = @_;
	$opts ||= {};
	my %allowed = map { $_ => 1 } ('Solitaire', 'Spider Solitaire', 'Mahjong', 'Blackjack', 'Twirl');
	my $game = $opts->{'game'} // '';
	$game =~ s/^\s+//;
	$game =~ s/\s+$//;
	return { ok => 0, error => 'That game does not save play time.' } unless $allowed{$game};
	my $now = &rightNow();
	my $device = $opts->{'device'} // &device_setter();
	my $at = int($opts->{'at'} // 0);
	$at = $now if $at <= 0 || $at > $now;
	# Only an open session is kept alive; a beat never starts one.
	my $open = &db_query(q{
		select uuid from appointments
		 where app = 'games' and lower(source) = 'browser_game' and device = ? and project = ?
		   and (type = 'start' or type = 'record') and stop_seen is null
		 order by cast(timestamp as integer) desc limit 1
	}, $device, $game)->hash;
	return { ok => 1, state => 'none' } unless $open && $open->{'uuid'};
	&subs::cache_set(&browser_game_beat_key($open->{'uuid'}), {
		uuid => $open->{'uuid'},
		at => $at,
		game => $game,
		device => $device,
	});
	return { ok => 1, state => 'beat' };
}

sub browser_game_play {
	my ($opts) = @_;
	$opts ||= {};
	my %allowed = map { $_ => 1 } ('Solitaire', 'Spider Solitaire', 'Mahjong', 'Blackjack', 'Twirl');
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
		# A play that arrives while the row is still open after a quiet spell is
		# a reopened window or a late control, not continuous play: the gap since
		# the last report is a pause and is left out of the session's length.
		my $beat = int($open->{'server_time'} // 0) || int($open->{'timestamp'} // 0);
		if ($at > $beat + $GAME_QUIET_MS) {
			&session_pause_add($open->{'uuid'}, 'games', $at - $beat);
		}
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
					&game_session_child_reopen($row->{'uuid'}, $now);
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
	# The play record carries the app's born warranty like any other appointment
	# (see game_play_appointment_tick): the first run adopts the `me` default,
	# and a spec that does not resolve to a moment ahead of now takes the
	# writer's -10y.
	my $init = &setting_initializer('games', $new_start);
	my $warranty = &ago_calc(($init->{'warranty'} || '-10y'), $now);
	$warranty = &ago_calc('-10y', $now) unless defined $warranty && $warranty =~ /^\d{12,}$/ && $warranty > $now;
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
		warranty => $warranty,
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
	my $play_stale = 2 * 60 * 1000;
	my $rows = eval {
		&db_query(q{
			select app, uuid, timestamp, server_time, source from appointments
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
		# A browser game's tab beats while it is being played; the liveness mark
		# lives in the cache so the play time still ends at the last touch. The
		# Gou's tick refreshes server_time itself. Either way a game whose
		# heartbeat stopped is closed within a couple of minutes, not ten.
		my $source = lc($open->{'source'} // '');
		my $heard = $beat;
		if ($source eq 'browser_game') {
			my $mark = &subs::cache_get(&browser_game_beat_key($uuid));
			my $mark_at = ref $mark eq 'HASH' ? int($mark->{'at'} // 0) : 0;
			$heard = $mark_at if $mark_at > $heard;
		}
		my $limit = ($source eq 'game' || $source eq 'browser_game') ? $play_stale : $stale;
		next if $now - $heard <= $limit;
		my $stop_at = $beat > $started ? $beat : $started;
		$stop_at = $now if $stop_at > $now;
		my $paused = &session_pause_take($uuid);
		my $duration = $started - $stop_at + $paused;
		$duration = 0 if $duration > 0;
		# The Gou's launch-opened session is dropped for being short; a browser play
		# is touch-started, so only one that measured no play at all is dropped.
		my $no_play = ($source eq 'browser_game')
			? ($duration == 0)
			: ($source eq 'game' && abs($duration) < $GAME_MIN_PLAY_MS);
		if ($no_play) {
			&game_session_discard($open, $now);
			$closed++;
			next;
		}
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
	# A sub-minute Gou game the launch tick paused is waiting out its five-minute
	# resume window. Once that window has passed it is not a game the person
	# played: drop it (and its own-app child) with the house's tombstone. A browser
	# play is touch-started and keeps any measured play; only a browser pause that
	# measured none is dropped here. Only recent rows are touched, so a short
	# session from the day's history is left alone.
	my $short = eval {
		&db_query(q{
			select app, uuid, timestamp, stop_timestamp, duration, source from appointments
			 where (lower(source) = 'game'
			    or (lower(source) = 'browser_game' and cast(duration as integer) = 0))
			   and type = 'stop' and stop_seen = 'yes'
			   and stop_timestamp is not null
			   and stop_timestamp <= ? and stop_timestamp > ?
			   and abs(cast(duration as integer)) < ?
		}, $now - 5 * 60 * 1000, $now - 15 * 60 * 1000, $GAME_MIN_PLAY_MS)->hashes;
	} || [];
	foreach my $row ( @{$short} ) {
		&game_session_discard($row, $now);
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
				# the distance the duty is compared in, in kilometres, from the
				# WGS84 ellipsoid a GPS actually reports against. One closure for
				# the fix now and the recorded fixes the stop branch checks.
				my $plate_km = sub {
					return sprintf( '%.3f', &subs::geodesic_offset(
						$plate_lat, $plate_lon, $_[0]->{'latitude'}, $_[0]->{'longitude'}
					)->{'metres'} / 1000 );
				};
				my $distance = $plate_km->($returner);
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
										my $distance = $plate_km->($local);
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
										my $distance = $plate_km->($local);
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
						# The plate fix joins the activity under the same one-device rule
						# as every other door: a machine the appointment is not recording
						# on still runs its plates, it just does not add a row the track will
						# count. The start or stop itself has already been written above.
						if (&subs::movement_records_here({ app => $app, appt => $hpdata->{'uuid'}, signatorial => $signatorial, timestamp => $returner->{'timestamp'}, fix => { latitude => $returner->{'latitude'}, longitude => $returner->{'longitude'}, timestamp => $returner->{'timestamp'} } })) {
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
	}

	&subs::navigation_information();
}

# The hour of the day each app most often happens at, over the recent past, in
# one query for every app. `hour_days` is how many of the days that hour was
# seen on, `days` how many days the app was seen at all, and `due` says whether
# today is one of the days its own cadence keeps it.
#
# The scan also learns the order the day runs in: the sequence of appointments
# the person starts and stops themselves, in the order they are completed.
# `sessions` holds the recent ones, one per stretch without a long pause, and
# the canonical is the most common of them - the day the line anticipates from.
# A row with a source_uuid came from a task, a default option or a default
# model, so it is not the person's own step and never enters a sequence.
#
# The history is the ground the person is on, not the calendar: stay at home and
# the home routine is read from the home days; stay at a friend's or a hotel and
# that place's own visits answer, however far back they are. The scan then runs
# on the house's clock (Configure -> Me, Eastern by default) rather than the
# box's UTC, so a routine begun at eight local reads the same wherever the
# machine sits.
sub clothesline_daily_hours {
	# A caller may ask for another day's routine (the anticipatory settings walk
	# this week); with no moment the present is read, as it always was. It may
	# also hand in the history it already read: the week walk asks for seven
	# days, and reading the near two months seven times was the dialog's whole
	# wait.
	my $now = shift || &rightNow();
	my %opt = @_;
	my ($rows, $window_days, $session_days);
	if (ref $opt{'history'} eq 'ARRAY') {
		($rows, $window_days, $session_days) = @{ $opt{'history'} };
	}
	else {
		($rows, $window_days, $session_days) = &clothesline_place_history($now);
	}
	$window_days ||= 60;
	$session_days ||= 14;
	my $zone = &clock_zone_house();
	my $had = exists $ENV{'TZ'};
	my $old = $ENV{'TZ'};
	$ENV{'TZ'} = $zone;
	POSIX::tzset();
	# The sockets say whether the house was up or out, which is what tells a day
	# whose shape was seen from one that was only inferred. A caller may hand the
	# reading in (the week walk reads it once for its seven days); otherwise it is
	# read here, on the house clock the day model runs in. A house whose sockets
	# were never retained has not been seen at all - liveness answers the whole
	# window as down - and no sighting is no evidence, so the rests decide alone
	# and a fresh house behaves exactly as it did before.
	my $live = $opt{'live'};
	if (!exists $opt{'live'}) {
		$live = &clothesline_device_liveness($now);
		$live = undef unless ref $live eq 'HASH' && ref $live->{'devices'} eq 'HASH' && %{ $live->{'devices'} };
	}
	my $scan = &clothesline_routine_scan($rows, $now,
		window_days => $window_days, session_days => $session_days,
		live => $live,
		(defined $opt{'pause'} ? (pause => $opt{'pause'}) : ()));
	if ($had) { $ENV{'TZ'} = $old } else { delete $ENV{'TZ'} }
	POSIX::tzset();
	# The rail and the settings dialog are drawn on a screen anyone can see: an
	# app the house keeps private, and a caller's number, are not steps here. The
	# check runs on the steps the routine actually offers (the recent sessions),
	# not on every app in two months of history - the week asks for seven days,
	# and a lookup per app per day was the dialog's whole wait.
	my %off;
	foreach my $s ( @{ $scan->{'sessions'} || [] } ) {
		next unless ref $s eq 'HASH' && ref $s->{'seq'} eq 'ARRAY';
		foreach my $app ( @{ $s->{'seq'} } ) {
			next unless defined $app && length $app;
			next if exists $off{$app};
			$off{$app} = &clothesline_app_off_line($app) ? 1 : 0;
		}
	}
	my %skip = map { $_ => 1 } grep { $off{$_} } keys %off;
	if (%skip) {
		foreach my $s ( @{ $scan->{'sessions'} || [] } ) {
			next unless ref $s eq 'HASH' && ref $s->{'seq'} eq 'ARRAY';
			my (@seq, @times);
			for my $i ( 0 .. $#{$s->{'seq'}} ) {
				my $app = $s->{'seq'}[$i];
				next if defined $app && $skip{$app};
				push @seq, $app;
				push @times, $s->{'times'}[$i] if ref $s->{'times'} eq 'ARRAY' && defined $s->{'times'}[$i];
			}
			$s->{'seq'} = \@seq;
			$s->{'times'} = \@times if ref $s->{'times'} eq 'ARRAY';
		}
		$scan->{'sessions'} = [ grep { ref $_ eq 'HASH' && @{ $_->{'seq'} || [] } } @{ $scan->{'sessions'} } ];
		foreach my $app ( keys %skip ) {
			delete $scan->{'apps'}{$app} if ref $scan->{'apps'} eq 'HASH';
			delete $scan->{'done'}{$app} if ref $scan->{'done'} eq 'HASH';
			delete $scan->{'done_ms'}{$app} if ref $scan->{'done_ms'} eq 'HASH';
			delete $scan->{'running'}{$app} if ref $scan->{'running'} eq 'HASH';
		}
		$scan->{'start_app'} = undef if defined $scan->{'start_app'} && $skip{ $scan->{'start_app'} };
	}
	return $scan;
}

# A phone number filed as its own app. The house files every unknown caller that
# way, and a spam caller is not a routine step. The number is the app's own name
# and its own phone row, so a named contact who has a number is never taken for
# one. The list is one query and is cleared after each request.
our %clothesline_number_cache;
sub clothesline_number_app {
	my ($app) = @_;
	return 0 unless defined $app && length $app;
	return 0 unless $app =~ /\A\d+\z/;
	unless (%clothesline_number_cache) {
		my $rows = eval { &db_query(q{select app from settings where setting = 'phone'})->hashes } || [];
		foreach my $r ( @{$rows} ) {
			next unless ref $r eq 'HASH' && defined $r->{'app'} && length $r->{'app'};
			$clothesline_number_cache{$r->{'app'}} = 1;
		}
	}
	return $clothesline_number_cache{$app} ? 1 : 0;
}

# Whether an app belongs on the clothesline at all. The rail is drawn on a screen
# anyone can see, and the settings dialog is part of it, so an app the house
# keeps private never appears; nor does a caller's number.
sub clothesline_app_off_line {
	my ($app) = @_;
	return 1 unless defined $app && length $app;
	return 1 if &app_hidden_now($app);
	return &clothesline_number_app($app);
}

# The ground the person is on. The last two days' fixes vote: the cell most of
# them share is the base (home, a friend's house, a hotel), so one afternoon out
# does not move the routine. Home is the house plate; anything else is a place
# with its own history. With no fix new enough, the latest fix answers, then the
# house plate.
sub clothesline_current_place($now) {
	$now ||= &rightNow();
	my $since = $now - (48 * 3600 * 1000);
	my $rows = eval {
		&db_query(q{select latitude, longitude, timestamp from continent where latitude is not null and latitude != ? and longitude is not null and longitude != ? and cast(timestamp as integer) >= ? and cast(timestamp as integer) <= ? and not (cast(latitude as real) = 0 and cast(longitude as real) = 0) order by cast(timestamp as integer) asc}, '', '', $since, $now + (3600 * 1000))->hashes;
	} || [];
	my (%cell, %last, @valid);
	foreach my $r ( @{$rows} ) {
		my $lat = $r->{'latitude'};
		my $lon = $r->{'longitude'};
		next unless defined $lat && defined $lon && $lat =~ /^-?\d/ && $lon =~ /^-?\d/;
		my $key = sprintf('%.2f,%.2f', $lat, $lon);
		my $ts = 0 + $r->{'timestamp'};
		$cell{$key}++;
		$last{$key} = $ts if !defined $last{$key} || $ts > $last{$key};
		push @valid, { lat => 0 + $lat, lon => 0 + $lon, key => $key };
	}
	my $place;
	if (%cell) {
		my ($key) = sort { $cell{$b} <=> $cell{$a} || ($last{$b} || 0) <=> ($last{$a} || 0) } keys %cell;
		my @in = grep { $_->{'key'} eq $key } @valid;
		my ($slat, $slon) = (0, 0);
		foreach my $in ( @in ) { $slat += $in->{'lat'}; $slon += $in->{'lon'}; }
		$place = { lat => $slat / scalar(@in), lon => $slon / scalar(@in) };
	}
	unless ($place) {
		my $fix = eval {
			&db_query(q{select latitude, longitude from continent where latitude is not null and latitude != ? and longitude is not null and longitude != ? order by cast(server_time as integer) desc limit 1}, '', '')->hashes->[0];
		};
		$place = { lat => 0 + $fix->{'latitude'}, lon => 0 + $fix->{'longitude'} } if $fix;
	}
	my $home = &weather_home_plate();
	unless ($place) {
		return { lat => $home->{'lat'}, lon => $home->{'lon'}, home => 1 } if $home && defined $home->{'lat'} && defined $home->{'lon'};
		return undef;
	}
	if ($home && defined $home->{'lat'} && defined $home->{'lon'}) {
		my $km = &weather_distance_km($place->{'lat'}, $place->{'lon'}, $home->{'lat'}, $home->{'lon'});
		if (defined $km && $km <= 1) {
			$place = { lat => 0 + $home->{'lat'}, lon => 0 + $home->{'lon'}, home => 1 };
		}
	}
	$place->{'home'} ||= 0;
	return $place;
}

# The appointments of the stays at the current ground. Home reads its last two
# months; a place away reads every visit it has, so a return to the same friend
# or hotel resumes what the line learned there, and a first visit learns from
# the days as they happen. The stays come from the fixes near the place: a day
# without one ends the stay. The appointments inside those stays are the whole
# routine, outings included.
sub clothesline_place_history($now) {
	$now ||= &rightNow();
	my $fallback = sub {
		my $since = $now - (60 * 86400 * 1000);
		return (&db_query(q{select app, timestamp, stop_timestamp, type, source, source_uuid from appointments where timestamp >= ? and timestamp <= ? and type in (?, ?, ?) and (coalesce(source,'') in ('press','nfc') or (coalesce(source,'') = '' and coalesce(source_uuid,'') = ''))}, $since, $now, 'usual', 'stop', 'start')->hashes->to_array, 60, 14);
	};
	my $place = &clothesline_current_place($now);
	return $fallback->() unless $place;
	# the near-place box: a kilometre each way - the same place the person is
	# standing on, to within a corner. Exact distance is for naming the place;
	# a stay only needs to know a fix landed here, so the box serves and saves a
	# haversine per fix (twenty thousand of them at home).
	my $km = 1;
	my $dlat = $km / 111;
	my $dlon = $km / (111 * cos(deg2rad($place->{'lat'})) || 1);
	my $since = $place->{'home'} ? $now - (60 * 86400 * 1000) : 0;
	# The stays are read a day at a time: one row a day that has a fix near the
	# place, so two months at home is sixty rows rather than twenty thousand. A
	# day without one ends the visit, which is the same rule the fixes gave.
	my $days = eval {
		&db_query(q{select cast(cast(timestamp as integer) / 86400000 as integer) d, min(cast(timestamp as integer)) mn, max(cast(timestamp as integer)) mx from continent where cast(latitude as real) between ? and ? and cast(longitude as real) between ? and ? and cast(timestamp as integer) >= ? and cast(timestamp as integer) <= ? and cast(timestamp as integer) > 0 group by d order by d asc}, $place->{'lat'} - $dlat, $place->{'lat'} + $dlat, $place->{'lon'} - $dlon, $place->{'lon'} + $dlon, $since, $now + (3600 * 1000))->hashes->to_array;
	} || [];
	my @visits;
	my ($start, $end, $prev_day);
	foreach my $d ( @{$days} ) {
		my $day = 0 + $d->{'d'};
		my ($mn, $mx) = (0 + $d->{'mn'}, 0 + $d->{'mx'});
		if (!defined $start || $day > $prev_day + 1) {
			push @visits, [$start, $end] if defined $start;
			($start, $end) = ($mn, $mx);
		}
		else {
			$start = $mn if $mn < $start;
			$end = $mx if $mx > $end;
		}
		$prev_day = $day;
	}
	push @visits, [$start, $end] if defined $start;
	return $place->{'home'} ? $fallback->() : ([], 14, 14) unless @visits;
	# the last fifty stays are plenty: an older visit teaches a routine the
	# canonical day already keeps, and each adds a clause to the query below
	@visits = @visits[-50 .. -1] if @visits > 50;
	for my $i ( 0 .. $#visits ) {
		$visits[$i][1] += 2 * 3600 * 1000;
		$visits[$i][1] = $now if $i == $#visits && $visits[$i][1] < $now
			&& ($now - $visits[$i][1]) < 24 * 3600 * 1000;
	}
	my $earliest = $visits[0][0];
	my $window_days = $place->{'home'} ? 60 : int((($now - $earliest) / (86400 * 1000))) + 1;
	my $session_days = $place->{'home'} ? 14 : $window_days;
	my @where;
	my @args = ('usual', 'stop', 'start');
	foreach my $v ( @visits ) {
		push @where, '(cast(timestamp as integer) between ? and ?)';
		push @args, $v->[0], $v->[1];
	}
	my $rows = eval {
		&db_query(q{select app, timestamp, stop_timestamp, type, source, source_uuid from appointments where type in (?, ?, ?) and (coalesce(source,'') in ('press','nfc') or (coalesce(source,'') = '' and coalesce(source_uuid,'') = '')) and (} . join(' or ', @where) . ')', @args)->hashes->to_array;
	} || [];
	return $place->{'home'} ? $fallback->() : ([], 14, 14) unless @{$rows};
	return ($rows, $window_days, $session_days);
}

# The local day a moment belongs to, as an integer that steps by one each
# midnight. Local noon keeps the difference between two days exact through a
# daylight-saving change, which a plain epoch/86400 would not.
sub clothesline_day_index {
	my $ms = shift;
	my @t = localtime(int($ms / 1000));
	my $noon = timelocal(12, 0, 0, $t[3], $t[4], $t[5]);
	return int($noon / 86400);
}

# The day's rests, learned from activity alone. A rest is the quiet interval a
# day keeps: the person stops, and starts again. Nothing here knows what the
# person calls it - the shape is the lesson. The night window and the profiles
# (a day shift and a night shift are two shapes) are learned from where those
# intervals fall on the clock, always relative to the person's own day.
#
# A brief waking inside a rest (a phone check, a trip in the night) is absorbed:
# a short run between two quiets is recorded as a blip and the night stays one
# rest. A day's main rest is its longest quiet interval; the shorter ones are
# naps or the pauses between the day's waves, and stay out of the rest set.
#
# The caller's clock is the house clock (clothesline_daily_hours adopts it); the
# hours are only ever used to place a rest on the person's own day, never as a
# gate on whether a rest happened.
sub clothesline_rest_episodes {
	my ($rows, $now, %opt) = @_;
	$rows = eval { [ $rows->each ] } if ref $rows && ref $rows ne 'ARRAY';
	$rows = [] unless ref $rows eq 'ARRAY';
	$now = &rightNow() unless defined $now;
	my $window_days = $opt{'window_days'} || 60;
	my $brief = $opt{'brief'} || (30 * 60 * 1000);
	my $rest_min = $opt{'rest_min'} || (90 * 60 * 1000);
	my $radius = $opt{'radius'} || 3;
	my $since = $now - ($window_days * 86400 * 1000);

	my @act;
	foreach my $r ( @{$rows} ) {
		next unless ref $r eq 'HASH';
		my $app = $r->{'app'};
		my $ms = $r->{'timestamp'};
		next unless defined $app && length $app && defined $ms && $ms =~ /^\d+(?:\.\d+)?$/ && $ms > 0;
		my $origin = lc($r->{'source'} // '');
		if ($origin ne 'press' && $origin ne 'nfc') { next if defined $r->{'source_uuid'} && length $r->{'source_uuid'}; }
		my $type = lc($r->{'type'} || '');
		next unless $type eq 'usual' || $type eq 'stop';
		next if $ms < $since || $ms > $now;
		push @act, 0 + $ms;
	}
	my $empty = { rests => [], profiles => [], profile => undef, window => undef, rest_min => $rest_min, brief => $brief };
	return $empty unless @act;
	@act = sort { $a <=> $b } @act;

	# Runs: activity closer than a brief waking is one run. A short run between
	# two quiets is a waking, not a run: it is kept as a blip on the rest.
	my @runs;
	foreach my $ms ( @act ) {
		if (@runs && $ms - $runs[-1]{'to'} <= $brief) { $runs[-1]{'to'} = $ms; }
		else { push @runs, { from => $ms, to => $ms, blips => [] }; }
	}
	my @kept;
	foreach my $i ( 0 .. $#runs ) {
		my $run = $runs[$i];
		if ($i > 0 && $i < $#runs && ($run->{'to'} - $run->{'from'}) <= $brief
			&& ($run->{'from'} - $runs[$i-1]{'to'}) >= $rest_min
			&& ($runs[$i+1]{'from'} - $run->{'to'}) >= $rest_min) {
			push @{ $kept[-1]{'blips'} }, [ $run->{'from'}, $run->{'to'} ];
			next;
		}
		push @kept, { %{$run}, blips => [ @{$run->{'blips'}} ] };
	}
	@runs = @kept;
	return $empty if @runs < 2;

	# Quiet intervals between runs. A day's main rest is the longest one whose
	# wake (the next run's first step) falls on that local day; the day it ends
	# is the day it starts, so a night that crosses midnight still belongs to the
	# morning it opens.
	my %day_rest;
	foreach my $i ( 1 .. $#runs ) {
		my $start = $runs[$i-1]{'to'};
		my $stop = $runs[$i]{'from'};
		my $len = $stop - $start;
		next if $len < $rest_min;
		my $day = &clothesline_day_index($stop);
		my $rest = { start => $start, stop => $stop, length => $len,
			blips => [ @{ $runs[$i-1]{'blips'} } ] };
		$day_rest{$day} = $rest if !defined $day_rest{$day} || $len > $day_rest{$day}{'length'};
	}
	my @rests = map { $day_rest{$_} } sort { $a <=> $b } keys %day_rest;
	return $empty unless @rests;

	my $pi = 4 * atan2(1, 1);
	my $hour_of = sub { my $ms = shift; my @t = localtime(int($ms / 1000)); return $t[2] + $t[3] / 60; };
	my $circ_mean = sub {
		my @h = @_;
		my ($s, $c) = (0, 0);
		foreach my $h ( @h ) { my $a = $h / 24 * 2 * $pi; $s += sin($a); $c += cos($a); }
		my $a = atan2($s / scalar(@h), $c / scalar(@h));
		$a += 2 * $pi while $a < 0;
		return ($a / (2 * $pi)) * 24;
	};
	foreach my $rest ( @rests ) {
		$rest->{'start_hour'} = $hour_of->($rest->{'start'});
		$rest->{'stop_hour'} = $hour_of->($rest->{'stop'});
	}
	my $window = {
		start_hour => $circ_mean->(map { $_->{'start_hour'} } @rests),
		stop_hour  => $circ_mean->(map { $_->{'stop_hour'} } @rests),
		days       => scalar @rests,
	};

	# Profiles: a day shift and a night shift are two places on the clock. A rest
	# joins the first profile whose means are within the radius; otherwise it
	# starts one. The selected profile is the one of the most recent rest - the
	# last day the person actually lived, not the calendar.
	my @profiles;
	my $circ_gap = sub {
		my ($a, $b) = @_;
		my $d = abs($a - $b); $d = 24 - $d if $d > 12; return $d;
	};
	foreach my $rest ( sort { $a->{'stop'} <=> $b->{'stop'} } @rests ) {
		my $found;
		foreach my $p ( @profiles ) {
			next unless $circ_gap->($p->{'start_hour'}, $rest->{'start_hour'}) <= $radius;
			next unless $circ_gap->($p->{'stop_hour'}, $rest->{'stop_hour'}) <= $radius;
			$found = $p; last;
		}
		unless ($found) {
			$found = { count => 0, starts => [], stops => [] };
			push @profiles, $found;
		}
		$found->{'count'}++;
		push @{$found->{'starts'}}, $rest->{'start_hour'};
		push @{$found->{'stops'}}, $rest->{'stop_hour'};
		$found->{'start_hour'} = $circ_mean->(@{$found->{'starts'}});
		$found->{'stop_hour'} = $circ_mean->(@{$found->{'stops'}});
		$found->{'last_stop'} = $rest->{'stop'};
		$rest->{'profile'} = $found;
	}
	my $selected = $rests[-1]{'profile'};
	return {
		rests => \@rests,
		profiles => \@profiles,
		profile => $selected,
		window => $window,
		rest_min => $rest_min,
		brief => $brief,
	};
}

# The day's segments: a day begins at the end of a rest. The rests are learned
# (clothesline_rest_episodes) and placed on the clock; the liveness says whether
# the house was up or out. A quiet the person comes back to night after night is
# their night, however short, and its wake opens a day; a quiet alone at its hour
# is a nap, an idle afternoon or a data gap and opens nothing, so a seven-hour
# afternoon with the house up never cuts a day in two. A night the house was out
# for is still one day - the person was gone or the power was - and it is marked
# inferred, because the shape of it was not seen.
#
# Each segment carries the steps that ran in it, the waves they fell into and
# where those waves paused, and the profile (the shape of the day) of the rest
# that opened it. A profile keeps its own day: a day shift and a night shift are
# two shapes, and each keeps the canonical day, the head and the pause it runs
# in. The last segment is open - it ends when the next night does.
#
# The caller's clock is the house clock, as for clothesline_rest_episodes: the
# hour only places a rest on the person's own day, it never decides that a day
# happened. No app's name is read here.
sub clothesline_day_segments {
	my ($rows, $live, $now, %opt) = @_;
	$rows = eval { [ $rows->each ] } if ref $rows && ref $rows ne 'ARRAY';
	$rows = [] unless ref $rows eq 'ARRAY';
	$now = &rightNow() unless defined $now;
	my $radius = defined $opt{'radius'} ? $opt{'radius'} : 3;
	my $model = &clothesline_rest_episodes($rows, $now, %opt);
	my $rest_min = $model->{'rest_min'};
	my $brief = $model->{'brief'};
	my @rests = @{ $model->{'rests'} || [] };
	my @profiles = @{ $model->{'profiles'} || [] };
	$profiles[$_]{'id'} = $_ for 0 .. $#profiles;

	# The steps the person took themselves, in order - the same rule the rest
	# learning applies: a press or a tag, or a row from before the source was
	# kept. A task's checkbox or a default option is not the person's day.
	my @steps;
	foreach my $r ( @{$rows} ) {
		next unless ref $r eq 'HASH';
		my $app = $r->{'app'};
		my $ms = $r->{'timestamp'};
		next unless defined $app && length $app && defined $ms && $ms =~ /^\d+(?:\.\d+)?$/ && $ms > 0;
		my $origin = lc($r->{'source'} // '');
		if ($origin ne 'press' && $origin ne 'nfc') { next if defined $r->{'source_uuid'} && length $r->{'source_uuid'}; }
		my $type = lc($r->{'type'} || '');
		next unless $type eq 'usual' || $type eq 'stop';
		next if $ms > $now;   # the day model describes the past, as the rests do
		push @steps, { app => $app, ms => 0 + $ms };
	}
	@steps = sort { $a->{'ms'} <=> $b->{'ms'} } @steps;

	my $empty = {
		rests => \@rests,
		profiles => \@profiles,
		profile => $model->{'profile'},
		window => $model->{'window'},
		segments => [],
		source => 'none',
		rest_min => $rest_min,
		brief => $brief,
		pause => undef,
	};

	my $circ_gap = sub {
		my $d = abs($_[0] - $_[1]);
		$d = 24 - $d if $d > 12;
		return $d;
	};

	# The clock the middle of a rest sits at: a night's start slides with the
	# person's own bedtime (eleven one night, one the next), but the middle of a
	# sleep stays put, so that is what tells a night from a long evening gap. The
	# hours are the house's, used to place a rest - never to decide one happened.
	foreach my $rest ( @rests ) {
		my $mid = $rest->{'start_hour'} + ($rest->{'length'} / 3600000) / 2;
		$mid -= 24 * int($mid / 24);
		$rest->{'mid_hour'} = $mid;
	}

	# A night is a rest the person keeps returning to: another rest sits at the
	# same middle of the clock within the radius. A quiet alone at its hour is a
	# nap, an idle afternoon or a data gap, and its end opens no day - including
	# the first day of the window, whose real night belongs to the day after it.
	my @wake;
	for my $i ( 0 .. $#rests ) {
		my $night = 0;
		for my $j ( 0 .. $#rests ) {
			next if $i == $j;
			if ($circ_gap->($rests[$i]{'mid_hour'}, $rests[$j]{'mid_hour'}) <= $radius) { $night = 1; last; }
		}
		next unless $night;
		push @wake, { ms => $rests[$i]{'stop'}, inferred => 0, rest => $rests[$i] };
	}

	# The liveness is optional: with none the rests alone say where the days are -
	# and none includes a house that has not been seen at all, whose empty
	# `devices` means every span is missing rather than the house being out. With
	# a sighting, a night the house was out for is still a day - the person was
	# gone or the power was - but the shape of it was not seen, so the day is
	# marked inferred rather than learned. A quiet the house was up for is idle
	# time and never a boundary unless it is a night on the clock, which is what
	# keeps a seven-hour afternoon from cutting the day in two.
	my $known = (ref $live eq 'HASH' && ref $live->{'down'} eq 'ARRAY'
		&& ref $live->{'devices'} eq 'HASH' && %{ $live->{'devices'} }) ? 1 : 0;
	my @down = $known ? @{ $live->{'down'} } : ();
	my $down_in = sub {
		my ($a, $b) = @_;
		my $sum = 0;
		foreach my $d ( @down ) {
			next unless ref $d eq 'ARRAY' && @{$d} >= 2;
			my $lo = $a > $d->[0] ? $a : $d->[0];
			my $hi = $b < $d->[1] ? $b : $d->[1];
			$sum += $hi - $lo if $hi > $lo;
		}
		return $sum;
	};
	foreach my $w ( @wake ) {
		next unless $known;
		my $rest = $w->{'rest'};
		$w->{'inferred'} = 1 if $rest->{'length'} > 0 && $down_in->($rest->{'start'}, $rest->{'stop'}) >= 0.5 * $rest->{'length'};
	}

	@wake = sort { $a->{'ms'} <=> $b->{'ms'} } @wake;
	return $empty unless @wake && @steps;

	my @segments;
	# The day the first learned night closes is a day too: it runs from the first
	# step the window kept to the wake that ends it, in the shape of that night.
	if ($steps[0]{'ms'} < $wake[0]{'ms'}) {
		push @segments, {
			start => $steps[0]{'ms'},
			stop => $wake[0]{'ms'},
			opened_by => undef,
			night => $wake[0]{'rest'},
			profile => $wake[0]{'rest'}{'profile'},
			inferred => 0,
		};
	}
	for my $i ( 0 .. $#wake ) {
		push @segments, {
			start => $wake[$i]{'ms'},
			stop => ($i < $#wake) ? $wake[$i+1]{'ms'} : undef,
			opened_by => $wake[$i]{'rest'},
			night => ($i < $#wake) ? $wake[$i+1]{'rest'} : undef,
			profile => $wake[$i]{'rest'}{'profile'},
			inferred => $wake[$i]{'inferred'},
		};
	}

	# Each segment's own day: its steps in order, the waves they fall into, and
	# the pauses where one wave gives way to the next. The steps are sorted and
	# the segments are contiguous, so one walk fills every day.
	my $pinned_gap = $opt{'gap'};
	my @bucket;
	my $at = 0;
	foreach my $step ( @steps ) {
		$at++ while $at < $#segments && defined $segments[$at]{'stop'} && $step->{'ms'} >= $segments[$at]{'stop'};
		push @{ $bucket[$at] }, $step;
	}
	for my $i ( 0 .. $#segments ) {
		my $seg = $segments[$i];
		my @mine = @{ $bucket[$i] || [] };
		$seg->{'day'} = &clothesline_day_index($seg->{'start'});
		$seg->{'seq'} = [ map { $_->{'app'} } @mine ];
		$seg->{'times'} = [ map { $_->{'ms'} } @mine ];
		my $gap = &clothesline_sequence_pause($seg->{'times'}, $pinned_gap);
		my $waves = &clothesline_sequence_waves($seg->{'times'}, $gap);
		$seg->{'gap'} = $gap;
		$seg->{'waves'} = $waves;
		my @pauses;
		for my $i ( 1 .. $#{$waves} ) {
			next unless $waves->[$i] > $waves->[$i-1];
			push @pauses, {
				index => $i,
				gap => $seg->{'times'}[$i] - $seg->{'times'}[$i-1],
				after => $seg->{'seq'}[$i-1],
				before => $seg->{'seq'}[$i],
			};
		}
		$seg->{'pauses'} = \@pauses;
	}

	# A profile keeps its own day: the canonical sequence, the app that opens it,
	# and the pause it runs in. The pause is where the day's own waves give way -
	# its longest repeated gap, floored at a coffee and capped at a workday - so a
	# dense morning and a sparse one each keep their own.
	foreach my $p ( @profiles ) {
		my @mine = grep { ref $_->{'profile'} eq 'HASH' && $_->{'profile'}{'id'} == $p->{'id'} } @segments;
		my @sessions;
		my @gaps;
		foreach my $seg ( @mine ) {
			my $t = $seg->{'times'};
			push @gaps, $t->[$_] - $t->[$_-1] for 1 .. $#$t;
			next unless @{ $seg->{'seq'} };
			push @sessions, {
				seq => [ @{ $seg->{'seq'} } ],
				times => [ @{ $seg->{'times'} } ],
				start => $seg->{'start'},
				profile => $p->{'id'},
			};
		}
		# the canonical day is the most common *recent* one: two months of a
		# shape is a comparison per pair per day, and yesterday says it better
		my $keep = $opt{'session_days'} || 14;
		@sessions = @sessions[-$keep .. -1] if @sessions > $keep;
		$p->{'sessions'} = \@sessions;
		$p->{'start_app'} = &clothesline_sequence_start_app(\@sessions);
		$p->{'canonical'} = &clothesline_sequence_canonical(\@sessions, $p->{'start_app'});
		my $pause = 6 * 3600 * 1000;
		if (@gaps) {
			my @sorted = sort { $a <=> $b } @gaps;
			$pause = $sorted[ int($#sorted * 0.8) ];
			$pause = 90 * 60 * 1000 if $pause < 90 * 60 * 1000;
			$pause = 6 * 3600 * 1000 if $pause > 6 * 3600 * 1000;
		}
		$p->{'pause'} = $pause;
	}

	my $profile = $model->{'profile'};
	my $pause = ($profile && defined $profile->{'pause'}) ? $profile->{'pause'} : (6 * 3600 * 1000);
	return {
		rests => \@rests,
		profiles => \@profiles,
		profile => $profile,
		window => $model->{'window'},
		segments => \@segments,
		source => 'model',
		rest_min => $rest_min,
		brief => $brief,
		pause => $pause,
	};
}

# Read the window's appointments into the routine the clothesline paints. Pure
# but for the clock: the query is clothesline_daily_hours' job, so a test can
# hand it rows and a moment and see the sequence, the days and the due flags.
sub clothesline_routine_scan {
	my ($rows, $now, %opt) = @_;
	# A plain arrayref is what this reads; `->hashes` hands back a
	# Mojo::Collection, which is also array-like but is not an ARRAY, so without
	# this the line would lead with nothing and say nothing about it.
	$rows = eval { [ $rows->each ] } if ref $rows && ref $rows ne 'ARRAY';
	$rows = [] unless ref $rows eq 'ARRAY';
	$now = &rightNow() unless defined $now;
	my $window = $opt{'window_days'} || 60;
	my $session_days = $opt{'session_days'} || 14;
	my $recent_since = $now - ($session_days * 86400 * 1000);

	# The day is learned now, not counted from six hours of quiet: a night's wake
	# opens a day and the day it opens carries its own shape, so a three-hour
	# night ends yesterday as surely as a nine-hour one, and a long daytime gap
	# with the house up does not. A caller may pin the pause (the session tests
	# do): then the old split is kept exactly, so a pinned pause still answers
	# what it always did. With no learned night - one rest is not a shape - the
	# old six-hour quiet stands as the fallback.
	my $pinned = (defined $opt{'pause'} && $opt{'pause'} > 0) ? $opt{'pause'} : undef;
	my $days = $pinned ? undef : &clothesline_day_segments($rows, $opt{'live'}, $now,
		window_days => $window, session_days => $session_days, %opt);
	my $model = ($days && $days->{'source'} eq 'model') ? $days : undef;
	my $segments = $model ? $model->{'segments'} : [];
	my $pause = defined $pinned ? $pinned
		: ($model && $model->{'pause'}) ? $model->{'pause'}
		: (6 * 3600 * 1000); # a gap that ends a routine when no day was learned

	# Where a moment sits in the learned days, and whether it belongs to the day
	# under way at all. A step from before this day's wake is yesterday's, however
	# recently it was pressed: the night was a boundary, not a long pause.
	my $segment_of = sub {
		my ($ms) = @_;
		return undef unless $model;
		for my $i ( 0 .. $#{$segments} ) {
			my $seg = $segments->[$i];
			return $i if $ms >= $seg->{'start'} && (!defined $seg->{'stop'} || $ms < $seg->{'stop'});
		}
		return undef;
	};
	my $current_seg = &$segment_of($now);
	my $day_start = defined $current_seg ? $segments->[$current_seg]{'start'} : undef;
	my $day_stop = (defined $current_seg && defined $segments->[$current_seg]{'stop'}) ? $segments->[$current_seg]{'stop'} : undef;
	my $in_day = sub {
		return 1 unless defined $day_start;
		return 0 if $_[0] < $day_start || $_[0] > $now;
		return 0 if defined $day_stop && $_[0] >= $day_stop;
		return 1;
	};

	my (@completed, @recent_completed, @started);
	my (%lengths, %open);
	foreach my $r ( @{$rows} ) {
		next unless ref $r eq 'HASH';
		my $app = $r->{'app'};
		my $ms = $r->{'timestamp'};
		next unless defined $app && length $app && defined $ms && $ms =~ /^\d+(?:\.\d+)?$/ && $ms > 0;
		# A step the person started or stopped themselves is the routine's own: a
		# press on the rail or a tag, even when it is a child of a session they
		# pressed (the banana taken with lunch). A default option, a task's
		# checkbox or a schedule's repeat belongs to whatever started it. A row
		# written before the source was kept answers by whether it has a parent.
		my $origin = lc($r->{'source'} // '');
		if ($origin ne 'press' && $origin ne 'nfc') {
			next if defined $r->{'source_uuid'} && length $r->{'source_uuid'};
		}
		my $type = lc($r->{'type'} || '');
		if ($type eq 'start') {
			if ($ms >= $recent_since) {
				push @started, { app => $app, ms => $ms + 0 };
				# the session is still open, and still this run of the routine: the
				# line reads where it is running. One left open past the routine's
				# pause - or from before this day's wake - is a forgotten session,
				# not a step in hand.
				if ($ms <= $now && ($now - $ms) <= $pause && $in_day->($ms)
					&& (!defined $open{$app} || $ms > $open{$app})) {
					$open{$app} = 0 + $ms;
				}
			}
			next;
		}
		next unless $type eq 'usual' || $type eq 'stop';
		my $row = { app => $app, ms => $ms + 0 };
		push @completed, $row;
		push @recent_completed, $row if $ms >= $recent_since;
		# how long the step usually runs: a closed row runs from its timestamp
		# to its stop_timestamp, and that length is what puts a long step (a
		# wake-up) where the day usually stops it
		my $stop = $r->{'stop_timestamp'};
		if (defined $stop && $stop =~ /^\d/ && (0 + $stop) > (0 + $ms)) {
			push @{$lengths{$app}}, (0 + $stop) - (0 + $ms);
		}
	}
	@completed = sort { $a->{'ms'} <=> $b->{'ms'} } @completed;
	@recent_completed = sort { $a->{'ms'} <=> $b->{'ms'} } @recent_completed;
	@started = sort { $a->{'ms'} <=> $b->{'ms'} } @started;

	# The step at hand, and the run of the routine it belongs to. The routine
	# keeps the day it began, so one that runs past midnight is still that day's
	# routine - the steps already taken do not come round again when the clock
	# turns. With a learned day the run is the day's own: a step from before this
	# day's wake is yesterday's, however short the night that separated them.
	my $last_any;
	if (@recent_completed) {
		$last_any = { app => $recent_completed[-1]{'app'}, ms => $recent_completed[-1]{'ms'}, type => 'done' };
	}
	if (@started && (!$last_any || $started[-1]{'ms'} >= $last_any->{'ms'})) {
		$last_any = { app => $started[-1]{'app'}, ms => $started[-1]{'ms'}, type => 'start' };
	}
	my $active = ($last_any && ($now - $last_any->{'ms'}) <= $pause && $in_day->($last_any->{'ms'})) ? 1 : 0;
	my $last_start = @recent_completed ? $recent_completed[-1]{'ms'} : undef;
	for (my $i = $#recent_completed; $i > 0; $i--) {
		# The learned day is the unit, so its own steps are one run however long
		# the gaps inside it (a workday is not a new day). Without a learned day
		# the old pause still splits the run.
		last unless $in_day->($recent_completed[$i-1]{'ms'});
		last if !$model && $recent_completed[$i]{'ms'} - $recent_completed[$i-1]{'ms'} > $pause;
		$last_start = $recent_completed[$i-1]{'ms'};
	}
	$last_start = undef if defined $last_start && !$in_day->($last_start);
	# With a day learned the routine is under way for the whole of it: what was
	# finished this morning is finished now, and the line does not offer it again
	# after a quiet afternoon. Without one, a long pause still ends the run.
	$active = 1 if $model && $last_any && $in_day->($last_any->{'ms'});
	my $belongs = 0;
	if ($active && defined $last_start) {
		if ($model) { $belongs = 1; }
		elsif ($last_any->{'type'} ne 'start') { $belongs = 1; }
		elsif (@recent_completed && ($last_any->{'ms'} - $recent_completed[-1]{'ms'}) <= $pause) { $belongs = 1; }
	}
	my $anchor_ms = $belongs ? $last_start : $now;
	my $today = &clothesline_day_index($anchor_ms);
	my @day_t = localtime(int($anchor_ms / 1000));
	my $today_wday = $day_t[6];
	# The weekdays the window actually offered, up to the routine's own day: a
	# Monday habit is not weakened by the Monday not having happened yet.
	my %offered;
	for my $d ( ($today - $window) .. ($today - 1) ) {
		my $wd = (($d - $today + $today_wday) % 7 + 7) % 7;
		$offered{$wd}++;
	}

	my (%app_days, %hour_days, %recent_days);
	foreach my $r ( @completed ) {
		$app_days{$r->{'app'}}->{&clothesline_day_index($r->{'ms'})} = 1;
	}
	foreach my $r ( @recent_completed ) {
		my @t = localtime(int($r->{'ms'} / 1000));
		$hour_days{$r->{'app'}}->{$t[2]}->{&clothesline_day_index($r->{'ms'})} = 1;
		$recent_days{$r->{'app'}}->{&clothesline_day_index($r->{'ms'})} = 1;
	}
	my $apps = {};
	foreach my $app ( keys %app_days ) {
		my ($best_hour, $best_days) = (undef, -1);
		foreach my $h ( keys %{$hour_days{$app} || {}} ) {
			my $c = scalar keys %{$hour_days{$app}->{$h}};
			if ($c > $best_days) { ($best_hour, $best_days) = ($h, $c); }
		}
		my $days = scalar keys %{$app_days{$app}};
		# A weekday habit is read from how often each weekday was offered: a
		# clear split (a weekday that holds on most of its chances and one that
		# never does) names the days it keeps. With no clear split, the gaps
		# between its days give the cadence - every other day, every third, up
		# to a month - and today is due on the phase its days share.
		my $due = 1;
		my $cadence = 1;
		if ($days >= 2) {
			my %weekdays;
			foreach my $d ( keys %{$app_days{$app}} ) {
				my $wd = (($d - $today + $today_wday) % 7 + 7) % 7;
				$weekdays{$wd}++;
			}
			my (%ratio, $on_wd, $off_wd);
			foreach my $wd ( keys %offered ) {
				$ratio{$wd} = $offered{$wd} ? (($weekdays{$wd} || 0) / $offered{$wd}) : 0;
				$on_wd = 1 if $ratio{$wd} >= 0.6;
				$off_wd = 1 if $ratio{$wd} <= 0.2;
			}
			if ($on_wd && $off_wd) {
				$cadence = 7;
				my $on_today = $weekdays{$today_wday} || 0;
				$due = ($on_today >= 2 && ($ratio{$today_wday} || 0) >= 0.6) ? 1 : 0;
			}
			else {
				my @days = sort { $a <=> $b } keys %{$app_days{$app}};
				my @gaps = map { $days[$_] - $days[$_ - 1] } (1 .. $#days);
				my %gap_count;
				$gap_count{$_}++ for @gaps;
				my $best_gap = -1;
				$cadence = 0;
				foreach my $g ( sort { $a <=> $b } keys %gap_count ) {
					if ($gap_count{$g} > $best_gap) { ($cadence, $best_gap) = ($g, $gap_count{$g}); }
				}
				$cadence = 1 if $cadence < 1;
				$cadence = 30 if $cadence > 30;
				if ($cadence >= 2) {
					my %residue;
					$residue{$_ % $cadence}++ for @days;
					my ($keep, $best_residue) = (0, -1);
					foreach my $res ( sort { $a <=> $b } keys %residue ) {
						if ($residue{$res} > $best_residue) { ($keep, $best_residue) = ($res, $residue{$res}); }
					}
					$due = (($today % $cadence) == $keep) ? 1 : 0;
				}
			}
		}
		# how many of the last two weeks the step happened on, which is what tells
		# a habit apart from a thing done once in a while
		$apps->{$app} = { hour => $best_hour, hour_days => $best_days, days => $days,
			recent_days => scalar keys %{ $recent_days{$app} || {} },
			due => $due, cadence => $cadence };
		# the middle length, so one runaway session does not stretch the step
		if (ref $lengths{$app} eq 'ARRAY' && @{$lengths{$app}}) {
			my @sorted = sort { $a <=> $b } @{$lengths{$app}};
			$apps->{$app}{'length'} = $sorted[int($#sorted / 2)];
		}
	}

	# sessions: the recent completed steps in order, split where one day ends and
	# the next begins. With a learned day the day is the session - a whole day's
	# steps are one shape, and the waves inside it are the pauses between its own
	# stretches - so a morning and its evening are not two days. Without one, a
	# long pause splits as it always did.
	my (@sessions, @names, @times, $start, $prev, $prev_seg, $sess_profile);
	my $profile_of = sub {
		my ($seg) = @_;
		return undef unless $model && defined $seg;
		my $p = $segments->[$seg]{'profile'};
		return ref $p eq 'HASH' ? $p->{'id'} : undef;
	};
	foreach my $r ( @recent_completed ) {
		my $seg = $model ? &$segment_of($r->{'ms'}) : undef;
		if (@names) {
			my $split = $model
				? ((defined $seg ? $seg : -1) != (defined $prev_seg ? $prev_seg : -1))
				: ($r->{'ms'} - $prev > $pause);
			if ($split) {
				push @sessions, { seq => [@names], times => [@times], start => $start, profile => $sess_profile };
				@names = ();
				@times = ();
				$sess_profile = undef;
			}
		}
		if (!@names) {
			$start = $r->{'ms'};
			$sess_profile = &$profile_of($seg);
		}
		push @names, $r->{'app'};
		push @times, $r->{'ms'};
		$prev = $r->{'ms'};
		$prev_seg = $seg;
	}
	push @sessions, { seq => [@names], times => [@times], start => $start, profile => $sess_profile } if @names;

	# The shape the person is living now is the one the most recent rest belongs
	# to, not the calendar's: the canonical day, its opener and its pauses are
	# that shape's own. A shape still being learned keeps its own day rather than
	# borrowing another's.
	my $selected = ($model && ref $model->{'profile'} eq 'HASH') ? $model->{'profile'} : undef;
	if ($selected) {
		my @mine = grep { ref $_ eq 'HASH' && defined $_->{'profile'} && $_->{'profile'} eq $selected->{'id'} } @sessions;
		@sessions = @mine if @mine;
	}
	# the app that opens the routine most often: the line starts there, so a
	# call or the weather checked before the first step is not made its head
	my $start_app = &clothesline_sequence_start_app(\@sessions);

	# what this run of the routine has already finished, by app: the line takes
	# those occurrences out of the canonical sequence, wherever in it they sit.
	# The times are kept too: the order the steps were finished is what tells a
	# second press of a step the day keeps twice from being its far occurrence.
	my (%done, %done_ms);
	if ($belongs) {
		foreach my $r ( @recent_completed ) {
			next unless $r->{'ms'} >= $last_start;
			$done{$r->{'app'}}++;
			push @{ $done_ms{$r->{'app'}} }, $r->{'ms'};
		}
	}

	my $current = { active => $active, running => undef, start => undef };
	$current->{'running'} = $last_any->{'app'} if $active && $last_any->{'type'} eq 'start'
		&& ($now - $last_any->{'ms'}) <= $pause;
	$current->{'start'} = $belongs ? $last_start : undef;

	# The day under way, and the shape it runs in, for a caller that wants it: the
	# segments themselves stay in clothesline_day_segments (a week of them is not
	# something to carry per hang).
	my $seg = defined $current_seg ? $segments->[$current_seg] : undef;
	my $day = $model ? {
		start => $day_start,
		stop => (ref $seg eq 'HASH' && defined $seg->{'stop'}) ? $seg->{'stop'} : undef,
		inferred => (ref $seg eq 'HASH' && $seg->{'inferred'}) ? 1 : 0,
		profile => $selected ? $selected->{'id'} : undef,
		pause => $pause,
	} : undef;
	my $shape = $selected ? {
		id => $selected->{'id'},
		start_hour => $selected->{'start_hour'},
		stop_hour => $selected->{'stop_hour'},
		count => $selected->{'count'},
		pause => $selected->{'pause'},
		start_app => $selected->{'start_app'},
	} : undef;
	return { apps => $apps, sessions => \@sessions, current => $current, last => $last_any, done => \%done, done_ms => \%done_ms, start_app => $start_app, running => \%open, pause => $pause, day => $day, profile => $shape };
}

# The longest run of steps two sequences share in order, which is how alike two
# days are even when one skips a step or moves one earlier.
sub clothesline_sequence_similarity {
	my ($a, $b) = @_;
	return 0 unless ref $a eq 'ARRAY' && ref $b eq 'ARRAY';
	my ($n, $m) = (scalar @{$a}, scalar @{$b});
	return 0 unless $n && $m;
	my @prev = (0) x ($m + 1);
	for my $i ( 1 .. $n ) {
		my @cur = (0) x ($m + 1);
		for my $j ( 1 .. $m ) {
			$cur[$j] = ($a->[$i - 1] eq $b->[$j - 1])
				? $prev[$j - 1] + 1
				: ($prev[$j] >= $cur[$j - 1] ? $prev[$j] : $cur[$j - 1]);
		}
		@prev = @cur;
	}
	return $prev[$m];
}

# The pause that gives way to the next wave: the day's own top fifth of gaps,
# kept between ten minutes and two hours, so a dense day and a sparse one each
# break where their routines actually change. A caller may pin the gap instead
# (the tests do, and so does a curated day).
sub clothesline_sequence_pause {
	my ($times, $pinned) = @_;
	return $pinned if defined $pinned && $pinned > 0;
	my $gap;
	if (ref $times eq 'ARRAY') {
		my @gaps;
		for my $i ( 1 .. $#{$times} ) {
			push @gaps, $times->[$i] - $times->[$i - 1] if $times->[$i] && $times->[$i - 1];
		}
		if (@gaps) {
			my @sorted = sort { $a <=> $b } @gaps;
			$gap = $sorted[ int($#sorted * 0.8) ];
			$gap = 10 * 60 * 1000 if $gap < 10 * 60 * 1000;
			$gap = 120 * 60 * 1000 if $gap > 120 * 60 * 1000;
		}
	}
	return (defined $gap && $gap > 0) ? $gap : (90 * 60 * 1000);
}

# Which wave each step of the day falls in: the wave turns over wherever two
# steps are further apart than the day's own pause. A step with no time cannot
# turn one over, so it keeps the wave it landed in. `$count` is the day's step
# count, which may outrun the times when a caller handed only some of them.
sub clothesline_sequence_waves {
	my ($times, $gap, $count) = @_;
	my @waves;
	return \@waves unless ref $times eq 'ARRAY';
	$count = scalar @{$times} unless defined $count;
	$gap = 90 * 60 * 1000 unless defined $gap && $gap > 0;
	my $wave = 0;
	for my $i ( 0 .. $count - 1 ) {
		if ($i > 0 && $times->[$i] && $times->[$i - 1]
			&& ($times->[$i] - $times->[$i - 1]) > $gap) { $wave++; }
		push @waves, $wave;
	}
	return \@waves;
}

# The app that opens the day most often: the line starts there, so a call or the
# weather checked before the first step is not made the routine's head. A
# profile learns its own opener, so a night shift's day does not open with the
# step a day shift happens to take first.
sub clothesline_sequence_start_app {
	my ($sessions) = @_;
	my %count;
	foreach my $s ( ref $sessions eq 'ARRAY' ? @{$sessions} : () ) {
		next unless ref $s eq 'HASH' && ref $s->{'seq'} eq 'ARRAY' && @{ $s->{'seq'} };
		$count{ $s->{'seq'}[0] }++;
	}
	my ($app, $best) = (undef, -1);
	foreach my $name ( sort keys %count ) {
		if ($count{$name} > $best) { ($app, $best) = ($name, $count{$name}); }
	}
	return $app;
}

# The most common recent day: the session whose sequence is most like all the
# others, with an exact shape winning a tie and the later session after that. A
# day that moves one step is still close to the rest; a one-off day is not. The
# comparison looks at the first thirty steps after the routine's start, which is
# cheap and enough to tell one day's shape from another; the whole day is
# returned, so the head can reach the evening's steps as the day goes on.
#
# The shape the person is living now is a profile (a day shift and a night shift
# are two): a caller that names one keeps only the sessions tagged with it, so
# the canonical day is the selected profile's own. A session with no tag - a
# test's, a curated day's - always counts.
sub clothesline_sequence_canonical {
	my ($sessions, $start_app, $wave_gap, %opt) = @_;
	$sessions = [] unless ref $sessions eq 'ARRAY';
	if (defined $opt{'profile'}) {
		my @kept = grep { ref $_ eq 'HASH' && (!defined $_->{'profile'} || $_->{'profile'} eq $opt{'profile'}) } @{$sessions};
		$sessions = \@kept if @kept;
	}
	my $cap = 30;
	my (@full, @full_times, @full_waves, @cut);
	foreach my $session ( @{$sessions} ) {
		next unless ref $session eq 'HASH' && ref $session->{'seq'} eq 'ARRAY';
		my @seq = @{ $session->{'seq'} };
		my @times = ref $session->{'times'} eq 'ARRAY' ? @{ $session->{'times'} } : ();
		next unless @seq;
		if (defined $start_app && length $start_app) {
			my $at = -1;
			for my $i ( 0 .. $#seq ) { if ($seq[$i] eq $start_app) { $at = $i; last; } }
			if ($at > 0) {
				@seq = @seq[$at .. $#seq];
				@times = @times[$at .. $#times] if @times > $at;
			}
		}
		# A wave is one stretch of the day: the steps run close together, then the
		# day pauses before the next. The pause is the day's own (see
		# clothesline_sequence_pause), unless the caller pinned the gap.
		my $gap = &clothesline_sequence_pause(\@times, $wave_gap);
		my $waves = &clothesline_sequence_waves(\@times, $gap, scalar @seq);
		push @full, \@seq;
		push @full_times, \@times;
		push @full_waves, $waves;
		my @short = @seq;
		@short = @short[0 .. $cap - 1] if @short > $cap;
		push @cut, \@short;
	}
	return { seq => [], times => [], waves => [] } unless @full;
	return { seq => $full[0], times => $full_times[0], waves => $full_waves[0] } if @full == 1;

	my ($best_idx, $best_score, $best_freq) = (-1, -1, -1);
	for my $i ( 0 .. $#cut ) {
		my $score = 0;
		for my $j ( 0 .. $#cut ) {
			next if $i == $j;
			$score += &clothesline_sequence_similarity($cut[$i], $cut[$j]);
		}
		my $shape = join("\x1f", @{$cut[$i]});
		my $freq = scalar grep { join("\x1f", @{$_}) eq $shape } @cut;
		if ($score > $best_score
			|| ($score == $best_score && ($freq > $best_freq
			|| ($freq == $best_freq && $i > $best_idx)))) {
			($best_idx, $best_score, $best_freq) = ($i, $score, $freq);
		}
	}
	return { seq => [], times => [], waves => [] } if $best_idx < 0;
	return { seq => $full[$best_idx], times => $full_times[$best_idx], waves => $full_waves[$best_idx] };
}

# The next steps of the routine, in the order the most common recent day keeps
# them. The steps already finished today are taken out of that sequence,
# wherever they sat in it, so a bed made before the coffee does not move the
# rest; a step done twice leaves its later occurrence to come round again. Each
# app is named once in the answer. A step whose day is not today is skipped but
# the walk carries on past it.
sub clothesline_sequence_anticipate {
	my ($scan, $now, %opt) = @_;
	$scan = {} unless ref $scan eq 'HASH';
	$now = &rightNow() unless defined $now;
	my $limit = $opt{'limit'} || 40;
	# A caller may ask for the whole day rather than the head (the anticipatory
	# settings walk this week): every wave, and nothing taken out for what is
	# already done, so the afternoon and the evening are there to curate too.
	my $all = $opt{'all_waves'} ? 1 : 0;
	# A curated day hands its own order in. The done subtraction and the wave
	# limit below are the same ones the learned order uses, so the head still
	# advances through a planned day instead of freezing on its first pill.
	my $sessions = ref $scan->{'sessions'} eq 'ARRAY' ? $scan->{'sessions'} : [];
	my ($seq, $waves, $canonical_times);
	if (ref $opt{'sequence'} eq 'ARRAY') {
		$seq = $opt{'sequence'};
		$waves = ref $opt{'waves'} eq 'ARRAY' ? $opt{'waves'} : [ (0) x scalar @{$seq} ];
		$canonical_times = $opt{'times'};
	}
	else {
		my $canonical = $opt{'canonical'} || &clothesline_sequence_canonical($sessions, $scan->{'start_app'});
		$seq = ref $canonical eq 'HASH' ? $canonical->{'seq'} : $canonical;
		$waves = (ref $canonical eq 'HASH' && ref $canonical->{'waves'} eq 'ARRAY') ? $canonical->{'waves'} : undef;
		$canonical_times = (ref $canonical eq 'HASH' && ref $canonical->{'times'} eq 'ARRAY') ? $canonical->{'times'} : undef;
	}
	return { list => [], current_wave => 0 } unless ref $seq eq 'ARRAY' && @{$seq};
	my $done = ref $scan->{'done'} eq 'HASH' ? $scan->{'done'} : {};
	# A pill the person added by hand belongs to no routine, so it is not left
	# behind when the wave limit moves on.
	my %keep = map { $_ => 1 } grep { defined $_ && length $_ } @{ $opt{'keep'} || [] };
	# `next_wave` off keeps the routine under way only; the default lets the one
	# after it ride along, as the rail always has.
	my $next_wave = (defined $opt{'next_wave'}) ? ($opt{'next_wave'} ? 1 : 0) : 1;

	# Which wave the last finished step sits in: the line shows that wave's
	# remainder and the one after it, never a wave two ahead. The wave is read
	# from the person's own order through the learned day, not from the clock:
	# they may wake at five or at eleven, and the same routine runs in a longer
	# or shorter span, so the hour is no anchor for where the day stands. A step
	# the day keeps twice (toothbrushing morning and night) must not be pulled to
	# its far occurrence by a second press in the morning: a completion advances
	# only to an occurrence in the wave under way or the one after it, and a
	# repeat of a step already passed stays a repeat. A caller that hands only
	# counts - a test, a curated day - still places it by the order the steps
	# were finished.
	#
	# A wave whose steps were never done does not hold the day back: a morning
	# skipped is still a morning passed when the midday step is pressed. The
	# occurrence a press belongs to is the one its own hour of the day points at,
	# so a step the day keeps twice is answered by the occurrence the person is
	# actually at, and a press clearly past an early occurrence leaves it behind
	# (the wave limit is what still stops a repeat jumping to its far one).
	my (%left, $current_wave);
	$current_wave = 0;
	if (!$all) {
		my $anchored;
		if (ref $scan->{'done_ms'} eq 'HASH' && ref $waves eq 'ARRAY' && @{$waves}) {
			# only a step the learned day knows can place the wave; a call, a
			# step off the line, says nothing about where the routine stands
			my %known = map { $_ => 1 } @{$seq};
			my @acts;
			foreach my $app ( keys %{$scan->{'done_ms'}} ) {
				next unless $known{$app} && ref $scan->{'done_ms'}{$app} eq 'ARRAY';
				foreach my $ms ( @{$scan->{'done_ms'}{$app}} ) {
					push @acts, { app => $app, ms => $ms } if defined $ms;
				}
			}
			if (@acts) {
				@acts = sort { $a->{'ms'} <=> $b->{'ms'} } @acts;
				my %occ;
				for my $i ( 0 .. $#{$seq} ) { push @{ $occ{ $seq->[$i] } }, $i; }
				# the day's own clock: an act and an occurrence are compared by
				# how far each sits from the day's first step, never by the hour
				my $cbase = (ref $canonical_times eq 'ARRAY' && defined $canonical_times->[0]) ? (0 + $canonical_times->[0]) : undef;
				my $abase = (ref $scan->{'current'} eq 'HASH' && defined $scan->{'current'}{'start'}) ? $scan->{'current'}{'start'}
					: (ref $scan->{'day'} eq 'HASH' && defined $scan->{'day'}{'start'}) ? $scan->{'day'}{'start'}
					: undef;
				my $near = (defined $opt{'near'} && $opt{'near'} > 0) ? $opt{'near'}
					: (ref $scan->{'pause'} && $scan->{'pause'} > 0) ? $scan->{'pause'}
					: (90 * 60 * 1000);
				my $off_of = sub {
					my ($i) = @_;
					return undef unless defined $cbase && ref $canonical_times eq 'ARRAY' && defined $canonical_times->[$i];
					return (0 + $canonical_times->[$i]) - $cbase;
				};
				my ($at, %used);
				$at = 0;
				foreach my $step ( @acts ) {
					my $list = $occ{ $step->{'app'} } or next;
					my $act_off = defined $abase ? $step->{'ms'} - $abase : undef;
					my (@pick, @passed);
					foreach my $i ( @{$list} ) {
						next if $i < $at || $used{$i};
						my $wave = defined $waves->[$i] ? $waves->[$i] : 0;
						my $off = $off_of->($i);
						my $close = (defined $act_off && defined $off) ? (abs($off - $act_off) <= $near ? 1 : 0) : 0;
						next unless $wave <= $current_wave + 1 || $close;
						push @pick, { i => $i, wave => $wave, off => $off };
						# the person is already at this occurrence, not waiting for it
						push @passed, $i if defined $off && defined $act_off && $off <= $act_off;
					}
					next unless @pick;
					# The occurrence a press belongs to is the one its own hour of the day
					# points at. Those the person is already past win, the latest of them;
					# with none, the nearest one ahead. A caller with no day clock keeps
					# the old order: the first one that fits the wave.
					my $best;
					if (!defined $act_off) { $best = $pick[0]; }
					else {
						my %passed = map { $_ => 1 } @passed;
						my @prefer = @passed ? (grep { $passed{ $_->{'i'} } } @pick) : @pick;
						$best = $prefer[0];
						foreach my $c ( @prefer ) {
							my ($a, $b) = ($c->{'off'}, $best->{'off'});
							next if !defined $a && defined $b;
							if (defined $a && defined $b) {
								# a passed occurrence: the latest one; else the nearest ahead
								my $cmp = @passed ? ($b <=> $a) : (abs($a - $act_off) <=> abs($b - $act_off));
								next if $cmp > 0;
								next if $cmp == 0 && $c->{'i'} > $best->{'i'};
							}
							elsif (!defined $a && !defined $b) { next if $c->{'i'} > $best->{'i'}; }
							$best = $c;
						}
					}
					$used{ $best->{'i'} } = 1;
					$at = $best->{'i'} + 1;
					$current_wave = $best->{'wave'} if $best->{'wave'} > $current_wave;
				}
				$anchored = 1;
			}
		}
		if (!$anchored) {
			for my $i ( 0 .. $#{$seq} ) {
				my $app = $seq->[$i];
				if (($left{$app} //= ($done->{$app} || 0)) > 0) {
					$left{$app}--;
					$current_wave = $waves->[$i] if $waves && defined $waves->[$i];
				}
			}
		}
	}

	my (@out, %seen, %left2);
	my $base = ($canonical_times && defined $canonical_times->[0]) ? (0 + $canonical_times->[0]) : undef;
	for my $i ( 0 .. $#{$seq} ) {
		my $app = $seq->[$i];
		if (!$all && ($left2{$app} //= ($done->{$app} || 0)) > 0) { $left2{$app}--; next; }
		my $wave = ($waves && defined $waves->[$i]) ? $waves->[$i] : 0;
		if (!$all) {
			next if $wave < $current_wave && !$keep{$app};
			next if $wave > $current_wave + $next_wave && !$keep{$app};
		}
		next if $seen{$app}++;
		my $due = ($scan->{'apps'}{$app} && defined $scan->{'apps'}{$app}{'due'}) ? $scan->{'apps'}{$app}{'due'} : 1;
		next unless $due || $opt{'force_due'};
		my $off = (defined $base && $canonical_times && defined $canonical_times->[$i]) ? (0 + $canonical_times->[$i]) - $base : undef;
		push @out, { app => $app, wave => $wave, off => $off };
		last if @out >= $limit;
	}

	# A step that is running sits where the routine usually stops it, not where
	# it starts. The wake-up runs all morning while the water and the coffee come
	# and go, so its pill moves down past them to the point of the day it is
	# usually stopped - the head then leads with the next press either way, and
	# there is little walking the rail to find the pill in hand.
	my $running = ref $scan->{'running'} eq 'HASH' ? $scan->{'running'} : {};
	if (@out && %{$running}) {
		my @keyed;
		my $last = 0;
		for my $n ( 0 .. $#out ) {
			my $row = $out[$n];
			my $key = $row->{'off'};
			$key = $last unless defined $key;
			if (exists $running->{$row->{'app'}}) {
				my $len = $scan->{'apps'}{$row->{'app'}}{'length'};
				$key += $len if defined $len && $len > 0;
			}
			$last = $key;
			push @keyed, [ $key, $n, $row ];
		}
		@out = map { $_->[2] } sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @keyed;
	}
	return { list => \@out, current_wave => $current_wave };
}

1;
