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
use Fcntl qw(:flock);
use File::Copy;
use File::Find;
use File::Path;
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
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

our %M;
our %Y;
our %ble_event_seen;
our $database;
our $device;
our $gb;
our $log;
our %m;

# Speech -> text through a cloud model. The transcription model (Configure -> Plat)
# is either Cloudflare's @cf/openai/whisper or an OpenAI-compatible /audio/
# transcriptions endpoint (Groq whisper-large-v3*, OpenAI whisper-1). '' on any
# failure, so the caller falls back to the local whisper.cpp pipeline.
sub ai_transcribe_cloud {
	my ($model, $raw, $lang) = @_;
	return '' unless $model && defined $raw && length $raw;
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
		return '' unless $account && $token;
		my $tx = $ua->post('https://api.cloudflare.com/client/v4/accounts/' . $account . '/ai/run/' . $model => {
			'Authorization' => 'Bearer ' . $token,
			'Content-Type' => 'application/json'
		} => json => { audio => encode_base64($raw, '') });
		return '' if $tx->error || !$tx->res->is_success;
		my $d = eval { $tx->res->json } || {};
		my $text = $d->{'result'}->{'text'} || $d->{'result'}->{'transcription'} || $d->{'result'};
		$text = '' if ref $text;
		return ($text || '');
	}
	# openai-compatible transcription: groq, openai, mistral (any provider whose
	# /audio/transcriptions speaks the same multipart shape)
	my ($provider, $real) = ('groq', $model);
	if ($model =~ /^([a-z]+):(.+)$/) { ($provider, $real) = ($1, $2); }
	my %ep = ( openai => 'https://api.openai.com/v1/audio/transcriptions', groq => 'https://api.groq.com/openai/v1/audio/transcriptions' );
	my $url = $ep{$provider} or return '';
	my %key = ( openai => 'openai_key', groq => 'groq_key' );
	my $key = $secret->($settings->{ $key{$provider} });
	return '' unless $key;
	my %form = (
		model => $real,
		file => { content => $raw, filename => 'clip.webm', 'Content-Type' => 'audio/webm' },
		response_format => 'json'
	);
	$form{'language'} = $lang if defined $lang && $lang =~ /^[a-z]{2,3}$/ && $lang ne 'auto';
	my $tx = $ua->post($url => {
		'Authorization' => 'Bearer ' . $key
	} => form => \%form);
	return '' if $tx->error || !$tx->res->is_success;
	my $d = eval { $tx->res->json } || {};
	return ($d->{'text'} || '');
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

# A warm server keeps the model loaded, so a clip skips the model load the
# one-shot CLI pays on every call. '' when it is not running or did not answer.
sub whisper_server_transcribe {
	my ($raw, $lang) = @_;
	return '' unless defined $raw && length $raw;
	my $ua = Mojo::UserAgent->new(connect_timeout => 2, inactivity_timeout => 30, request_timeout => 45);
	my $form = {
		file => { content => $raw, filename => 'clip.webm', 'Content-Type' => 'audio/webm' },
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
	my $bin   = &subs::home('~/whisper.cpp/build/bin/whisper-cli');
	# A command is a handful of words against a tiny vocabulary, so the fast tiny
	# model is plenty and a clip gets through much sooner, especially on the
	# phone; base is the fallback when tiny is not installed. A caller that knows
	# its clip needs more (a screened call's name) names the model it wants.
	my $model = ($wanted && -e $wanted) ? $wanted : &subs::home('~/whisper.cpp/models/ggml-tiny.bin');
	if (!defined $wanted && !-e $model) {
		$model = &subs::home('~/whisper.cpp/models/ggml-base.bin');
	}
	return '' unless -e $bin && -e $model;
	my $language = (defined $lang && $lang =~ /^[a-z]{2,3}$/ && $lang ne 'auto') ? ' -l ' . $lang : '';
	my $cmd = sprintf(
		'ffmpeg -nostdin -loglevel error -i - -blocksize 4096 -f wav -ar 16000 -ac 1 -acodec pcm_s16le - | %s -m %s%s --output-txt --file - 2>/dev/null',
		$bin, $model, $language
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

# --- Vosk: the free, offline recogniser ------------------------------------
# Vosk's Python package ships glibc wheels only, so it cannot run under Termux
# (Bionic); the gateway/laptop is where it lives. scripts/jawnos_deps.pl puts a
# venv and the small English model under ~/.local/share/jawnos/vosk. The runner
# is a JSON-lines helper because it is also the live stream the screening
# transcript reads (--raw --stream).
sub vosk_runner {
	# JAWNOS_VOSK_RUNNER and JAWNOS_VOSK_DIR exist for a worktree or a machine
	# that keeps the model on a bigger disk; the defaults are the installed tree.
	my $runner = $ENV{'JAWNOS_VOSK_RUNNER'};
	return $runner if defined $runner && length $runner;
	return &subs::home('~/jawnos/scripts/vosk_transcribe.py');
}
sub vosk_root {
	my $dir = $ENV{'JAWNOS_VOSK_DIR'};
	return $dir if defined $dir && length $dir;
	return &subs::home('~/.local/share/jawnos/vosk');
}

# The live reader sits beside the one-shot runner and takes the same model.
sub vosk_streamer {
	my $streamer = $ENV{'JAWNOS_VOSK_STREAMER'};
	return $streamer if defined $streamer && length $streamer;
	my $runner = &vosk_runner();
	$runner =~ s{[^/]+$}{vosk_stream.py};
	return $runner;
}

# The WebRTC bridge sits beside the other two readers and uses the same venv
# (aiortc lives there).
sub rtc_bridge {
	my $script = $ENV{'JAWNOS_RTC_BRIDGE'};
	return $script if defined $script && length $script;
	my $runner = &vosk_runner();
	$runner =~ s{[^/]+$}{rtc_bridge.py};
	return $runner;
}

sub vosk_python {
	my $venv = &vosk_root() . '/venv/bin/python3';
	return $venv if -x $venv;
	foreach my $dir ( split /:/, ($ENV{'PATH'} // '') ) {
		next unless defined $dir && length $dir;
		my $py = "$dir/python3";
		return $py if -x $py;
	}
	return '';
}

# A model is a directory named for its language (vosk-model-small-en-us-0.15,
# or a hand-made `fr`). A language asked for but not installed answers '', so
# the caller falls back to whisper rather than reading French with an English
# model; 'auto' takes English when it exists and the first model otherwise.
sub vosk_model_dir {
	my ($lang) = @_;
	$lang = lc($lang // '');
	$lang = '' unless $lang =~ /^[a-z]{2,3}$/;
	my $root = &vosk_root() . '/models';
	return '' unless -d $root;
	opendir(my $dh, $root) or return '';
	my @names = sort grep { !/^\./ && -d "$root/$_" } readdir $dh;
	closedir $dh;
	return '' unless @names;
	if (length $lang) {
		foreach my $n (@names) {
			return "$root/$n" if $n eq $lang || $n =~ /-$lang-/ || $n =~ /-$lang$/;
		}
		return '';
	}
	foreach my $n (@names) {
		return "$root/$n" if $n =~ /-en-/ || $n =~ /-en$/;
	}
	return "$root/$names[0]";
}

sub _python_has_vosk {
	# A venv with the wheel installed, or a system interpreter that already has
	# it. The import is the only proof: a bare python3 is not an install.
	my ($python) = @_;
	return 0 unless $python;
	require IPC::Open3;
	require Symbol;
	my ($in, $out, $err);
	$err = Symbol::gensym();
	my $pid = eval { IPC::Open3::open3($in, $out, $err, $python, '-c', 'import vosk') };
	return 0 unless $pid;
	close $in;
	do { local $/; <$out> };
	close $out;
	do { local $/; <$err> };
	close $err;
	waitpid($pid, 0);
	return $? == 0 ? 1 : 0;
}

# The Plat page and the Crew abilities both ask this; one probe a minute is
# enough, and it keeps a page render from forking Python for every role.
our $vosk_probe;
sub vosk_available {
	my $now = time;
	return $vosk_probe->{'ok'} if $vosk_probe && $now - $vosk_probe->{'at'} < 60;
	my $ok = 0;
	if (-f &vosk_runner() && length &vosk_model_dir()) {
		$ok = &_python_has_vosk(&vosk_python());
	}
	$vosk_probe = { at => $now, ok => $ok };
	return $ok;
}

sub vosk_transcribe {
	# A whole clip through Vosk. Raw audio bytes in (any container ffmpeg reads),
	# the transcript out; '' when Vosk is not installed, its model for this
	# language is missing, or it heard nothing.
	my ($raw, $lang) = @_;
	return '' unless defined $raw && length $raw;
	my $runner = &vosk_runner();
	my $python = &vosk_python();
	my $model  = &vosk_model_dir($lang);
	return '' unless -f $runner && $python && length $model;
	require IPC::Open3;
	require Symbol;
	my ($in, $out, $err);
	$err = Symbol::gensym();
	my $pid = eval {
		IPC::Open3::open3($in, $out, $err, $python, $runner,
			'--model', $model, '--lang', (defined $lang ? $lang : ''));
	};
	return '' unless $pid;
	binmode($in);
	print {$in} $raw;
	close($in);
	my $output = do { local $/; <$out> // '' };
	close($out);
	close($err);
	waitpid($pid, 0);
	my ($line) = split /\n/, $output;
	my $d = eval { decode_json($line) } || {};
	return '' if $d->{'error'};
	my $text = $d->{'text'} // '';
	$text =~ s/\r//g;
	$text =~ s/^\s+|\s+$//g;
	$text =~ s/\n+/ /g;
	return $text;
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
	# model. A new engine is one more line here and its own option on the Plat
	# page (templates/configure/plat_setting_list.html.ep).
	my ($value) = @_;
	return \&vosk_transcribe          if ($value // '') eq 'local:vosk';
	return \&whisper_local_transcribe if ($value // '') eq 'local:whisper.cpp';
	return undef;
}

sub whisper_transcribe {
	# Speech -> text. The transcription role names a primary and a fallback,
	# tried in that order; either may be a local engine (Vosk, whisper.cpp) or a
	# cloud model. whisper.cpp is always the last resort when it is not already
	# in the list, so a role that names only Vosk still has a free path when the
	# Vosk model for the language is missing. Raw audio bytes in (any container
	# ffmpeg reads), the transcript out. '' on any failure or on a stock silence
	# line, so a caller only has to check for text. $lang is the keyboard
	# layout's language ('fr', 'hi', ...); 'auto' lets the engine decide.
	my ($raw, $lang) = @_;
	return '' unless $raw;
	my ($primary, $fallback) = &ai_role_models('transcription_assistant');
	my @order = grep { defined && length } ($primary, $fallback);
	my %seen;
	foreach my $m (@order) {
		next if $seen{$m}++;
		my $local = &transcribe_local_engine($m);
		my $text = $local ? $local->($raw, $lang) : &ai_transcribe_cloud($m, $raw, $lang);
		next if $text && &subs::voice_silence_hallucination($text);
		return $text if $text;
	}
	return '' if grep { $_ eq 'local:whisper.cpp' } @order;
	return &whisper_local_transcribe($raw, $lang);
}

sub whisper_name_transcribe {
	# The one thing a screened call leaves is who called, and the words are a
	# handful over a narrowband 8 kHz link. The tiny model that keeps dictation
	# fast read one such clip as "Listen strong." where base read "This is John."
	# - through ffmpeg, sox and miniaudio alike - and base still answers in
	# seconds over a clip this short. So the name takes base and the CLI, and the
	# warm server's model is left to the keyboard. What comes back is the words as
	# heard; the caller is filed under name_from_transcript of them, and the raw
	# line is kept beside it because a surname over this link is often only
	# close. '' when nobody spoke.
	my ($raw, $lang) = @_;
	return '' unless defined $raw && length $raw;
	my $base = &subs::home('~/whisper.cpp/models/ggml-base.bin');
	my $text = -e $base
		? &whisper_cli_transcribe($raw, $lang || 'auto', $base)
		: &whisper_transcribe($raw, $lang || 'auto');
	return '' if !length $text || &voice_silence_hallucination($text);
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
	$name =~ s/^\s*(?:this is|that'?s|it'?s|i'?m|i am|my name is|you'?re speaking (?:to|with)|speaking to|here is|call me)\s+//i;
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
	&subs::setting_setter({ app => $app, setting => 'toggle', value => $want });
	my $db_data = {
		app => $app,
		server_time => $now,
		# the clip's own time (when the utterance began), not our processing time:
		# voice_ingest carries it as 'ts'
		timestamp => $meta->{'ts'} || $now,
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
	&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $db_data->{'uuid'} . '\');' });
	return $db_data;
}

sub voice_note_store {
	# A spoken clip with no wake word is not a failed command, it is a note: keep
	# the transcript so it turns up in the Notes app, to be sorted out later. This
	# is the whole 'audio that did not match the command word' path - the clip
	# already reached us (over BLE or WiFi), so nothing extra has to be collected.
	#
	# $at is the clip's own time (when the utterance began); the note is stamped
	# there, not at our processing time, so a note sorts where it was said.
	my ($text, $at) = @_;
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
	return unless scalar @words >= 3;
	my $now = &subs::rightNow();
	# A plain note row, not an appointment: the Notes app reads this table, and the
	# server_time column rides the generic peer sync so the note still reaches
	# every machine.
	&subs::db_insert('notes', {
		app => 'notes',
		timestamp => $at || $now,
		server_time => $now,
		text => $clean,
		uuid => &subs::random_string_creator(21)
	});
	$log->info('voice: note stored (' . $clean . ')');
	return $clean;
}

sub voice_clip_fresh {
	# One clip, one transcription. The watch streams a clip while it is being spoken
	# and still keeps the file as a fallback, so the same clip can legitimately
	# arrive twice (an ack lost, a link that died mid-stream); a second pass would
	# run the person's command twice. Keyed by the watch's own clip stamp.
	my ($chip_id, $ts) = @_;
	return 1 unless $chip_id && $ts;
	my $key = $chip_id . '|' . $ts;
	my $now = time();
	delete $gb::voice_seen->{$_} for grep { $now - $gb::voice_seen->{$_} > 300 } keys %{ $gb::voice_seen || {} };
	if ($gb::voice_seen->{$key}) {
		$log->info('voice: clip ' . $key . ' already handled; ignoring the duplicate');
		return 0;
	}
	$gb::voice_seen->{$key} = $now;
	return 1;
}

sub adpcm_wav_wrap {
	# The 60-byte header the watch's voice_compress_clip writes around these same
	# blocks, rebuilt here because a streamed clip arrives without it: IMA ADPCM,
	# 8 kHz mono, 1024-byte blocks of 2041 samples. ffmpeg reads it natively, so
	# the streamed and whole-clip paths meet at the very same file.
	my ($data) = @_;
	my ($block, $spb, $rate) = (1024, 2041, 8000);
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
		console => 'if (window.helpChatIngest) { helpChatIngest(' . encode_json($text) . '); }',
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
	my ($out) = $fast
		? &subs::evaluation_model_call_with_fallback($fast, $model, $system, 'USER: ' . $text . "\n\nReply with the single JSON action.", &subs::ai_role_thinking_effective('help_assistant'), 'help_assistant')
		: &subs::evaluation_model_call_role('help_assistant', $system, 'USER: ' . $text . "\n\nReply with the single JSON action.", &subs::ai_role_thinking_effective('help_assistant'));
	$log->info('voice: brain model ' . ($fast || $model) . ' raw ' . (defined $out ? substr($out, 0, 240) : 'undef'));
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

sub voice_ingest {
	# Audio -> text -> action. The single entry both the WiFi route and the BLE
	# bridge funnel into, so the two transports behave identically.
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
	my $text = &subs::whisper_transcribe($raw);
	return { status => 'silence' } unless $text;
	$log->info('voice: heard "' . $text . '"');
	# A wake-word capture already consumed the phrase on the watch, so its
	# transcript is the command itself; a VAD capture must still open with the
	# phrase, so a stray "start" in the room does nothing. If what we heard is not
	# a command we can run, keep it as a note rather than throw the clip away.
	my $mode = $meta->{'voice'} || '';
	my $wake_optional = ($mode ne '' && $mode ne 'vad');
	my $cmd = &subs::voice_command_parse($text, $wake_optional);
	if (($cmd->{'status'} || '') ne 'ok') {
		$log->info('voice: ' . ($cmd->{'status'} || '?') . ' (' . $text . ')');
		# Keep it as a note only when it was addressed to us: a wake-word capture
		# (the phrase was consumed on the watch) or a clip that opened with the
		# phrase. A VAD clip of the room, or a clipped fragment, is not a note.
		my $addressed = $wake_optional || (($cmd->{'status'} || '') ne 'no_wake');
		# addressed, but not a plain command: hand it to the voice brain before
		# settling for a note (see voice_brain). If no brain claims it, fall through
		if ($addressed) {
			# the message is set to the Guide as well as answered: it lands in the
			# Guide's chat (if one is open) so a spoken message is visible there
			&subs::guide_set_message($text, $meta);
			my $brain = eval { &subs::voice_brain($text, $meta) };
			if ($brain && ref $brain eq 'HASH' && $brain->{'handled'}) {
				$log->info('voice: brain handled "' . $text . '"');
				&subs::voice_clip_ack($meta);
				return { status => 'brain', said => $text, %{$brain} };
			}
		}
		if ($addressed && &subs::voice_note_store($text, $meta->{'ts'})) {
			# a note landed: refresh any open Notes window at once, and let the
			# watch drop its local copy of the clip
			&Websocket::send('tab', { console => 'notesReload();' });
			&subs::voice_clip_ack($meta);
		}
		return $cmd;
	}
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
	unless ($row) {
		$log->info('voice: no app for "' . $cmd->{'target'} . '" (' . $text . ')');
		return { status => 'no_app', said => $text, target => $cmd->{'target'} };
	}
	my $did = eval { &subs::voice_command_apply($app, $cmd->{'want'}, $meta); 1 };
	unless ($did) {
		$log->error('voice: apply failed for ' . $app . ': ' . ($@ || 'unknown'));
		return { status => 'apply_failed', app => $app, said => $text };
	}
	$log->info('voice: ' . $app . ' -> ' . $cmd->{'want'} . ' (' . $text . ')');
	return { status => 'done', app => $app, want => $cmd->{'want'}, said => $text };
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
