package Manager;
use strict;
use warnings;
no warnings 'uninitialized';
use feature 'signatures';

use Mojo::JSON qw(decode_json encode_json);

# One route, two roles. A browser opens it on this machine (session-cookie
# authenticated) and sends hello/PCM; the source manager opens it on each
# enabled remote with `peer=1&signatorial=...` and the peer signature, and the
# remote turns the PCM into sound. The gate exempts this path (hooks.pl); each
# role checks its caller here.
# ---- remote video: a separate websocket -----------------------------------
#
# The source window draws its #video into a canvas and sends JPEG/WebP frames
# with a 16-byte header (magic, media time, sequence). This window's manager
# forwards each frame to every peer it was told about; a peer's ws worker hands
# them to the receiver overlay its browser opened. Both sockets on a peer use
# ws_port, which is one worker, so the relay is in-process. The source socket is
# on the main port, exactly like the audio tap's.
my %music_video_receivers;
my %music_video_streams;

Manager::app->routes->websocket('/manager/music/video' => sub ($c) {
	if ($c->param('peer')) {
		my $signatorial = $c->param('signatorial');
		my $rm = ($signatorial ? &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0] : undef);
		unless ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm)) { $c->rendered(403); return; }
		my $id = $c->param('stream') || &subs::random_string_creator(20);
		my $st = { id => $id, tx => $c->tx, info => {}, open => 0 };
		$c->on(text => sub {
			my ($c, $msg) = @_;
			my $d = eval { decode_json $msg } || {};
			my $type = $d->{'type'} || '';
			if ($type eq 'hello') {
				$st->{'info'} = $d;
				$st->{'open'} = 1;
				$music_video_streams{$id} = $st;
				my $open_info = {
					stream => $id,
					title => ($d->{'title'} || ''),
					source => ($d->{'source'} || ''),
					width => ($d->{'width'} || 0),
					height => ($d->{'height'} || 0),
					fps => ($d->{'fps'} || 24),
					enhance => ($d->{'enhance'} || {}),
					delay_ms => ($d->{'delay_ms'} || 100)
				};
				$st->{'open_info'} = $open_info;
				&music_video_receiver_command($id, $open_info, 1);
				# a lost push (or a tab that was still loading) gets one more try;
				# once the receiver socket is here the timer does nothing
				Mojo::IOLoop->timer(4 => sub {
					return unless $st->{'open'};
					return if $music_video_receivers{$id} && keys %{$music_video_receivers{$id}};
					&music_video_receiver_command($id, $open_info, 1);
				});
				# a reconnecting source may find the screen already open
				if ($music_video_receivers{$id} && keys %{$music_video_receivers{$id}}) {
					eval { $c->tx->send({text => encode_json({ type => 'receiver', ready => 1 })}); };
				}
			}
			elsif ($type eq 'control') {
				# pause, resume, seek and the subtitle line ride the same socket as
				# the frames; the overlay needs them in order with the picture
				my $json = encode_json($d);
				foreach my $tx ( values %{ $music_video_receivers{$id} || {} } ) {
					next unless $tx && $tx->is_websocket;
					eval { $tx->send({text => $json}); };
				}
				if (($d->{'action'} || '') eq 'stop') {
					&music_video_receiver_command($id, {}, 0);
					$st->{'open'} = 0;
				}
			}
		});
		$c->on(binary => sub {
			my ($c, $msg) = @_;
			return unless $st->{'open'};
			foreach my $tx ( values %{ $music_video_receivers{$id} || {} } ) {
				next unless $tx && $tx->is_websocket;
				next if length($tx->{write} // '') > 2_000_000;
				eval { $tx->send({binary => $msg}); };
			}
		});
		$c->on(finish => sub {
			&music_video_receiver_command($id, {}, 0) if $st->{'open'};
			delete $music_video_receivers{$id};
			delete $music_video_streams{$id};
		});
		return;
	}

	if ($c->param('local')) {
		unless ($c->session('authentication') eq 'approved') { $c->rendered(403); return; }
		my $id = $c->param('stream') || '';
		return unless length $id;
		my $tx = $c->tx;
		$music_video_receivers{$id}->{$tx} = $tx;
		# tell the source a screen is actually listening; until then it does not
		# spend the link on frames nobody is showing
		if (my $peer = $music_video_streams{$id}) {
			if ($peer->{'tx'} && $peer->{'tx'}->is_websocket) {
				eval { $peer->{'tx'}->send({text => encode_json({ type => 'receiver', ready => 1 })}); };
			}
		}
		$c->on(finish => sub {
			delete $music_video_receivers{$id}->{$tx};
			if (!$music_video_receivers{$id} || !keys %{$music_video_receivers{$id}}) {
				delete $music_video_receivers{$id};
				if (my $peer = $music_video_streams{$id}) {
					if ($peer->{'tx'} && $peer->{'tx'}->is_websocket) {
						eval { $peer->{'tx'}->send({text => encode_json({ type => 'receiver', ready => 0 })}); };
					}
				}
			}
		});
		return;
	}

	unless ($c->session('authentication') eq 'approved') { $c->rendered(403); return; }
	my $st = { role => 'source', clients => {}, stream => &subs::random_string_creator(20), hello => {} };
	$c->on(text => sub {
		my ($c, $msg) = @_;
		my $d = eval { decode_json $msg } || {};
		my $type = $d->{'type'} || '';
		if ($type eq 'hello') {
			$st->{'hello'} = $d;
			$st->{'browser'} = $c;
			$st->{'file'} = $d->{'file'} || '';
			my $r = $d->{'rate'} || 1;
			$st->{'rate'} = ($r =~ /^\d+(?:\.\d+)?$/ && $r >= 0.25 && $r <= 4) ? $r : 1;
			$st->{'playing_hint'} = ($d->{'playing'} // 1) ? 1 : 0;
			&music_video_source_sync_outputs($c, $st, $d->{'outputs'} || []);
			eval { $c->tx->send({text => encode_json({ type => 'stream', stream => $st->{'stream' } })}); };
			&music_video_pump_sync($st, $d->{'time'}, (($d->{'playing'} // 1) ? 1 : 0));
		}
		elsif ($type eq 'outputs') {
			&music_video_source_sync_outputs($c, $st, $d->{'outputs'} || []);
			my $n = scalar keys %{ $st->{'want'} || {} };
			if (!$n) { &music_video_pump_stop($st); }
			elsif ($st->{'file'} && !$st->{'pump_pid'}) { &music_video_pump_sync($st, $st->{'reported_time'} || 0, 1); }
		}
		elsif ($type eq 'control') {
			my $action = $d->{'action'} || '';
			if ($action eq 'delay' && $d->{'key'}) {
				# a measured lip-sync correction; only that peer's picture waits
				my $cl = $st->{'clients'}->{$d->{'key'}};
				if ($cl && $cl->{'up'} && $cl->{'tx'}) {
					eval { $cl->{'tx'}->send({text => encode_json($d)}); };
				}
				return;
			}
			if ($action eq 'state') {
				my $r = $d->{'rate'} || 1;
				my $rate = ($r =~ /^\d+(?:\.\d+)?$/ && $r >= 0.25 && $r <= 4) ? $r : 1;
				my $rate_changed = (($st->{'rate'} || 1) != $rate);
				$st->{'rate'} = $rate;
				$st->{'playing_hint'} = $d->{'playing'} ? 1 : 0;
				if ($rate_changed) { &music_video_pump_start($st, $d->{'time'} || 0); }
				else { &music_video_pump_sync($st, $d->{'time'}, ($d->{'playing'} ? 1 : 0)); }
				return;
			}
			if ($action eq 'seek') {
				$st->{'reported_time'} = $d->{'time'} || 0;
				&music_video_pump_start($st, $st->{'reported_time'});
				&music_video_pump_pause($st) unless $st->{'playing_hint'};
			}
			elsif ($action eq 'pause') { $st->{'playing_hint'} = 0; &music_video_pump_pause($st); }
			elsif ($action eq 'resume') {
				$st->{'playing_hint'} = 1;
				$st->{'reported_time'} = $d->{'time'} || 0;
				if ($st->{'pump_pid'}) { &music_video_pump_resume($st); }
				else { &music_video_pump_start($st, $st->{'reported_time'}); }
			}
			&music_video_source_forward($st, $d);
			&music_video_source_close($st) if ($action eq 'stop');
		}
	});
	$c->on(binary => sub {
		my ($c, $msg) = @_;
		foreach my $key (keys %{$st->{'clients'}}) {
			my $cl = $st->{'clients'}->{$key};
			next unless $cl->{'up'} && $cl->{'tx'} && $cl->{'ready'};
			next if length($cl->{'tx'}->{write} // '') > 1_000_000;
			eval { $cl->{'tx'}->send({binary => $msg}); };
		}
	});
	$c->on(finish => sub { &music_video_source_close($st); });
});

Manager::app->routes->websocket('/manager/music/stream' => sub ($c) {
	if ($c->param('peer')) {
		my $signatorial = $c->param('signatorial');
		my $rm = ($signatorial ? &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0] : undef);
		unless ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm)) {
			$c->rendered(403);
			return;
		}
		if (&music_receiving_refused()) {
			$c->rendered(403);
			return;
		}
		my $st = { role => 'remote', source => $signatorial, key => ($c->param('from') || ''), rate => 48000, tx => $c->tx };
		$c->on(text => sub {
			my ($c, $msg) = @_;
			my $d = eval { decode_json $msg } || {};
			my $type = $d->{'type'} || '';
			if ($type eq 'hello') {
				$st->{'file'} = $d->{'file'} || '';
				$st->{'type'} = ($d->{'music_data'} && $d->{'music_data'}->{'type'})
					? $d->{'music_data'}->{'type'}
					: ($st->{'file'} =~ /\.(mp4|mkv|mov|webm|wmv|avi)$/i ? 'video' : 'audio');
				$st->{'rate'} = &music_stream_rate($d->{'rate'});
				$st->{'codec'} = (($d->{'codec'} || 'pcm') eq 'opus') ? 'opus' : 'pcm';
				my $channel = lc($d->{'channel'} || 'stereo');
				$st->{'channel'} = ($channel eq 'left' || $channel eq 'right') ? $channel : 'stereo';
				# Opus has an encoder and decoder buffer in front of pacat's; the
				# ping measures only the network/player round trip, so the base
				# carries the extra for the remote's estimate.
				$st->{'base'} = ($st->{'codec'} eq 'opus') ? 280 : 80;
				$st->{'music_data'} = $d->{'music_data'};
				&music_stream_watcher_write($d->{'music_data'});
				my $ok = &music_remote_audio_start($st);
				$c->tx->send({text => encode_json({ type => 'ready', key => $st->{'key'}, base => $st->{'base'}, latency_ms => $st->{'base'}, ok => ($ok ? 1 : 0), error => ($st->{'error'} || '') })});
			}
			elsif ($type eq 'mark') {
				# The source's beacon: the media position at the moment the samples
				# around it were sent. It arrives in order with them, so every byte
				# written after it is audio from that position onwards, and the
				# report can say how far behind the player is running.
				my $tot = $st->{'rx_total'} || 0;
				my $prev = $st->{'mark'};
				if ($prev && ($st->{'codec'} || 'pcm') eq 'opus') {
					my $dm = ($d->{'media_ms'} || 0) - ($prev->{'media_ms'} || 0);
					my $db = $tot - ($prev->{'bytes'} || 0);
					if ($dm > 200 && $db > 0) {
						my $cand = $db / $dm;
						$st->{'rx_bpm'} = $cand if !$st->{'rx_bpm'} || $cand > $st->{'rx_bpm'};
					}
				}
				$st->{'mark'} = { seq => ($d->{'seq'} || 0), media_ms => ($d->{'media_ms'} || 0), at => &subs::rightNow(), bytes => $tot };
				# The first beacon after a player (re)start measures the fresh player.
				# Answer it soon instead of waiting for the two-second report, so the
				# source can move the lead before the old pipeline's offset is heard.
				my $started = $st->{'starts'} || 0;
				if (($st->{'early_for'} // -1) != $started) {
					$st->{'early_for'} = $started;
					Mojo::IOLoop->timer(0.4 => sub {
						return unless $st->{'stream'} && !$st->{'paused'};
						&music_rx_report_send($st);
					});
				}
			}
			elsif ($type eq 'ping') {
				$c->tx->send({text => encode_json({ type => 'pong', t => $d->{'t'}, base => (($st->{'base'} || 80) + ($st->{'sink_ms'} || 0)) })});
			}
			elsif ($type eq 'control') {
				my $action = $d->{'action'} || '';
				if ($action eq 'pause') {
					# Opus keeps its decoder alive: the source resumes the same
					# WebM stream, and a new ffmpeg would need a new header.
					if (($st->{'codec'} || 'pcm') ne 'opus') { &music_remote_audio_stop($st, 1); }
					$st->{'paused'} = 1;
					&music_stream_state_write($st);
				}
				elsif ($action eq 'resume') {
					$st->{'paused'} = 0;
					if (($st->{'codec'} || 'pcm') ne 'opus') { &music_remote_audio_start($st); }
					else { &music_stream_state_write($st); }
				}
				elsif ($action eq 'seek' || $action eq 'track' || $action eq 'flush') {
					if ($action eq 'track' && $d->{'file'}) {
						$st->{'file'} = $d->{'file'};
						$st->{'type'} = ($d->{'music_data'} && $d->{'music_data'}->{'type'}) ? $d->{'music_data'}->{'type'} : $st->{'type'};
						$st->{'music_data'} = $d->{'music_data'} if $d->{'music_data'};
						&music_stream_watcher_write($d->{'music_data'}) if $d->{'music_data'};
					}
					# Opus is a continuous WebM stream; seeking or changing the
					# track does not restart its decoder. PCM restarts pacat to
					# flush the buffer (a seek, a new track, or the source's flush
					# after it dropped a stale backlog).
					if (($st->{'codec'} || 'pcm') ne 'opus' && !$st->{'paused'}) {
						&music_remote_audio_stop($st, 1);
						&music_stream_state_write($st);
						&music_remote_audio_start($st);
					}
					elsif (($st->{'codec'} || 'pcm') eq 'opus') { &music_stream_state_write($st); }
				}
				elsif ($action eq 'stop') {
					&music_remote_audio_stop($st, 0);
				}
			}
		});
		$c->on(binary => sub { my ($c, $msg) = @_; &music_remote_write($st, $msg); });
		$c->on(finish => sub { &music_remote_audio_stop($st, 0); });
		return;
	}

	unless ($c->session('authentication') eq 'approved') {
		$c->rendered(403);
		return;
	}
	my $st = { role => 'source', clients => {} };
	$c->on(text => sub {
		my ($c, $msg) = @_;
		my $d = eval { decode_json $msg } || {};
		my $type = $d->{'type'} || '';
		if ($type eq 'hello') {
			$st->{'hello'} = $d;
			$st->{'started'} = 1;
			&music_source_sync_outputs($c, $st, $d->{'outputs'} || [], $d->{'channels'});
		}
		elsif ($type eq 'outputs') {
			&music_source_sync_outputs($c, $st, $d->{'outputs'} || [], $d->{'channels'});
		}
		elsif ($type eq 'sync_report') {
			&music_sync_log('source', '', $d);
		}
		elsif ($type eq 'mark') {
			# The beacon rides the same socket as the audio, so every receiver sees
			# it in order with the samples whose position it names.
			&music_source_forward($st, $d);
		}
		elsif ($type eq 'control') {
			if (($d->{'action'} || '') eq 'track') {
				$st->{'hello'}->{'file'} = $d->{'file'} if $d->{'file'};
				$st->{'hello'}->{'music_data'} = $d->{'music_data'} if $d->{'music_data'};
			}
			&music_source_forward($st, $d);
			&music_source_close($st) if (($d->{'action'} || '') eq 'stop');
		}
	});
	$c->on(binary => sub {
		my ($c, $msg) = @_;
		return unless $st->{'started'};
		foreach my $key (keys %{$st->{'clients'}}) {
			my $cl = $st->{'clients'}->{$key};
			next unless $cl->{'up'} && $cl->{'tx'} && $cl->{'tx'}->is_websocket;
			# a stalled remote must not grow this worker's buffer without bound
			next if length($cl->{'tx'}->{write} // '') > 1_000_000;
			eval { $cl->{'tx'}->send({binary => $msg}); };
		}
	});
	$c->on(finish => sub { &music_source_close($st); });
});



1;
