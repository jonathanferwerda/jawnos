package Manager;
use strict;
use warnings;
no warnings 'uninitialized';
use feature 'signatures';

use Mojo::JSON qw(decode_json encode_json);
use File::Slurp;
use URI::Encode qw(uri_encode);

our ($music_device, $music_config);

# ---- remote video: frames, not a file --------------------------------------
#
# A picture needs a screen, so the receiver is the peer's own browser rather
# than `pacat`. These are the peers that can show one: every active machine but
# this one and the server. The synthetic 'me' row is the machine picker's, not a
# peer, and a video never carries itself as an output.
sub music_video_machines {
	my $rows = &subs::remote_machine_lister({ self => 'no' }) || [];
	my $me = &subs::signatorial_designer();
	my $mvo = &music_video_settings();
	my (@out, %seen);
	foreach my $rm ( @{$rows} ) {
		next if (($rm->{'hostname'} || '') eq 'me' && ($rm->{'ip'} || '') eq '127.0.0.1');
		next if $me && (($rm->{'signatorial'} || '') eq $me);
		next if (($rm->{'device'} || '') eq 'server');
		next unless (($rm->{'connection'} || '') eq 'active');
		my $key = $rm->{'fqdn'} || $rm->{'ip'};
		next unless $key && !$seen{$key}++;
		push @out, {
			key => $key,
			label => &subs::device_hostname_better($rm->{'hostname'}, '', $rm->{'fqdn'}) || $rm->{'hostname'} || $key,
			device => ($rm->{'device'} || ''),
			uuid => ($rm->{'uuid'} || ''),
			# no row means the machine is on, which is how the section
			# behaved before the TV boxes; an explicit 'off' is a choice
			enabled => ((defined $mvo->{$key} && $mvo->{$key} eq 'off') ? 0 : 1)
		};
	}
	return \@out;
}

# The TV boxes' on/off map. A missing key means on, which is how the section
# behaved before the boxes; an explicit 'off' is a choice. 'me' is this
# machine's own screen, keyed like a peer so one map holds both.
sub music_video_settings {
	return eval { decode_json(&subs::setting_grabber({ app => 'music', setting => 'mvo' }) // '') } || {};
}

sub music_video_local_enabled {
	my $mvo = &music_video_settings();
	return (defined $mvo->{'me'} && $mvo->{'me'} eq 'off') ? 0 : 1;
}

sub music_video_source_uri($rm) {
	my $host = $rm->{'ip'};
	if (!$host) {
		my $url = eval { Mojo::URL->new($rm->{'manager'}) };
		$host = $url ? $url->host : '';
	}
	return unless $host;
	my $port = $rm->{'ws_port'} || $music_config->{'ws_port'} || '';
	return 'wss://' . $host . ($port ? ':' . $port : '') . '/manager/music/video';
}

sub music_video_source_retry($st, $key) {
	return unless $st->{'want'} && $st->{'want'}->{$key};
	my $n = ($st->{'retries'}->{$key} || 0);
	return if $n >= 3;
	$st->{'retries'}->{$key} = $n + 1;
	my $browser = $st->{'browser'};
	Mojo::IOLoop->timer(5 => sub {
		return unless $browser && $browser->tx->is_websocket;
		return unless $st->{'want'} && $st->{'want'}->{$key};
		&music_video_source_client_open($browser, $st, $key) unless $st->{'clients'}->{$key};
	});
}

sub music_video_source_client_open($c, $st, $key) {
	return if $st->{'clients'}->{$key};
	my $rm = &music_source_row($key);
	unless ($rm && $rm->{'uuid'}) {
		$c->tx->send({text => encode_json({ type => 'error', key => $key, error => 'unreachable' })}) if $c->tx->is_websocket;
		return;
	}
	return if (($rm->{'device'} || '') eq 'server');
	my $url = &music_video_source_uri($rm);
	return unless $url;
	my $ua = Mojo::UserAgent->new()->insecure(1)->connect_timeout(5)->request_timeout(0)->inactivity_timeout(0);
	$ua->on(start => sub { my ($ua, $tx) = @_; &subs::peer_sign_request($tx->req); });
	my $cl = { key => $key, rm => $rm, ua => $ua, up => 0, ready => 0 };
	$st->{'clients'}->{$key} = $cl;
	my $source = &subs::signatorial_designer();
	my $full = $url . '?peer=1&signatorial=' . uri_encode($source)
		. '&stream=' . uri_encode($st->{'stream'}) . '&from=' . uri_encode($key);
	$ua->websocket($full => sub {
		my ($ua, $tx) = @_;
		if (!$tx->is_websocket) {
			delete $st->{'clients'}->{$key};
			$c->tx->send({text => encode_json({ type => 'error', key => $key, error => 'connect' })}) if $c->tx->is_websocket;
			$c->tx->send({text => encode_json({ type => 'peer', key => $key, state => 'error' })}) if $c->tx->is_websocket;
			&music_video_source_retry($st, $key);
			return;
		}
		$cl->{'tx'} = $tx;
		$cl->{'up'} = 1;
		delete $st->{'retries'}->{$key};
		$c->tx->send({text => encode_json({ type => 'peer', key => $key, state => 'open' })}) if $c->tx->is_websocket;
		my $delays = ($st->{'hello'}->{'delays'} || {});
		my $hello = {
			type => 'hello',
			stream => $st->{'stream'},
			source => $source,
			key => $key,
			title => ($st->{'hello'}->{'title'} || ''),
			width => ($st->{'hello'}->{'width'} || 0),
			height => ($st->{'hello'}->{'height'} || 0),
			fps => ($st->{'hello'}->{'fps'} || 24),
			enhance => ($st->{'hello'}->{'enhance'} || {}),
			# the audio path has already measured this peer; the picture waits
			# that long in the receiver, so the lips and the words agree
			delay_ms => (($delays && $delays->{$key}) || 100)
		};
		eval { $tx->send({text => encode_json($hello)}); };
		$tx->on(text => sub {
			my ($tx, $msg) = @_;
			my $d = eval { decode_json $msg } || {};
			if (($d->{'type'} || '') eq 'closed') { $cl->{'up'} = 0; }
			if (($d->{'type'} || '') eq 'receiver') {
				$cl->{'ready'} = ($d->{'ready'} ? 1 : 0);
				$c->tx->send({text => encode_json({ type => 'peer', key => $key, state => ($cl->{'ready'} ? 'ready' : 'open') })}) if $c->tx->is_websocket;
			}
		});
		$tx->on(finish => sub {
			$cl->{'up'} = 0;
			delete $st->{'clients'}->{$key};
			$c->tx->send({text => encode_json({ type => 'peer', key => $key, state => 'closed' })}) if $c->tx->is_websocket;
			# a peer that reboots or wakes is reopened while the picture is
			# still wanted; three tries is enough to ride out a reboot
			&music_video_source_retry($st, $key);
		});
	});
}

sub music_video_source_sync_outputs($c, $st, $outputs) {
	my %want;
	foreach my $key ( @{$outputs || []} ) {
		next unless defined $key && length $key;
		$want{$key} = 1;
	}
	$st->{'want'} = \%want;
	foreach my $key (keys %want) {
		&music_video_source_client_open($c, $st, $key) unless $st->{'clients'}->{$key};
	}
	foreach my $key (keys %{$st->{'clients'}}) {
		next if exists $want{$key};
		my $cl = delete $st->{'clients'}->{$key};
		next unless $cl->{'tx'};
		eval { $cl->{'tx'}->send({text => encode_json({ type => 'control', action => 'stop' })}); $cl->{'tx'}->finish; };
	}
}

sub music_video_source_forward($st, $data) {
	my $json = encode_json($data);
	foreach my $key (keys %{$st->{'clients'}}) {
		my $cl = $st->{'clients'}->{$key};
		next unless $cl->{'up'} && $cl->{'tx'};
		eval { $cl->{'tx'}->send({text => $json}); };
	}
}

sub music_video_source_close($st) {
	delete $st->{'want'};
	&music_video_pump_stop($st);
	foreach my $key (keys %{$st->{'clients'}}) {
		my $cl = delete $st->{'clients'}->{$key};
		next unless $cl->{'tx'};
		eval { $cl->{'tx'}->send({text => encode_json({ type => 'control', action => 'stop' })}); $cl->{'tx'}->finish; };
	}
}

# ---- the frame pump ---------------------------------------------------------
#
# The browser cannot draw a playing <video> into a canvas on WebKitGTK: both
# drawImage and createImageBitmap yield a blank frame, which is why a peer saw
# a solid colour instead of the picture. The manager already holds the file and
# ffmpeg, so it renders the frames itself and the browser's only job is to say
# where the player is. Receivers are unchanged - they still draw JPEG frames.

sub music_video_pump_stop($st) {
	my $pid = delete $st->{'pump_pid'};
	if ($st->{'pump_stream'}) {
		$st->{'pump_stream'}->close;
		delete $st->{'pump_stream'};
	}
	if ($st->{'pump_fh'}) {
		eval { close $st->{'pump_fh'}; };
		delete $st->{'pump_fh'};
	}
	if ($pid) {
		eval { kill 'CONT', $pid; };
		eval { kill 'TERM', $pid; };
		Mojo::IOLoop->timer(0.2 => sub { waitpid($pid, 1); });
	}
	delete $st->{'pump_buf'};
	delete $st->{'pump_frames'};
	delete $st->{'pump_paused'};
}

sub music_video_pump_pause($st) {
	return unless $st->{'pump_pid'};
	return if $st->{'pump_paused'};
	$st->{'pump_paused'} = 1;
	eval { kill 'STOP', $st->{'pump_pid'}; };
}

sub music_video_pump_resume($st) {
	return unless $st->{'pump_pid'};
	return unless $st->{'pump_paused'};
	delete $st->{'pump_paused'};
	eval { kill 'CONT', $st->{'pump_pid'}; };
}

sub music_video_pump_emit($st, $jpeg) {
	my $seq = ++$st->{'pump_frames'};
	my $rate = $st->{'rate'} || 1;
	my $media = ($st->{'pump_time'} || 0)
		+ ((&subs::rightNow() - ($st->{'pump_started_at'} || &subs::rightNow())) / 1000) * $rate;
	my $frame = pack('V d< V', 0x4D564944, $media, $seq) . $jpeg;
	foreach my $key (keys %{$st->{'clients'}}) {
		my $cl = $st->{'clients'}->{$key};
		next unless $cl->{'up'} && $cl->{'tx'} && $cl->{'ready'};
		next if length($cl->{'tx'}->{write} // '') > 1_000_000;
		eval { $cl->{'tx'}->send({binary => $frame}); };
	}
}

sub music_video_pump_start($st, $time) {
	&music_video_pump_stop($st);
	return unless $st->{'want'} && keys %{ $st->{'want'} };
	return unless $st->{'file'} && -e $st->{'file'};
	my $h = $st->{'hello'}->{'height'} || 720;
	$h = 240 if $h < 240;
	$h = 1080 if $h > 1080;
	my $fps = $st->{'hello'}->{'fps'} || 24;
	$fps = 24 unless grep { $_ == $fps } (15, 24, 30);
	my $q = (($st->{'hello'}->{'quality'} || '') eq '1080p') ? 5 : 6;
	my $rate = $st->{'rate'} || 1;
	$rate = 1 unless $rate =~ /^\d+(?:\.\d+)?$/ && $rate >= 0.25 && $rate <= 4;
	$time = 0 unless defined $time && $time =~ /^\d+(?:\.\d+)?$/;
	my @cmd = ('ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error');
	push @cmd, ('-ss', sprintf('%.3f', $time)) if $time > 0;
	push @cmd, ($rate == 1 ? '-re' : '-readrate', ($rate == 1 ? () : $rate),
		'-i', $st->{'file'}, '-an', '-threads', '4',
		'-vf', 'scale=-2:' . $h, '-r', $fps, '-f', 'image2pipe',
		'-vcodec', 'mjpeg', '-q:v', $q, 'pipe:1');
	my $pid = open(my $fh, '-|', @cmd);
	return unless $pid;
	$st->{'pump_pid'} = $pid;
	$st->{'pump_fh'} = $fh;
	$st->{'pump_time'} = $time;
	$st->{'pump_frames'} = 0;
	$st->{'pump_buf'} = '';
	$st->{'pump_started_at'} = &subs::rightNow();
	$fh->blocking(0);
	my $stream = Mojo::IOLoop::Stream->new($fh)->timeout(0);
	$stream->start;
	$st->{'pump_stream'} = $stream;
	$stream->on(error => sub { });
	$stream->on(read => sub {
		my ($stream, $bytes) = @_;
		return unless $st->{'pump_stream'} && $st->{'pump_stream'} == $stream;
		$st->{'pump_buf'} .= $bytes;
		if (length($st->{'pump_buf'}) > 8_000_000) {
			# a stray start marker would otherwise grow forever
			$st->{'pump_buf'} = substr($st->{'pump_buf'}, -4_000_000);
		}
		while (1) {
			my $start = index($st->{'pump_buf'}, "\xFF\xD8");
			last if $start < 0;
			my $end = index($st->{'pump_buf'}, "\xFF\xD9", $start + 2);
			last if $end < 0;
			my $jpeg = substr($st->{'pump_buf'}, $start, $end - $start + 2);
			$st->{'pump_buf'} = substr($st->{'pump_buf'}, $end + 2);
			&music_video_pump_emit($st, $jpeg) if length $jpeg > 64;
		}
	});
	$stream->on(close => sub {
		delete $st->{'pump_stream'};
		my $dead = delete $st->{'pump_pid'};
		delete $st->{'pump_fh'};
		Mojo::IOLoop->timer(0.3 => sub { waitpid($dead, 1) }) if $dead;
	});
}

# The browser's heartbeat. A video that is playing wants a pump at its own
# position; a seek or a long drift restarts it, a pause freezes the process.
sub music_video_pump_sync($st, $time, $playing) {
	return unless $st->{'want'} && keys %{ $st->{'want'} };
	return unless $st->{'file'};
	$time = 0 unless defined $time && $time =~ /^\d+(?:\.\d+)?$/;
	if (!$playing) { &music_video_pump_pause($st); return; }
	$st->{'reported_time'} = $time;
	unless ($st->{'pump_pid'}) {
		&music_video_pump_start($st, $time);
		return;
	}
	&music_video_pump_resume($st);
	my $rate = $st->{'rate'} || 1;
	my $expected = ($st->{'pump_time'} || 0)
		+ ((&subs::rightNow() - ($st->{'pump_started_at'} || &subs::rightNow())) / 1000) * $rate;
	my $drift = $time - $expected;
	my $now = &subs::rightNow();
	if (abs($drift) > 1.5 && $now - ($st->{'pump_restart_at'} || 0) > 3000) {
		$st->{'pump_restart_at'} = $now;
		&music_video_pump_start($st, $time);
	}
}

# The receiver overlay is created by the peer's own browser. It is pushed on the
# always-open `server` channel rather than `music`, so a machine that is not
# showing the Music window still opens its screen.
sub music_video_receiver_command($id, $info, $open) {
	my $cmd = $open
		? &Websocket::console_command('musicVideoReceiverOpen', $id, $info)
		: &Websocket::console_command('musicVideoReceiverClose', $id);
	&Websocket::send('server', { console => $cmd, timestamp => &subs::rightNow() });
}

# The browser's playback stream can come back from PulseAudio's stream-restore
# at a remembered level - muted, or a few percent - and WebKit's element volume
# is tied to that stream. The app's real level lives in the shared graph (or the
# system mixer), so the stream itself is always meant to be full scale. Put only
# this house's streams right, after playback has created them.
sub music_stream_health {
	my $full = shift || 0;
	return [] unless $music_device eq 'computer';
	my $json = `pactl -f json list sink-inputs 2>/dev/null`;
	return [] unless $json =~ /^\s*\[/;
	my $list = eval { decode_json $json } || [];
	my @fixed;
	my $latency = 0;
	foreach my $si ( @{$list} ) {
		my $p = $si->{'properties'} || {};
		my $app = $p->{'application.name'} || '';
		next unless $app =~ /^jawnos/i;
		# the Web Audio stream is the one this machine hears. Its node latency is
		# the graph's own render buffer; the sink input's buffer and the device's
		# own latency sit after it, and all of them delay Me relative to the
		# picture, so the largest path is the one the local delay must allow for.
		if (lc($p->{'media.role'} || '') eq 'webaudio') {
			my $sec = 0;
			my $nl = $p->{'node.latency'} || '';
			if ($nl =~ m{^(\d+)/(\d+)$} && $2 > 0) { $sec = $1 / $2; }
			my $buf = ($si->{'buffer_latency_usec'} || 0) + 0;
			my $sink = ($si->{'sink_latency_usec'} || 0) + 0;
			my $path = ($buf + $sink) / 1_000_000;
			my $total = $path > $sec ? $path : $sec;
			$latency = $total if $total > $latency;
		}
		my $id = $si->{'index'};
		next unless defined $id && $id =~ /^\d+$/;
		my $pct = -1;
		foreach my $ch ( values %{$si->{'volume'} || {}} ) {
			if (defined $ch->{'value_percent'} && $ch->{'value_percent'} =~ /^(\d+)%/) { $pct = $1; last; }
		}
		next unless $si->{'mute'} || $pct < 0 || $pct < 100;
		# Only when the app's level is not the element's own: with a graph the
		# element is a full-gain pass-through, and with the system mixer wired
		# the ceiling is for the mixer to set.
		next unless $full;
		`pactl set-sink-input-mute $id 0 2>/dev/null`;
		`pactl set-sink-input-volume $id 100% 2>/dev/null`;
		push @fixed, $id;
	}
	return (\@fixed, $latency);
}

Manager::app->routes->get('/manager/music/stream_health' => sub($c) {
	my ($fixed, $latency) = &music_stream_health(($c->param('full') // '') eq '1');
	$c->render(json => { fixed => $fixed, latency => $latency });
});

Manager::app->routes->get('/manager/music/receiver' => sub($c) {
	$c->render(json => &music_receiver_state());
});

Manager::app->routes->post('/manager/music/receiver/stop' => sub($c) {
	&music_receiver_stop();
	$c->render(json => &music_receiver_state());
});

Manager::app->routes->post('/manager/music/receiver/block' => sub($c) {
	my $marker = &subs::home('~/.president/music_receive_off');
	if (($c->param('blocked') // '') eq 'on') {
		write_file($marker, '1');
		# Refusing further transmissions also stops the one already playing: it
		# is the same intent ("not here"), and leaving it running would make the
		# switch look broken.
		&music_receiver_stop();
	}
	else {
		unlink $marker if -e $marker;
	}
	$c->render(json => &music_receiver_state());
});

# The last reports from the browser and from each receiver. A failing stream is
# read here after the fact: the source's send counters, the receiver's arrival
# gaps, and the picture's black runs sit on the same timeline. `limit` caps the
# records returned (1-500); the file itself is rotated at 1 MB.
Manager::app->routes->get('/manager/music/sync_diag' => sub($c) {
	my $limit = int($c->param('limit') // 120);
	$limit = 1 if $limit < 1;
	$limit = 500 if $limit > 500;
	my $path = &music_sync_log_path();
	my @entries;
	if (-e $path) {
		my $text = eval { read_file($path) };
		if (defined $text && length $text) {
			my @lines = grep { length } split /\n/, $text;
			my $start = @lines > $limit ? scalar(@lines) - $limit : 0;
			for my $i ($start .. $#lines) {
				my $d = eval { decode_json($lines[$i]) };
				push @entries, $d if $d;
			}
		}
	}
	$c->render(json => { entries => \@entries, size => (-e $path ? (-s $path) : 0) });
});

1;
