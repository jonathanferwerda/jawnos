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
use strict;
use warnings;
use utf8;

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

1;
