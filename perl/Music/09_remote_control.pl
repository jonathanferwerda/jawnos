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
	my $target = &subs::setting_grabber({ app => 'music', setting => 'remote_target' }) || '';
	my $widget_target = &subs::setting_grabber({ app => 'music', setting => 'widget_target' }) || '';
	# The panel's local chip is written as empty now; an older save of the chip
	# itself must not read back as a machine named 'local'.
	$target = '' if $target eq 'local';
	$widget_target = '' if $widget_target eq 'local';
	return {
		ok => 1,
		machines => &music_remote_machines(),
		target => $target,
		widget_target => $widget_target
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
	# A level the peer never wrote is not a level: null lets a controller show
	# its own bar until the peer's player has saved one.
	my $volume = $player->{'volume'};
	$volume = undef unless defined $volume && $volume =~ /^-?\d+(?:\.\d+)?$/;
	return {
		ok => 1,
		playing => ($player->{'state'} ? 1 : 0),
		file => $file,
		key => ($player->{'key'} || ''),
		title => $title,
		currentTime => ($player->{'currentTime'} || 0),
		duration => ($duration + 0),
		volume => (defined $volume ? $volume + 0 : undef),
		muted => ($player->{'muted'} ? 1 : 0),
		fullscreen => ($player->{'fullscreen'} ? 1 : 0)
	};
}

# The peer's browser is the only place a command can act. play_files carries its
# queue as an array, so the router receives data rather than source text.
sub music_transport_local($action, $opts = {}) {
	$action = '' unless defined $action;
	$action = lc $action;
	return 0 unless $action =~ /^(?:play|pause|toggle|next|prev|stop|open|seek_percent|play_files|play_track|volume|mute|fullscreen)$/;
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
	# A track press starts one file in the controlled machine's own queue. The
	# list is not replaced, so the tracks already played stay above it.
	if ($action eq 'play_track') {
		my $file = $opts->{'file'};
		return 0 unless defined $file && length $file;
		&Websocket::send('server', { console => &Websocket::console_command('musicPlayTrack', $file) });
		return 1;
	}
	# Mute keeps the level for the next play, so it is a switch of its own, not a
	# volume of zero. Only 0 or 1 crosses.
	if ($action eq 'mute') {
		my $on = $opts->{'value'};
		return 0 unless defined $on && $on =~ /^(?:0|1)$/;
		&Websocket::send('server', { console => &Websocket::console_command('musicMuteSet', $on + 0) });
		return 1;
	}
	# The controlled window's own big picture. The command arrives with no press
	# behind it, so the host puts up its full-screen dress and asks its desktop
	# shell for the trusted click that makes it the real top layer; a browser
	# keeps the dress until the next press, exactly as a reload restore does.
	if ($action eq 'fullscreen') {
		my $on = $opts->{'value'};
		return 0 unless defined $on && $on =~ /^(?:0|1|on|off|true|false)$/i;
		my $want = ($on =~ /^(?:1|on|true)$/i) ? 1 : 0;
		&Websocket::send('server', { console => &Websocket::console_command('musicFullscreenSet', $want) });
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
		value => $c->param('value'),
		file => $c->param('file')
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

# The host's own queue, compactly, for a controller that wants a short list to
# pick from. The queue cache is the order its window is showing; the player
# cache names the row that is playing. A long queue is answered around the
# current track, capped so one poll stays small.
sub music_remote_queue {
	my $queue = &subs::cache_get({ app => 'music', context => 'queue' }) || {};
	my $player = &subs::cache_get({ app => 'music', context => 'player' }) || {};
	my $files = (ref $queue->{'files'} eq 'ARRAY') ? $queue->{'files'} : [];
	my $current = $player->{'file'} || '';
	my $total = scalar @{$files};
	my $limit = 300;
	my $index = -1;
	if (length $current) {
		for my $i ( 0 .. $#{$files} ) {
			if (($files->[$i] // '') eq $current) { $index = $i; last; }
		}
	}
	my $start = 0;
	$start = $index - int($limit / 2) if $index >= 0;
	$start = 0 if $start < 0;
	$start = $total - $limit if $start + $limit > $total;
	$start = 0 if $start < 0;
	my $end = $start + $limit - 1;
	$end = $total - 1 if $end > $total - 1;
	my @songs;
	foreach my $file ( @{$files}[$start .. $end] ) {
		next unless defined $file && length $file;
		my @parts = split m{/}, $file;
		my $title = basename($file);
		$title =~ s/\.[^.\/]+$//;
		push @songs, {
			file => $file,
			title => (&subs::format_name($title) || $title),
			album => (@parts >= 2 && $parts[-2] ne '') ? &subs::format_name($parts[-2]) : '',
			artist => (@parts >= 3 && $parts[-3] ne '') ? &subs::format_name($parts[-3]) : '',
			current => (length $current && $file eq $current) ? 1 : 0
		};
	}
	return { ok => 1, total => $total, start => $start, count => scalar @songs, file => $current, songs => \@songs };
}

# ---- the controlled machine's outputs --------------------------------------
#
# The table has an internal speaker, the server player, and every peer as an
# output. A controller asks which one that machine is playing through and picks
# one; the choice is the host's own setting, written on the host, and only the
# host's browser is asked to notice it.
sub music_output_on($state) {
	return ($state // '') =~ /^(?:on|stereo|left|right)$/ ? 1 : 0;
}

sub music_output_catalogue {
	my $settings = &subs::settings_grabber({ app => 'music' }) || {};
	my $mao = eval { decode_json($settings->{'mao'} // '') } || {};
	my $self = &subs::signatorial_designer();
	my (@outputs, %seen);
	my $add = sub {
		my ($key, $label) = @_;
		return unless defined $key && length $key && !$seen{$key}++;
		my $state = $mao->{$key} // 'off';
		$state = 'off' unless $state =~ /^(?:off|on|stereo|left|right)$/;
		push @outputs, {
			key => $key,
			label => $label,
			state => $state,
			on => &music_output_on($state)
		};
	};
	$add->('me', (&subs::machine_name() || &subs::ui('This machine')) . ' (' . &subs::ui('internal speaker') . ')');
	$add->('srv', &subs::ui('Server'));
	foreach my $rm ( @{&subs::remote_machine_lister() || []} ) {
		next if (($rm->{'hostname'} || '') eq 'me' && ($rm->{'ip'} || '') eq '127.0.0.1');
		next if $self && (($rm->{'signatorial'} || '') eq $self);
		my $key = $rm->{'fqdn'} || $rm->{'ip'} || '';
		next unless length $key;
		# Loopback is this machine under another name, never a speaker: a
		# peer row left with 127.0.0.1 is a stale address, not an output.
		next if $key =~ /^(?:127\.|localhost$|\[?::1\]?$)/i;
		my $label = &subs::device_hostname_better($rm->{'hostname'}, '', $rm->{'fqdn'}) || $rm->{'hostname'} || $key;
		$add->($key, $label);
	}
	my $current = 'me';
	foreach my $output ( @outputs ) {
		if ($output->{'on'}) { $current = $output->{'key'}; last; }
	}
	return { ok => 1, outputs => \@outputs, current => $current };
}

# Choosing an output is a choice, not an addition: the picked one is the output
# the machine plays through, so every other key is written off. Keys the machine
# has written before stay in the map (as off) so the stream still knows them.
sub music_output_pick($key) {
	my $catalogue = &music_output_catalogue();
	return 0 unless grep { $_->{'key'} eq $key } @{$catalogue->{'outputs'}};
	my $settings = &subs::settings_grabber({ app => 'music' }) || {};
	my $mao = eval { decode_json($settings->{'mao'} // '') } || {};
	foreach my $other ( keys %{$mao} ) { $mao->{$other} = 'off'; }
	$mao->{$key} = 'on';
	&subs::setting_setter({ app => 'music', setting => 'mao', value => encode_json($mao) });
	# The setting is data; the host's player is what has to move its stream now.
	&Websocket::send('server', { console => &Websocket::console_command('musicOutputApply', encode_json($mao)) });
	return 1;
}

# ---- the controlled machine's physical devices -----------------------------
#
# A stream output says where the player's copy goes; a device says which
# speaker, headphone jack or Bluetooth sink that machine's own sound comes out
# of. It is the same default the Sound app's IO section sets, read and written
# on the controlled machine so the controller never changes its own hardware.
sub music_remote_devices_read {
	my $status = eval { &subs::sound_status() } || {};
	my @outputs;
	foreach my $device ( @{ $status->{'outputs'} || [] } ) {
		next unless ref $device eq 'HASH' && defined $device->{'id'} && length $device->{'id'};
		push @outputs, {
			id => $device->{'id'},
			label => ($device->{'name'} || $device->{'id'}),
			default => ($device->{'default'} ? 1 : 0)
		};
	}
	my $current = (ref $status->{'output'} eq 'HASH') ? ($status->{'output'}->{'id'} // '') : '';
	return {
		ok => 1,
		backend => ($status->{'backend'} || ''),
		outputs => \@outputs,
		current => $current
	};
}

sub music_remote_device_pick($id) {
	return 0 unless defined $id && length $id;
	my $result = eval { &subs::sound_default('output', $id) } || {};
	return (ref $result eq 'HASH' && $result->{'ok'}) ? 1 : 0;
}

# The controlled machine's own outputs, for the Sound window's Remote pill. A
# machine that has gone offline answers as the transport does.
Manager::app->routes->get('/music/remote_outputs' => sub ($c) {
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
	$c->render(json => &music_output_catalogue());
});

# The controlled machine's physical outputs, for the Sound window's Remote
# pill. A machine with no sound backend answers an empty list, not an error.
Manager::app->routes->get('/music/remote_devices' => sub ($c) {
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
	$c->render(json => &music_remote_devices_read());
});

# Pick the speaker, headphones or Bluetooth sink the controlled machine plays
# through. The write is its default output, exactly as the Sound app sets it.
Manager::app->routes->post('/music/remote_device' => sub ($c) {
	my $target = $c->param('target') || '';
	my $remoted = (($c->param('remoted') // '') eq 'yes') ? 1 : 0;
	my $id = $c->param('id') || '';
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
	my $ok = &music_remote_device_pick($id);
	$c->render(json => { ok => $ok ? 1 : 0, id => $id });
});

# Pick the output the controlled machine plays through. It is the host's own
# `mao` setting, so a controller never changes this machine's outputs.
Manager::app->routes->post('/music/remote_output' => sub ($c) {
	my $target = $c->param('target') || '';
	my $remoted = (($c->param('remoted') // '') eq 'yes') ? 1 : 0;
	my $output = $c->param('output') || '';
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
	my $ok = &music_output_pick($output);
	$c->render(json => { ok => $ok ? 1 : 0, output => $output });
});

# A short list of the controlled machine's own queue, for the Sound window's
# Remote pill. A machine that has gone offline answers as the transport does.
Manager::app->routes->get('/music/remote_queue' => sub ($c) {
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
	$c->render(json => &music_remote_queue());
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
