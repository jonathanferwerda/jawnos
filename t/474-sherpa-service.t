# tests-for: lib/JawnOS/Domain/Ai.pm lib/JawnOS/Domain/Loader.pm templates/configure/plat_setting_list.html.ep perl/help/topics_functions.pl
# covers:    sherpa-onnx as a local transcription service: bin/model discovery,
#           sherpa_available's 60-second probe, the English-only language rule,
#           the last-final JSON line, the ffmpeg -> jawn-asr pipeline, the role
#           wiring (sherpa falls through on a non-English or unavailable engine,
#           never dispatches to the whisper Crew job), the gateway refusing
#           sherpa as a live-call model, the Plat option and the help topic.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);

use JawnOSTest;

require(root() . '/lib/JawnOS/Domain/Ai.pm');

my $repo = root();
my $tmp  = tempdir(CLEANUP => 1);
my $bindir = "$tmp/bin";
my $model  = "$tmp/model";
my $weak   = "$tmp/model-incomplete";
my $args   = "$tmp/asr-args";
make_path($bindir, $model, $weak);

# A stand-in for the staged recogniser: it records the arguments it was given,
# drains the PCM ffmpeg (a fake below) sent, and prints a partial then a final
# line, exactly as jawn-asr does.
my $asr = "$tmp/jawn-asr";
write_file($asr, <<"SH");
#!/bin/sh
printf '%s\\n' "\$*" >> '$args'
cat >/dev/null
printf '%s\\n' '{"text":" after early","final":false}'
printf '%s\\n' '{"text":"AFTER EARLY NIGHTFALL","final":true}'
SH
chmod 0755, $asr;

# No real ffmpeg is needed: this one drains the clip and writes nothing, which
# closes the recogniser's stdin at once.
write_file("$bindir/ffmpeg", "#!/bin/sh\ncat >/dev/null\n");
chmod 0755, "$bindir/ffmpeg";

# A complete model bundle (tokens + one of each onnx) and an incomplete one
# (no joiner), so both halves of the presence check are exercised.
foreach my $name (qw(
	tokens.txt
	encoder-epoch-99-avg-1.int8.onnx
	decoder-epoch-99-avg-1.onnx
	joiner-epoch-99-avg-1.int8.onnx
)) {
	write_file("$model/$name", 'x');
}
foreach my $name (qw(
	tokens.txt
	encoder-epoch-99-avg-1.int8.onnx
	decoder-epoch-99-avg-1.onnx
)) {
	write_file("$weak/$name", 'x');
}

local $ENV{'JAWNOS_SHERPA_BIN'}       = $asr;
local $ENV{'JAWNOS_SHERPA_MODEL_DIR'} = $model;
local $ENV{'PATH'} = "$bindir:" . ($ENV{'PATH'} // '');

# ------------------------------------------------------------ discovery
is(subs::sherpa_bin(), $asr, 'an executable $JAWNOS_SHERPA_BIN is the binary');
is(subs::sherpa_model_dir(), $model, 'the model directory comes from its variable');
ok(subs::sherpa_model_present($model), 'tokens + encoder + decoder + joiner is a model');
ok(!subs::sherpa_model_present($weak), 'a bundle without a joiner is not a model');
ok(!subs::sherpa_model_present("$tmp/nope"), 'and neither is a missing directory');

{
	local $ENV{'JAWNOS_SHERPA_MODEL_DIR'} = $weak;
	$subs::sherpa_probe = undef;
	ok(!subs::sherpa_available(), 'a binary with an incomplete model is not available');
}

$subs::sherpa_probe = undef;
ok(subs::sherpa_available(), 'a binary and a complete model are an available engine');
{
	local $ENV{'JAWNOS_SHERPA_MODEL_DIR'} = $weak;
	ok(subs::sherpa_available(), 'the availability probe is cached for a minute');
	$subs::sherpa_probe = undef;
	ok(!subs::sherpa_available(), 'and is recomputed once the cache is cleared');
}

# ------------------------------------------------------------ the language rule
ok(subs::sherpa_language_ok(undef), 'no language is English enough for the base model');
ok(subs::sherpa_language_ok(''), 'an empty language too');
ok(subs::sherpa_language_ok('auto'), 'auto is the keyboard not choosing');
ok(subs::sherpa_language_ok('en'), 'en');
ok(subs::sherpa_language_ok('en-US'), 'and en-*');
ok(!subs::sherpa_language_ok('fr'), 'fr is not');
ok(!subs::sherpa_language_ok('english'), 'nor a word that only starts with en');

# ------------------------------------------------------------ the engine choice
is(ref(subs::transcribe_local_engine('local:sherpa')), 'CODE', 'sherpa is a local engine');
is(ref(subs::transcribe_local_engine('local:whisper.cpp')), 'CODE', 'whisper.cpp is still one');
is(subs::transcribe_local_engine('@cf/openai/whisper'), undef, 'a cloud model is not local');

# ------------------------------------------------------------ the JSON
is(subs::sherpa_final_text(
	qq({"text":"first final","final":true}\n{"text":"the last one","final":true}\n)
), 'the last one', 'the last final line is the take');
is(subs::sherpa_final_text(
	qq({"text":"partial one","final":false}\n{"text":"partial two","final":false}\n)
), 'partial two', 'without a final line the last result is used');
is(subs::sherpa_final_text(''), '', 'no output is no text');

# ------------------------------------------------------------ English end to end
unlink $args;
my $english = subs::sherpa_local_transcribe('RIFF-not-really', 'en');
is($english, 'AFTER EARLY NIGHTFALL', 'an English clip returns the final line, trimmed');
ok(-e $args, 'the recogniser was started');
my $called = -e $args ? read_file($args) : '';
like($called, qr/--model-dir \Q$model\E/, 'with the model directory');
like($called, qr/--pcm-stdin/, 'and reading PCM on stdin');

# ------------------------------------------------------------ non-English
unlink $args;
is(subs::sherpa_local_transcribe('RIFF-not-really', 'fr'), '',
	'a non-English clip is not transcribed by sherpa');
ok(!-e $args, 'and the binary is never started');

# ------------------------------------------------------------ the Plat Test
$subs::sherpa_probe = undef;
{
	my ($ok, $msg) = subs::ai_transcribe_test('local:sherpa');
	is($ok, 1, 'the Test passes when the engine is ready');
	like($msg, qr/English only/, 'and says the model is English only');
}
{
	local $ENV{'JAWNOS_SHERPA_MODEL_DIR'} = $weak;
	$subs::sherpa_probe = undef;
	my ($ok, $msg) = subs::ai_transcribe_test('local:sherpa');
	is($ok, 0, 'the Test fails when the model is missing');
	like($msg, qr/not installed/, 'and says the engine is not installed');
}

# ------------------------------------------------------------ the gateway
# scripts/whisper_stream.py reads a live call, so sherpa is not a gateway engine.
{
	local *subs::transcription_role_for = sub { return 'transcription_ivr' };
	local *subs::ai_role_models = sub { return ('local:sherpa', '') };
	my (undef, $note) = subs::whisper_stream_model('ivr');
	like($note, qr/local:sherpa.*cannot read a call on this gateway.*base model/,
		'a sherpa role gets the existing gateway note instead of being accepted');
}
{
	local *subs::transcription_role_for = sub { return 'transcription_ivr' };
	local *subs::ai_role_models = sub { return ('local:whisper.cpp', '') };
	my (undef, $note) = subs::whisper_stream_model('ivr');
	is($note, '', 'whisper.cpp is still the gateway engine');
}

# ------------------------------------------------------------ the role wiring
# A non-English sherpa role falls through to the role's fallback, and the sherpa
# binary is not started; the whisper Crew job is never handed the clip.
{
	local *subs::transcription_role_for = sub { return 'transcription_assistant' };
	local *subs::ai_role_models = sub { return ('local:sherpa', '@cf/openai/whisper') };
	local *subs::sherpa_available = sub { return 1 };
	local *subs::whisper_peer_transcribe = sub { die 'a sherpa clip is not a whisper job' };
	local *subs::ai_transcribe_cloud = sub { return 'the cloud heard this' };
	unlink $args;
	is(subs::whisper_transcribe('RIFF-not-really', 'fr'), 'the cloud heard this',
		'a non-English sherpa role falls through to the fallback');
	ok(!-e $args, 'and sherpa is not started');
}

# An unavailable sherpa is the same fall-through.
{
	local *subs::transcription_role_for = sub { return 'transcription_assistant' };
	local *subs::ai_role_models = sub { return ('local:sherpa', '@cf/openai/whisper') };
	local *subs::sherpa_available = sub { return 0 };
	local *subs::ai_transcribe_cloud = sub { return 'the cloud heard this' };
	unlink $args;
	is(subs::whisper_transcribe('RIFF-not-really', 'en'), 'the cloud heard this',
		'an unavailable sherpa falls through to the fallback');
	ok(!-e $args, 'and is not started');
}

# An English sherpa role answers through the real pipeline.
{
	local *subs::transcription_role_for = sub { return 'transcription_assistant' };
	local *subs::ai_role_models = sub { return ('local:sherpa', '') };
	local *subs::sherpa_available = sub { return 1 };
	unlink $args;
	is(subs::whisper_transcribe('RIFF-not-really', 'en'), 'AFTER EARLY NIGHTFALL',
		'an English clip is answered by sherpa');
	ok(-e $args, 'through the recogniser');
}

# With no fallback, a non-English sherpa role reaches the whisper last resort.
{
	local *subs::transcription_role_for = sub { return 'transcription_assistant' };
	local *subs::ai_role_models = sub { return ('local:sherpa', '') };
	local *subs::sherpa_available = sub { return 1 };
	local *subs::whisper_available = sub { return 0 };
	local *subs::whisper_peer_transcribe = sub { return 'the whisper peer heard this' };
	unlink $args;
	is(subs::whisper_transcribe('RIFF-not-really', 'fr'), 'the whisper peer heard this',
		'a non-English sherpa role still finds the whisper last resort');
	ok(!-e $args, 'sherpa itself is not started');
}

# ------------------------------------------------------------ the wiring on the page
my $plat = read_file("$repo/templates/configure/plat_setting_list.html.ep");
like($plat, qr/value="local:sherpa"/, 'the Plat page offers sherpa-onnx');
like($plat, qr/&subs::sherpa_available\(\)/, 'only when this machine has it');
like($plat, qr/\$setting ne 'transcription_ivr'/, 'but never for screened calls');
like($plat, qr/value="local:whisper\.cpp"/, 'whisper.cpp is still offered');

my $loader = read_file("$repo/lib/JawnOS/Domain/Loader.pm");
like($loader, qr/JawnOS::Domain::Ai' for qw\([^)]*\bsherpa_available\b/,
	'the new helpers are in the domain map');

my $help = read_file("$repo/perl/help/topics_functions.pl");
like($help, qr/sherpa-onnx.*English only/s, 'the help topic says sherpa is English only');
like($help, qr/falls through to the fallback and then to whisper\.cpp/,
	'and that a non-English language falls through to whisper');

done_testing();
