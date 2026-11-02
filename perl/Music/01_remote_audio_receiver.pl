package Manager;
use strict;
use warnings;
no warnings 'uninitialized';
use feature 'signatures';

use Mojo::JSON qw(decode_json encode_json);
use File::Slurp;

our ($music_device);

# ---- remote audio: a live stream, not a downloaded file ---------------------
#
# The Music window taps the sound it is playing (public/js/music_stream_worklet.js)
# and sends 16-bit stereo PCM over a websocket to this manager. The source manager
# opens one peer-signed websocket per enabled output and forwards the frames; the
# remote manager writes them to `pacat`, so the remote hears the stream itself
# rather than a second copy of the file started at a guessed offset.
#
# The old whole-file path (download to ~/.president/pipe.<ext>, then `play ...
# trim`) is gone: it waited for a complete copy, wrote a plaintext file to disk,
# and could only approximate the position. The receiver strip and the block
# marker are kept; they now describe and stop this stream.

sub music_stream_state_path { return &subs::home('~/.president/music_stream.json'); }
sub music_stream_watcher_path { return &subs::home('~/.president/ws_watcher'); }
sub music_stream_wake_path { return &subs::home('~/.president/music_stream_wake'); }
sub music_stream_rate { my $r = shift || 48000; return $r =~ /^\d+$/ ? $r : 48000; }

# ---- the sync trace ---------------------------------------------------------
# The browser's 2-second report and each receiver's arrival report land in one
# line-per-record file. It is a trace for a person (or the coding agent) to read
# after a bad stream, not an audit: the oldest file is moved aside at 1 MB.
sub music_sync_log_path { return &subs::home('~/.president/music_sync.jsonl'); }
sub music_sync_log($role, $key, $d) {
	my %row = (ref $d eq 'HASH') ? %{$d} : ();
	$row{'role'} = $role;
	$row{'key'} = $key if defined $key && length $key;
	$row{'machine'} = $music_device;
	$row{'at'} = &subs::rightNow();
	my $line = eval { encode_json(\%row) };
	return unless defined $line && length $line;
	my $path = &music_sync_log_path();
	rename($path, $path . '.1') if -e $path && (-s $path) > 1_048_576;
	if (open(my $fh, '>>', $path)) {
		print $fh $line, "\n";
		close $fh;
	}
}

# The remote's record of the stream it is playing. The receiver strip is served
# by a different worker (the main prefork) from the websocket worker that owns
# pacat, so the state is a file, not a process variable. A stale pid means the
# stream ended without clearing it.
sub music_stream_state_read {
	my $path = &music_stream_state_path();
	return {} unless -e $path;
	# read_file in list context returns lines; decode_json is not prototyped, so
	# assign first or it decodes only the opening brace
	my $text = eval { read_file($path) };
	return {} unless defined $text && length $text;
	my $md = eval { decode_json $text } || {};
	if ($md->{'pid'} && !kill(0, $md->{'pid'})) {
		unlink $path;
		return {};
	}
	return $md;
}
sub music_stream_state_write($st) {
	write_file(&music_stream_state_path(), encode_json({
		file => ($st->{'file'} // ''),
		type => ($st->{'type'} // ''),
		source => ($st->{'source'} // ''),
		rate => ($st->{'rate'} // 48000),
		latency_ms => ($st->{'base'} // 80),
		codec => ($st->{'codec'} // 'pcm'),
		channel => ($st->{'channel'} // 'stereo'),
		pid => ($st->{'pid'} // 0),
		started => ($st->{'started'} // &subs::rightNow()),
		updated => &subs::rightNow(),
		paused => ($st->{'paused'} ? 1 : 0),
	}));
}

# The track the remote is playing, in the shape the keyboard strip already reads.
sub music_stream_watcher_write {
	my ($music_data) = @_;
	return unless defined $music_data;
	my $text = ref $music_data ? encode_json($music_data) : $music_data;
	write_file(&music_stream_watcher_path(), $text);
}

# Whether this machine refuses what other machines send it. A marker file, not
# a setting: `music` settings sync across the mesh, and refusing music here says
# nothing about any other machine.
sub music_receiving_refused {
	return -e &subs::home('~/.president/music_receive_off') ? 1 : 0;
}

sub music_receiver_state {
	my $state = &music_stream_state_read();
	my $watcher = &music_stream_watcher_path();
	my $md = {};
	if (-e $watcher) {
		my $text = eval { read_file($watcher) };
		$md = eval { decode_json $text } || {} if $text;
	}
	my $updated = 0;
	if (-e &music_stream_state_path()) { $updated = (stat(&music_stream_state_path()))[9] || 0; }
	elsif (-e $watcher) { $updated = (stat($watcher))[9] || 0; }
	return {
		playing => ($state->{'pid'} ? 1 : 0),
		paused => ($state->{'paused'} ? 1 : 0),
		blocked => &music_receiving_refused(),
		file => ($md->{'file'} // $state->{'file'} // ''),
		type => ($md->{'type'} // $state->{'type'} // ''),
		source => ($state->{'source'} // ''),
		latency_ms => ($state->{'latency_ms'} // 0),
		updated => $updated,
	};
}

# Stop the stream this machine is receiving, and take the markers with it so a
# later status read does not keep showing a track that is no longer playing.
sub music_receiver_stop {
	my $state = &music_stream_state_read();
	if ($state->{'pid'}) {
		kill 'TERM', $state->{'pid'};
		select(undef, undef, undef, 0.05);
	}
	unlink &music_stream_state_path();
	my $watcher = &music_stream_watcher_path();
	write_file($watcher, '') if -e $watcher;
	# the removed download path left these behind; clear them on the way through
	foreach my $pipe ( glob(&subs::home('~/.president/pipe') . '.*') ) {
		unlink $pipe if -e $pipe;
	}
}

# A Termux node must hold a wake lock or Android suspends it when the screen goes
# off - which is exactly how a tablet or phone is used as a wireless speaker. The
# count keeps two overlapping streams from releasing each other's lock.
#
# The count file is not self-describing: a manager restart or crash mid-stream
# leaves the last count behind with nothing to decrement it. The receiver's state
# file is the record of a stream that exists (written on start, removed on stop),
# so with no state file the count is stale and the live count is zero.
sub music_wake_live_count {
	return 0 unless -e &music_stream_state_path();
	my $path = &music_stream_wake_path();
	return 0 unless -e $path;
	return (read_file($path) + 0);
}

sub music_wake_lock($delta) {
	return unless $music_device eq 'mobile';
	my $path = &music_stream_wake_path();
	# Taking the lock starts from the live count, so a stale number from a stream
	# that died with the manager does not carry into the new one. Releasing keeps
	# the raw count: music_remote_audio_stop removes the state file before it
	# decrements, and a stream still holding the lock must still be counted down.
	my $count = $delta > 0 ? &music_wake_live_count() : ((-e $path) ? (read_file($path) + 0) : 0);
	my $was = $count;
	$count += $delta;
	$count = 0 if $count < 0;
	write_file($path, $count);
	if (($was == 0 && $count > 0) || ($was > 0 && $count == 0)) {
		# The app holds its own partial wake lock; the tree asks for it through
		# the bridge and has no shell command to fall back to.
		&subs::device_call($count > 0 ? 'power.wake_lock' : 'power.wake_unlock');
	}
}

# Start the Termux PulseAudio daemon if a reboot left it down. The sink module is
# `module-sles-sink` there (OpenSL), so a normal `pacat` reaches the Android
# speaker; a LINUX node's PipeWire/Pulse is already up.
sub music_pulse_ready {
	my $info = `pactl info 2>&1`;
	return 1 if $info =~ /Server String:/;
	return 0 unless $music_device eq 'mobile';
	my $found = `command -v pulseaudio 2>/dev/null`;
	chomp $found;
	return 0 unless $found;
	`$found --start --exit-idle-time=-1 >/dev/null 2>&1`;
	for (1..20) {
		select(undef, undef, undef, 0.1);
		$info = `pactl info 2>&1`;
		return 1 if $info =~ /Server String:/;
	}
	return 0;
}

# One output can be given one channel of the stereo pair. The source still sends
# ordinary stereo; a left/right output is produced here with ffmpeg's pan filter.
# A computer's stereo pair keeps the physical side (left speaker only / right
# speaker only); a phone or tablet usually has one speaker, so the chosen
# channel is sent to both sides there and is still heard however its speaker is
# wired.
sub music_channel_filter($channel, $device) {
	my $side = $channel // '';
	return '' unless $side eq 'left' || $side eq 'right';
	my $src = $side eq 'left' ? 'c0' : 'c1';
	if (($device // '') eq 'mobile') {
		return 'pan=stereo|c0=' . $src . '|c1=' . $src;
	}
	# A bare 0 is not accepted as an input channel in the pan filter this ffmpeg
	# ships with ("Expected in channel name"), so the silent side is 0 times a
	# real channel. Verified on the Table: c0=c0|c1=0*c0 gives left only and
	# c0=0*c1|c1=c1 gives right only.
	return 'pan=stereo|c0=c0|c1=0*c0' if $side eq 'left';
	return 'pan=stereo|c0=0*c1|c1=c1' if $side eq 'right';
	return '';
}

# How much the receiving machine's own audio path adds after pacat has handed
# the samples over: the sink input's buffer and device latency. The source's
# ping can only measure the network and the player's start, so without this a
# phone's OpenSL buffer sat between the remote sound and the picture.
sub music_receiver_sink_latency {
	my $json = `pactl -f json list sink-inputs 2>/dev/null`;
	return 0 unless $json =~ /^\s*\[/;
	my $list = eval { decode_json $json } || [];
	my $ms = 0;
	foreach my $si ( @{$list} ) {
		my $p = $si->{'properties'} || {};
		my $name = lc(($p->{'media.name'} || '') . ' ' . ($p->{'application.name'} || '') . ' ' . ($p->{'application.process.binary'} || ''));
		next unless $name =~ /jawnos-music/;
		my $b = ($si->{'buffer_latency_usec'} || 0) + 0;
		my $s = ($si->{'sink_latency_usec'} || 0) + 0;
		my $v = ($b + $s) / 1000;
		$ms = $v if $v > $ms;
	}
	return int($ms + 0.5);
}

# How many bytes of the stream carry one millisecond of sound. PCM is exact;
# Opus is compressed at a varying rate, so its calibration comes from the
# source's beacons (the bytes between two marks over the media time between
# them), which is why the receiver keeps the largest from every pair.
sub music_receiver_bytes_per_ms($st) {
	my $rate = &music_stream_rate($st->{'rate'});
	return 0 unless $rate;
	return ($st->{'rx_bpm'} || 0) if ($st->{'codec'} || 'pcm') eq 'opus';
	return $rate * 2 * 2 / 1000;
}

sub music_pacat_command($st, $rate) {
	my $pacat = `command -v pacat 2>/dev/null`;
	chomp $pacat;
	$pacat = 'pacat' unless $pacat;
	return ($pacat,
		'--playback', '--raw', '--format=s16le',
		'--rate=' . &music_stream_rate($rate),
		'--channels=2',
		# A video's picture is delayed to match the sound, so its remote stream is
		# allowed a deeper buffer: a Wi-Fi stall then plays through instead of
		# cutting out. A music file has no picture to answer the extra delay, so it
		# keeps the tight sink buffer.
		'--latency-msec=' . &music_receiver_latency_ms($st),
		# PulseAudio's stream-restore remembers a stream name's old level, so a
		# receiver that was once turned down (or muted) came back silent while
		# the Music app looked like it was playing. pacat names the level it
		# wants at creation; the sender's own volume arrives in the samples.
		'--volume=65536',
		'--client-name=jawnos-music',
		'--stream-name=jawnos-music');
}

# A video can spend a few hundred milliseconds of buffer on lip-sync; a music
# file cannot, because Me is playing the same sound with no picture to wait.
sub music_receiver_latency_ms {
	my $st = shift;
	return ((($st && ($st->{'type'} || '') eq 'video')) ? 80 : 30);
}

sub music_receiver_pipe_bytes($st) {
	return ((($st && ($st->{'type'} || '') eq 'video')) ? 32_768 : 8_192);
}

sub music_receiver_write_cap($st) {
	return ((($st && ($st->{'type'} || '') eq 'video')) ? 65_536 : 16_384);
}
1;
