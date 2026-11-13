package subs;

# Weather: current conditions and a forecast for a coordinate, from the
# national service of the country when it has a free API (Environment Canada
# for Canada, the US National Weather Service for the US) and Open-Meteo
# elsewhere. The app asks for the house's own GPS fixation - the `continent`
# table - rather than scraping a city page, so a phone in another town gets
# that town's weather.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Math::Trig qw(deg2rad);
use Mojo::JSON qw(decode_json encode_json);
use Mojo::UserAgent;
use Mojo::DOM;
use Mojo::Util qw(md5_sum);
use Time::Local qw(timegm);
use Time::Piece;

our $device;
our $gb;

# ---- small reader helpers ---------------------------------------------------
# The national services wrap a value in { value => { en => ... } }; Open-Meteo
# sends a plain number. These two read either shape.
sub weather_text($v) {
	return '' unless defined $v;
	return $v if !ref $v;
	if (ref $v eq 'HASH') {
		return $v->{'en'} if defined $v->{'en'} && !ref $v->{'en'};
		if (ref $v->{'value'} eq 'HASH') {
			return $v->{'value'}->{'en'} if defined $v->{'value'}->{'en'} && !ref $v->{'value'}->{'en'};
		}
		return $v->{'value'} if defined $v->{'value'} && !ref $v->{'value'};
	}
	return '';
}

sub weather_number($v) {
	return undef unless defined $v;
	if (ref $v eq 'HASH') {
		return &weather_number($v->{'value'}->{'en'}) if ref $v->{'value'} eq 'HASH';
		return &weather_number($v->{'en'}) if exists $v->{'en'};
		return &weather_number($v->{'value'}) if exists $v->{'value'};
	}
	return undef if ref $v;
	# The old weather page trimmed a leading zero, so its readings include
	# "-.1" and ".5" as well as ordinary decimals.
	return undef unless "$v" =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)$/;
	return 0 + $v;
}

sub weather_iso_epoch($s) {
	return 0 unless defined $s && length $s;
	return 0 unless $s =~ /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?/;
	my ($y, $mo, $d, $h, $mi, $sec) = ($1, $2, $3, $4, $5, $6 // 0);
	my $epoch = eval { timegm($sec, $mi, $h, $d, $mo - 1, $y) };
	return $epoch ? $epoch * 1000 : 0;
}

sub weather_compass($deg) {
	return '' unless defined $deg && "$deg" =~ /^-?\d+(?:\.\d+)?$/;
	my @points = qw(N NNE NE ENE E ESE SE SSE S SSW SW WSW W WNW NW NNW);
	my $i = int((((0 + $deg) % 360) + 360) % 360 / 22.5 + 0.5) % 16;
	return $points[$i];
}

sub weather_distance_km($lat1, $lon1, $lat2, $lon2) {
	my $r = 6371;
	my $dlat = deg2rad($lat2 - $lat1);
	my $dlon = deg2rad($lon2 - $lon1);
	my $a = sin($dlat / 2) ** 2 + cos(deg2rad($lat1)) * cos(deg2rad($lat2)) * sin($dlon / 2) ** 2;
	return $r * 2 * atan2(sqrt($a), sqrt(1 - $a));
}

# A rule states pressure in kPa (the unit Environment Canada sends); the US and
# Open-Meteo send hPa. Keep one unit so a rule reads the same under every
# provider.
sub weather_pressure_kpa($value, $unit) {
	my $n = &weather_number($value);
	return undef unless defined $n;
	my $u = lc($unit // '');
	return $n / 10 if $u =~ /^(?:hpa|mb|mbar)$/;
	return $n / 1000 if $u =~ /^pa$/;
	return $n;
}

# The picker's stamp: 11/06/2026 3:01:44pm. The house reads Eastern; the box and
# the database stay UTC, and this formats in the server's local time like the
# rest of the panel.
sub weather_stamp_text($ms) {
	return '' unless defined $ms && "$ms" =~ /^\d+$/;
	return localtime(int($ms / 1000))->strftime('%m/%d/%Y %-I:%M:%S%P');
}

# ---- dates and daily merging ------------------------------------------------
# The providers do not all carry a date on a forecast period: EC names the
# period (Today, Tonight, Tomorrow, Saturday night) and NWS names the day. The
# app needs one row per calendar day for the history comparison, so every
# normalizer gives each period a date and these two helpers merge day/night
# pairs into the day they belong to.
sub weather_day_key($ms) {
	return '' unless defined $ms && "$ms" =~ /^-?\d+(?:\.\d+)?$/;
	return Time::Piece->new(int($ms / 1000))->strftime('%Y-%m-%d');
}

sub weather_days_between($from, $to) {
	return undef unless defined $from && defined $to
		&& $from =~ /^\d{4}-\d{2}-\d{2}$/ && $to =~ /^\d{4}-\d{2}-\d{2}$/;
	my $a = eval { Time::Piece->strptime($from, '%Y-%m-%d') } or return undef;
	my $b = eval { Time::Piece->strptime($to, '%Y-%m-%d') } or return undef;
	return int(($b->epoch - $a->epoch) / 86400);
}

sub weather_condition_class($text) {
	my $t = lc($text // '');
	return 'thunder' if $t =~ /thunder|storm/;
	return 'snow' if $t =~ /snow|flurr|blizzard|ice/;
	return 'rain' if $t =~ /rain|shower|drizzle/;
	return 'fog' if $t =~ /fog|mist|haze/;
	return 'cloud' if $t =~ /cloud|overcast/;
	return 'clear' if $t =~ /clear|sunny|sun/;
	return 'other';
}

# A national service forecasts about a week. Keep its days and take the rest from
# Open-Meteo; a day the service named is never replaced by the fallback.
sub weather_daily_extend($primary, $extra) {
	my @out = map { { %{$_} } } grep {
		ref $_ eq 'HASH' && ($_->{'date'} // '') =~ /^\d{4}-\d{2}-\d{2}$/
	} @{ ref $primary eq 'ARRAY' ? $primary : [] };
	my %have = map { $_->{'date'} => 1 } @out;
	foreach my $d (@{ ref $extra eq 'ARRAY' ? $extra : [] }) {
		next unless ref $d eq 'HASH';
		my $date = $d->{'date'} // '';
		next unless $date =~ /^\d{4}-\d{2}-\d{2}$/;
		next if $have{$date}++;
		my %copy = %{$d};
		$copy{'extended'} = 1;
		push @out, \%copy;
	}
	return [ sort { ($a->{'date'} // '') cmp ($b->{'date'} // '') } @out ];
}

sub weather_daily_merge($daily) {
	my %by;
	my @order;
	foreach my $d (@{ ref $daily eq 'ARRAY' ? $daily : [] }) {
		next unless ref $d eq 'HASH';
		my $date = $d->{'date'} // '';
		next unless $date =~ /^\d{4}-\d{2}-\d{2}$/;
		if (!$by{$date}) {
			$by{$date} = {
				date => $date,
				label => $d->{'label'} // '',
				high => $d->{'high'},
				low => $d->{'low'},
				condition => $d->{'condition'} // '',
				text => $d->{'text'} // '',
				glyph => $d->{'glyph'} // '',
				precip_prob => $d->{'precip_prob'},
				wind_speed => $d->{'wind_speed'},
				uv => $d->{'uv'},
				periods => [],
			};
			push @order, $date;
		}
		my $m = $by{$date};
		$m->{'high'} = $d->{'high'} if defined $d->{'high'} && (!defined $m->{'high'} || $d->{'high'} > $m->{'high'});
		$m->{'low'} = $d->{'low'} if defined $d->{'low'} && (!defined $m->{'low'} || $d->{'low'} < $m->{'low'});
		$m->{'condition'} = $d->{'condition'} if !length $m->{'condition'} && defined $d->{'condition'} && length $d->{'condition'};
		$m->{'text'} = $d->{'text'} if !length $m->{'text'} && defined $d->{'text'} && length $d->{'text'};
		$m->{'glyph'} = $d->{'glyph'} if !length $m->{'glyph'} && defined $d->{'glyph'} && length $d->{'glyph'};
		$m->{'precip_prob'} = $d->{'precip_prob'} if defined $d->{'precip_prob'} && (!defined $m->{'precip_prob'} || $d->{'precip_prob'} > $m->{'precip_prob'});
		$m->{'wind_speed'} = $d->{'wind_speed'} if defined $d->{'wind_speed'} && (!defined $m->{'wind_speed'} || $d->{'wind_speed'} > $m->{'wind_speed'});
		$m->{'uv'} = $d->{'uv'} if !defined $m->{'uv'} && defined $d->{'uv'};
		push @{$m->{'periods'}}, {
			label => $d->{'label'} // '',
			text => $d->{'text'} // '',
			condition => $d->{'condition'} // '',
		};
	}
	return [ map { $by{$_} } @order ];
}

# ---- condition words and glyphs --------------------------------------------
sub weather_wmo_text($code) {
	my %word = (
		0 => 'Clear sky', 1 => 'Mainly clear', 2 => 'Partly cloudy', 3 => 'Overcast',
		45 => 'Fog', 48 => 'Depositing rime fog',
		51 => 'Light drizzle', 53 => 'Moderate drizzle', 55 => 'Dense drizzle',
		56 => 'Light freezing drizzle', 57 => 'Dense freezing drizzle',
		61 => 'Slight rain', 63 => 'Moderate rain', 65 => 'Heavy rain',
		66 => 'Light freezing rain', 67 => 'Heavy freezing rain',
		71 => 'Slight snow', 73 => 'Moderate snow', 75 => 'Heavy snow', 77 => 'Snow grains',
		80 => 'Slight rain showers', 81 => 'Moderate rain showers', 82 => 'Violent rain showers',
		85 => 'Slight snow showers', 86 => 'Heavy snow showers',
		95 => 'Thunderstorm', 96 => 'Thunderstorm with slight hail', 99 => 'Thunderstorm with heavy hail',
	);
	my $n = &weather_number($code);
	return defined $n && exists $word{$n} ? $word{$n} : 'Weather';
}

sub weather_glyph_wmo($code) {
	my $n = &weather_number($code);
	return '☀️' if defined $n && $n == 0;
	return '🌤️' if defined $n && $n == 1;
	return '⛅' if defined $n && $n == 2;
	return '☁️' if defined $n && $n == 3;
	return '🌫️' if defined $n && ($n == 45 || $n == 48);
	return '🌦️' if defined $n && $n >= 51 && $n <= 57;
	return '🌧️' if defined $n && (($n >= 61 && $n <= 67) || ($n >= 80 && $n <= 82));
	return '🌨️' if defined $n && (($n >= 71 && $n <= 77) || $n == 85 || $n == 86);
	return '⛈️' if defined $n && $n >= 95;
	return '🌡️';
}

sub weather_glyph_ec($code, $text) {
	my %glyph = (
		0 => '☀️', 1 => '🌤️', 2 => '⛅', 3 => '🌥️', 4 => '☁️',
		5 => '🌦️', 6 => '🌧️', 7 => '🌨️', 8 => '🌨️', 9 => '🌫️',
		10 => '🌫️', 11 => '🌧️', 12 => '🌧️', 13 => '🌧️', 14 => '🌧️',
		15 => '🌨️', 16 => '🌨️', 17 => '🌨️', 18 => '🌨️',
		19 => '🌧️', 20 => '🌧️', 21 => '🌧️', 22 => '🌧️', 23 => '🌧️',
		24 => '🌧️', 25 => '🌧️', 26 => '🌧️', 27 => '🌧️', 28 => '🌧️',
		29 => '🌧️', 30 => '🌧️', 31 => '🌧️', 32 => '🌧️', 33 => '🌧️',
		34 => '🌧️', 35 => '🌧️', 36 => '🌧️', 37 => '🌧️', 38 => '🌧️',
		39 => '🌧️', 40 => '⛈️', 41 => '⛈️', 42 => '⛈️', 43 => '⛈️',
		44 => '⛈️', 45 => '⛈️', 46 => '⛈️', 47 => '⛈️', 48 => '⛈️',
		49 => '🌫️',
	);
	my $n = &weather_number($code);
	return $glyph{$n} if defined $n && exists $glyph{$n};
	my $t = lc(&weather_text($text));
	return '☀️' if $t =~ /clear|sunny/;
	return '🌤️' if $t =~ /mainly clear|mostly sunny/;
	return '⛅' if $t =~ /partly/;
	return '☁️' if $t =~ /cloudy|overcast/;
	return '🌫️' if $t =~ /fog|mist|haze/;
	return '🌨️' if $t =~ /snow|flurr/;
	return '⛈️' if $t =~ /thunder|storm/;
	return '🌧️' if $t =~ /rain|shower|drizzle/;
	return '🌡️';
}

sub weather_glyph_nws($icon, $text) {
	my $url = lc($icon // '');
	return '☀️' if $url =~ /skc|hot|sunny/;
	return '🌤️' if $url =~ /few/;
	return '⛅' if $url =~ /sct/;
	return '☁️' if $url =~ /bkn|ovc|cloud/;
	return '🌫️' if $url =~ /fog|haze/;
	return '🌨️' if $url =~ /snow|blizzard|ice/;
	return '⛈️' if $url =~ /tsra|tstm|thunder/;
	return '🌧️' if $url =~ /rain|shower|drizzle/;
	return &weather_glyph_ec(undef, $text);
}

# ---- provider choice --------------------------------------------------------
sub weather_provider_default($lat, $lon) {
	return 'ec' if $lat >= 41 && $lat <= 84 && $lon >= -141 && $lon <= -52;
	return 'nws' if $lat >= 24 && $lat <= 50 && $lon >= -125 && $lon <= -66;
	return 'openmeteo';
}

sub weather_provider_for($lat, $lon, $override = undef) {
	if (!defined $override) {
		$override = eval { &setting_grabber({ app => 'misc', setting => 'weather_provider' }) } || '';
	}
	return lc($override) if defined $override && $override =~ /^(?:ec|nws|openmeteo)$/i;
	return &weather_provider_default($lat, $lon);
}

sub weather_provider_label($provider) {
	return 'Environment Canada' if ($provider // '') eq 'ec';
	return 'US National Weather Service' if ($provider // '') eq 'nws';
	return 'Open-Meteo';
}

# ---- Environment Canada ----------------------------------------------------
sub weather_ec_normalize($feature) {
	my $p = ref $feature eq 'HASH' ? ($feature->{'properties'} || $feature) : {};
	my $cc = $p->{'currentConditions'} || {};
	my $cur = {
		temperature => &weather_number($cc->{'temperature'}),
		temperature_unit => 'C',
		feels_like => &weather_number($cc->{'windChill'}),
		humidity => &weather_number($cc->{'relativeHumidity'}),
		condition => &weather_text($cc->{'condition'}),
		wind_speed => &weather_number($cc->{'wind'}->{'speed'}),
		wind_direction => &weather_text($cc->{'wind'}->{'direction'}),
		wind_gust => &weather_number($cc->{'wind'}->{'gust'}),
		pressure => &weather_number($cc->{'pressure'}),
		pressure_unit => &weather_text($cc->{'pressure'}->{'units'}),
		dew_point => &weather_number($cc->{'dewpoint'}),
		observed_at => &weather_iso_epoch(&weather_text($cc->{'timestamp'})),
		observed_text => &weather_text($cc->{'timestamp'}),
		station => &weather_text($cc->{'station'}->{'value'}),
		icon => &weather_text($cc->{'iconCode'}->{'url'}),
		glyph => &weather_glyph_ec($cc->{'iconCode'}->{'value'}, &weather_text($cc->{'condition'})),
	};
	my @hourly;
	foreach my $h (@{ $p->{'hourlyForecastGroup'}->{'hourlyForecasts'} || [] }) {
		next unless ref $h eq 'HASH';
		push @hourly, {
			time => &weather_iso_epoch($h->{'timestamp'}),
			time_text => $h->{'timestamp'} // '',
			temperature => &weather_number($h->{'temperature'}),
			condition => &weather_text($h->{'condition'}),
			glyph => &weather_glyph_ec($h->{'iconCode'}->{'value'}, &weather_text($h->{'condition'})),
			icon => &weather_text($h->{'iconCode'}->{'url'}),
			precip_prob => &weather_number($h->{'lop'}),
			wind_speed => &weather_number($h->{'wind'}->{'speed'}),
			wind_direction => &weather_text($h->{'wind'}->{'direction'}),
		};
	}
	my @daily;
	foreach my $f (@{ $p->{'forecastGroup'}->{'forecasts'} || [] }) {
		next unless ref $f eq 'HASH';
		my @temps = @{ $f->{'temperatures'}->{'temperature'} || [] };
		my ($high, $low);
		foreach my $t (@temps) {
			my $class = lc(&weather_text($t->{'class'}));
			my $v = &weather_number($t);
			$high = $v if $class eq 'high' && !defined $high;
			$low = $v if $class eq 'low' && !defined $low;
		}
		$high = &weather_number($temps[0]) if !defined $high && scalar @temps == 1;
		$low = &weather_number($temps[-1]) if !defined $low && scalar @temps > 1;
		my $condition = &weather_text($f->{'abbreviatedForecast'}->{'textSummary'}) || &weather_text($f->{'cloudPrecip'});
		my $prob;
		$prob = $1 + 0 if $condition =~ /(\d+)\s*percent/i;
		my $wind = $f->{'winds'}->{'periods'}->[0] || {};
		my $bearing = &weather_number($wind->{'bearing'});
		push @daily, {
			label => &weather_text($f->{'period'}->{'textForecastName'}) || &weather_text($f->{'period'}->{'value'}),
			high => $high,
			low => $low,
			condition => $condition,
			text => &weather_text($f->{'cloudPrecip'}),
			glyph => &weather_glyph_ec($f->{'abbreviatedForecast'}->{'icon'}->{'value'}, $condition),
			icon => &weather_text($f->{'abbreviatedForecast'}->{'icon'}->{'url'}),
			precip_prob => $prob,
			wind_speed => &weather_number($wind->{'speed'}),
			wind_direction => defined $bearing ? &weather_compass($bearing) : '',
			uv => &weather_text($f->{'uv'}->{'index'}),
		};
	}
	my $today = Time::Piece->new()->strftime('%Y-%m-%d');
	my $cursor = Time::Piece->strptime($today, '%Y-%m-%d');
	for my $i (0 .. $#daily) {
		my $label = lc($daily[$i]->{'label'} // '');
		if ($i == 0) { $daily[$i]->{'date'} = $cursor->strftime('%Y-%m-%d'); next; }
		if ($label =~ /night|evening|overnight/) { $daily[$i]->{'date'} = $daily[$i - 1]->{'date'}; next; }
		$cursor = Time::Piece->new($cursor->epoch + 86400);
		$daily[$i]->{'date'} = $cursor->strftime('%Y-%m-%d');
	}
	$cur->{'high'} = $daily[0]->{'high'} if @daily;
	$cur->{'low'} = $daily[0]->{'low'} if @daily;
	$cur->{'uv'} = $daily[0]->{'uv'} if @daily && !defined $cur->{'uv'};
	my @alerts;
	foreach my $w (@{ $p->{'warnings'} || [] }) {
		next unless ref $w eq 'HASH';
		# EC sends the generic category in `type` ("statement") and the words a
		# person reads in `description` ("SPECIAL WEATHER STATEMENT"). The body of
		# the report is on the linked page, not in this payload, so keep the URL
		# and the issue/expiry times for the card.
		my $headline = &weather_text($w->{'description'})
			|| &weather_text($w->{'type'})
			|| &weather_text($w->{'title'})
			|| 'Weather alert';
		my $body = &weather_text($w->{'text'});
		$body = '' if lc($body) eq lc($headline);
		my $issued = &weather_iso_epoch(&weather_text($w->{'eventIssue'}));
		my $expires = &weather_iso_epoch(&weather_text($w->{'expiryTime'}));
		push @alerts, {
			title => &subs::format_name($headline),
			text => $body,
			url => &weather_text($w->{'url'}),
			region => &weather_text($p->{'region'}),
			($issued ? (issued_at => $issued) : ()),
			($expires ? (expires_at => $expires) : ()),
		};
	}
	return {
		provider => 'ec',
		provider_label => &weather_provider_label('ec'),
		location_name => &weather_text($p->{'name'}),
		region => &weather_text($p->{'region'}),
		issued_at => &weather_iso_epoch($p->{'lastUpdated'}),
		current => $cur,
		hourly => \@hourly,
		daily => \@daily,
		alerts => \@alerts,
		timezone => 'local',
	};
}

sub weather_ec_find_city($lat, $lon, $ua) {
	my $key = sprintf('%.1f_%.1f', $lat, $lon);
	my $cached = eval { &cache_get({ app => 'weather', context => 'ec_city', subcontext => $key }) };
	return $cached if ref $cached eq 'HASH' && $cached->{'id'};
	my $radius = 1.5;
	for my $try (1 .. 3) {
		my $bbox = sprintf('%.4f,%.4f,%.4f,%.4f', $lon - $radius, $lat - $radius, $lon + $radius, $lat + $radius);
		my $url = "https://api.weather.gc.ca/collections/citypageweather-realtime/items?f=json&limit=100&bbox=$bbox";
		my ($json) = &weather_http_get($url, $ua);
		if ($json) {
			my ($best, $best_distance);
			foreach my $f (@{ $json->{'features'} || [] }) {
				next unless ref $f eq 'HASH';
				my ($flon, $flat) = @{ $f->{'geometry'}->{'coordinates'} || [] };
				next unless defined $flon && defined $flat;
				my $distance = &weather_distance_km($lat, $lon, $flat, $flon);
				if (!defined $best_distance || $distance < $best_distance) {
					$best_distance = $distance;
					$best = $f;
				}
			}
			if ($best) {
				my $out = {
					id => &weather_text($best->{'properties'}->{'identifier'}),
					name => &weather_text($best->{'properties'}->{'name'}),
					region => &weather_text($best->{'properties'}->{'region'}),
					lat => $best->{'geometry'}->{'coordinates'}->[1],
					lon => $best->{'geometry'}->{'coordinates'}->[0],
					distance_km => $best_distance,
				};
				eval { &cache_set({ app => 'weather', context => 'ec_city', subcontext => $key, warranty => '-1d' }, $out) };
				return $out;
			}
		}
		$radius *= 2;
	}
	return undef;
}

sub weather_ec_fetch($lat, $lon, $ua) {
	my $city = &weather_ec_find_city($lat, $lon, $ua);
	return { error => 'No Environment Canada city near this location.' } unless $city && $city->{'id'};
	my ($json, $error) = &weather_http_get("https://api.weather.gc.ca/collections/citypageweather-realtime/items/$city->{'id'}?f=json", $ua);
	return { error => $error || 'Environment Canada did not answer.' } unless $json;
	my $out = &weather_ec_normalize($json);
	$out->{'location_name'} = $city->{'name'} if !$out->{'location_name'};
	$out->{'location_region'} = $city->{'region'};
	$out->{'location_distance_km'} = $city->{'distance_km'};
	return $out;
}

# ---- Open-Meteo -------------------------------------------------------------
sub weather_openmeteo_normalize($json) {
	my $j = ref $json eq 'HASH' ? $json : {};
	my $cur = $j->{'current'} || {};
	my $current = {
		temperature => &weather_number($cur->{'temperature_2m'}),
		temperature_unit => 'C',
		feels_like => &weather_number($cur->{'apparent_temperature'}),
		humidity => &weather_number($cur->{'relative_humidity_2m'}),
		condition => &weather_wmo_text($cur->{'weather_code'}),
		glyph => &weather_glyph_wmo($cur->{'weather_code'}),
		wind_speed => &weather_number($cur->{'wind_speed_10m'}),
		wind_direction => &weather_compass($cur->{'wind_direction_10m'}),
		wind_gust => &weather_number($cur->{'wind_gusts_10m'}),
		pressure => &weather_number($cur->{'pressure_msl'}),
		pressure_unit => 'hPa',
		dew_point => &weather_number($cur->{'dew_point_2m'}),
		precip => &weather_number($cur->{'precipitation'}),
		cloud_cover => &weather_number($cur->{'cloud_cover'}),
		is_day => $cur->{'is_day'},
		observed_at => 0,
		observed_text => $cur->{'time'} // '',
		icon => '',
	};
	my $h = $j->{'hourly'} || {};
	my @times = @{ $h->{'time'} || [] };
	my @hourly;
	for my $i (0 .. $#times) {
		push @hourly, {
			time => 0,
			time_text => $times[$i] // '',
			temperature => &weather_number($h->{'temperature_2m'}->[$i]),
			condition => &weather_wmo_text($h->{'weather_code'}->[$i]),
			glyph => &weather_glyph_wmo($h->{'weather_code'}->[$i]),
			precip_prob => &weather_number($h->{'precipitation_probability'}->[$i]),
			wind_speed => &weather_number($h->{'wind_speed_10m'}->[$i]),
			wind_direction => &weather_compass($h->{'wind_direction_10m'}->[$i]),
		};
	}
	my $d = $j->{'daily'} || {};
	my @dates = @{ $d->{'time'} || [] };
	my @daily;
	for my $i (0 .. $#dates) {
		push @daily, {
			date => $dates[$i],
			label => $dates[$i],
			high => &weather_number($d->{'temperature_2m_max'}->[$i]),
			low => &weather_number($d->{'temperature_2m_min'}->[$i]),
			condition => &weather_wmo_text($d->{'weather_code'}->[$i]),
			glyph => &weather_glyph_wmo($d->{'weather_code'}->[$i]),
			precip_prob => &weather_number($d->{'precipitation_probability_max'}->[$i]),
			wind_speed => &weather_number($d->{'wind_speed_10m_max'}->[$i]),
			sunrise => $d->{'sunrise'}->[$i] // '',
			sunset => $d->{'sunset'}->[$i] // '',
			uv => &weather_number($d->{'uv_index_max'}->[$i]),
		};
	}
	$current->{'high'} = $daily[0]->{'high'} if @daily;
	$current->{'low'} = $daily[0]->{'low'} if @daily;
	$current->{'uv'} = $daily[0]->{'uv'} if @daily;
	return {
		provider => 'openmeteo',
		provider_label => &weather_provider_label('openmeteo'),
		location_name => '',
		region => '',
		issued_at => &weather_number($j->{'current'}->{'time'}),
		current => $current,
		hourly => \@hourly,
		daily => \@daily,
		alerts => [],
		timezone => $j->{'timezone'} // '',
		utc_offset_seconds => $j->{'utc_offset_seconds'} // 0,
	};
}

sub weather_openmeteo_fetch($lat, $lon, $ua) {
	my $url = 'https://api.open-meteo.com/v1/forecast'
		. "?latitude=$lat&longitude=$lon"
		. '&current=temperature_2m,relative_humidity_2m,apparent_temperature,is_day,precipitation,weather_code,cloud_cover,pressure_msl,wind_speed_10m,wind_direction_10m,wind_gusts_10m,dew_point_2m'
		. '&hourly=temperature_2m,precipitation_probability,weather_code,wind_speed_10m,wind_direction_10m'
		. '&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,wind_speed_10m_max,uv_index_max,sunrise,sunset'
		. '&timezone=auto&forecast_days=14&temperature_unit=celsius&wind_speed_unit=kmh&precipitation_unit=mm';
	my ($json, $error) = &weather_http_get($url, $ua);
	return { error => $error || 'Open-Meteo did not answer.' } unless $json;
	return &weather_openmeteo_normalize($json);
}

# ---- US National Weather Service -------------------------------------------
sub weather_nws_temp($period) {
	my $v = &weather_number($period->{'temperature'});
	return undef unless defined $v;
	return ($v - 32) * 5 / 9 if (($period->{'temperatureUnit'} // '') eq 'F');
	return $v;
}

sub weather_nws_speed($speed) {
	my ($n) = ($speed // '') =~ /(\d+(?:\.\d+)?)/;
	return undef unless defined $n;
	return $n * 1.60934 if ($speed // '') =~ /mph/i;
	return $n + 0;
}

sub weather_nws_normalize($obs, $hourly, $daily, $points) {
	my $op = $obs->{'properties'} || {};
	my $pressure = &weather_number($op->{'barometricPressure'});
	$pressure = $pressure / 100 if defined $pressure;
	my $visibility = &weather_number($op->{'visibility'});
	$visibility = $visibility / 1000 if defined $visibility;
	my $current = {
		temperature => &weather_number($op->{'temperature'}),
		temperature_unit => 'C',
		feels_like => &weather_number($op->{'heatIndex'}) // &weather_number($op->{'windChill'}) // &weather_number($op->{'temperature'}),
		humidity => &weather_number($op->{'relativeHumidity'}),
		condition => $op->{'textDescription'} // '',
		glyph => &weather_glyph_nws($op->{'icon'}, $op->{'textDescription'}),
		wind_speed => &weather_number($op->{'windSpeed'}),
		wind_direction => &weather_compass(&weather_number($op->{'windDirection'})),
		wind_gust => &weather_number($op->{'windGust'}),
		pressure => $pressure,
		pressure_unit => 'hPa',
		dew_point => &weather_number($op->{'dewpoint'}),
		visibility => $visibility,
		observed_at => &weather_iso_epoch($op->{'timestamp'}),
		observed_text => $op->{'timestamp'} // '',
		icon => $op->{'icon'} // '',
	};
	my @hourly;
	foreach my $h (@{ $hourly->{'properties'}->{'periods'} || [] }) {
		next unless ref $h eq 'HASH';
		push @hourly, {
			time => &weather_iso_epoch($h->{'startTime'}),
			time_text => $h->{'startTime'} // '',
			temperature => &weather_nws_temp($h),
			condition => $h->{'shortForecast'} // '',
			glyph => &weather_glyph_nws($h->{'icon'}, $h->{'shortForecast'}),
			precip_prob => &weather_number($h->{'probabilityOfPrecipitation'}),
			wind_speed => &weather_nws_speed($h->{'windSpeed'}),
			wind_direction => $h->{'windDirection'} // '',
		};
	}
	my @periods = @{ $daily->{'properties'}->{'periods'} || [] };
	my @daily;
	for (my $i = 0; $i < @periods && @daily < 7; $i++) {
		my $p = $periods[$i];
		next unless ref $p eq 'HASH' && $p->{'isDaytime'};
		my $low;
		$low = &weather_nws_temp($periods[$i + 1]) if $i + 1 < @periods && !$periods[$i + 1]->{'isDaytime'};
		push @daily, {
			date => substr($p->{'startTime'} // '', 0, 10),
			label => $p->{'name'} // '',
			high => &weather_nws_temp($p),
			low => $low,
			condition => $p->{'shortForecast'} // '',
			text => $p->{'detailedForecast'} // '',
			glyph => &weather_glyph_nws($p->{'icon'}, $p->{'shortForecast'}),
			precip_prob => &weather_number($p->{'probabilityOfPrecipitation'}),
			wind_speed => &weather_nws_speed($p->{'windSpeed'}),
			wind_direction => $p->{'windDirection'} // '',
		};
	}
	$current->{'high'} = $daily[0]->{'high'} if @daily;
	$current->{'low'} = $daily[0]->{'low'} if @daily;
	my $city = $points->{'properties'}->{'relativeLocation'}->{'properties'}->{'city'} // '';
	my $state = $points->{'properties'}->{'relativeLocation'}->{'properties'}->{'state'} // '';
	return {
		provider => 'nws',
		provider_label => &weather_provider_label('nws'),
		location_name => join(', ', grep { length } ($city, $state)),
		region => $state,
		issued_at => &weather_iso_epoch($daily->{'properties'}->{'updated'} // ''),
		current => $current,
		hourly => \@hourly,
		daily => \@daily,
		alerts => [],
		timezone => 'local',
	};
}

sub weather_nws_fetch($lat, $lon, $ua) {
	my ($points, $error) = &weather_http_get("https://api.weather.gov/points/$lat,$lon", $ua);
	return { error => $error || 'The National Weather Service did not answer.' } unless $points;
	my $props = $points->{'properties'} || {};
	my ($hourly) = $props->{'forecastHourly'} ? &weather_http_get($props->{'forecastHourly'}, $ua) : (undef);
	my ($daily) = $props->{'forecast'} ? &weather_http_get($props->{'forecast'}, $ua) : (undef);
	my $obs;
	if ($props->{'observationStations'}) {
		my ($stations) = &weather_http_get($props->{'observationStations'}, $ua);
		my $station = $stations->{'features'}->[0]->{'properties'}->{'stationIdentifier'} if $stations;
		if ($station) {
			($obs) = &weather_http_get("https://api.weather.gov/stations/$station/observations/latest", $ua);
		}
	}
	return &weather_nws_normalize($obs || {}, $hourly || {}, $daily || {}, $points);
}

# ---- one fetch, one cache ---------------------------------------------------
# A place name for a coordinate the national services do not cover. Open-Meteo
# names no place, so ask this free service and let the caller keep the answer.
sub weather_reverse_geocode($lat, $lon) {
	return '' unless defined $lat && defined $lon;
	my $ua = Mojo::UserAgent->new(connect_timeout => 4, inactivity_timeout => 5, request_timeout => 6);
	my $url = 'https://api.bigdatacloud.net/data/reverse-geocode-client'
		. "?latitude=$lat&longitude=$lon&localityLanguage=en";
	my ($json) = &weather_http_get($url, $ua);
	return '' unless ref $json eq 'HASH';
	foreach my $key (qw(city locality principalSubdivision)) {
		my $value = $json->{$key} // '';
		$value =~ s/^\s+|\s+$//g;
		return $value if length $value && $value ne 'null';
	}
	return '';
}

sub weather_alert_report_parse($html, $url = '') {
	return undef unless defined $html && length $html;
	my $dom = Mojo::DOM->new($html);
	my ($frag) = ($url // '') =~ /#([A-Za-z0-9_-]+)\s*$/;
	my $root;
	if (defined $frag && length $frag) {
		$root = $dom->at('div[id="' . $frag . '"]');
	}
	unless ($root) {
		# A report without a fragment: the first alert block that carries a
		# pre-wrapped statement body is the one to read.
		($root) = grep { $_->at('p.pre-wrap') } @{ $dom->find('div[id]')->to_array };
	}
	return undef unless $root;
	my $body_node = $root->at('p.pre-wrap');
	return undef unless $body_node;
	my $body = $body_node->text;
	$body =~ s/\r\n?/\n/g;
	$body =~ s/[ \t]+\n/\n/g;
	$body =~ s/^\s+|\s+$//g;
	my @areas;
	my $list = $root->at('ul');
	if ($list) {
		foreach my $li (@{ $list->find('li')->to_array }) {
			my $area = $li->text;
			$area =~ s/^\s+|\s+$//g;
			push @areas, $area if length $area;
		}
	}
	return { body => $body, areas => \@areas };
}

# The alert payload names the statement but does not carry its body; the report
# page does. The URL's fragment is the id of the alert's block, so read that
# block rather than the whole page (a region can have several). Keep it for half
# an hour; the report is public and changes only when the alert does.
sub weather_alert_report($url) {
	return undef unless defined $url && $url =~ m{^https?://};
	my $key = substr(md5_sum($url), 0, 24);
	my $cached = eval { &cache_get({ app => 'weather', context => 'alert_report', subcontext => $key }) };
	return $cached if ref $cached eq 'HASH' && ($cached->{'at'} || 0) > &rightNow() - 30 * 60 * 1000;
	my $ua = Mojo::UserAgent->new(connect_timeout => 4, inactivity_timeout => 6, request_timeout => 8, max_redirects => 4);
	my ($html, $error) = &weather_http_get_text($url, $ua);
	my $parsed = $html ? &weather_alert_report_parse($html, $url) : undef;
	my $out = $parsed
		? { at => &rightNow(), %{$parsed} }
		: { at => &rightNow(), error => $error || 'no report body' };
	eval { &cache_set({ app => 'weather', context => 'alert_report', subcontext => $key, warranty => ($parsed ? '-30m' : '-10m') }, $out) };
	return $out;
}

sub weather_alert_enrich($weather) {
	return $weather unless ref $weather eq 'HASH' && ref $weather->{'alerts'} eq 'ARRAY';
	foreach my $alert (@{ $weather->{'alerts'} }) {
		next unless ref $alert eq 'HASH' && length($alert->{'url'} // '');
		my $report = eval { &weather_alert_report($alert->{'url'}) };
		next unless ref $report eq 'HASH' && !$report->{'error'};
		$alert->{'text'} = $report->{'body'} if length($report->{'body'} // '');
		$alert->{'areas'} = $report->{'areas'}
			if ref $report->{'areas'} eq 'ARRAY' && @{ $report->{'areas'} };
	}
	return $weather;
}

sub weather_http_get_text($url, $ua) {
	return (undef, 'no address') unless defined $url && length $url;
	my $res = eval {
		$ua->get($url => {
			'User-Agent' => 'JawnOS Weather (weather@jawnos.local)',
			'Accept' => 'text/html,application/xhtml+xml',
		})->result;
	};
	return (undef, 'request failed') unless $res;
	return (undef, 'HTTP ' . $res->code) unless $res->is_success;
	return ($res->body, undef);
}

sub weather_http_get($url, $ua) {
	return (undef, 'no address') unless defined $url && length $url;
	my $res = eval {
		$ua->get($url => {
			'User-Agent' => 'JawnOS Weather (weather@jawnos.local)',
			'Accept' => 'application/geo+json, application/json',
		})->result;
	};
	return (undef, 'request failed') unless $res;
	return (undef, 'HTTP ' . $res->code) unless $res->is_success;
	my $json = eval { decode_json $res->body };
	return (undef, 'bad JSON') unless $json;
	return ($json, undef);
}

# ---- private stations -------------------------------------------------------
# Environment Canada's city page reads the nearest airport, which in a rural
# place can be thirty kilometres away. A personal station on Weather Underground
# is a reading of the ground the person is standing on. "Closest" takes the
# barometer from the nearest station and the other measures from the next
# nearest, so a pressure-only station still contributes the reading it has.
# A saved key is the stable path. With none, read the public key Weather
# Underground puts in its own page and keep it for a day: the API is the same
# one the page uses, so Closest works before anyone signs up for a key. A saved
# key always wins, and the dialog names which one is in use.
sub weather_pws_api_key() {
	my $key = eval { &setting_grabber({ app => 'weather', setting => 'pws_api_key' }) };
	$key = '' unless defined $key;
	$key =~ s/^\s+|\s+$//g;
	return $key if length $key;
	my $cached = eval { &cache_get({ app => 'weather', context => 'wu_key', subcontext => 'public' }) };
	return $cached->{'key'} if ref $cached eq 'HASH' && ($cached->{'at'} || 0) > &rightNow() - 24 * 3600 * 1000;
	my $ua = &weather_pws_ua();
	my $res = eval {
		$ua->get('https://www.wunderground.com/' => {
			'User-Agent' => 'JawnOS Weather (weather@jawnos.local)',
			'Accept' => 'text/html',
		})->result;
	};
	return '' unless $res && $res->is_success;
	my ($found) = $res->body =~ /"API_KEY":"([A-Za-z0-9]{20,})"/;
	return '' unless $found;
	eval { &cache_set({ app => 'weather', context => 'wu_key', subcontext => 'public', warranty => '-1d' }, { at => &rightNow(), key => $found }) };
	return $found;
}

sub weather_pws_key_source() {
	my $saved = eval { &setting_grabber({ app => 'weather', setting => 'pws_api_key' }) };
	$saved = '' unless defined $saved;
	$saved =~ s/^\s+|\s+$//g;
	return 'setting' if length $saved;
	return 'public' if length &weather_pws_api_key();
	return '';
}

sub weather_pws_ua() {
	return Mojo::UserAgent->new(connect_timeout => 4, inactivity_timeout => 6, request_timeout => 8);
}

sub weather_pws_near($lat, $lon, $opts = {}) {
	$opts ||= {};
	return { error => &subs::ui('A Weather Underground API key is needed for local stations.'), missing_key => 1 }
		unless length &weather_pws_api_key();
	return { error => &subs::ui('No coordinate to look up.') } unless defined $lat && defined $lon;
	my $key = sprintf('%.2f_%.2f', $lat, $lon);
	my $cached = eval { &cache_get({ app => 'weather', context => 'pws_near', subcontext => $key }) };
	return $cached if !$opts->{'force'} && ref $cached eq 'HASH' && ($cached->{'at'} || 0) > &rightNow() - 300_000;
	my $api = &weather_pws_api_key();
	my $url = 'https://api.weather.com/v3/location/near?geocode=' . $lat . ',' . $lon
		. '&product=pws&format=json&apiKey=' . $api;
	my ($json, $error) = &weather_http_get($url, &weather_pws_ua());
	return { error => $error || &subs::ui('Weather Underground did not answer.') } unless ref $json eq 'HASH';
	my $loc = ref $json->{'location'} eq 'HASH' ? $json->{'location'} : {};
	my $list = sub {
		my ($name) = @_;
		return ref $loc->{$name} eq 'ARRAY' ? $loc->{$name} : [];
	};
	my @ids = @{ $list->('stationId') };
	my @stations;
	for my $i (0 .. $#ids) {
		my $id = $ids[$i] // '';
		next unless $id =~ /^[A-Za-z0-9]{4,20}$/;
		my $qc = $list->('qcStatus')->[$i];
		next if defined $qc && $qc < 0;
		my $name = $list->('stationName')->[$i] // '';
		$name = $id unless length $name;
		my $distance = &weather_number($list->('distanceKm')->[$i]);
		push @stations, {
			id => $id,
			name => $name,
			distance_km => defined $distance ? 0 + $distance : 0,
			lat => &weather_number($list->('latitude')->[$i]),
			lon => &weather_number($list->('longitude')->[$i]),
			updated => $list->('updateTimeUtc')->[$i],
		};
	}
	@stations = sort { $a->{'distance_km'} <=> $b->{'distance_km'} || $a->{'id'} cmp $b->{'id'} } @stations;
	my $out = { at => &rightNow(), stations => \@stations };
	eval { &cache_set({ app => 'weather', context => 'pws_near', subcontext => $key, warranty => '-5m' }, $out) };
	return $out;
}

# One observation from Weather Underground in the shape the app already reads.
# The station's own pressure is kept in hPa; the observer converts it to kPa for
# a rule, exactly as it does for a national service that sends hPa.
sub weather_pws_normalize($obs, $distance_km = undef, $name = '') {
	return undef unless ref $obs eq 'HASH';
	my $m = ref $obs->{'metric'} eq 'HASH' ? $obs->{'metric'} : {};
	my $out = {
		id => $obs->{'stationID'} // '',
		name => length($obs->{'neighborhood'} // '') ? $obs->{'neighborhood'} : ($name // ''),
		distance_km => defined $distance_km ? 0 + $distance_km : undef,
		lat => &weather_number($obs->{'lat'}),
		lon => &weather_number($obs->{'lon'}),
		observed_at => &weather_iso_epoch($obs->{'obsTimeUtc'}),
		observed_text => $obs->{'obsTimeUtc'} // '',
		temperature => &weather_number($m->{'temp'}),
		feels_like => &weather_number($m->{'heatIndex'}),
		humidity => &weather_number($obs->{'humidity'}),
		wind_speed => &weather_number($m->{'windSpeed'}),
		wind_gust => &weather_number($m->{'windGust'}),
		wind_direction => &weather_compass(&weather_number($obs->{'winddir'})),
		pressure => &weather_number($m->{'pressure'}),
		pressure_unit => 'hPa',
		dew_point => &weather_number($m->{'dewpt'}),
		precip_rate => &weather_number($m->{'precipRate'}),
		precip_total => &weather_number($m->{'precipTotal'}),
		uv => &weather_number($obs->{'uv'}),
		solar_radiation => &weather_number($obs->{'solarRadiation'}),
		qc_status => $obs->{'qcStatus'},
		software => $obs->{'softwareType'} // '',
	};
	$out->{'feels_like'} = &weather_number($m->{'windChill'}) unless defined $out->{'feels_like'};
	$out->{'name'} = $out->{'id'} unless length $out->{'name'};
	my @measures = grep {
		defined $out->{$_} && (ref $out->{$_} || length "$out->{$_}")
	} qw(temperature feels_like humidity wind_speed wind_gust wind_direction pressure dew_point precip_rate precip_total uv);
	$out->{'measures'} = \@measures;
	return $out;
}

sub weather_pws_current($id, $opts = {}) {
	$opts ||= {};
	return { error => &subs::ui('No station chosen.') } unless defined $id && $id =~ /^[A-Za-z0-9]{4,20}$/;
	my $cached = eval { &cache_get({ app => 'weather', context => 'pws_current', subcontext => $id }) };
	return $cached if !$opts->{'force'} && ref $cached eq 'HASH' && ($cached->{'at'} || 0) > &rightNow() - 120_000;
	my $api = &weather_pws_api_key();
	return { error => &subs::ui('A Weather Underground API key is needed for local stations.'), missing_key => 1 }
		unless length $api;
	my $url = 'https://api.weather.com/v2/pws/observations/current?stationId=' . $id
		. '&numericPrecision=decimal&format=json&units=m&extraVars=1&apiKey=' . $api;
	my ($json, $error) = &weather_http_get($url, &weather_pws_ua());
	return { error => $error || &subs::ui('Weather Underground did not answer.') } unless ref $json eq 'HASH';
	my $obs = ref $json->{'observations'} eq 'ARRAY' ? $json->{'observations'}->[0] : undef;
	return { error => &subs::ui('That station has no current reading.') } unless ref $obs eq 'HASH';
	my $out = &weather_pws_normalize($obs);
	$out->{'id'} = $id unless length $out->{'id'};
	$out->{'at'} = &rightNow();
	eval { &cache_set({ app => 'weather', context => 'pws_current', subcontext => $id, warranty => '-5m' }, $out) };
	return $out;
}

sub weather_pws_fresh($obs, $opts = {}) {
	$opts ||= {};
	return 0 unless ref $obs eq 'HASH' && !$obs->{'error'};
	my $max = $opts->{'max_age_ms'} || 90 * 60 * 1000;
	my $seen = $obs->{'observed_at'} || 0;
	return ($seen > 0 && $seen >= &rightNow() - $max) ? 1 : 0;
}

# The nearest station supplies the barometer, the next nearest everything else.
# A station that has stopped reporting, or one the network flags, is skipped;
# the next one on the same list takes its role.
sub weather_pws_pick($lat, $lon, $opts = {}) {
	$opts ||= {};
	my $near = &weather_pws_near($lat, $lon, $opts);
	return $near if $near->{'error'};
	my @stations = @{ $near->{'stations'} || [] };
	return { error => &subs::ui('No local station was found.'), near => $near } unless @stations;
	my $try = $opts->{'try'} || 4;
	my @fetched;
	foreach my $station (@stations) {
		last if @fetched >= $try;
		my $obs = &weather_pws_current($station->{'id'}, $opts);
		next if $obs->{'error'};
		$obs->{'distance_km'} = $station->{'distance_km'} unless defined $obs->{'distance_km'};
		$obs->{'name'} = $station->{'name'}
			if !length($obs->{'name'} // '') || $obs->{'name'} eq $obs->{'id'};
		next unless &weather_pws_fresh($obs, $opts);
		push @fetched, $obs;
	}
	return { error => &subs::ui('No local station has a current reading.'), near => $near } unless @fetched;
	my ($barometer) = grep { defined $_->{'pressure'} } @fetched;
	my ($other) = grep {
		defined $_->{'temperature'} && defined $_->{'humidity'}
			&& (!$barometer || $_->{'id'} ne $barometer->{'id'})
	} @fetched;
	$other ||= $barometer;
	$barometer ||= $other;
	$other ||= $fetched[0];
	$barometer ||= $other;
	return {
		at => &rightNow(),
		barometer => $barometer,
		other => $other,
		stations => \@fetched,
		near => $near,
	};
}

sub weather_pws_summary($obs) {
	return undef unless ref $obs eq 'HASH';
	return {
		id => $obs->{'id'} // '',
		name => $obs->{'name'} // '',
		distance_km => $obs->{'distance_km'},
		observed_text => $obs->{'observed_text'} // '',
		measures => $obs->{'measures'} || [],
	};
}

# Fold the local station into the provider's answer. The forecast stays with the
# national service; only the current measures come from the stations. The local
# rain gauge decides precipitation, so a city page that reads an airport thirty
# kilometres away cannot keep the house wet when the station says it is dry.
sub weather_pws_merge($base, $pick) {
	return $base unless ref $base eq 'HASH' && ref $pick eq 'HASH';
	my $out = { %{$base} };
	my $current = { %{ $base->{'current'} || {} } };
	my $label = sub {
		my ($word) = @_;
		my $shown = eval { &subs::format_name($word) };
		return defined $shown && length $shown ? $shown : ucfirst($word);
	};
	my $bar = $pick->{'barometer'};
	my $other = $pick->{'other'} || $bar;
	if ($other) {
		foreach my $pair (
			[ 'temperature', 'temperature' ],
			[ 'feels_like', 'feels_like' ],
			[ 'humidity', 'humidity' ],
			[ 'wind_speed', 'wind_speed' ],
			[ 'wind_gust', 'wind_gust' ],
			[ 'wind_direction', 'wind_direction' ],
			[ 'dew_point', 'dew_point' ],
			[ 'uv', 'uv' ],
		) {
			$current->{ $pair->[1] } = $other->{ $pair->[0] }
				if defined $other->{ $pair->[0] };
		}
		$current->{'temperature_unit'} = 'C';
		$current->{'wind_unit'} = 'km/h';
		$current->{'observed_at'} = $other->{'observed_at'} if $other->{'observed_at'};
		$current->{'observed_text'} = $other->{'observed_text'}
			if length($other->{'observed_text'} // '');
		if (defined $other->{'precip_rate'}) {
			my $temp = $current->{'temperature'};
			if ($other->{'precip_rate'} > 0) {
				my $word = (defined $temp && $temp <= 0) ? 'snow' : 'rain';
				$current->{'condition'} = $label->($word);
				$current->{'glyph'} = $word eq 'snow' ? '🌨️' : '🌧️';
			}
			else {
				my $base_condition = $current->{'condition'} // '';
				if ($base_condition =~ /rain|shower|drizzle/i) {
					my $word = $base_condition =~ /thunder|storm/i ? 'thunderstorm' : 'cloudy';
					$current->{'condition'} = $label->($word);
					$current->{'glyph'} = $word eq 'thunderstorm' ? '⛈️' : '☁️';
				}
			}
		}
	}
	if ($bar && defined $bar->{'pressure'}) {
		$current->{'pressure'} = $bar->{'pressure'};
		$current->{'pressure_unit'} = 'hPa';
	}
	$out->{'current'} = $current;
	$out->{'provider'} = 'closest';
	$out->{'provider_label'} = &subs::ui('Closest stations');
	$out->{'pws'} = {
		barometer => &weather_pws_summary($bar),
		other => &weather_pws_summary($other),
	};
	return $out;
}

sub weather_fetch($lat, $lon, $opts) {
	$opts ||= {};
	my $source = $opts->{'source'};
	$source = { mode => $source } if defined $source && !ref $source;
	if (ref $source eq 'HASH' && !$opts->{'raw'}) {
		my $mode = lc($source->{'mode'} // '');
		if ($mode eq 'closest' || $mode eq 'pws') {
			my $base = &weather_fetch($lat, $lon, { %{$opts}, raw => 1, source => undef });
			return $base if ref $base ne 'HASH' || $base->{'error'};
			my $pick;
			if ($mode eq 'pws') {
				my $obs = &weather_pws_current($source->{'station'} // '', { force => $opts->{'force'} });
				$pick = $obs && !$obs->{'error'}
					? { barometer => $obs, other => $obs, stations => [$obs] }
					: { error => ($obs->{'error'} // &subs::ui('That station has no current reading.')), missing_key => $obs->{'missing_key'} };
			}
			else {
				$pick = &weather_pws_pick($lat, $lon, { force => $opts->{'force'} });
			}
			if (!$pick || $pick->{'error'}) {
				$base->{'source_note'} = $pick->{'error'} // &subs::ui('No local station was found.');
				$base->{'source_missing_key'} = 1 if $pick->{'missing_key'};
				return $base;
			}
			my $out = &weather_pws_merge($base, $pick);
			$out->{'forecast_provider'} = $base->{'provider'} // '';
			$out->{'forecast_provider_label'} = $base->{'provider_label'} // '';
			return $out;
		}
		$opts->{'provider'} = $mode if $mode =~ /^(?:ec|nws|openmeteo)$/;
	}
	return &weather_fetch_raw($lat, $lon, $opts);
}

sub weather_fetch_raw($lat, $lon, $opts) {
	$opts ||= {};
	my $provider = &weather_provider_for($lat, $lon, $opts->{'provider'});
	my $key = sprintf('%.2f_%.2f_%s', $lat, $lon, $provider);
	my $cached = eval { &cache_get({ app => 'weather', context => 'forecast', subcontext => $key }) };
	if (!$opts->{'force'} && ref $cached eq 'HASH' && !$cached->{'error'} && ($cached->{'fetched_at'} || 0) > &rightNow() - 600000
		&& (($provider eq 'openmeteo')
			|| (@{ $cached->{'hourly'} || [] }
				&& (@{ $cached->{'daily'} || [] } >= 14 || $cached->{'daily_short'})))) {
		return $cached;
	}
	my $ua = Mojo::UserAgent->new(connect_timeout => 6, inactivity_timeout => 10, request_timeout => 15);
	my $out;
	if ($provider eq 'ec') { $out = eval { &weather_ec_fetch($lat, $lon, $ua) }; }
	elsif ($provider eq 'nws') { $out = eval { &weather_nws_fetch($lat, $lon, $ua) }; }
	else { $out = eval { &weather_openmeteo_fetch($lat, $lon, $ua) }; }
	if (!$out || $out->{'error'}) {
		my $fallback = eval { &weather_openmeteo_fetch($lat, $lon, $ua) };
		if ($fallback && !$fallback->{'error'}) {
			$fallback->{'provider_label'} = &weather_provider_label('openmeteo');
			$fallback->{'fallback_from'} = $provider;
			$out = $fallback;
		}
	}
	return { error => 'Weather is unavailable right now.' } unless $out && !$out->{'error'};
	$out->{'daily'} = &weather_daily_merge($out->{'daily'});
	if ($provider ne 'openmeteo'
		&& (!@{ $out->{'hourly'} || [] } || @{ $out->{'daily'} || [] } < 14)) {
		my $fallback = eval { &weather_openmeteo_fetch($lat, $lon, $ua) };
		if ($fallback && !$fallback->{'error'}) {
			if (!@{ $out->{'hourly'} || [] } && @{ $fallback->{'hourly'} || [] }) {
				$out->{'hourly'} = $fallback->{'hourly'};
				$out->{'hourly_provider'} = 'openmeteo';
				$out->{'hourly_provider_label'} = &weather_provider_label('openmeteo');
			}
			if (@{ $out->{'daily'} || [] } < 14 && @{ $fallback->{'daily'} || [] }) {
				my $before = scalar @{ $out->{'daily'} || [] };
				$out->{'daily'} = &weather_daily_extend($out->{'daily'}, $fallback->{'daily'});
				$out->{'daily'} = [ @{ $out->{'daily'} }[0 .. 13] ] if @{ $out->{'daily'} } > 14;
				if (@{ $out->{'daily'} } > $before) {
					$out->{'daily_provider'} = 'openmeteo';
					$out->{'daily_provider_label'} = &weather_provider_label('openmeteo');
				}
			}
		}
	}
	# A short list after the extension is the service's real horizon, so the
	# cache may serve it; otherwise every request would pay for the fallback.
	$out->{'daily_short'} = 1 if @{ $out->{'daily'} || [] } < 14;
	$out->{'provider'} = $provider if ($out->{'fallback_from'} // '') eq '';
	$out->{'lat'} = $lat;
	$out->{'lon'} = $lon;
	$out->{'fetched_at'} = &rightNow();
	eval { &weather_forecast_snapshot_save($out, $lat, $lon) };
	eval { &cache_set({ app => 'weather', context => 'forecast', subcontext => $key, warranty => '-10m' }, $out) };
	return $out;
}

# ---- the house's own GPS fixes ---------------------------------------------
sub weather_device_fixes($window_ms) {
	$window_ms ||= 24 * 60 * 60 * 1000;
	my $now = &rightNow();
	my $rows = eval {
		&db_query(
			"select c.signatorial, c.latitude, c.longitude, c.accuracy, c.server_time, "
			. "coalesce(rm.hostname, rm.device, '') as label, rm.device "
			. "from continent c left join remote_machines rm on rm.signatorial = c.signatorial "
			. "where c.type = 'temporary' and c.latitude is not null and c.latitude != '' "
			. "and cast(c.server_time as integer) > ? "
			. "order by cast(c.server_time as integer) desc",
			$now - $window_ms
		)->hashes;
	} || [];
	my %seen;
	my @out;
	foreach my $r (@{$rows}) {
		my $sig = $r->{'signatorial'} || '';
		next if !length $sig || $seen{$sig}++;
		my $lat = &weather_number($r->{'latitude'});
		my $lon = &weather_number($r->{'longitude'});
		next unless defined $lat && defined $lon;
		my $seen_at = &weather_number($r->{'server_time'}) || 0;
		push @out, {
			signatorial => $sig,
			device => $r->{'device'} || '',
			label => $r->{'label'} || $r->{'device'} || 'Device',
			lat => $lat,
			lon => $lon,
			accuracy => $r->{'accuracy'},
			seen => $seen_at,
			age_ms => $now - $seen_at,
		};
	}
	my $me = &signatorial_designer();
	@out = sort {
		my $am = ($a->{'signatorial'} || '') eq $me ? 1 : 0;
		my $bm = ($b->{'signatorial'} || '') eq $me ? 1 : 0;
		$bm <=> $am || $b->{'seen'} <=> $a->{'seen'}
	} @out;
	return \@out;
}

sub weather_device_fix($signatorial) {
	$signatorial = &signatorial_designer() if !defined $signatorial || !length $signatorial || $signatorial eq 'me';
	my $row = eval {
		&db_query(
			"select * from continent where type = 'temporary' and signatorial = ? "
			. "and latitude is not null and latitude != '' "
			. "order by cast(server_time as integer) desc limit 1",
			$signatorial
		)->hashes->[0];
	};
	return undef unless $row;
	my $lat = &weather_number($row->{'latitude'});
	my $lon = &weather_number($row->{'longitude'});
	return undef unless defined $lat && defined $lon;
	return {
		signatorial => $signatorial,
		lat => $lat,
		lon => $lon,
		accuracy => $row->{'accuracy'},
		seen => &weather_number($row->{'server_time'}) || 0,
	};
}

1;
