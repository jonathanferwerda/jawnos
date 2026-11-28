# tests-for: scripts/piper_server.py lib/JawnOS/Domain/Say.pm lib/JawnOS/Domain/Loader.pm
# covers:    the Python warm server. The pip wheel's `piper` CLI exits after one
#            stdin line, so it cannot be the resident process; PiperVoice can.
#            The server binds before loading the model (a duplicate spawn then
#            costs no second load), answers /health, /render and /shutdown with
#            the same contract as the Perl CLI daemon, and returns 8 kHz PCM.

use strict;
use warnings;
no warnings 'once';
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Path qw(make_path);
use File::Slurp qw(write_file);
use File::Spec ();
use File::Temp qw(tempdir);
use IO::Socket::INET ();
use POSIX ();

require(root() . '/lib/JawnOS/Domain/Say.pm') unless defined &subs::reply_pcm_8k;

my $python = '';
foreach my $dir (split /:/, ($ENV{'PATH'} || '')) {
	if (-x "$dir/python3") { $python = "$dir/python3"; last }
}
my $ffmpeg = '';
foreach my $dir (split /:/, ($ENV{'PATH'} || '')) {
	if (-x "$dir/ffmpeg") { $ffmpeg = "$dir/ffmpeg"; last }
}

SKIP: {
	skip 'python3 is not installed', 11 unless $python;
	skip 'ffmpeg is not installed', 10 unless $ffmpeg;

	my $tmp = tempdir(CLEANUP => 1);
	make_path("$tmp/piper");
	write_file("$tmp/piper/__init__.py", <<'FAKE_PIPER');
import wave

class PiperVoice:
    @classmethod
    def load(cls, model_path, config_path=None, espeak_data_dir=None):
        return cls()

    def synthesize_wav(self, text, wav_file, syn_config=None):
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(8000)
        wav_file.writeframes(b'\x01\x02' * 800)
FAKE_PIPER
	my $model = "$tmp/voice.onnx";
	write_file($model, 'not really a model');
	my $script = root() . '/scripts/piper_server.py';
	ok(-f $script, 'the Python warm server is in scripts/');

	my $probe = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1, Proto => 'tcp');
	ok($probe, 'found a loopback port for the server');
	my $port = $probe->sockport;
	close $probe;
	local $ENV{'JAWNOS_PIPER_WARM_PORT'} = $port;

	my $pid = fork();
	if (!defined $pid) { fail('could not fork the Python server'); }
	elsif ($pid == 0) {
		local $ENV{'PYTHONPATH'} = $tmp;
		open(STDOUT, '>', File::Spec->devnull());
		open(STDERR, '>&', STDOUT);
		exec($python, $script, '--model', $model, '--port', $port,
			'--idle', 60, '--log', "$tmp/python-warm.log");
		POSIX::_exit(1);
	}
	my $health;
	for (1 .. 100) {
		$health = subs::piper_server_health();
		last if $health;
		select(undef, undef, undef, 0.1);
	}
	ok($health, 'the server answers /health');
	is($health->{'model'}, $model, 'and names the model it loaded');
	is($health->{'port'}, $port, 'on the port it was given');

	my $pcm = subs::piper_server_render('hello there', $model);
	ok(defined $pcm && length $pcm, 'a render returns 8 kHz PCM');
	ok(length($pcm) < 10_000, 'and only the sentence, not a stuck pipe');
	my $again = subs::piper_server_render('hello there', $model);
	ok(defined $again && length $again, 'and the next render keeps the model loaded');
	is(subs::piper_server_render('hello there', '/other/voice.onnx'), undef,
		'a render for a different voice is refused');

	is(subs::piper_server_shutdown(), 1, 'the server accepts a shutdown');
	my $gone = 0;
	for (1 .. 50) {
		$gone = 1 if waitpid($pid, POSIX::WNOHANG()) != 0;
		last if $gone;
		select(undef, undef, undef, 0.1);
	}
	ok($gone, 'and exits when asked');
	kill 'KILL', $pid if !$gone;
	waitpid($pid, 0) if !$gone;
}

done_testing();
