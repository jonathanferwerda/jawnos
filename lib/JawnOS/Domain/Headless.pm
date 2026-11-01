package subs;

# Headless: extracted from subroutines.pl (package subs). Loaded on
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
our $device;
our $gb;
our $lockdown_enemy_apps_cache;
our %lockdown_sweep_at;
our $log;
our %m;
our $presence_relationship_cache;
our $present_person_apps_cache;
our @relationship_order;
our %relationship_rating;
our $visibility_exposure_cache;
our %visibility_graph_links;
our $visibility_graph_ready;
our %visibility_graph_uuid_app;

sub headless_navigation {
	my $signatorial = &subs::signatorial_designer();
	my $now = &subs::rightNow();
	my $navigation_due = [];
	my $note;
	my $running_appts = &subs::db_query('select app,uuid,type,warranty from appointments where (type = ? or type = ?) and timestamp < ?', 'start', 'record', $now)->hashes;
	foreach my $appt ( @{$running_appts} ) {
		my $navigation = &subs::setting_grabber({ app => $appt->{'app'}, setting => 'navigation' });
		if ($navigation eq 'none') {
			next;
		}
		if ($navigation eq 'once') {
			# `once` means "log when the person acts", but a start on a cold GPS
			# can happen before the first fix arrives. If the running appointment
			# still has no point of its own, give it the next real fix rather than
			# losing the act.
			my $has_point = &subs::db_query('select uuid from continent where app = ? and uuid like ? and latitude is not null and latitude != ? order by server_time desc limit 1', $appt->{'app'}, $appt->{'uuid'} . '%', '')->hashes->[0];
			unless ($has_point) {
				push @{$navigation_due}, {
					app => $appt->{'app'},
					uuid => $appt->{'uuid'},
					warranty => $appt->{'warranty'},
				};
			}
			next;
		}
		else {
			my $last_appt_location = &subs::db_query('select * from continent where app=? and uuid like ? order by server_time desc', $appt->{'app'}, $appt->{'uuid'} . '%')->hashes->[0];
			my $increment = &subs::time_abbrev_translator($navigation);
			if ($now >= $last_appt_location->{'timestamp'} + $increment ) {
				push @{$navigation_due}, { app => $appt->{'app'}, uuid => $appt->{'uuid'} };
			}
		}
	}

	# utility_runner is the navigation schedule; this second gate only guards a
	# call from elsewhere. The runner's tick of slack keeps a call landing a few
	# milliseconds before the interval from skipping a whole slot (the stamp is
	# taken at the slot, so a strict comparison can be just short).
	my $pace = &navigation_pace();
	if ($now - $gb::timeouts->{'navigation'}->{'lasted_run'} >= ($pace * 1000) - 5000) {
		$gb::timeouts->{'navigation'}->{'lasted_run'} = $now;
		my $returner = {
			uuid => &subs::random_string_creator(103),
			type => 'temporary',
			app => '__president',
			timestamp => $now,
			signatorial => $signatorial,
			server_time => &subs::rightNow(),
			# duration_sayer reads seconds; a millisecond count here used to become
			# "8d 8h" for a four-minute pace and left a stale place current for days
			warranty => &subs::ago_calc('-' . &subs::duration_sayer(&navigation_interval() * 3),$now),
		};
		my $written = 0;
		# The capture runs on the navigation interval alone (the gate above). It
		# used to also wait until the machine's newest location row was older than
		# the interval - but the browser writes those rows too (continent_record),
		# so an open app reset the clock and this autonomous capture starved. It now
		# records on its own cadence whether or not the browser just did.
		if (&subs::device_setter() eq 'mobile') {
			# The app's GPS service keeps this machine's fix on disk, so there
			# is no process to spawn and no wait; the file is as fresh as the
			# navigation pace. A machine that has not run the service yet asks
			# the bridge for one GPS fix - never the network provider.
			my $current_pace = &navigation_pace();
			my $max_age = ($current_pace * 2 * 1000) + 120000;
			$max_age = 5 * 60 * 1000 if $max_age < 5 * 60 * 1000;
			$max_age = 15 * 60 * 1000 if $max_age > 15 * 60 * 1000;
			my $loc = &subs::native_location({ max_age_ms => $max_age });
			unless ($loc) {
				my $j = &subs::device_call('location.current', { provider => 'gps', timeout_ms => 20000 }) || {};
				if (($j->{'provider'} || '') eq 'gps' && $j->{'latitude'}
					&& ($j->{'elapsedMs'} || 1e9) <= $max_age) {
					$loc = {
						provider => 'gps',
						latitude => $j->{'latitude'},
						longitude => $j->{'longitude'},
						accuracy => $j->{'accuracy'},
						elapsedMs => $j->{'elapsedMs'},
					};
				}
			}
			# Only a `gps` provider answer proves this machine has the
			# hardware; a machine with no GPS must never become a source
			# another machine borrows from.
			&subs::navigation_gps_confirm($loc->{'provider'}) if $loc;
			my $has_gps = &subs::navigation_gps_present();
			# The service already bounds the fix's age; a walk still gives
			# perfectly usable fixes that are a little loose.
			my $usable = $has_gps && $loc && $loc->{'latitude'}
				&& ($loc->{'accuracy'} || 0) < 500;
			if ($usable) {
				$returner->{'latitude'} = $loc->{'latitude'};
				$returner->{'longitude'} = $loc->{'longitude'};
				$returner->{'accuracy'} = sprintf("%.2F", ($loc->{'accuracy'} || 0));
				&subs::db_delete('continent', { type => 'temporary', signatorial => $signatorial });
				my $treturner = clone $returner;
				$treturner->{'uuid'} = &subs::random_string_creator(31);
				&subs::db_insert('continent', $treturner);
				$written = 1;
				$note = 'fix gps ' . ($returner->{'accuracy'} || '?') . 'm';
			}
			else {
				$log->info('navigation: no fresh GPS fix; no place recorded');
				$note = 'no usable fix';
			}
		}
		else {
			$returner = &subs::embedded_location_grabber($returner);
			if ($returner->{'latitude'}) {
				&subs::db_delete('continent', { type => 'temporary', signatorial => $signatorial });
				my $treturner = clone $returner;
				$treturner->{'uuid'} = &subs::random_string_creator(31);
				&subs::db_insert('continent', $treturner);
				$written = 1;
				$note = 'fix ' . ($returner->{'accuracy'} || '?') . 'm';
			}
		}
		if ($returner->{'latitude'} && $written == 1) {
			# Hand the fix to a computer on this LAN before the appointment
			# bookkeeping runs: the laptop records the place, but only this
			# machine (the one holding the GPS) starts or stops appointments.
			&subs::navigation_share_fix($returner);

		#	&subs::db_insert('continent', $returner);
			foreach my $nd ( @{$navigation_due} ) {
				$returner->{'uuid'} = $nd->{'uuid'} . '-' . &subs::random_string_creator(9);
				$returner->{'app'} = $nd->{'app'};
				$returner->{'warranty'} = $nd->{'warranty'};
				$returner->{'type'} = 'app';
				&subs::db_insert('continent', $returner);
			}
			&subs::navigation_automation($returner, 'gps');

		}
	}
	return $note;
}

sub navigation_information {
	my $data = shift;
	my $current_locations;
	if ($data->{'signatorial'}) {
		$current_locations = &subs::db_query('select * from continent where type=? and signatorial =? and cast(warranty as integer) > cast(? as integer)','temporary',$data->{'signatorial'},&subs::rightNow())->hashes;
	} else {
		$current_locations = &subs::db_query('select * from continent where type=? and cast(warranty as integer) > cast(? as integer)','temporary',&subs::rightNow())->hashes;
	}
	my $navigation_information = {};
	my $runs = 0;
	my $count = 0;
	foreach my $cl ( @{$current_locations} ) {
		$count++;
		my $cache = &subs::cache_get({ app => 'travel', context => 'navigation_information', subcontext => $cl->{'signatorial'} });
		next if $cache->{'timestamp'} + 5000 >= &subs::rightNow();
		$navigation_information->{$cl->{'signatorial'}}->{'__location'} = $cl;
		if (!$cache->{'__location'}) { $runs++; $runs++; next; }
		if (!$cache->{'__location'}->{'warranty'} || $cache->{'__location'}->{'warranty'} < &subs::rightNow()) { $runs++; $runs++; next; }
		my @old_location = (deg2rad($cache->{'__location'}->{'longitude'}), deg2rad(90 - $cache->{'__location'}->{'latitude'}));
		my @new_location = (deg2rad($cl->{'longitude'}), deg2rad(90 - $cl->{'latitude'}));
		my $distance = sprintf("%.3f", great_circle_distance(@old_location, @new_location, $gb::planet_radius));

		if ($distance < .020 || ($data->{'cache'} eq 'yes' && $cache->{'__location'}->{'latitude'}) ) {
			$navigation_information->{$cl->{'signatorial'}} = $cache;
			next;
		}
		elsif (!$cache->{'__location'}->{'latitude'}) {
#			&subs::headless_navigation();
			$runs++;$runs++;
		}
		$runs++;
	}

	if ($runs < $count && scalar @{$current_locations} > 0) {
		return $navigation_information;
	}
	elsif (scalar @{$current_locations} == 0 && $data->{'signatorial'}) {
		my $pset = &subs::settings_grabber({ app => '__president', settings => [ $data->{'signatorial'} . '_site_type', $data->{'signatorial'} . '_site_rating' ] });
		if ($pset->{$data->{'signatorial'} . '_site_type'}) {
			$navigation_information->{$data->{'signatorial'}}->{'site_type'} = $pset->{$data->{'signatorial'} . '_site_type'};
			$navigation_information->{$data->{'signatorial'}}->{'site_rating'} = $pset->{$data->{'signatorial'} . '_site_rating'};
			$navigation_information->{$data->{'signatorial'}}->{'site_source'} = 'manual';
		} else {
			$navigation_information->{$data->{'signatorial'}}->{'site_type'} = 'public';
			$navigation_information->{$data->{'signatorial'}}->{'site_rating'} = $gb::site_types->{'public'}->{'rating'};
			$navigation_information->{$data->{'signatorial'}}->{'site_source'} = 'lost';
		}
		return $navigation_information;
	}
	else {
		my $pset = {};
		my $hpds = &subs::db_query('select * from settings where setting=? and value is not null and value != ?', 'home_plate_duties', '[]')->hashes;
		foreach my $hpder ( @{$hpds} ) {
			my $home_plate = eval { return decode_json &subs::setting_grabber({ app => $hpder->{'app'}, setting => 'home_plate' }) || &subs::setting_grabber({ app => 'me', setting => 'home_plate' }) } || {};
			if ($home_plate->{'latitude'}) {
				my $hpd = eval { return decode_json $hpder->{'value'} } || [];
				foreach my $hp ( @{$hpd} ) {
					my $parent_app = $hpder->{'app'};
					# a plate only triggers its own app; a duty may carry its own ground
					my $app = $parent_app;
					next unless $app;
					my $plate_lat = $hp->{'latitude'} || $home_plate->{'latitude'};
					my $plate_lon = $hp->{'longitude'} || $home_plate->{'longitude'};
					next unless $plate_lat && $plate_lon;
					my @home_plate = (deg2rad($plate_lon), deg2rad(90 - $plate_lat));
					foreach my $returner ( @{$current_locations} ) {
						next if grep { $_ eq $returner->{'signatorial'}} @{$hp->{'signatorials'}};
						push @{$hp->{'signatorials'}}, $returner->{'signatorial'};

						$pset->{$returner->{'signatorial'}} = &subs::settings_grabber({ app => '__president', settings => [ $returner->{'signatorial'} . '_site_type', $returner->{'signatorial'} . '_site_rating' ] })
							unless $pset->{$returner->{'signatorial'}};

						my @visitor = (deg2rad($returner->{'longitude'}), deg2rad(90 - $returner->{'latitude'}));
						my $distance = sprintf("%.3f", great_circle_distance(@home_plate, @visitor, $gb::planet_radius));

						my $hset = &subs::settings_grabber({ app => $app, settings => [ 'warranty', 'toggle', 'site_type'] });
						my $tog = $hset->{'toggle'};
						my $ndata = {
							app => $app,
							distance => $distance,
							parent_app => $parent_app
					#		current_location => $returner,
					#		coordinates => $home_plate
						};
						if ($hp->{'placement'} eq 'within') {
							if ($distance <= $hp->{'distance'}) {
								push @{$navigation_information->{$returner->{'signatorial'}}->{'within'}}, $ndata;
								push @{$navigation_information->{$returner->{'signatorial'}}->{'site_types'}}, $hset->{'site_type'} || 'public';
							} else {
								push @{$navigation_information->{$returner->{'signatorial'}}->{'other'}}, $ndata;
							}
						}
						elsif ($hp->{'placement'} eq 'without') {
							if ($distance > $hp->{'distance'}) {
								push @{$navigation_information->{$returner->{'signatorial'}}->{'without'}}, $ndata;
							} else {
								push @{$navigation_information->{$returner->{'signatorial'}}->{'other'}}, $ndata;
							}
						}
						else {

							push @{$navigation_information->{$returner->{'signatorial'}}->{'other'}}, $ndata;

						}
						my $site_type = $navigation_information->{$returner->{'signatorial'}}->{'site_type'} || $gb::site_types->{'public'}->{'name'};
						my $site_rating = $navigation_information->{$returner->{'signatorial'}}->{'site_rating'} || $gb::site_types->{'public'}->{'rating'};
						my $types = $navigation_information->{$returner->{'signatorial'}}->{'site_types'};
						foreach my $t ( reverse sort { $gb::site_types->{$a}->{'rating'} <=> $gb::site_types->{$b}->{'rating'} } keys %{$gb::site_types} ) {
							if ( grep { $_ eq $t } @{$types} ) {
								$site_type = $t;
								$site_rating = $gb::site_types->{$t}->{'rating'};
								if ($site_rating >= 3) {
									last;
								}
							}
						}
						if ($pset->{$returner->{'signatorial'}}->{$returner->{'signatorial'} . '_site_type'}) {
							$navigation_information->{$returner->{'signatorial'}}->{'site_type'} = $pset->{$returner->{'signatorial'}}->{$returner->{'signatorial'} . '_site_type'};
							$navigation_information->{$returner->{'signatorial'}}->{'site_rating'} = $pset->{$returner->{'signatorial'}}->{$returner->{'signatorial'} . '_site_rating'};
							$navigation_information->{$returner->{'signatorial'}}->{'site_source'} = 'manual';
						} else {
							$navigation_information->{$returner->{'signatorial'}}->{'site_type'} = $site_type || 'public';
							$navigation_information->{$returner->{'signatorial'}}->{'site_rating'} = $site_rating || 0;
							$navigation_information->{$returner->{'signatorial'}}->{'site_source'} = 'navigation';
						}
					}
				}
			}
		}
		foreach my $sig ( keys %{$navigation_information} ) {
			$navigation_information->{'timestamp'} = &subs::rightNow();
			&subs::cache_set({ app => 'travel', context => 'navigation_information', subcontext => $sig, warranty => '-10m' }, $navigation_information->{$sig});
		}
		return $navigation_information;
	}
}

sub relationship_part_rating {
	my ($part) = @_;
	$part = lc($part // '');
	$part =~ s/^\s+|\s+$//g;
	return 0 unless length $part;
	return $relationship_rating{$part} if exists $relationship_rating{$part};
	return 3 if $part =~ /^(?:enemy|hostile|combative|adversarial|blacklist|blacklisted|blocked)$/;
	return 2 if $part =~ /^(?:stranger|unknown|indifferent|neutral|competitive)$/;
	return 1 if $part =~ /^(?:friend|friendly|self|familial|amicable|professional|sexual|marital|holy)$/;
	return 0;
}

sub relationship_rating {
	my ($value) = @_;
	$value = $value->{'value'} if ref $value eq 'HASH';
	$value = join ',', @{$value} if ref $value eq 'ARRAY';
	return 0 unless defined $value;
	my $v = "$value";
	$v = lc $v;
	$v =~ s/^\s+|\s+$//g;
	return $relationship_rating{$v} if exists $relationship_rating{$v};
	if ($v =~ /^\s*\[/) {
		my $list = eval { decode_json($v) };
		$v = ref $list eq 'ARRAY' ? join ',', @{$list} : '';
	}
	my $rating = 0;
	foreach my $part (split /[,\s]+/, $v) {
		my $r = &relationship_part_rating($part);
		$rating = $r if $r > $rating;
	}
	return $rating;
}

sub relationship_value {
	my ($value) = @_;
	my $rating = &relationship_rating($value);
	return '' unless $rating;
	return ('', 'friend', 'stranger', 'enemy')[$rating];
}

sub relationship_options {
	return [ map { {
		value => $_,
		rating => $relationship_rating{$_},
		label => &format_name($_),
	} } @relationship_order ];
}

sub person_relationship_value {
	my ($app) = @_;
	return '' unless defined $app && length $app;
	my $row = eval {
		&db_query("select value from settings where app = ? and setting = 'app_measures' order by cast(server_time as integer) desc limit 1", $app)->hashes->[0];
	};
	my $am = $row ? (eval { decode_json($row->{'value'}) } || {}) : {};
	my $value = &relationship_value($am->{'relationship'}->{'value'} // '');
	unless (length $value) {
		my $direct = eval {
			&db_query("select value from settings where app = ? and setting = 'relationship' order by cast(server_time as integer) desc limit 1", $app)->hashes->[0];
		};
		$value = &relationship_value($direct->{'value'} // '') if $direct;
	}
	return $value;
}

sub person_relationship_rating {
	my ($app) = @_;
	return &relationship_rating(&person_relationship_value($app));
}

sub person_relationships {
	my %map;
	my $rows = eval {
		&db_query("select app, value from settings where setting = 'app_measures' and value like '%relationship%' order by cast(server_time as integer)")->hashes;
	} || [];
	foreach my $row ( @{$rows} ) {
		my $app = $row->{'app'} // next;
		my $am = eval { decode_json($row->{'value'}) } || {};
		my $value = &relationship_value($am->{'relationship'}->{'value'} // '');
		next unless length $value;
		$map{$app} = { value => $value, rating => $relationship_rating{$value} };
	}
	my $direct = eval {
		&db_query("select app, value from settings where setting = 'relationship' order by cast(server_time as integer)")->hashes;
	} || [];
	foreach my $row ( @{$direct} ) {
		my $app = $row->{'app'} // next;
		my $value = &relationship_value($row->{'value'});
		next unless length $value;
		$map{$app} = { value => $value, rating => $relationship_rating{$value} };
	}
	return \%map;
}

sub present_person_apps {
	my ($opts) = @_;
	$opts ||= {};
	return $present_person_apps_cache if defined $present_person_apps_cache && !$opts->{'refresh'};
	my $rows = eval {
		&db_query(q{
			select distinct a.app as app
			  from appointments a
			 where (a.stop_timestamp is null or a.stop_timestamp = '')
			   and a.type in ('start','record')
			   and exists (
			       select 1 from settings s
			        where s.app = a.app
			          and s.setting in ('pos','mab')
			          and s.value = 'person'
			   )
		})->hashes;
	} || [];
	my @apps = map { $_->{'app'} } grep { defined $_->{'app'} && length $_->{'app'} } @{$rows};
	$present_person_apps_cache = \@apps;
	return $present_person_apps_cache;
}

sub present_relationship_rating {
	my ($opts) = @_;
	$opts ||= {};
	return $presence_relationship_cache if defined $presence_relationship_cache && !$opts->{'refresh'};
	my $rating = 0;
	foreach my $app ( @{ &present_person_apps($opts) } ) {
		my $r = &person_relationship_rating($app);
		$rating = $r if $r > $rating;
	}
	$presence_relationship_cache = $rating;
	return $rating;
}

sub lockdown_enemy_apps {
	my ($opts) = @_;
	$opts ||= {};
	return $lockdown_enemy_apps_cache if defined $lockdown_enemy_apps_cache && !$opts->{'refresh'};
	my %apps;
	foreach my $app ( @{ &present_person_apps($opts) } ) {
		$apps{$app} = 1 if &person_relationship_rating($app) >= 3;
	}
	$lockdown_enemy_apps_cache = \%apps;
	return $lockdown_enemy_apps_cache;
}

sub lockdown_active {
	return &visibility_exposure() >= 3 ? 1 : 0;
}

sub lockdown_revealed {
	my ($device) = @_;
	$device = &device_setter() unless defined $device && length $device;
	return 0 unless $device;
	my $now = &rightNow();
	my $rows = eval {
		&db_query("select data from cache where context = 'lockdown_reveal' and device = ? order by server_time desc", $device)->hashes;
	} || [];
	foreach my $row ( @{$rows} ) {
		my $d = eval { decode_json($row->{'data'}) } || {};
		return 1 if ($d->{'until'} || 0) > $now;
	}
	return 0;
}

sub lockdown_reveal_store {
	my ($device, $until) = @_;
	$device = &device_setter() unless defined $device && length $device;
	return 0 unless $device;
	my $now = &rightNow();
	$until = $now + 120000 unless defined $until && $until > $now;
	&db_query("delete from cache where context = 'lockdown_reveal' and device = ?", $device);
	&db_insert('cache', {
		uuid => &random_string_creator(25),
		context => 'lockdown_reveal',
		app => 'security',
		device => $device,
		data => encode_json({ until => $until }),
		timestamp => $now,
		server_time => $now,
	});
	return $until;
}

sub lockdown_reveal_clear {
	my ($device) = @_;
	$device = &device_setter() unless defined $device && length $device;
	return 0 unless $device;
	&db_query("delete from cache where context = 'lockdown_reveal' and device = ?", $device);
	return 1;
}

sub lockdown_sweep {
	my ($opts) = @_;
	$opts ||= {};
	return 0 unless &lockdown_active();
	my $now = &rightNow();
	my $device = $opts->{'device'};
	$device = &device_setter() unless defined $device;
	my $tab = $opts->{'browser_tab_id'};
	my $key = ($device || '') . "\x1f" . ($tab || '');
	return 0 if !$opts->{'force'} && defined $lockdown_sweep_at{$key} && $now - $lockdown_sweep_at{$key} < 3000;
	$lockdown_sweep_at{$key} = $now;
	my $revealed = &lockdown_revealed($device);
	my $enemies = &lockdown_enemy_apps();
	&Websocket::send('server', { console => '$("#start_menu").addClass("lockdown");', browser_tab_id => $tab });
	my $rows = eval {
		&db_query("select distinct app, browser_tab_id from websockets where type = 'stayingAlive'")->hashes;
	} || [];
	foreach my $row ( @{$rows} ) {
		my $app = $row->{'app'} // next;
		my $row_tab = $row->{'browser_tab_id'} || '';
		next if defined $tab && length $tab && $row_tab ne $tab;
		next if $app =~ /^(?:server|tab|manager)\z/;
		next if $app eq 'security';
		if ($enemies->{$app}) {
			next if $revealed;
		}
		elsif (&visibility_normalize(&app_visibility_value($app)) eq 'dangerous') {
			next;
		}
		&window_closer($app, $row_tab);
	}
	return 1;
}

sub visibility_site_rating {
	my $sig = &signatorial_designer();
	my $nav = eval { &navigation_information({ signatorial => $sig, cache => 'yes' }) } || {};
	my $rating = $nav->{$sig}->{'site_rating'};
	return ($rating =~ /^\d+$/ && $rating > 0) ? $rating + 0 : 2;
}

sub visibility_exposure {
	return $visibility_exposure_cache if defined $visibility_exposure_cache;
	my $place = &visibility_site_rating();
	my $presence = &present_relationship_rating();
	$place = 3 if $presence >= 3;   # an enemy is a dangerous room
	$visibility_exposure_cache = $place;
	return $visibility_exposure_cache;
}

sub visibility_normalize {
	my ($value) = @_;
	my $v = lc($value // '');
	$v =~ s/^\s+|\s+$//g;
	return 'private' if $v eq 'private' || $v eq 'unchecked' || $v eq 'off' || $v eq 'hidden' || $v eq 'none' || $v eq 'no' || $v eq '1';
	return 'dangerous' if $v eq 'dangerous' || $v eq '3';
	return 'public';
}

sub visibility_rank {
	my ($value) = @_;
	my $v = &visibility_normalize($value);
	return 1 if $v eq 'private';
	return 3 if $v eq 'dangerous';
	return 2;
}

sub visibility_graph_build {
	return 1 if $visibility_graph_ready;
	$visibility_graph_ready = 1;
	my $device = &device_setter();
	my $rows = eval {
		&db_query("select app, value, device from settings where setting = 'visible' order by cast(server_time as integer) desc")->hashes;
	} || [];
	my (%own, %all, %me, %latest, %private);
	foreach my $row ( @{$rows} ) {
		my $app = $row->{'app'} // next;
		next unless length $app;
		my $d = $row->{'device'} // '';
		my $value = $row->{'value'};
		$private{$app} = 1 if &visibility_normalize($value) eq 'private';
		$latest{$app} = $value unless defined $latest{$app};
		$all{$app} = $value if $d eq 'all' && !defined $all{$app};
		$me{$app} = $value if $d eq 'me' && !defined $me{$app};
		$own{$app} = $value if $d eq $device && !defined $own{$app};
	}
	foreach my $app ( keys %latest ) {
		$app_visibility_own_cache{$app} = $private{$app} ? 'private'
			: &visibility_normalize(defined $own{$app} ? $own{$app}
				: defined $all{$app} ? $all{$app}
				: defined $me{$app} ? $me{$app}
				: $latest{$app});
	}
	my $links = eval {
		&db_query("select app, setting, value from settings where setting = 'uuid' or substr(setting,1,3) = 'sc_'")->hashes;
	} || [];
	my %social_sing = map { $_->{'sing'} => 1 } values %{$gb::social_constructs};
	foreach my $row ( @{$links} ) {
		my $app = $row->{'app'} // next;
		next unless length $app;
		next unless ($row->{'setting'} // '') eq 'uuid';
		my $uuid = $row->{'value'} // '';
		next unless defined $uuid && length $uuid;
		$visibility_graph_uuid_app{$uuid} = $app;
	}
	foreach my $row ( @{$links} ) {
		my $app = $row->{'app'} // next;
		next unless length $app;
		my $setting = $row->{'setting'} // '';
		next unless $setting =~ /^sc_(.+)$/;
		# Only social-construct links inherit privacy. The same sc_* arrays also
		# carry taxonomies (idea, action, product, service, thing); an ingredient
		# linked to a private idea is not part of that idea, so those are left out.
		my $sing = $1;
		next unless $social_sing{$sing};
		my $list = eval { decode_json($row->{'value'} // '') } || [];
		next unless ref $list eq 'ARRAY';
		foreach my $uuid ( @{$list} ) {
			next unless defined $uuid && length $uuid;
			my $related = $visibility_graph_uuid_app{$uuid} // next;
			next if $related eq $app;
			$visibility_graph_links{$app}->{$related} = 1;
		}
	}
	return 1;
}

sub app_visibility_own_value {
	my ($app) = @_;
	return 'public' unless defined $app && length $app;
	&visibility_graph_build();
	return $app_visibility_own_cache{$app} || 'public';
}

sub app_visibility_rank_effective {
	my ($app, $seen) = @_;
	return 4 unless defined $app && length $app;
	&visibility_graph_build();
	my $device = &device_setter();
	my $cache_key = $device . "\x1f" . $app;
	return $app_visibility_rank_cache{$cache_key} if exists $app_visibility_rank_cache{$cache_key};
	my $root = !defined $seen;
	$seen ||= {};
	return 4 if $seen->{$app}++;
	my $rank = &visibility_rank(&app_visibility_own_value($app));
	my $links = $visibility_graph_links{$app} || {};
	foreach my $related ( keys %{$links} ) {
		my $r = &app_visibility_rank_effective($related, $seen);
		$rank = $r if $r < $rank;
	}
	$app_visibility_rank_cache{$cache_key} = $rank if $root;
	return $rank;
}

sub app_visibility_value {
	my ($app) = @_;
	return 'public' unless defined $app && length $app;
	my $device = &device_setter();
	my $cache_key = $device . "\x1f" . $app;
	return $app_visibility_cache{$cache_key} if exists $app_visibility_cache{$cache_key};
	my $rank = &app_visibility_rank_effective($app);
	my $value = $rank <= 1 ? 'private' : $rank >= 3 ? 'dangerous' : 'public';
	$app_visibility_cache{$cache_key} = $value;
	return $value;
}

sub app_visibility_preload {
	my ($apps) = @_;
	return 0 unless ref $apps eq 'ARRAY' && scalar @{$apps};
	&visibility_graph_build();
	my $seen = 0;
	foreach my $app ( @{$apps} ) {
		next unless defined $app && length $app;
		&app_visibility_value($app);
		$seen++;
	}
	return $seen ? 1 : 0;
}

1;
