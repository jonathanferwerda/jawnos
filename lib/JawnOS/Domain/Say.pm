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
use File::Spec ();
use JawnOS::Platform ();
use JawnOS::Platform::Audio ();
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
	my $bundled = &subs::voices_dir() . '/piper/piper';
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
	return join ' ', JawnOS::Platform::Audio::player_argv();
}

# The piper executable's own directory, on either platform: a Windows bundle
# names it with backslashes, and the espeak-ng data sits beside it.
sub say_piper_dir {
	my ($bin) = @_;
	return '' unless defined $bin && length $bin && $bin =~ m{[\\/]};
	(my $dir = $bin) =~ s{[\\/][^\\/]+$}{};
	return $dir;
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
	my $model = &subs::voices_dir() . '/' . $spec->{'model'} . '.onnx';
	return () unless scalar @argv && -e $model;
	# a bundle carries its own espeak-ng data; point piper at it (the glibc
	# launcher, unlike a native run, does not find it on its own)
	my $piper_dir = &subs::say_piper_dir($argv[-1] || '');
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
	my $tmp_dir = $gb::tmp_dir || JawnOS::Platform::Paths::tmp_dir();
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

# Send a finished WAV to the browsers on this machine.
#
# Windows has no shell player, so the voice it renders has no sink to fork.
# The frame carries the audio itself - base64 in the message the socket already
# sends - so nothing is served from a directory and nothing outlives the
# utterance. The cap keeps a runaway render out of a socket frame; a normal
# sentence is far under it.
our $say_broadcast_max_bytes = 2 * 1024 * 1024;

sub say_broadcast_wav {
	my ($wav) = @_;
	return 0 unless defined $wav && length $wav && -f $wav && -s $wav;
	my $size = -s $wav;
	if ($size > $say_broadcast_max_bytes) {
		eval { $log->info('say: the clip is too long to send to the browser (' . $size . ' bytes)') } if $log;
		unlink $wav;
		return 0;
	}
	my $bytes = read_file($wav, binmode => ':raw');
	unlink $wav;
	return 0 unless defined $bytes && length $bytes;
	# The notification card already broadcasts through this socket, so the
	# browser hears the voice on the same channel it hears the chime.
	&Websocket::send('server', {
		type => 'speech',
		audio => encode_base64($bytes, ''),
		mime => 'audio/wav',
	});
	return 1;
}

# The speaking, with no event loop of its own to reset. say_it runs it in a
# child - a fork on Unix, perl/subprocessor_worker.pl on a box without fork -
# because a request may speak and still have to answer (Leave says goodbye).
# Run inline it would reset the request worker's event loop, and the reply in
# flight would never leave.
sub say_speak {
	my ($text, $voice_override) = @_;
	return unless defined $text && length $text;
	return if eval { &subs::sound_muted_for('speech') };
	my $pick = $voice_override || &subs::misc_setting('say_voice') || &subs::say_default_voice();
	my $spec = &subs::say_voice_spec($pick) || &subs::say_voice_spec(&subs::say_default_voice());
	# Piper first, on every device, so the voice is uniform wherever it can
	# run: the models are shared (voice_sync), only the binary is per-device.
	if (($spec->{'engine'} || '') eq 'piper') {
		my $wav = &subs::say_render_wav($text, $pick);
		if ($wav) {
			# A machine with no shell player (Windows) has no sink to fork:
			# hand the finished clip to the open browser instead. The phone
			# keeps its bridge and a Linux box keeps its local voice.
			if ($device ne 'mobile' && !JawnOS::Platform::Audio::player_available()) {
				&subs::say_broadcast_wav($wav);
				return;
			}
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
	my @espeak = JawnOS::Platform::Audio::speak_argv($text, $voice);
	system(@espeak) if @espeak;
	return;
}

sub say_it {
	my $text = shift;
	my $voice_override = shift;
	return unless defined $text && length $text;
	return if eval { &subs::sound_muted_for('speech') };
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
	# A clip that arrived over the WiFi route names the device by its source
	# address, even when the device list has no IP for it (a watch seen only over
	# BLE). That is proof the device is on this network right now, so its board
	# server is not probed: the probe stays for the BLE path, where the request's
	# source is the bridge rather than the device.
	my $peer = $meta->{'peer_ip'} || '';
	my $dev_ip = $peer =~ /^(?:10\.\d{1,3}|192\.168|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}$/
		? $peer : '';
	if (!length $dev_ip) {
		my $dev = &subs::device_lister(&subs::rightNow(), $edt, undef, $meta->{'chip_id'});
		$dev_ip = $dev->{'ip'};
		return undef unless $dev_ip && $dev_ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
		require IO::Socket::INET;
		my $sock = IO::Socket::INET->new(PeerAddr => $dev_ip, PeerPort => ($ENV{PORT_BOARD} || 3000), Proto => 'tcp', Timeout => 0.7);
		return undef unless $sock;
		close $sock;
	}
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
	# The reply id is the capability (see /watch/reply_audio), so the device needs
	# no Now Me pair to fetch the one-shot file. A missing authorization spec must
	# not push a WiFi reply back onto Bluetooth, where the sound is slow.
	return {
		ip => $dev_ip,
		edt => $edt,
		base => 'https://' . $server_ip . ':' . ($ENV{'PORT_ARM'} || ''),
	};
}

# The cloud speech model a reply falls back to when this machine has no piper.
# The Android app runtime is one: it runs no glibc binary and ships no python, so
# scripts/jawnos_deps.pl skips piper there by design. Piper is still preferred
# wherever it can speak, so the house voice does not change on a desktop.
sub reply_speech_model {
	my $model = &subs::setting_grabber({ app => 'mail', setting => 'text_to_audio_assistant' });
	$model = &subs::setting_grabber({ app => 'mail', setting => 'text_to_audio_assistant', device => 'all' })
		unless defined $model && length $model;
	return (defined $model && length $model) ? $model : '';
}

# Piper -> 8 kHz mono s16le PCM (the rate the watch's speaker opens). '' when
# piper is absent or the pipeline fails; the caller then tries the cloud.
sub piper_pcm_8k {
	my ($text, $argv, $espeak, $model, $rate) = @_;
	return undef unless $argv && $model;
	require IPC::Open3;
	require Symbol;
	my @piper = (@{$argv}, @{$espeak}, '--output_raw', '-m', $model);
	my $pipeline = join(' | ', &subs::pipeline_quote(@piper),
		"ffmpeg -nostdin -loglevel error -f s16le -ar $rate -ac 1 -i - -f s16le -ar 8000 -ac 1 -");
	my $err = Symbol::gensym();
	my ($pin, $pout);
	my $pid = eval { IPC::Open3::open3($pin, $pout, $err, 'sh', '-c', $pipeline) };
	return undef unless $pid;
	print {$pin} $text;
	close $pin;
	binmode($pout);
	my $pcm = do { local $/; <$pout> // '' };
	close $pout;
	close $err;
	waitpid($pid, 0);
	return ($? == 0 && length $pcm) ? $pcm : undef;
}

# Any container ffmpeg reads (the cloud hands back mp3 or wav) -> the same
# 8 kHz mono s16le PCM the reply paths have always streamed.
sub transcode_pcm_8k {
	my ($bytes) = @_;
	return undef unless defined $bytes && length $bytes;
	require IPC::Open3;
	require Symbol;
	my $err = Symbol::gensym();
	my ($pin, $pout);
	my $pid = eval {
		IPC::Open3::open3($pin, $pout, $err, 'ffmpeg',
			'-nostdin', '-loglevel', 'error', '-i', '-',
			'-f', 's16le', '-ar', '8000', '-ac', '1', '-')
	};
	return undef unless $pid;
	binmode($pin);
	print {$pin} $bytes;
	close $pin;
	binmode($pout);
	my $pcm = do { local $/; <$pout> // '' };
	close $pout;
	close $err;
	waitpid($pid, 0);
	return ($? == 0 && length $pcm) ? $pcm : undef;
}

# ---------------------------------------------------------------------------
# Warm Piper: a resident voice for the replies that follow each other.
#
# piper the CLI loads its model on every call, and a short sentence is most of
# that cost on a small machine. A repeat reply should not pay it twice. The
# daemon (scripts/piper_server.pl) keeps one piper process and answers loopback
# HTTP with the same 8 kHz PCM the one-shot path makes; the reply path tries it
# first and falls back to the one-shot when it is not up, not current, or slow.
#
# It follows the warm whisper server's shape (Ai.pm): a demand marker,
# ~/.president/piper-want, that a voice clip touches, a President loop that
# starts the daemon while the marker is fresh and stops the one it started after
# ten quiet minutes, and no server on a machine that has no piper (the Android
# app runtime). The daemon also stops itself, so a server a Crew job started on
# a peer cannot outlive its welcome either.
# ---------------------------------------------------------------------------

sub piper_server_port {
	my $port = $ENV{'JAWNOS_PIPER_WARM_PORT'};
	return $port + 0 if defined $port && $port =~ /^\d+$/;
	return 8179;
}

# The daemon this tree ships. A packaged install keeps scripts/ beside lib/.
sub piper_server_script {
	my $root = eval { &subs::install_dir() } || '';
	return '' unless length $root;
	return $root . '/scripts/piper_server.pl';
}

# True only where a warm render is possible at all: piper, a voice model for the
# chosen voice, and the daemon script. The phone answers no here (no glibc piper,
# no python), so it never starts a loop it cannot use.
sub piper_server_available {
	return 0 unless length &subs::say_piper_binary();
	my ($argv, $espeak, $model, $rate) = &subs::say_piper_parts();
	return 0 unless $argv && ref $argv eq 'ARRAY' && @{$argv} && $model && -e $model;
	my $script = &piper_server_script();
	return 0 unless length $script && -f $script;
	return 1;
}

# Demand marker, the same contract as whisper-want: 0 when nothing has ever
# asked, the marker's mtime otherwise. Passing a true value touches it.
sub piper_server_wanted {
	my ($touch) = @_;
	my $file = &subs::home('~/.president/piper-want');
	if (!-e $file) {
		return 0 unless $touch;
		my $dir = &subs::home('~/.president');
		eval { File::Path::make_path($dir) } unless -d $dir;
		open(my $fh, '>>', $file) or return 0;
		close($fh);
	}
	utime(undef, undef, $file) if $touch;
	my $mtime = (stat($file))[9];
	return $mtime || 0;
}

# One request to the daemon. Returns { code, headers, body } or undef. A tiny
# hand-rolled client (rather than Mojo::UserAgent) keeps this usable inside a
# subprocessor child whose loop was reset and gives a precise timeout: a reply
# must fall back, never wait.
sub _piper_warm_http {
	my ($method, $path, $body, $timeout) = @_;
	$timeout = 3 unless defined $timeout && $timeout > 0;
	require IO::Socket::INET;
	require IO::Select;
	my $sock = IO::Socket::INET->new(
		PeerAddr => '127.0.0.1',
		PeerPort => &piper_server_port(),
		Proto    => 'tcp',
		Timeout  => 1,
	);
	return undef unless $sock;
	$sock->autoflush(1);
	$body = '' unless defined $body;
	my $req = $method . ' ' . $path . " HTTP/1.1\r\n"
		. "Host: 127.0.0.1\r\nConnection: close\r\n";
	$req .= "Content-Type: text/plain; charset=utf-8\r\n" if $method eq 'POST';
	$req .= 'Content-Length: ' . length($body) . "\r\n\r\n" . $body;
	my $wrote = eval {
		local $SIG{'PIPE'} = 'IGNORE';
		print {$sock} $req;
		1;
	};
	unless ($wrote) {
		close $sock;
		return undef;
	}
	my $sel = IO::Select->new($sock);
	my $buf = '';
	my $deadline = time + $timeout;
	while (1) {
		my $left = $deadline - time;
		last if $left <= 0;
		last unless $sel->can_read($left);
		my $n = sysread($sock, my $chunk, 65536);
		last unless defined $n && $n > 0;
		$buf .= $chunk;
		last if length($buf) > 2_000_000;
		if ($buf =~ /\r?\n\r?\n/ && $buf =~ /^Content-Length:\s*(\d+)/mi) {
			my (undef, $got) = split(/\r?\n\r?\n/, $buf, 2);
			last if defined $got && length($got) >= $1;
		}
	}
	close $sock;
	my ($head, $payload) = split(/\r?\n\r?\n/, $buf, 2);
	return undef unless defined $head && length $head;
	my ($code) = $head =~ m{^HTTP/\d\.\d\s+(\d{3})};
	return undef unless defined $code;
	my %headers;
	foreach my $line (split(/\r?\n/, $head)) {
		my ($k, $v) = $line =~ /^([^:]+):\s*(.*)$/ or next;
		$headers{lc $k} = $v;
	}
	$payload = '' unless defined $payload;
	my $len = $headers{'content-length'};
	if (defined $len && $len =~ /^\d+$/ && length($payload) > $len) {
		$payload = substr($payload, 0, $len);
	}
	return { code => $code + 0, headers => \%headers, body => $payload };
}

# The daemon's identity, or undef. The model is how the caller knows a voice
# change has made the resident process stale.
sub piper_server_health {
	my $res = &_piper_warm_http('GET', '/health', '', 2);
	return undef unless $res && $res->{'code'} == 200;
	my $d = eval { decode_json($res->{'body'}) };
	return undef unless ref $d eq 'HASH' && $d->{'ok'};
	return $d;
}

# Render words through the resident process. Undef when it is not up, answers
# with a different model, or takes longer than a reply may. The caller then uses
# the one-shot path, so a warm server is an accelerator and never a dependency.
sub piper_server_render {
	my ($text, $model) = @_;
	return undef unless defined $text && length $text;
	my $res = &_piper_warm_http('POST', '/render', $text, 10);
	return undef unless $res && $res->{'code'} == 200;
	my $seen = $res->{'headers'}->{'x-piper-model'} // '';
	if (defined $model && length $model && $seen ne $model) {
		return undef;
	}
	my $pcm = $res->{'body'};
	return (defined $pcm && length $pcm) ? $pcm : undef;
}

sub piper_server_shutdown {
	my $res = &_piper_warm_http('POST', '/shutdown', '', 2);
	return ($res && $res->{'code'} == 200) ? 1 : 0;
}

# Start the daemon detached. The child loads the model while the caller returns
# to its turn; the server's own idle timer is what eventually ends it. Only a
# platform with fork runs it (the loop and the Crew job are its two callers, and
# the no-fork desktops fall back to the one-shot render).
sub piper_server_spawn {
	my ($argv, $espeak, $model) = @_;
	return 0 unless $argv && ref $argv eq 'ARRAY' && @{$argv} && $model;
	return 0 unless JawnOS::Platform::use_fork();
	my $script = &piper_server_script();
	return 0 unless length $script && -f $script;
	my $piper = $argv->[-1];
	return 0 unless defined $piper && length $piper && -x $piper;
	my $log = &subs::home('~/piper-warm.log');
	my @cmd = ($^X, $script, '--piper', $piper, '--model', $model,
		'--port', &piper_server_port(), '--log', $log);
	push @cmd, '--runner', $argv->[0] if scalar(@{$argv}) > 1;
	my $espeak_dir = (@{ $espeak || [] } >= 2 && $espeak->[0] eq '--espeak_data')
		? $espeak->[1] : '';
	push @cmd, '--espeak-data', $espeak_dir if length $espeak_dir;
	my $pid = fork();
	return 0 unless defined $pid;
	if ($pid == 0) {
		POSIX::setsid();
		open(STDIN, '<', File::Spec->devnull());
		open(STDOUT, '>>', $log);
		open(STDERR, '>&', STDOUT);
		exec(@cmd) or POSIX::_exit(1);
	}
	return $pid;
}

# Ask for a warm voice now. Touches the marker (so the demand loop keeps one
# alive) and starts the daemon when it is not already up. Best effort: a machine
# without piper answers 0 and nothing is started.
sub piper_server_warm {
	return 0 unless &piper_server_available();
	&piper_server_wanted(1);
	return 1 if &piper_server_health();
	my ($argv, $espeak, $model, $rate) = &subs::say_piper_parts();
	my $pid = &piper_server_spawn($argv, $espeak, $model);
	return $pid ? 1 : 0;
}

# A warm server outlives the tree that started it: its loop is killed with the
# restart and the process stays, reparented to init. Stop those once, when the
# loop starts. Only a piper_server.pl on this port is touched; a person's own
# server is not this script's business.
sub piper_server_stop_orphans {
	my $port = &piper_server_port();
	my $stopped = 0;
	require JawnOS::Platform::Process;
	foreach my $row ( @{ JawnOS::Platform::Process::table() } ) {
		my $pid = $row->{'pid'};
		next if $pid == $$;
		next unless defined $row->{'ppid'} && $row->{'ppid'} eq '1';
		my $cmd = $row->{'cmdline'} || '';
		next unless length $cmd;
		next unless $cmd =~ /piper_server\.pl/;
		next unless $cmd =~ /--port\s+\Q$port\E/;
		JawnOS::Platform::Process::signal('TERM', $pid);
		$stopped++;
	}
	return $stopped;
}

# The demand loop, run by President as the 'piper server' subprocessor. Started
# only where piper can run; the phone has none and skips it. The daemon stops
# itself on idle, so the loop owns a process only to reap it; a server a Crew
# job started on a peer is left to its own timer. The one thing the loop must
# act on is a voice change: the resident model is the old voice, so it is
# stopped and (while the house is still talking) the new one is started.
sub piper_server_demand_loop {
	my $idle_limit = 600;      # ten quiet minutes, then the model goes back
	my $want_at = 0;
	my $server_pid = 0;
	my $orphans = &piper_server_stop_orphans();
	$log->info('piper: stopped ' . $orphans . ' orphaned warm server(s)') if $orphans && $log;
	while (1) {
		&subs::subprocessor_heartbeat();
		my $want = &piper_server_wanted();
		$want_at = $want if $want > $want_at;
		my $recent = ($want_at && (time - $want_at) <= 120) ? 1 : 0;
		my $idle   = ($want_at && (time - $want_at) > $idle_limit) ? 1 : 0;
		if ($server_pid) {
			my $reaped = waitpid($server_pid, POSIX::WNOHANG());
			$server_pid = 0 if $reaped == $server_pid || $reaped == -1;
		}
		my ($argv, $espeak, $model, $rate) = &subs::say_piper_parts();
		my $health = &piper_server_health();
		my $up = $health ? 1 : 0;
		my $up_model = $health ? ($health->{'model'} // '') : '';
		if ($up && length $model && $up_model ne $model) {
			# The chosen voice changed: the loaded model is the old one. Stop it
			# whatever started it, then let the fresh start below pick it up.
			&piper_server_shutdown();
			$up = 0;
			$server_pid = 0;
		}
		my $ready = ($argv && $model && -e $model) ? 1 : 0;
		if (!$up && !$server_pid && $recent && $ready) {
			$server_pid = &piper_server_spawn($argv, $espeak, $model);
		}
		elsif ($up && $server_pid && $idle) {
			&piper_server_shutdown();
			my $gone = 0;
			for (1 .. 50) {
				$gone = 1 if waitpid($server_pid, POSIX::WNOHANG()) != 0;
				last if $gone;
				select(undef, undef, undef, 0.1);
			}
			if (!$gone) {
				kill 'KILL', $server_pid;
				waitpid($server_pid, 0);
			}
			$server_pid = 0;
		}
		sleep($recent ? 5 : 30);
	}
}

# The phone's own voice, written to a file instead of played: the app runtime
# has no piper and no python, but its Android service can synthesize to a WAV
# (speech.synth, added in app 0.118.377). The path must be inside getFilesDir(),
# which subs::home() is on the app runtime (files/home). Returns 8 kHz PCM or
# undef; the caller logs 'device:tts' when it spoke.
sub device_tts_pcm_8k {
	my ($text) = @_;
	return undef unless defined $text && length $text;
	my $dir = &subs::home('~/.president');
	eval { File::Path::make_path($dir) } unless -d $dir;
	# Sweep a crashed render's leftovers; a reply is a few hundred KB at most.
	foreach my $old ( glob("$dir/speech_*.wav") ) {
		unlink $old if $old && time - (stat($old))[9] > 600;
	}
	my $name = &subs::random_string_creator(24);
	$name =~ s/[^A-Za-z0-9]//g;
	return undef unless length $name >= 12;
	my $wav = "$dir/speech_$name.wav";
	# A first synthesis may load the device's engine, so give the bridge longer
	# than its two-second default; the reply must still never wait on a dead one.
	my $result = eval {
		&subs::device_call('speech.synth', { text => $text, path => $wav }, 10);
	};
	unless ($result) {
		unlink $wav if -e $wav;
		return undef;
	}
	unless (-f $wav && (-s $wav) > 44) {
		unlink $wav if -e $wav;
		return undef;
	}
	my $bytes = eval { read_file($wav, binmode => ':raw') };
	unlink $wav if -e $wav;
	return undef unless defined $bytes && length $bytes;
	return &transcode_pcm_8k($bytes);
}

# Ask the Crew for a machine with piper to render the words. Returns 8 kHz
# PCM, or undef. This keeps the house voice on a homebase that cannot run
# piper (the Android app runtime) without sending the reply to a provider.
sub crew_say_render {
	my ($text) = @_;
	return undef unless defined $text && length $text;
	return undef unless defined &crew::dispatch;
	my $out = eval { &crew::dispatch('say.render', { text => $text }) };
	if ($out && ref $out eq 'HASH' && !$out->{'ok'}) {
		$log->info('voice: peer piper unavailable: ' . ($out->{'error'} || 'no peer')) if $log;
	}
	return undef unless $out && ref $out eq 'HASH' && $out->{'ok'};
	my $res = $out->{'result'};
	return undef unless ref $res eq 'HASH' && defined $res->{'pcm_b64'} && length $res->{'pcm_b64'};
	require MIME::Base64;
	my $pcm = MIME::Base64::decode_base64($res->{'pcm_b64'});
	return (defined $pcm && length $pcm) ? $pcm : undef;
}

# The words as 8 kHz PCM by whichever engine this machine has. Returns
# ($pcm, $source, $error); $source is 'piper-warm', 'piper', 'device:tts',
# 'piper@peer' or 'cloud:<model>', so a log line and a test can say who spoke.
sub reply_pcm_8k {
	my ($text) = @_;
	return (undef, undef, 'nothing to say') unless defined $text && length $text;
	my ($argv, $espeak, $model, $rate) = &subs::say_piper_parts();
	if ($argv && $model) {
		# Warm first: it skips the model load the one-shot pays on every call.
		# A repeat reply is then fast; when the daemon is not up yet this is a
		# refused loopback connect, and the one-shot below renders the reply.
		my $warm = &piper_server_render($text, $model);
		return ($warm, 'piper-warm', undef) if defined $warm && length $warm;
		my $pcm = &piper_pcm_8k($text, $argv, $espeak, $model, $rate);
		return ($pcm, 'piper', undef) if defined $pcm && length $pcm;
	}
	# The phone's own engine, to a file this manager can read. It is the house's
	# voice only where piper cannot run (the Android app runtime); it keeps the
	# sentence on the device, unlike the cloud fallback below.
	if ((&subs::device_setter() // '') eq 'mobile') {
		my $device = &device_tts_pcm_8k($text);
		return ($device, 'device:tts', undef) if defined $device && length $device;
	}
	# No local piper: a peer that has one renders the house voice. This is the
	# phone homebase's normal path, and it keeps the reply out of the cloud.
	my $peer = &subs::crew_say_render($text);
	return ($peer, 'piper@peer', undef) if defined $peer && length $peer;
	my $speech = &subs::reply_speech_model();
	return (undef, undef, 'no piper here and no speech model is set (Configure, Plat, Audio)') unless length $speech;
	my ($bytes, undef, $err) = &subs::ai_text_to_speech_result($text, $speech);
	return (undef, undef, $err || 'the speech model returned nothing') unless defined $bytes && length $bytes;
	my $pcm = &transcode_pcm_8k($bytes);
	return (undef, undef, 'the speech audio could not be transcoded (ffmpeg)') unless defined $pcm && length $pcm;
	# Name the model that actually answered: a stale groq:playai-tts setting
	# is mapped to the current Orpheus model, and the log should say so.
	my ($provider, $real) = &subs::ai_text_to_speech_spec($speech, $text);
	my $label = ($provider && $real)
		? (($speech =~ /^[a-z]+:/) ? $provider . ':' . $real : $real) : $speech;
	return ($pcm, 'cloud:' . $label, undef);
}

# A 44-byte PCM WAV header around 8 kHz mono s16le samples.
sub reply_wav_bytes {
	my ($pcm) = @_;
	return '' unless defined $pcm && length $pcm;
	return 'RIFF' . pack('V', 36 + length($pcm)) . 'WAVE'
		. 'fmt ' . pack('VvvVVvv', 16, 1, 1, 8000, 16000, 2, 16)
		. 'data' . pack('V', length($pcm)) . $pcm;
}

# Render the answer once as a WAV, so a WiFi device can fetch it in one
# streamed GET instead of receiving hundreds of BLE notifications. Returns the
# id (the file is ~/.president/reply_<id>.wav) or undef when neither piper nor
# the cloud speech model can produce one; the caller then keeps the BLE stream.
sub device_reply_wav {
	my ($text) = @_;
	my $dir = &subs::home('~/.president');
	foreach my $old ( glob("$dir/reply_*.wav") ) {
		unlink $old if $old && time - (stat($old))[9] > 600;
	}
	my $id = &subs::random_string_creator(32);
	$id =~ s/[^A-Za-z0-9]//g;
	$id = substr($id, 0, 24);
	return undef unless length $id >= 16;
	my $path = "$dir/reply_$id.wav";
	my $started = &subs::rightNow();
	my ($pcm, $source, $err) = &subs::reply_pcm_8k($text);
	unless (defined $pcm && length $pcm) {
		$log->info('voice: reply audio unavailable: ' . ($err || 'nothing rendered')) if $log;
		return undef;
	}
	my $wav = &subs::reply_wav_bytes($pcm);
	unless (write_file($path, { binmode => ':raw' }, $wav)) {
		$log->info('voice: reply audio could not be written to ' . $path) if $log;
		return undef;
	}
	$log->info('voice: reply audio ' . $source . ' ' . length($pcm) . ' bytes in '
		. (&subs::rightNow() - $started) . 'ms') if $log;
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
	# The person's clock, not the log's: ts is when they started speaking. The
	# reply line below is the end-to-end number they actually feel.
	my $since_onset = (defined $meta->{'ts'} && $meta->{'ts'})
		? (&subs::rightNow() - $meta->{'ts'}) . 'ms' : '-';
	my $who = ' chip=' . $meta->{'chip_id'} . ' since_onset=' . $since_onset;
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
	if (defined $want && $want eq 'off') {
		$log->info('voice: reply text-only (audio replies are off)' . $who) if $log;
		return;
	}
	# A device on WiFi pulls one WAV instead of receiving hundreds of BLE parts;
	# an off-WiFi device gets the BLE stream immediately. The text above is the
	# small, immediate half either way.
	my $wifi = &subs::device_wifi_reply($meta);
	if ($wifi) {
		my $args = {
			text => $text,
			chip_id => $meta->{'chip_id'},
			edt => $edt,
			base => $wifi->{'base'},
		};
		$log->info('voice: reply transport=wifi' . $who) if $log;
		&subs::subprocessor(sub { Mojo::IOLoop->reset; &subs::watch_reply_wifi($args) },
			{ name => 'watch reply wifi', fork => 1, args => $args });
		return;
	}
	# Piper synthesizes far faster than the answer is spoken, and the WiFi path
	# runs voice_ingest inline in the request: do all of this off the request. The
	# child re-dials the database itself (bluetooth_sender reads it), so forking
	# here is safe.
	$log->info('voice: reply transport=ble' . $who) if $log;
	my $args = { text => $text, chip_id => $meta->{'chip_id'}, edt => $edt };
	&subs::subprocessor(sub { Mojo::IOLoop->reset; &subs::watch_reply_audio($args) },
		{ name => 'watch reply audio', fork => 1, args => $args });
}

# The WiFi half of a watch reply, as a named body: the subprocessor starts it by
# name on a box without fork, so it must not close over the request it came from.
# It renders one WAV the watch pulls, or streams the sound over BLE when piper
# could not render.
sub watch_reply_wifi {
	my ($args) = @_;
	my $text = defined $args->{'text'} ? $args->{'text'} : '';
	my $meta = { chip_id => $args->{'chip_id'}, edt => $args->{'edt'} };
	my $edt = $args->{'edt'} || 'watch';
	my $id = &subs::device_reply_wav($text);
	if ($id) {
		&subs::bluetooth_sender({
			intent => 'com.jawn.president.bt.connect',
			chip_id => $meta->{'chip_id'},
			edt => $edt,
			message => { type => 'say_audio_ready', data => { id => $id, base => $args->{'base'} } }
		});
	}
	else {
		# piper/ffmpeg failed: the BLE stream still gets the sound there
		&subs::watch_reply_stream($meta, $text);
	}
	return;
}

sub watch_reply_audio {
	my ($args) = @_;
	&subs::watch_reply_stream(
		{ chip_id => $args->{'chip_id'}, edt => $args->{'edt'} },
		defined $args->{'text'} ? $args->{'text'} : '',
	);
	return;
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
	# No piper on this machine (the Android app runtime ships none): render the
	# answer through the configured cloud speech model and send the same 8 kHz
	# PCM parts. This is the case that used to leave the watch silent.
	if (!$argv || !$model) {
		my $started = &subs::rightNow();
		my ($pcm, $source, $err) = &subs::reply_pcm_8k($text);
		my $sent = 0;
		if (defined $pcm && length $pcm) {
			my $est_total = length $pcm;
			my $seq = 0;
			for (my $off = 0; $off < length $pcm; $off += 4096) {
				my $chunk = substr($pcm, $off, 4096);
				$send->({ type => 'say_audio', data => { seq => $seq, last => 0, rate => 8000, total => $est_total, audio => MIME::Base64::encode_base64($chunk, '') } });
				$seq++;
			}
			$send->({ type => 'say_audio', data => { seq => $seq, last => 1, rate => 8000, total => $est_total, audio => '' } });
			$sent = 1;
			$log->info('voice: reply audio ' . $source . ' ' . length($pcm) . ' bytes in '
				. (&subs::rightNow() - $started) . 'ms over BLE') if $log;
		}
		else {
			$log->info('voice: no reply audio rendered for the watch (text only): '
				. ($err || 'nothing rendered')) if $log;
		}
		close $bt if $bt;
		return $sent;
	}
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

# A copy of the app's main image for a notification or another native surface:
# sealed bytes are decrypted through openssl with the passphrase in the process
# environment and resized through a pipe. Nothing plaintext is written to disk,
# not even a thumbnail cache; the caller gets the bytes (and may base64 them).
sub main_image_inline_bytes {
	my $data = shift || {};
	my $app = $data->{'app'} || '';
	my $max = $data->{'max'} || 0;
	my $value = $data->{'value'};
	$value = &subs::setting_grabber({ app => $app, setting => 'main_image' })
		unless defined $value;
	return undef unless defined $value && length $value;
	if ($value =~ /\Adata:image\/[A-Za-z0-9.+-]+;base64,(.*)\z/s) {
		my $b64 = $1;
		$b64 =~ s/\s+//g;
		my $bytes = eval { decode_base64($b64) };
		return (defined $bytes && length $bytes) ? $bytes : undef;
	}
	my $suds = eval { &subs::suds_grabber() } || '';
	return undef unless length $suds;
	my $file = -e $value ? $value : '';
	if (!length $file) {
		my ($destination, $asset) = &subs::file_device_renamer({ file => $value, app => $app, type => 'image' });
		$file = (defined $destination && defined $asset) ? $destination . $asset : '';
		$file = '' unless length $file && -e $file;
	}
	return undef unless length $file;
	my $bytes;
	if ($file =~ /\.enc\z/i) {
		my $standard = $data->{'standard'}
			|| &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' })
			|| 'aes-256-ctr';
		local $ENV{'JAWNOS_INLINE_SUDS'} = $suds;
		open(my $fh, '-|', 'openssl', 'enc', '-d', '-pass', 'env:JAWNOS_INLINE_SUDS', '-' . $standard, '-pbkdf2', '-in', $file) or return undef;
		binmode $fh;
		$bytes = do { local $/; <$fh> };
		close $fh;
		return undef if $?;
	}
	else {
		$bytes = eval { read_file($file) };
	}
	return undef unless defined $bytes && length $bytes;
	return $bytes unless $max > 0;
	my $jpg = &main_image_inline_resize($bytes, $max);
	return (defined $jpg && length $jpg) ? $jpg : $bytes;
}

sub main_image_inline_b64 {
	my $bytes = &main_image_inline_bytes(shift);
	return undef unless defined $bytes && length $bytes;
	return encode_base64($bytes, '');
}

sub main_image_inline_resize {
	my ($bytes, $max) = @_;
	return undef unless defined $bytes && length $bytes;
	my ($reader, $writer);
	my $pid = eval { open2($reader, $writer, 'magick',
		'-limit', 'memory', '128MiB', '-limit', 'map', '0',
		'-', '-resize', "${max}x${max}>", '-quality', '86', 'jpg:-') };
	return undef unless $pid;
	binmode $writer;
	print {$writer} $bytes;
	close $writer;
	binmode $reader;
	my $jpg = do { local $/; <$reader> };
	close $reader;
	waitpid($pid, 0);
	return (defined $jpg && length $jpg) ? $jpg : undef;
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
	# A caller may name the picture to wear when the app has none: the Notices
	# rows ask for the bell, so an app that has never been drawn still reads as a
	# notice. The gear stays the default for every other surface.
	if (defined $data->{'fallback'} && length $data->{'fallback'}) {
		return &icon_for($data->{'fallback'});
	}
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
		# The name is request- and settings-derived. encode_json makes it a JS
		# string literal; html_text then keeps its quotes inside the attribute.
		$onclick = 'onclick="windowRestorer(' . (0 + $timestamp) . ',' . &subs::html_text(encode_json($unformatted_name)) . ')"';
	}
	$settings = &subs::settings_grabber({ app => $unformatted_name }) unless $settings;
	# a window may wear a name that is not its key (the accounting app is still
	# stored under 'budget'), so the caller can name the hint it shows
	my $hint = (defined $data->{'hint'} && length $data->{'hint'}) ? $data->{'hint'} : &subs::format_name($unformatted_name);
	# a caller may want the icon to read as a control (the title bar's icon opens
	# the window's quiet controls), so it can add a class of its own
	my $extra_class = (defined $data->{'class'} && length $data->{'class'}) ? ' ' . $data->{'class'} : '';
	my $src = &subs::main_icon_source({ app => $unformatted_name, settings => $settings, fallback => $data->{'fallback'} });
	my $name_attr = &subs::html_text($unformatted_name);
	my $hint_attr = &subs::html_text($hint);
	my $class_attr = &subs::html_text($extra_class);
	my $src_attr = &subs::html_text($src);
	my $main_image = '<span id="window_icon_' . (0 + $timestamp) . '" style="display:none;" class="window_icon ' . $size . '_thumb' . $class_attr . '" app="' . $name_attr . '" hint="' . $hint_attr . '" ' . $onclick . '>' . &subs::initialize_name($hint) . '</span>';
	if (length $src) {
		$main_image = '<img id="window_icon_' . (0 + $timestamp) . '" class="window_icon ' . $size . '_thumb' . $class_attr . '" app="' . $name_attr . '" hint="' . $hint_attr . '" src="' . $src_attr . '" ' . $onclick . '>';
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
