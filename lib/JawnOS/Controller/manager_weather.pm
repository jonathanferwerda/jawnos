package Manager;

# manager_weather: the Weather app. The page is a shell; the browser asks
# /manager/weather/data for one coordinate, and the server answers from the
# national service of that country (Environment Canada, NWS) or Open-Meteo.
# The coordinate comes from the house's own GPS fixes in `continent`, so a
# phone in another town gets that town's weather, not a fixed city page.
use strict;
use warnings;
use utf8;

# GET /manager/weather
sub action_52010 {
	my $c = shift;
	my $me = &subs::signatorial_designer();
	my $fixes = eval { &subs::weather_device_fixes(24 * 60 * 60 * 1000) } || [];
	my ($me_fix) = grep { ($_->{'signatorial'} || '') eq $me } @{$fixes};
	my @others = grep { ($_->{'signatorial'} || '') ne $me } @{$fixes};
	my $default = $me_fix ? 'me' : (@others ? $others[0]->{'signatorial'} : 'me');
	my $content = $c->render_to_string(
		template => 'apps/weather',
		me_fix => $me_fix,
		devices => \@others,
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
	my ($use_lat, $use_lon, $label, $seen_at);
	my $browser = defined $lat && defined $lon
		&& $lat =~ /^-?\d+(?:\.\d+)?$/ && $lon =~ /^-?\d+(?:\.\d+)?$/
		&& $lat >= -90 && $lat <= 90 && $lon >= -180 && $lon <= 180;
	if ($browser) {
		$use_lat = 0 + $lat;
		$use_lon = 0 + $lon;
		$label = $c->param('source') || &subs::ui('Browser location');
		$seen_at = &subs::rightNow();
	}
	else {
		my $sig = $device eq 'me' ? &subs::signatorial_designer() : $device;
		my $fix = eval { &subs::weather_device_fix($sig) };
		my ($known) = grep { ($_->{'signatorial'} || '') eq $sig } @{$fixes};
		unless ($fix) {
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
	}
	my $weather = eval { &subs::weather_fetch($use_lat, $use_lon, { force => ($c->param('force') ? 1 : 0) }) };
	unless ($weather && ref $weather eq 'HASH' && !$weather->{'error'}) {
		$c->render(json => {
			error => (ref $weather eq 'HASH' && $weather->{'error'}) || &subs::ui('Weather is unavailable right now.'),
			devices => $fixes,
		});
		return;
	}
	$weather->{'source'} = $label;
	$weather->{'source_at'} = $seen_at;
	$weather->{'source_device'} = $device;
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


1;
