package subs;

# WeatherAutomation: what the Weather app does with a condition it has seen.
# The house already keeps "condition -> start/stop an app" rules in an app's
# `app_measures` setting; the old weather web-measure app used them to start
# `raining`, `snowing`, `foggy`, `sunny` and `thunderstorm`. That page named a
# city an hour away, so this module moves those rules to the app that reads the
# house's own coordinate and feeds the same engine (appt_measure_action) with
# the condition the person actually has.
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

use Mojo::JSON qw(decode_json encode_json);

our $log;

# ---- rules ------------------------------------------------------------------
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

# Which rules the condition wakes. appt_measure_writer stores a text measure
# through unformat_name ("Light Rain" -> "light_rain"), so match the same shape
# here; the engine's own test is a case-insensitive substring.
sub weather_automation_matches($rules, $condition) {
	my $state = lc(&subs::unformat_name($condition // ''));
	my @hit;
	foreach my $r (@{ ref $rules eq 'ARRAY' ? $rules : [] }) {
		next unless ref $r eq 'HASH';
		my $match = lc($r->{'match'} // '');
		next unless length $match && index($state, $match) >= 0;
		push @hit, { app => $r->{'app'}, action => $r->{'action'} || 'start' };
	}
	return \@hit;
}

# ---- the rules' home --------------------------------------------------------
# The first read carries the old app's rules over. `weather` keeps its hourly
# readings for the History tab, but its rules are cleared so the London page
# cannot start or stop an app for a condition the house does not have.
sub weather_observe_prepare() {
	my $app = &weather_automation_app();
	my $own = eval { decode_json(&subs::setting_grabber({ app => $app, setting => 'app_measures' }) // '') } || {};
	return $own if ref $own->{'condition'} eq 'HASH';
	my $source = eval { decode_json(&subs::setting_grabber({ app => 'weather', setting => 'app_measures' }) // '') } || {};
	my $rules = &weather_automation_rules($source);
	my $copy = {
		condition => {
			type => 'text',
			value => ($source->{'condition'}->{'value'} // ''),
			cm => $rules,
		},
	};
	&subs::setting_setter({ app => $app, setting => 'app_measures', value => encode_json $copy });
	my $seen = eval { decode_json(&subs::setting_grabber({ app => 'weather', setting => 'seen_measures' }) // '') };
	if (ref $seen eq 'ARRAY' && @{$seen}) {
		&subs::setting_setter({ app => $app, setting => 'seen_measures', value => encode_json $seen });
	}
	if (@{$rules}) {
		$source->{'condition'}->{'cm'} = [];
		&subs::setting_setter({ app => 'weather', setting => 'app_measures', value => encode_json $source });
	}
	return $copy;
}

sub weather_automation_state() {
	my $am = &weather_observe_prepare();
	my $app = &weather_automation_app();
	my $rules = &weather_automation_rules($am);
	my $seen = eval { decode_json(&subs::setting_grabber({ app => $app, setting => 'seen_measures' }) // '') } || [];
	my $last = eval { &cache_get({ app => 'weather', context => 'observe', subcontext => 'last' }) } || {};
	return {
		app => $app,
		condition => ($am->{'condition'}->{'value'} // ''),
		condition_text => &subs::format_name($am->{'condition'}->{'value'} // ''),
		condition_at => $last->{'at'},
		condition_changed_at => $last->{'changed_at'},
		seen => [ sort @{ ref $seen eq 'ARRAY' ? $seen : [] } ],
		rules => [ map { { %{$_}, app_label => &subs::format_name($_->{'app'}) } } @{$rules} ],
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

# ---- the observation --------------------------------------------------------
# Record the condition the app fetched. appt_measure_writer appends it to the
# current measure appointment and runs the rules itself. A condition that has
# not changed is written at most every half hour; a changed one is written at
# once, because that is the edge the rules act on.
sub weather_observe_record($weather, $opts) {
	$opts ||= {};
	return { skipped => 'no condition' }
		unless ref $weather eq 'HASH' && length($weather->{'current'}{'condition'} // '');
	my $condition = $weather->{'current'}{'condition'};
	my $am = &weather_observe_prepare();
	my $rules = &weather_automation_rules($am);
	return { skipped => 'no rules', condition => $condition } unless @{$rules};
	my $last = eval { &cache_get({ app => 'weather', context => 'observe', subcontext => 'last' }) } || {};
	my $now = &rightNow();
	my $changed = (($last->{'condition'} // '') ne $condition);
	my $due = !$last->{'at'} || $now - $last->{'at'} >= 30 * 60 * 1000;
	return {
		skipped => 'waiting',
		condition => $condition,
		changed => $changed ? 1 : 0,
		at => $last->{'at'},
	} unless $opts->{'force'} || $changed || $due;
	my $matched = &weather_automation_matches($rules, $condition);
	my $c = &subs::controller_builder();
	my $uuid = eval {
		&Manager::appt_measure_writer($c, {
			app => &weather_automation_app(),
			measure => 'condition',
			value => $condition,
			timestamp => $now,
		});
	};
	$log->warn('weather observe: the measure writer did not answer: ' . ($@ || 'no uuid')) if $log && !$uuid;
	return { error => &subs::ui('The observation was not recorded.'), condition => $condition }
		unless $uuid;
	&cache_set({ app => 'weather', context => 'observe', subcontext => 'last', warranty => '-1d' }, {
		condition => $condition,
		at => $now,
		changed_at => $changed ? $now : ($last->{'changed_at'} || $now),
	});
	return {
		ok => 1,
		condition => $condition,
		changed => $changed ? 1 : 0,
		matched => $matched,
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
	my $am = &weather_observe_prepare();
	return { skipped => 'no rules' } unless @{ &weather_automation_rules($am) };
	my $now = &rightNow();
	my $lock = eval { &cache_get({ app => 'weather', context => 'observe', subcontext => 'lock' }) } || {};
	return { skipped => 'held', at => $lock->{'at'} }
		if ($lock->{'at'} || 0) > $now - 20 * 60 * 1000;
	&cache_set({ app => 'weather', context => 'observe', subcontext => 'lock', warranty => '-1d' }, { at => $now });
	my $result = &weather_observe_now({});
	if ($log) {
		$log->info('weather observe: ' . encode_json({
			map { $_ => $result->{$_} }
			grep { defined $result->{$_} }
			qw(ok skipped error condition changed)
		}));
	}
	return $result;
}

1;
