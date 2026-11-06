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

sub weather_measure_rule_save($rule) {
	my $rules = &weather_measure_rule_apply(&weather_measure_rules(), $rule);
	return { error => &subs::ui('A measurement rule needs at least one complete condition and an action.') }
		unless $rules;
	&subs::setting_setter({
		app => &weather_automation_app(),
		setting => 'weather_rules',
		value => encode_json $rules,
	});
	return &weather_automation_state();
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
sub weather_rule_app_switch($app, $on, $source_uuid, $timestamp) {
	return 0 unless defined $app && length $app;
	$timestamp ||= &rightNow();
	my $toggle = &subs::setting_grabber({ app => $app, setting => 'toggle' });
	$toggle = 'off' unless defined $toggle && length $toggle;
	if ($on && $toggle ne 'on') {
		&subs::setting_setter({ app => $app, setting => 'toggle', value => 'on', timestamp => $timestamp });
		eval {
			&Manager::appointment_writer(undef, {
				app => $app,
				timestamp => $timestamp,
				type => 'start',
				source_uuid => $source_uuid,
				subtype => 'measure',
			});
		};
		$log->warn('weather rule: could not start ' . $app . ': ' . $@) if $log && $@;
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
sub weather_measure_rule_evaluate($values, $series, $uuid, $now, $location = '') {
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
				push @fired, { uuid => $id, name => $rule->{'name'} || '', action => 'stop', app => $rule->{'app'}, ok => &weather_rule_app_switch($rule->{'app'}, 0, $uuid, $now) };
			}
			else {
				push @fired, { uuid => $id, name => $rule->{'name'} || '', action => 'start', app => $rule->{'app'}, ok => &weather_rule_app_switch($rule->{'app'}, 1, $uuid, $now) };
			}
		}
		elsif (!$matched && $previous && $action eq 'start') {
			push @fired, { uuid => $id, name => $rule->{'name'} || '', action => 'stop', app => $rule->{'app'}, ok => &weather_rule_app_switch($rule->{'app'}, 0, $uuid, $now) };
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

sub weather_automation_state() {
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
					location_label => (length $loc ? ($location_label->{$loc} || $loc) : '') }
			} @{$rules}
		],
		measures => &weather_measure_catalog(),
		values => ($last->{'values'} || {}),
		measure_rules => [
			map {
				my %r = %{$_};
				my $loc = $_->{'location'} // '';
				$r{'app_label'} = &subs::format_name($_->{'app'}) if length($_->{'app'} // '');
				$r{'location_label'} = length $loc ? ($location_label->{$loc} || $loc) : '';
				\%r;
			} @{$measure_rules}
		],
		locations => $locations,
		apps => \@app_options,
	};
}

sub weather_automation_save($rule) {
	my $am = &weather_observe_prepare();
	my $rules = &weather_automation_apply($am->{'condition'}->{'cm'} || [], $rule);
	return { error => &subs::ui('A rule needs a condition and an app.') } unless $rules;
	$am->{'condition'}->{'cm'} = $rules;
	&subs::setting_setter({
		app => &weather_automation_app(),
		setting => 'app_measures',
		value => encode_json $am,
	});
	return &weather_automation_state();
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

# Every place a rule names, plus the newest fix when a global rule still exists.
sub weather_rule_locations() {
	my (@keys, %seen);
	my $global = 0;
	my $am = &weather_observe_prepare();
	foreach my $rule (@{ &weather_automation_rules($am) }) {
		my $location = &weather_rule_location_normalize($rule->{'location'});
		if (length $location) { push @keys, $location unless $seen{$location}++; }
		else { $global = 1; }
	}
	foreach my $rule (@{ &weather_measure_rules() }) {
		my $location = &weather_rule_location_normalize($rule->{'location'});
		if (length $location) { push @keys, $location unless $seen{$location}++; }
		else { $global = 1; }
	}
	if ($global) {
		my $fixes = eval { &subs::weather_device_fixes(24 * 60 * 60 * 1000) } || [];
		my ($fix) = @{$fixes};
		my $sig = $fix ? ($fix->{'signatorial'} // '') : '';
		if ($sig =~ /^[A-Za-z0-9_-]+$/) {
			my $key = "dev:$sig";
			push @keys, $key unless $seen{$key}++;
		}
	}
	return \@keys;
}

# ---- saved locations --------------------------------------------------------
# A saved location is an app fact on the Weather app: the picker lists it beside
# the machines with a GPS fix, and the data route resolves `loc:<uuid>`.
sub weather_locations() {
	my $raw = eval { decode_json(&subs::setting_grabber({ app => 'weather', setting => 'locations' }) // '') };
	return ref $raw eq 'ARRAY' ? [ grep { ref $_ eq 'HASH' } @{$raw} ] : [];
}

sub weather_location_find($uuid) {
	return undef unless defined $uuid && $uuid =~ /^[A-Za-z0-9_-]+$/;
	my ($location) = grep { ($_->{'uuid'} // '') eq $uuid } @{ &weather_locations() };
	return $location;
}

sub weather_location_save($name, $lat, $lon) {
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
	my $uuid;
	if ($existing) {
		$uuid = $existing->{'uuid'};
		$existing->{'name'} = $name;
	}
	else {
		$uuid = &subs::random_string_creator(22);
		push @{$locations}, { uuid => $uuid, name => $name, lat => 0 + $lat, lon => 0 + $lon };
	}
	&subs::setting_setter({ app => 'weather', setting => 'locations', value => encode_json $locations });
	return { uuid => $uuid, locations => $locations };
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
	my $signature = $location . '|' . join('|', map { $_ . '=' . $values->{$_} } sort keys %{$values});
	my $changed = (($last->{'signature'} // '') ne $signature);
	my $due = !$last->{'at'} || $now - $last->{'at'} >= 30 * 60 * 1000;
	return {
		skipped => 'waiting',
		condition => $condition,
		changed => $changed ? 1 : 0,
		at => $last->{'at'},
	} unless $opts->{'force'} || $changed || $due;
	my $c = &subs::controller_builder();
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
				(defined $uuid ? (uuid => $uuid) : ()),
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
	my $fired = &weather_measure_rule_evaluate($values, $series, $uuid, $now, $location);
	my $matched = &weather_automation_matches($condition_rules, $condition, $location);
	&cache_set({ app => 'weather', context => 'observe', subcontext => 'last', warranty => '-1d' }, {
		signature => $signature,
		values => $values,
		condition => ($values->{'condition'} // ''),
		at => $now,
		changed_at => $changed ? $now : ($last->{'changed_at'} || $now),
		place => ($weather->{'location_name'} // ''),
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
		at => $now,
		uuid => $uuid,
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

# The scheduled pass. The lock keeps the house to one fetch even when several
# machines run the utility; a condition that changed still writes at once, so
# the lock is a ceiling on the fetch, not on the rules.
sub weather_observe_tick() {
	my $now = &rightNow();
	my $am = &weather_observe_prepare();
	my $has_rules = @{ &weather_automation_rules($am) } || @{ &weather_measure_rules() };
	return { skipped => 'no rules' } unless $has_rules;
	my $keys = &weather_rule_locations();
	return { skipped => 'no fix' } unless @{$keys};
	my $lock = eval { &cache_get({ app => 'weather', context => 'observe', subcontext => 'lock' }) } || {};
	return { skipped => 'held', at => $lock->{'at'} }
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
	return { skipped => 'no fix', results => \@results } unless @results;
	return { ok => 1, results => \@results };
}

1;
