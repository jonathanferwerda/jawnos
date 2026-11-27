# tests-for: perl/crew.pl lib/JawnOS/Domain/Say.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_misc3.pm
# covers:    say.render, the Crew job a machine with piper runs for one without
#            it. The watch's phone homebase is the Android app runtime: no glibc
#            piper, no python, so the spoken reply used to be text only. The job
#            is gated on the piper tool (binary AND a voice model), returns
#            8 kHz mono PCM so the caller writes or streams it exactly as its own
#            render would, and is capped so a runaway caller cannot fill the
#            job cache with base64.

use strict;
use warnings;
no warnings 'once';
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use MIME::Base64 qw(encode_base64 decode_base64);

require(root() . '/perl/crew.pl');
# The harness may already have loaded Say.pm through its module name (a
# different %INC key), so guard the path require to keep the output clean.
require(root() . '/lib/JawnOS/Domain/Say.pm') unless defined &subs::reply_wav_bytes;

my $kind = crew::job_kind('say.render');
ok($kind, 'the Crew registry knows say.render');
is_deeply($kind->{'needs'}, ['piper'], 'and gates it on a machine that can really speak');
is($kind->{'timeout'}, 60, 'a reply is seconds, so the job is bounded');
ok(ref $kind->{'handler'} eq 'CODE', 'and has a handler');

# The ability itself: binary AND model, read in LIST context (a scalar-context
# eval returns only the last element, which made every machine say no).
{
	no warnings 'redefine';
	local *subs::say_piper_argv = sub { return ('/opt/piper') };
	local *subs::say_piper_parts = sub { return (['/opt/piper'], [], '/voices/ljspeech.onnx', 22050) };
	is(crew::_piper_binary(), '/opt/piper', 'a machine with piper and a model reads as able to speak');
}
{
	no warnings 'redefine';
	local *subs::say_piper_argv = sub { return () };
	local *subs::say_piper_parts = sub { return () };
	is(crew::_piper_binary(), '', 'no binary is not able to speak');
}
{
	no warnings 'redefine';
	local *subs::say_piper_argv = sub { return ('/opt/piper') };
	local *subs::say_piper_parts = sub { return (['/opt/piper'], [], '', 22050) };
	is(crew::_piper_binary(), '', 'a binary without a voice model is not able to speak');
}

my $able = { cores => 4, load1 => 0.2, tools => { piper => 1 } };
ok(crew::can('say.render', $able), 'a machine with piper can run it');
ok(!crew::can('say.render', { cores => 4, load1 => 0.2, tools => { piper => 0 } }),
	'a machine without piper cannot');
ok(!crew::can('say.render', { cores => 4, load1 => 20, tools => { piper => 1 } }),
	'and a machine already loaded is not chosen for it');
ok(!crew::job_caches('say.render'), 'the audio result is not kept in the job cache');
ok(crew::job_caches('whisper.transcribe'), 'a small answer still is');

# The caller's side: decode the peer's PCM, or come back empty.
{
	no warnings 'redefine';
	local *crew::dispatch = sub {
		my ($kind_name, $payload) = @_;
		is($kind_name, 'say.render', 'the caller asks for the render job');
		is($payload->{'text'}, 'hello', 'with the words to say');
		return { ok => 1, result => { pcm_b64 => encode_base64('PEER-PCM', ''), rate => 8000 } };
	};
	is(subs::crew_say_render('hello'), 'PEER-PCM', 'the peer\'s PCM comes back decoded');
}
{
	no warnings 'redefine';
	local *crew::dispatch = sub { return { ok => 0, error => 'no peer has piper' } };
	is(subs::crew_say_render('hello'), undef, 'a refused job renders nothing');
}
{
	no warnings 'redefine';
	local *crew::dispatch = sub { return { ok => 1, result => {} } };
	is(subs::crew_say_render('hello'), undef, 'a result with no audio renders nothing');
}

# The handler's side: piper renders, and the wire carries only the PCM.
{
	no warnings 'redefine';
	local *subs::say_piper_parts = sub { return ([qw(/opt/piper)], [], '/voices/ljspeech.onnx', 22050) };
	local *subs::piper_pcm_8k = sub { return 'PEER-PCM' };
	my $out = crew::_job_say_render({ text => 'hello' });
	is($out->{'rate'}, 8000, 'the job returns the reply rate');
	is(decode_base64($out->{'pcm_b64'}), 'PEER-PCM', 'and the PCM itself');
}
{
	no warnings 'redefine';
	local *subs::say_piper_parts = sub { return () };
	my $ok = eval { crew::_job_say_render({ text => 'hello' }); 1 };
	ok(!$ok, 'a machine without piper refuses the job');
	like($@, qr/piper is not ready here/, 'and says why');
}
{
	no warnings 'redefine';
	local *subs::say_piper_parts = sub { return ([qw(/opt/piper)], [], '/voices/ljspeech.onnx', 22050) };
	my $ok = eval { crew::_job_say_render({ text => 'x' x 2500 }); 1 };
	ok(!$ok, 'a reply far past a sentence is refused');
	like($@, qr/too long/, 'so the job cache cannot hold megabytes');
}

done_testing();
