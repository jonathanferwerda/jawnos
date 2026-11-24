package Manager;

# Remote Music control: one machine tells another machine's Music app what to
# do. Three callers share these routes - the Sound taskbar widget, the Music
# window's own remote panel, and a relayed command that arrives with remoted=yes
# and runs here.
#
# The command is never source. The peer's browser owns the only table of
# instructions it will run (public/js/manager/websocket/00_console_router.js), and
# this file only names an entry in it. That keeps a relayed string from becoming
# code on the far side.

use strict;
use warnings;
no warnings 'uninitialized';
use feature 'signatures';

use Mojo::JSON qw(decode_json encode_json);
use File::Basename qw(basename);

# The peers a person may control: every active machine but this one and the
# server. A server has no browser, so it has no Music app to command; the
# synthetic 'me' row is the picker's, not a peer.
sub music_remote_machines {
	my $rows = &subs::remote_machine_lister({ self => 'no' }) || [];
	my $me = &subs::signatorial_designer();
	my (@out, %seen);
	foreach my $rm ( @{$rows} ) {
		next if (($rm->{'hostname'} || '') eq 'me' && ($rm->{'ip'} || '') eq '127.0.0.1');
		next if $me && (($rm->{'signatorial'} || '') eq $me);
		next if (($rm->{'device'} || '') eq 'server');
		next unless (($rm->{'connection'} || '') eq 'active');
		my $uuid = $rm->{'uuid'} || '';
		next unless length $uuid && !$seen{$uuid}++;
		push @out, {
			uuid => $uuid,
			label => &subs::device_hostname_better($rm->{'hostname'}, '', $rm->{'fqdn'}) || $rm->{'hostname'} || $uuid,
			hostname => ($rm->{'hostname'} || ''),
			device => ($rm->{'device'} || '')
		};
	}
	return \@out;
}

# The row a saved target names. A machine that has gone offline is not a
# target any more: a command would be a silent loss, so the answer says so.
sub music_remote_row($uuid) {
	return unless defined $uuid && length $uuid && $uuid ne 'local';
	return &subs::db_query('select * from remote_machines where uuid=? and connection=?', $uuid, 'active')->hashes->[0];
}

# The two pickers, in one answer. The Music window's target and the taskbar
# widget's target are deliberately separate: choosing a machine in the widget
# must not turn the Music window into its controller, and the other way round.
sub music_remote_picker {
	return {
		ok => 1,
		machines => &music_remote_machines(),
		target => (&subs::setting_grabber({ app => 'music', setting => 'remote_target' }) || ''),
		widget_target => (&subs::setting_grabber({ app => 'music', setting => 'widget_target' }) || '')
	};
}

# The player cache is written by the browser that is playing, so it is the only
# truth about a machine whose app is not on this screen. A missing cache reads
# as paused, not as an error: a machine whose Music app never opened answers the
# same shape as one that is stopped.
sub music_transport_state {
	my $player = &subs::cache_get({ app => 'music', context => 'player' }) || {};
	my $file = $player->{'file'} || '';
	my $title = $file ? basename($file) : '';
	$title =~ s/\.[^.\/]+$// if length $title;
	$title = &subs::format_name($title) if length $title;
	my $duration = $player->{'duration'};
	$duration = 0 unless defined $duration && $duration =~ /^\d+(?:\.\d+)?$/;
	return {
		ok => 1,
		playing => ($player->{'state'} ? 1 : 0),
		file => $file,
		key => ($player->{'key'} || ''),
		title => $title,
		currentTime => ($player->{'currentTime'} || 0),
		duration => ($duration + 0),
		volume => ($player->{'volume'} || 0),
		muted => ($player->{'muted'} ? 1 : 0)
	};
}

# The peer's browser is the only place a command can act. play_files carries its
# queue as an array, so the router receives data rather than source text.
sub music_transport_local($action, $opts = {}) {
	$action = '' unless defined $action;
	$action = lc $action;
	return 0 unless $action =~ /^(?:play|pause|toggle|next|prev|stop|open|seek_percent|play_files|volume)$/;
	if ($action eq 'play_files') {
		my $files = $opts->{'files'};
		return 0 unless ref $files eq 'ARRAY' && scalar @{$files};
		&Websocket::send('server', {
			console => &Websocket::console_command(
				'musicPlayFiles',
				$files,
				$opts->{'same_order'} ? 1 : 0,
				($opts->{'key'} || '')
			)
		});
		return 1;
	}
	# Volume is the controlled player's own level, the same one its slider
	# writes: clamp it here so a caller cannot hand the peer a wild value.
	if ($action eq 'volume') {
		my $level = $opts->{'value'};
		return 0 unless defined $level && $level =~ /^-?\d+(?:\.\d+)?$/;
		$level = 0 if $level < 0;
		$level = 1 if $level > 1;
		&Websocket::send('server', { console => &Websocket::console_command('musicVolumeSet', $level + 0) });
		return 1;
	}
	my @args = ($action);
	push @args, ($opts->{'percent'} + 0) if $action eq 'seek_percent' && defined $opts->{'percent'};
	&Websocket::send('server', { console => &Websocket::console_command('musicTransportLocal', @args) });
	return 1;
}

# The settings a controller may change on the machine it is controlling. A
# whitelist, not a filter: `library` would move the host's own library, and
# `remote_target` would make the host try to control a third machine.
my %music_remote_setting = map { $_ => 1 } qw(normalize video equalizer subtitles);

sub music_remote_setting_write($setting, $value) {
	return 0 unless defined $setting && $music_remote_setting{$setting};
	&subs::setting_setter({ app => 'music', setting => $setting, value => (defined $value ? $value : '') });
	# The setting is data in the host's database; the player in its browser is
	# what has to hear it now. This console command applies it without a reload.
	&Websocket::send('server', {
		console => &Websocket::console_command('musicSettingApply', $setting, defined $value ? $value : '')
	});
	return 1;
}

# A write handed to a peer. remote_relay_request signs the request with this
# machine's key and returns the peer's body; a dead route is an answer of its
# own, never this machine's result.
sub music_remote_relay($c) {
	my $result = &Manager::remote_relay_request($c);
	my $reply = eval { decode_json($result || '') };
	return ref $reply eq 'HASH' ? $reply : { ok => 0, error => 'that machine did not answer' };
}

Manager::app->routes->get('/music/remote_machines' => sub ($c) {
	$c->render(json => &music_remote_picker());
});

# Remember which machine a picker is controlling. scope=widget is the Sound
# taskbar's memory; everything else is the Music window's own.
Manager::app->routes->post('/music/remote_target' => sub ($c) {
	my $scope = (($c->param('scope') // '') eq 'widget') ? 'widget' : 'window';
	my $target = $c->param('target') || '';
	$target = '' if $target eq 'local';
	if ($target && !&music_remote_row($target)) {
		$c->render(json => { ok => 0, error => 'that machine is not reachable' });
		return;
	}
	my $setting = $scope eq 'widget' ? 'widget_target' : 'remote_target';
	&subs::setting_setter({ app => 'music', setting => $setting, value => $target });
	$c->render(json => { ok => 1, scope => $scope, target => $target });
});

# Play, pause, next, previous, open or hand a queue to a machine's Music app.
# A target that is this machine (or a relayed command) acts here; any other
# target is relayed to the machine named.
Manager::app->routes->post('/music/transport' => sub ($c) {
	my $target = $c->param('target') || '';
	my $remoted = (($c->param('remoted') // '') eq 'yes') ? 1 : 0;
	my $action = $c->param('action') || '';
	my $files = [];
	if (($c->param('files') // '') ne '') {
		$files = eval { decode_json($c->param('files')) } || [];
	}
	my %opts = (
		files => $files,
		same_order => ($c->param('same_order') ? 1 : 0),
		key => ($c->param('key') || ''),
		percent => $c->param('percent'),
		value => $c->param('value')
	);
	if ($target && $target ne 'local' && !$remoted) {
		my $rm = &music_remote_row($target);
		unless ($rm) {
			$c->render(json => { ok => 0, error => 'that machine is not reachable' });
			return;
		}
		$c->param('remote_uuid' => $rm->{'uuid'});
		$c->param('subprocess' => 'yes');
		$c->render(json => &music_remote_relay($c));
		return;
	}
	my $ok = &music_transport_local($action, \%opts);
	$c->render(json => { ok => $ok ? 1 : 0, action => $action });
});

# What the target's player is doing. The taskbar widget and the Music window
# both read this shape, so a remote room looks the same in either place.
Manager::app->routes->get('/music/transport_state' => sub ($c) {
	my $target = $c->param('target') || '';
	my $remoted = (($c->param('remoted') // '') eq 'yes') ? 1 : 0;
	if ($target && $target ne 'local' && !$remoted) {
		my $rm = &music_remote_row($target);
		unless ($rm) {
			$c->render(json => { ok => 0, error => 'that machine is not reachable' });
			return;
		}
		$c->param('remote_uuid' => $rm->{'uuid'});
		$c->param('subprocess' => 'yes');
		$c->render(json => &music_remote_relay($c));
		return;
	}
	$c->render(json => &music_transport_state());
});

# One playback setting, written where the controlled machine's player reads it.
Manager::app->routes->post('/music/remote_setting' => sub ($c) {
	my $target = $c->param('target') || '';
	my $remoted = (($c->param('remoted') // '') eq 'yes') ? 1 : 0;
	my $setting = $c->param('setting') || '';
	my $value = $c->param('value');
	unless ($music_remote_setting{$setting}) {
		$c->render(json => { ok => 0, error => 'that setting cannot be controlled remotely' });
		return;
	}
	if ($target && $target ne 'local' && !$remoted) {
		my $rm = &music_remote_row($target);
		unless ($rm) {
			$c->render(json => { ok => 0, error => 'that machine is not reachable' });
			return;
		}
		$c->param('remote_uuid' => $rm->{'uuid'});
		$c->param('subprocess' => 'yes');
		$c->render(json => &music_remote_relay($c));
		return;
	}
	my $ok = &music_remote_setting_write($setting, $value);
	$c->render(json => { ok => $ok ? 1 : 0, setting => $setting });
});

# The controlled machine's playback settings, for the panel to show the values
# its player is actually using instead of this machine's.
Manager::app->routes->get('/music/remote_settings' => sub ($c) {
	my $target = $c->param('target') || '';
	my $remoted = (($c->param('remoted') // '') eq 'yes') ? 1 : 0;
	if ($target && $target ne 'local' && !$remoted) {
		my $rm = &music_remote_row($target);
		unless ($rm) {
			$c->render(json => { ok => 0, error => 'that machine is not reachable' });
			return;
		}
		$c->param('remote_uuid' => $rm->{'uuid'});
		$c->param('subprocess' => 'yes');
		$c->render(json => &music_remote_relay($c));
		return;
	}
	my $settings = &subs::settings_grabber({ app => 'music' }) || {};
	$c->render(json => {
		ok => 1,
		normalize => ($settings->{'normalize'} || 'off'),
		video => (eval { decode_json($settings->{'video'} // '') } || {}),
		equalizer => (eval { decode_json($settings->{'equalizer'} // '') } || {})
	});
});

1;
