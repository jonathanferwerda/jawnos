# tests-for: lib/JawnOS/Domain/Evaluation.pm lib/JawnOS/Domain/Say.pm lib/JawnOS/Domain/Loader.pm
# covers:    How a spoken answer gets its sound when the machine cannot run
#            piper. The Android app runtime runs no glibc binary and ships no
#            python, so scripts/jawnos_deps.pl skips piper there by design - the
#            watch's homebase was answering in text only. The reply paths now
#            fall back to the OpenAI-compatible /audio/speech endpoint the
#            text_to_audio_assistant role names (groq:playai-tts), and the WiFi
#            decision trusts the clip's own source address instead of probing a
#            device server that may not answer.

use strict;
use warnings;
no warnings 'once';
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file);
use IO::Socket::INET ();

require(root() . '/lib/JawnOS/Domain/Say.pm') unless defined &subs::reply_wav_bytes;
require(root() . '/lib/JawnOS/Domain/Evaluation.pm') unless defined &subs::ai_text_to_speech_spec;

# --- the request an OpenAI-compatible speech endpoint expects ----------------
{
	my ($provider, $real, $url, $key, $payload) =
		&subs::ai_text_to_speech_spec('groq:playai-tts', 'hello there');
	is($provider, 'groq', 'a groq speech model names its provider');
	is($real, 'canopylabs/orpheus-v1-english', 'and the PlayAI setting maps to the current Orpheus model');
	like($url, qr{\Ahttps://api\.groq\.com/openai/v1/audio/speech\z}, 'at the OpenAI-compatible speech URL');
	is($key, 'groq_key', 'the Groq key is the one it needs');
	is($payload->{'model'}, 'canopylabs/orpheus-v1-english', 'the payload names the current Groq model');
	is($payload->{'input'}, 'hello there', 'and carries the words unchanged');
	is($payload->{'voice'}, 'hannah', 'with an Orpheus voice');
	is($payload->{'response_format'}, 'wav', 'and asks for a WAV');

	my (undef, $orealis, undef, undef, $orpheus) =
		&subs::ai_text_to_speech_spec('groq:canopylabs/orpheus-v1-english', 'hi');
	is($orealis, 'canopylabs/orpheus-v1-english', 'an explicit Orpheus model rides through');
	is($orpheus->{'voice'}, 'hannah', 'with the same default voice');

	my ($op, $oreal, $ourl, $okey, $opayload) =
		&subs::ai_text_to_speech_spec('gpt-4o-mini-tts', 'hi');
	is($op, 'openai', 'a bare model is OpenAI');
	is($opayload->{'voice'}, 'alloy', 'and gets OpenAI\'s default voice');

	my @none = &subs::ai_text_to_speech_spec('nope:nothing', 'hi');
	is(scalar(@none), 0, 'an unknown provider has no request');
	my @empty = &subs::ai_text_to_speech_spec('groq:playai-tts', '');
	is(scalar(@empty), 0, 'and empty words have none either');
}

# --- the WAV the watch pulls -------------------------------------------------
{
	my $pcm = 'P' x 3200;   # 0.2 s at 8 kHz mono s16
	my $wav = &subs::reply_wav_bytes($pcm);
	is(substr($wav, 0, 4), 'RIFF', 'the reply WAV starts with RIFF');
	is(substr($wav, 8, 4), 'WAVE', 'and names the WAVE form');
	is(length($wav), 44 + length($pcm), 'with a 44-byte header and the PCM after it');
	my $fmt = unpack('v', substr($wav, 20, 2));
	my $channels = unpack('v', substr($wav, 22, 2));
	my $rate = unpack('V', substr($wav, 24, 4));
	is($fmt, 1, 'the samples are PCM');
	is($channels, 1, 'mono');
	is($rate, 8000, 'at the rate the watch\'s speaker opens');
}

# --- piper first, the cloud only when it cannot speak -----------------------
{
	my @cloud_calls;
	{
		no warnings 'redefine';
		local *subs::say_piper_parts = sub { return (['/bin/true'], [], '/models/voice.onnx', 22050) };
		local *subs::piper_pcm_8k = sub { return 'PIPER-PCM' };
		local *subs::reply_speech_model = sub { push @cloud_calls, 1; return 'groq:playai-tts' };
		my ($pcm, $source) = &subs::reply_pcm_8k('hello');
		is($pcm, 'PIPER-PCM', 'a machine with piper renders with piper');
		is($source, 'piper', 'and says who spoke');
		is(scalar(@cloud_calls), 0, 'never asking the cloud');
	}
	{
		no warnings 'redefine';
		local *subs::say_piper_parts = sub { return () };   # the app runtime
		local *subs::crew_say_render = sub { return 'PEER-PCM' };
		local *subs::reply_speech_model = sub { push @cloud_calls, 1; return 'groq:playai-tts' };
		my ($pcm, $source, $err) = &subs::reply_pcm_8k('hello');
		is($pcm, 'PEER-PCM', 'a machine without piper first asks a peer that has it');
		is($source, 'piper@peer', 'and keeps the house voice');
		is($err, undef, 'with no error');
		is(scalar(@cloud_calls), 0, 'and never reaching the cloud');
	}
	{
		no warnings 'redefine';
		local *subs::say_piper_parts = sub { return () };   # the app runtime
		local *subs::crew_say_render = sub { return undef };
		local *subs::reply_speech_model = sub { return 'groq:playai-tts' };
		local *subs::ai_text_to_speech_result = sub { return ('MP3-BYTES', 'audio/mpeg', undef) };
		local *subs::transcode_pcm_8k = sub { return 'CLOUD-PCM' };
		my ($pcm, $source, $err) = &subs::reply_pcm_8k('hello');
		is($pcm, 'CLOUD-PCM', 'a machine without piper speaks through the cloud model');
		is($source, 'cloud:groq:canopylabs/orpheus-v1-english', 'and names the model that answered');
		is($err, undef, 'with no error');
	}
	{
		no warnings 'redefine';
		local *subs::say_piper_parts = sub { return () };
		local *subs::reply_speech_model = sub { return '' };
		my ($pcm, $source, $err) = &subs::reply_pcm_8k('hello');
		is($pcm, undef, 'no piper and no cloud model renders nothing');
		like($err, qr/no piper here and no speech model/, 'and says exactly why');
	}
}

# --- device_reply_wav really writes the file the route serves ---------------
{
	my $dir = tempdir(CLEANUP => 1);
	my @logged;
	{
		no warnings 'redefine';
		local *TLog::info = sub { push @logged, $_[1] };
		local $subs::log = bless {}, 'TLog';
		local *subs::home = sub { return $dir };
		local *subs::random_string_creator = sub { return 'ABCDEF0123456789abcdef' };
		local *subs::rightNow = sub { return 1_700_000_000_000 };
		local *subs::reply_pcm_8k = sub { return ('P' x 1600, 'cloud:groq:playai-tts', undef) };
		my $id = &subs::device_reply_wav('hello');
		is($id, 'ABCDEF0123456789abcdef', 'the reply gets an id');
		my $path = "$dir/reply_$id.wav";
		ok(-s $path, 'and its WAV exists where /watch/reply_audio looks');
		my $bytes = read_file($path, binmode => ':raw');
		is(substr($bytes, 0, 4), 'RIFF', 'the file is a WAV');
		ok(scalar(grep { /voice: reply audio cloud:/ } @logged), 'and the log names the speaker');
	}
	{
		no warnings 'redefine';
		local $subs::log = bless {}, 'TLog';
		local *TLog::info = sub { return 1 };
		local *subs::home = sub { return $dir };
		local *subs::random_string_creator = sub { return 'FEDCBA9876543210fedcba' };
		local *subs::reply_pcm_8k = sub { return (undef, undef, 'no piper here and no speech model is set') };
		is(&subs::device_reply_wav('hello'), undef, 'nothing rendered means no id');
		ok(!-e "$dir/reply_FEDCBA9876543210fedcba.wav", 'and no empty file is left behind');
	}
}

# --- the BLE reply streams the peer's PCM as say_audio parts ---------------
{
	my @sent;
	{
		no warnings 'redefine';
		local *TLog::info = sub { return 1 };
		local $subs::log = bless {}, 'TLog';
		local *subs::say_piper_parts = sub { return () };   # no piper here
		local *subs::reply_pcm_8k = sub { return ('P' x 9000, 'piper@peer', undef) };
		local *subs::bluetooth_stream_open = sub { return undef };
		local *subs::bluetooth_sender = sub { push @sent, $_[0]{'message'} };
		my $ok = &subs::watch_reply_stream({ chip_id => 'watch-chip', edt => 'watch' }, 'hello');
		is($ok, 1, 'a peer render reaches an off-WiFi watch');
		my @audio = grep { ($_->{'type'} || '') eq 'say_audio' } @sent;
		ok(scalar(@audio) >= 3, 'as a sequence of say_audio parts');
		is($audio[0]{'data'}{'seq'}, 0, 'starting at part zero');
		is($audio[0]{'data'}{'rate'}, 8000, 'at the rate the watch opens');
		is($audio[0]{'data'}{'total'}, 9000, 'and carrying the whole-clip length');
		is($audio[-1]{'data'}{'last'}, 1, 'the final part is marked last');
	}
	{
		@sent = ();
		no warnings 'redefine';
		local *TLog::info = sub { return 1 };
		local $subs::log = bless {}, 'TLog';
		local *subs::say_piper_parts = sub { return () };
		local *subs::reply_pcm_8k = sub { return (undef, undef, 'nothing to say') };
		local *subs::bluetooth_stream_open = sub { return undef };
		local *subs::bluetooth_sender = sub { push @sent, $_[0]{'message'} };
		my $ok = &subs::watch_reply_stream({ chip_id => 'watch-chip', edt => 'watch' }, 'hello');
		is($ok, 0, 'nothing rendered sends no parts');
		is(scalar(@sent), 0, 'and leaves the watch silent rather than half-spoken');
	}
}

# --- a WiFi clip proves the device is on the network ------------------------
{
	my $looked_up = 0;
	{
		no warnings 'redefine';
		local *subs::network_interface_reporter = sub { return { eth0 => { ip => '192.168.1.50' } } };
		local *subs::device_lister = sub { $looked_up++; return {} };
		local *subs::embedded_operator_door = sub { return '{}' };
		my $wifi = &subs::device_wifi_reply({
			chip_id => 'watch-chip', edt => 'watch', peer_ip => '192.168.1.77',
		});
		ok($wifi, 'a peer address on the LAN is enough to answer over WiFi');
		like($wifi->{'base'}, qr{\Ahttps://192\.168\.1\.50:\d*\z},
			'the base is this machine on that subnet');
	}
	{
		no warnings 'redefine';
		local *subs::network_interface_reporter = sub { return { eth0 => { ip => '192.168.1.50' } } };
		local *subs::device_lister = sub { return { ip => '192.168.1.77' } };
		local *subs::embedded_operator_door = sub { return '{}' };
		# a device server that takes the connect: the BLE path's probe pass.
		# Return a real filehandle, because the probe closes it with the builtin.
		local *IO::Socket::INET::new = sub { open(my $fh, '<', '/dev/null') or return; return $fh };
		my $wifi = &subs::device_wifi_reply({ chip_id => 'watch-chip', edt => 'watch' });
		ok($wifi, 'without a peer address the device list and its server decide');
	}
}

done_testing();
