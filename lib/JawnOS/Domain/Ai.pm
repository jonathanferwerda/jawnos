package subs;

# Ai: extracted from subroutines.pl (package subs). Loaded on
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
use Errno qw(EEXIST);
use Fcntl qw(:flock O_CREAT O_EXCL O_WRONLY);
use File::Copy;
use File::Find;
use File::Path qw(make_path);
use File::Slurp;
use IPC::Open2;
use JSON::PP ();
use List::Util qw(shuffle);
use MIME::Base64;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use JawnOS::Platform ();
use JawnOS::Platform::Process ();
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

our %M;
our %Y;

# A clip the watch's Rec button records is a voice memo, not a command: the
# capture is tagged with this mode (jw_07_house_audio.ino) and always lands in
# the Notes app. VOICE_NOTE_LIMIT is how many such memos a device keeps: a quick
# jot is useful, an endless pile of spoken fragments is not a notebook. The cap
# is keyed by the device that spoke them, so a manually written note is never
# touched.
our $VOICE_NOTE_MODE  = 'note';
our $VOICE_NOTE_LIMIT = 10;
our %ble_event_seen;
our $database;
our $device;
our $gb;
our $log;
our %m;
our $warm_piper_at;

# Speech -> text through a cloud model. The transcription model (Configure -> Plat)
# is either Cloudflare's @cf/openai/whisper or an OpenAI-compatible /audio/
# transcriptions endpoint (Groq whisper-large-v3*, OpenAI whisper-1). '' on any
# failure, so the caller falls back to the local whisper.cpp pipeline.
sub ai_transcribe_cloud {
	my ($text) = &ai_transcribe_cloud_result(@_);
	return defined $text ? $text : '';
}

# The same call, with the reason a failure failed and with silence told apart
# from an outage: a 2xx that heard nothing is still a working model, which is
# what the Plat Test needs to know. ai_transcribe_cloud keeps its old '' answer.
sub ai_transcribe_cloud_result {
	my ($model, $raw, $lang) = @_;
	return (undef, 'no transcription model is set') unless $model && defined $raw && length $raw;
	my @key_settings = &subs::ai_key_settings();
	my $settings = &subs::settings_grabber({ app => 'mail', settings => [ 'cloudflare_account', 'cloudflare_token', @key_settings ] });
	my $suds = &subs::suds_grabber();
	my $secret = sub {
		my $v = shift;
		return '' unless defined $v && length $v;
		my $d = eval { &subs::note_decrypter($suds, $v) };
		return ($d && length $d) ? $d : $v;
	};
	my $ua = Mojo::UserAgent->new(connect_timeout => 6, inactivity_timeout => 30, request_timeout => 45);
	if ($model =~ /^\@cf/) {
		my $account = $settings->{'cloudflare_account'};
		my $token = $secret->($settings->{'cloudflare_token'});
		return (undef, 'no Cloudflare account is set (Configure, Plat, Provider access)') unless $account;
		return (undef, 'no Cloudflare token is set (Configure, Plat, Provider access)') unless $token;
		my $tx = $ua->post('https://api.cloudflare.com/client/v4/accounts/' . $account . '/ai/run/' . $model => {
			'Authorization' => 'Bearer ' . $token,
			'Content-Type' => 'application/json'
		} => json => { audio => encode_base64($raw, '') });
		return (undef, 'could not reach Cloudflare: ' . $tx->error->{'message'}) if $tx->error;
		my $res = $tx->res;
		return (undef, 'the transcription model answered ' . $res->code . ': ' . substr(($res->body || ''), 0, 200)) unless $res->is_success;
		my $d = eval { $res->json } || {};
		my $text = $d->{'result'}->{'text'} || $d->{'result'}->{'transcription'} || $d->{'result'};
		$text = '' if ref $text;
		return ($text // '', undef);
	}
	# openai-compatible transcription: groq, openai, mistral (any provider whose
	# /audio/transcriptions speaks the same multipart shape)
	my ($provider, $real) = ('groq', $model);
	if ($model =~ /^([a-z]+):(.+)$/) { ($provider, $real) = ($1, $2); }
	my %ep = ( openai => 'https://api.openai.com/v1/audio/transcriptions', groq => 'https://api.groq.com/openai/v1/audio/transcriptions' );
	return (undef, 'no transcription endpoint for ' . $provider) unless $ep{$provider};
	my $url = $ep{$provider};
	my %key = ( openai => 'openai_key', groq => 'groq_key' );
	my $key = $secret->($settings->{ $key{$provider} });
	return (undef, 'no ' . $provider . ' key is set (Configure, Plat, Provider access)') unless $key;
	# A test clip is a WAV; a phone's real clip is webm. Name the file by its own
	# header, so a provider that trusts the name still sees the right container.
	my $is_wav = substr($raw, 0, 4) eq 'RIFF';
	my %form = (
		model => $real,
		file => {
			content => $raw,
			filename => ($is_wav ? 'clip.wav' : 'clip.webm'),
			'Content-Type' => ($is_wav ? 'audio/wav' : 'audio/webm'),
		},
		response_format => 'json'
	);
	$form{'language'} = $lang if defined $lang && $lang =~ /^[a-z]{2,3}$/ && $lang ne 'auto';
	my $tx = $ua->post($url => {
		'Authorization' => 'Bearer ' . $key
	} => form => \%form);
	return (undef, 'could not reach ' . $provider . ': ' . $tx->error->{'message'}) if $tx->error;
	my $res = $tx->res;
	return (undef, 'the transcription model answered ' . $res->code . ': ' . substr(($res->body || ''), 0, 200)) unless $res->is_success;
	my $d = eval { $res->json } || {};
	return ($d->{'text'} // '', undef);
}

# The clip the transcription Test sends: a short, known sentence rendered by
# the house's libritts_r voice at 16 kHz mono, committed with the tree. Silence
# only proved that a provider answered; a model that heard nothing at all read
# as healthy. The words are the test's fixed point - the sentence and the
# committed WAV are the same on every machine.
sub transcription_test_wav {
	my @paths;
	# a unit test may load this module without Key.pm, which is where the
	# install dir is defined; the relative path is the fallback there
	my $install = (defined &subs::install_dir) ? &subs::install_dir() : '';
	push @paths, "$install/public/sounds/transcribe-test.wav" if defined $install && length $install;
	push @paths, 'public/sounds/transcribe-test.wav';
	foreach my $path (@paths) {
		next unless -f $path && (-s _) > 44;
		my $bytes = eval { read_file($path, binmode => ':raw') };
		return $bytes if defined $bytes && length $bytes;
	}
	return undef;
}

# The Plat panel's Test for the transcription role. A cloud model is asked to
# transcribe the committed test sentence, so the answer names what it heard and
# a model that returns nothing is not mistaken for a working one. A 2xx with no
# words still passes (the provider answered) but says so. whisper.cpp is run on
# the same clip when it is installed, which proves the model file as well as the
# binary; a machine without it is told, not silently passed.
sub ai_transcribe_test {
	my ($model) = @_;
	$model = '' unless defined $model;
	$model =~ s/^\s+|\s+$//g;
	return (0, 'Pick a model first.') unless length $model;
	if (&transcription_service_is_client($model)) {
		return (1, 'the phone recogniser runs on the device, not here');
	}
	my $wav = &transcription_test_wav();
	if ($model eq 'local:whisper.cpp' || $model eq 'local:vosk') {
		return (0, 'whisper.cpp is not installed on this machine') unless &whisper_available();
		if (defined $wav && length $wav) {
			my $heard = &whisper_cli_transcribe($wav, 'en');
			$heard = '' unless defined $heard;
			$heard =~ s/^\s+|\s+$//g;
			$heard =~ s/\s+/ /g;
			return (1, 'whisper.cpp heard: ' . $heard) if length $heard;
			return (0, 'whisper.cpp is installed but did not hear the test sentence');
		}
		return (1, 'whisper.cpp is ready on this machine');
	}
	# A tree without the clip still gets the old silence probe, so the button
	# never does nothing on a hand-trimmed install.
	unless (defined $wav && length $wav) {
		my $rate = 8000;
		my $frames = int($rate / 2);
		my $pcm = "\x80\x00" x $frames;
		$wav = 'RIFF' . pack('V', 36 + length($pcm))
			. 'WAVEfmt ' . pack('VvvVVvv', 16, 1, 1, $rate, $rate * 2, 2, 16)
			. 'data' . pack('V', length($pcm)) . $pcm;
	}
	my ($heard, $err) = &ai_transcribe_cloud_result($model, $wav, 'en');
	return (0, $err) if $err;
	$heard = '' unless defined $heard;
	$heard =~ s/^\s+|\s+$//g;
	$heard =~ s/\s+/ /g;
	return (1, 'the model heard: ' . $heard) if length $heard;
	return (1, 'the transcription model answered, but heard nothing');
}

sub voice_silence_hallucination {
	# Both transcribers invent a stock phrase when a clip said nothing: whisper.cpp
	# writes "Thank you." and the cloud models "Thanks for watching!" - the well
	# known silence hallucinations. Near-empty clips do happen (a wake phrase that
	# no command followed, and whatever the phone's listener sends), and a
	# transcript that is nothing but one of these is silence, not speech. Without
	# saying so, the guide associate answers a sentence nobody spoke - which is
	# exactly the "it always thinks I said thank you" reply.
	#
	# Only a transcript that is *entirely* one of them counts. A lone word can never
	# be acted on anyway - voice_command_parse needs a verb and a target, and
	# voice_note_store wants three words - so trimming these costs nothing.
	my ($text) = @_;
	return 0 unless defined $text && length $text;
	my $bare = lc $text;
	$bare =~ s/[\[\(][^\]\)]*[\]\)]//g;   # [BLANK_AUDIO], (music), [ Silence ]
	$bare =~ s/[^a-z0-9' ]+/ /g;
	$bare =~ s/\s+/ /g;
	$bare =~ s/^\s+|\s+$//g;
	return 1 unless length $bare;
	my %stock = map { $_ => 1 } (
		'thank you', 'thanks', 'thank you very much', 'thanks very much',
		'thank you so much', 'thanks a lot', 'many thanks', 'thank you thank you',
		'thank you for watching', 'thanks for watching',
		'thank you for watching everyone', 'thanks for watching everyone',
		'thank you for watching this video', 'thanks for watching this video',
		'thank you so much for watching', 'thanks for watching and see you next time',
		'please subscribe', 'please like and subscribe', 'like and subscribe',
		'subscribe to my channel', 'please subscribe to my channel',
		'you', 'yeah', 'yep', 'okay', 'ok', 'hmm', 'mm hmm', 'uh huh',
		'bye', 'bye bye', 'goodbye', 'the end', 'that is it', 'so', 'oh',
	);
	return $stock{$bare} ? 1 : 0;
}

# The warm whisper.cpp server's loopback port. It is an accelerator for this
# machine, never a service offered to the network.
sub whisper_server_port { return 8178; }

# The warm server is started by demand, not at boot: it holds the model (base,
# a 148 MB file and more resident) and a machine that takes no dictation and
# no call should not pay for it. Every transcription request touches this
# marker; President.pl's own loop starts the server while the marker is fresh
# and stops the one it started after ten quiet minutes. Returns the marker's
# mtime, 0 when nothing has ever asked.
sub whisper_server_wanted {
	my ($touch) = @_;
	my $file = &subs::home('~/.president/whisper-want');
	if (!-e $file) {
		return 0 unless $touch;
		open(my $fh, '>>', $file) or return 0;
		close($fh);
	}
	utime(undef, undef, $file) if $touch;
	my $mtime = (stat($file))[9];
	return $mtime || 0;
}

# A whisper server outlives the tree that started it: its loop is killed with the
# restart and the process stays, reparented to init (PPid 1). Nothing would ever
# stop it, and the demand logic in President.pl would keep it as "already up" and
# hold the model for good - base, a 148 MB file and more resident, on a machine
# that may never transcribe again. Stop those once, when that loop starts, and
# only those: a server a person started by hand has a shell for a parent and is
# left alone.
sub whisper_server_stop_orphans {
	my $port = &whisper_server_port();
	my $stopped = 0;
	foreach my $row ( @{ JawnOS::Platform::Process::table() } ) {
		my $pid = $row->{'pid'};
		next if $pid == $$;
		next unless defined $row->{'ppid'} && $row->{'ppid'} eq '1';
		my $cmd = $row->{'cmdline'} || '';
		next unless length $cmd;
		# The compiled binary is whisper-server; the pip wrapper installs as
		# whisper_tool.py. Both spell the name differently, and the underscore is
		# the one this house actually runs (the Gou's server is a wrapper).
		next unless $cmd =~ /whisper[-_](?:server|tool\.py)/;
		next unless $cmd =~ /--port\s+\Q$port\E/;
		JawnOS::Platform::Process::signal('TERM', $pid);
		$stopped++;
	}
	return $stopped;
}

# The desktop wheel's server decodes whatever it is handed; the native
# whisper.cpp server (the phone's) reads WAV only. Convert once here so both
# accept the same bytes. '' when ffmpeg is missing or refuses the clip; the
# caller then posts the raw upload exactly as before.
sub whisper_server_wav {
	my ($raw) = @_;
	return '' unless defined $raw && length $raw;
	require IPC::Open3;
	require Symbol;
	my ($in, $out, $err);
	$err = Symbol::gensym();
	my $pid = eval {
		IPC::Open3::open3($in, $out, $err, 'ffmpeg',
			'-nostdin', '-loglevel', 'error', '-i', '-',
			'-f', 'wav', '-ar', '16000', '-ac', '1', '-acodec', 'pcm_s16le', '-');
	};
	return '' unless $pid;
	binmode($in);
	binmode($out);
	print {$in} $raw;
	close($in);
	my $wav = do { local $/; <$out> // '' };
	close($out);
	close($err);
	waitpid($pid, 0);
	return '' unless ($? >> 8) == 0;
	return $wav;
}

# A warm server keeps the model loaded, so a clip skips the model load the
# one-shot CLI pays on every call. '' when it is not running or did not answer.
sub whisper_server_transcribe {
	my ($raw, $lang) = @_;
	return '' unless defined $raw && length $raw;
	# Ask for the warm server even though this request may fall back to the CLI
	# while the model loads: the next clip is the one that finds it up.
	&whisper_server_wanted(1);
	my $ua = Mojo::UserAgent->new(connect_timeout => 2, inactivity_timeout => 30, request_timeout => 45);
	my $wav = &whisper_server_wav($raw);
	my $form = {
		file => length $wav
			? { content => $wav, filename => 'clip.wav', 'Content-Type' => 'audio/wav' }
			: { content => $raw, filename => 'clip.webm', 'Content-Type' => 'audio/webm' },
		response_format => 'json'
	};
	# the keyboard's chosen layout names the language; whisper itself treats
	# 'auto' as detect
	$form->{'language'} = $lang if defined $lang && $lang =~ /^[a-z]{2,3}$/ && $lang ne 'auto';
	my $tx = eval {
		$ua->post('http://127.0.0.1:' . &whisper_server_port() . '/inference' => form => $form);
	};
	return '' unless $tx && !$tx->error && $tx->res->is_success;
	my $d = eval { $tx->res->json } || {};
	my $text = $d->{'text'} || '';
	$text =~ s/\r//g;
	$text =~ s/^\s+|\s+$//g;
	$text =~ s/\n+/ /g;
	return $text;
}

# The one-shot CLI path. It is also the local path on a machine whose warm
# server is not up yet.
sub whisper_cli_transcribe {
	my ($raw, $lang, $wanted) = @_;
	return '' unless $raw;
	require IPC::Open3;
	require Symbol;
	my $bin   = &whisper_cli_bin();
	# base is the default: on a house command it heard "kitchen lights" where tiny
	# dropped a word ("Kirch and light"), and the roughly doubled time is the
	# accuracy the house asked for. tiny is the fallback when base is not
	# installed; a caller that knows its clip needs a named model still passes it.
	my $model = ($wanted && -e $wanted) ? $wanted : &whisper_model_file('base');
	if (!defined $wanted && (!length $model || !-e $model)) {
		$model = &whisper_model_file('tiny');
	}
	return '' unless $bin && length $model && -e $model;
	my $language = (defined $lang && $lang =~ /^[a-z]{2,3}$/ && $lang ne 'auto') ? ' -l ' . $lang : '';
	# A screened call still has prompts to play while its name is read: base
	# held ~3 of 4 ARM cores for 27 s and starved the Piper voice. Both stages
	# yield with nice 19 so ffmpeg and whisper-cli give the CPU back to the call.
	# The launcher, not the path: on the app runtime the wrapper is read by sh
	# and a native binary is opened by the linker, because exec is refused.
	my $runner = join(' ', map { &subs::shell_quote($_) } &whisper_launch_argv($bin));
	my $cmd = sprintf(
		'nice -n 19 ffmpeg -nostdin -loglevel error -i - -blocksize 4096 -f wav -ar 16000 -ac 1 -acodec pcm_s16le - | nice -n 19 %s -m %s%s --output-txt --file - 2>/dev/null',
		$runner, &subs::shell_quote($model), $language
	);
	my ($in, $out, $err);
	$err = Symbol::gensym();
	my $pid = IPC::Open3::open3($in, $out, $err, 'sh', '-c', $cmd);
	return '' unless $pid;
	binmode($in);
	print {$in} $raw;
	close($in);
	my $text = do { local $/; <$out> // '' };
	close($out);
	close($err);
	waitpid($pid, 0);
	$text =~ s/\r//g;
	$text =~ s/^\s+|\s+$//g;
	$text =~ s/\n+/ /g;
	return $text;
}

# --- whisper.cpp: the local recogniser -------------------------------------
# Every machine transcribes with the same engine. scripts/whisper_stream.py
# reads a screened call; the one-shot paths use the warm server on loopback or
# whisper-cli. scripts/jawnos_deps.pl puts the pywhispercpp wheel, the models
# and both wrappers under ~/.local/share/jawnos/whisper; a machine that built
# whisper.cpp by hand into ~/whisper.cpp is still found. Termux cannot run the
# glibc wheel, so a phone leaves its screened call's audio on the gateway.

sub whisper_root {
	my $dir = $ENV{'JAWNOS_WHISPER_DIR'};
	return $dir if defined $dir && length $dir;
	return &subs::home('~/.local/share/jawnos/whisper');
}

sub whisper_models_dir {
	my $dir = $ENV{'JAWNOS_WHISPER_MODELS'};
	return $dir if defined $dir && length $dir;
	my $installed = &whisper_root() . '/models';
	return $installed if -d $installed;
	my $built = &subs::home('~/whisper.cpp/models');
	return $built if -d $built;
	return $installed;
}

sub whisper_model_file {
	# 'base', 'tiny' or a path; '' when that model is not installed.
	my ($name) = @_;
	$name = 'base' unless defined $name && length $name;
	return $name if $name =~ m{/} && -e $name;
	my $dir = &whisper_models_dir();
	foreach my $candidate ("ggml-$name.bin", "$name.bin") {
		my $path = $dir . '/' . $candidate;
		return $path if -e $path;
	}
	return '';
}

sub whisper_python {
	my $venv = &whisper_root() . '/venv/bin/python3';
	return $venv if -x $venv;
	foreach my $dir (split /:/, ($ENV{'PATH'} // '')) {
		next unless defined $dir && length $dir;
		my $py = "$dir/python3";
		return $py if -x $py;
	}
	return '';
}

sub whisper_cli_bin {
	my $bin = $ENV{'JAWNOS_WHISPER_CLI'};
	return $bin if defined $bin && length $bin && -x $bin;
	foreach my $candidate (
		&whisper_root() . '/whisper-cli',
		&whisper_root() . '/venv/bin/whisper-cli',
		&subs::home('~/whisper.cpp/build/bin/whisper-cli'),
	) {
		return $candidate if -x $candidate;
	}
	foreach my $dir (split /:/, ($ENV{'PATH'} // '')) {
		next unless defined $dir && length $dir;
		my $path = "$dir/whisper-cli";
		return $path if -x $path;
	}
	return '';
}

sub whisper_server_bin {
	my $bin = $ENV{'JAWNOS_WHISPER_SERVER'};
	return $bin if defined $bin && length $bin && -x $bin;
	foreach my $candidate (
		&whisper_root() . '/whisper-server',
		&whisper_root() . '/venv/bin/whisper-server',
		&subs::home('~/whisper.cpp/build/bin/whisper-server'),
	) {
		return $candidate if -x $candidate;
	}
	foreach my $dir (split /:/, ($ENV{'PATH'} // '')) {
		next unless defined $dir && length $dir;
		my $path = "$dir/whisper-server";
		return $path if -x $path;
	}
	return '';
}

# Android's app data directory is mounted noexec, so an ELF copied into
# $PREFIX or ~/.local/share cannot be exec'd at all ("Permission denied",
# even with 0755). The system linker can still map it. Termux papers over the
# same mount with termux-exec; the app runtime has no such shim, so the tree
# asks the linker itself. Any package's data dir is the same mount, so the test
# is the path, not the package name. JAWNOS_ANDROID_LINKER forces the answer for
# a test (an empty value turns it off) and skips the path check.
sub _whisper_android_linker {
	my ($bin) = @_;
	my $forced = $ENV{'JAWNOS_ANDROID_LINKER'};
	return $forced if defined $forced;
	return '' unless -e '/system/bin/linker64';
	return '' unless defined $bin && $bin =~ m{^/data/(?:data|user/\d+)/};
	return '/system/bin/linker64';
}

sub whisper_launch_argv {
	# The argv that runs $bin, for a call that must not go through a shell (the
	# warm server) or for the one that does (the CLI pipeline). A shell wrapper
	# is text: `sh file` reads it where exec would be refused. A binary on the
	# app runtime goes through the linker; everywhere else it runs as itself.
	my ($bin) = @_;
	return () unless defined $bin && length $bin;
	return ($bin) unless -f $bin;
	if (!-B $bin) {
		# Only a shell script can be handed to sh; a Python console script
		# still needs its own interpreter and its exec bit.
		my $first = '';
		if (open(my $fh, '<', $bin)) {
			$first = <$fh> // '';
			close $fh;
		}
		return ('sh', $bin) if $first !~ m{^#!} || $first =~ m{^#!.*\b(?:ba|da)?sh\b};
		return ($bin);
	}
	my $linker = &_whisper_android_linker($bin);
	return ($linker, $bin) if length $linker;
	return ($bin);
}

sub whisper_streamer {
	my $streamer = $ENV{'JAWNOS_WHISPER_STREAMER'};
	return $streamer if defined $streamer && length $streamer;
	return &subs::home('~/jawnos/scripts/whisper_stream.py');
}

# The Plat page and the Crew rail both ask this; one probe a minute is enough.
our $whisper_probe;
# Set while a Crew whisper.transcribe job runs on a peer: the job must use that
# machine's own engine and never dispatch the same clip onward.
our $whisper_no_peer = 0;
sub whisper_available {
	# The file engine is the command and a model. The Python streamer is the
	# screened-call reader's, not this path's: the app runtime on a phone/tablet
	# has no Python, and it still transcribes a clip. A gateway that cannot start
	# the reader says so when it tries.
	my $now = time;
	return $whisper_probe->{'ok'} if $whisper_probe && $now - $whisper_probe->{'at'} < 60;
	my $model = &whisper_model_file('base');
	$model = &whisper_model_file('tiny') unless length $model;
	my $ok = (length $model && (length &whisper_cli_bin() || length &whisper_server_bin())) ? 1 : 0;
	$whisper_probe = { at => $now, ok => $ok };
	return $ok;
}

sub whisper_peer_transcribe {
	# A machine without the local engine can still use the house's: the Crew rail
	# has a whisper.transcribe job with `needs => ['whisper']`, so placement runs
	# it on a peer that advertises the tool. The audio rides base64 on the wire.
	# '' when no peer answers (the caller then tries its own fallback).
	my ($raw, $lang) = @_;
	return '' if $whisper_no_peer;
	return '' unless defined &crew::dispatch;
	my $out = eval {
		&crew::dispatch('whisper.transcribe', {
			audio_b64 => encode_base64($raw, ''),
			lang      => ($lang || 'auto'),
		});
	};
	return '' unless $out && ref $out eq 'HASH' && $out->{'ok'};
	my $result = $out->{'result'};
	return '' unless ref $result eq 'HASH';
	return $result->{'text'} // '';
}

sub whisper_house_available {
	# True when this machine has whisper.cpp, or a house peer that advertises it
	# can run the Crew's whisper.transcribe job. The Plat page offers the engine
	# on that basis: a phone cannot run the wheel itself, but the house can.
	return 1 if &whisper_available();
	return 0 unless defined &crew::place;
	my $me = eval { &subs::signatorial_designer() } || '';
	my $where = eval { &crew::place('whisper.transcribe', {}, from => $me) };
	return ($where && ref $where eq 'HASH' && $where->{'ok'} && !$where->{'local'}) ? 1 : 0;
}

sub _python_has_module {
	my ($python, $module) = @_;
	return 0 unless $python && $module;
	require IPC::Open3;
	require Symbol;
	my ($in, $out, $err);
	$err = Symbol::gensym();
	my $pid = eval { IPC::Open3::open3($in, $out, $err, $python, '-c', "import $module") };
	return 0 unless $pid;
	close $in;
	do { local $/; <$out> };
	close $out;
	do { local $/; <$err> };
	close $err;
	waitpid($pid, 0);
	return $? == 0 ? 1 : 0;
}

# The WebRTC bridge is its own extra and its own venv now that the transcript
# no longer needs one. A machine that has not re-run the installer may still
# have aiortc in the old shared venv, so that location is read but not written.
sub rtc_root {
	my $dir = $ENV{'JAWNOS_RTC_DIR'};
	return $dir if defined $dir && length $dir;
	return &subs::home('~/.local/share/jawnos/rtc');
}

sub rtc_python {
	my $venv = &rtc_root() . '/venv/bin/python3';
	return $venv if -x $venv;
	my $legacy = &subs::home('~/.local/share/jawnos/vosk/venv/bin/python3');
	return $legacy if -x $legacy && &_python_has_module($legacy, 'aiortc');
	foreach my $dir (split /:/, ($ENV{'PATH'} // '')) {
		next unless defined $dir && length $dir;
		my $py = "$dir/python3";
		return $py if -x $py;
	}
	return '';
}

sub rtc_bridge {
	my $script = $ENV{'JAWNOS_RTC_BRIDGE'};
	return $script if defined $script && length $script;
	return &subs::home('~/jawnos/scripts/rtc_bridge.py');
}

sub whisper_local_transcribe {
	# whisper.cpp alone: the warm server first (the model is already loaded),
	# then the one-shot CLI. A stock silence line is not a transcript.
	my ($raw, $lang) = @_;
	my $text = &whisper_server_transcribe($raw, $lang);
	$text = &whisper_cli_transcribe($raw, $lang) unless length $text;
	return '' unless length $text;
	if (&subs::voice_silence_hallucination($text)) {
		$log->info('voice: dropping a stock silence transcript ("' . $text . '")') if $log;
		return '';
	}
	return $text;
}

sub transcribe_local_engine {
	# The local engine a role value names, as a coderef, or undef for a cloud
	# model. An older settings row may still say local:vosk; that engine is
	# gone, and the value is read as whisper.cpp so the role keeps working.
	my ($value) = @_;
	$value = '' unless defined $value;
	$value = 'local:whisper.cpp' if $value eq 'local:vosk';
	return \&whisper_local_transcribe if $value eq 'local:whisper.cpp';
	return undef;
}

# Which transcription service answers which surface. A consumer names what is
# speaking - keyboard, guide, watch, teletype - and its own role
# (transcription_<consumer>) wins once the Plat page has set one. A surface with
# no row of its own reads the shared transcription_assistant row, so a house
# that has never opened the new rows behaves exactly as it did.
sub transcription_role_for {
	my ($consumer) = @_;
	$consumer = '' unless defined $consumer;
	$consumer = lc $consumer;
	$consumer =~ s/[^a-z0-9_]//g;
	$consumer = substr($consumer, 0, 24);
	return 'transcription_assistant' unless length $consumer;
	my $role = 'transcription_' . $consumer;
	my $chosen = &subs::setting_grabber({ app => 'mail', setting => $role });
	# A surface whose reader may be another machine - the screened call's gateway,
	# a clip that lands on whichever manager receives it - is set house-wide from
	# the phone pane (device 'all'). The machine's own row still wins when it has one.
	$chosen = &subs::setting_grabber({ app => 'mail', setting => $role, device => 'all' })
		unless defined $chosen && length $chosen;
	return (defined $chosen && length $chosen) ? $role : 'transcription_assistant';
}

# The concrete service a surface's transcription role resolves to: the role its
# own row names (or the shared role), read through ai_role_models so the caller
# sees the model value ('android:oem', 'local:whisper.cpp', a cloud model) and
# never the role's name. The page uses it to decide whether the phone's own
# recogniser should answer a microphone press; the primary is the chosen
# service, and the fallback stands in only when no primary is set.
sub transcription_service_for {
	my ($consumer) = @_;
	my $role = &transcription_role_for($consumer);
	my ($primary, $fallback) = &ai_role_models($role);
	return $primary if defined $primary && length $primary;
	return defined $fallback ? $fallback : '';
}

# The phone recogniser is a service the house can name but never run: the app
# holds the microphone, not this process. It is offered only for the surfaces
# the phone itself speaks to, and a clip that still finds it in a role is
# skipped rather than posted to a provider that does not exist.
sub transcription_service_is_client {
	my ($service) = @_;
	return (defined $service && $service eq 'android:oem') ? 1 : 0;
}

# The model a screened call's live reader loads. The gateway runs
# scripts/whisper_stream.py, so only the local engine can answer a call here:
# a role naming a cloud model or the phone's own recogniser is read as no role
# at all (the base model, as before) and the note says why. The surface's own
# row (transcription_ivr) wins once the Plat page or the Phone pane sets it;
# until then the shared transcription_assistant row answers. A role that names
# whisper.cpp gets the concrete installed file, so the streamer never has to
# choose a model from the directory itself. Returns (path, note); the note is
# '' when nothing needs explaining.
sub whisper_stream_model {
	my ($consumer) = @_;
	$consumer = 'ivr' unless defined $consumer && length $consumer;
	my $role = &transcription_role_for($consumer);
	my ($primary, $fallback) = &ai_role_models($role);
	my @named = grep { defined $_ && length $_ } ($primary, $fallback);
	my $base = &whisper_model_file('base');
	$base = &whisper_model_file('tiny') unless length $base;
	$base = &whisper_models_dir() unless length $base;
	foreach my $value (@named) {
		next unless &transcribe_local_engine($value);
		return ($base, '');
	}
	return ($base, '') unless @named;
	return ($base, $named[0] . ' cannot read a call on this gateway; using the base model');
}

sub whisper_transcribe {
	# Speech -> text. The transcription role names a primary and a fallback,
	# tried in that order; either may be the local engine (whisper.cpp) or a
	# cloud model. whisper.cpp is always the last resort when it is not already
	# in the list. An older role value of local:vosk is read as whisper.cpp.
	# Raw audio bytes in (any container ffmpeg reads), the transcript out. ''
	# on any failure or on a stock silence line, so a caller only has to check
	# for text. $lang is the keyboard layout's language ('fr', 'hi', ...);
	# 'auto' lets the engine decide. $consumer names what is speaking
	# (keyboard, guide, watch, teletype); its own role is read when the Plat
	# page has set one, otherwise the shared transcription role answers.
	my ($raw, $lang, $consumer) = @_;
	return '' unless $raw;
	my $role = &transcription_role_for($consumer);
	my ($primary, $fallback) = &ai_role_models($role);
	my @order = grep { defined && length } ($primary, $fallback);
	my %seen;
	foreach my $m (@order) {
		my $engine = ($m eq 'local:vosk') ? 'local:whisper.cpp' : $m;
		next if $seen{$engine}++;
		# a service only the app can run: this clip goes to the next choice
		next if &transcription_service_is_client($engine);
		my $local = &transcribe_local_engine($engine);
		my $text;
		if ($local) {
			# The role names this machine; if the engine is not installed here, the
			# house's own engine is the next best thing (the fallback model below is
			# still tried when no peer answers).
			$text = &whisper_available() ? $local->($raw, $lang) : &whisper_peer_transcribe($raw, $lang);
		}
		else {
			$text = &ai_transcribe_cloud($engine, $raw, $lang);
		}
		next if $text && &subs::voice_silence_hallucination($text);
		return $text if $text;
	}
	return '' if grep { $_ eq 'local:whisper.cpp' || $_ eq 'local:vosk' } @order;
	return &whisper_available() ? &whisper_local_transcribe($raw, $lang) : &whisper_peer_transcribe($raw, $lang);
}

sub whisper_name_transcribe {
	# The one thing a screened call leaves is who called, and the words are a
	# handful over a narrowband 8 kHz link. The warm server is asked first: its
	# model is already loaded, so the clip skips the one-shot CLI's load. The
	# local default is base - tiny once read such a clip as "Listen strong." where
	# base read "This is John.", through ffmpeg, sox and miniaudio alike - and
	# when the server is down or says nothing usable the niced CLI at base is the
	# fallback, even at the cost of holding the CPU while Piper plays the call's
	# remaining prompts. What comes back is the words as heard; the caller is
	# filed under name_from_transcript of them, and the raw line is kept beside it
	# because a surname over this link is often only close. '' when nobody spoke.
	my ($raw, $lang) = @_;
	return '' unless defined $raw && length $raw;
	my $text = &whisper_server_transcribe($raw, $lang || 'auto');
	$text = '' if defined $text && &voice_silence_hallucination($text);
	if (!defined $text || !length $text) {
		my $base = &whisper_model_file('base');
		$text = ($base && -e $base)
			? &whisper_cli_transcribe($raw, $lang || 'auto', $base)
			: &whisper_transcribe($raw, $lang || 'auto');
	}
	return '' if !defined $text || !length $text || &voice_silence_hallucination($text);
	return $text;
}

sub name_from_transcript {
	# A caller answers "who are you" with a sentence - "This is Jon", "It's Jon
	# speaking", "My name is Jon Smith". What the house files is the name itself.
	my ($text) = @_;
	return '' unless defined $text;
	my $name = $text;
	$name =~ s/^\s*[-\x{2013}\x{2014}]\s*//;
	$name =~ s/^\s*(?:well|okay|ok|hi|hello),?\s+//i;
	$name =~ s/^\s*(?:this is|the is|that'?s|it'?s|i'?m|i am|my name is|you'?re speaking (?:to|with)|speaking to|here is|call me)\s+//i;
	$name =~ s/\s+(?:speaking|here|on the line)[\s.,!?;:]*$//i;
	$name =~ s/[\s.,!?;:]+$//;
	$name =~ s/^\s+//;
	return $name;
}

sub dictation_punctuate {
	# The Guide's model, not whisper, restores sentence punctuation and capital
	# letters to a dictated phrase. It is told to change nothing but punctuation;
	# the word guard below enforces that, so a model that rewrites the phrase
	# cannot lose what the person said. Returns (text, error).
	my ($text) = @_;
	return (undef, 'nothing to punctuate') unless defined $text && length $text;
	return (undef, 'too long') if length($text) > 6000;
	my ($primary, $fallback) = &ai_role_models('help_assistant');
	return (undef, 'no guide model') unless $primary;
	my $system = 'You are the punctuation pass for dictated text in JawnOS. '
		. 'Return ONLY the same text with correct sentence punctuation, capitalisation and spacing. '
		. 'Never add, remove, reorder or reword anything: keep every word, name, number and filler exactly as given. '
		. 'Do not translate, do not explain, and do not wrap the answer in quotes. '
		. 'If the text is already correct, return it unchanged.';
	my ($out, $err) = &evaluation_model_call_with_fallback($primary, $fallback, $system, $text, &ai_role_thinking_effective('help_assistant'), 'help_assistant');
	return (undef, $err || 'no answer') if $err || !defined $out || !length $out;
	$out =~ s/^\s+|\s+$//g;
	$out =~ s/^["'`\x{201C}\x{201D}]+|["'`\x{201C}\x{201D}]+$//g;
	$out =~ s/\s+/ /g;
	return (undef, 'empty') unless length $out;
	my $norm = sub {
		my $s = shift;
		utf8::decode($s) if length $s && !utf8::is_utf8($s);
		$s = lc $s;
		$s =~ s/[^\p{L}\p{N}]+/ /g;
		$s =~ s/^\s+|\s+$//g;
		return $s;
	};
	return (undef, 'words changed') unless $norm->($text) eq $norm->($out);
	return ($out, undef);
}

sub voice_command_parse {
	# The words after the wake phrase, split into a verb and a target app. Only a
	# command that actually follows "hey jawn" counts, so a stray "start" in
	# conversation does nothing.
	#
	# $wake_optional is set for a clip that came from a wake-word capture: the
	# phrase was already consumed by the on-device trigger, so the transcript IS
	# the command and no "hey jawn" appears in it to match.
	my ($transcript, $wake_optional) = @_;
	my $low = lc($transcript || '');
	$low =~ s/[^a-z0-9 ]+/ /g;
	$low =~ s/\s+/ /g;
	my @w = split ' ', $low;
	my @rest;
	my $woke = 0;
	# The wake phrase is "hey jawn", matched as a pair: whisper mangles both
	# halves of it (hey -> hay/a/ay, jawn -> john/dawn/yawn), and requiring the two
	# together is what stops a lone "john"/"dawn" in stray speech from running a
	# command. The command is whatever follows the pair.
	my %hey  = map { $_ => 1 } qw/hey hay a ay eh hei hej heya/;
	my %jawn = map { $_ => 1 } qw/jawn jaun jauns jawns john johns jon dawn dawns down downs don dons dun yawn yawns yon/;
	for (my $i = 1; $i < @w; $i++) {
		next unless $jawn{$w[$i]} && $hey{$w[$i-1]};
		$woke = 1;
		@rest = @w[ $i + 1 .. $#w ];
		last;
	}
	if (!$woke && $wake_optional) {
		# a wake-word capture: the phrase was consumed on the watch, so treat the
		# whole transcript as the command
		$woke = 1;
		@rest = @w;
	}
	return { status => 'no_wake', said => $transcript } unless $woke && scalar @rest;
	my $verb = shift @rest;
	my %on  = map { $_ => 1 } qw/start begin open launch play run resume/;
	my %off = map { $_ => 1 } qw/stop end close finish pause halt quit/;
	my $want = $on{$verb} ? 'on' : $off{$verb} ? 'off' : undef;
	return { status => 'no_verb', verb => $verb, said => $transcript } unless $want;
	my $target = join ' ', @rest;
	$target =~ s/^\s+|\s+$//g;
	return { status => 'no_target', said => $transcript } unless length $target;
	return { status => 'ok', want => $want, target => $target, said => $transcript };
}

sub voice_command_apply {
	# Act on a command by the same writes a watch button makes - a toggle and a
	# start/stop appointment - but without touching the watch's own operator_door,
	# because voice is not a button press.
	my ($app, $want, $meta) = @_;
	my $now = &subs::rightNow();
	my $settings = &subs::settings_grabber({ app => $app }) || {};
	# The person is asking NOW. The clip's own stamp is when they started speaking,
	# and the watch's RTC can lag the house by minutes; feeding that to the toggle
	# write made the settings layer refuse it as "older than the stored toggle", so
	# "start email test" did nothing and the reply said so. The utterance stamp
	# still rides along on the clip for the note's own sort order (voice_note_store).
	my $written = &subs::setting_setter({ app => $app, setting => 'toggle', value => $want, timestamp => $now });
	my $db_data = {
		app => $app,
		server_time => $now,
		# a spoken movement starts now; a stale clip is not a scheduled start
		timestamp => $now,
		type => ($want eq 'on' ? 'start' : 'stop'),
		toggle => ($want eq 'on' ? 1 : 0),
		uuid => &subs::random_string_creator(21),
		duration => &subs::time_abbrev_translator($settings->{'duration'}),
		warranty => &subs::ago_calc(&subs::setting_grabber({ app => $app, setting => 'warranty' }) || &subs::setting_grabber({ app => 'me', setting => 'warranty' }), $now),
		project => $settings->{'t_project'},
		pos => $settings->{'pos'},
		seen => 'yes'
	};
	&Manager::appointment_writer(&subs::controller_builder(), $db_data);
	&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', $app, $db_data->{'uuid'})});
	# What the app now holds, read from the row this write landed on rather than
	# assumed: a device-less read can answer with a peer's synced row (the phone's
	# stale "off" made the wrist say a start that had just happened had failed), and
	# a refused write must not be reported as one that landed.
	my $state;
	if (ref $written eq 'HASH' && !$written->{'refused'}) {
		$state = $written->{'value'};
		if (defined $written->{'device'} && length $written->{'device'}) {
			my $read = &subs::setting_grabber({ app => $app, setting => 'toggle', device => $written->{'device'} });
			$state = $read if defined $read;
		}
	}
	$db_data->{'state'} = (defined $state && $state =~ /^\s*(?:1|on|true|yes)\s*$/i) ? 'on' : 'off';
	return $db_data;
}

sub voice_clip_shape {
	# What a received clip actually IS, in one log-safe line. "The watch's Rec did
	# nothing" has two very different causes - the bytes never arrived, or they
	# arrived as silence - and whisper's stock hallucination ("you",
	# "[BLANK_AUDIO]") cannot tell them apart. This reads the WAV header the watch
	# sends (IMA ADPCM or PCM) and counts the non-zero bytes in the data chunk, so
	# the next arrival says bytes=N wav=kind rate=R data=D nonzero=Z. A clip of
	# silence is all zeroes; good samples are not.
	my ($raw) = @_;
	my $n = defined $raw ? length $raw : 0;
	return 'bytes=0' unless $n;
	my $shape = 'bytes=' . $n;
	if ($n >= 44 && substr($raw, 0, 4) eq 'RIFF' && substr($raw, 8, 4) eq 'WAVE') {
		my ($fmt, $ch, $rate, $bits, $dlen, $doff) = (undef, undef, undef, undef, 0, 0);
		my $at = 12;
		while ($at + 8 <= $n) {
			my $id = substr($raw, $at, 4);
			my $len = unpack('V', substr($raw, $at + 4, 4));
			if ($id eq 'fmt ' && $at + 24 <= $n) {
				($fmt, $ch, $rate) = unpack('vvV', substr($raw, $at + 8, 8));
				$bits = unpack('v', substr($raw, $at + 22, 2));
			}
			elsif ($id eq 'data') {
				$doff = $at + 8;
				$dlen = $len;
				last;
			}
			$at += 8 + $len + ($len % 2);
		}
		my $kind = !defined $fmt ? 'wav?'
			: $fmt == 0x11 ? 'adpcm'
			: $fmt == 1 ? 'pcm'
			: 'fmt' . $fmt;
		$shape .= ' wav=' . $kind;
		$shape .= ' rate=' . $rate if defined $rate;
		$shape .= ' ch=' . $ch if defined $ch;
		$shape .= ' bits=' . $bits if defined $bits;
		if ($doff && $dlen && $doff <= $n) {
			my $avail = $n - $doff;
			my $probe = substr($raw, $doff, $dlen < $avail ? $dlen : $avail);
			$probe = substr($probe, 0, 65536) if length($probe) > 65536;
			my $copy = $probe;
			my $zeros = ($copy =~ tr/\x00//);
			$shape .= ' data=' . $dlen . ' nonzero=' . (length($probe) - $zeros) . '/' . length($probe);
		}
	}
	else {
		my $probe = substr($raw, 0, 65536);
		my $copy = $probe;
		my $zeros = ($copy =~ tr/\x00//);
		$shape .= ' raw nonzero=' . (length($probe) - $zeros) . '/' . length($probe);
	}
	return $shape;
}

sub voice_note_store {
	# A spoken clip with no wake word is not a failed command, it is a note: keep
	# the transcript so it turns up in the Notes app, to be sorted out later. This
	# is the whole 'audio that did not match the command word' path - the clip
	# already reached us (over BLE or WiFi), so nothing extra has to be collected.
	#
	# $at is the clip's own time (when the utterance began); the note is stamped
	# there, not at our processing time, so a note sorts where it was said.
	#
	# $device is the watch that recorded a Rec-button memo. When it is given, the
	# device keeps only its newest $VOICE_NOTE_LIMIT memos: the older rows are
	# tombstoned, not erased, so every peer learns they are gone. A note written
	# by hand names no device and is never counted or pruned here.
	my ($text, $at, $device) = @_;
	return unless defined $text;
	my $clean = $text;
	$clean =~ s/\s+/ /g;
	$clean =~ s/^\s+|\s+$//g;
	# whisper annotates non-speech as [BLANK_AUDIO] / (music) / [ Silence ]; with
	# those removed, a clip that actually said nothing is not a note
	my $spoken = $clean;
	$spoken =~ s/[\[\(][^\]\)]*[\]\)]//g;
	$spoken =~ s/\s+/ /g;
	$spoken =~ s/^\s+|\s+$//g;
	return unless length $spoken;
	# a single word, a clipped fragment, or a two-word noise is not a note: the
	# wake word already filters ", the room"; this keeps the rest of the mumbles out.
	my @words = split ' ', $spoken;
	if (scalar @words < 3) {
		$log->info('voice: note dropped (fewer than three words): "' . $clean . '"') if $log;
		return;
	}
	my $now = &subs::rightNow();
	# A plain note row, not an appointment: the Notes app reads this table, and the
	# server_time column rides the generic peer sync so the note still reaches
	# every machine. The device column carries the watch, which is what the memo
	# cap counts.
	my %row = (
		app => 'notes',
		timestamp => $at || $now,
		server_time => $now,
		text => $clean,
		uuid => &subs::random_string_creator(21)
	);
	$row{'device'} = $device if defined $device && length $device;
	# A failed write must not take the worker down with it: the watch is waiting
	# for voice_done, and a note that did not land has to say so in the log.
	my $stored = eval { &subs::db_insert('notes', \%row); 1 };
	unless ($stored) {
		$log->error('voice: note store failed (' . ($@ =~ s/\s+/ /gr) . ')') if $log;
		return;
	}
	&voice_note_prune($device) if defined $device && length $device;
	$log->info('voice: note stored (' . $clean . ')') if $log;
	return $clean;
}

sub voice_note_prune {
	# Keep the newest $VOICE_NOTE_LIMIT memos for one device. The rows are read
	# newest-first the way the app lists them, and everything past the limit is
	# tombstoned through the Notes domain's own delete, so the house and its peers
	# agree the old memos are gone without losing the row a peer may still hold.
	my ($device) = @_;
	return unless defined $device && length $device;
	my $rows = &subs::db_query(
		"select uuid from notes where device = ? and app = 'notes' "
		. "and coalesce(text, '') != '' and coalesce(ost, '') != ? "
		. "order by cast(coalesce(timestamp, '0') as integer) desc, "
		. "cast(coalesce(server_time, '0') as integer) desc",
		$device, &subs::notes_delete_marker()
	) || return;
	my $kept = 0;
	foreach my $row ( @{ $rows->hashes } ) {
		next if ++$kept <= $VOICE_NOTE_LIMIT;
		&subs::notes_tombstone($row->{'uuid'});
	}
	return $kept;
}

sub voice_clip_fresh {
	# One clip, one transcription. The watch streams a clip while it is being spoken
	# and still keeps the file as a fallback, so the same clip can legitimately
	# arrive twice (an ack lost, a link that died mid-stream); a second pass would
	# run the person's command twice. Keyed by the watch's own clip stamp.
	#
	# The claim is a marker file, not process memory: the BLE ingest runs in a
	# forked worker while /watch/voice runs in a request worker, so a map here
	# would see only its own process. O_CREAT|O_EXCL makes the create the race -
	# exactly one process wins it - and a marker older than the same 300 s window
	# the map used is pruned by mtime. The directory sits with the house's other
	# runtime markers under ~/.president, reached through subs::home() so a HOME
	# override lands in the same place whisper-want's marker does.
	my ($chip_id, $ts) = @_;
	return 1 unless $chip_id && $ts;
	my $key = $chip_id . '|' . $ts;
	my $now = time();
	my $dir = &subs::home('~/.president/voice-seen');
	eval { make_path($dir) } unless -d $dir;
	if (-d $dir && opendir(my $dh, $dir)) {
		# A marker past the window is no longer a duplicate: forget it, as the
		# in-memory sweep did.
		foreach my $name (readdir $dh) {
			next if $name eq '.' || $name eq '..';
			my $path = $dir . '/' . $name;
			my $mtime = (stat($path))[9] || 0;
			unlink $path if $now - $mtime > 300;
		}
		closedir $dh;
		my $file = $dir . '/' . &subs::path_name($key) . '.seen';
		my $fh;
		if (sysopen($fh, $file, O_CREAT | O_EXCL | O_WRONLY, 0600)) {
			close($fh);
			return 1;
		}
		if ($!{EEXIST}) {
			$log->info('voice: clip ' . $key . ' already handled; ignoring the duplicate');
			return 0;
		}
		# A marker that cannot be written (a read-only home, a full disk) must not
		# drop the clip: fall back to this process's map and say why.
		$log->error('voice: could not claim clip ' . $key . ' (' . $! . '); using memory');
	}
	delete $gb::voice_seen->{$_} for grep { $now - $gb::voice_seen->{$_} > 300 } keys %{ $gb::voice_seen || {} };
	if ($gb::voice_seen->{$key}) {
		$log->info('voice: clip ' . $key . ' already handled; ignoring the duplicate');
		return 0;
	}
	$gb::voice_seen->{$key} = $now;
	return 1;
}

sub voice_stream_chunk {
	# One chunk of the WiFi upload stream (the watch POSTs a clip while it is still
	# recording). Chunks are appended to a per-session file under
	# ~/.president/voice-stream, so a prefork watch worker can take the next chunk
	# on any process; the last chunk reads the assembly back, wraps it in the same
	# 60-byte IMA ADPCM WAV header the whole-clip path carries (adpcm_wav_wrap) and
	# hands it to the caller. Bounded on purpose: one chunk is at most 512 KB, one
	# session at most 4 MB, and a session abandoned mid-stream is swept after two
	# minutes so a dead watch cannot fill the home.
	#
	# Returns { status => 'ok', ... } for a chunk, { status => 'complete', wav =>
	# $bytes, ... } for the last one, and a non-'ok' status the route can turn into
	# a 4xx (so the watch keeps the whole-clip fallback) for anything unusable.
	my ($chunk, $meta) = @_;
	$meta ||= {};
	my $chip = defined $meta->{'chip_id'} ? $meta->{'chip_id'} : '';
	my $ts   = defined $meta->{'ts'} ? $meta->{'ts'} : '';
	my $session = defined $meta->{'session'} ? $meta->{'session'} : '';
	my $seq  = defined $meta->{'seq'} ? (0 + $meta->{'seq'}) : 0;
	my $last = $meta->{'last'} ? 1 : 0;
	$chunk = '' unless defined $chunk;
	return { status => 'bad_session' } unless $session =~ /\A[A-Za-z0-9_.-]{1,64}\z/ && length $chip && $ts =~ /\A\d{1,20}\z/;
	my $rate = (defined $meta->{'rate'} && $meta->{'rate'} =~ /\A(?:8000|16000|22050|32000|44100|48000)\z/)
		? 0 + $meta->{'rate'} : 8000;
	return { status => 'too_large' } if length($chunk) > 512 * 1024;
	my $dir = &subs::home('~/.president/voice-stream');
	eval { make_path($dir) } unless -d $dir;
	return { status => 'no_dir' } unless -d $dir;
	my $base = &subs::path_name($chip . '|' . $ts . '|' . $session);
	my $part = $dir . '/' . $base . '.part';
	my $meta_path = $dir . '/' . $base . '.meta';
	if (opendir(my $dh, $dir)) {
		my $now = time;
		foreach my $name (readdir $dh) {
			next if $name eq '.' || $name eq '..';
			my $path = $dir . '/' . $name;
			unlink $path if $now - ((stat($path))[9] || 0) > 120;
		}
		closedir $dh;
	}
	if ($seq == 0) {
		write_file($part, { binmode => ':raw' }, '');
		write_file($meta_path, encode_json({
			rate => $rate,
			voice => ($meta->{'voice'} // ''),
			chip_id => $chip,
			ts => $ts,
			t_arrival => ($meta->{'t_arrival'} || &subs::rightNow()),
			bytes => 0,
			chunks => 0,
		}));
	}
	return { status => 'no_session' } unless -f $part;
	my $info = eval { decode_json(read_file($meta_path)) } || {};
	my $have = -s $part || 0;
	if ($have + length($chunk) > 4 * 1024 * 1024) {
		# The session is over the cap: drop it now instead of holding the bytes
		# until the idle sweep, and answer 4xx so the watch falls back to the file.
		unlink $part;
		unlink $meta_path;
		return { status => 'too_large', bytes => $have };
	}
	if (length $chunk) {
		open(my $fh, '>>', $part) or return { status => 'write_failed' };
		binmode($fh);
		print {$fh} $chunk;
		close($fh);
		$have += length $chunk;
	}
	$info->{'bytes'} = $have;
	$info->{'chunks'} = (0 + ($info->{'chunks'} || 0)) + 1;
	$info->{'rate'} = $rate if $seq == 0;
	eval { write_file($meta_path, encode_json($info)) };
	my $result = {
		status => 'ok',
		bytes => $have,
		chunks => $info->{'chunks'},
		seq => $seq,
		last => $last,
		rate => ($info->{'rate'} || 8000),
		voice => ($info->{'voice'} // ''),
		t_arrival => ($info->{'t_arrival'} || &subs::rightNow()),
	};
	return $result unless $last;
	my $data = eval { read_file($part, binmode => ':raw') } // '';
	unlink $part;
	unlink $meta_path;
	return { status => 'empty', bytes => length($data) } unless length($data) > 100;
	# A firmware that sends whole WAV chunks instead of raw blocks is not wrapped
	# twice; anything else is the raw IMA ADPCM the watch's encoder emits.
	my $wav = (substr($data, 0, 4) eq 'RIFF') ? $data : &subs::adpcm_wav_wrap($data, $result->{'rate'});
	return {
		status => 'complete',
		wav => $wav,
		bytes => length($data),
		rate => $result->{'rate'},
		voice => $result->{'voice'},
		t_arrival => $result->{'t_arrival'},
		chunks => $result->{'chunks'},
	};
}

sub adpcm_wav_wrap {
	# The 60-byte header the watch's voice_compress_clip writes around these same
	# blocks, rebuilt here because a streamed clip arrives without it: IMA ADPCM,
	# mono, 1024-byte blocks of 2041 samples. ffmpeg reads it natively, so the
	# streamed and whole-clip paths meet at the very same file. The rate is the
	# clip's capture rate - 16 kHz when WiFi carried it, 8 kHz otherwise - and an
	# absent rate means 8 kHz, so an older watch's stream stays byte-identical.
	# The block layout is rate-independent; only this header follows the rate.
	my ($data, $rate) = @_;
	$rate = 8000 unless $rate;
	my ($block, $spb) = (1024, 2041);
	my $blocks = int(length($data) / $block);
	my $samples = $blocks * $spb;
	my $abps = int($rate * $block / $spb);
	my $head = 'RIFF' . pack('V', 52 + length($data)) . 'WAVE'
		. 'fmt ' . pack('V', 20) . pack('v', 0x11) . pack('v', 1)
		. pack('V', $rate) . pack('V', $abps) . pack('v', $block) . pack('v', 4)
		. pack('v', 2) . pack('v', $spb)
		. 'fact' . pack('V', 4) . pack('V', $samples)
		. 'data' . pack('V', length($data));
	return $head . $data;
}

sub voice_clip_ack {
	# The clip was transcribed and filed, so the watch no longer needs its local
	# copy: tell it over the bridge to drop the file (/voice.wav). Keyed by the
	# clip's own timestamp so an ack that arrives after the watch has started a
	# new capture cannot delete the newer clip.
	my ($meta) = @_;
	return unless $meta && $meta->{'chip_id'};
	&subs::bluetooth_sender_async({
		intent => 'com.jawn.president.bt.connect',
		chip_id => $meta->{'chip_id'},
		edt => $meta->{'edt'} || 'watch',
		# echo the watch's own clock (seconds), which voice_ingest parks in ts_watch
		# while ts carries the normalized ms everything else reads
		message => { type => 'voice_done', ts => (0 + ($meta->{'ts_watch'} || $meta->{'ts'} || 0)) }
	});
}

sub guide_set_message {
	# Set a message to the Guide: a transcript the house heard addressed to it (a
	# wake-word capture, or a clip that opened with the phrase) is put into the
	# Guide's chat, so the spoken message is there to read and the Guide answers it
	# in the conversation - alongside the spoken answer voice_brain sends back to
	# the device. The Guide's window may not be open; the push is a no-op then.
	# A plain command ('start email test') never comes through here: that is a
	# movement, not a message for the Guide.
	my ($text, $meta) = @_;
	return unless defined $text && length $text;
	&Websocket::send('tab', {
		console => &Websocket::console_command('helpChatIngest', $text),
	});
	return 1;
}

sub json_from_model {
	# A model's reply parsed as JSON. A model call hands back Perl characters
	# (already UTF-8 decoded), but Mojo::JSON::decode_json wants UTF-8 bytes: one
	# em dash or curly apostrophe makes the decode die, and callers that wrap it
	# in eval read that as "nothing". Encode to bytes first; fall back to a
	# braced substring when the model wrapped the object in prose.
	my ($out) = @_;
	return undef unless defined $out && length $out;
	my $decode = sub {
		my ($s) = @_;
		return undef unless defined $s && length $s;
		my $bytes = $s;
		utf8::encode($bytes) if utf8::is_utf8($bytes);
		return eval { decode_json $bytes };
	};
	my $parsed = $decode->($out);
	$parsed = $decode->($1) if !$parsed && $out =~ /(\{.*\})/s;
	# A model that answers with a single-quoted object is not JSON, but a
	# conversational action still names the words to say. Pull them out rather
	# than showing the object to the person.
	if (!$parsed && $out =~ /['"]action['"]\s*:\s*['"](say|ask|done)['"]/) {
		my $verb = $1;
		my $text = '';
		if ($out =~ /['"]text['"]\s*:\s*(['"])(.*)\1\s*[,}]/s) {
			$text = $2;
			$text =~ s/\\n/\n/g;
			$text =~ s/\\t/\t/g;
			$text =~ s/\\(['"\\])/$1/g;
		}
		$parsed = { action => $verb };
		$parsed->{'text'} = $text if length $text;
	}
	return $parsed;
}

sub voice_brain {
	# The voice assistant's brain: an utterance addressed to us that is not a
	# plain start/stop command goes to the guide's action vocabulary, so a spoken
	# request can act (make an appointment, play something), answer aloud, or ask
	# back. The guide's own model reads it; the verbs offered are only the ones a
	# voice turn can carry out (there is no screen and no follow-up turn).
	#
	#   $text  the transcript. For a wake-word capture the phrase was already
	#          consumed on the watch; for a VAD capture it opens with the phrase.
	#   $meta  { edt, chip_id, ts, voice } - ts is when the utterance began (the
	#          wake word), voice is the capture mode ('vad' or a wake phrase).
	#
	# Return a hashref { handled => 1, ... } to claim the utterance: the caller
	# then acks the clip and stops. Return undef and the caller files it as a
	# note. Must keep the database handle it was given: no forking here beyond
	# say_it's own child, which touches no database.
	my ($text, $meta) = @_;
	$meta ||= {};
	return undef unless defined $text && length $text;
	# A reply to a watch-addressed utterance lands on the watch (text on screen,
	# the spoken answer over its speaker); any other utterance speaks locally.
	my $reply = sub {
		my ($speech) = @_;
		return unless defined $speech && length $speech;
		if (($meta->{'chip_id'} || '') ne '') {
			&subs::watch_reply($meta, $speech);
		}
		else {
			&subs::say_it($speech);
		}
	};
	# The guide's own model (Configure -> Plat); without one the caller keeps the
	# note fallback. A voice turn has to answer in seconds, and the guide's chat
	# model can be a large cloud one (gemma4:cloud measured 147 s for one turn),
	# so the role's fast fallback is tried first - or a voice_assistant model when
	# one is set - with the guide's model as that call's own fallback.
	my ($model, $fallback) = &subs::ai_role_models('help_assistant');
	return undef unless $model;
	my $fast = &subs::setting_grabber({ app => 'mail', setting => 'voice_assistant' });
	$fast = ($fallback && $fallback ne $model) ? $fallback : '' unless defined $fast && length $fast;
	my %voice_verbs = map { $_ => 1 } qw/say ask done measure where_when create play_music open_app alias unalias/;
	my $system = &help::actions_prompt(\%voice_verbs) . "\n\n";
	$system .= "This came in as a spoken command to the person's watch, transcribed on-device: "
		. "words may be misheard, and there is no follow-up turn - when the intent is clear, act "
		. "or answer; do not reply with a question. Keep spoken answers to one or two short sentences.\n";
	$system .= 'Right now it is ' . localtime(&subs::rightNow() / 1000)->strftime('%A, %B %d %Y, %I:%M%P') . ".\n";
	my $brain_started = &subs::rightNow();
	my ($out) = $fast
		? &subs::evaluation_model_call_with_fallback($fast, $model, $system, 'USER: ' . $text . "\n\nReply with the single JSON action.", &subs::ai_role_thinking_effective('help_assistant'), 'help_assistant')
		: &subs::evaluation_model_call_role('help_assistant', $system, 'USER: ' . $text . "\n\nReply with the single JSON action.", &subs::ai_role_thinking_effective('help_assistant'));
	$log->info('voice: brain call ' . (&subs::rightNow() - $brain_started) . 'ms on ' . ($fast || $model)
		. ' raw ' . (defined $out ? substr($out, 0, 240) : 'undef'));
	my $action = &json_from_model($out);
	if ($action && ref $action eq 'HASH' && $action->{'action'}) {
		$log->info('voice: brain action ' . $action->{'action'});
	}
	else {
		$log->info('voice: brain found no action in that reply');
	}
	return undef unless $action && ref $action eq 'HASH' && $action->{'action'};
	my $a = $action->{'action'};
	# Resolve the name before anything acts on it. A clear answer is rewritten
	# to the canonical app key; a tie becomes a spoken question, never a guess.
	$action = &subs::guide_resolve_action($action);
	if (($action->{'action'} || '') eq 'ask') {
		my $speech = $action->{'text'} || 'Which one did you mean?';
		$reply->($speech);
		$log->info('voice: brain asked "' . $speech . '"');
		return { handled => 1, action => 'ask', said => $speech };
	}
	$a = $action->{'action'};
	# A make/create is the Guide's write path: stage a proposal, and the
	# Confirmation Requirement decides whether the same breath saves it (the
	# Confirm tick in the Guide's associate; off = save without asking).
	if ($a eq 'create') {
		my $when = $action->{'when'};
		# no time named: the clip's own onset, so the appointment sits where the
		# person said it, not where whisper finished
		my $timestamp = (defined $when && length $when)
			? &subs::guide_resolve_when($when)
			: ($meta->{'ts'} || &subs::rightNow());
		my $staged = eval { &Manager::guide_stage_appointment(&subs::controller_builder(), {
			app => $action->{'app'}, type => $action->{'type'}, timestamp => $timestamp,
			title => $action->{'title'}, notes => $action->{'notes'},
		}) };
		return undef unless $staged && $staged->{'staged'};
		my $what = $staged->{'title'} || &subs::format_name($staged->{'app'}) || 'it';
		my $confirm = &subs::setting_grabber({ app => '__president', setting => 'guide_confirm', device => 'all' });
		if (defined $confirm && $confirm eq 'off') {
			my $promoted = eval { &Manager::guide_promote_staged(&subs::controller_builder(), $staged->{'staged'}) };
			if ($promoted && !$promoted->{'error'}) {
				my $speech = 'Saved ' . $what . '.';
				$reply->($speech);
				$log->info('voice: brain saved "' . $what . '"');
				return { handled => 1, action => 'create', saved => 1, said => $speech };
			}
		}
		my $speech = 'I staged ' . $what . '. Promote it in the Guide and it is saved.';
		$reply->($speech);
		$log->info('voice: brain staged "' . $what . '"');
		return { handled => 1, action => 'create', staged => $staged->{'staged'}, said => $speech };
	}
	# speaking verbs: answer out loud, nothing else to run
	if ($a eq 'say' || $a eq 'ask' || $a eq 'done') {
		my $speech = $action->{'text'} || '';
		return undef unless length $speech;
		$reply->($speech);
		$log->info('voice: brain said "' . $speech . '"');
		return { handled => 1, action => $a, said => $speech };
	}
	# teaching a word for a thing is stored here; it is not a screen action
	if ($a eq 'alias' || $a eq 'unalias') {
		my $r = $a eq 'alias'
			? &subs::guide_alias_add($action->{'alias'}, $action->{'target'})
			: &subs::guide_alias_remove($action->{'alias'});
		my $speech = $r->{'text'} || ($r->{'ok'} ? 'Done.' : 'I could not do that.');
		$reply->($speech);
		$log->info('voice: brain ' . $a . ' "' . $speech . '"');
		return { handled => 1, action => $a, said => $speech };
	}
	# the acting verbs the server can run itself: measure/where read our own
	# records, play_music/open_app reach the open JawnOS tabs over the socket
	if ($a eq 'measure' || $a eq 'where_when' || $a eq 'play_music' || $a eq 'open_app') {
		my $obs = eval { &Manager::remote_command_execute(&subs::controller_builder(), $action) };
		return undef unless defined $obs && length $obs;
		$reply->($obs);
		$log->info('voice: brain ' . $a . ' (' . $obs . ')');
		return { handled => 1, action => $a, observation => $obs };
	}
	# anything else: undef lets the note fallback keep the transcript
	return undef;
}

# A voice clip is the moment before a spoken reply. Ask the Crew to warm a
# Piper model now, in the background, so the render after whisper and the Guide
# does not pay the model load - the whole point of a repeat reply being fast.
# Best effort only: the turn never waits on it, and a peer with piper is warmed
# exactly the same way as this machine's own demand loop.
sub voice_warm_piper {
	return 0 unless defined &crew::dispatch;
	# The warm-up is a child process. A platform without fork would run the
	# peer HTTP call inline and make the turn wait, so it keeps the cold path.
	return 0 unless JawnOS::Platform::use_fork();
	my $now = time();
	return 0 if $warm_piper_at && $now - $warm_piper_at < 20;
	$warm_piper_at = $now;
	# A machine with its own piper touches the marker here too, so its demand
	# loop starts even if the Crew dispatch below finds nothing to place.
	eval { &subs::piper_server_wanted(1) } if eval { length &subs::say_piper_binary() };
	&subs::subprocessor(sub {
		eval { &crew::dispatch('say.warm', {}); 1 };
	}, { name => 'say warm', fork => 1, args => {} });
	return 1;
}

sub voice_ingest {
	# Audio -> text -> action. The single entry both the WiFi route and the BLE
	# bridge funnel into; the caller says whether its bytes are the whole-clip file
	# or the stream, because which copy is the truth depends on what was recorded.
	my ($raw, $meta) = @_;
	$meta ||= {};
	# The watch stamps the clip with its own clock in epoch SECONDS
	# (timestamp_maker in jw.ino). Everything downstream - appointment_writer,
	# notes, guide_when_ms - wants epoch ms, so a bare seconds stamp filed the
	# appointment at the start of the epoch (a 'start email test' landed in 1970).
	# Normalize once here. The raw seconds ride along as ts_watch: the voice_done
	# ack must echo the watch's own clock, because the watch compares the echo
	# against voice_clip_ts - ms would never match and its clip would never delete.
	if (($meta->{'ts'} || 0) && (0 + $meta->{'ts'}) < 100000000000) {
		$meta->{'ts_watch'} = 0 + $meta->{'ts'};
		$meta->{'ts'} = $meta->{'ts_watch'} * 1000;
	}
	# Which copy of the clip is the truth differs by what was recorded. A memo has
	# two copies in flight (the always-on stream and the whole-clip file the watch
	# keeps as a fallback), and only the file is complete enough to be the
	# transcript: a streamed memo is deferred here, before whisper, before an ack,
	# so the file is the one that is filed. The trade a person must know: a memo
	# whose file never ships is not filed at all - but the watch retries the file,
	# and the stream no longer acks a memo, so nothing is deleted before it lands.
	my $mode   = $meta->{'voice'} || '';
	my $source = $meta->{'source'} || 'file';
	$meta->{'source'} = $source;
	# Arrival, before anything decides to drop the clip: source, mode, and what
	# the bytes actually are. This one line separates "never arrived" from
	# "arrived but silent" in the next Rec/Com report, which whisper's stock
	# hallucination alone cannot do.
	$log->info('voice: arrival source=' . $source
		. ' mode=' . (length($mode) ? $mode : '-')
		. ' chip=' . ($meta->{'chip_id'} // '-')
		. ' ts=' . ($meta->{'ts_watch'} // $meta->{'ts'} // '-')
		. ' ' . &subs::voice_clip_shape($raw)) if $log;
	# One ledger line per stage, so "it took 30 s" can be answered without
	# guessing. The watch stamps the clip when the person STARTED speaking
	# (ts), so since_onset is the wall clock the person actually feels; the
	# caller's t_arrival separates the network from whisper and the Guide.
	my $t0 = (defined $meta->{'t_arrival'} && $meta->{'t_arrival'})
		? $meta->{'t_arrival'} : &subs::rightNow();
	my $timing = sub {
		my ($stage, $extra) = @_;
		my $now = &subs::rightNow();
		my $onset = (defined $meta->{'ts'} && $meta->{'ts'}) ? ($now - $meta->{'ts'}) : undef;
		$log->info('voice: timing stage=' . $stage
			. ' chip=' . ($meta->{'chip_id'} // '-')
			. ' source=' . $source
			. ' since_onset=' . (defined $onset ? $onset : '-') . 'ms'
			. ' since_arrival=' . ($now - $t0) . 'ms'
			. ((defined $extra && length $extra) ? ' ' . $extra : ''));
	};
	if ($mode eq $VOICE_NOTE_MODE && $source eq 'stream') {
		$log->info('voice: memo streamed; waiting for the whole-clip file (chip=' . ($meta->{'chip_id'} // '-') . ')') if $log;
		return { status => 'deferred' };
	}
	# A command is the opposite: whichever copy arrives first wins. Claim the clip
	# once here, before paying for whisper - the same clip over both transports (a
	# WiFi file after a BLE stream, or the reverse) would otherwise run the
	# person's command twice. A memo is not claimed: its file still follows the
	# deferred stream above and must be allowed through.
	if ($mode ne $VOICE_NOTE_MODE
		&& !&subs::voice_clip_fresh($meta->{'chip_id'}, $meta->{'ts'})) {
		$log->info('voice: duplicate clip dropped (chip=' . ($meta->{'chip_id'} // '-')
			. ' mode=' . $mode . ' source=' . $source . ')') if $log;
		return { status => 'duplicate' };
	}
	if ($mode ne $VOICE_NOTE_MODE) {
		&subs::voice_warm_piper();
	}
	my $text = &subs::whisper_transcribe($raw, undef, $meta->{'edt'} || 'watch');
	if (!$text) {
		$log->info('voice: stt empty (chip=' . ($meta->{'chip_id'} // '-')
			. ' mode=' . ($mode || '-') . ' source=' . $source . ')') if $log;
		$timing->('silence');
		return { status => 'silence' };
	}
	$timing->('asr');
	$log->info('voice: heard "' . $text . '"');
	# The watch's Rec button records a memo, not a command: file it in Notes and
	# stop. It is the one path that turns speech into a note now.
	if ($mode eq $VOICE_NOTE_MODE) {
		if (&subs::voice_note_store($text, $meta->{'ts'}, $meta->{'chip_id'})) {
			&Websocket::send('tab', { console => &Websocket::console_command('notesReload')});
			&subs::voice_clip_ack($meta);
			$timing->('note');
			return { status => 'note', said => $text };
		}
		$log->info('voice: note not stored ("' . $text . '")') if $log;
		$timing->('note_empty');
		return { status => 'note_empty', said => $text };
	}
	# A wake-word capture already consumed the phrase on the watch, so its
	# transcript is the command itself; a VAD capture must still open with the
	# phrase, so a stray "start" in the room does nothing. Command first: a
	# recognised start/stop with a target we know runs exactly as before. Anything
	# else addressed to us goes to the Guide - only the Rec button makes a note.
	my $wake_optional = ($mode ne '' && $mode ne 'vad');
	my $cmd = &subs::voice_command_parse($text, $wake_optional);
	my $addressed = $wake_optional || (($cmd->{'status'} || '') ne 'no_wake');
	if (($cmd->{'status'} || '') eq 'ok') {
		# Match the target against the apps the system actually knows (the settings
		# table), not the static known_appts list - the user's apps (breakfast,
		# music, ...) live in the database. Match the plain key first, then the
		# spelled-out name, so "Mr. Sun" and "mr sun" agree.
		my $app = &subs::unformat_name($cmd->{'target'});
		my $row = &subs::db_select('settings', undef, { app => $app })->hashes->[0];
		unless ($row) {
			foreach my $r ( @{ &subs::db_select('settings', undef, { setting => 'toggle' })->hashes } ) {
				next unless $r->{'app'};
				if (&subs::unformat_name($r->{'app'}) eq $app) { $app = $r->{'app'}; $row = $r; last; }
			}
		}
		if ($row) {
			my $applied = eval { &subs::voice_command_apply($app, $cmd->{'want'}, $meta) };
			unless (defined $applied) {
				$log->error('voice: apply failed for ' . $app . ': ' . ($@ || 'unknown'));
				return { status => 'apply_failed', app => $app, said => $text };
			}
			$log->info('voice: ' . $app . ' -> ' . $cmd->{'want'} . ' (' . $text . ')');
			# A Com clip is a spoken command, so a recognised movement answers
			# too: the watch shows the words and speaks them. The answer names
			# what the app actually holds now; a write that did not land (or a
			# stale peer) is reported instead of a claimed state.
			my $state = (ref $applied eq 'HASH' && defined $applied->{'state'})
				? $applied->{'state'} : $cmd->{'want'};
			my $speech = ($state eq $cmd->{'want'})
				? &subs::format_name($app) . ($state eq 'on' ? ' on.' : ' off.')
				: 'I could not ' . ($cmd->{'want'} eq 'on' ? 'start ' : 'stop ') . &subs::format_name($app) . '.';
			my $who = $meta->{'chip_id'} // '';
			if (length $who) { &subs::watch_reply($meta, $speech); }
			else { &subs::say_it($speech); }
			# The command consumed the clip: tell the watch to drop its copy. The
			# arrival receipt (voice_recv) stops the retry, but only voice_done
			# deletes the file - a command used to leave every clip on disk.
			&subs::voice_clip_ack($meta);
			$log->info('voice: command reply "' . $speech . '"') if $log;
			$timing->('command', 'app=' . $app . ' want=' . $cmd->{'want'});
			return { status => 'done', app => $app, want => $cmd->{'want'}, said => $text, reply => $speech };
		}
		# The verb was heard but no app matches the target: fall through to the
		# Guide so "start a conversation about the roof" is answered, not dropped.
		$log->info('voice: no app for "' . $cmd->{'target'} . '" (' . $text . ')');
	}
	else {
		$log->info('voice: ' . ($cmd->{'status'} || '?') . ' (' . $text . ')');
	}

	# Anything addressed to us that we could not run goes to the Guide. The clip
	# is consumed either way: the Guide's window may be closed and its model
	# absent, and that is not the watch's reason to keep retrying it.
	if ($addressed) {
		&subs::guide_set_message($text, $meta);
		my $brain = eval { &subs::voice_brain($text, $meta) };
		my $handled = ($brain && ref $brain eq 'HASH' && $brain->{'handled'}) ? 1 : 0;
		$log->info($handled ? 'voice: brain handled "' . $text . '"' : 'voice: guide left "' . $text . '"');
		&subs::voice_clip_ack($meta);
		$timing->($handled ? 'brain' : 'guide');
		return { status => ($handled ? 'brain' : 'guide'), said => $text,
			($handled ? %{$brain} : ()) };
	}
	# A VAD clip of the room (no phrase) is not addressed: nothing to do.
	$timing->('unaddressed');
	return $cmd;
}

sub event_duplicate {
	# True when this physical event was already applied a moment ago. Two bridge
	# radios (or an older board that ran both of its input scanners) can deliver
	# the same movement twice; acting on it twice is a toggle that flashes and a
	# relay that clicks. Key on the board, the component and the state, never on
	# the arrival time. A person cannot complete a full off/on cycle inside the
	# window, so a real second press is never swallowed.
	my ($key, $ttl) = @_;
	$ttl = 2 unless defined $ttl;
	my $now = time();
	foreach my $k ( keys %ble_event_seen ) {
		delete $ble_event_seen{$k} if $now - $ble_event_seen{$k} > 10;
	}
	return 1 if $ble_event_seen{$key} && $now - $ble_event_seen{$key} < $ttl;
	$ble_event_seen{$key} = $now;
	return 0;
}

1;
