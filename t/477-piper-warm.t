# tests-for: lib/JawnOS/Domain/Say.pm lib/JawnOS/Domain/Ai.pm lib/JawnOS/Domain/Loader.pm perl/crew.pl perl/President.pl scripts/piper_server.pl
# covers:    the warm Piper reply path. piper the CLI loads its voice model on
#            every call, so a homebase paid that load inside each spoken reply.
#            A demand-started resident daemon keeps one piper process and answers
#            loopback HTTP with 8 kHz PCM; the reply path tries it first and
#            falls back to the one-shot. The phone (no piper, no python) asks
#            the Crew to warm a peer's piper while whisper and the Guide think,
#            and uses its own Android speech.synth-to-file when no peer answers.
#            The render source is part of the answer, so cold vs warm is
#            measurable in the log.

use strict;
use warnings;
no warnings 'once';
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Spec ();
use File::Temp qw(tempdir);
use IO::Socket::INET ();
use POSIX ();

require(root() . '/lib/JawnOS/Domain/Say.pm') unless defined &subs::reply_pcm_8k;
require(root() . '/lib/JawnOS/Domain/Ai.pm')   unless defined &subs::voice_warm_piper;
require(root() . '/lib/JawnOS/Domain/Evaluation.pm') unless defined &subs::ai_text_to_speech_spec;
require(root() . '/perl/crew.pl');

# --- the Crew job a voice clip uses to warm a peer --------------------------
{
	my $kind = crew::job_kind('say.warm');
	ok($kind, 'the Crew registry knows say.warm');
	is_deeply($kind->{'needs'}, ['piper'], 'and gates it on a machine that can speak');
	is($kind->{'timeout'}, 30, 'a warm-up is seconds, so the job is bounded');
	ok(!crew::job_caches('say.warm'), 'a warm-up answer is not cached');
	ok(crew::can('say.warm', { cores => 4, load1 => 0.1, tools => { piper => 1 } }),
		'a machine with piper can warm one');
	ok(!crew::can('say.warm', { cores => 4, load1 => 0.1, tools => { piper => 0 } }),
		'a machine without piper cannot');
}
{
	my @warm;
	no warnings 'redefine';
	local *subs::say_piper_parts = sub { return ([qw(/opt/piper)], [], '/voices/ljspeech.onnx', 22050) };
	local *subs::piper_server_warm = sub { push @warm, 1; return 1 };
	my $out = crew::_job_say_warm({});
	is($out->{'warm'}, 1, 'the warm job asks its own machine to start the voice');
	is($out->{'model'}, '/voices/ljspeech.onnx', 'and names the model it warmed');
	is(scalar(@warm), 1, 'exactly once');
}
{
	no warnings 'redefine';
	local *subs::say_piper_parts = sub { return () };
	my $ok = eval { crew::_job_say_warm({}); 1 };
	ok(!$ok, 'a machine without piper refuses the warm job');
	like($@, qr/piper is not ready here/, 'and says why');
}

# --- a voice clip dispatches it, best effort, without touching the turn -----
{
	my (@kinds, $ran);
	no warnings 'redefine';
	local $subs::warm_piper_at = 0;
	local *subs::subprocessor = sub {
		my ($body) = @_;
		$ran++;
		$body->();
		return;
	};
	local *crew::dispatch = sub { push @kinds, $_[0]; return { ok => 1 } };
	local *subs::say_piper_binary = sub { return '' };   # the phone
	is(subs::voice_warm_piper(), 1, 'a clip asks the Crew to warm a voice');
	is_deeply(\@kinds, ['say.warm'], 'with the say.warm kind');
	is($ran, 1, 'in a subprocess, so the turn does not wait for it');
	is(subs::voice_warm_piper(), 0, 'a second clip moments later does not ask again');
	is(scalar(@kinds), 1, 'the throttle keeps a burst to one warm-up');
}

# --- the phone's own speech-to-file bridge ----------------------------------
{
	my $dir = tempdir(CLEANUP => 1);
	my @calls;
	no warnings 'redefine';
	local *subs::home = sub { return $dir };
	local *subs::random_string_creator = sub { return 'ABCDEF0123456789' };
	local *subs::device_call = sub {
		my ($method, $args) = @_;
		push @calls, [ $method, $args ];
		open(my $fh, '>:raw', $args->{'path'}) or return undef;
		print {$fh} 'R' x 100;
		close $fh;
		return { ok => 1 };
	};
	local *subs::transcode_pcm_8k = sub { return 'DEVICE-PCM' };
	my $pcm = subs::device_tts_pcm_8k('hello there');
	is($pcm, 'DEVICE-PCM', 'a synthesized WAV becomes the reply PCM');
	is($calls[0][0], 'speech.synth', 'through the app\'s speech.synth method');
	is($calls[0][1]{'text'}, 'hello there', 'with the words');
	like($calls[0][1]{'path'}, qr{^\Q$dir\E/speech_[A-Za-z0-9]+\.wav$},
		'and a .wav path inside the manager\'s writable home');
	ok(!-e $calls[0][1]{'path'}, 'the temporary WAV is removed after transcoding');
}
{
	my $dir = tempdir(CLEANUP => 1);
	my @transcoded;
	no warnings 'redefine';
	local *subs::home = sub { return $dir };
	local *subs::random_string_creator = sub { return 'ABCDEF0123456789' };
	local *subs::device_call = sub {
		my (undef, $args) = @_;
		open(my $fh, '>:raw', $args->{'path'}) or return undef;
		print {$fh} 'short';
		close $fh;
		return { ok => 1 };
	};
	local *subs::transcode_pcm_8k = sub { push @transcoded, 1; return 'X' };
	is(subs::device_tts_pcm_8k('hello'), undef, 'a file at or below the WAV header renders nothing');
	is(scalar(@transcoded), 0, 'and is not sent to ffmpeg');
}
{
	my $dir = tempdir(CLEANUP => 1);
	no warnings 'redefine';
	local *subs::home = sub { return $dir };
	local *subs::random_string_creator = sub { return 'ABCDEF0123456789' };
	local *subs::device_call = sub { return undef };
	is(subs::device_tts_pcm_8k('hello'), undef, 'a bridge that refuses renders nothing');
}

# --- the order: local piper (warm then cold), device TTS, peer, cloud -------
{
	my $one_shot = 0;
	no warnings 'redefine';
	local *subs::say_piper_parts = sub { return ([qw(/opt/piper)], [], '/voices/ljspeech.onnx', 22050) };
	local *subs::piper_server_render = sub { return 'WARM-PCM' };
	local *subs::piper_pcm_8k = sub { $one_shot++; return 'PIPER-PCM' };
	my ($pcm, $source) = subs::reply_pcm_8k('hello');
	is($pcm, 'WARM-PCM', 'a resident piper speaks first');
	is($source, 'piper-warm', 'and the source says it was warm');
	is($one_shot, 0, 'the one-shot render is not paid for');
}
{
	my $one_shot = 0;
	no warnings 'redefine';
	local *subs::say_piper_parts = sub { return ([qw(/opt/piper)], [], '/voices/ljspeech.onnx', 22050) };
	local *subs::piper_server_render = sub { return undef };
	local *subs::piper_pcm_8k = sub { $one_shot++; return 'PIPER-PCM' };
	local *subs::device_setter = sub { return 'computer' };
	my ($pcm, $source) = subs::reply_pcm_8k('hello');
	is($pcm, 'PIPER-PCM', 'without a warm daemon the one-shot still speaks');
	is($source, 'piper', 'and the source says cold');
	is($one_shot, 1, 'exactly one cold render');
}
{
	my $peer = 0;
	no warnings 'redefine';
	local *subs::say_piper_parts = sub { return () };
	local *subs::device_setter = sub { return 'mobile' };
	local *subs::device_tts_pcm_8k = sub { return 'DEVICE-PCM' };
	local *subs::crew_say_render = sub { $peer++; return 'PEER-PCM' };
	local *subs::reply_speech_model = sub { return 'groq:playai-tts' };
	my ($pcm, $source) = subs::reply_pcm_8k('hello');
	is($pcm, 'DEVICE-PCM', 'a phone speaks through its own engine before asking a peer');
	is($source, 'device:tts', 'and names it');
	is($peer, 0, 'so the peer is not bothered');
}
{
	my $peer = 0;
	no warnings 'redefine';
	local *subs::say_piper_parts = sub { return () };
	local *subs::device_setter = sub { return 'mobile' };
	local *subs::device_tts_pcm_8k = sub { return undef };
	local *subs::crew_say_render = sub { $peer++; return 'PEER-PCM' };
	my ($pcm, $source) = subs::reply_pcm_8k('hello');
	is($pcm, 'PEER-PCM', 'a phone whose own engine refuses falls back to a peer');
	is($source, 'piper@peer', 'keeping the house voice');
	is($peer, 1, 'and asks once');
}
{
	my $device_called = 0;
	no warnings 'redefine';
	local *subs::say_piper_parts = sub { return () };
	local *subs::device_setter = sub { return 'computer' };
	local *subs::device_tts_pcm_8k = sub { $device_called++; return 'DEVICE-PCM' };
	local *subs::crew_say_render = sub { return undef };
	local *subs::reply_speech_model = sub { return 'groq:playai-tts' };
	local *subs::ai_text_to_speech_result = sub { return ('MP3', 'audio/mpeg', undef) };
	local *subs::transcode_pcm_8k = sub { return 'CLOUD-PCM' };
	my ($pcm, $source) = subs::reply_pcm_8k('hello');
	is($pcm, 'CLOUD-PCM', 'a desktop without piper still reaches the cloud');
	is($source, 'cloud:groq:canopylabs/orpheus-v1-english', 'and names the model');
	is($device_called, 0, 'never using the phone bridge on a desktop');
}

# --- the daemon's life: start, answer, reload, stop -------------------------
my $ffmpeg = '';
foreach my $dir (split /:/, ($ENV{'PATH'} || '')) {
	if (-x "$dir/ffmpeg") { $ffmpeg = "$dir/ffmpeg"; last }
}
SKIP: {
	skip 'ffmpeg is not installed, so the daemon cannot transcode', 10 unless $ffmpeg;

	my $tmp = tempdir(CLEANUP => 1);
	my $fake = "$tmp/fake-piper.pl";
	write_file($fake, <<'FAKE');
#!/usr/bin/env perl
use strict;
use warnings;
# The Python piper wheel writes the WAV but logs "Wrote ..." to stderr, and its
# stdout is silent. The daemon must find the file itself, not read a path.
my $dir = '.';
while (@ARGV) {
	my $a = shift @ARGV;
	$dir = shift @ARGV if defined $a && $a eq '-d';
}
my $n = 0;
while (defined(my $line = <STDIN>)) {
	next unless $line =~ /\S/;
	my $data = "\x01\x02" x 800;   # 0.1 s of 8 kHz mono s16
	my $hdr = 'RIFF' . pack('V', 36 + length $data) . 'WAVE'
		. 'fmt ' . pack('VvvVVvv', 16, 1, 1, 8000, 16000, 2, 16)
		. 'data' . pack('V', length $data);
	my $path = "$dir/fake-" . (++$n) . '.wav';
	open(my $fh, '>:raw', $path) or die "fake piper: $!";
	print {$fh} $hdr, $data;
	close $fh;
}
FAKE
	chmod 0755, $fake;
	my $model = "$tmp/voice.onnx";
	write_file($model, 'not really a model');
	my $log = "$tmp/piper-warm.log";
	my $script = root() . '/scripts/piper_server.pl';

	my $probe = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1, Proto => 'tcp');
	ok($probe, 'found a loopback port for the daemon');
	my $port = $probe->sockport;
	close $probe;
	local $ENV{'JAWNOS_PIPER_WARM_PORT'} = $port;

	my $pid = fork();
	if (!defined $pid) { fail('could not fork the daemon'); }
	elsif ($pid == 0) {
		open(STDOUT, '>', File::Spec->devnull());
		open(STDERR, '>&', STDOUT);
		exec($^X, $script, '--piper', $fake, '--model', $model,
			'--port', $port, '--idle', 60, '--log', $log);
		POSIX::_exit(1);
	}
	my $health;
	for (1 .. 60) {
		$health = subs::piper_server_health();
		last if $health;
		select(undef, undef, undef, 0.1);
	}
	ok($health, 'the daemon answers /health once piper is up');
	is((subs::piper_server_health() || {})->{'model'}, $model, 'and names the model it loaded');

	my $pcm = subs::piper_server_render('hello there', $model);
	ok(defined $pcm && length $pcm, 'a render returns 8 kHz PCM');
	my $again = subs::piper_server_render('hello there', $model);
	ok(defined $again && length $again, 'and the next render keeps the model loaded');
	is(subs::piper_server_render('hello there', '/other/voice.onnx'), undef,
		'a render for a different voice is refused, so a stale model never speaks');

	is(subs::piper_server_shutdown(), 1, 'the daemon accepts a shutdown');
	my $gone = 0;
	for (1 .. 50) {
		$gone = 1 if waitpid($pid, POSIX::WNOHANG()) != 0;
		last if $gone;
		select(undef, undef, undef, 0.1);
	}
	ok($gone, 'and exits when asked');
	kill 'KILL', $pid if !$gone;
	waitpid($pid, 0) if !$gone;

	# The daemon stops itself after its idle limit, so a Crew job on a peer
	# cannot leave a model resident for good.
	my $probe2 = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1, Proto => 'tcp');
	my $port2 = $probe2 ? $probe2->sockport : 0;
	close $probe2 if $probe2;
	$ENV{'JAWNOS_PIPER_WARM_PORT'} = $port2;
	my $pid2 = fork();
	if (!defined $pid2) { fail('could not fork the idle daemon'); }
	elsif ($pid2 == 0) {
		open(STDOUT, '>', File::Spec->devnull());
		open(STDERR, '>&', STDOUT);
		exec($^X, $script, '--piper', $fake, '--model', $model,
			'--port', $port2, '--idle', 2, '--max-age', 60, '--log', "$tmp/idle.log");
		POSIX::_exit(1);
	}
	my $up2 = 0;
	for (1 .. 60) {
		$up2 = 1 if subs::piper_server_health();
		last if $up2;
		select(undef, undef, undef, 0.1);
	}
	ok($up2, 'a second daemon starts too');
	my $self_exit = 0;
	for (1 .. 100) {
		$self_exit = 1 if waitpid($pid2, POSIX::WNOHANG()) != 0;
		last if $self_exit;
		select(undef, undef, undef, 0.1);
	}
	ok($self_exit, 'and stops itself after its idle limit');
	kill 'KILL', $pid2 if !$self_exit;
	waitpid($pid2, 0) if !$self_exit;
}

done_testing();
