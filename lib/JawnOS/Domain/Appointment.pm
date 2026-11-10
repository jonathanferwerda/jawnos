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

sub internet_site_appointment_tick {
	my ($opts) = @_;
	$opts ||= {};
	my $now = &rightNow();
	return 0 if !$opts->{'force'} && defined $internet_site_tick_at && $now - $internet_site_tick_at < 2000;
	$internet_site_tick_at = $now;
	my $map = &internet_domain_app_map();
	return 0 unless scalar keys %{$map};
	my $grace = 60000;
	my $from = $now - 15 * 60 * 1000;
	my $rows = eval {
		&db_query(q{
			select key_name, started_at, ended_at
			  from usage_sessions
			 where kind = 'site' and cast(ended_at as integer) >= ?
			 order by cast(started_at as integer) asc
		}, $from)->hashes;
	} || [];
	my (%run_start, %run_end, %domains_for_app);
	foreach my $domain ( keys %{$map} ) {
		my $app = $map->{$domain} // next;
		push @{$domains_for_app{$app}}, $domain if length $domain;
	}
	foreach my $row ( @{$rows} ) {
		my $domain = lc($row->{'key_name'} // '');
		$domain =~ s/^www\.//;
		my $app = $map->{$domain} || next;
		my $start = int($row->{'started_at'} // 0);
		my $end = int($row->{'ended_at'} // 0);
		next unless $start > 0 && $end > 0;
		if (!defined $run_end{$app}) {
			$run_start{$app} = $start;
			$run_end{$app} = $end;
		}
		elsif ($start <= $run_end{$app} + $grace) {
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
			my $domains = $domains_for_app{$app} || [];
			if (scalar @{$domains}) {
				my $ph = join ',', map { '?' } @{$domains};
				my $row = eval {
					&db_query("select max(cast(ended_at as integer)) as last_end from usage_sessions where kind = 'site' and key_name in ($ph) and cast(ended_at as integer) >= ?", @{$domains}, $started)->hash;
				} || {};
				$last = int($row->{'last_end'}) if defined $row->{'last_end'} && $row->{'last_end'} ne '';
			}
		}
		my $active = defined $last && ($now - $last) <= $grace && !&app_hidden_now($app);
		next if $active;
		my $stop_at = (defined $last && $last > $started) ? $last : $now;
		# A session's duration is the negative accrual (start - stop), the sign
		# every other close path writes; a positive value paints the band before
		# the start dot instead of running from it to the recorded end.
		my $duration = $started - $stop_at;
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
	}
	# Sessions to start: a mapped site that is still being reported and has no
	# session of any kind running for its app.
	foreach my $app ( sort keys %run_end ) {
		next if $now - $run_end{$app} > $grace;
		next if &app_hidden_now($app);
		next if &open_session_uuid($app);
		my $init = &setting_initializer($app, $run_start{$app});
		my $name = (ref $init eq 'HASH' && $init->{'app'}) ? $init->{'app'} : $app;
		next if $name ne $app && (&open_session_uuid($name) || &app_hidden_now($name));
		my $start_at = $run_start{$app};
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
# navigation_automation (three navigation intervals). The fact is transient (a
# cache entry), but it only has to outlive the next fix and the resume window.
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
								# A return within three navigation intervals of a navigation stop is
								# the same visit, so reopen that session rather than starting a new
								# one. The interval is the machine's navigation job in the utility
								# controller (four minutes by default), so the window follows the
								# pace that produced the fixes rather than a fixed fifteen
								# minutes - a plate that reports every ten minutes keeps the visit
								# whole across two missed fixes. A leave farther than three radii
								# was certain, so its return starts a new session even inside the
								# window. Reopen only the newest stop - the one the person has
								# just come back from - never every stop in the window.
								my $reopen_window = 3 * &navigation_interval($signatorial) * 1000;
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
