package subs;

# WeatherHistory: the Weather app's past. The old `weather` web-measure app
# kept 4,600+ readings in the appointment's `measures` JSON; this module folds
# them into one row per day, records the current app's forecast snapshots, and
# compares a forecast made 1-7 days before a date with what the house actually
# measured.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Mojo::JSON qw(decode_json encode_json);
use Mojo::UserAgent;
use Time::Piece;

our $device;
our $log;

# ---- place names for the old sources ---------------------------------------
sub weather_history_place($id) {
	return { name => '', region => '' } unless defined $id && $id =~ /^[A-Za-z0-9_-]+$/;
	my $cached = eval { &cache_get({ app => 'weather', context => 'source_place', subcontext => $id }) };
	return $cached if ref $cached eq 'HASH' && (defined $cached->{'name'} || defined $cached->{'region'});
	my $ua = Mojo::UserAgent->new(connect_timeout => 4, inactivity_timeout => 6, request_timeout => 10);
	my ($json) = eval { &weather_http_get("https://api.weather.gc.ca/collections/citypageweather-realtime/items/$id?f=json", $ua) };
	my $out = {
		name => $json ? &weather_text($json->{'properties'}->{'name'}) : '',
		region => $json ? &weather_text($json->{'properties'}->{'region'}) : '',
	};
	eval { &cache_set({ app => 'weather', context => 'source_place', subcontext => $id, warranty => '-30d' }, $out) };
	return $out;
}

# A history source reads as the place it is about: "Warwick Weather",
# "Charlottetown Weather". A saved place keeps the name the person gave it; a
# device's place comes from the provider's answer, kept by the observer.
sub weather_history_station_place($location = '', $last = {}) {
	$last ||= {};
	my $key = $location // '';
	if (length $key && (($last->{'location'} // '') eq $key) && length($last->{'place'} // '')) {
		return $last->{'place'};
	}
	if ($key =~ /^loc:(.+)$/) {
		my $loc = eval { &weather_location_find($1) };
		if ($loc) {
			my $name = $loc->{'name'} // '';
			return $name if length $name && !(eval { &weather_name_is_coordinate($name) });
			my $place = eval { &weather_place_name($loc->{'lat'}, $loc->{'lon'}) } || '';
			return $place if length $place;
		}
	}
	elsif ($key =~ /^dev:(.+)$/) {
		my $fix = eval { &weather_device_fix($1) };
		if ($fix) {
			my $place = eval { &weather_place_name($fix->{'lat'}, $fix->{'lon'}) } || '';
			return $place if length $place;
		}
	}
	return ($last->{'place'} // '') unless length $key;
	return '';
}

# The old apps carry a configured display name (notification_text). When it is
# still the generic app name, the provider's city is the better place; when the
# person named it (Warwick Weather), that name wins. Either way the suffix is
# Weather, so the source list reads as places, not internal app keys.
sub weather_history_source_label($app, $meta = {}, $station_place = '') {
	$meta ||= {};
	my $name = '';
	if (($app // '') eq 'weather_station') {
		$name = $station_place // '';
	}
	else {
		# The source's name is a house fact, not a per-machine one: ask for the
		# newest notification_text any machine has stored for the app.
		my $configured = '';
		my $row = eval {
			&db_query(
				"select value from settings where app = ? and setting = 'notification_text' "
				. "and value is not null and value != '' order by cast(server_time as integer) desc limit 1",
				$app
			)->hashes->[0];
		};
		$configured = $row ? ($row->{'value'} // '') : '';
		$configured =~ s/^\s+|\s+$//g;
		my $default = eval { &format_name($app) } || '';
		$configured = '' if lc($configured) eq lc($default);
		$name = length $configured ? $configured : ($meta->{'city'} // '');
	}
	$name =~ s/^\s+|\s+$//g;
	return (eval { &ui('Weather station') } || 'Weather station') unless length $name;
	return $name if $name =~ /(?:\bWeather)\s*$/i;
	my $weather_word = eval { &ui('Weather') } || 'Weather';
	return $name . ' ' . $weather_word;
}

sub weather_history_sources($station_location = '') {
	my $rows = eval {
		&db_query("select app, value from settings where app in ('weather', 'cambridge_weather') and setting = 'web' order by app")->hashes;
	} || [];
	my @sources;
	foreach my $r (@{$rows}) {
		my $app = $r->{'app'} || '';
		next unless length $app;
		my $url = $r->{'value'} || '';
		my ($id) = $url =~ m{/items/([^/?]+)};
		my $place = $id ? &weather_history_place($id) : { name => '', region => '' };
		my $counts = eval {
			&db_query(
				'select count(*) as n, min(timestamp) as from_ts, max(timestamp) as to_ts '
				. 'from appointments where app = ? and measures is not null',
				$app
			)->hashes->[0];
		} || {};
		push @sources, {
			app => $app,
			label => &weather_history_source_label($app, { city => ($place->{'name'} || ''), region => ($place->{'region'} || '') }, ''),
			city => $place->{'name'} || '',
			region => $place->{'region'} || '',
			url => $url,
			id => $id || '',
			readings => $counts->{'n'} || 0,
			show_city => 0,
			from => &weather_day_key($counts->{'from_ts'}),
			to => &weather_day_key($counts->{'to_ts'}),
		};
	}
	# The app's own station readings are the ground the person is on now, so they
	# come first: a one-day hourly view and the accuracy comparison both want the
	# nearest source, and the two old pages stay selectable below it.
	my $station = eval {
		&db_query(
			"select count(*) as n, min(timestamp) as from_ts, max(timestamp) as to_ts "
			. "from appointments where app = 'weather_station' and measures is not null"
		)->hashes->[0];
	} || {};
	if (($station->{'n'} || 0) > 0) {
		my $last = eval { &cache_get({ app => 'weather', context => 'observe', subcontext => 'last' }) } || {};
		my $place = &weather_history_station_place($station_location, $last);
		unshift @sources, {
			app => 'weather_station',
			label => &weather_history_source_label('weather_station', {}, $place),
			city => $place,
			region => '',
			url => '',
			id => '',
			location => ($last->{'location'} // ''),
			readings => $station->{'n'} || 0,
			show_city => 0,
			from => &weather_day_key($station->{'from_ts'}),
			to => &weather_day_key($station->{'to_ts'}),
		};
	}
	return \@sources;
}

# ---- the old measures -> one row per day -----------------------------------
# The old app logged whatever the page said: "Mainly Sunny" from a Canadian
# page, "a_few_clouds" from an Open-Meteo-style one. The underscores are a
# machine token, not words, so show them as words.
sub weather_history_condition_text($value) {
	my $t = &weather_text($value);
	$t =~ tr/_/ /;
	$t =~ s/\s+/ /g;
	$t =~ s/^\.+|\.+$//g;
	$t =~ s/^\s+|\s+$//g;
	# The two pages wrote the same sky differently ("Clear" from one, "clear"
	# from the other); one spelling keeps a day's condition count whole.
	return length $t ? ucfirst lc $t : '';
}

# Visibility came from the same pages, so it is sometimes "24", sometimes
# "24 km" and sometimes a runaway scrape ("C", "km", a whole paragraph). Keep
# only what reads as a distance.
sub weather_history_visibility_text($value) {
	my $t = &weather_text($value);
	$t =~ s/\s+/ /g;
	$t =~ s/^\s+|\s+$//g;
	return '' unless $t =~ /^(\d+(?:\.\d+)?)\s*(?:km)?$/i;
	return "$1 km";
}

sub weather_history_top_text($counts) {
	return '' unless ref $counts eq 'HASH' && %{$counts};
	my ($best) = sort { $counts->{$b} <=> $counts->{$a} || $a cmp $b } keys %{$counts};
	return $best // '';
}

sub weather_history_aggregate($rows, $opts = {}) {
	$opts ||= {};
	my $want_location = $opts->{'location'} // '';
	my $location_app = $opts->{'location_app'} // 'weather_station';
	my (%days, %seen, %sources);
	foreach my $row (@{ ref $rows eq 'ARRAY' ? $rows : [] }) {
		next unless ref $row eq 'HASH';
		my $app = $row->{'app'} || '';
		next unless length $app;
		my $measures = ref $row->{'measures'} eq 'ARRAY'
			? $row->{'measures'}
			: eval { decode_json($row->{'measures'} // '[]') };
		next unless ref $measures eq 'ARRAY';
		my $base_ts = $row->{'timestamp'};
		$sources{$app} ||= { app => $app, readings => 0, days => {} };
		foreach my $m (@{$measures}) {
			next unless ref $m eq 'HASH';
			# A reading with no location predates per-location observations: keep it
			# (the house's history) instead of hiding it behind the newest fix.
			next if $want_location && $app eq $location_app
				&& length($m->{'location'} // '') && ($m->{'location'} // '') ne $want_location;
			my $ts = $m->{'ts'} || $base_ts;
			my $day = &weather_day_key($ts);
			next unless length $day;
			# The old app wrote one reading per entry with the measure name as
			# the key - {"temperature":"-4","ts":"...","uuid":"..."} - so `ts`
			# and `uuid` ride along and every other key is a reading.
			foreach my $field (sort keys %{$m}) {
				next if $field eq 'ts' || $field eq 'uuid' || $field eq 'location';
				my $name = lc $field;
				my $value = $m->{$field};
				next if ref $value || !defined $value || !length "$value";
				# The same reading can be written by more than one machine; a
				# ten-minute bucket plus the value keeps the day's extremes
				# honest without counting one reading twice.
				my $dedupe = join('|', $app, $name, int($ts / 600000), lc($value));
				next if $seen{$dedupe}++;
				my $dkey = $app . '|' . $day;
				my $d = $days{$dkey} ||= {
					source => $app, date => $day, temps => [], conditions => {},
					humidity_sum => 0, humidity_n => 0, wind_sum => 0, wind_n => 0,
					wind_directions => {}, visibility => '', readings => 0,
				};
				$d->{'readings'}++;
				$sources{$app}{'readings'}++;
				if ($name eq 'temperature') {
					my $n = &weather_number($value);
					push @{$d->{'temps'}}, $n if defined $n;
				}
				elsif ($name eq 'condition') {
					my $t = &weather_history_condition_text($value);
					$d->{'conditions'}{$t}++ if length $t;
				}
				elsif ($name eq 'humidity') {
					my $n = &weather_number($value);
					if (defined $n) { $d->{'humidity_sum'} += $n; $d->{'humidity_n'}++; }
				}
				elsif ($name eq 'speed' || $name eq 'wind') {
					# The old app wrote "calm" on still days.
					my $n = lc("$value") eq 'calm' ? 0 : &weather_number($value);
					if (defined $n) { $d->{'wind_sum'} += $n; $d->{'wind_n'}++; }
				}
				elsif ($name eq 'wind_direction') {
					my $t = uc(&weather_text($value));
					$d->{'wind_directions'}{$t}++ if $t =~ /^[A-Z]{1,3}$/;
				}
				elsif ($name eq 'visibility') {
					my $t = &weather_history_visibility_text($value);
					$d->{'visibility'} = $t if length $t;
				}
			}
		}
	}
	my @out;
	foreach my $key (keys %days) {
		my $d = $days{$key};
		my @temps = sort { $a <=> $b } @{$d->{'temps'}};
		my ($high, $low, $mean);
		if (@temps) {
			$high = $temps[-1];
			$low = $temps[0];
			my $sum = 0;
			$sum += $_ for @temps;
			$mean = $sum / scalar @temps;
		}
		my @conditions = sort {
			$d->{'conditions'}{$b} <=> $d->{'conditions'}{$a} || $a cmp $b
		} keys %{$d->{'conditions'}};
		my $top = @conditions > 3 ? 3 : scalar @conditions;
		push @out, {
			source => $d->{'source'},
			date => $d->{'date'},
			high => $high,
			low => $low,
			mean => $mean,
			count => scalar @temps,
			condition => @conditions ? $conditions[0] : '',
			conditions => [ map { { text => $_, count => $d->{'conditions'}{$_} } } @conditions[0 .. $top - 1] ],
			humidity_forecast => $d->{'humidity_n'} ? $d->{'humidity_sum'} / $d->{'humidity_n'} : undef,
			wind => $d->{'wind_n'} ? $d->{'wind_sum'} / $d->{'wind_n'} : undef,
			wind_direction => &weather_history_top_text($d->{'wind_directions'}),
			visibility => $d->{'visibility'},
			readings => $d->{'readings'},
		};
		$sources{$d->{'source'}}{'days'}{$d->{'date'}} = 1;
	}
	@out = sort { $a->{'source'} cmp $b->{'source'} || $a->{'date'} cmp $b->{'date'} } @out;
	foreach my $app (keys %sources) {
		my @ds = sort keys %{$sources{$app}{'days'}};
		$sources{$app}{'from'} = $ds[0] // '';
		$sources{$app}{'to'} = $ds[-1] // '';
		$sources{$app}{'day_count'} = scalar @ds;
		delete $sources{$app}{'days'};
	}
	return { days => \@out, sources => \%sources };
}

sub weather_history_build($opts) {
	$opts ||= {};
	my $station_location = $opts->{'location'} // '';
	my $meta_list = &weather_history_sources($station_location);
	my @apps = @{$meta_list} ? map { $_->{'app'} } @{$meta_list} : qw(weather cambridge_weather);
	my @rows;
	foreach my $app (@apps) {
		my $r = eval {
			&db_query(
				'select app, device, timestamp, measures from appointments '
				. 'where app = ? and measures is not null order by cast(timestamp as integer) asc',
				$app
			)->hashes;
		} || [];
		push @rows, @{$r};
	}
	my $agg = &weather_history_aggregate(\@rows, { location => $station_location });
	my %meta = map { ($_->{'app'} || '') => $_ } @{$meta_list};
	my @sources;
	foreach my $app (@apps) {
		my $m = $meta{$app} || { app => $app, label => $app, city => '', region => '' };
		my $s = $agg->{'sources'}->{$app} || {};
		push @sources, {
			app => $app,
			label => $m->{'label'},
			city => $m->{'city'} || '',
			region => $m->{'region'} || '',
			url => $m->{'url'} || '',
			id => $m->{'id'} || '',
			location => $m->{'location'} || '',
			readings => $s->{'readings'} || $m->{'readings'} || 0,
			days => $s->{'day_count'} || 0,
			from => $s->{'from'} || $m->{'from'} || '',
			to => $s->{'to'} || $m->{'to'} || '',
		};
	}
	my %by_source;
	foreach my $d (@{$agg->{'days'}}) {
		push @{$by_source{$d->{'source'}}}, $d;
	}
	my $out = {
		built_at => &rightNow(),
		sources => \@sources,
		days => \%by_source,
		note => &subs::ui('History comes from the old weather appointments and the app\'s own readings. Temperature and condition are observations; humidity is the forecast value the old app logged, not an observation. High and low are the extremes of the readings the house kept, so they are sampled rather than a station daily extreme.'),
	};
	eval { &cache_set({ app => 'weather', context => 'history', subcontext => &weather_history_cache_key($station_location), warranty => '-1d' }, $out) };
	return $out;
}

sub weather_history_cache_key($station_location) {
	my $suffix = $station_location // '';
	$suffix =~ s/[^A-Za-z0-9_-]//g;
	# v4: sources are named for their place, so a v3 entry would keep the old
	# "Weather station" label until it expired.
	return 'v4' . (length $suffix ? '_' . $suffix : '');
}

# A one-day read is hourly, not daily: the last 24 hours of one source's
# temperature, averaged into the hour it was taken in. The old apps logged one
# reading an hour (Cambridge every three), and the Weather station every half
# hour, so the strip has more points on the source the house owns.
sub weather_history_hourly($app, $hours, $location = '') {
	$hours ||= 24;
	my $want_location = $location // '';
	my $now = &rightNow();
	my $from = $now - $hours * 3600000;
	my $rows = eval {
		&db_query(
			'select timestamp, measures from appointments '
			. 'where app = ? and measures is not null and cast(timestamp as integer) >= ? '
			. 'order by cast(timestamp as integer) asc',
			$app, $from
		)->hashes;
	} || [];
	my %bucket;
	foreach my $row (@{$rows}) {
		my $base = $row->{'timestamp'};
		my $list = eval { decode_json($row->{'measures'} // '[]') } || [];
		next unless ref $list eq 'ARRAY';
		foreach my $measure (@{$list}) {
			next unless ref $measure eq 'HASH';
			next if $want_location && $app eq 'weather_station'
				&& length($measure->{'location'} // '') && ($measure->{'location'} // '') ne $want_location;
			my $ts = $measure->{'ts'} || $base;
			next unless defined $ts && "$ts" =~ /^\d+$/ && $ts >= $from;
			my $hour = int($ts / 3600000) * 3600000;
			$bucket{$hour}{'ts'} = $hour;
			if (defined $measure->{'temperature'}) {
				my $n = &weather_number($measure->{'temperature'});
				push @{ $bucket{$hour}{'temps'} }, $n if defined $n;
			}
			if (defined $measure->{'condition'}) {
				my $text = &weather_history_condition_text($measure->{'condition'});
				$bucket{$hour}{'conditions'}{$text}++ if length $text;
			}
		}
	}
	my @out;
	foreach my $hour (sort { $a <=> $b } keys %bucket) {
		my $b = $bucket{$hour};
		my @temps = @{ $b->{'temps'} || [] };
		my $temperature;
		if (@temps) {
			my $sum = 0;
			$sum += $_ for @temps;
			$temperature = $sum / scalar @temps;
		}
		push @out, {
			ts => $hour,
			temperature => $temperature,
			condition => &weather_history_top_text($b->{'conditions'} || {}),
			readings => scalar @temps,
		};
	}
	return \@out;
}

sub weather_history_pick_source($sources, $city, $region) {
	return '' unless ref $sources eq 'ARRAY' && @{$sources};
	my $want = lc(join(' ', $city // '', $region // ''));
	my @tokens = grep { length($_) > 3 } split /\W+/, $want;
	if (@tokens) {
		foreach my $s (@{$sources}) {
			my $blob = lc(join(' ', $s->{'city'} // '', $s->{'region'} // ''));
			next unless length $blob;
			foreach my $token (@tokens) {
				return $s->{'app'} if index($blob, $token) >= 0;
			}
		}
	}
	my ($best) = sort { ($b->{'readings'} || 0) <=> ($a->{'readings'} || 0) } @{$sources};
	return $best ? $best->{'app'} : '';
}

sub weather_history_read($opts) {
	$opts ||= {};
	my $last = eval { &cache_get({ app => 'weather', context => 'observe', subcontext => 'last' }) } || {};
	my $station_location = $last->{'location'} // '';
	my $cache_key = &weather_history_cache_key($station_location);
	my $history = eval { &cache_get({ app => 'weather', context => 'history', subcontext => $cache_key }) };
	if (!$history || ref $history ne 'HASH' || !$history->{'built_at'}
		|| $opts->{'force'} || $history->{'built_at'} < &rightNow() - 6 * 60 * 60 * 1000) {
		$history = &weather_history_build({ %{$opts}, location => $station_location });
	}
	my $source = $opts->{'source'} || &weather_history_pick_source($history->{'sources'}, $opts->{'city'}, $opts->{'region'});
	my @days = @{ $history->{'days'}->{$source} || [] };
	my $range = $opts->{'range'} || '30';
	if ($range =~ /^\d+$/ && $range > 0) {
		my $from = &weather_day_key(&rightNow() - $range * 86400000);
		@days = grep { ($_->{'date'} // '') ge $from } @days;
	}
	my $hours = ($range eq '1')
		? &weather_history_hourly($source, 24, $source eq 'weather_station' ? $station_location : '')
		: undef;
	my ($source_meta) = grep { ($_->{'app'} || '') eq $source } @{ $history->{'sources'} || [] };
	return {
		built_at => $history->{'built_at'},
		sources => $history->{'sources'} || [],
		source => $source,
		source_label => $source_meta ? $source_meta->{'label'} : $source,
		source_city => $source_meta ? ($source_meta->{'city'} || '') : '',
		source_region => $source_meta ? ($source_meta->{'region'} || '') : '',
		source_location => $source eq 'weather_station' ? $station_location : '',
		days => \@days,
		(defined $hours ? (hours => $hours) : ()),
		from => @days ? $days[0]->{'date'} : '',
		to => @days ? $days[-1]->{'date'} : '',
		note => $history->{'note'} || '',
	};
}

# ---- forecast snapshots -----------------------------------------------------
sub weather_forecast_snapshot_save($weather, $lat, $lon) {
	return unless ref $weather eq 'HASH' && defined $lat && defined $lon;
	my $key = sprintf('%.2f_%.2f', $lat, $lon);
	my $history = eval { &cache_get({ app => 'weather', context => 'forecast_history', subcontext => $key }) } || {};
	my $now = &rightNow();
	my $today = &weather_day_key($now);
	foreach my $d (@{ $weather->{'daily'} || [] }) {
		next unless ref $d eq 'HASH';
		my $date = $d->{'date'} // '';
		next unless $date =~ /^\d{4}-\d{2}-\d{2}$/;
		my $lead = &weather_days_between($today, $date);
		next unless defined $lead && $lead >= 1 && $lead <= 7;
		$history->{$date}{$lead} = {
			fetched_at => $now,
			high => $d->{'high'},
			low => $d->{'low'},
			condition => $d->{'condition'} // '',
			precip_prob => $d->{'precip_prob'},
			provider => $weather->{'provider'} // '',
		};
	}
	my $cutoff = &weather_day_key($now - 14 * 86400000);
	foreach my $date (keys %{$history}) {
		delete $history->{$date} if $date lt $cutoff;
	}
	eval { &cache_set({ app => 'weather', context => 'forecast_history', subcontext => $key, warranty => '-30d' }, $history) };
	return $history;
}

sub weather_forecast_snapshots_read($lat, $lon) {
	return {} unless defined $lat && defined $lon;
	my $history = eval {
		&cache_get({ app => 'weather', context => 'forecast_history', subcontext => sprintf('%.2f_%.2f', $lat, $lon) });
	};
	return ref $history eq 'HASH' ? $history : {};
}

# ---- forecast against what happened ----------------------------------------
sub weather_accuracy_summary($actuals, $snapshots) {
	my %acc;
	my @detail;
	foreach my $a (@{ ref $actuals eq 'ARRAY' ? $actuals : [] }) {
		next unless ref $a eq 'HASH' && ($a->{'date'} // '') =~ /^\d{4}-\d{2}-\d{2}$/;
		my $row = {
			date => $a->{'date'},
			actual => {
				high => $a->{'high'},
				low => $a->{'low'},
				condition => $a->{'condition'} // '',
			},
			forecasts => {},
		};
		foreach my $lead (1 .. 7) {
			my $s = $snapshots->{$a->{'date'}}{$lead};
			next unless ref $s eq 'HASH';
			my $high_error = (defined $s->{'high'} && defined $a->{'high'}) ? $s->{'high'} - $a->{'high'} : undef;
			my $low_error = (defined $s->{'low'} && defined $a->{'low'}) ? $s->{'low'} - $a->{'low'} : undef;
			my $match;
			if (length($s->{'condition'} // '') && length($a->{'condition'} // '')) {
				$match = &weather_condition_class($s->{'condition'}) eq &weather_condition_class($a->{'condition'}) ? 1 : 0;
			}
			$row->{'forecasts'}{$lead} = {
				high => $s->{'high'},
				low => $s->{'low'},
				condition => $s->{'condition'} // '',
				high_error => $high_error,
				low_error => $low_error,
				condition_match => $match,
				fetched_at => $s->{'fetched_at'},
			};
			my $x = $acc{$lead} ||= { n => 0, nl => 0, ah => 0, al => 0, cm => 0, cn => 0 };
			if (defined $high_error) { $x->{'n'}++; $x->{'ah'} += abs($high_error); }
			if (defined $low_error) { $x->{'nl'}++; $x->{'al'} += abs($low_error); }
			if (defined $match) { $x->{'cn'}++; $x->{'cm'} += $match; }
		}
		push @detail, $row if scalar keys %{$row->{'forecasts'}};
	}
	my @summary;
	foreach my $lead (1 .. 7) {
		my $x = $acc{$lead} || { n => 0, nl => 0, ah => 0, al => 0, cm => 0, cn => 0 };
		push @summary, {
			lead => $lead,
			count => $x->{'n'},
			mae_high => $x->{'n'} ? $x->{'ah'} / $x->{'n'} : undef,
			mae_low => $x->{'nl'} ? $x->{'al'} / $x->{'nl'} : undef,
			condition_match => $x->{'cn'} ? 100 * $x->{'cm'} / $x->{'cn'} : undef,
			condition_count => $x->{'cn'},
		};
	}
	return {
		summary => \@summary,
		detail => \@detail,
		actuals => scalar @{ ref $actuals eq 'ARRAY' ? $actuals : [] },
		forecast_days => scalar @detail,
	};
}

sub weather_accuracy_build($opts) {
	$opts ||= {};
	my $lat = &weather_number($opts->{'lat'});
	my $lon = &weather_number($opts->{'lon'});
	return { error => &subs::ui('Load the current weather first so the forecast location is known.') }
		unless defined $lat && defined $lon;
	my $history = &weather_history_read({
		source => $opts->{'source'},
		range => $opts->{'range'} || '30',
		city => $opts->{'city'},
		region => $opts->{'region'},
		force => $opts->{'force'},
	});
	my $snapshots = &weather_forecast_snapshots_read($lat, $lon);
	my $summary = &weather_accuracy_summary($history->{'days'}, $snapshots);
	my $source_city = $history->{'source_city'} || '';
	my $source_region = $history->{'source_region'} || '';
	my $different = 0;
	if (length $source_city || length $source_region) {
		my $blob = lc(join(' ', $source_city, $source_region));
		my $want = lc(join(' ', $opts->{'city'} // '', $opts->{'region'} // ''));
		my $match = 0;
		foreach my $token (grep { length($_) > 3 } split /\W+/, $want) {
			$match = 1 if index($blob, $token) >= 0;
		}
		$different = 1 unless $match;
	}
	return {
		%{$summary},
		sources => $history->{'sources'} || [],
		source => $history->{'source'},
		source_label => $history->{'source_label'},
		source_city => $source_city,
		source_region => $source_region,
		forecast_city => $opts->{'city'} // '',
		forecast_region => $opts->{'region'} // '',
		different_city => $different,
		note => $history->{'note'},
	};
}

1;
