package Manager;

# manager_weather: the Weather app. The page is a shell; the browser asks
# /manager/weather/data for one coordinate, and the server answers from the
# national service of that country (Environment Canada, NWS) or Open-Meteo.
# The coordinate comes from the house's own GPS fixes in `continent`, so a
# phone in another town gets that town's weather, not a fixed city page.
use strict;
use warnings;
use utf8;

our $log;

# GET /manager/weather
sub action_52010 {
	my $c = shift;
	my $me = &subs::signatorial_designer();
	my $fixes = eval { &subs::weather_device_fixes(24 * 60 * 60 * 1000) } || [];
	my ($me_fix) = grep { ($_->{'signatorial'} || '') eq $me } @{$fixes};
	my @others = grep { ($_->{'signatorial'} || '') ne $me } @{$fixes};
	my $default = $me_fix ? 'me' : (@others ? $others[0]->{'signatorial'} : 'me');
	my $locations = eval { &subs::weather_locations() } || [];
	my $content = $c->render_to_string(
		template => 'apps/weather',
		me_fix => $me_fix,
		devices => \@others,
		locations => $locations,
		default_device => $default,
	);
	my $contents = &window_maker({
		user_agent => $c->param('user_agent'),
		app => 'weather',
		title => &subs::ui('Weather'),
		contents => $content,
	}, $c->param('timestamp'));
	$c->render(text => $contents);
}

# GET /manager/weather/data
sub action_52011 {
	my $c = shift;
	my $device = $c->param('device') || 'me';
	my $lat = $c->param('lat');
	my $lon = $c->param('lon');
	my $fixes = eval { &subs::weather_device_fixes(24 * 60 * 60 * 1000) } || [];
	my ($use_lat, $use_lon, $label, $seen_at, $location_key);
	my $browser = defined $lat && defined $lon
		&& $lat =~ /^-?\d+(?:\.\d+)?$/ && $lon =~ /^-?\d+(?:\.\d+)?$/
		&& $lat >= -90 && $lat <= 90 && $lon >= -180 && $lon <= 180;
	if ($browser) {
		$use_lat = 0 + $lat;
		$use_lon = 0 + $lon;
		$label = $c->param('source') || &subs::ui('Browser location');
		$seen_at = &subs::rightNow();
		$location_key = 'browser';
	}
	elsif ($device =~ /^loc:([A-Za-z0-9_-]+)$/) {
		my $saved = eval { &subs::weather_location_find($1) };
		unless ($saved) {
			$log->warn("weather data: saved location $device is gone") if $log;
			$c->render(json => {
				error => &subs::ui('That saved location is gone.'),
				devices => $fixes,
			});
			return;
		}
		$use_lat = $saved->{'lat'};
		$use_lon = $saved->{'lon'};
		$label = $saved->{'name'};
		$seen_at = &subs::rightNow();
		$location_key = $device;
	}
	else {
		my $sig = $device eq 'me' ? &subs::signatorial_designer() : $device;
		my $fix = eval { &subs::weather_device_fix($sig) };
		my ($known) = grep { ($_->{'signatorial'} || '') eq $sig } @{$fixes};
		unless ($fix) {
			$log->warn("weather data: no recent GPS fix for $device ($sig)") if $log;
			$c->render(json => {
				error => &subs::ui('No recent GPS fix for this device.'),
				devices => $fixes,
			});
			return;
		}
		$use_lat = $fix->{'lat'};
		$use_lon = $fix->{'lon'};
		$label = $device eq 'me'
			? &subs::ui('This device')
			: (($known && $known->{'label'}) || $device);
		$seen_at = $fix->{'seen'};
		$location_key = 'dev:' . $sig;
	}
	my $weather = eval { &subs::weather_fetch($use_lat, $use_lon, { force => ($c->param('force') ? 1 : 0) }) };
	unless ($weather && ref $weather eq 'HASH' && !$weather->{'error'}) {
		my $why = (ref $weather eq 'HASH' && $weather->{'error'}) || &subs::ui('Weather is unavailable right now.');
		$log->warn("weather data: fetch for $location_key at $use_lat,$use_lon failed: $why") if $log;
		$c->render(json => {
			error => $why,
			devices => $fixes,
		});
		return;
	}
	$weather->{'source'} = $label;
	$weather->{'source_at'} = $seen_at;
	$weather->{'source_device'} = $device;
	$weather->{'source_location'} = $location_key;
	# The condition the person is looking at is the one the house acts on.
	# The write is throttled and the rules run through appt_measure_writer.
	eval { &subs::weather_observe_record($weather, { location => $location_key }) };
	$c->render(json => $weather);
}

# GET /manager/weather/history
sub action_52012 {
	my $c = shift;
	my $result = eval { &subs::weather_history_read({
		source => $c->param('source') || '',
		range => $c->param('range') || '30',
		city => $c->param('city') || '',
		region => $c->param('region') || '',
		force => ($c->param('force') ? 1 : 0),
	}) };
	$c->render(json => $result || { error => &subs::ui('History is unavailable.') });
}

# POST /manager/weather/backfill
sub action_52013 {
	my $c = shift;
	my $result = eval { &subs::weather_history_build({ force => 1 }) };
	unless ($result) {
		$c->render(json => { ok => 0, error => &subs::ui('The backfill failed.') });
		return;
	}
	$c->render(json => {
		ok => 1,
		built_at => $result->{'built_at'},
		sources => $result->{'sources'} || [],
	});
}

# GET /manager/weather/accuracy
sub action_52014 {
	my $c = shift;
	my $result = eval { &subs::weather_accuracy_build({
		source => $c->param('source') || '',
		range => $c->param('range') || '30',
		city => $c->param('city') || '',
		region => $c->param('region') || '',
		lat => $c->param('lat'),
		lon => $c->param('lon'),
	}) };
	$c->render(json => $result || { error => &subs::ui('Accuracy is unavailable.') });
}

# GET /manager/weather/automations
sub action_52015 {
	my $c = shift;
	my $state = eval { &subs::weather_automation_state() };
	$c->render(json => $state || { error => &subs::ui('Automations are unavailable.') });
}

# POST /manager/weather/automation
sub action_52016 {
	my $c = shift;
	my $result = eval { &subs::weather_automation_save({
		uuid => $c->param('uuid') || '',
		match => $c->param('match') || '',
		app => $c->param('app') || '',
		action => $c->param('action') || 'start',
		location => $c->param('location') || '',
		remove => ($c->param('remove') ? 1 : 0),
	}) };
	$c->render(json => $result || { error => &subs::ui('The automation was not saved.') });
}

# POST /manager/weather/observe
sub action_52017 {
	my $c = shift;
	my $lat = $c->param('lat');
	my $lon = $c->param('lon');
	my $opts = { force => 1, location => ($c->param('location') || '') };
	if (defined $lat && defined $lon
		&& $lat =~ /^-?\d+(?:\.\d+)?$/ && $lon =~ /^-?\d+(?:\.\d+)?$/
		&& $lat >= -90 && $lat <= 90 && $lon >= -180 && $lon <= 180) {
		$opts->{'lat'} = 0 + $lat;
		$opts->{'lon'} = 0 + $lon;
	}
	my $result = eval { &subs::weather_observe_now($opts) };
	$c->render(json => $result || { error => &subs::ui('The weather could not be checked.') });
}

# POST /manager/weather/location
sub action_52018 {
	my $c = shift;
	my $saved = eval {
		&subs::weather_location_save($c->param('name'), $c->param('lat'), $c->param('lon'));
	};
	$c->render(json => $saved || { error => &subs::ui('The location was not saved.') });
}

# POST /manager/weather/measure_rule
sub action_52019 {
	my $c = shift;
	my $conditions = eval { decode_json($c->param('when') // '[]') } || [];
	my $result = eval {
		&subs::weather_measure_rule_save({
			uuid => $c->param('uuid') || '',
			name => $c->param('name') || '',
			when => $conditions,
			for_ms => $c->param('for_ms') || 0,
			action => $c->param('action') || 'start',
			app => $c->param('app') || '',
			command => $c->param('command') || '',
			location => $c->param('location') || '',
			remove => ($c->param('remove') ? 1 : 0),
		});
	};
	$c->render(json => $result || { error => &subs::ui('The measurement rule was not saved.') });
}


1;
