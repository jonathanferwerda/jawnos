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

# POST /manager/sound/plan - save the house's routing plan
sub action_53030 {
	my $c = shift;
	my $raw = $c->param('plan');
	my $plan = (defined $raw && length $raw) ? eval { decode_json($raw) } : undef;
	my $result = eval { &subs::audio_plan_write($plan) };
	$c->render(json => $result || { ok => 0, error => 'the plan could not be saved' });
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
sub action_53033 {
	my $c = shift;
	my $route = $c->param('route');
	my $name  = $c->param('name');
	my $value = $c->param('value');

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

1;
