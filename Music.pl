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

# An album's own visibility decides whether its sealed tracks need the padlock.
# The album is the folder above the file, the same part the walk names as `app`.
my %app_visible_cache;
sub music_app_visible($name) {
	my @part = split '/', $name;
	return 1 unless scalar @part >= 2;
	my $app = &subs::unformat_name($part[-2]);
	return 1 unless defined $app && length $app;
	unless (exists $app_visible_cache{$app}) {
		$app_visible_cache{$app} = &Manager::help_app_hidden($app) ? 0 : 1;
	}
	return $app_visible_cache{$app};
}

sub process_file($name) {
	return unless playable_name($name)
		|| (($permissive == 1 || music_app_visible($name)) && playable_enc_name($name));
	# A directory walk hands names back as UTF-8 bytes, but the music window is a
	# character string: an undecoded name gets upgraded as Latin-1 and served
	# double-encoded (Æ -> Ã), which the player then cannot open. Decode only the
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

	&Manager::rock_and_roll($c);

	# the lip-sync clone re-requests /play for the same file; it must not start
	# the server-side player a second time
	if ($mao->{'srv'} eq 'on' && $c->param('clone') ne '1') {
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
sub music_wake_lock($delta) {
	return unless $device eq 'mobile';
	my $path = &music_stream_wake_path();
	my $count = (-e $path ? (read_file($path) + 0) : 0);
	my $was = $count;
	$count += $delta;
	$count = 0 if $count < 0;
	write_file($path, $count);
	my $cmd = $count > 0 ? 'termux-wake-lock' : 'termux-wake-unlock';
	if (($was == 0 && $count > 0) || ($was > 0 && $count == 0)) {
		my $found = `command -v $cmd 2>/dev/null`;
		chomp $found;
		`$cmd >/dev/null 2>&1` if $found;
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

sub music_pacat_command($rate) {
	my $pacat = `command -v pacat 2>/dev/null`;
	chomp $pacat;
	$pacat = 'pacat' unless $pacat;
	return ($pacat,
		'--playback', '--raw', '--format=s16le',
		'--rate=' . &music_stream_rate($rate),
		'--channels=2',
		'--latency-msec=60',
		# PulseAudio's stream-restore remembers a stream name's old level, so a
		# receiver that was once turned down (or muted) came back silent while
		# the Music app looked like it was playing. pacat names the level it
		# wants at creation; the sender's own volume arrives in the samples.
		'--volume=65536',
		'--client-name=jawnos-music',
		'--stream-name=jawnos-music');
}

# --- the receiving side ------------------------------------------------------
sub music_remote_audio_stop($st, $keep_state) {
	# a report timer would otherwise outlive the stream it describes
	&music_rx_report_stop($st);
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
			. ' | pacat --playback --raw --format=s16le --rate=44100 --channels=2 --latency-msec=60'
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
			. ' --channels=2 --latency-msec=60 --volume=65536 --client-name=jawnos-music --stream-name=jawnos-music';
		@cmd = ('sh', '-c', $pipeline);
	}
	else { @cmd = &music_pacat_command($st->{'rate'}); }
	my $pid = open(my $fh, '|-', @cmd);
	unless ($pid) {
		$st->{'error'} = 'pacat';
		return 0;
	}
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
	my $cap = (($st->{'codec'} || 'pcm') eq 'opus') ? 4_000_000 : 65_536;
	# The gap between writes is the receiver's own measure of a starving stream:
	# pacat's 60 ms buffer cannot hide a mesh stall longer than that.
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
	$st->{'rx_writes'} = ($st->{'rx_writes'} || 0) + 1;
	$st->{'stream'}->write($bytes);
}

# The receiving machine's half of the trace. The source reports what it sent;
# this reports what actually arrived, so a gap can be attributed to the network,
# to pacat, or to the source having dropped the frame itself.
sub music_rx_report_send($st) {
	return unless $st->{'tx'} && $st->{'tx'}->is_websocket;
	my $now = &subs::rightNow();
	# pactl is not free; refresh the sink number now and then
	if (!$st->{'sink_at'} || $now - $st->{'sink_at'} > 10_000) {
		$st->{'sink_at'} = $now;
		my $ms = &music_receiver_sink_latency();
		$st->{'sink_ms'} = $ms if $ms > 0;
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
		starts => ($st->{'starts'} || 0),
	};
	eval { $st->{'tx'}->send({ text => encode_json($d) }); };
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
		# the Web Audio stream is the one this machine hears; its node latency
		# is the graph's own output buffer, which the picture has to wait for
		if (lc($p->{'media.role'} || '') eq 'webaudio') {
			my $nl = $p->{'node.latency'} || '';
			if ($nl =~ m{^(\d+)/(\d+)$} && $2 > 0) {
				my $sec = $1 / $2;
				$latency = $sec if $sec > $latency;
			}
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
	my %machine_for;
	foreach my $rm ( @{$machines} ) {
		$machine_for{$rm->{'signatorial'}} = $rm if $rm->{'signatorial'};
		$machine_for{$rm->{'uuid'}} = $rm if $rm->{'uuid'};
	}
	my @lookups;
	foreach my $pick ( @{$picked} ) {
		if ($pick->{'location'}) {
			my $archive = $misc->{$device}->{$pick->{'location'} . '_archive'};
			next unless $archive;
			my $rm = $machine_for{$archive};
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
			$manifest = &subs::archive_manifest_fetch({ remote_uuid => $lookup->{'remote_uuid'}, location => $lookup->{'location'} });
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
	if ($data->{'settings'}-{'all_albums'} eq 'yes') {
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

	splice @local_files, $max_files;
	if ($now_playing->{'file'}) {
		my @is = grep { $_ eq $now_playing->{'file'} } @local_files;
		unshift @local_files, $now_playing->{'file'} unless grep { $_ eq $now_playing->{'file'} } @local_files;
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
			artist_folder => $artist_folder,
			album => $t[-2],
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
get '/music/audio' => sub ($c) {
	my $settings = &subs::settings_grabber({ app => 'music' });
	my $jmao = $settings->{'mao'};
	my $mao = eval { return decode_json $jmao } || {};
	my $eq = eval { return decode_json($settings->{'equalizer'} // '') } || {};
	my $html = $c->render_to_string(
		template => 'apps/music/audio',
		folders => &Manager::misc_setting_list(),
		device => &subs::device_setter(),
		mao => $mao,
		jmao => $jmao,
		settings => $settings,
		crate => { settings => $settings }
	);
	$c->render(json => { html => $html, equalizer => $eq, mao => $mao });
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
