#!/usr/bin/perl




use Mojolicious::Lite -signatures;
use Mojolicious::Static;
use Mojo::Log;
use Mojo::File;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::UserAgent;
use Mojo::IOLoop;
use Mojo::IOLoop::Stream;
use Mojo::URL;
use Encode qw(encode decode);
use List::Util qw(shuffle);
use Data::Dumper;
use Data::UUID;
use Mojo::Util qw/term_escape html_unescape url_unescape url_escape/;
use File::Find;
use File::Slurp;
use Fcntl qw(F_SETPIPE_SZ);
plugin 'RenderFile';
use LWP::UserAgent;
use Mojolicious::Sessions;
use URI::Encode qw(uri_encode uri_decode);
use MIME::Base64;
use strict;
use warnings;
no warnings 'uninitialized';
my $com = 'echo $HOME';
my $cwd = `$com`;
chomp $cwd;

require "./subroutines.pl";
my $device = &subs::device_setter();
my $config_file = read_file('./config.json');
my $config = decode_json $config_file;
my $environment = $config->{'environment'};
my @folders = @{$config->{'folders'}};
our $logfile = &subs::home($config->{'logfile'});
`touch $logfile` if not -e $logfile;
our $log = Mojo::Log->new(path => $logfile);
my (@results);
my $files = [];
my $thumb_files = [];
my $permissive = 0;

# The playable and cover extensions the walk looks for. The old wanted() tested
# them with /mp3$|m4a$|.../i - a ten-way case-insensitive suffix match run on
# every entry of every folder, and the one part of the walk that cost real time
# (about 0.15s of a 0.2s walk over a large library). A look-up of the final three
# or four lowercased characters answers the same question in constant time. The
# extensionless tail is still allowed ("WAV" ends in wav), exactly as before.
my %playable_suffix = map { $_ => 1 } qw/mp3 m4a wav flac mp4 mkv mov webm weba wmv/;
my %cover_suffix = map { $_ => 1 } qw/jpg png/;

sub playable_name($name) {
	my $tail = lc substr($name, -4);
	return 1 if $playable_suffix{$tail};
	return 1 if $playable_suffix{substr($tail, -3)};
	return 0;
}

sub playable_enc_name($name) {
	return 0 unless lc(substr($name, -4)) eq '.enc';
	return playable_name(substr($name, 0, -4));
}

# An album's own visibility decides whether its tracks need the padlock. The
# album is the folder above the file, the same part the walk names as `app`.
# The shared rule is read fresh: a cached answer would keep a track visible after
# a lockdown began or a place changed.
sub music_app_name($name) {
	my @part = split '/', $name;
	return '' unless scalar @part >= 2;
	my $app = &subs::unformat_name($part[-2]);
	return (defined $app && length $app) ? $app : '';
}

sub music_app_private($name) {
	my $app = &music_app_name($name);
	return 0 unless length $app;
	return &subs::app_private_now($app) ? 1 : 0;
}

sub music_app_visible($name) {
	my $app = &music_app_name($name);
	return 1 unless length $app;
	return &Manager::help_app_hidden($app) ? 0 : 1;
}

sub process_file($name) {
	# A private album is a lock, not a place level. Outside a private place its
	# tracks are not listed at all; inside one they still need a fingerprint (its
	# own Music padlock or the Security private grant).
	if (&music_app_private($name)) {
		return unless &subs::private_reachable_now();
		return unless $permissive == 1 || &subs::private_revealed();
	}
	return unless playable_name($name)
		|| (($permissive == 1 || music_app_visible($name)) && playable_enc_name($name));
	# A directory walk hands names back as UTF-8 bytes, but the music window is a
	# character string: an undecoded name gets upgraded as Latin-1 and served
	# double-encoded (Æ -> Ã), so the player then cannot open it. Decode only the
	# names that are kept, so the rest of the app sees them as the browser does.
	# Invalid UTF-8 is left as bytes, which is what it was before.
	utf8::decode($name) unless utf8::is_utf8($name);
	$name =~ s/^\.\///g;
	push @{$files}, $name;
}

sub process_thumbfile() {
	my $name = $File::Find::name;
	if ($cover_suffix{lc substr($name, -3)}) {
		$name =~ s/^\.\///g;
		push @{$thumb_files}, $name;
	}
}

get '/manager/music' => sub ($c) {
	my $search = $c->param('search') || &subs::setting_grabber({ app => 'music', 'setting' => 'search' });
	my $window_maker = $c->param('window_maker');
	# an app opens locked: only the token this window holds, minted by the
	# phone's unlock, may list a sealed track. A refresh after that unlock
	# carries the token and stays open.
	my $unlocked = &Manager::media_unlock_open($c, 'music') ? 1 : 0;
	my $unlock = $unlocked ? $c->param('unlock') : '';
	my $content_cache = &subs::jawn_version() . ($unlocked ? '-unlocked' : '-locked');
	my $port = $c->req->url->base->port;
	my $misses = eval { return decode_json $c->param('misses') } || {};
	if (!$misses->{'video'}) {
		$misses->{'video'} = &subs::random_string_creator(25,"Aa");
	}
	$files = eval { return decode_json $c->param('files') } || undef;
	my $same_order = $c->param('same_order');
	my $settings = &subs::settings_grabber({ app => 'music' });
	$settings->{'artist'} = eval { return decode_json $settings->{'artist'} } || [];
	$settings->{'album'} = eval { return decode_json $settings->{'album'} } || [];
	if ($settings->{'library'} ne 'local' && $c->param('remoted') ne 'yes') {
		my $rm = &subs::db_query('select * from remote_machines where uuid=? and connection=?', $settings->{'library'}, 'active')->hashes->[0];
		if ($rm->{'uuid'}) {
			$c->param('remote_uuid' => $rm->{'uuid'});
			$c->param('library_name' => &music_remote_label($rm));
			$c->param('subprocess' => 'yes');
			my $result = &Manager::remote_relay_request($c);
			if ($result =~ /music/gi) {
				$c->render(text => $result);
				return;
			}
		}
		else { &subs::setting_setter({ app => 'music', setting => 'library', value => 'local' }); $settings->{'library'} = 'local'; }
	}
	my $misc_settings = &Manager::misc_setting_list();
	# A relayed page carries the host it came from; do not answer it from the
	# cached shell, which was built for whichever library last filled it.
	unless ($files || $c->param('library_name')) {
		if (my $cache = &subs::cache_get({ app => 'music', context => 'content', subcontext => $content_cache })) {
			if ($cache->{'contents'}) {
				if ($c->param('window_maker')) {
					my $website = &Manager::window_maker({ app => 'music', title => 'music', contents => $cache->{'contents'} }, &subs::rightNow());
					$c->render(text => $website);
				}
				else {
					$c->render(text => $cache->{'contents'});
				}
				return;
			}
		}
	}
	my $crate = &music_search({ settings => $settings, c => $c, search => $search, now_playing => {}, port => $port, misc_settings => $misc_settings, files => $files, same_order => $same_order, permissive => $unlocked });
	$crate->{'unlock'} = $unlock;
	$crate->{'unlocked'} = $unlocked;
	my $timestamp = &subs::rightNow();
	my $jmao = &subs::setting_grabber({ app => 'music', setting => 'mao' });
	my $player = &subs::cache_get({ app => 'music', context => 'player' });
	my $resizes = eval { return decode_json $settings->{'resizes'} } || {};
	my $contents;
	if ($c->param('window_maker')) {
		$contents = $c->render_to_string(
			crate => $crate,
			interface_colour => &subs::random_colour_grabber(),
			template => 'apps/music/music',
			window_maker => 'yes',
			folders => $misc_settings,
			device => &subs::device_setter(),
			mao => eval { return decode_json $jmao } || {},
			jmao => $jmao,
			search => $search,
			resizes => $resizes,
			misses => $misses,
		);
		my $website = &Manager::window_maker({ app => 'music', title => 'music', contents => $contents }, $timestamp);
		$c->render(text => $website);
	}
	else {
		$contents = $c->render_to_string(
			crate => $crate,
			interface_colour => &subs::random_colour_grabber(),
			template => 'apps/music/music',
			layout => 'music',
			window_maker => 'no',
			string => &subs::jawn_version(),
			folders => $misc_settings,
			device => &subs::device_setter(),
			mao => eval { return decode_json $jmao } || {},
			jmao => $jmao,
			search => $search,
			resizes => $resizes,
			misses => $misses
		);
		$c->render(text => $contents);
	}
	&subs::cache_set({ app => 'music', context => 'content', subcontext => $content_cache }, { contents => $contents });
};


get '/play' => sub($c) {
	my $mao = eval { return decode_json &subs::setting_grabber({ app => 'music', setting => 'mao' }) } || {};
	# the query is already decoded by Mojo; decoding again would corrupt a name
	# with a literal %xx in it (see Manager::rock_and_roll)
	my $track = &subs::terminal_name($c->param('track'));
	my $data;

	# The ahead tap is an <audio> element reading the same file. Without a Range
	# the file is answered as a live stream with no known length: its seekable
	# window moves and its clock wanders, so a seek lands somewhere else. A
	# whole-file range gives it the same fixed, seekable response a <video>
	# element asks for by itself.
	if ((($c->param('ahead') // $c->param('clone') // '') eq '1') && !$c->req->headers->header('Range')) {
		$c->req->headers->header('Range' => 'bytes=0-');
	}

	&Manager::rock_and_roll($c);

	# the ahead tap re-requests /play for the same file; it must not start the
	# server-side player a second time
	if ($mao->{'srv'} eq 'on' && $c->param('ahead') ne '1' && $c->param('clone') ne '1') {
		&subs::subprocessor(sub {

			if ($device eq 'computer') {
				my $t = term_escape $track;
				`vlc $track`;
			}
			elsif ($device eq 'mobile') {
				`play $track`;
			}
		}, { name => 'music play' });
		$c->render(text => 'play');
	}

};

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
	$row{'machine'} = $device;
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
	return unless $device eq 'mobile';
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
	return 0 unless $device eq 'mobile';
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
	my $pan = &music_channel_filter($channel, $device);
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
	my $port = $rm->{'ws_port'} || $config->{'ws_port'} || '';
	return 'wss://' . $host . ($port ? ':' . $port : '') . '/manager/music/stream';
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
		$c->tx->send({text => encode_json({ type => 'error', key => $key, error => 'unreachable' })});
		return;
	}
	if (($rm->{'device'} || '') eq 'server') {
		$c->tx->send({text => encode_json({ type => 'error', key => $key, error => 'no audio' })});
		return;
	}
	my $url = &music_source_uri($rm);
	unless ($url) {
		$c->tx->send({text => encode_json({ type => 'error', key => $key, error => 'no address' })});
		return;
	}
	my $ua = Mojo::UserAgent->new()->insecure(1)->connect_timeout(5)->request_timeout(0)->inactivity_timeout(0);
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
			&music_sync_log('link', $key, { type => 'link', state => 'error' });
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
	my $port = $rm->{'ws_port'} || $config->{'ws_port'} || '';
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
	my @cmd = ('ffmpeg', '-hide_banner', '-loglevel', 'error');
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
	my $cmd = ($open ? 'musicVideoReceiverOpen(' : 'musicVideoReceiverClose(')
		. encode_json($id) . ($open ? ',' . encode_json($info) : '') . ');';
	&Websocket::send('server', { console => $cmd, timestamp => &subs::rightNow() });
}

# The browser's playback stream can come back from PulseAudio's stream-restore
# at a remembered level - muted, or a few percent - and WebKit's element volume
# is tied to that stream. The app's real level lives in the shared graph (or the
# system mixer), so the stream itself is always meant to be full scale. Put only
# this house's streams right, after playback has created them.
sub music_stream_health {
	my $full = shift || 0;
	return [] unless $device eq 'computer';
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

get '/manager/music/stream_health' => sub($c) {
	my ($fixed, $latency) = &music_stream_health(($c->param('full') // '') eq '1');
	$c->render(json => { fixed => $fixed, latency => $latency });
};

get '/manager/music/receiver' => sub($c) {
	$c->render(json => &music_receiver_state());
};

post '/manager/music/receiver/stop' => sub($c) {
	&music_receiver_stop();
	$c->render(json => &music_receiver_state());
};

post '/manager/music/receiver/block' => sub($c) {
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
};

# The last reports from the browser and from each receiver. A failing stream is
# read here after the fact: the source's send counters, the receiver's arrival
# gaps, and the picture's black runs sit on the same timeline. `limit` caps the
# records returned (1-500); the file itself is rotated at 1 MB.
get '/manager/music/sync_diag' => sub($c) {
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
};

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

websocket '/manager/music/video' => sub ($c) {
	if ($c->param('peer')) {
		my $signatorial = $c->param('signatorial');
		my $rm = ($signatorial ? &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0] : undef);
		unless ($rm && &subs::peer_verify($c, $rm)) { $c->rendered(403); return; }
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
};

websocket '/manager/music/stream' => sub ($c) {
	if ($c->param('peer')) {
		my $signatorial = $c->param('signatorial');
		my $rm = ($signatorial ? &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0] : undef);
		unless ($rm && &subs::peer_verify($c, $rm)) {
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
};



# Which folders this device is looking at, by location name as well as by path.
# The window sends the buttons it has lit and the names are the intent -
# documents, downloads, and so on - while the path behind each one is this
# machine's own, so a library on another machine is asked for the same locations
# by name instead of by this machine's paths. Without a selection the stored
# toggles decide, which is what the first window build has to go on. A lit button
# with no path behind it on this machine is nothing to walk, and is left out
# rather than guessed at.
sub music_folder_selection($selected) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my @picked = ();
	my $settings = &Manager::misc_setting_list();
	my %wanted;
	my $chosen = defined $selected;
	foreach my $s ( @{$selected || []} ) {
		next unless $s =~ /_location$/;
		$wanted{$s} = 1;
	}
	foreach my $s ( sort keys %{$settings->{$device}} ) {
		if ($s =~ /_location$/gi) {
			my $status = &subs::setting_grabber({ app => 'music_folder_toggle', setting => $s, device => $device });
			if ($chosen) {
				next unless $wanted{$s};
			}
			elsif ($status ne 'on') {
				next;
			}
			my $path = $settings->{$device}->{$s};
			next unless (defined $path && length $path);
			my $location = $s;
			$location =~ s/_location$//;
			push @picked, { location => $location, path => $path };
		}
	}
	return \@picked;
}

sub music_folder_grabber($selected) {
	return map { $_->{'path'} } @{&music_folder_selection($selected)};
}

# The archived half of a listing. For the folders being looked at, the rows come
# from the archive machine's manifest - one small request instead of a walk over
# the tunnel - and each row keeps the machine it lives on, because that is where
# the player has to fetch the bytes from. An artist or album pick reads the same
# manifest down to that folder instead of a whole location.
sub music_archive_entries($data) {
	my $picked = $data->{'picked'} || [];
	my $misc = $data->{'misc_settings'} || &Manager::misc_setting_list();
	my $device = &subs::device_setter();
	my $machines = &subs::remote_machine_lister({ self => 'no' });
	my @lookups;
	foreach my $pick ( @{$picked} ) {
		if ($pick->{'location'}) {
			my $rm = &subs::archive_machine_for($pick->{'location'}, $misc->{$device} || {}, $machines);
			next unless ($rm && $rm->{'uuid'});
			push @lookups, { location => $pick->{'location'}, remote_uuid => $rm->{'uuid'}, prefix => '' };
		}
		else {
			my $plan = &subs::archive_plan({
				items => [ { path => $pick->{'path'}, type => 'folder' } ],
				settings => $misc->{$device} || {},
				machines => $machines
			});
			foreach my $job ( @{$plan->{'jobs'}} ) {
				push @lookups, { location => $job->{'location'}, remote_uuid => $job->{'remote_uuid'}, prefix => $job->{'relative'} };
			}
		}
	}
	my (@entries, %fetched);
	foreach my $lookup ( @lookups ) {
		my $key = $lookup->{'location'} . '|' . $lookup->{'remote_uuid'};
		my $manifest = $fetched{$key};
		unless (defined $manifest) {
			# the listing is an errand, not a transfer: a sleeping archive machine
			# must not hold the worker (and the window) for the long default
			$manifest = &subs::archive_manifest_fetch({ remote_uuid => $lookup->{'remote_uuid'}, location => $lookup->{'location'}, timeout => 6 });
			$fetched{$key} = $manifest;
		}
		next if $manifest->{'error'};
		my $folder = $manifest->{'folder'} || '';
		foreach my $row ( @{$manifest->{'rows'} || []} ) {
			my $type = $row->{'type'} || '';
			next unless ($type eq 'audio' || $type eq 'video');
			my $relative = $row->{'relative'} || '';
			next unless length $relative;
			# a sealed track waits for the padlock only when its album is hidden
			next if (!$permissive && $relative =~ /\.enc$/i && !music_app_visible($relative));
			next if (length $lookup->{'prefix'} && index($relative, $lookup->{'prefix'}) != 0);
			push @entries, {
				path => (length $folder ? $folder . '/' . $relative : $relative),
				location => $lookup->{'location'},
				relative => $relative,
				type => $type,
				info => $row->{'info'} || {},
				size => $row->{'size'},
				mtime => $row->{'mtime'},
				remote_uuid => $lookup->{'remote_uuid'},
				remote_hostname => $manifest->{'hostname'} || ''
			};
		}
	}
	return { entries => \@entries };
}

sub music_search($data) {
	my $search = $data->{'search'};
	my $now_playing = $data->{'now_playing'};
	my $settings = $data->{'settings'};
	my $c = $data->{'c'};
	my $misc_settings = $data->{'misc_settings'};
	my $port = $data->{'port'};
	my $misses = $data->{'misses'};
	$files = [];
	unless ($settings->{'uuid'}) {
		$settings = &subs::settings_grabber({ app => 'music' });
		$settings->{'artist'} = eval { return decode_json $settings->{'artist'} } || [];
		$settings->{'album'} = eval { return decode_json $settings->{'album'} } || [];
	}
	# the window's token decides this, not the secret left in settings: a
	# fresh open is locked even if an earlier window still holds one
	$permissive = $data->{'permissive'} ? 1 : 0;

	my @folders;
	my %archive;
	if ($data->{'files'}) {
		$files = $data->{'files'};
	}
	else {
		my $picked = [];
		if (scalar @{$settings->{'album'}} > 0) { 
			push @folders, map { $_->{'path'} } @{$settings->{'album'}};
			$picked = [ map { { path => $_->{'path'} } } @{$settings->{'album'}} ];
		}
		elsif (scalar @{$settings->{'artist'}} > 0) {
			push @folders, map { $_->{'path'} } @{$settings->{'artist'}};
			$picked = [ map { { path => $_->{'path'} } } @{$settings->{'artist'}} ];
		}
		else {
			my $selection = &music_folder_selection($data->{'folders'});
			@folders = map { $_->{'path'} } @{$selection};
			$picked = $selection;
		}
		my @walk = grep { -d } map { &subs::home($_) } @folders;
		&process_file($_) for &subs::dir_listing(\@walk);
		# the archive is part of the collection too, when the app is asked to
		# look there: its manifest is the listing, and each row knows the
		# machine its bytes come from
		if ($settings->{'archive'} eq 'on') {
			my $archived = &music_archive_entries({ picked => $picked, misc_settings => $misc_settings });
			foreach my $entry ( @{$archived->{'entries'}} ) {
				push @{$files}, $entry->{'path'};
				$archive{$entry->{'path'}} = $entry;
			}
		}
	}
	my @local_files = @{$files};
	if ($search && !$data->{'files'}) {	
		@local_files = grep { lc $_ =~ /($search)/gi } @{$files};
	}
	# a caller that only wants the matches (the guide's play_music) gets the file
	# list back instead of a rendered crate, so it can hand one file to the player
	if ($data->{'return_files'}) {
		return { files => \@local_files, count => scalar @local_files };
	}
	my $crate = &song_maker({ c => $c, port => $port, files => \@local_files, archive => \%archive, settings => $settings, now_playing => $now_playing, same_order => $data->{'same_order'} });
	$permissive = 0;
	return $crate;
}

# A peer's name for the library label. A Termux machine's own hostname is
# 'localhost', which tells nobody which library they are on; its fqdn (or its
# address) does.
sub music_remote_label($rm) {
	return '' unless $rm;
	my $host = $rm->{'hostname'} || '';
	$host = $rm->{'fqdn'} || $rm->{'ip'} || '' if $host eq '' || lc($host) eq 'localhost' || lc($host) eq 'me';
	return $host || $rm->{'uuid'} || '';
}

# What the search bar should say the library is: this machine's own name for a
# local library, or the host the window was relayed from for a remote one. The
# caller passes library_name when it relays, because the page is then rendered
# by the remote machine and knows itself only as 'local'.
sub music_library_label($settings, $c) {
	my $passed = $c ? $c->param('library_name') : undef;
	return $passed if defined $passed && length $passed;
	my $library = $settings->{'library'} // '';
	if ($library eq '' || $library eq 'local') {
		return &subs::setting_grabber({ app => 'me', setting => 'computer_name' })
			|| &subs::config_reader()->{'name'}
			|| &subs::ui('Local');
	}
	return &subs::ui('None') if $library eq 'none';
	my $rm = &subs::db_query('select hostname,fqdn,ip from remote_machines where uuid=?', $library)->hashes->[0];
	my $host = &music_remote_label($rm);
	return $host if length $host;
	return $library;
}

# ---- what a track is called -------------------------------------------------
#
# The library is a folder tree - artist/album/track - but a file's own name
# often carries more than its folder, and a release name such as
# Doctor.Who.S03E06.720p.HDTV.x264 tells nobody what the episode is. The list
# shows three things and only three: the artist, the album and the track. A
# music file normally carries them as tags, so those win. A video usually has
# only its name: the episode marker is read out of it (S03E06, 1x02,
# Season 3 Episode 6), and the quality, source, codec and release group are
# dropped, so both kinds read the same way.

sub music_trim_text {
	my $text = shift;
	return '' unless defined $text;
	$text = "$text";
	$text =~ s/[\x00-\x1f\x7f]+/ /g;
	$text =~ s/\s+/ /g;
	$text =~ s/^ | $//g;
	return $text;
}

# A folder or file name rather than a tag: dots and underscores stand in for
# spaces, and a name stored wholly in lower case is title-cased. A name that
# already carries a capital keeps its own spelling (AC/DC stays AC/DC).
sub music_path_text {
	my $text = &music_trim_text(shift);
	$text =~ s/[._]+/ /g;
	$text =~ s/\s+/ /g;
	$text =~ s/^ | $//g;
	if ($text !~ /\p{Lu}/) {
		$text =~ s/(^|[\s\-\(\[])(\p{Ll})/$1 . uc($2)/ge;
	}
	return $text;
}

# Everything a release name carries that is about the file and not the work.
my $music_release_junk = qr{
	\b(?:
		(?:2160|1440|1080|720|576|480|360)p
		|4k|uhd|hdr10|hdr
		|blu[ .-]?ray|bdrip|brrip|remux|web[ .-]?dl|webrip|web[ .-]?rip
		|hdtv|pdtv|dvd|dvdrip|dvdscr|hdrip|hdlight
		|x264|x265|h[ .]?264|h[ .]?265|hevc|avc|xvid|divx
		|10bit|8bit|hi10p
		|aac|ac3|eac3|dts(?:[ .-]?hd)?|ddp?[ .]?[57][ .]?1|truehd|flac|opus
		|amzn|dsnp|hmax|atvp|yify|yts|rarbg|eztv|galaxytv
	)\b
}ix;

sub music_strip_release {
	my $text = &music_trim_text(shift);
	return '' unless length $text;
	$text =~ s/\[[^\]]*\]//g;
	$text =~ s/\{[^}]*\}//g;
	$text =~ s/\([^)]*(?:\d{3,4}p|rip|x26[45]|hevc|avc|aac|ac3|dts|hdr|uhd|web)[^)]*\)//gi;
	my $had_junk = ($text =~ s/$music_release_junk/ /gi) ? 1 : 0;
	# a group tag usually hangs off the last release token, as in x264-GROUP
	$text =~ s/\s*[-\x{2013}\x{2014}]\s*[A-Za-z0-9][A-Za-z0-9._-]{1,24}\s*$// if $had_junk;
	# edges: Arrested Development - S01E01 - Pilot leaves "- Pilot"; the dashes
	# belong to the release name, not the episode
	$text =~ s/^[\s\-\x{2013}\x{2014}:;,.|_]+//;
	$text =~ s/^[+&]\s+//;
	$text =~ s/[\s\-\x{2013}\x{2014}:;,.|_]+$//;
	return &music_trim_text($text);
}

# A file's extension tells us how to play it, never what it is. song_maker has
# already removed the audio ones it recognises; this finishes the job for video
# (and for a sealed track, whose real extension sits inside .enc).
my $music_media_extension = qr/\.(?:mp4|m4v|mkv|avi|mov|webm|wmv|flv|mpg|mpeg|m2ts|ts|mp3|m4a|wav|flac|aac|ogg|opus|aiff|wma)$/i;
sub music_media_stem {
	my $text = shift;
	return '' unless defined $text;
	my $stem = "$text";
	$stem =~ s/\.enc$//i;
	$stem =~ s/$music_media_extension//;
	return $stem;
}

sub music_episode_from_text {
	my $text = shift;
	return {} unless defined $text && length $text;
	# S06E01, S06X01 / S04M01 (The Office and Sabrina use X and M),
	# S01E01+E02, S07E17X01, S07E21+22
	if ($text =~ /^(.*?)\s*\bS(\d{1,2})\s*([EXM])(\d{1,3})(?:\s*[+&]\s*[EXM]?\d{1,3})*(?:\s*X\d{1,3})?\b(.*)$/i) {
		my ($show, $season, $marker, $episode, $rest) = ($1, $2, $3, $4, $5);
		return { show => $show, season => $season, episode => $episode, rest => $rest,
			code => sprintf('S%02d%s%02d', $season, uc $marker, $episode) };
	}
	# 1x02, and 4x22 & 23
	if ($text =~ /^(.*?)\s*\b(\d{1,2})\s*x\s*(\d{1,3})(?:\s*[+&]\s*\d{1,3})*\b(.*)$/i) {
		return { show => $1, season => $2, episode => $3, rest => $4, code => sprintf('S%02dE%02d', $2, $3) };
	}
	if ($text =~ /^(.*?)\s*\b(?:Season|Series)\s*(\d{1,2})\s*(?:Episode|Ep)\s*(\d{1,3})\b(.*)$/i) {
		return { show => $1, season => $2, episode => $3, rest => $4, code => sprintf('S%02dE%02d', $2, $3) };
	}
	# Episode 6 / E06 / X01 / M01. X264 and X265 are codecs, not episodes.
	if ($text =~ /^(.*?)\s*\b([EXM])(?:p|pisode)?\s*(\d{1,3})\b(.*)$/i) {
		my ($show, $marker, $episode, $rest) = ($1, $2, $3, $4);
		unless (uc($marker) eq 'X' && $episode =~ /^26[45]$/) {
			my $code = ($marker =~ /E/i) ? sprintf('Episode %d', $episode) : sprintf('%s%02d', uc $marker, $episode);
			return { show => $show, season => '', episode => $episode, rest => $rest, code => $code };
		}
	}
	# Home Improvement - 315 - Reel Men: a packed season/episode code
	if ($text =~ /^(.*?)\s*[-\x{2013}\x{2014}]\s*(\d)(\d{2})\s*[-\x{2013}\x{2014}]\s*(.*)$/) {
		return { show => $1, season => $2, episode => $3, rest => $4, code => sprintf('S%02dE%02d', $2, $3) };
	}
	# Home Improvement 5-01 A Taylor Runs Through It
	if ($text =~ /^(.*?)\s*\b(\d{1,2})\s*[-\x{2013}\x{2014}]\s*(\d{2})\b(.*)$/) {
		return { show => $1, season => $2, episode => $3, rest => $4, code => sprintf('S%02dE%02d', $2, $3) };
	}
	return {};
}

# A release tag repeated through a whole folder (GalaxyTV, PSA, SAiNTS, 2CH) is
# part of the release, not the episode. Only tokens that *look* like release
# noise are taken: one with a digit, one in capitals at the end, or one sitting
# after a known release token. This is deliberately narrow - in the Portugal.
# The Man album every track ends in "Magic", and Magic is the title, not noise.
sub music_common_noise {
	my $files = shift;
	my %noise;
	my @names;
	foreach my $path ( @{$files || []} ) {
		next unless defined $path && length $path;
		my $base = $path;
		$base =~ s{.*/}{};
		$base = &music_media_stem($base);
		push @names, $base if length $base;
	}
	my $count = scalar @names;
	return {} if $count < 3;
	my $need = int($count * 0.8 + 0.9999);
	my (%seen, %after, %last);
	foreach my $base ( @names ) {
		my @token = grep { length } split /[^A-Za-z0-9]+/, $base;
		next unless scalar @token;
		my %once;
		$once{$_} = 1 for @token;
		$seen{$_}++ for keys %once;
		$last{$token[-1]}++ if length $token[-1];
		my $marked = 0;
		foreach my $token ( @token ) {
			if ($token =~ $music_release_junk) {
				$marked = 1;
				next;
			}
			$after{$token}++ if $marked;
		}
	}
	foreach my $token ( keys %seen ) {
		next if length($token) < 2;
		next if $token =~ /^\d+$/;
		next if $token =~ /^[Ss]\d{1,2}[EeXxMm]?\d{0,3}$/;
		next if $token =~ /^\d{1,2}x\d{1,3}$/i;
		next if $token =~ /^(?:the|a|an|and|or|of|to|in|on|for|with|at|by|from|one|two|part|vol|ep|episode|season|series)$/i;
		next if ($seen{$token} || 0) < $need;
		my $digit = ($token =~ /\d/) ? 1 : 0;
		my $caps = ($token =~ /^[A-Z0-9]{2,12}$/) ? 1 : 0;
		my $after = (($after{$token} || 0) >= $need) ? 1 : 0;
		my $last = (($last{$token} || 0) >= $need) ? 1 : 0;
		$noise{lc $token} = 1 if $digit || $after || ($caps && $last);
	}
	return \%noise;
}

# The three labels every track carries, worked out once so the list, the icons
# grid and the phone all draw the same words.
sub music_media_labels {
	my ($f, $noise) = @_;
	$noise ||= {};
	my $tags = (ref($f->{'info'}) && ref($f->{'info'}->{'tags'})) ? $f->{'info'}->{'tags'} : {};
	my $tag_artist = &music_trim_text($tags->{'artist'} || $tags->{'album_artist'} || '');
	my $tag_album  = &music_trim_text($tags->{'album'} || '');
	my $tag_title  = &music_trim_text($tags->{'title'} || '');
	my $is_video = (($f->{'type'} || '') eq 'video') ? 1 : 0;
	my $folder_artist = &music_path_text($f->{'artist_name'} // $f->{'artist'});
	my $folder_album  = &music_path_text($f->{'album_name'} // $f->{'album'});
	my $stem = &music_path_text(&music_media_stem($f->{'full_title'} || $f->{'song'}));
	# folder names that only say where the file is, not who made it
	my %generic = map { $_ => 1 } qw/videos video movies movie tv television shows show media library music audio films film/;
	$folder_artist = '' if $generic{lc $folder_artist};
	$folder_album  = '' if $generic{lc $folder_album};
	if ($is_video) {
		# A folder carries release notes too ("(360p re-dvdrip)"), and a
		# whole-series folder carries a range ("S01-S07 (1993-)"). Clean both
		# before they become the artist and album.
		$folder_artist = &music_strip_release($folder_artist);
		$folder_album  = &music_strip_release($folder_album);
		my $album_range = ($folder_album =~ /\bS\d{1,2}\s*[-\x{2013}\x{2014}]\s*S?\d{1,2}\b/i
			|| $folder_album =~ /\b(?:season|series)\s*\d{1,2}\s*[-\x{2013}\x{2014}]\s*\d{1,2}\b/i) ? 1 : 0;
		my $series_name = '';
		if ($album_range) {
			($series_name = $folder_album) =~ s/\s*\bS\d{1,2}\s*[-\x{2013}\x{2014}]\s*S?\d{1,2}\b//ig;
			$series_name =~ s/\s*\b(?:season|series)\s*\d{1,2}\s*[-\x{2013}\x{2014}]\s*\d{1,2}\b//ig;
			$folder_album = '';
		}
		foreach my $name ( \$folder_artist, \$folder_album ) {
			next unless length $$name;
			$$name =~ s/\s*\bS\d{1,2}\s*[-\x{2013}\x{2014}]\s*S?\d{1,2}\b//ig;
			$$name =~ s/\s*\b(?:season|series)\s*\d{1,2}\s*[-\x{2013}\x{2014}]\s*\d{1,2}\b//ig;
			$$name =~ s/\s*\((?:19|20)\d{2}\s*[-\x{2013}\x{2014}]\s*(?:\d{2,4})?\)\s*$//;
			$$name =~ s/\s+\b(?:19|20)\d{2}\s*[-\x{2013}\x{2014}]\s*(?:\d{2,4})?$// if $$name =~ /[^\d\s]/;
			$$name = &music_trim_text($$name);
		}
		# a whole-series folder is the show, not an album: when the file sits
		# directly in it, that show is the artist and the season comes from the
		# episode marker (Entourage S08M01, Sabrina TTW X01)
		if (!length $folder_artist && length $series_name) {
			$series_name =~ s/\s*\((?:19|20)\d{2}\s*[-\x{2013}\x{2014}]\s*(?:\d{2,4})?\)\s*$//;
			$series_name =~ s/\s+\b(?:19|20)\d{2}\s*[-\x{2013}\x{2014}]\s*(?:\d{2,4})?$// if $series_name =~ /[^\d\s]/;
			$folder_artist = &music_trim_text($series_name);
		}
	}
	# "Home Improvement Season 3", "The Office US S06 (360p re-blurip)" and
	# "Friends Season 1" are all the same shelf; name it Season N. A folder
	# holding a range (S01-S09, Season 1-3) was emptied above.
	if ($folder_album =~ /\b(?:season|series)\s*(\d{1,2})\b(?!\s*[-\x{2013}\x{2014}]\s*[SE]?\d)/i
		|| $folder_album =~ /\bS(\d{1,2})\b(?!\s*[-\x{2013}\x{2014}]\s*[SE]?\d)/i) {
		$folder_album = 'Season ' . (0 + $1);
	}

	my ($artist, $album, $track, $code);
	if (($f->{'type'} || '') eq 'video') {
		my $ep = &music_episode_from_text($stem);
		# A container's own title is sometimes the release name itself; trust it
		# only when it is not that.
		my $tag_ok = length($tag_title)
			&& $tag_title !~ /\bS\d{1,2}\s*[EXM]\d{1,3}\b/i
			&& $tag_title !~ /\b(?:\d{3,4}p|4k|x26[45]|hevc|web[ .-]?dl|blu[ .-]?ray)\b/i
			&& $tag_title !~ /\.(?:mp4|m4v|mkv|avi|mov|webm|wmv|flv|mpg|mpeg|m2ts|ts)$/i;
		if ($ep->{'episode'}) {
			$artist = &music_strip_release($ep->{'show'});
			# Doctor Who 2005 is the same show as Doctor Who in the folder
			$artist =~ s/\s*\((?:19|20)\d{2}\)\s*$//;
			$artist =~ s/\s+\b(?:19|20)\d{2}\s*$// if $artist =~ /[^\d\s]/;
			$artist = &music_trim_text($artist);
			$artist = $tag_artist if !length $artist;
			$artist = $folder_artist if !length $artist;
			$code = $ep->{'code'};
			my $title = &music_strip_release($ep->{'rest'});
			$title = $tag_title if !length($title) && $tag_ok && lc($tag_title) ne lc($artist);
			$track = length($title) ? $title : $code;
			my $season_no = $ep->{'season'};
			my $folder_is_season = $folder_album =~ /\b(?:season|series)\b|\bS\d{1,2}\b/i;
			if (length($folder_album) && lc($folder_album) ne lc($artist) && ($folder_is_season || length $season_no)) {
				$album = $folder_album;
			}
			elsif (length $season_no) {
				$album = 'Season ' . (0 + $season_no);
			}
			else {
				$album = $folder_album;
			}
			$album = $tag_album if !length $album;
		}
		else {
			$artist = $tag_artist || $folder_artist;
			$album = $tag_album || $folder_album;
			# "001 - Pilot" (Boy Meets World): the number is the episode and the
			# season is the folder. Only where the folder names a season, so a
			# film called 300 keeps its number.
			my ($season_no) = $folder_album =~ /^Season\s*(\d+)$/i;
			my $name_rest;
			if (length($season_no) && $stem =~ /^(\d{1,3})(?:-\d)?\s*[-\x{2013}\x{2014}]\s*(.+)$/) {
				my $ep_no = $1;
				$name_rest = $2;
				$code = sprintf('S%02dE%02d', $season_no, $ep_no);
			}
			if ($tag_ok) {
				$track = $tag_title;
			}
			elsif (defined $name_rest) {
				$track = &music_strip_release($name_rest);
			}
			else {
				$track = &music_strip_release($stem);
			}
			# a film has no artist/album split: the folder is the work, so it
			# becomes the artist rather than an album that repeats the title
			if (!length($artist) && length($album) && $album !~ /^Season\s+\d+$/i) {
				$artist = $album;
				$album = '';
			}
			# the film's year sits in the folder; do not repeat it in the track
			if (length($artist) && $artist =~ /\(((?:19|20)\d{2})\)/) {
				my $year = $1;
				$track =~ s/\s*\b\Q$year\E\b\s*$//;
			}
			# a film filed as Movies/Inception/inception-2010.mkv would otherwise
			# read the same words twice; when there is no artist, the album is the
			# only other word worth keeping, so drop it only when it repeats the track
			if (!length($artist) && length($album)) {
				my $album_key = lc $album;
				my $track_key = lc $track;
				$album_key =~ s/[^\p{L}\p{N}]+//g;
				$track_key =~ s/[^\p{L}\p{N}]+//g;
				$album = '' if $album_key eq $track_key;
			}
		}
	}
	else {
		$artist = $tag_artist || $folder_artist;
		$album = $tag_album || $folder_album;
		$track = $tag_title;
		if (!length $track) {
			# no tag: the file name, with its track number and any repeated artist
			my $name = &music_strip_release($stem);
			$name =~ s/^\d{1,3}[\s._-]+//;
			$track = $name;
		}
	}
	# the show's own name is the artist, not part of the track
	if (length $artist) {
		$track =~ s/^\s*\Q$artist\E\s*[-\x{2013}\x{2014}:]\s*//i;
	}
	# a tag repeated through the folder is release noise (GalaxyTV, 2CH, PSA)
	if (%{$noise}) {
		my @word;
		foreach my $word ( split /\s+/, $track ) {
			(my $key = $word) =~ s/[^\p{L}\p{N}]+//g;
			next if length($key) && $noise->{lc $key};
			push @word, $word;
		}
		$track = &music_trim_text(join ' ', @word);
	}
	$track =~ s/^[\s\-\x{2013}\x{2014}:;,.|_]+//;
	$track =~ s/[\s\-\x{2013}\x{2014}:;,.|_]+$//;
	$track = &music_trim_text($track);
	$track = $code if !length($track) && length($code);
	$track = $stem if !length $track;
	return {
		artist => $artist,
		album => $album,
		track => $track,
		code => $code || '',
		meta => join(' ' . chr(0xB7) . ' ', grep { length } ($artist, $album)),
	};
}

sub song_maker($data) {
	my $files = $data->{'files'};
	my $settings = $data->{'settings'};
	my $now_playing = $data->{'now_playing'};
	my $c = $data->{'c'};
	my $misc_settings = $data->{'misc_settings'};
	my $port = $data->{'port'};
	my $config = $data->{'config'};
	my $archive = $data->{'archive'} || {};
	my @local_files;
	my $background_colour = &subs::config_reader()->{'manager'}->{'background_colour'} || &subs::setting_grabber({ app => 'misc', setting => 'manager_background_colour'});
	# the track cards wear the manager's colour; on a dark desk they wear its
	# dark counterpart, so a light manager colour does not glare through the music
	my $dark_background_colour = &subs::dark_colour_for($background_colour);
	my $computer_name = &subs::config_reader()->{'name'} || &subs::setting_grabber({ app => 'me', setting => 'computer_name' });
	my $file_informations = {};
	my ($cache_artists,$cache_albums);
	if ($data->{'settings'}->{'all_albums'} eq 'yes') {
		$cache_albums = &subs::cache_get({ app => 'music', context => 'albums' }) || {};
	}
	if ($data->{'settings'}->{'all_artists'} eq 'yes') {
		$cache_artists = &subs::cache_get({ app => 'music', context => 'artists' }) || {};
	}

	if ($data->{'same_order'} != 1) {
		if ($settings->{'shuffle'} eq 'on') {
			@local_files = shuffle(@{$files});
		}
		else {
			@local_files = sort @{$files};
		}
	}
	else {
		@local_files = @{$files};
	}
	my @lf;
	my $track_number = 0;
	my $max_files = &subs::setting_grabber({ app => 'misc', setting => 'max_files' }) || 30;
	my $tree = &subs::inventory_grabber();
	my $artists = {};
	my $albums = {};
	my $songs = [];
	my $pushed_now_playing = 0;
	my $current_track;
	# covers live in the album folder, so tracks that share one are listed once
	my %thumb_cache;

	# An archived track is not in the local walk's count, and its path lives on
	# another machine ('/mnt/...' sorts after this disk's '/home/...'), so
	# slicing the combined list outright dropped every archive row: a library
	# with more than max_files local tracks never showed what the archive held.
	# Spend the budget on local files and keep every archive row.
	if (%{$archive}) {
		my $local_budget = $max_files - scalar(keys %{$archive});
		$local_budget = 0 if $local_budget < 0;
		my (@kept, $locals);
		$locals = 0;
		foreach my $path ( @local_files ) {
			if ($archive->{$path}) { push @kept, $path; next; }
			next if $locals >= $local_budget;
			push @kept, $path;
			$locals++;
		}
		@local_files = @kept;
	}
	else {
		splice @local_files, $max_files;
	}
	if ($now_playing->{'file'}) {
		my @is = grep { $_ eq $now_playing->{'file'} } @local_files;
		unshift @local_files, $now_playing->{'file'} unless grep { $_ eq $now_playing->{'file'} } @local_files;
	}

	# A tag repeated through one folder is part of the release, not the track
	# (GalaxyTV, SAiNTS, 2CH). Work it out per folder, so one show's group tag
	# is never applied to a track from another show.
	my %noise_by_folder;
	my %files_by_folder;
	foreach my $path ( @local_files ) {
		my ($dir) = $path =~ m{^(.*)/[^/]*$};
		$dir = '' unless defined $dir;
		push @{$files_by_folder{$dir}}, $path;
	}
	foreach my $dir ( keys %files_by_folder ) {
		$noise_by_folder{$dir} = &music_common_noise($files_by_folder{$dir});
	}

	for (my $n = 0; $n <= $max_files; $n++) {
		my $f = $local_files[$n];
		# an archived track is not on this disk: the manifest already said what it
		# is, and its machine is where the player fetches the bytes from
		my $archive_row = $archive->{$f};
		unless ($archive_row || -e $f) {
			next;
		}
		$track_number = $track_number + 1;
		my @t = split '/', $f;
		my @temp_path = @t;
		my $t = $t[-1];
		my $track_number = 0;
		$t =~ s/(\.mp3$|\.m4a$|\.wav$|\.flac$)//gi;
		my $extension = $1;
		my ($info,$type,@thumbs);
		if ($archive_row) {
			$type = ($archive_row->{'type'} eq 'video') ? 'video' : 'audio';
		}
		elsif ($extension) {
			$type = 'audio';
		}
		else {
			$type = 'video';
		}
		my $filename = $f;
		my $full_title = $t;
		$tree->{lc $t} = $t[-3];
		$tree->{lc $t} .= "\n" . $t[-2] if $t[-2];
		$tree->{lc $t} .="\n" . $tree->{lc $t};
		pop @temp_path;
		my $album_folder = join '/', @temp_path;
		if ($type eq 'audio' && !$archive_row) {
			unless (exists $thumb_cache{$album_folder}) {
				$thumb_files = [];
				find(\&process_thumbfile,$album_folder);
				$thumb_cache{$album_folder} = [ @{$thumb_files} ];
			}
			@thumbs = @{ $thumb_cache{$album_folder} };
		}
		my $app;
		if ($filename =~ /\.enc$/gi) {
			$app = $t[-2];
		}
		my $formatted_name = &subs::format_name(join '.', $full_title);

		pop @temp_path;
		my $artist_folder = join '/', @temp_path;

		$f = { 
			filename => $filename,
			type => $type,
			track => $t,
			extension => $extension,
			artist => $t[-3],
			artist_name => $t[-3],
			artist_folder => $artist_folder,
			album => $t[-2],
			album_name => $t[-2],
			app => &subs::unformat_name($t[-2]),
			album_folder => $album_folder,
			thumbs => \@thumbs,
			info => $info,
			song => $t[-1],
			full_title => $full_title,
			formatted_name => $formatted_name,
			track_number => $track_number,
			file_uuid => &subs::random_string_creator(21),
			description => $tree->{lc $t},
			computer_name => $computer_name,
			colour => $background_colour,
			dark_colour => $dark_background_colour
		};

		if ($archive_row) {
			# nothing here to probe: the manifest carried the facts, and the tags
			# keep the shape the rest of this loop and the template expect
			$f->{'info'} = $archive_row->{'info'} || {};
			$f->{'info'}->{'tags'} = {} unless ref $f->{'info'}->{'tags'};
			$f->{'remote_uuid'} = $archive_row->{'remote_uuid'};
			$f->{'archive_host'} = $archive_row->{'remote_hostname'};
		}
		elsif ($filename && $filename !~ /\.enc$/gi) {
			if (!$file_informations->{$artist_folder}) {
				$file_informations->{$artist_folder} = &subs::cache_get({ app => 'music', context => 'file_information', subcontext => $artist_folder }) || {};
			}


			my $file_information = $file_informations->{$artist_folder};
			if ($file_information->{$filename}) {
				$f->{'info'} = $file_information->{$filename};
			}
			else {
				$f = &subs::file_media_information($f, &subs::terminal_name($filename));
				$file_information->{$filename} = $f->{'info'};
			}
			foreach my $i ( qw/artist album track genre title date composer publisher lyrics lyrics-eng/ ) {
				if ($i =~ /lyrics/ && $f->{'info'}->{'tags'}->{$i}) {
					$f->{'lyrics'} = $f->{'info'}->{'tags'}->{$i};
					$f->{'lyrics'} =~ s/\\\n|\\\r/<br>/gi;
				}
				else {
					$f->{$i} = $f->{'info'}->{'tags'}->{$i} if $f->{'info'}->{'tags'}->{$i};
				}
			}
		}
		# the three words every draw shows, settled once here
		my $labels = &music_media_labels($f, $noise_by_folder{$album_folder} || {});
		$f->{'display_artist'} = $labels->{'artist'};
		$f->{'display_album'} = $labels->{'album'};
		$f->{'display_track'} = $labels->{'track'};
		$f->{'display_code'} = $labels->{'code'};
		$f->{'display_meta'} = $labels->{'meta'};
		$f->{'formatted_name'} = $labels->{'track'} if length $labels->{'track'};
		if ($now_playing->{'file'} eq $filename) {
			$current_track = $n;
			$f->{'playing'} = 'yes';
		}
		else {

		}
	#	$artists->{$t[-3]}->{'full_title'} => $t[-3];
		$artists->{$t[-3]}->{'path'} = $artist_folder;
		push @{$artists->{$t[-3]}->{'tracks'}}, $f;
	#	$albums->{$t[-2]}->{'full_title'} => $t[-3];
		$albums->{$t[-2]}->{'path'} = $album_folder;
		push @{$albums->{$t[-3]}->{'tracks'}}, $f;

		push @{$songs}, $f;
		if ($data->{'settings'}->{'all_artists'} eq 'yes') {
			$cache_artists->{lc $f->{'artist'}} = { path => $artist_folder, artist => $f->{'artist'} };
		}
		if ($data->{'settings'}->{'all_albums'} eq 'yes') {
			$cache_albums->{lc $f->{'album'}} = { path => $album_folder, album => $f->{'album'} };
		}
	}
	foreach my $finfo ( keys %{$file_informations} ) {
		&subs::cache_set({ app => 'music', context => 'file_information', subcontext => $finfo, warranty => '-6M' }, $file_informations->{$finfo});
	}
	if ($data->{'settings'}->{'all_artists'} eq 'yes') {
		&subs::cache_set({ app => 'music', context => 'artists' }, $cache_artists);
		$artists = $cache_artists;
	}
	if ($data->{'settings'}->{'all_albums'} eq 'yes') {
		&subs::cache_set({ app => 'music', context => 'albums' }, $cache_albums);
		$albums = $cache_albums;
	}

	my $crate = {
		config => $config,
		remote_uuid => $c->param('remote_uuid'),
		library_name => &music_library_label($settings, $c), 
		current_track => $current_track, 
		artist => $settings->{'artist'}, 
		album => $settings->{'album'}, 
		artists => $artists, 
		albums => $albums, 
		songs => $songs, 
		settings => $settings,
	};
	return $crate;
}

post '/music/search' => sub ($c) {
	my $title = 'music';
	my $search = lc $c->param('search');
	my $unlock = $c->param('unlock');
	my $window_maker = $c->param('window_maker');
	# the window's own unlock token, not the secret in settings: a fresh open
	# has none and lists no sealed track; the refresh after a phone signs does
	my $unlocked = &Manager::media_unlock_open($c, 'music') ? 1 : 0;
	my $content_cache = &subs::jawn_version() . ($unlocked ? '-unlocked' : '-locked');
	# the lit folder buttons from the window, by location name, so the machine
	# that walks the folders looks in the ones the panel shows as on. No param
	# at all means the stored toggles still decide; an empty list means nothing
	# is lit and nothing is walked.
	my $folders = $c->param('folders');
	$folders = defined $folders ? (eval { return decode_json $folders } || []) : undef;
	my $new_settings = eval { return decode_json $c->param('new_settings') } || {};
	my $resizes = $c->param('resizes');
	my $misses = eval { return decode_json $c->param('misses') } || {};
	if (!$misses->{'video'}) {
		$misses->{'video'} = &subs::random_string_creator(25,"Aa");
	}
	foreach my $ns ( keys %{$new_settings} ) {
		&subs::setting_setter({ app => 'music', setting => $ns, value => $new_settings->{$ns} });
	}


	my $port = $c->req->url->base->port;
	my $list = eval { return decode_json $c->param('list') } || [];
	my $now_playing = eval { return decode_json $c->param('now_playing') } || {};
	my $same_order = $c->param('same_order');
	&subs::cache_delete({ app => 'music', context => 'content' });
	my $artist = $c->param('artist');
	my $album = $c->param('album');
	my $misc_settings = &Manager::misc_setting_list();
	$permissive = $unlocked;

	
	&subs::setting_setter({ app => 'music', setting => 'resizes', value => $resizes });
	&subs::setting_setter({ app => 'music', setting => 'album', value => $album });
	&subs::setting_setter({ app => 'music', setting => 'artist', value => $artist });
	&subs::setting_setter({ app => 'music', setting => 'search', value => $search });
	# the library choice rides in with the search: written as its own request it
	# raced the search, and whenever the search won it relayed to the old
	# machine again, which looked like being stuck on a remote library. It is a
	# local-machine choice, so it is not forwarded as new_settings.
	if (my $library = $c->param('library')) {
		&subs::setting_setter({ app => 'music', setting => 'library', value => $library });
	}
	my $settings = &subs::settings_grabber({ app => 'music' });

	if ($settings->{'library'} ne 'local' && $c->param('remoted') ne 'yes') {
		$c->param('resizes' => undef);
		my $rm = &subs::db_query('select * from remote_machines where uuid=? and connection=?', $settings->{'library'}, 'active')->hashes->[0];
		if ($rm->{'uuid'}) {
			$c->param('remote_uuid' => $rm->{'uuid'});
			$c->param('library_name' => &music_remote_label($rm));
			$c->param('subprocess' => 'yes');
			my $result = &Manager::remote_relay_request($c);
			if ($result =~ /music/gi) {
				# the relay hands the remote's reply back as a plain string; the
				# browser's search handler expects JSON, so put the content type
				# back or the response arrives as text and the list never reloads
				my $reply = eval { return decode_json $result };
				if ($reply && ref $reply eq 'HASH') {
					$c->render(json => $reply);
				}
				else {
					$c->render(text => $result);
				}
				return;
			}
		}
		else { &subs::setting_setter({ app => 'music', setting => 'library', value => 'local' }); $settings->{'library'} = 'local'; }
	}

	$settings->{'artist'} = eval { return decode_json $settings->{'artist'} } || [];
	$settings->{'album'} = eval { return decode_json $settings->{'album'} } || [];
	my $crate;
	if (scalar @{$list} > 0) {
		$crate = &song_maker({ c => $c, config => $config, port => $port, files => $list, settings => $settings, now_playing => $now_playing, same_order => $same_order, misc_settings => $misc_settings });
	}
	else {
		$crate = &music_search({ c => $c, search => $search, now_playing => $now_playing, settings => $settings, port => $port, misc_settings => $misc_settings, folders => $folders, permissive => $unlocked });
	}
	$crate->{'unlock'} = $unlocked ? $unlock : '';
	$crate->{'unlocked'} = $unlocked;
	
	my @interface_color= qw/yellow green blue orange black fuschia pink navy purple brown/;
	my $random_number = rand(0..8);
	my $timestamp = &subs::rightNow();
	my $jmao = &subs::setting_grabber({ app => 'music', setting => 'mao' });
	$artist = eval { return decode_json $artist } || [];
	$album = eval { return decode_json $album } || [];
	$resizes = eval { return decode_json $resizes } || {};
	my $contents;
	if ($c->param('window_maker')) {
		$contents = $c->render_to_string(
			crate => $crate,
			interface_colour => $interface_color[$random_number],
			template => 'apps/music/music',
			window_maker => 'yes',
			folders => $misc_settings,
			device => &subs::device_setter(),
			mao => eval { return decode_json $jmao } || {},
			jmao => $jmao,
			search => $search,
			resizes => $resizes,
			misses => $misses
		);
		my $website = &Manager::window_maker({ app => 'music', title => $title, contents => $contents }, $timestamp);
		$c->render(json => { artist => $artist, album => $album, search => $search, html => $website });
	}
	else {
		$contents = $c->render_to_string(
			template => 'apps/music/files',
			crate => $crate,
			search => $search,
			# the phone's own list (see apps/music/music.html.ep): this bare
			# fragment draws whatever the window would have
			phone => (($device // '') eq 'mobile') ? 1 : 0,
		);
		$c->render(text => $contents);
	}
	&subs::cache_set({ app => 'music', context => 'content', subcontext => $content_cache }, { contents => $contents });
};

post '/music/folder_toggle' => sub($c) {
	my $timestamp = $c->param('timestamp');
	my $location = $c->param('location');
	my $status = $c->param('status');
	&subs::setting_setter({ app => 'music_folder_toggle', setting => $location, value => $status, timestamp => $timestamp });
	# the toggle flips the local button and also steers the scanning of the
	# machine whose library is loaded, so a remote library gets the same click
	my $settings = &subs::settings_grabber({ app => 'music' });
	if ($settings->{'library'} ne 'local' && $c->param('remoted') ne 'yes') {
		my $rm = &subs::db_query('select * from remote_machines where uuid=? and connection=?', $settings->{'library'}, 'active')->hashes->[0];
		if ($rm->{'uuid'}) {
			$c->param('remote_uuid' => $rm->{'uuid'});
			$c->param('subprocess' => 'yes');
			my $result = &Manager::remote_relay_request($c);
			if ($result && $result =~ /^\s*(on|off)\s*$/) {
				$c->render(text => $result);
				return;
			}
		}
	}
	my $setting = &subs::setting_grabber({ app => 'music_folder_toggle', setting => $location, device => $device });
	$c->render(text => $setting);
};

# Whether a listing also carries what the archives hold. Like the folder
# toggles, it steers the machine whose library is loaded, so a remote library
# gets the same choice.
post '/music/archive_toggle' => sub($c) {
	my $status = $c->param('status');
	&subs::setting_setter({ app => 'music', setting => 'archive', value => $status, timestamp => $c->param('timestamp') });
	my $settings = &subs::settings_grabber({ app => 'music' });
	if ($settings->{'library'} ne 'local' && $c->param('remoted') ne 'yes') {
		my $rm = &subs::db_query('select * from remote_machines where uuid=? and connection=?', $settings->{'library'}, 'active')->hashes->[0];
		if ($rm->{'uuid'}) {
			$c->param('remote_uuid' => $rm->{'uuid'});
			$c->param('subprocess' => 'yes');
			my $result = &Manager::remote_relay_request($c);
			if ($result && $result =~ /^\s*(on|off)\s*$/) {
				$c->render(text => $result);
				return;
			}
		}
	}
	$c->render(text => &subs::setting_grabber({ app => 'music', setting => 'archive' }));
};

post '/music/audio_output_select' => sub ($c) {
	my $output = $c->param('output');
	my $state = $c->param('state') // 'off';
	$state = 'off' unless $state =~ /^(?:off|on|stereo|left|right)$/;
	my $mao = eval { return decode_json &subs::setting_grabber({ app => 'music', setting => 'mao' }) } || {};
	$mao->{$output} = $state;
	my $jmao = encode_json $mao;
	&subs::setting_setter({ app => 'music', setting => 'mao', value => $jmao });
	$c->render(json => $mao);
};

# The Audio drawer belongs to this machine even when the library is remote: it
# is rendered from this machine's settings and output list, so a remote render of
# the Music window (which would carry the remote's mao) never supplies it.
get '/music/video/outputs' => sub ($c) {
	unless ($c->session('authentication') eq 'approved') { $c->rendered(403); return; }
	my $video = eval { return decode_json(&subs::setting_grabber({ app => 'music', setting => 'video' }) // '') } || {};
	$c->render(json => { machines => &music_video_machines(), settings => $video, me => &music_video_local_enabled() });
};

get '/music/audio' => sub ($c) {
	my $settings = &subs::settings_grabber({ app => 'music' });
	my $jmao = $settings->{'mao'};
	my $mao = eval { return decode_json $jmao } || {};
	my $eq = eval { return decode_json($settings->{'equalizer'} // '') } || {};
	my $video = eval { return decode_json($settings->{'video'} // '') } || {};
	my $mvo = eval { return decode_json($settings->{'mvo'} // '') } || {};
	my $html = $c->render_to_string(
		template => 'apps/music/audio',
		folders => &Manager::misc_setting_list(),
		device => &subs::device_setter(),
		mao => $mao,
		jmao => $jmao,
		settings => $settings,
		video_machines => &music_video_machines(),
		mvo => $mvo,
		crate => { settings => $settings }
	);
	$c->render(json => { html => $html, equalizer => $eq, video => $video, mvo => $mvo, mao => $mao, video_machines => &music_video_machines(), video_me => &music_video_local_enabled() });
};

get '/music/configuration' => sub ($c) {
	my $returner = {};
	my $settings = &subs::settings_grabber({ app => 'music' });
	my $jmao = $settings->{'mao'};
	# the panel belongs to this machine even when the library does not: it is
	# rendered from the local settings, and the loaded remote is shown by name
	# rather than as a bare uuid
	my $remote_uuid = $c->param('remote_uuid');
	my $remote_hostname;
	if ($remote_uuid) {
		my $rm = &subs::db_query('select * from remote_machines where uuid=?', $remote_uuid)->hashes->[0];
		$remote_hostname = $rm->{'hostname'} if $rm;
	}
	$returner->{'html'} = $c->render_to_string(
		template => 'apps/music/configuration',
		folders => &Manager::misc_setting_list(),
		device => &subs::device_setter(),
		mao => eval { return decode_json $jmao } || {},
		jmao => $jmao,
		settings => $settings,
		crate => { remote_uuid => $remote_uuid, remote_hostname => $remote_hostname, settings => $settings }
	);
	$c->render(json => $returner);
};

1;
