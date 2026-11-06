package Manager;
use strict;
use warnings;
no warnings 'uninitialized';
use feature 'signatures';

use Mojo::JSON qw(decode_json encode_json);
use File::Slurp;
use URI::Encode qw(uri_encode);
use Fcntl qw(F_SETPIPE_SZ);

our ($music_device, $music_config);

sub music_remote_audio_stop($st, $keep_state) {
	# a report timer would otherwise outlive the stream it describes
	&music_rx_report_stop($st);
	# a beacon from before the stop names a position this player is no longer at
	delete $st->{'mark'};
	# capture the pid first: the stream's close event clears it
	my $pid = $st->{'pid'};
	# an intentional stop (pause, seek, stop) must not look like pacat dying and
	# tell the source to hang up
	$st->{'stopping'} = 1;
	if ($st->{'stream'}) {
		$st->{'stream'}->close;
		delete $st->{'stream'};
	}
	# closing the stream only removes the reactor watcher; the pipe itself is
	# still open until its handle goes, and pacat needs that EOF to exit
	if ($st->{'fh'}) {
		eval { close $st->{'fh'}; };
		delete $st->{'fh'};
	}
	if ($pid) { waitpid($pid, 0); }
	delete $st->{'pid'};
	$st->{'stopping'} = 0;
	unless ($keep_state) {
		unlink &music_stream_state_path();
		my $watcher = &music_stream_watcher_path();
		write_file($watcher, '') if -e $watcher;
		if ($st->{'locked'}) {
			&music_wake_lock(-1);
			$st->{'locked'} = 0;
		}
	}
}

sub music_remote_audio_start($st) {
	return 1 if $st->{'pid'};
	delete $st->{'error'};
	unless (&music_pulse_ready()) {
		$st->{'error'} = 'pulse';
		return 0;
	}
	my @cmd;
	my $channel = $st->{'channel'} // 'stereo';
	my $pan = &music_channel_filter($channel, $music_device);
	if (($st->{'codec'} || 'pcm') eq 'opus') {
		# The source records WebM/Opus. ffmpeg decodes the live stream from
		# stdin and pacat plays the PCM; decoding to 44100 keeps the phone and
		# tablet's OpenSL sink from resampling. The command is fixed text (no
		# caller input), so the shell pipeline is safe here.
		my $filter = $pan ne '' ? ' -af "' . $pan . '"' : '';
		my $pipeline = 'ffmpeg -hide_banner -loglevel error -fflags nobuffer -analyzeduration 0 -probesize 32k'
			. ' -i pipe:0' . $filter . ' -f s16le -acodec pcm_s16le -ar 44100 -ac 2 pipe:1'
			. ' | pacat --playback --raw --format=s16le --rate=44100 --channels=2 --latency-msec=' . &music_receiver_latency_ms($st)
			. ' --volume=65536 --client-name=jawnos-music-opus --stream-name=jawnos-music';
		@cmd = ('sh', '-c', $pipeline);
	}
	elsif ($pan ne '') {
		# Raw stereo PCM plus a channel filter: ffmpeg only remaps the samples,
		# so the same pacat at the end keeps the low latency.
		my $rate = &music_stream_rate($st->{'rate'});
		my $pacat = `command -v pacat 2>/dev/null`;
		chomp $pacat;
		$pacat = 'pacat' unless $pacat;
		my $pipeline = 'ffmpeg -hide_banner -loglevel error -fflags nobuffer -f s16le'
			. ' -ar ' . $rate . ' -ac 2 -i pipe:0 -af "' . $pan . '"'
			. ' -f s16le -acodec pcm_s16le -ar ' . $rate . ' -ac 2 pipe:1'
			. ' | ' . $pacat . ' --playback --raw --format=s16le --rate=' . $rate
			. ' --channels=2 --latency-msec=' . &music_receiver_latency_ms($st) . ' --volume=65536 --client-name=jawnos-music --stream-name=jawnos-music';
		@cmd = ('sh', '-c', $pipeline);
	}
	else { @cmd = &music_pacat_command($st, $st->{'rate'}); }
	my $pid = open(my $fh, '|-', @cmd);
	unless ($pid) {
		$st->{'error'} = 'pacat';
		return 0;
	}
	# The kernel pipe between this manager and pacat is a buffer the receiver's
	# report cannot see. Linux gives it 64 KB by default: about 363 ms at
	# 44.1 kHz stereo, sitting after pacat's 30 ms and the sink - half a second
	# of audio a room is heard behind while the measured lag says a tenth of
	# it. Shrink it so a slow player backs up into bytes_waiting, which is
	# measured (the lead answers it, and PCM flushes when it runs away).
	my $pipe_bytes = ((($st->{'codec'} || 'pcm') eq 'opus') || $pan ne '') ? 65_536 : &music_receiver_pipe_bytes($st);
	eval { fcntl($fh, F_SETPIPE_SZ, $pipe_bytes) };
	$fh->blocking(0);
	my $stream = Mojo::IOLoop::Stream->new($fh)->timeout(0);
	$stream->start;
	$stream->on(error => sub { });
	$stream->on(close => sub {
		delete $st->{'stream'};
		my $dead = delete $st->{'pid'};
		# WNOHANG: the pipe is still open when this fires, so a blocking wait
		# would deadlock. Reap a moment later, once pacat has seen the EOF.
		Mojo::IOLoop->timer(0.5 => sub { waitpid($dead, 1) }) if $dead;
		# pacat ended without our asking (the receiver's Stop, or a crashed
		# sink): tell the source, so it stops pushing frames at a dead output
		unless ($st->{'stopping'} || $st->{'paused'}) {
			if ($st->{'tx'} && $st->{'tx'}->is_websocket) {
				eval {
					$st->{'tx'}->send({text => encode_json({ type => 'stopped' })});
					$st->{'tx'}->finish;
				};
			}
		}
	});
	$st->{'pid'} = $pid;
	$st->{'fh'} = $fh;
	$st->{'stream'} = $stream;
	$st->{'paused'} = 0;
	$st->{'started'} ||= &subs::rightNow();
	$st->{'starts'} = ($st->{'starts'} || 0) + 1;
	&music_rx_report_start($st);
	unless ($st->{'locked'}) {
		&music_wake_lock(1);
		$st->{'locked'} = 1;
	}
	&music_stream_state_write($st);
	# The receiver's own sink latency joins the measured base: the ping can only
	# time the network and the player's start, not the phone's output buffer.
	Mojo::IOLoop->timer(0.25 => sub {
		return unless $st->{'pid'};
		my $ms = &music_receiver_sink_latency();
		$st->{'sink_ms'} = $ms if $ms > 0;
	});
	return 1;
}

sub music_remote_write($st, $bytes) {
	return unless $st->{'stream'} && !$st->{'paused'};
	# PCM is paced in real time, so a backlog is a delay: drop it. Opus clusters
	# are not independent packets (the WebM header and cluster order matter), so
	# that stream is allowed a larger buffer instead of being corrupted.
	# The kernel pipe is kept small in music_remote_audio_start, so this cap is
	# most of the receiver's hidden buffer; about a tenth of a second of backlog
	# is the point where a live stream is better off skipping than falling behind.
	my $cap = (($st->{'codec'} || 'pcm') eq 'opus') ? 4_000_000 : &music_receiver_write_cap($st);
	# The gap between writes is the receiver's own measure of a starving stream:
	# pacat's sink buffer and the pipe cannot hide a mesh stall longer than that.
	my $now = &subs::rightNow();
	if ($st->{'rx_last'}) {
		my $gap = $now - $st->{'rx_last'};
		$st->{'rx_max_gap'} = $gap if $gap > ($st->{'rx_max_gap'} || 0);
	}
	$st->{'rx_last'} = $now;
	if ($st->{'stream'}->bytes_waiting > $cap) {
		$st->{'rx_dropped'} = ($st->{'rx_dropped'} || 0) + 1;
		return;
	}
	$st->{'rx_bytes'} = ($st->{'rx_bytes'} || 0) + length($bytes);
	# cumulative as well: a beacon's anchor is an absolute byte count
	$st->{'rx_total'} = ($st->{'rx_total'} || 0) + length($bytes);
	$st->{'rx_writes'} = ($st->{'rx_writes'} || 0) + 1;
	$st->{'stream'}->write($bytes);
}

# The receiving machine's half of the trace. The source reports what it sent;
# this reports what actually arrived, so a gap can be attributed to the network,
# to pacat, or to the source having dropped the frame itself.
sub music_rx_report_send($st) {
	return unless $st->{'tx'} && $st->{'tx'}->is_websocket;
	my $now = &subs::rightNow();
	# pactl is not free, but the sink buffer is what a resume changes; a number
	# ten seconds stale reads as a smaller lag than the room can hear
	if (!$st->{'sink_at'} || $now - $st->{'sink_at'} > 2_000) {
		$st->{'sink_at'} = $now;
		my $ms = &music_receiver_sink_latency();
		$st->{'sink_ms'} = $ms if $ms > 0;
	}
	# How far behind the source's beacon this player is running: the time since
	# the mark arrived, less the sound that has actually gone through the pipe,
	# plus what is still buffered (the pipe and the sink). A steady player reads
	# its own buffer here; a starved or dropped stream reads more, which is the
	# lag the picture has to wait for.
	my $lag_ms = 0;
	my $waiting_ms = 0;
	# -1 means no beacon has been seen, which is not the same as a fresh one
	my $mark_age_ms = -1;
	my $bpm = &music_receiver_bytes_per_ms($st);
	if ($st->{'mark'} && $bpm > 0) {
		$mark_age_ms = $now - ($st->{'mark'}->{'at'} || $now);
		$waiting_ms = ($st->{'stream'} ? ($st->{'stream'}->bytes_waiting || 0) : 0) / $bpm;
		if (!$st->{'paused'} && $mark_age_ms < 4000) {
			my $written_ms = (($st->{'rx_total'} || 0) - ($st->{'mark'}->{'bytes'} || 0)) / $bpm;
			my $lag = $mark_age_ms - $written_ms + ($st->{'sink_ms'} || 0) + $waiting_ms;
			$lag_ms = int($lag + 0.5) if $lag > 0;
		}
	}
	# Near-live: a pipe that has filled with a burst stays filled, because pacat
	# consumes exactly what arrives. When the lag says the player is running
	# hundreds of milliseconds behind, throw the stale buffer away and let a
	# fresh player start on the audio arriving now. PCM restarts pacat for this;
	# Opus cannot, because a new ffmpeg would need the WebM header again.
	my $flushed = 0;
	# The lead is measured from this same report, so a steady pipe backlog is not
	# a fault: the sender simply leads it. On a video that lead can answer a few
	# hundred milliseconds, so only a stranded player is restarted there. An audio
	# track has no lead to reduce it, and a few hundred milliseconds is plainly
	# heard as an echo, so it is flushed much sooner.
	my $lag_flush = (($st->{'type'} || '') eq 'audio') ? 350 : 1500;
	if ($lag_ms > $lag_flush && ($st->{'codec'} || 'pcm') ne 'opus') {
		$st->{'lag_big'} = ($st->{'lag_big'} || 0) + 1;
	}
	else { delete $st->{'lag_big'}; }
	if (($st->{'lag_big'} || 0) >= 2 && $now - ($st->{'flush_at'} || 0) > 30_000) {
		$st->{'flush_at'} = $now;
		$st->{'lag_big'} = 0;
		$flushed = 1;
	}
	my $d = {
		type => 'rx_report',
		t => $now,
		bytes => (delete($st->{'rx_bytes'}) || 0),
		writes => (delete($st->{'rx_writes'}) || 0),
		max_gap_ms => (delete($st->{'rx_max_gap'}) || 0),
		dropped => (delete($st->{'rx_dropped'}) || 0),
		waiting => ($st->{'stream'} ? ($st->{'stream'}->bytes_waiting || 0) : 0),
		alive => (($st->{'pid'} && kill(0, $st->{'pid'})) ? 1 : 0),
		paused => ($st->{'paused'} ? 1 : 0),
		codec => ($st->{'codec'} || 'pcm'),
		sink_ms => ($st->{'sink_ms'} || 0),
		waiting_ms => int($waiting_ms + 0.5),
		mark_age_ms => $mark_age_ms,
		mark_seq => ($st->{'mark'} ? ($st->{'mark'}->{'seq'} || 0) : 0),
		lag_ms => $lag_ms,
		flushed => $flushed,
		starts => ($st->{'starts'} || 0),
	};
	eval { $st->{'tx'}->send({ text => encode_json($d) }); };
	if ($flushed) {
		&music_sync_log('remote', $st->{'key'}, { type => 'flush', lag_ms => $lag_ms, waiting_ms => int($waiting_ms + 0.5), sink_ms => ($st->{'sink_ms'} || 0) });
		&music_remote_audio_stop($st, 1);
		unless (&music_remote_audio_start($st)) {
			&music_sync_log('remote', $st->{'key'}, { type => 'flush', state => 'restart_failed', error => ($st->{'error'} || '') });
		}
	}
}
sub music_rx_report_start($st) {
	&music_rx_report_stop($st);
	$st->{'rx_bytes'} = 0;
	$st->{'rx_writes'} = 0;
	$st->{'rx_max_gap'} = 0;
	$st->{'rx_dropped'} = 0;
	$st->{'rx_last'} = 0;
	$st->{'rx_timer'} = Mojo::IOLoop->recurring(2 => sub { &music_rx_report_send($st); });
}
sub music_rx_report_stop($st) {
	if ($st->{'rx_timer'}) {
		Mojo::IOLoop->remove($st->{'rx_timer'});
		delete $st->{'rx_timer'};
	}
}

# --- the sending side --------------------------------------------------------
sub music_source_row($key) {
	return &subs::db_query('select * from remote_machines where (fqdn=? or ip=? or hostname=?) and connection=? order by server_time desc limit 1', $key, $key, $key, 'active')->hashes->[0];
}

sub music_source_uri($rm) {
	my $host = $rm->{'ip'};
	if (!$host) {
		my $url = eval { Mojo::URL->new($rm->{'manager'}) };
		$host = $url ? $url->host : '';
	}
	return unless $host;
	my $port = $rm->{'ws_port'} || $music_config->{'ws_port'} || '';
	my $uri = 'wss://' . $host . ($port ? ':' . $port : '') . '/manager/music/stream';
	# The peer listener carries the house-CA leaf; a peer that has not been
	# issued one answers on its main wss port and keeps the signed rail.
	return &subs::peer_secure_url($rm, $uri);
}

sub music_source_client_close($st, $key) {
	my $cl = delete $st->{'clients'}->{$key};
	return unless $cl;
	if ($cl->{'tx'}) {
		my $tx = $cl->{'tx'};
		eval {
			$tx->send({text => encode_json({ type => 'control', action => 'stop' })});
			$tx->finish;
		};
	}
}

sub music_source_ping($tx, $cl) {
	return unless $cl && $cl->{'up'} && $tx;
	$cl->{'pings'} = ($cl->{'pings'} || 0) + 1;
	eval { $tx->send({text => encode_json({ type => 'ping', t => &subs::rightNow() })}); };
}

sub music_source_client_open($c, $st, $key, $channel) {
	return if $st->{'clients'}->{$key};
	$channel = 'stereo' unless defined $channel && ($channel eq 'left' || $channel eq 'right');
	my $rm = &music_source_row($key);
	unless ($rm && $rm->{'uuid'}) {
		&music_sync_log('link', $key, { type => 'link', state => 'unreachable', error => 'no row' });
		$c->tx->send({text => encode_json({ type => 'error', key => $key, error => 'unreachable' })});
		return;
	}
	if (($rm->{'device'} || '') eq 'server') {
		&music_sync_log('link', $key, { type => 'link', state => 'unreachable', error => 'server' });
		$c->tx->send({text => encode_json({ type => 'error', key => $key, error => 'no audio' })});
		return;
	}
	my ($url, $source_verified) = &music_source_uri($rm);
	unless ($url) {
		&music_sync_log('link', $key, { type => 'link', state => 'unreachable', error => 'no address' });
		$c->tx->send({text => encode_json({ type => 'error', key => $key, error => 'no address' })});
		return;
	}
	my $ua = Mojo::UserAgent->new()->connect_timeout(5)->request_timeout(0)->inactivity_timeout(0);
	if ($source_verified) { &subs::peer_tls_verify($ua) } else { $ua->insecure(1) }
	# every request on the peer rail names this machine and carries a signature
	$ua->on(start => sub { my ($ua, $tx) = @_; &subs::peer_sign_request($tx->req); });
	my $cl = { key => $key, rm => $rm, ua => $ua, up => 0, rtt => 0, channel => $channel };
	$st->{'clients'}->{$key} = $cl;
	my $source = &subs::signatorial_designer();
	my $full = $url . '?peer=1&signatorial=' . uri_encode($source) . '&from=' . uri_encode($key);
	$ua->websocket($full => sub {
		my ($ua, $tx) = @_;
		if (!$tx->is_websocket) {
			delete $st->{'clients'}->{$key};
			&music_sync_log('link', $key, { type => 'link', state => 'error', error => 'connect' });
			$c->tx->send({text => encode_json({ type => 'error', key => $key, error => 'connect' })}) if $c->tx->is_websocket;
			return;
		}
		$cl->{'tx'} = $tx;
		$cl->{'up'} = 1;
		$cl->{'opened'} = &subs::rightNow();
		&music_sync_log('link', $key, { type => 'link', state => 'open', channel => $cl->{'channel'}, codec => ($st->{'hello'}->{'codec'} || 'pcm') });
		my $hello = { %{$st->{'hello'} || {}}, type => 'hello', source => $source, key => $key, channel => $cl->{'channel'} };
		delete $hello->{'channels'};
		$tx->on(text => sub {
			my ($tx, $msg) = @_;
			my $d = eval { decode_json $msg } || {};
			my $kind = $d->{'type'} || '';
			# pacat ended on its own. Tell the browser the same thing a dropped
			# connection says, so the output is reopened instead of staying dead.
			if ($kind eq 'stopped') {
				&music_sync_log('link', $key, { type => 'link', state => 'stopped' });
				$c->tx->send({text => encode_json({ type => 'closed', key => $key })}) if $c->tx->is_websocket;
				return;
			}
			if ($kind eq 'rx_report') {
				&music_sync_log('remote', $key, $d);
				# The live measurement the picture follows. The one-shot ping estimate
				# says what the network and the player start should cost; this says
				# what the receiver's buffer and any shortfall actually cost, which is
				# the number that moves when the stream falls behind.
				$c->tx->send({text => encode_json({
					type => 'sync',
					key => $key,
					lag_ms => ($d->{'lag_ms'} || 0),
					waiting_ms => ($d->{'waiting_ms'} || 0),
					sink_ms => ($d->{'sink_ms'} || 0),
					age_ms => ($d->{'mark_age_ms'} || 0),
					seq => ($d->{'mark_seq'} || 0),
					# which player produced this report: a new one (a resume, a seek,
					# a dropped buffer) has a new pipeline, and the source must not
					# keep leading it by the old player's measurement
					starts => ($d->{'starts'} || 0),
					paused => ($d->{'paused'} ? 1 : 0),
					alive => ($d->{'alive'} ? 1 : 0),
					flushed => ($d->{'flushed'} ? 1 : 0),
					rtt_ms => int(($cl->{'min_rtt'} || 0) / 2)
				})}) if $c->tx->is_websocket;
				return;
			}
			# The receiver could not start its player. Close this connection so the
			# browser's retry (a fresh outputs message) opens a new one; leaving it
			# open made a "pulse is not ready" answer permanent.
			if ($kind eq 'ready' && defined $d->{'ok'} && !$d->{'ok'}) {
				&music_sync_log('link', $key, { type => 'link', state => 'ready_failed', error => ($d->{'error'} || '') });
				eval { $tx->finish; };
				delete $st->{'clients'}->{$key};
				return;
			}
			if ($kind eq 'pong') {
				my $rtt = &subs::rightNow() - ($d->{'t'} || 0);
				$cl->{'base'} = $d->{'base'} if $d->{'base'};
				$cl->{'min_rtt'} = $rtt if !defined $cl->{'min_rtt'} || $rtt < $cl->{'min_rtt'};
				$cl->{'pongs'} = ($cl->{'pongs'} || 0) + 1;
				# a phone starting ffmpeg/pacat can delay the first reply by a
				# second; three spread pings and the smallest wins
				if ($cl->{'pongs'} < 3) {
					Mojo::IOLoop->timer(0.3 => sub { &music_source_ping($tx, $cl); });
					return;
				}
				unless ($cl->{'latency_sent'}) {
					$cl->{'latency_sent'} = 1;
					my $ms = int(($cl->{'base'} || 80) + ($cl->{'min_rtt'} / 2) + 20);
					$c->tx->send({text => encode_json({ type => 'latency', key => $key, ms => $ms })}) if $c->tx->is_websocket;
				}
				return;
			}
			# Ping only once the remote has started its player: the ping is what
			# measures the pipeline, and it must not include pacat's startup time.
			if ($kind eq 'ready') {
				# A beacon now measures the new player before the two-second report
				# would; the browser sends the samples that frame the mark.
				eval { $c->tx->send({text => encode_json({ type => 'mark_now', key => $key })}) } if $c->tx->is_websocket;
			}
			if ($kind eq 'ready' && !$cl->{'pinged'}) {
				$cl->{'pinged'} = 1;
				Mojo::IOLoop->timer(0.4 => sub { &music_source_ping($tx, $cl); });
				# if a reply is lost, still give the browser a safe estimate
				Mojo::IOLoop->timer(2.5 => sub {
					return if $cl->{'latency_sent'} || !$cl->{'up'};
					$cl->{'latency_sent'} = 1;
					my $min = defined $cl->{'min_rtt'} ? $cl->{'min_rtt'} : 20;
					my $ms = int(($cl->{'base'} || 80) + ($min / 2) + 20);
					eval { $c->tx->send({text => encode_json({ type => 'latency', key => $key, ms => $ms })}); };
				});
			}
			$c->tx->send({text => $msg}) if $c->tx->is_websocket;
		});
		$tx->send({text => encode_json($hello)});
		$tx->on(finish => sub {
			$cl->{'up'} = 0;
			delete $st->{'clients'}->{$key};
			&music_sync_log('link', $key, { type => 'link', state => 'closed', up_ms => ($cl->{'opened'} ? &subs::rightNow() - $cl->{'opened'} : 0) });
			$c->tx->send({text => encode_json({ type => 'closed', key => $key })}) if $c->tx->is_websocket;
		});
	});
}

sub music_source_sync_outputs($c, $st, $outputs, $channels) {
	my %want;
	foreach my $key ( @{$outputs || []} ) {
		my $ch = (ref $channels eq 'HASH' && defined $channels->{$key}) ? $channels->{$key} : 'stereo';
		$ch = 'stereo' unless $ch eq 'left' || $ch eq 'right';
		$want{$key} = $ch;
	}
	foreach my $key (keys %want) {
		my $cl = $st->{'clients'}->{$key};
		# a different side needs a different player, so reopen that output
		if ($cl && ($cl->{'channel'} || 'stereo') ne $want{$key}) {
			&music_source_client_close($st, $key);
			$cl = undef;
		}
		&music_source_client_open($c, $st, $key, $want{$key}) unless $cl;
	}
	foreach my $key (keys %{$st->{'clients'}}) { &music_source_client_close($st, $key) unless exists $want{$key}; }
}

sub music_source_forward($st, $data) {
	my $json = encode_json($data);
	foreach my $key (keys %{$st->{'clients'}}) {
		my $cl = $st->{'clients'}->{$key};
		next unless $cl->{'up'} && $cl->{'tx'};
		eval { $cl->{'tx'}->send({text => $json}); };
	}
}

sub music_source_close($st) {
	foreach my $key (keys %{$st->{'clients'}}) { &music_source_client_close($st, $key); }
	delete $st->{'started'};
}

1;
