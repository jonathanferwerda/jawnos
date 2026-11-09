package Manager;

# manager_sound: the Sound app and the taskbar's volume reading.
#
# The status route is deliberately outside the /manager/sound prefix: it is
# read-only, and the taskbar widget must work for a resident session too. The
# window and the three writes live under /manager/sound, which the tier table
# keeps at resident - the same desk as the rest of /manager.
use strict;
use warnings;
use utf8;

# GET /manager/sound
sub action_53020 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $contents = $c->render_to_string(
		template => 'apps/sound',
		status => eval { &subs::sound_status() } || { ok => 0, outputs => [], inputs => [] },
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
	$c->render(json => eval { &subs::sound_status() } || { ok => 0, error => 'the sound reading failed' });
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

1;
