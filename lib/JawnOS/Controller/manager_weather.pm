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

1;
