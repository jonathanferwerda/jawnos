package subs;

# WeatherAutomation: what the Weather app does with what it has seen.
#
# Two kinds of rule live here:
#   * the old web-measure app's condition rules ("condition contains rain ->
#     start raining"), kept in `app_measures.condition.cm` and run by the
#     existing appt_measure_action engine; and
#   * measurement rules ("wind gust >= 20 km/h from the N -> start gusty",
#     "pressure < 101.2 kPa for six hours -> run a command"), kept in
#     `weather_station.weather_rules` and evaluated here.
#
# The observation is written under `weather_station` rather than `weather`: the
# old `weather` app keeps logging its London history every hour, and mixing a
# Cambridge reading into that source would corrupt the History tab.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';
no warnings 'once';

use Mojo::JSON qw(decode_json encode_json);
use Mojo::UserAgent;
use Mojo::Util qw(md5_sum);

our $log;

# ---- the condition rules ----------------------------------------------------
sub weather_automation_app() {
	return 'weather_station';
}

# The rule list the automation engine reads. A blank row is the configure
# page's "add a rule" placeholder, not a rule: it would never match and is
# better kept out of the state the app shows.
sub weather_automation_rules($app_measures) {
	my $am = ref $app_measures eq 'HASH'
		? $app_measures
		: (eval { decode_json($app_measures // '') } || {});
	my $condition = ref $am->{'condition'} eq 'HASH' ? $am->{'condition'} : {};
	my $cms = ref $condition->{'cm'} eq 'ARRAY' ? $condition->{'cm'} : [];
	my @rules = grep {
		ref $_ eq 'HASH' && length($_->{'match'} // '') && length($_->{'app'} // '')
	} @{$cms};
	return \@rules;
}

sub weather_automation_normalize($rule) {
	return undef unless ref $rule eq 'HASH';
	my $match_text = $rule->{'match'} // '';
	$match_text =~ s/^\s+|\s+$//g;
	# The engine compares the stored state, which appt_measure_writer ran through
	# unformat_name, so a person's "light rain" must read light_rain here too.
	my $match = &subs::unformat_name($match_text);
	my $app = &subs::unformat_name($rule->{'app'} // '');
	return undef unless length $match && length $app;
	my $action = lc($rule->{'action'} // '');
	$action = 'start' unless $action eq 'start' || $action eq 'record';
	my $uuid = $rule->{'uuid'} // '';
	$uuid = &subs::random_string_creator(22) unless $uuid =~ /^[A-Za-z0-9_-]{6,}$/;
	return {
		uuid => $uuid,
		type => 'match',
		match => $match,
		app => $app,
		action => $action,
		location => &weather_rule_location_normalize($rule->{'location'}),
	};
}

# Add, replace by uuid, or remove a rule. A remove names its uuid; anything
# else is a save and answers undef when it has no condition or app to work on.
sub weather_automation_apply($rules, $rule) {
	my @out = map { { %{$_} } } grep { ref $_ eq 'HASH' } @{ ref $rules eq 'ARRAY' ? $rules : [] };
	return undef unless ref $rule eq 'HASH';
	my $uuid = $rule->{'uuid'} // '';
	if ($rule->{'remove'}) {
		@out = grep { ($_->{'uuid'} // '') ne $uuid } @out;
		return \@out;
	}
	my $clean = &weather_automation_normalize($rule);
	return undef unless $clean;
	my $found = 0;
	foreach my $r (@out) {
		next unless ($r->{'uuid'} // '') eq $clean->{'uuid'};
		%{$r} = %{$clean};
		$found = 1;
	}
	push @out, $clean unless $found;
	return \@out;
}

# Which condition rules the condition wakes. appt_measure_writer stores a text
# measure through unformat_name ("Light Rain" -> "light_rain"), so match the
# same shape here; the engine's own test is a case-insensitive substring.
sub weather_automation_matches($rules, $condition, $location = '') {
	my $state = lc(&subs::unformat_name($condition // ''));
	my $want_location = $location // '';
	my @hit;
	foreach my $r (@{ ref $rules eq 'ARRAY' ? $rules : [] }) {
		next unless ref $r eq 'HASH';
		my $rule_location = $r->{'location'} // '';
		next if length $rule_location && $rule_location ne $want_location;
		my $match = lc($r->{'match'} // '');
		next unless length $match && index($state, $match) >= 0;
		push @hit, { app => $r->{'app'}, action => $r->{'action'} || 'start' };
	}
	return \@hit;
}

# ---- the measures the observer writes ---------------------------------------
# The station's app_measures carries these definitions so appt_measure_writer
# knows how to normalize each value and so a rule can name a measure, its type
# and its unit without another table.
sub weather_measure_definitions() {
	return {
		condition      => { type => 'text' },
		temperature    => { type => 'number', unit => 'C' },
		feels_like     => { type => 'number', unit => 'C' },
		humidity       => { type => 'number', unit => '%' },
		wind           => { type => 'number', unit => 'km/h' },
		wind_gust      => { type => 'number', unit => 'km/h' },
		wind_direction => { type => 'text' },
		pressure       => { type => 'number', unit => 'kPa' },
		visibility     => { type => 'number', unit => 'km' },
		dew_point      => { type => 'number', unit => 'C' },
		uv             => { type => 'number' },
	};
}

sub weather_measure_catalog() {
	my @points = qw(N NNE NE ENE E ESE SE SSE S SSW SW WSW W WNW NW NNW);
	return [
		{ key => 'wind_gust', label => 'Wind gust', unit => 'km/h', type => 'number', ops => [qw(> >= < <= == !=)] },
		{ key => 'wind', label => 'Wind speed', unit => 'km/h', type => 'number', ops => [qw(> >= < <= == !=)] },
		{ key => 'wind_direction', label => 'Wind direction', unit => '', type => 'direction', ops => ['from'], points => \@points },
		{ key => 'pressure', label => 'Pressure', unit => 'kPa', type => 'number', ops => [qw(> >= < <= == !=)] },
		{ key => 'temperature', label => 'Temperature', unit => '°C', type => 'number', ops => [qw(> >= < <= == !=)] },
		{ key => 'feels_like', label => 'Feels like', unit => '°C', type => 'number', ops => [qw(> >= < <= == !=)] },
		{ key => 'humidity', label => 'Humidity', unit => '%', type => 'number', ops => [qw(> >= < <= == !=)] },
		{ key => 'visibility', label => 'Visibility', unit => 'km', type => 'number', ops => [qw(> >= < <= == !=)] },
		{ key => 'dew_point', label => 'Dew point', unit => '°C', type => 'number', ops => [qw(> >= < <= == !=)] },
		{ key => 'uv', label => 'UV index', unit => '', type => 'number', ops => [qw(> >= < <= == !=)] },
		{ key => 'condition', label => 'Condition', unit => '', type => 'text', ops => [qw(is contains)] },
	];
}

sub weather_measure_values($weather) {
	my $cur = ref $weather eq 'HASH' ? ($weather->{'current'} || {}) : {};
	my %v;
	my $condition = $cur->{'condition'};
	$v{'condition'} = &subs::unformat_name($condition) if defined $condition && length $condition;
	foreach my $pair (
		['temperature', 'temperature'], ['feels_like', 'feels_like'],
		['humidity', 'humidity'], ['wind', 'wind_speed'],
		['wind_gust', 'wind_gust'], ['visibility', 'visibility'],
		['dew_point', 'dew_point'], ['uv', 'uv'],
	) {
		my $n = &subs::weather_number($cur->{ $pair->[1] });
		$v{ $pair->[0] } = $n if defined $n;
	}
	my $direction = $cur->{'wind_direction'};
	$v{'wind_direction'} = &subs::unformat_name($direction) if defined $direction && length $direction;
	my $pressure = &subs::weather_pressure_kpa($cur->{'pressure'}, $cur->{'pressure_unit'});
	$v{'pressure'} = $pressure if defined $pressure;
	return \%v;
}

# ---- the measurement rules --------------------------------------------------
sub weather_measure_rules() {
	my $raw = eval {
		decode_json(&subs::setting_grabber({ app => &weather_automation_app(), setting => 'weather_rules' }) // '');
	};
	return ref $raw eq 'ARRAY' ? [ grep { ref $_ eq 'HASH' } @{$raw} ] : [];
}

sub weather_measure_rule_normalize($rule) {
	return undef unless ref $rule eq 'HASH';
	my %catalog = map { $_->{'key'} => $_ } @{ &weather_measure_catalog() };
	my @when;
	foreach my $condition (@{ ref $rule->{'when'} eq 'ARRAY' ? $rule->{'when'} : [] }) {
		next unless ref $condition eq 'HASH';
		my $def = $catalog{ $condition->{'measure'} // '' } or next;
		my $op = $condition->{'op'} // '';
		next unless grep { $_ eq $op } @{ $def->{'ops'} || [] };
		my $value;
		if ($def->{'type'} eq 'direction') {
			my $wanted = uc($condition->{'value'} // '');
			next unless grep { $_ eq $wanted } @{ $def->{'points'} || [] };
			$value = &subs::unformat_name($wanted);
		}
		elsif ($def->{'type'} eq 'text') {
			$value = &subs::unformat_name($condition->{'value'} // '');
			next unless length $value;
		}
		else {
			my $number = &subs::weather_number($condition->{'value'});
			next unless defined $number;
			$value = $number;
		}
		push @when, { measure => $def->{'key'}, op => $op, value => $value };
	}
	return undef unless @when;
	my $for_ms = 0;
	if (defined $rule->{'for_ms'} && "$rule->{'for_ms'}" =~ /^\d+$/) {
		$for_ms = 0 + $rule->{'for_ms'};
		# A window longer than a month would scan the whole record for no reason.
		$for_ms = 30 * 24 * 60 * 60 * 1000 if $for_ms > 30 * 24 * 60 * 60 * 1000;
	}
	my $action = lc($rule->{'action'} // '');
	$action = 'start' unless $action eq 'start' || $action eq 'stop' || $action eq 'run';
	my $app = &subs::unformat_name($rule->{'app'} // '');
	my $command = $rule->{'command'} // '';
	$command =~ s/^\s+|\s+$//g;
	return undef if $action eq 'run' && !length $command;
	return undef if $action ne 'run' && !length $app;
	my $uuid = $rule->{'uuid'} // '';
	$uuid = &subs::random_string_creator(22) unless $uuid =~ /^[A-Za-z0-9_-]{6,}$/;
	my $name = $rule->{'name'} // '';
	$name =~ s/^\s+|\s+$//g;
	$name = substr($name, 0, 80);
	return {
		uuid => $uuid,
		name => $name,
		when => \@when,
		for_ms => $for_ms,
		action => $action,
		app => $app,
		command => $command,
		location => &weather_rule_location_normalize($rule->{'location'}),
	};
}

sub weather_measure_rule_apply($rules, $rule) {
	my @out = map { { %{$_} } } grep { ref $_ eq 'HASH' } @{ ref $rules eq 'ARRAY' ? $rules : [] };
	return undef unless ref $rule eq 'HASH';
	my $uuid = $rule->{'uuid'} // '';
	if ($rule->{'remove'}) {
		@out = grep { ($_->{'uuid'} // '') ne $uuid } @out;
		return \@out;
	}
	my $clean = &weather_measure_rule_normalize($rule);
	return undef unless $clean;
	my $found = 0;
	foreach my $r (@out) {
		next unless ($r->{'uuid'} // '') eq $clean->{'uuid'};
		%{$r} = %{$clean};
		$found = 1;
	}
	push @out, $clean unless $found;
	return \@out;
}

sub weather_measure_rule_save($rule, $opts = {}) {
	my $rules = &weather_measure_rule_apply(&weather_measure_rules(), $rule);
	return { error => &subs::ui('A measurement rule needs at least one complete condition and an action.') }
		unless $rules;
	&subs::setting_setter({
		app => &weather_automation_app(),
		setting => 'weather_rules',
		value => encode_json $rules,
	});
	return &weather_automation_state($opts || {});
}

# ---- reading a rule's conditions -------------------------------------------
sub weather_compass_from($have, $want) {
	my $got = uc($have // '');
	my $wanted = uc($want // '');
	return 0 unless length $got && length $wanted;
	return 1 if $got eq $wanted;
	# A main compass point means the 45-degree sector around it, so "from the
	# North" answers N, NNE and NNW rather than only the exact tick.
	my %sector = (
		N  => [qw(N NNE NNW)],  NE => [qw(NE NNE ENE)],
		E  => [qw(E ENE ESE)],  SE => [qw(SE ESE SSE)],
		S  => [qw(S SSE SSW)],  SW => [qw(SW SSW WSW)],
		W  => [qw(W WSW WNW)],  NW => [qw(NW WNW NNW)],
	);
	foreach my $point (@{ $sector{$wanted} || [] }) {
		return 1 if $got eq $point;
	}
	return 0;
}

sub weather_rule_condition_match($condition, $values) {
	return 0 unless ref $condition eq 'HASH' && ref $values eq 'HASH';
	my $have = $values->{ $condition->{'measure'} // '' };
	return 0 unless defined $have && length $have;
	my $op = $condition->{'op'} // '';
	my $wanted = $condition->{'value'};
	if ($op eq 'is') {
		return lc($have) eq lc($wanted // '') ? 1 : 0;
	}
	if ($op eq 'contains') {
		return index(lc($have), lc($wanted // '')) >= 0 ? 1 : 0;
	}
	if ($op eq 'from') {
		return &weather_compass_from($have, $wanted);
	}
	my $a = &subs::weather_number($have);
	my $b = &subs::weather_number($wanted);
	return 0 unless defined $a && defined $b;
	return $a > $b  ? 1 : 0 if $op eq '>';
	return $a >= $b ? 1 : 0 if $op eq '>=';
	return $a < $b  ? 1 : 0 if $op eq '<';
	return $a <= $b ? 1 : 0 if $op eq '<=';
	return $a == $b ? 1 : 0 if $op eq '==';
	return $a != $b ? 1 : 0 if $op eq '!=';
	return 0;
}

# A rule that must hold for a while is true only when every reading in the
# window satisfies it and the oldest reading covers the window. A gap is not a
# violation, but a window with no reading at its start cannot prove the span,
# so it waits rather than firing early.
sub weather_rule_held($series, $condition, $for_ms, $now) {
	return 0 unless $for_ms > 0;
	my $from = $now - $for_ms;
	my @window = grep {
		ref $_ eq 'HASH' && ($_->{'ts'} || 0) >= $from - 60_000 && ($_->{'ts'} || 0) <= $now + 60_000
	} @{ ref $series eq 'ARRAY' ? $series : [] };
	return 0 unless @window;
	my ($oldest) = sort { ($a->{'ts'} || 0) <=> ($b->{'ts'} || 0) } @window;
	return 0 unless ($oldest->{'ts'} || 0) <= $from + 10 * 60 * 1000;
	foreach my $reading (@window) {
		return 0 unless &weather_rule_condition_match($condition, $reading->{'values'});
	}
	return 1;
}

sub weather_rule_matches($rule, $values, $series, $now) {
	return 0 unless ref $rule eq 'HASH';
	my $conditions = ref $rule->{'when'} eq 'ARRAY' ? $rule->{'when'} : [];
	return 0 unless @{$conditions};
	my $for_ms = $rule->{'for_ms'} || 0;
	foreach my $condition (@{$conditions}) {
		if ($for_ms > 0) {
			return 0 unless &weather_rule_held($series, $condition, $for_ms, $now);
		}
		else {
			return 0 unless &weather_rule_condition_match($condition, $values);
		}
	}
	return 1;
}

# The station's own readings, merged by the minute: the writer appends one
# measure entry per key at nearly the same time, and the first write stamps the
# appointment with rightNow() while the rest carry the observation's timestamp.
# A minute is finer than the half-hour cadence and always keeps one observation
# together.
sub weather_observation_series($app, $from, $to, $location = '') {
	my $want_location = $location // '';
	my $rows = eval {
		&subs::db_query(
			'select timestamp, measures from appointments '
			. 'where app = ? and measures is not null and cast(timestamp as integer) >= ? '
			. 'order by cast(timestamp as integer) asc',
			$app, $from
		)->hashes;
	} || [];
	my %by;
	foreach my $row (@{$rows}) {
		my $base = $row->{'timestamp'};
		my $list = eval { decode_json($row->{'measures'} // '[]') } || [];
		next unless ref $list eq 'ARRAY';
		foreach my $measure (@{$list}) {
			next unless ref $measure eq 'HASH';
			next if length($want_location) && ($measure->{'location'} // '') ne $want_location;
			my $ts = $measure->{'ts'} || $base;
			next unless defined $ts && "$ts" =~ /^\d+$/;
			next if $to && $ts > $to + 60_000;
			my $bucket = int($ts / 60000);
			$by{$bucket}{'__ts'} = $ts + 0;
			foreach my $key (keys %{$measure}) {
				next if $key eq 'ts' || $key eq 'uuid' || $key eq 'location';
				$by{$bucket}{$key} = $measure->{$key};
			}
		}
	}
	return [ map {
		my $entry = $by{$_};
		my %values = map { $_ => $entry->{$_} } grep { $_ ne '__ts' } keys %{$entry};
		{ ts => $entry->{'__ts'}, values => \%values };
	} sort { $a <=> $b } keys %by ];
}

# ---- acting on a measurement rule ------------------------------------------
sub weather_rule_app_switch($app, $on, $source_uuid, $timestamp, $warranty = '') {
	return 0 unless defined $app && length $app;
	$timestamp ||= &rightNow();
	$warranty = '' unless defined $warranty;
	my $toggle = &subs::setting_grabber({ app => $app, setting => 'toggle' });
	$toggle = 'off' unless defined $toggle && length $toggle;
	if ($on && $toggle ne 'on') {
		&subs::setting_setter({ app => $app, setting => 'toggle', value => 'on', timestamp => $timestamp });
		# The toggle is a setting per machine, but the appointments are the house's
		# one record. A second weather screen must not start an app that is already
		# running here, so a start also waits for no open session for the app.
		my $open = eval { &subs::open_session_uuid($app) } || '';
		unless ($open) {
			eval {
				&Manager::appointment_writer(undef, {
					app => $app,
					timestamp => $timestamp,
					type => 'start',
					source_uuid => $source_uuid,
					subtype => 'measure',
					(length $warranty ? (warranty => $warranty) : ()),
				});
			};
			$log->warn('weather rule: could not start ' . $app . ': ' . $@) if $log && $@;
		}
		return 1;
	}
	if (!$on && $toggle eq 'on') {
		eval {
			&Manager::appointment_writer(undef, {
				app => $app,
				timestamp => $timestamp,
				type => 'stop',
				source_uuid => $source_uuid,
				subtype => 'measure',
				(length $warranty ? (warranty => $warranty) : ()),
			});
		};
		&subs::setting_setter({ app => $app, setting => 'toggle', value => 'off', timestamp => $timestamp });
		$log->warn('weather rule: could not stop ' . $app . ': ' . $@) if $log && $@;
		return 1;
	}
	return 0;
}

# A rule acts on its rising edge. A start rule also stops its app on the falling
# edge, which is what makes "rain -> raining" start and stop; a run rule fires
# once and waits for the condition to clear before it can fire again.
sub weather_measure_rule_evaluate($values, $series, $uuid, $now, $location = '', $warranty = '') {
	my $rules = &weather_measure_rules();
	return [] unless @{$rules};
	my $want_location = $location // '';
	my $state = eval { &cache_get({ app => 'weather', context => 'rules', subcontext => 'state' }) } || {};
	my %live = map { ($_->{'uuid'} // '') => 1 } @{$rules};
	my @fired;
	foreach my $rule (@{$rules}) {
		next unless ref $rule eq 'HASH';
		my $rule_location = &weather_rule_location_normalize($rule->{'location'});
		next if length($rule_location) && $rule_location ne $want_location;
		my $id = $rule->{'uuid'} // '';
		next unless length $id;
		my $matched = &weather_rule_matches($rule, $values, $series, $now) ? 1 : 0;
		my $previous = $state->{$id} && $state->{$id}{'matched'} ? 1 : 0;
		my $action = $rule->{'action'} || 'start';
		if ($matched && !$previous) {
			if ($action eq 'run') {
				my $ok = eval { &subs::run_command(&weather_automation_app(), $rule->{'command'}, $now); 1 };
				$log->warn('weather rule: command failed: ' . $@) if $log && $@;
				push @fired, { uuid => $id, name => $rule->{'name'} || '', action => 'run', ok => $ok ? 1 : 0 };
			}
			elsif ($action eq 'stop') {
				push @fired, { uuid => $id, name => $rule->{'name'} || '', action => 'stop', app => $rule->{'app'}, ok => &weather_rule_app_switch($rule->{'app'}, 0, $uuid, $now, $warranty) };
			}
			else {
				push @fired, { uuid => $id, name => $rule->{'name'} || '', action => 'start', app => $rule->{'app'}, ok => &weather_rule_app_switch($rule->{'app'}, 1, $uuid, $now, $warranty) };
			}
		}
		elsif (!$matched && $previous && $action eq 'start') {
			push @fired, { uuid => $id, name => $rule->{'name'} || '', action => 'stop', app => $rule->{'app'}, ok => &weather_rule_app_switch($rule->{'app'}, 0, $uuid, $now, $warranty) };
		}
		$state->{$id} = { matched => $matched, at => $now };
	}
	$state = { map { $_ => $state->{$_} } grep { $live{$_} } keys %{$state} };
	eval { &cache_set({ app => 'weather', context => 'rules', subcontext => 'state', warranty => '-30d' }, $state) };
	return \@fired;
}

# ---- the rules' home --------------------------------------------------------
# The first read carries the old app's rules over. `weather` keeps its hourly
# readings for the History tab, but its rules are cleared so the London page
# cannot start or stop an app for a condition the house does not have.
sub weather_observe_prepare() {
	my $app = &weather_automation_app();
	my $own = eval { decode_json(&subs::setting_grabber({ app => $app, setting => 'app_measures' }) // '') } || {};
	my $changed = 0;
	unless (ref $own->{'condition'} eq 'HASH') {
		my $source = eval { decode_json(&subs::setting_grabber({ app => 'weather', setting => 'app_measures' }) // '') } || {};
		my $rules = &weather_automation_rules($source);
		$own = {
			condition => {
				type => 'text',
				value => ($source->{'condition'}->{'value'} // ''),
				cm => $rules,
			},
		};
		my $seen = eval { decode_json(&subs::setting_grabber({ app => 'weather', setting => 'seen_measures' }) // '') };
		if (ref $seen eq 'ARRAY' && @{$seen}) {
			&subs::setting_setter({ app => $app, setting => 'seen_measures', value => encode_json $seen });
		}
		if (@{$rules}) {
			$source->{'condition'}->{'cm'} = [];
			&subs::setting_setter({ app => 'weather', setting => 'app_measures', value => encode_json $source });
		}
		$changed = 1;
	}
	my $definitions = &weather_measure_definitions();
	foreach my $key (keys %{$definitions}) {
		next if ref $own->{$key} eq 'HASH';
		$own->{$key} = { %{ $definitions->{$key} } };
		$changed = 1;
	}
	&subs::setting_setter({ app => $app, setting => 'app_measures', value => encode_json $own }) if $changed;
	return $own;
}

# The rules carried over from the old weather app, and every rule added before
# the tab was per-place, named no place and so acted on a reading anywhere. They
# are the home's rules: pin each to the saved place at the home plate, once per
# machine, so every machine at home shows and runs the same list. A rule that
# already names a place is left alone; after this pass a person can still choose
# Any location for a rule meant for the whole house. Returns false until a home
# place exists, so the backfill retries on a later pass.
sub weather_automation_adopt_home() {
	my $home = &weather_home_place({ create => 1 });
	my $uuid = ref $home eq 'HASH' ? ($home->{'uuid'} // '') : '';
	return 0 unless $uuid =~ /^[A-Za-z0-9_-]+$/;
	my $key = 'loc:' . $uuid;
	my $am = &weather_observe_prepare();
	my $changed = 0;
	my $cms = ref $am->{'condition'} eq 'HASH' && ref $am->{'condition'}{'cm'} eq 'ARRAY'
		? $am->{'condition'}{'cm'} : [];
	foreach my $rule (@{$cms}) {
		next unless ref $rule eq 'HASH';
		next unless length($rule->{'match'} // '') && length($rule->{'app'} // '');
		next if length &weather_rule_location_normalize($rule->{'location'});
		$rule->{'location'} = $key;
		$changed++;
	}
	if ($changed) {
		&subs::setting_setter({ app => &weather_automation_app(), setting => 'app_measures', value => encode_json $am });
	}
	my $measure_rules = &weather_measure_rules();
	my $moved = 0;
	foreach my $rule (@{$measure_rules}) {
		next unless ref $rule eq 'HASH';
		next if length &weather_rule_location_normalize($rule->{'location'});
		$rule->{'location'} = $key;
		$moved++;
	}
	if ($moved) {
		&subs::setting_setter({ app => &weather_automation_app(), setting => 'weather_rules', value => encode_json $measure_rules });
	}
	return 1;
}

# The place the toolbar's choice names, for the Automations tab. A saved place
# is itself. A machine is the saved place it is standing on when that place is
# anchored or a rule names it - the same place the observer records the reading
# as - and otherwise the machine itself.
sub weather_automation_view_location($opts = {}) {
	$opts ||= {};
	my $device = $opts->{'device'} // 'me';
	return $device if $device =~ /^loc:[A-Za-z0-9_-]+$/;
	my $sig = $device eq 'me' ? &subs::signatorial_designer() : $device;
	return '' unless defined $sig && $sig =~ /^[A-Za-z0-9_-]+$/;
	my $key = 'dev:' . $sig;
	my ($lat, $lon) = ($opts->{'lat'}, $opts->{'lon'});
	unless (defined $lat && defined $lon && "$lat" =~ /^-?\d/ && "$lon" =~ /^-?\d/) {
		my $fix = eval { &subs::weather_device_fix($sig) };
		($lat, $lon) = ($fix->{'lat'}, $fix->{'lon'}) if $fix;
	}
	return $key unless defined $lat && defined $lon;
	my $place = &weather_location_for_fix($lat, $lon, '', {});
	return $key unless $place && ($place->{'uuid'} // '') =~ /^[A-Za-z0-9_-]+$/;
	my $place_key = 'loc:' . $place->{'uuid'};
	return $place_key if $place->{'anchor'};
	my $am = eval { decode_json(&subs::setting_grabber({ app => &weather_automation_app(), setting => 'app_measures' }) // '') } || {};
	foreach my $rule (@{ &weather_automation_rules($am) }, @{ &weather_measure_rules() }) {
		next unless ref $rule eq 'HASH';
		return $place_key if &weather_rule_location_normalize($rule->{'location'}) eq $place_key;
	}
	return $key;
}

# `device`/`lat`/`lon` scope the tab to the location the toolbar shows; a
# resolved `location` does the same for a caller that already has the key. With
# neither, the state is the whole rule list as before. A rule for Any location
# applies wherever you look, so it stays in every view.
sub weather_automation_state($opts = {}) {
	$opts ||= {};
	my $view = '';
	if (defined $opts->{'device'} && length $opts->{'device'}) {
		$view = &weather_automation_view_location({
			device => $opts->{'device'},
			(defined $opts->{'lat'} ? (lat => $opts->{'lat'}) : ()),
			(defined $opts->{'lon'} ? (lon => $opts->{'lon'}) : ()),
		});
	}
	elsif (defined $opts->{'location'} && length $opts->{'location'}) {
		$view = &weather_rule_location_normalize($opts->{'location'});
	}
	my $show = sub {
		my ($where) = @_;
		return 1 unless length $view;
		$where = &weather_rule_location_normalize($where);
		return 1 unless length $where;
		return $where eq $view ? 1 : 0;
	};
	my $am = &weather_observe_prepare();
	my $app = &weather_automation_app();
	my $rules = &weather_automation_rules($am);
	my $measure_rules = &weather_measure_rules();
	my $seen = eval { decode_json(&subs::setting_grabber({ app => $app, setting => 'seen_measures' }) // '') } || [];
	# The station also stores compass points (wind direction is a text measure);
	# they are not conditions and would clutter the condition picker.
	my %compass = map { $_ => 1 } qw(n nne ne ene e ese se sse s ssw sw wsw w wnw nw nnw);
	my @conditions = grep { !$compass{$_} } @{ ref $seen eq 'ARRAY' ? $seen : [] };
	my $last = eval { &cache_get({ app => 'weather', context => 'observe', subcontext => 'last' }) } || {};
	my $locations = &weather_location_options();
	my $location_label = &weather_location_label_map();
	# A person starts an app by name, so suggest the house's app catalog and the
	# apps its rules already name. The settings table also holds one-off names
	# (shopping items, photo files); offering its 2,000 rows would bury the app
	# they want and bloat every refresh of this tab.
	my (%seen_app, @app_options);
	my $add_app = sub {
		my $name = shift // '';
		return unless length $name && $name !~ /^__/ && !$seen_app{$name}++;
		push @app_options, { key => $name, label => &subs::format_name($name) };
	};
	$add_app->($_) for sort keys %{ $gb::known_appts || {} };
	$add_app->($_->{'app'}) for grep { ref $_ eq 'HASH' } @{$rules};
	$add_app->($_->{'app'}) for grep { ref $_ eq 'HASH' } @{$measure_rules};
	@app_options = sort { $a->{'label'} cmp $b->{'label'} } @app_options;
	return {
		app => $app,
		condition => ($am->{'condition'}->{'value'} // ''),
		condition_text => &subs::format_name($am->{'condition'}->{'value'} // ''),
		condition_at => $last->{'at'},
		condition_changed_at => $last->{'changed_at'},
		condition_place => $last->{'place'} // '',
		condition_location => $last->{'location'} // '',
		seen => [ sort @conditions ],
		rules => [
			map {
				my $loc = $_->{'location'} // '';
				+{ %{$_}, app_label => &subs::format_name($_->{'app'}),
					location_label => (length $loc ? ($location_label->{$loc} || ($loc =~ /^loc:/ ? &subs::ui('Deleted place') : $loc)) : '') }
			} grep { $show->($_->{'location'}) } @{$rules}
		],
		measures => &weather_measure_catalog(),
		values => ($last->{'values'} || {}),
		measure_rules => [
			map {
				my %r = %{$_};
				my $loc = $_->{'location'} // '';
				$r{'app_label'} = &subs::format_name($_->{'app'}) if length($_->{'app'} // '');
				$r{'location_label'} = length $loc ? ($location_label->{$loc} || ($loc =~ /^loc:/ ? &subs::ui('Deleted place') : $loc)) : '';
				\%r;
			} grep { $show->($_->{'location'}) } @{$measure_rules}
		],
		view_location => $view,
		locations => $locations,
		apps => \@app_options,
	};
}

sub weather_automation_save($rule, $opts = {}) {
	my $am = &weather_observe_prepare();
	my $rules = &weather_automation_apply($am->{'condition'}->{'cm'} || [], $rule);
	return { error => &subs::ui('A rule needs a condition and an app.') } unless $rules;
	$am->{'condition'}->{'cm'} = $rules;
	&subs::setting_setter({
		app => &weather_automation_app(),
		setting => 'app_measures',
		value => encode_json $am,
	});
	return &weather_automation_state($opts || {});
}

# ---- locations --------------------------------------------------------------
# A rule names where it applies: the phone, another machine, or a saved place.
# `dev:<signatorial>` is a machine's own GPS fix; `loc:<uuid>` is a saved point.
# An empty location is the old app's global rule and evaluates anywhere.
sub weather_rule_location_normalize($value) {
	$value = '' unless defined $value;
	return '' unless length $value;
	return $value if $value =~ /^(?:dev|loc):[A-Za-z0-9_-]+$/;
	return '';
}

sub weather_location_options() {
	my @out = ({ key => '', label => 'Any location' });
	my $fixes = eval { &subs::weather_device_fixes(24 * 60 * 60 * 1000) } || [];
	foreach my $group (@{ &weather_place_groups($fixes) }) {
		push @out, { key => 'dev:' . $group->{'signatorial'}, label => $group->{'label'} };
	}
	my $labels = &weather_location_labels();
	foreach my $loc (@{ &weather_locations() }) {
		my $uuid = $loc->{'uuid'} // '';
		next unless $uuid =~ /^[A-Za-z0-9_-]+$/;
		push @out, { key => "loc:$uuid", label => $labels->{$uuid} };
	}
	return \@out;
}

# ---- place names ------------------------------------------------------------
# A coordinate is not a name. The weather provider answers with the city it is
# reading for, so keep those answers: the picker and the rule sentences show
# `Kitchener`, not 43.4500, -80.4900. The cache is by hundredth of a degree,
# the same ground the forecast cache covers.
sub weather_name_is_coordinate($name) {
	return 0 unless defined $name && length $name;
	return $name =~ /-?\d+\.\d+\s*,\s*-?\d+\.\d+\s*$/ ? 1 : 0;
}

sub weather_place_names() {
	my $raw = eval { decode_json(&subs::setting_grabber({ app => 'weather', setting => 'place_names' }) // '') };
	return ref $raw eq 'HASH' ? $raw : {};
}

sub weather_place_name($lat, $lon) {
	return '' unless defined $lat && defined $lon;
	my $names = &weather_place_names();
	return $names->{ sprintf('%.2f,%.2f', $lat, $lon) } // '';
}

sub weather_place_name_remember($lat, $lon, $name) {
	return 0 unless defined $lat && defined $lon && defined $name;
	$name = "$name";
	$name =~ s/^\s+|\s+$//g;
	return 0 unless length $name && length $name <= 80;
	return 0 if &weather_name_is_coordinate($name);
	my $names = &weather_place_names();
	my $key = sprintf('%.2f,%.2f', $lat, $lon);
	return 0 if ($names->{$key} // '') eq $name;
	$names->{$key} = $name;
	&subs::setting_setter({ app => 'weather', setting => 'place_names', value => encode_json $names });
	return 1;
}

# Ask the provider what the place is called. Environment Canada has a cheap city
# search, so that is the page-render path; the other services only name the place
# in a full forecast, which `fetch` allows for a save the person is waiting on.
sub weather_place_misses() {
	my $raw = eval { decode_json(&subs::setting_grabber({ app => 'weather', setting => 'place_misses' }) // '') };
	return ref $raw eq 'HASH' ? $raw : {};
}

sub weather_place_miss_remember($lat, $lon) {
	return 0 unless defined $lat && defined $lon;
	my $misses = &weather_place_misses();
	$misses->{ sprintf('%.2f,%.2f', $lat, $lon) } = &rightNow();
	&subs::setting_setter({ app => 'weather', setting => 'place_misses', value => encode_json $misses });
	return 1;
}

sub weather_place_lookup($lat, $lon, $opts = {}) {
	return '' unless defined $lat && defined $lon;
	my $known = &weather_place_name($lat, $lon);
	return $known if length $known;
	# A place that failed is not asked again for six hours, so a page render or an
	# observation never waits twice. Only a save the person is waiting on retries.
	# The miss is per place: a saved point in a country without a cheap name
	# lookup must not close the door on the others.
	unless ($opts->{'retry'}) {
		my $misses = &weather_place_misses();
		my $miss = $misses->{ sprintf('%.2f,%.2f', $lat, $lon) } || 0;
		return '' if $miss && $miss > &rightNow() - 6 * 3600 * 1000;
	}
	my $name = '';
	my $provider = eval { &subs::weather_provider_for($lat, $lon) } || '';
	if ($provider eq 'ec') {
		my $ua = Mojo::UserAgent->new(connect_timeout => 4, inactivity_timeout => 6, request_timeout => 8);
		$ua->insecure(1);
		my $city = eval { &subs::weather_ec_find_city($lat, $lon, $ua) };
		$name = ($city && $city->{'name'}) ? $city->{'name'} : '';
		$log->info("weather place: no city for $lat,$lon") if $log && !length $name;
	}
	elsif ($opts->{'fetch'}) {
		# The National Weather Service names its city in the forecast; anywhere
		# else Open-Meteo names nothing, so ask a reverse geocoder.
		my $weather = eval { &subs::weather_fetch($lat, $lon) };
		$name = ($weather && !$weather->{'error'}) ? ($weather->{'location_name'} // '') : '';
		$name = &subs::weather_reverse_geocode($lat, $lon) unless length $name;
	}
	else {
		$name = &subs::weather_reverse_geocode($lat, $lon);
	}
	$name =~ s/^\s+|\s+$//g;
	if (length $name) {
		&weather_place_name_remember($lat, $lon, $name);
	}
	else {
		&weather_place_miss_remember($lat, $lon);
	}
	return $name;
}

# Machines at one place are one entry in the picker: they see the same weather.
# A group keeps the current machine first (the fixes are sorted that way), so the
# key is stable for the house's own device, and every device in it is listed by
# the group's `devices_text` for the tooltip.
sub weather_place_groups($fixes) {
	my $me = &subs::signatorial_designer();
	my @groups;
	foreach my $fix (@{ ref $fixes eq 'ARRAY' ? $fixes : [] }) {
		next unless ref $fix eq 'HASH';
		my $sig = $fix->{'signatorial'} // '';
		next unless $sig =~ /^[A-Za-z0-9_-]+$/;
		my ($lat, $lon) = ($fix->{'lat'}, $fix->{'lon'});
		next unless defined $lat && defined $lon;
		# Five kilometres is one place to the weather: a phone in the yard and a
		# laptop indoors share the forecast, while the cottage does not.
		my $group;
		foreach my $candidate (@groups) {
			next unless &subs::weather_distance_km($lat, $lon, $candidate->{'lat'}, $candidate->{'lon'}) <= 5;
			$group = $candidate;
			last;
		}
		if (!$group) {
			$group = {
				key => sprintf('%.3f,%.3f', $lat, $lon), lat => $lat, lon => $lon,
				signatorial => $sig, seen => 0, me => 0, devices => [],
			};
			push @groups, $group;
		}
		my $label = $sig eq $me ? &subs::ui('This device') : &subs::format_name($fix->{'label'} || $sig);
		push @{$group->{'devices'}}, { signatorial => $sig, label => $label };
		$group->{'me'} = 1 if $sig eq $me;
		$group->{'seen'} = $fix->{'seen'} if ($fix->{'seen'} || 0) > ($group->{'seen'} || 0);
		$group->{'primary_label'} //= $label;
	}
	foreach my $group (@groups) {
		my $place = &weather_place_name($group->{'lat'}, $group->{'lon'});
		$group->{'place'} = $place;
		$group->{'label'} = length $place
			? $place
			: ($group->{'me'} ? &subs::ui('This device') : $group->{'primary_label'});
		$group->{'devices_text'} = join(', ', map { $_->{'label'} } @{$group->{'devices'}});
	}
	return \@groups;
}

# The display name of each saved place. A place saved without a name keeps a
# coordinate in storage (so a second save on the same ground still finds it), but
# nobody should read that: use the provider's name, and number the nameless.
sub weather_location_labels() {
	my (%out, $n);
	$n = 0;
	foreach my $loc (@{ &weather_locations() }) {
		my $uuid = $loc->{'uuid'} // '';
		next unless length $uuid;
		my $name = $loc->{'name'} // '';
		if (&weather_name_is_coordinate($name)) {
			$name = &weather_place_name($loc->{'lat'}, $loc->{'lon'});
		}
		$name = &subs::format_name($name) if length $name;
		if (!length $name) {
			$n++;
			$name = &subs::ui('Saved location') . ' ' . $n;
		}
		$out{$uuid} = $name;
	}
	return \%out;
}

# Every key a rule can hold, so a rule pinned to a device that is no longer the
# group's first still reads as its place.
sub weather_location_label_map() {
	my %out;
	my $fixes = eval { &subs::weather_device_fixes(24 * 60 * 60 * 1000) } || [];
	foreach my $group (@{ &weather_place_groups($fixes) }) {
		$out{ 'dev:' . $_->{'signatorial'} } = $group->{'label'} foreach @{$group->{'devices'}};
	}
	my $labels = &weather_location_labels();
	$out{"loc:$_"} = $labels->{$_} for keys %{$labels};
	return \%out;
}

# Name a saved place whose stored name is only a coordinate. Run once when the
# page opens: Environment Canada answers in one request and the answer is kept,
# so this is silent after the first time.
sub weather_location_name_repair() {
	my $fixed = 0;
	foreach my $loc (@{ &weather_locations() }) {
		next unless &weather_name_is_coordinate($loc->{'name'} // '');
		my $known = &weather_place_name($loc->{'lat'}, $loc->{'lon'});
		$known = &weather_place_lookup($loc->{'lat'}, $loc->{'lon'}) unless length $known;
		next unless length $known;
		&weather_location_save($known, $loc->{'lat'}, $loc->{'lon'});
		$fixed++;
	}
	return $fixed;
}

# The house's home plate: the ground the hourly pass keeps. The home app's
# plate is the house itself; a house with none uses the place the person
# anchored, so one anchored place is still always checked.
sub weather_home_plate() {
	my $row = eval {
		&subs::db_query(
			"select value from settings where app = 'home' and setting = 'home_plate' "
			. "and value is not null and value != '' order by cast(server_time as integer) desc limit 1"
		)->hashes->[0];
	};
	my $plate = $row ? eval { decode_json($row->{'value'} // '') } : undef;
	if (ref $plate eq 'HASH') {
		my $lat = &subs::weather_number($plate->{'latitude'});
		my $lon = &subs::weather_number($plate->{'longitude'});
		return { lat => $lat, lon => $lon, from => 'home' } if defined $lat && defined $lon;
	}
	foreach my $loc (@{ &weather_locations() }) {
		next unless $loc->{'anchor'};
		next unless defined $loc->{'lat'} && defined $loc->{'lon'};
		return { lat => 0 + $loc->{'lat'}, lon => 0 + $loc->{'lon'}, uuid => $loc->{'uuid'}, from => 'anchor' };
	}
	return undef;
}

# The saved place at the home plate, or undef when the house has none yet. The
# page marks that place in the picker; the pass asks for it with create so the
# house's ground is a place even before the first save.
sub weather_home_place($opts = {}) {
	$opts ||= {};
	my $home = &weather_home_plate();
	return undef unless $home;
	return &weather_location_for_fix($home->{'lat'}, $home->{'lon'}, '', { create => ($opts->{'create'} ? 1 : 0) });
}

# The display label the house last gave the home place. A move compares the
# notification texts with it, so a name the person set themselves is not
# overwritten.
sub weather_home_label() {
	my $row = eval {
		&subs::db_query(
			"select value from settings where app = 'weather' and setting = 'home_label' "
			. "and value is not null and value != '' order by cast(server_time as integer) desc limit 1"
		)->hashes->[0];
	};
	my $label = $row ? ($row->{'value'} // '') : '';
	$label =~ s/^\s+|\s+$//g;
	return $label;
}

# Keep the app's display name in step with the home place. Only a name that
# still reads as the old home's label (or the app's default) moves; a name the
# person chose is left alone. An unnamed place (a coordinate) does not move it,
# so the first observation can name the place and the next pass can follow.
sub weather_home_name_sync($place) {
	return unless ref $place eq 'HASH';
	my $name = $place->{'name'} // '';
	$name =~ s/^\s+|\s+$//g;
	return if !length $name || &weather_name_is_coordinate($name);
	my $weather_word = &subs::ui('Weather') || 'Weather';
	my $label = $name . ' ' . $weather_word;
	my @apps = qw/weather weather_station/;
	my $note = sub {
		my ($app) = @_;
		my $row = eval {
			&subs::db_query(
				"select value from settings where app = ? and setting = 'notification_text' "
				. "and value is not null and value != '' order by cast(server_time as integer) desc limit 1",
				$app
			)->hashes->[0];
		};
		my $current = $row ? ($row->{'value'} // '') : '';
		$current =~ s/^\s+|\s+$//g;
		return $current;
	};
	my $follow = sub {
		my ($old) = @_;
		foreach my $app (@apps) {
			my $current = $note->($app);
			my $default = eval { &subs::format_name($app) } || '';
			next if length $current && lc($current) ne lc($old) && lc($current) ne lc($default);
			&subs::setting_setter({ app => $app, setting => 'notification_text', value => $label });
		}
	};
	my $stored = &weather_home_label();
	unless (length $stored) {
		# First sight of a home: only a default or empty name is replaced, so a
		# name the person already chose stays.
		$follow->($label);
		&subs::setting_setter({ app => 'weather', setting => 'home_label', value => $label });
		return $label;
	}
	return $label if lc($stored) eq lc($label);
	$follow->($stored);
	&subs::setting_setter({ app => 'weather', setting => 'home_label', value => $label });
	return $label;
}

# Resolve the home plate to a place and remember it. A move to a new plate
# unanchors the old home: the old place stays an ordinary added place (it can be
# anchored again deliberately) but no longer records just by being the old home.
sub weather_home_place_sync() {
	my $place = &weather_home_place({ create => 1 });
	return undef unless $place && ($place->{'uuid'} // '') =~ /^[A-Za-z0-9_-]+$/;
	my $uuid = $place->{'uuid'};
	my $row = eval {
		&subs::db_query(
			"select value from settings where app = 'weather' and setting = 'home_place' "
			. "and value is not null and value != '' order by cast(server_time as integer) desc limit 1"
		)->hashes->[0];
	};
	my $old_uuid = $row ? ($row->{'value'} // '') : '';
	if ($old_uuid ne $uuid) {
		if (length $old_uuid && $old_uuid =~ /^[A-Za-z0-9_-]+$/) {
			my $old_place = &weather_location_find($old_uuid);
			&weather_location_anchor($old_uuid, 0) if $old_place && $old_place->{'anchor'};
		}
		&subs::setting_setter({ app => 'weather', setting => 'home_place', value => $uuid });
	}
	# Run even when the uuid did not move: the place may have just been named by
	# the first observation after a move to a not-yet-named ground.
	&weather_home_name_sync($place);
	return $place;
}

# The places the scheduled pass records. A rule's own place and every anchored
# place are stations, and so is the home plate: the house keeps reading its own
# ground when the phones leave. A device's fix is not a station here - the pass
# does not follow the person; the page offers one check where they are instead.
sub weather_rule_locations() {
	my (@keys, %seen);
	my $am = &weather_observe_prepare();
	foreach my $rule (@{ &weather_automation_rules($am) }) {
		my $location = &weather_rule_location_normalize($rule->{'location'});
		push @keys, $location if length $location && !$seen{$location}++;
	}
	foreach my $rule (@{ &weather_measure_rules() }) {
		my $location = &weather_rule_location_normalize($rule->{'location'});
		push @keys, $location if length $location && !$seen{$location}++;
	}
	# An anchored place is a station the house keeps, wherever the phones are.
	foreach my $loc (@{ &weather_locations() }) {
		my $uuid = $loc->{'uuid'} // '';
		next unless $loc->{'anchor'} && $uuid =~ /^[A-Za-z0-9_-]+$/;
		my $key = 'loc:' . $uuid;
		push @keys, $key unless $seen{$key}++;
	}
	# The home plate is always a station. Find the place at the plate (or make
	# one there) so its readings, History and Delete all name one place.
	my $home = &weather_home_place({ create => 1 });
	if ($home && ($home->{'uuid'} // '') =~ /^[A-Za-z0-9_-]+$/) {
		my $key = 'loc:' . $home->{'uuid'};
		push @keys, $key unless $seen{$key}++;
	}
	return \@keys;
}

# ---- saved locations --------------------------------------------------------
# A saved location is an app fact on the Weather app: the picker lists it beside
# the machines with a GPS fix, and the data route resolves `loc:<uuid>`.
sub weather_locations() {
	# Places are a house fact, not a machine's: read the newest list any
	# machine stored, so the house server observes an anchor a phone added.
	my $row = eval {
		&subs::db_query(
			"select value from settings where app = 'weather' and setting = 'locations' "
			. "and value is not null and value != '' order by cast(server_time as integer) desc limit 1"
		)->hashes->[0];
	};
	my $raw = eval { decode_json($row ? ($row->{'value'} // '') : '') };
	return ref $raw eq 'ARRAY' ? [ grep { ref $_ eq 'HASH' } @{$raw} ] : [];
}

sub weather_location_find($uuid) {
	return undef unless defined $uuid && $uuid =~ /^[A-Za-z0-9_-]+$/;
	my ($location) = grep { ($_->{'uuid'} // '') eq $uuid } @{ &weather_locations() };
	return $location;
}

# A place the observer creates from a fix gets a stable key: two machines that
# arrive at the same ground name the same place instead of racing a random id.
sub weather_place_auto_uuid($lat, $lon) {
	return 'p' . substr(md5_sum(sprintf('%.2f,%.2f', $lat, $lon)), 0, 20);
}

# The ground a fix and a saved place share. Thirty kilometres covers a town
# and its nearer neighbours, so a drive to the next town does not become a
# second place.
sub weather_place_match_km() { return 30; }

# How far a coordinate is from the nearest saved place, in kilometres. Undef
# when the house has saved none.
sub weather_saved_place_km($lat, $lon) {
	return undef unless defined $lat && defined $lon;
	my $nearest;
	foreach my $saved (@{ &weather_locations() }) {
		next unless defined $saved->{'lat'} && defined $saved->{'lon'};
		my $km = eval { &subs::weather_distance_km($lat, $lon, $saved->{'lat'}, $saved->{'lon'}) };
		$nearest = $km if defined $km && (!defined $nearest || $km < $nearest);
	}
	return $nearest;
}

# The place a fix belongs to. A saved place within the match radius is that
# place; a new fix can create one, which is what makes a stay somewhere a place
# the person can later find in the picker and delete. An anchored place keeps
# its name and its readings even when the phone leaves.
sub weather_location_for_fix($lat, $lon, $name = '', $opts = {}) {
	$opts ||= {};
	return undef unless defined $lat && defined $lon;
	my $limit = $opts->{'km'} || &weather_place_match_km();
	my $locations = &weather_locations();
	my ($best, $best_km);
	foreach my $loc (@{$locations}) {
		next unless defined $loc->{'lat'} && defined $loc->{'lon'};
		my $km = eval { &subs::weather_distance_km($lat, $lon, $loc->{'lat'}, $loc->{'lon'}) };
		next unless defined $km;
		if (!defined $best_km || $km < $best_km) {
			$best = $loc;
			$best_km = $km;
		}
	}
	$name = '' unless defined $name;
	$name =~ s/^\s+|\s+$//g;
	if ($best && $best_km <= $limit) {
		my $changed = 0;
		# A place the person named stays named; an auto place takes the
		# provider's newer name instead of the coordinate it started with.
		if (length $name && $best->{'auto'}
			&& (!length($best->{'name'} // '') || &weather_name_is_coordinate($best->{'name'} // ''))) {
			$best->{'name'} = substr($name, 0, 80);
			$changed = 1;
		}
		&subs::setting_setter({ app => 'weather', setting => 'locations', value => encode_json $locations })
			if $changed;
		return $best;
	}
	return undef unless $opts->{'create'};
	$name = sprintf('%.4f, %.4f', $lat, $lon) unless length $name;
	my $uuid = (defined $opts->{'uuid'} && $opts->{'uuid'} =~ /^[A-Za-z0-9_-]+$/)
		? $opts->{'uuid'}
		: &weather_place_auto_uuid($lat, $lon);
	if (grep { ($_->{'uuid'} // '') eq $uuid } @{$locations}) {
		$uuid = &subs::random_string_creator(22);
	}
	my $place = {
		uuid => $uuid,
		name => substr($name, 0, 80),
		lat => 0 + $lat,
		lon => 0 + $lon,
		auto => 1,
		anchor => 0,
	};
	$place->{'seen'} = 0 + $opts->{'seen'} if defined $opts->{'seen'};
	push @{$locations}, $place;
	&subs::setting_setter({ app => 'weather', setting => 'locations', value => encode_json $locations });
	return $place;
}

sub weather_location_save($name, $lat, $lon, $opts = {}) {
	$opts ||= {};
	return undef unless defined $lat && defined $lon
		&& "$lat" =~ /^-?\d+(?:\.\d+)?$/ && "$lon" =~ /^-?\d+(?:\.\d+)?$/
		&& $lat >= -90 && $lat <= 90 && $lon >= -180 && $lon <= 180;
	my $locations = &weather_locations();
	$name = defined $name ? "$name" : '';
	$name =~ s/^\s+|\s+$//g;
	$name = substr($name, 0, 80);
	$name = sprintf('%.4f, %.4f', $lat, $lon) unless length $name;
	# A second save on the same ground renames the place rather than adding a
	# duplicate a few metres away.
	my $key = sprintf('%.4f,%.4f', $lat, $lon);
	my ($existing) = grep {
		sprintf('%.4f,%.4f', $_->{'lat'} // 0, $_->{'lon'} // 0) eq $key
	} @{$locations};
	# A map tap a few metres from an auto-created place is that place: keep one
	# record, so naming a place does not leave a second entry beside it.
	unless ($existing) {
		my ($near, $near_km);
		foreach my $loc (@{$locations}) {
			next unless defined $loc->{'lat'} && defined $loc->{'lon'};
			my $km = eval { &subs::weather_distance_km($lat, $lon, $loc->{'lat'}, $loc->{'lon'}) };
			next unless defined $km && $km <= 1;
			if (!defined $near_km || $km < $near_km) {
				$near = $loc;
				$near_km = $km;
			}
		}
		$existing = $near;
	}
	my $uuid;
	if ($existing) {
		$uuid = $existing->{'uuid'};
		$existing->{'name'} = $name;
		$existing->{'anchor'} = $opts->{'anchor'} ? 1 : 0 if exists $opts->{'anchor'};
		$existing->{'auto'} = $opts->{'auto'} ? 1 : 0 if exists $opts->{'auto'};
		$existing->{'seen'} = 0 + $opts->{'seen'} if defined $opts->{'seen'};
	}
	else {
		$uuid = (defined $opts->{'uuid'} && $opts->{'uuid'} =~ /^[A-Za-z0-9_-]+$/)
			? $opts->{'uuid'}
			: &subs::random_string_creator(22);
		push @{$locations}, {
			uuid => $uuid,
			name => $name,
			lat => 0 + $lat,
			lon => 0 + $lon,
			anchor => ($opts->{'anchor'} ? 1 : 0),
			auto => ($opts->{'auto'} ? 1 : 0),
			(defined $opts->{'seen'} ? (seen => 0 + $opts->{'seen'}) : ()),
		};
	}
	&subs::setting_setter({ app => 'weather', setting => 'locations', value => encode_json $locations });
	return { uuid => $uuid, locations => $locations };
}

sub weather_location_anchor($uuid, $anchor) {
	return undef unless defined $uuid && $uuid =~ /^[A-Za-z0-9_-]+$/;
	my $locations = &weather_locations();
	my ($place) = grep { ($_->{'uuid'} // '') eq $uuid } @{$locations};
	return undef unless $place;
	$place->{'anchor'} = $anchor ? 1 : 0;
	&subs::setting_setter({ app => 'weather', setting => 'locations', value => encode_json $locations });
	my $labels = &weather_location_labels();
	return {
		uuid => $uuid,
		anchor => $place->{'anchor'} ? 1 : 0,
		locations => $locations,
		labels => $labels,
	};
}

# Delete a saved place. A rule that named it keeps its key so nothing silently
# widens to "Any location"; the Automations tab labels that key as a deleted
# place, and the person can choose the new one.
sub weather_location_delete($uuid) {
	return undef unless defined $uuid && $uuid =~ /^[A-Za-z0-9_-]+$/;
	my $locations = &weather_locations();
	return undef unless grep { ($_->{'uuid'} // '') eq $uuid } @{$locations};
	my @kept = grep { ($_->{'uuid'} // '') ne $uuid } @{$locations};
	&subs::setting_setter({ app => 'weather', setting => 'locations', value => encode_json \@kept });
	# A place's readings leave with it. The observer tags each measure with
	# `place`; readings recorded before places existed used `location`.
	my $key = 'loc:' . $uuid;
	my $rows = eval {
		&subs::db_query(
			"select uuid, measures from appointments where app = 'weather_station' "
			. "and measures is not null and measures like ?",
			'%' . $key . '%'
		)->hashes;
	} || [];
	my $deleted = 0;
	foreach my $row (@{$rows}) {
		my $list = eval { decode_json($row->{'measures'} // '[]') } || [];
		my $hit = 0;
		foreach my $measure (@{$list}) {
			next unless ref $measure eq 'HASH';
			next unless (($measure->{'place'} // '') eq $key || ($measure->{'location'} // '') eq $key);
			$hit = 1;
			last;
		}
		next unless $hit;
		$deleted++ if eval { &subs::records_tombstone('weather_station', $row->{'uuid'}); 1 };
	}
	# The last observation must not keep History pointed at a place that is gone.
	my $last = eval { &subs::cache_get({ app => 'weather', context => 'observe', subcontext => 'last' }) } || {};
	if (($last->{'place_key'} // '') eq $key) {
		eval { &subs::cache_delete({ app => 'weather', context => 'observe', subcontext => 'last' }) };
	}
	eval { &subs::cache_delete({ app => 'weather', context => 'history' }) };
	my $labels = &weather_location_labels();
	return {
		uuid => $uuid,
		locations => \@kept,
		labels => $labels,
		deleted_readings => $deleted,
	};
}

# ---- the observation --------------------------------------------------------
# Record what the app fetched. Every measure goes into the same appointment, so
# one observation is one row of values; appt_measure_writer also runs the old
# condition rules. A changed reading writes at once; an unchanged one waits half
# an hour. The scheduled pass forces a write.
sub weather_observe_record($weather, $opts) {
	$opts ||= {};
	return { skipped => 'no condition' }
		unless ref $weather eq 'HASH' && length($weather->{'current'}{'condition'} // '');
	my $condition = $weather->{'current'}{'condition'};
	my $location = &weather_rule_location_normalize($opts->{'location'});
	my $place_name = $weather->{'location_name'} // '';
	$place_name = &weather_place_lookup($weather->{'lat'}, $weather->{'lon'}, { fetch => 1 })
		unless length $place_name;
	if (length $place_name) {
		&weather_place_name_remember($weather->{'lat'}, $weather->{'lon'}, $place_name);
		# A place saved from the map without a name stored its coordinate. Now
		# that the provider has named it, keep the name instead.
		if ($location =~ /^loc:(.+)$/) {
			my $saved = &weather_location_find($1);
			&weather_location_save($place_name, $saved->{'lat'}, $saved->{'lon'})
				if $saved && &weather_name_is_coordinate($saved->{'name'} // '');
		}
	}
	my $values = &weather_measure_values($weather);
	my $am = &weather_observe_prepare();
	my $condition_rules = &weather_automation_rules($am);
	my $measure_rules = &weather_measure_rules();
	my $last = eval { &cache_get({ app => 'weather', context => 'observe', subcontext => 'last' }) } || {};
	my $now = &rightNow();
	# Tag the reading with the physical place it belongs to. A saved or anchored
	# place is itself; a device's fix finds or creates the place it is standing
	# on, so a stay somewhere becomes a place the person can see and delete.
	my $place;
	my $place_key = '';
	if ($location =~ /^loc:([A-Za-z0-9_-]+)$/) {
		$place = &weather_location_find($1);
		$place_key = $place ? 'loc:' . $place->{'uuid'} : '';
	}
	elsif ($location =~ /^dev:([A-Za-z0-9_-]+)$/) {
		my ($wlat, $wlon) = ($weather->{'lat'}, $weather->{'lon'});
		if (!defined $wlat || !defined $wlon) {
			my $fix = eval { &weather_device_fix($1) };
			($wlat, $wlon) = ($fix->{'lat'}, $fix->{'lon'}) if $fix;
		}
		$place = &weather_location_for_fix($wlat, $wlon, $place_name, { create => 1, seen => $now });
		$place_key = $place ? 'loc:' . $place->{'uuid'} : '';
	}
	# A place that is anchored, or that a rule names, is written as itself: its
	# readings and its rules do not depend on which phone happens to be there.
	my $place_rule = 0;
	if (length $place_key) {
		foreach my $rule (@{ $condition_rules || [] }, @{ $measure_rules || [] }) {
			next unless ref $rule eq 'HASH';
			if (&weather_rule_location_normalize($rule->{'location'}) eq $place_key) {
				$place_rule = 1;
				last;
			}
		}
	}
	$location = $place_key if length $place_key && ($place_rule || ($place && $place->{'anchor'}));
	my $signature = $location . '|' . $place_key . '|' . join('|', map { $_ . '=' . $values->{$_} } sort keys %{$values});
	my $changed = (($last->{'signature'} // '') ne $signature);
	my $due = !$last->{'at'} || $now - $last->{'at'} >= 30 * 60 * 1000;
	return {
		skipped => 'waiting',
		condition => $condition,
		changed => $changed ? 1 : 0,
		at => $last->{'at'},
	} unless $opts->{'force'} || $changed || $due;
	my $c = &subs::controller_builder();
	# One house, one actor. The toggle is a setting per machine, so every screen
	# that refreshed the weather started its own copy of the app; the house server
	# is the one that acts, and the other machines still keep the reading they saw.
	my $leader = &weather_observe_leader() ? 1 : 0;
	my $uuid;
	my @order = qw(condition temperature feels_like humidity wind wind_gust wind_direction pressure visibility dew_point uv);
	foreach my $measure (@order) {
		next unless exists $values->{$measure};
		my $written = eval {
			&Manager::appt_measure_writer($c, {
				app => &weather_automation_app(),
				measure => $measure,
				value => $values->{$measure},
				timestamp => $now,
				location => $location,
				(length $place_key ? (place => $place_key) : ()),
				(defined $uuid ? (uuid => $uuid) : ()),
				skip_actions => ($leader ? 0 : 1),
			});
		};
		if (!$written) {
			$log->warn('weather observe: ' . $measure . ' was not recorded: ' . ($@ || 'no uuid')) if $log;
			next;
		}
		$uuid = $written;
	}
	return { error => &subs::ui('The observation was not recorded.'), condition => $condition }
		unless $uuid;
	# The appointment an automation writes carries the warranty of the observation
	# that woke it, so the house's record reads as one event with one warranty.
	my $warranty = '';
	{
		my $source = eval { &subs::db_select('appointments', ['warranty'], { uuid => $uuid })->hashes->[0] };
		$warranty = $source->{'warranty'} if $source && defined $source->{'warranty'} && length $source->{'warranty'};
	}
	my $series = [];
	if (@{$measure_rules}) {
		my $longest = 0;
		foreach my $rule (@{$measure_rules}) {
			$longest = $rule->{'for_ms'} if ($rule->{'for_ms'} || 0) > $longest;
		}
		my $from = $now - $longest - 2 * 60 * 60 * 1000;
		$series = &weather_observation_series(&weather_automation_app(), $from, $now, $location);
		push @{$series}, { ts => $now, values => { %{$values} } }
			unless @{$series} && ($series->[-1]{'ts'} || 0) >= $now - 60_000;
	}
	my $fired = $leader ? &weather_measure_rule_evaluate($values, $series, $uuid, $now, $location, $warranty) : [];
	my $matched = &weather_automation_matches($condition_rules, $condition, $location);
	&cache_set({ app => 'weather', context => 'observe', subcontext => 'last', warranty => '-1d' }, {
		signature => $signature,
		values => $values,
		condition => ($values->{'condition'} // ''),
		at => $now,
		changed_at => $changed ? $now : ($last->{'changed_at'} || $now),
		place => ($place_name || $weather->{'location_name'} || ''),
		place_key => $place_key,
		location => $location,
	});
	return {
		ok => 1,
		condition => $condition,
		changed => $changed ? 1 : 0,
		matched => $matched,
		rules => $fired,
		values => $values,
		location => $location,
		place => $place_name,
		place_key => $place_key,
		at => $now,
		uuid => $uuid,
		leader => $leader,
	};
}

sub weather_observe_now($opts) {
	$opts ||= {};
	my ($lat, $lon) = ($opts->{'lat'}, $opts->{'lon'});
	if (!defined $lat || !defined $lon) {
		my $fixes = eval { &subs::weather_device_fixes(24 * 60 * 60 * 1000) } || [];
		my ($fix) = @{$fixes};
		$log->info('weather observe: no GPS fix in the last day') if $log && !$fix;
		return { skipped => 'no fix' } unless $fix;
		$lat = $fix->{'lat'};
		$lon = $fix->{'lon'};
		$opts->{'location'} ||= 'dev:' . $fix->{'signatorial'} if ($fix->{'signatorial'} // '') =~ /^[A-Za-z0-9_-]+$/;
	}
	my $weather = eval { &subs::weather_fetch($lat, $lon, { force => ($opts->{'force'} ? 1 : 0) }) };
	unless (ref $weather eq 'HASH' && !$weather->{'error'}) {
		my $why = (ref $weather eq 'HASH' && $weather->{'error'}) || &subs::ui('Weather is unavailable right now.');
		$log->warn("weather observe: fetch for $lat,$lon failed: $why") if $log;
		return { error => $why };
	}
	my $result = &weather_observe_record($weather, $opts);
	$result->{'lat'} = $lat;
	$result->{'lon'} = $lon;
	$result->{'location_name'} = $weather->{'location_name'} // '';
	return $result;
}

# How long the house server may be silent before another machine takes the pass.
# remote_machine_sync refreshes a peer's row about every ten minutes; a server
# that has not been heard from in fifteen is away, not merely between syncs.
my $WEATHER_LEADER_GRACE_MS = 15 * 60 * 1000;

# One pass per household. The house server records the weather; a phone, tablet
# or laptop only reads what it kept. When the server is away, the live machines
# elect the lowest signatorial among them as the stand-in, so the rules keep
# running without every machine acting at once. A household with no server row
# still checks its own rules, so a single machine is never left waiting.
sub weather_observe_leader() {
	my $me = &subs::signatorial_designer() // '';
	# The house server is the actor by definition. Its own roster does not
	# contain itself, so a server with no `device='server'` row in
	# remote_machines would otherwise fall into the stand-in election and lose
	# the pass to the lowest peer.
	my $is_server = (eval { &subs::device_setter() } || '') eq 'server';
	return 1 if $is_server;
	my $now = &subs::rightNow();
	my $rows = eval {
		&subs::db_query(
			"select signatorial, device, connection, server_time from remote_machines "
			. "where signatorial is not null and signatorial != ''"
		)->hashes;
	} || [];
	my (@servers, %live);
	foreach my $row (@{$rows}) {
		my $sig = $row->{'signatorial'} // '';
		next unless length $sig;
		$live{$sig} = 1
			if (($row->{'connection'} || '') eq 'active')
			&& int($row->{'server_time'} || 0) > $now - $WEATHER_LEADER_GRACE_MS;
		push @servers, $row if (($row->{'device'} || '') eq 'server');
	}
	if (@servers) {
		my @ordered = sort { int($b->{'server_time'} || 0) <=> int($a->{'server_time'} || 0) } @servers;
		my ($server) = grep { $live{$_->{'signatorial'} // ''} } @ordered;
		if ($server) {
			my $sig = $server->{'signatorial'} // '';
			return ($sig eq $me) ? 1 : 0;
		}
	}
	$live{$me} = 1 if length $me;
	return 0 unless %live;
	my ($stand_in) = sort keys %live;
	return ($stand_in eq $me) ? 1 : 0;
}

# The whole house is together when every machine heard from in the last day is
# connected and has reported in inside the grace. That is the moment to fold the
# duplicates a split produced: the rows from all machines have met in one table.
# A machine gone for more than a day is not awaited; its rows sync when it
# returns, and the next pass catches what they bring.
sub weather_observe_house_together() {
	my $now = &subs::rightNow();
	my $rows = eval {
		&subs::db_query(
			"select signatorial, connection, server_time from remote_machines "
			. "where signatorial is not null and signatorial != ''"
		)->hashes;
	} || [];
	return 1 unless @{$rows};
	my $recent = $now - 24 * 60 * 60 * 1000;
	foreach my $row (@{$rows}) {
		my $seen = int($row->{'server_time'} || 0);
		next if $seen < $recent;
		return 0 unless (($row->{'connection'} || '') eq 'active');
		return 0 unless $seen > $now - $WEATHER_LEADER_GRACE_MS;
	}
	return 1;
}

# ---- putting the house back together ----------------------------------------
# A split house records the same reading on more than one machine. Sync keeps
# both rows because their uuids differ; the values, the place and the minute are
# what make them one observation. Walk each place's readings in time order and
# fold a run of identical readings inside the provider's own cache window (ten
# minutes), so a value that changes and comes back is not mistaken for a
# duplicate.
sub weather_observe_row_signature($row) {
	return undef unless ref $row eq 'HASH';
	my $list = ref $row->{'measures'} eq 'ARRAY'
		? $row->{'measures'}
		: eval { decode_json($row->{'measures'} // '[]') };
	return undef unless ref $list eq 'ARRAY' && @{$list};
	my ($location, $place, @parts);
	foreach my $measure (@{$list}) {
		next unless ref $measure eq 'HASH';
		$place //= $measure->{'place'}
			if defined $measure->{'place'} && length $measure->{'place'};
		$location //= $measure->{'location'}
			if defined $measure->{'location'} && length $measure->{'location'};
		my @fields = sort grep { $_ ne 'ts' && $_ ne 'uuid' && $_ ne 'location' } keys %{$measure};
		next unless @fields;
		push @parts, join('&', map { $_ . '=' . (defined $measure->{$_} ? $measure->{$_} : '') } @fields);
	}
	return undef unless @parts;
	# Two machines at one place are one place even when their rule keys are
	# different devices; the physical place is the group duplicates fold into.
	return {
		location => ($place || $location || ''),
		signature => join('|', sort @parts),
	};
}

# A folded row leaves through the same door as any other deleted record, so a
# peer that still holds it learns the deletion instead of handing it back.
sub weather_observe_forget($uuid) {
	return 0 unless defined $uuid && length $uuid;
	my $ok = eval { &subs::records_tombstone('weather_station', $uuid); 1 };
	return $ok ? 1 : 0;
}

sub weather_observe_reconcile($opts = {}) {
	$opts ||= {};
	my $window = $opts->{'window_ms'} || 10 * 60 * 1000;
	my $days = $opts->{'days'} || 7;
	my $now = &subs::rightNow();
	my $rows = eval {
		&subs::db_query(
			"select uuid, timestamp, device, measures from appointments "
			. "where app = 'weather_station' and type = 'measure' and measures is not null "
			. "and cast(timestamp as integer) >= ? order by cast(timestamp as integer) asc",
			$now - $days * 24 * 60 * 60 * 1000
		)->hashes;
	} || [];
	my %by_location;
	foreach my $row (@{$rows}) {
		my $sig = &weather_observe_row_signature($row);
		next unless $sig && length $sig->{'location'};
		push @{ $by_location{$sig->{'location'}} }, { %{$row}, %{$sig} };
	}
	my (@removed, $checked);
	$checked = 0;
	foreach my $location (sort keys %by_location) {
		my @burst;
		my $fold = sub {
			return unless @burst > 1;
			# The house server's copy is the one the rules saw; keep it when it
			# is in the run. Otherwise the earliest copy is the observation.
			my ($keep) = grep { ($_->{'device'} // '') eq 'server' } @burst;
			$keep ||= $burst[0];
			foreach my $row (@burst) {
				next if $row == $keep;
				next unless &weather_observe_forget($row->{'uuid'} // '');
				push @removed, $row->{'uuid'};
			}
			@burst = ();
		};
		foreach my $row (@{ $by_location{$location} }) {
			$checked++;
			my $last = @burst ? $burst[-1] : undef;
			if ($last
				&& ($row->{'signature'} // '') eq ($last->{'signature'} // '')
				&& (int($row->{'timestamp'} || 0) - int($last->{'timestamp'} || 0)) <= $window) {
				push @burst, $row;
			}
			else {
				$fold->();
				@burst = ($row);
			}
		}
		$fold->();
	}
	my $out = { checked => $checked, removed => scalar @removed, uuids => \@removed };
	eval { &subs::cache_set({ app => 'weather', context => 'observe', subcontext => 'reconcile', warranty => '-1d' }, { at => $now, removed => scalar @removed }) };
	return $out;
}

# The scheduled pass. The lock keeps the house to one fetch even when several
# machines run the utility; a condition that changed still writes at once, so
# the lock is a ceiling on the fetch, not on the rules.
sub weather_observe_tick() {
	return { skipped => 'not the house' } unless &weather_observe_leader();
	my $now = &rightNow();
	# Fold the split's duplicates as soon as the house is whole again. This runs
	# before the fetch as well as when there is no fix, because cleaning the
	# record must not wait for a machine's GPS.
	my $reconcile;
	if (&weather_observe_house_together()) {
		my $last_run = eval { &subs::cache_get({ app => 'weather', context => 'observe', subcontext => 'reconcile' }) } || {};
		if (($last_run->{'at'} || 0) <= $now - 60 * 60 * 1000) {
			$reconcile = eval { &weather_observe_reconcile() };
			if ($log && $reconcile && $reconcile->{'removed'}) {
				$log->info('weather reconcile: folded ' . $reconcile->{'removed'} . ' duplicate reading(s)');
			}
		}
	}
	# A home plate that moved is a new station and an ordinary old place; resolve
	# it before the pass picks its keys so the old home does not keep a turn.
	eval { &weather_home_place_sync(); };
	my $keys = &weather_rule_locations();
	return { skipped => 'no fix', (defined $reconcile ? (reconcile => $reconcile) : ()) } unless @{$keys};
	my $lock = eval { &cache_get({ app => 'weather', context => 'observe', subcontext => 'lock' }) } || {};
	return { skipped => 'held', at => $lock->{'at'}, (defined $reconcile ? (reconcile => $reconcile) : ()) }
		if ($lock->{'at'} || 0) > $now - 20 * 60 * 1000;
	&cache_set({ app => 'weather', context => 'observe', subcontext => 'lock', warranty => '-1d' }, { at => $now });
	my @results;
	foreach my $key (@{$keys}) {
		my ($lat, $lon);
		if ($key =~ /^dev:(.+)$/) {
			my $fix = eval { &subs::weather_device_fix($1) };
			unless ($fix) {
				$log->info("weather observe: $key has no recent GPS fix") if $log;
				next;
			}
			$lat = $fix->{'lat'};
			$lon = $fix->{'lon'};
		}
		elsif ($key =~ /^loc:(.+)$/) {
			my $location = &weather_location_find($1);
			unless ($location) {
				$log->info("weather observe: $key is gone") if $log;
				next;
			}
			$lat = $location->{'lat'};
			$lon = $location->{'lon'};
		}
		else { next; }
		my $result = &weather_observe_now({ lat => $lat, lon => $lon, location => $key, force => 1 });
		$result->{'location'} = $key;
		push @results, $result;
		if ($log) {
			$log->info("weather observe $key: " . encode_json({
				map { $_ => $result->{$_} }
				grep { defined $result->{$_} }
				qw(ok skipped error condition changed)
			}));
		}
	}
	return { skipped => 'no fix', results => \@results, (defined $reconcile ? (reconcile => $reconcile) : ()) } unless @results;
	return { ok => 1, results => \@results, (defined $reconcile ? (reconcile => $reconcile) : ()) };
}

1;
