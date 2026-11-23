package Manager;

# manager_sound: the Sound app and the taskbar's volume reading.
#
# The status route is deliberately outside the /manager/sound prefix: it is
# read-only, and the taskbar widget must work for a resident session too. The
# window and the writes live under /manager/sound, which the tier table keeps
# at resident - the same desk as the rest of /manager.
#
# The four sound levels live here too: the house level is a setting, and one
# app's profile is the same setting on that app's row, so the widget and the
# window save through these routes and read the same resolved answer.
#
# The house patchbay's plan is one setting too (Domain::Audio); the window reads
# it with the page and saves it through /manager/sound/plan, while the taskbar's
# status poll stays free of the engine's socket.
use strict;
use warnings;
use utf8;

use Mojo::JSON qw(decode_json);

# The device reading plus the levels the house resolves from it. One shape, so
# the widget's poll and the window's render never disagree.
sub sound_reading {
	my $status = eval { &subs::sound_status() } || { ok => 0, outputs => [], inputs => [] };
	$status->{'level'} = eval { &subs::sound_house_setting_level() } || 'sound';
	$status->{'house_level'} = eval { &subs::sound_house_level() } || $status->{'level'};
	$status->{'profiles'} = eval { &subs::sound_profiles_list() } || [];
	return $status;
}

# GET /manager/sound
sub action_53020 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $reading = &sound_reading();
	# The datalist is only for the window; the widget's poll stays small.
	$reading->{'apps'} = eval { &subs::sound_app_choices() } || [];
	my $contents = $c->render_to_string(
		template => 'apps/sound',
		status => $reading,
	);
	my $window = &window_maker({
		user_agent => $c->param('user_agent'),
		app => 'sound',
		contents => $contents,
	}, $timestamp);
	$c->render(json => { window => $window });
}

# GET /manager/sound_status
sub action_53021 {
	my $c = shift;
	$c->render(json => &sound_reading());
}

# POST /manager/sound/volume
sub action_53022 {
	my $c = shift;
	my $result = eval {
		&subs::sound_set(
			$c->param('kind'),
			$c->param('id'),
			$c->param('volume'),
		);
	};
	$c->render(json => $result || { ok => 0, error => 'the volume could not be set' });
}

# POST /manager/sound/mute
sub action_53023 {
	my $c = shift;
	my $result = eval {
		&subs::sound_mute(
			$c->param('kind'),
			$c->param('id'),
			$c->param('mute'),
		);
	};
	$c->render(json => $result || { ok => 0, error => 'the mute state could not be set' });
}

# POST /manager/sound/default
sub action_53024 {
	my $c = shift;
	my $result = eval {
		&subs::sound_default(
			$c->param('kind'),
			$c->param('id'),
		);
	};
	$c->render(json => $result || { ok => 0, error => 'the default device could not be set' });
}

# POST /manager/sound/level - the house level from the widget or the window
sub action_53025 {
	my $c = shift;
	eval { &subs::sound_house_level_write($c->param('level')) };
	$c->render(json => &sound_reading());
}

# POST /manager/sound/profile - one app's own level
sub action_53026 {
	my $c = shift;
	eval { &subs::sound_app_level_write($c->param('app'), $c->param('level')) };
	$c->render(json => &sound_reading());
}

# POST /manager/sound/plan - save the house's routing plan and its uplink.
# The uplink is a house setting too, so it rides this existing save path rather
# than a route of its own: a request may carry a plan, an uplink, or both. A
# request with only an uplink must not overwrite the stored plan with an empty
# document, so each half is saved only when it was posted.
sub action_53030 {
	my $c = shift;
	my $raw = $c->param('plan');
	my $uplink = $c->param('uplink');

	my $saved_plan;
	my $saved_uplink;
	if (defined $raw && length $raw) {
		my $plan = eval { decode_json($raw) };
		$saved_plan = eval { &subs::audio_plan_write($plan) };
		$saved_plan = { ok => 0, error => 'the plan could not be saved' }
			unless ref $saved_plan eq 'HASH';
	}
	if (defined $uplink) {
		$saved_uplink = eval { &subs::audio_uplink_write($uplink) };
		$saved_uplink = { ok => 0, error => 'the uplink could not be saved' }
			unless ref $saved_uplink eq 'HASH';
	}

	my $result;
	if ($saved_plan && $saved_uplink) {
		$result = { %{$saved_plan}, %{$saved_uplink} };
		$result->{ok} = ($saved_plan->{ok} && $saved_uplink->{ok}) ? 1 : 0;
		$result->{error} = $saved_plan->{error} || $saved_uplink->{error}
			unless $result->{ok};
	}
	elsif ($saved_plan)    { $result = $saved_plan }
	elsif ($saved_uplink)  { $result = $saved_uplink }
	else {
		$result = { ok => 0, error => 'the plan could not be saved' };
	}
	$c->render(json => $result);
}

# GET /manager/sound/plan - the saved plan, the switch and the engine's answer
sub action_53031 {
	my $c = shift;
	$c->render(json => eval { &subs::audio_plan_status() }
		|| { plan => { sources => [], buses => [], sinks => [], routes => [] }, manage => 0, engine_available => 0 });
}

# POST /manager/sound/manage - the master switch beside the management line
sub action_53032 {
	my $c = shift;
	my $on = ($c->param('manage') || '') =~ /^(?:1|yes|on|true)$/i ? 1 : 0;
	my $result = eval { &subs::audio_manage_set($on) };
	$c->render(json => $result || { ok => 0, error => 'the switch could not be saved' });
}

# POST /manager/sound/param - one live fader on the running patch. The route
# number is the 0-based index in the plan's routes array; the engine clamps the
# value and refuses a muted route, so its answer is what the page shows.
#
# `target=patch_source` addresses a source instead: `source` is the 0-based
# index in the plan's `sources` array, and `name` is `gain`, `mute` or one
# `<insert>.<control>` the source actually armed. The engine is the authority on
# whether that insert is in the source's chain, exactly as it is for a route.
sub action_53033 {
	my $c = shift;
	my $target = $c->param('target');
	my $name   = $c->param('name');
	my $value  = $c->param('value');

	if (defined $target && $target eq 'patch_source') {
		my $source = $c->param('source');
		my $error;
		if (!defined $source || $source !~ /\A\d+\z/) {
			$error = 'a source number is a whole, non-negative index';
		}
		elsif (!defined $name || ($name ne 'gain'
			&& $name ne 'mute'
			&& $name !~ /\A[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*\z/)) {
			$error = 'a source fader is named gain, mute or <insert>.<control>';
		}
		elsif (!defined $value
			|| $value !~ /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/) {
			$error = 'a fader value is a finite number';
		}
		if ($error) {
			$c->render(json => { ok => 0, error => $error });
			return;
		}
		require JawnOS::Audio::Engine;
		my $result = eval {
			JawnOS::Audio::Engine::audio_engine_patch_source_param(
				$source + 0, $name, $value + 0,
			);
		};
		$c->render(json => $result || { ok => 0, error => 'the source fader could not be set' });
		return;
	}

	my $route = $c->param('route');

	my $error;
	if (!defined $route || $route !~ /\A\d+\z/) {
		$error = 'a route number is a whole, non-negative index';
	}
	elsif (!defined $name || ($name ne 'gain' && $name ne 'pan')) {
		$error = 'a patch fader is named gain or pan';
	}
	elsif (!defined $value
		|| $value !~ /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/) {
		$error = 'a fader value is a finite number';
	}

	if ($error) {
		$c->render(json => { ok => 0, error => $error });
		return;
	}

	require JawnOS::Audio::Engine;
	my $result = eval {
		JawnOS::Audio::Engine::audio_engine_patch_param($route + 0, $name, $value + 0);
	};
	$c->render(json => $result || { ok => 0, error => 'the fader could not be set' });
}

# POST /manager/sound/device - the interface the engine opens. The picker
# writes the supervisor's startup copy and, while the engine is up, quits it so
# the supervisor restarts on the new device.
sub action_53034 {
	my $c = shift;
	my $result = eval {
		&subs::audio_engine_device_write($c->param('backend'), $c->param('device'));
	};
	$c->render(json => $result || { ok => 0, error => 'the engine device could not be saved' });
}

# GET /manager/sound/apps - the Apps pill: the house channels, the JawnOS app
# levels and every playback and recording stream the sound system reports.
sub action_53035 {
	my $c = shift;
	my $reading = eval { &subs::sound_apps_reading() };
	$c->render(json => $reading || {
		ok => 0, error => 'the streams could not be read',
		channels => {}, apps => [], playback => [], recording => [],
	});
}

# POST /manager/sound/app - one fader, mute or app level from the Apps pill.
# kind is channel, app, playback or recording; a successful answer carries the
# fresh reading so the window updates from one response.
sub action_53036 {
	my $c = shift;
	my $result = eval {
		&subs::sound_apps_set(
			$c->param('kind'),
			$c->param('name'),
			$c->param('id'),
			$c->param('volume'),
			$c->param('muted'),
			$c->param('level'),
		);
	};
	$result = { ok => 0, error => 'the sound could not be set' } unless ref $result eq 'HASH';
	if ($result->{'ok'}) {
		my $reading = eval { &subs::sound_apps_reading() } || {};
		$result = { %{$reading}, %{$result} };
	}
	$c->render(json => $result);
}

# POST /manager/sound/monitor - monitor several inputs at once, or stop or
# read the monitor. `channels` is a comma list (`0,1`) or a JSON array; one
# channel is the historical Listen and keeps its behaviour. The engine builds
# one strip per input and sums them on the output, so `gain`, `pan` and the
# insert chain are the same controls a single Listen has.
#
# The patchbay is the house's multi-source path when a plan is running: every
# routed source already mixes to the sink, and `sources[]` in its status names
# them. This route is for hearing several device inputs before a plan exists.
sub action_53037 {
	my $c = shift;
	require JawnOS::Audio::Engine;

	my $action = $c->param('action');
	$action = 'start' unless defined $action && length $action;
	if ($action eq 'status') {
		$c->render(json => &JawnOS::Audio::Engine::audio_engine_status());
		return;
	}
	if ($action eq 'stop') {
		$c->render(json => &JawnOS::Audio::Engine::audio_engine_stop());
		return;
	}
	if ($action ne 'start') {
		$c->render(json => { ok => 0, error => 'choose an action: start, stop or status' }, status => 400);
		return;
	}

	my ($error, $channels) = &sound_monitor_channels($c->param('channels'));
	if (defined $error) {
		$c->render(json => { ok => 0, error => $error }, status => 400);
		return;
	}

	my $gain = &sound_monitor_number($c->param('gain'), 0.8, 0, 4);
	if (!defined $gain) {
		$c->render(json => { ok => 0, error => 'gain must be a finite number between 0 and 4' }, status => 400);
		return;
	}
	my $pan = &sound_monitor_number($c->param('pan'), 0, -1, 1);
	if (!defined $pan) {
		$c->render(json => { ok => 0, error => 'pan must be a finite number between -1 and 1' }, status => 400);
		return;
	}

	my @inserts;
	my $inserts = $c->param('inserts');
	if (defined $inserts && length $inserts) {
		for my $part (split /,/, $inserts) {
			$part =~ s/\A\s+|\s+\z//g;
			next unless length $part;
			if ($part !~ /\A[a-z][a-z0-9_]*\z/) {
				$c->render(json => { ok => 0, error => "no such insert: $part" }, status => 400);
				return;
			}
			push @inserts, $part;
		}
	}

	# Studio's monitor carries its own capture only by default: folding the
	# machine's mix into it makes the page's own monitor audible again.
	my $system = $c->param('system');
	my $system_value = 0;
	if (defined $system && length $system) {
		if ($system !~ /\A\s*(?:0|1|true|false)\s*\z/i) {
			$c->render(json => { ok => 0, error => 'system must be 0 or 1' }, status => 400);
			return;
		}
		$system_value = ($system =~ /\A\s*(?:0|false)\s*\z/i) ? 0 : 1;
	}

	my $answer = eval {
		JawnOS::Audio::Engine::audio_engine_listen_channels(
			$channels, $gain, $pan, \@inserts, $system_value,
		);
	};
	$answer = { ok => 0, error => 'the monitor could not be started' }
		unless ref $answer eq 'HASH';
	$c->render(json => $answer);
}

# A `channels` field as a list of device inputs: `0,1` or `[0,1]`. The engine
# refuses an input the device does not have; this only refuses a shape that
# could never be a channel list, and a duplicate that would monitor one input
# twice.
sub sound_monitor_channels {
	my ($value) = @_;
	$value = '0' unless defined $value && length $value;
	$value =~ s/\A\s+|\s+\z//g;
	my @parts;
	if ($value =~ /\A\[/) {
		my $decoded = eval { decode_json($value) };
		return ('channels must be a JSON array of input numbers', undef)
			unless ref $decoded eq 'ARRAY';
		@parts = @$decoded;
	}
	else {
		@parts = split /,/, $value;
		for my $part (@parts) {
			$part =~ s/\A\s+|\s+\z//g;
		}
	}
	@parts = grep { defined $_ && length $_ } @parts;
	return ('channels must name at least one input', undef) unless @parts;
	my (@channels, %seen);
	for my $part (@parts) {
		return ('channels must be whole input numbers between 0 and 31', undef)
			unless $part =~ /\A\d+\z/ && $part <= 31;
		return ("channel $part is named twice", undef) if $seen{$part}++;
		push @channels, $part + 0;
	}
	return (undef, \@channels);
}

# A finite number in a range, with a default for an absent field. `undef` means
# the caller sent something that is not a number or is outside the range.
sub sound_monitor_number {
	my ($value, $default, $low, $high) = @_;
	return $default unless defined $value && length $value;
	return undef
		unless $value =~ /\A\s*[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?\s*\z/;
	$value += 0;
	return undef unless $value == $value && ($value - $value) == 0;
	return undef if $value < $low || $value > $high;
	return $value;
}

1;
