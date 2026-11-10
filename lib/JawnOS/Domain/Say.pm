package subs;

# Say: extracted from subroutines.pl (package subs). Loaded on
# demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Clone qw(clone);
use Data::Dumper;
use Date::Parse;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use Fcntl qw(:flock);
use File::Copy;
use File::Find;
use File::Path;
use File::Slurp;
use JawnOS::Platform ();
use IO::Select;
use IPC::Open2;
use JSON::PP ();
use List::Util qw(shuffle);
use MIME::Base64;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

our $config;
our $database;
our $device;
our $device_bridge_memo;
our $device_bridge_seq;
our $device_bridge_sock;
our $gb;
our $log;
our %m;
our $say_quiet;

sub say_voice_spec {
	my $pick = shift;
	foreach my $v ( &subs::say_voices() ) {
		return $v if $v->{'value'} eq $pick;
	}
	return undef;
}

# Where the piper binary is on this device. It is arch-specific, so the voice
# sync never carries it - only the models (which are arch-independent). The
# dependency step's copy wins, then a piper on PATH; the repo's own bundle is the
# desktop last resort (on the phone it is the wrong architecture).
sub say_piper_binary {
	# installed by the dependency step (scripts/jawnos_deps.pl --extras); a glibc
	# build, which on Android is run through glibc-runner (see say_piper_argv)
	my $installed = &subs::home('~/.local/share/jawnos/piper/piper');
	return $installed if -x $installed;
	# a piper on PATH (a distribution package, or a Termux install)
	my $onpath = JawnOS::Platform::tool_path('piper');
	return $onpath if $onpath;
	# the copy staged in the repo's blob store (fine on a desktop)
	return '' if $device eq 'mobile';
	my $bundled = &subs::home('~/jawnos/voices/piper/piper');
	return $bundled if -x $bundled;
	return '';
}

# The command that runs piper here, engine only (say_it appends the model and
# output args). A glibc-built bundle needs the glibc launcher on Android; a
# Termux build runs directly.
sub say_piper_argv {
	my $piper = &subs::say_piper_binary();
	return () unless $piper;
	if ($device eq 'mobile' && $piper eq &subs::home('~/.local/share/jawnos/piper/piper')) {
		my $runner = JawnOS::Platform::tool_path('glibc-runner');
		return ($runner, $piper) if $runner;
	}
	return ($piper);
}

# How to play a finished wav here. Android has no sox audio backend; the app
# plays the clip through the bridge instead, so there is no shell player on a
# handheld and the caller passes an empty command.
sub say_player_command {
	return '' if $device eq 'mobile';
	return 'play -q';
}

# The piper invocation shared by the local player and the streaming reply:
# (argv, extra args, model path, the model's own sample rate). '' when no piper
# render is possible on this machine.
sub say_piper_parts {
	my ($pick_hint) = @_;
	my $pick = $pick_hint || &subs::misc_setting('say_voice') || &subs::say_default_voice();
	my $spec = &subs::say_voice_spec($pick) || &subs::say_voice_spec(&subs::say_default_voice());
	return () unless $spec && (($spec->{'engine'} || '') eq 'piper');
	my @argv = &subs::say_piper_argv();
	my $model = &subs::home('~/jawnos/voices') . '/' . $spec->{'model'} . '.onnx';
	return () unless scalar @argv && -e $model;
	# a bundle carries its own espeak-ng data; point piper at it (the glibc
	# launcher, unlike a native run, does not find it on its own)
	my $piper_bin = $argv[-1] || '';
	(my $piper_dir = $piper_bin) =~ s{/[^/]+$}{};
	my @espeak = ($piper_dir && -d "$piper_dir/espeak-ng-data") ? ('--espeak_data', "$piper_dir/espeak-ng-data") : ();
	# the model's own rate: piper writes raw PCM at it, and ffmpeg needs to know
	my $rate = 22050;
	if (open(my $jf, '<', $model . '.json')) {
		local $/;
		my $cfg = eval { decode_json(<$jf> // '') };
		close $jf;
		$rate = $cfg->{'audio'}->{'sample_rate'} if $cfg && $cfg->{'audio'}->{'sample_rate'};
	}
	return (\@argv, \@espeak, $model, $rate);
}

# Shell-quote one command of a pipeline ("arg with space" -> 'arg with space'),
# so the paths the voice settings name survive the sh -c that runs piper | ffmpeg.
sub pipeline_quote {
	return join ' ', map {
		my $a = defined $_ ? $_ : '';
		$a =~ s/'/'\\''/g;
		"'" . $a . "'";
	} @_;
}

# Piper render to a file (the local player's path). Returns the path of a fresh
# WAV, or '' when no piper render is possible. The caller owns (and unlinks) it.
sub say_render_wav {
	my ($text, $pick_hint) = @_;
	return '' unless defined $text && length $text;
	my ($argv, $espeak, $model) = &subs::say_piper_parts($pick_hint);
	return '' unless $argv && $model;
	my $tmp_dir = $gb::tmp_dir || '/tmp';
	my $wav = $tmp_dir . '/jawn_say_' . &subs::random_string_creator(10) . '.wav';
	my $made = 0;
	# the words go to piper on stdin, so nothing has to be quoted for a shell.
	# no -q: the flag exists in the 1.2.0 build but not in the newer CLI, and
	# an unknown flag is a hard argparse error there.
	if (my $pid = open(my $piper_in, '|-', @{$argv}, @{$espeak}, '-m', $model, '-f', $wav)) {
		print {$piper_in} $text;
		close $piper_in;
		$made = 1 if -s $wav;
	}
	unlink $wav if -e $wav && !$made;
	return $made ? $wav : '';
}

# The speaking, with no event loop of its own to reset. say_it runs it in a
# child - a fork on Unix, perl/subprocessor_worker.pl on a box without fork -
# because a request may speak and still have to answer (Leave says goodbye).
# Run inline it would reset the request worker's event loop, and the reply in
# flight would never leave.
sub say_speak {
	my ($text, $voice_override) = @_;
	return unless defined $text && length $text;
	my $pick = $voice_override || &subs::misc_setting('say_voice') || &subs::say_default_voice();
	my $spec = &subs::say_voice_spec($pick) || &subs::say_voice_spec(&subs::say_default_voice());
	# Piper first, on every device, so the voice is uniform wherever it can
	# run: the models are shared (voice_sync), only the binary is per-device.
	if (($spec->{'engine'} || '') eq 'piper') {
		my $wav = &subs::say_render_wav($text, $pick);
		if ($wav) {
			my $player = &subs::say_player_command();
			# the app plays it natively on a phone; only a desktop has a
			# shell player to fall back to
			my $played = $device eq 'mobile'
				? &subs::device_call('media.player', { action => 'play', path => $wav })
				: 0;
			# a headless server has no sink; a failed play is not our problem
			`$player "$wav" 2>/dev/null` if !$played && length $player;
			unlink $wav;
			return;
		}
	}
	# Fallbacks: Android's own engine where piper cannot run; espeak elsewhere.
	if ($device eq 'mobile') {
		&subs::device_call('speech.speak', { text => $text });
		return;
	}
	# espeak: the chosen espeak voice, or the fallback when piper is missing.
	# It is a Unix tool; a box without it has no speech, and probing for it
	# through the shell printed Windows' "path not found" on every backfill
	# note. system(LIST) also keeps the words out of the shell.
	my $voice = $spec->{'voice'} || 'en-us';
	my $espeak = JawnOS::Platform::tool_path('espeak');
	system($espeak, '-a70', '-v', $voice, $text) if $espeak;
	return;
}

sub say_it {
	my $text = shift;
	my $voice_override = shift;
	return unless defined $text && length $text;
	# the error watch's propose runs are headless: a stand-down notice must not
	# speak (or block on audio) inside a background fork
	return if $say_quiet;
	# A request may call this (Leave says goodbye): an inline run resets the
	# request worker's event loop and the reply never leaves. Always a child -
	# the name is in %JOB, so a box without fork starts the worker by name and
	# takes the words from args.
	&subs::subprocessor(sub {
		Mojo::IOLoop->reset;
		&subs::say_speak($text, $voice_override);
	}, { name => 'say it', fork => 1, args => { text => $text, voice => $voice_override } });
}

# Is the device on WiFi and reachable? Its own web server on the board port is the
# test: an off-LAN or powered-down device fails the connect at once, which is
# what lets the reply go to Bluetooth without waiting for a timeout. Returns
# the address the reply route is served from, or undef.
sub device_wifi_reply {
	my ($meta) = @_;
	return undef unless $meta && $meta->{'chip_id'};
	my $edt = $meta->{'edt'} || 'watch';
	my $dev = &subs::device_lister(&subs::rightNow(), $edt, undef, $meta->{'chip_id'});
	my $dev_ip = $dev->{'ip'};
	return undef unless $dev_ip && $dev_ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
	require IO::Socket::INET;
	my $sock = IO::Socket::INET->new(PeerAddr => $dev_ip, PeerPort => ($ENV{PORT_BOARD} || 3000), Proto => 'tcp', Timeout => 0.7);
	return undef unless $sock;
	close $sock;
	# the server's own address on the device's subnet: a fallback machine may
	# differ from the homebase the device still has stored
	my $addrs = &subs::network_interface_reporter();
	my $net = $dev_ip;
	$net =~ s/\.\d+$//;
	my $server_ip;
	foreach my $nic ( keys %{$addrs} ) {
		my $ip = $addrs->{$nic}->{'ip'};
		next unless $ip;
		my $n = $ip;
		$n =~ s/\.\d+$//;
		if ($n eq $net) { $server_ip = $ip; last; }
	}
	if (!$server_ip && %{$addrs}) {
		my ($first) = values %{$addrs};
		$server_ip = $first->{'ip'};
	}
	return undef unless $server_ip;
	my $od = eval { decode_json(&subs::embedded_operator_door($edt, $meta->{'chip_id'})) } || {};
	my $auth = $od->{'__specs'}->{'authorization'};
	return undef unless $auth;
	return {
		ip => $dev_ip,
		edt => $edt,
		auth => $auth,
		base => 'https://' . $server_ip . ':' . ($ENV{'PORT_ARM'} || ''),
	};
}

# Render the answer once as a WAV, so a WiFi device can fetch it in one
# streamed GET instead of receiving hundreds of BLE notifications. Returns the
# id (the file is ~/.president/reply_<id>.wav) or undef when piper/ffmpeg
# cannot produce one; the caller then keeps the BLE stream.
sub device_reply_wav {
	my ($text) = @_;
	my ($argv, $espeak, $model, $rate) = &subs::say_piper_parts();
	return undef unless $argv && $model;
	require IPC::Open3;
	require Symbol;
	my $dir = &subs::home('~/.president');
	foreach my $old ( glob("$dir/reply_*.wav") ) {
		unlink $old if $old && time - (stat($old))[9] > 600;
	}
	my $id = &subs::random_string_creator(32);
	$id =~ s/[^A-Za-z0-9]//g;
	$id = substr($id, 0, 24);
	return undef unless length $id >= 16;
	my $path = "$dir/reply_$id.wav";
	my @piper = (@{$argv}, @{$espeak}, '--output_raw', '-m', $model);
	my $pipeline = join(' | ', &subs::pipeline_quote(@piper),
		"ffmpeg -nostdin -loglevel error -f s16le -ar $rate -ac 1 -i - -ar 8000 -ac 1 -f wav -");
	my $err = Symbol::gensym();
	my ($pin, $pout);
	my $pid = eval { IPC::Open3::open3($pin, $pout, $err, 'sh', '-c', $pipeline) };
	return undef unless $pid;
	print {$pin} $text;
	close $pin;
	binmode($pout);
	open(my $out, '>', $path) or return undef;
	binmode($out);
	my $bytes = 0;
	while (1) {
		my $buf = '';
		my $n = read($pout, $buf, 8192);
		last unless defined $n && $n > 0;
		print {$out} $buf;
		$bytes += $n;
	}
	close $pout;
	waitpid($pid, 0);
	close $out;
	if ($bytes < 100) {
		unlink $path;
		return undef;
	}
	return $id;
}

# A spoken answer to a voice command that came from the watch: push the reply
# text (the watch shows it on screen) and the spoken answer (a short piper clip
# the watch plays) over the bridge, so the answer lands on the wrist. No local
# say_it: the machine holding the bridge would double-talk with the watch.
sub watch_reply {
	my ($meta, $text) = @_;
	return unless $meta && $meta->{'chip_id'} && defined $text && length $text;
	my $edt = $meta->{'edt'} || 'watch';
	# The words go first and must keep their place ahead of the audio below, so
	# this send is async only when we are on the loop (see bluetooth_sender_async:
	# inside a fork it runs inline).
	&subs::bluetooth_sender_async({
		intent => 'com.jawn.president.bt.connect',
		chip_id => $meta->{'chip_id'},
		edt => $edt,
		message => { type => 'say', data => { text => $text } }
	});
	# The spoken half is optional: the Embedded panel's Audio replies toggle, on
	# by default, writes audio_replies into the device's operator_door specs.
	my $op = eval { decode_json &subs::embedded_operator_door($edt, $meta->{'chip_id'}) } || {};
	my $want = $op->{'__specs'}->{'audio_replies'};
	return if defined $want && $want eq 'off';
	# A device on WiFi pulls one WAV instead of receiving hundreds of BLE parts;
	# an off-WiFi device gets the BLE stream immediately. The text above is the
	# small, immediate half either way.
	my $wifi = &subs::device_wifi_reply($meta);
	if ($wifi) {
		&subs::subprocessor(sub {
			Mojo::IOLoop->reset;
			my $id = &subs::device_reply_wav($text);
			if ($id) {
				&subs::bluetooth_sender({
					intent => 'com.jawn.president.bt.connect',
					chip_id => $meta->{'chip_id'},
					edt => $edt,
					message => { type => 'say_audio_ready', data => { id => $id, base => $wifi->{'base'} } }
				});
			}
			else {
				# piper/ffmpeg failed: the BLE stream still gets the sound there
				&subs::watch_reply_stream($meta, $text);
			}
		}, { name => 'watch reply wifi', fork => 1 });
		return;
	}
	# Piper synthesizes far faster than the answer is spoken, and the WiFi path
	# runs voice_ingest inline in the request: do all of this off the request. The
	# child re-dials the database itself (bluetooth_sender reads it), so forking
	# here is safe.
	&subs::subprocessor(sub {
		Mojo::IOLoop->reset;
		&subs::watch_reply_stream($meta, $text);
	}, { name => 'watch reply audio', fork => 1 });
}

# Stream the spoken answer to the watch as PCM parts. Piper writes raw samples as
# it makes them; ffmpeg resamples them to 8 kHz mono (16 KB/s, which the BLE link
# carries comfortably) as it goes, so parts leave while the sentence is still
# being synthesized - the watch starts talking back almost at once instead of
# after the whole clip has been rendered and pushed. Each part is its own bridge
# message (all over one connection, see bluetooth_stream_open), so a long answer
# is no longer capped by the 64 KB message limit.
sub watch_reply_stream {
	my ($meta, $text) = @_;
	my ($argv, $espeak, $model, $rate) = &subs::say_piper_parts();
	return 0 unless $argv && $model;
	require MIME::Base64;
	require IPC::Open3;
	require Symbol;
	# the words go first as their own message; the sound rides this one connection
	my $bt = &subs::bluetooth_stream_open({
		intent => 'com.jawn.president.bt.connect',
		chip_id => $meta->{'chip_id'},
		edt => $meta->{'edt'} || 'watch'
	});
	# A bridge that can carry the words does not always expose the streaming
	# client (the Android bridge falls back to a broadcast send and has no
	# jawn-bt script). Do not throw the sound away there: send the same parts
	# through bluetooth_sender, one message at a time, which is the path the
	# text already takes. Slower, but the deck buffers to the last part anyway.
	unless ($bt) {
		$log->info('voice: no stream client; sending reply audio part by part');
	}
	my $send = sub {
		my ($data) = @_;
		if ($bt) {
			{
				local $SIG{'PIPE'} = 'IGNORE';
				print {$bt} encode_json($data) . "\n";
			}
		}
		else {
			&subs::bluetooth_sender({
				intent => 'com.jawn.president.bt.connect',
				chip_id => $meta->{'chip_id'},
				edt => $meta->{'edt'} || 'watch',
				message => $data
			});
		}
	};
	my @piper = (@{$argv}, @{$espeak}, '--output_raw', '-m', $model);
	# How much audio there will be, near enough: ~14 characters a second of
	# speech, 8 kHz mono s16 is 16000 bytes a second. The watch uses it to decide
	# how much to hold back before speaking (half of it, clamped), so playback
	# starts with a cushion against the link's jitter without a short answer
	# waiting for a cushion longer than itself.
	my $est_total = int((length($text) / 14) * 16000);
	# Resample to 8 kHz when ffmpeg is here (the whisper path uses it, so it is on
	# every machine that can already hear). Otherwise piper's own rate rides along
	# in the messages and the watch opens the codec at it.
	my $pipeline = join(' | ', &subs::pipeline_quote(@piper),
		"ffmpeg -nostdin -loglevel error -f s16le -ar $rate -ac 1 -i - -ar 8000 -ac 1 -f s16le -");
	my $done = 0;
	for my $attempt ( [ $pipeline, 8000 ], [ &subs::pipeline_quote(@piper), $rate ] ) {
		my ($pipe, $out_rate) = @{$attempt};
		my $err = Symbol::gensym();
		my ($pin, $pout);
		my $pid = eval { IPC::Open3::open3($pin, $pout, $err, 'sh', '-c', $pipe) };
		next unless $pid;
		print {$pin} $text;
		close $pin;
		binmode($pout);
		my ($seq, $sent) = (0, 0);
		while (1) {
			my $chunk = '';
			# 4 KB of PCM per part: the base64 JSON is then ~5.5 KB, which the
			# deck's ~15 KB internal heap can reassemble (16 KB raw parts made a
			# ~22 KB line and were silently dropped by the BLE reassembler).
			my $n = read($pout, $chunk, 4096);
			last unless defined $n && $n > 0;
			my $b64 = MIME::Base64::encode_base64($chunk, '');
			$send->({ type => 'say_audio', data => { seq => $seq, last => 0, rate => $out_rate, total => $est_total, audio => $b64 } });
			$seq++;
			$sent += $n;
		}
		close $pout;
		waitpid($pid, 0);
		if ($sent) {
			$send->({ type => 'say_audio', data => { seq => $seq, last => 1, rate => $out_rate, total => $est_total, audio => '' } });
			$done = 1;
			last;
		}
		# nothing came out (ffmpeg missing, say): try piper alone at its own rate
	}
	close $bt if $bt;
	$log->info('voice: no reply audio rendered for the watch (text only)') unless $done;
	return $done;
}

# Does this path hold a picture, not just a directory entry? A synced stub can be
# a single placeholder byte, which /file_open answers with nothing; an icon must
# not take it while the real picture is still on another machine. A sealed photo
# names itself the way Note reads it back ("Salted__", an 8-byte salt, then the
# ciphertext); an open file must answer with an image magic.
sub main_image_real_file {
	my $file = shift;
	return 0 unless defined $file && length $file && -f $file;
	my $size = -s $file || 0;
	open my $fh, '<', $file or return 0;
	binmode $fh;
	my $head = '';
	read($fh, $head, 64);
	close $fh;
	return (substr($head, 0, 8) eq 'Salted__' && $size > 16) ? 1 : 0 if $file =~ /\.enc\z/i;
	my $type = &subs::plaintext_verdict($head);
	return (defined $type && $type =~ m{\Aimage/}) ? 1 : 0;
}

# The picture an app's `main_image` setting names, as an <img> can draw it. The
# row is written per device, and a synced row can name the file on the machine
# that wrote it; a path this machine can open is used as it stands, and a foreign
# one is mapped through this device's photo folder (file_device_renamer) the way
# the gallery maps a row another machine wrote. A snapshot main image is a data
# URI that carries its own bytes. Returns '' when nothing here can be shown.
sub main_image_src {
	my ($value, $app, $thumb, $require_real) = @_;
	return '' unless defined $value && length $value;
	return $value if $value =~ /\Adata:image\//i;
	my $file = -e $value ? $value : '';
	if (!length $file) {
		my ($destination, $asset) = &subs::file_device_renamer({ file => $value, app => $app, type => 'image' });
		my $local = (defined $destination && defined $asset) ? $destination . $asset : '';
		$file = $local if length $local && -e $local;
	}
	return '' unless length $file;
	return '' if $require_real && !&main_image_real_file($file);
	my $src = '/file_open?file=' . &subs::url_escape_utf8($file)
		. ((defined $app && length $app) ? '&app=' . &subs::url_escape_utf8($app) : '');
	# An icon is drawn at a few dozen pixels: the cached thumbnail is the right
	# picture, and it is also the one /file_open can draw when the original is
	# sealed or not on this machine.
	$src .= '&thumb=ya' if $thumb;
	return $src;
}

# The picture an app's icon shows: the person's own main image when there is
# one, else the active icon set's version of the app's known picture, else the
# placeholder for its pos. main_icon_maker renders this in HTML; the native
# home asks /apps/icon for the same answer as a PNG it can draw. Returns ''
# when the app has no icon at all.
sub main_icon_source {
	my $data = shift;
	my $unformatted_name = $data->{'app'};
	my $settings = $data->{'settings'};
	$settings = &subs::settings_grabber({ app => $unformatted_name }) unless $settings;
	if ($settings->{'main_image'}) {
		my $src = &subs::main_image_src($settings->{'main_image'}, $unformatted_name, 1, 1);
		return $src if length $src;
	}
	# the Internet app's picture lives under the web button's name
	return &icon_for('/images/make believe/web_button.png') if $unformatted_name eq 'internet';
	if ($gb::known_appts->{$unformatted_name} && $gb::known_appts->{$unformatted_name}->{'icon'}) {
		return &icon_for($gb::known_appts->{$unformatted_name}->{'icon'});
	}
	return &icon_for('/icons/pos/' . $settings->{'pos'} . '.png') if $settings->{'pos'} && -e 'public/icons/pos/' . $settings->{'pos'} . '.png';
	# A custom app has no entry in known_appts and may have no picture yet; the
	# same gear the start menu and search index draw keeps its window and
	# taskbar button from losing the icon entirely.
	return &icon_for('/images/decipherable/gear.png');
}

sub main_icon_maker {
	my $data = shift;
	my $unformatted_name = $data->{'app'};
	my $timestamp = $data->{'timestamp'};
	my $settings = $data->{'settings'};
	my $size = $data->{'size'} || 'tiny';
	# A caller that supplies its own onclick used to leave this undefined, and
	# every icon built that way warned in the concatenation below.
	my $onclick = $data->{'onclick'};
	unless (defined $onclick && length $onclick) {
		$onclick = 'onclick="windowRestorer(' . $timestamp . ',\'' . $unformatted_name . '\')"';
	}
	$settings = &subs::settings_grabber({ app => $unformatted_name }) unless $settings;
	# a window may wear a name that is not its key (the accounting app is still
	# stored under 'budget'), so the caller can name the hint it shows
	my $hint = (defined $data->{'hint'} && length $data->{'hint'}) ? $data->{'hint'} : &subs::format_name($unformatted_name);
	# a caller may want the icon to read as a control (the title bar's icon opens
	# the window's quiet controls), so it can add a class of its own
	my $extra_class = (defined $data->{'class'} && length $data->{'class'}) ? ' ' . $data->{'class'} : '';
	my $src = &subs::main_icon_source({ app => $unformatted_name, settings => $settings });
	my $main_image = '<span id="window_icon_' . $timestamp . '" style="display:none;" class="window_icon ' . $size . '_thumb' . $extra_class . '" app="' . $unformatted_name . '" hint="' . $hint . '" ' . $onclick . '>' . &subs::initialize_name($hint) . '</span>';
	if (length $src) {
		$main_image = '<img id="window_icon_' . $timestamp . '" class="window_icon ' . $size . '_thumb' . $extra_class . '" app="' . $unformatted_name . '" hint="' . $hint . '" src="' . $src . '" ' . $onclick . '>';
	}
	return $main_image
}

sub device_setter {
	my $device = 'computer';
	if ($config->{'device'}) {
		$device = $config->{'device'};
	}
	elsif ($^O eq 'MSWin32' || $^O eq 'darwin') {
		$device = 'computer';
	}
	elsif (-e '/system/bin/init' || $ENV{'ANDROID_ROOT'} || $ENV{'TERMUX_VERSION'}) {
		$device = 'mobile';
	}
	else {
		my $uname = `uname -a`;
		if ($uname =~ /Android/gi) {
			$device = 'mobile';
		}
		elsif ($uname =~ /Debian/gi) {
			$device = 'server';
		}
	}
	return $device;
}

# M0 contracts (docs/roadmap-handoff.md): one door for every Android device
# command. A caller names the command without its "termux-" prefix and passes
# the argument string exactly as the shell should see it, so wrapping a call
# site changes nothing at runtime. M1 replaces these three bodies with the
# DeviceService client and the call sites stay put. The literal "termux-"
# now lives only here; scripts/termux_ledger.pl counts it.
sub device_cmd {
	my ($name, $args) = @_;
	$name = '' unless defined $name;
	$name =~ s/\Atermux-//;
	my $cmd = "termux-$name";
	return (defined $args && length $args) ? "$cmd $args" : $cmd;
}

# Run a device command through the shell. The optional prefix keeps a pipeline
# or a timeout at the call site ("timeout 8 ", 'echo "$message" | ').
sub device_run {
	my ($name, $args, $prefix) = @_;
	$prefix = '' unless defined $prefix;
	my $cmd = &device_cmd($name, $args);
	return `$prefix$cmd`;
}

# Where the Termux API app's command would be, for the capability probes that
# ask "-x" before spawning one. M1 answers this from the bridge instead.
sub device_bin {
	my ($name) = @_;
	$name = '' unless defined $name;
	$name =~ s/\Atermux-//;
	# M4: the app is com.jawnos, and its prefix is whatever the app exported;
	# the old fork's absolute path was baked here and would point at nothing.
	my $prefix = $ENV{'PREFIX'};
	$prefix = '/data/data/com.jawnos/files/usr' unless defined $prefix && length $prefix;
	return "$prefix/bin/termux-$name";
}

# The host app's identity (M4). The Java package is com.jawnos.app and every
# intent action is com.jawnos.app.*, but the *installed* package is com.jawnos
# (the app's manifest package) and in the fork it was com.termux. A component
# name is relative to the installed package ("com.jawnos/.app.X"), so both the
# action and the component follow this one value: a device still on the fork
# keeps answering its own names until it is migrated.
sub app_package {
	my $package = $ENV{'JAWNOS_APP_PACKAGE'};
	return $package if defined $package && length $package;
	# A device still on the fork keeps com.termux until it is migrated; an app's
	# own data dir is readable to its own uid, and a desktop has neither.
	return 'com.termux' if !-d '/data/data/com.jawnos' && -d '/data/data/com.termux';
	return 'com.jawnos';
}

# An intent action of the host app: JAWN_WAKE -> com.jawnos.app.JAWN_WAKE.
sub app_action {
	my ($name) = @_;
	return undef unless defined $name && length $name;
	return &app_package() . '.app.' . $name;
}

# A component of the host app, named the way `am` wants it.
sub app_component {
	my ($class) = @_;
	return undef unless defined $class && length $class;
	return &app_package() . '/.app.' . $class;
}

sub device_bridge_token_file {
	my $env = $ENV{'JAWNOS_DEVICE_TOKEN'};
	return $env if defined $env && length $env;
	return &home('~/.jawn/device.token');
}

sub device_bridge_port {
	my $port = $ENV{'JAWNOS_DEVICE_BRIDGE_PORT'};
	return $port + 0 if defined $port && $port =~ /^\d+$/;
	return 46000;
}

sub device_bridge_connect {
	require IO::Socket::INET;
	my $sock = IO::Socket::INET->new(
		PeerAddr => '127.0.0.1',
		PeerPort => &device_bridge_port(),
		Proto    => 'tcp',
		Timeout  => 1,
	);
	return $sock;
}

# M1 device bridge (docs/roadmap-handoff.md): ask the host app directly instead
# of spawning a termux-* command. One JSON line in, one back, with a request
# id, on a loopback socket the app opens (the jawn-bt pattern). Returns the
# decoded result, or undef when the bridge is not there - every caller keeps
# the termux command as its fallback, so an old app with a new tree and a new
# app with an old tree both work.
#
# The token is the app's: it writes $HOME/.jawn/device.token (mode 600) because
# the app and Termux share one uid. JAWNOS_DEVICE_TOKEN/BRIDGE_PORT exist for
# the tests and an unusual install.
sub device_call {
	my ($method, $args, $wait) = @_;
	return undef unless defined $method && length $method;

	my $now = time;
	# One missed reply is usually the app being busy, not a dead bridge. Keep
	# the cooldown short so the next poll recovers; the battery sample serves
	# the last good reading while this is in force.
	my $cooldown = 5;
	return undef if $device_bridge_memo && ($device_bridge_memo->{'until'} || 0) > $now;

	my $token = '';
	my $token_file = &device_bridge_token_file();
	if (open(my $tf, '<', $token_file)) {
		$token = <$tf> // '';
		close $tf;
		$token =~ s/\s+//g;
	}
	unless (length $token) {
		$device_bridge_memo = { until => $now + $cooldown };
		return undef;
	}

	my $sock = $device_bridge_sock;
	unless ($sock) {
		$sock = &device_bridge_connect();
		unless ($sock) {
			$device_bridge_memo = { until => $now + $cooldown };
			return undef;
		}
		$sock->autoflush(1);
		$device_bridge_sock = $sock;
	}

	my $id = ++$device_bridge_seq;
	my $request = eval {
		encode_json({
			id     => $id,
			token  => $token,
			method => $method,
			args   => (ref $args eq 'HASH' ? $args : {}),
		});
	};
	if (!defined $request) { return undef; }

	my $wrote = eval {
		local $SIG{'PIPE'} = 'IGNORE';
		print {$sock} $request . "\n";
	};
	if (!$wrote) {
		close $sock;
		$device_bridge_sock = undef;
		$device_bridge_memo = { until => $now + $cooldown };
		return undef;
	}

	my $answer;
	my $select = IO::Select->new($sock);
	if ($select->can_read(defined $wait ? $wait : 2)) {
		$answer = <$sock>;
	}
	unless (defined $answer) {
		close $sock;
		$device_bridge_sock = undef;
		$device_bridge_memo = { until => $now + $cooldown };
		return undef;
	}
	$answer =~ s/\s+$//;
	my $reply = eval { decode_json($answer) };
	unless (ref $reply eq 'HASH' && $reply->{'ok'} && ref $reply->{'result'} eq 'HASH') {
		# A refusal or a malformed answer is not a transport failure: fall back
		# to the termux command now, but leave the bridge enabled.
		return undef;
	}
	return $reply->{'result'};
}

sub device_thumbnail {
	my ($path, $max, $at_ms) = @_;
	return undef unless defined $path && length $path;
	$max = 256 unless defined $max && $max > 0;
	my %args = (path => $path, max => int($max));
	$args{'at_ms'} = int($at_ms) if defined $at_ms;
	my $result = &device_call('media.thumbnail', \%args, 20);
	return undef unless ref $result eq 'HASH';
	my $data = $result->{'data'};
	return undef unless defined $data && length $data;
	require MIME::Base64;
	my $bytes = MIME::Base64::decode_base64($data);
	return (defined $bytes && length $bytes) ? $bytes : undef;
}

# The robust slope of a battery history, in percentage points per hour.
# Points are { t => epoch_ms, p => percent }. A fit needs $min_points samples
# across $min_span milliseconds AND at least $min_delta points of net movement:
# on a 1% gauge a three-sample five-minute window is one integer step, not a
# rate. The slope is Theil-Sen (the median of every pairwise slope), so a
# single voltage sag or bad reading is one pair's worth of noise rather than the
# answer. Returns (slope, span_ms, samples, p25, p75, movement); the first three
# are the old contract, and p25/p75 form the confidence band the card shows as a
# range. A partial answer still carries the span/movement so a caller can tell
# "not enough time yet" from "too flat to measure".
sub battery_slope {
	my ($points, $min_points, $min_span, $min_delta) = @_;
	$min_points ||= 3;
	$min_span ||= 1200000;   # twenty minutes
	$min_delta = 2 unless defined $min_delta;
	my @raw = sort { $a->{'t'} <=> $b->{'t'} }
		grep { ref $_ eq 'HASH' && defined $_->{'p'} && defined $_->{'t'} } @{ $points || [] };
	my @p;
	my $last_t;
	foreach my $point ( @raw ) {
		my $t = $point->{'t'} + 0;
		my $v = $point->{'p'} + 0;
		next if $v < 0 || $v > 100;
		next if defined $last_t && $t <= $last_t;   # a duplicate or out of order
		# A jump this large, or a gap this long, is a new segment - a battery
		# swap, a bad read, or a board that slept through the gap - not the
		# drain being measured. Keep the newest segment.
		@p = () if @p && abs($v - $p[-1]->{'p'}) > 10;
		@p = () if @p && $t - $p[-1]->{'t'} > 1800000;
		push @p, { t => $t, p => $v };
		$last_t = $t;
	}
	return (undef, 0, 0, undef, undef, 0) unless @p;
	my $span = $p[-1]->{'t'} - $p[0]->{'t'};
	my $movement = abs($p[-1]->{'p'} - $p[0]->{'p'});
	return (undef, $span, scalar @p, undef, undef, $movement) if @p < $min_points;
	return (undef, $span, scalar @p, undef, undef, $movement) if $span < $min_span;
	return (undef, $span, scalar @p, undef, undef, $movement) if $movement < $min_delta;
	my @slopes;
	for my $i ( 0 .. $#p - 1 ) {
		for my $j ( $i + 1 .. $#p ) {
			my $dt = ($p[$j]->{'t'} - $p[$i]->{'t'}) / 3600000;   # hours
			next unless $dt > 0;
			push @slopes, ($p[$j]->{'p'} - $p[$i]->{'p'}) / $dt;
		}
	}
	return (undef, $span, scalar @p, undef, undef, $movement) unless @slopes;
	@slopes = sort { $a <=> $b } @slopes;
	my $quantile = sub {
		my $f = shift;
		my $pos = $f * (scalar(@slopes) - 1);
		my $lo = int($pos);
		my $hi = $lo + 1;
		$hi = $lo if $hi > $#slopes;
		return $slopes[$lo] + ($slopes[$hi] - $slopes[$lo]) * ($pos - $lo);
	};
	my $median = $quantile->(0.5);
	my $lo = $quantile->(0.25);
	my $hi = $quantile->(0.75);
	return ($median, $span, scalar @p, $lo, $hi, $movement);
}

1;
