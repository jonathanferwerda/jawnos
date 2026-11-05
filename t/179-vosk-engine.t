# tests-for: lib/JawnOS/Domain/Ai.pm perl/crew.pl scripts/jawnos_deps.pl scripts/vosk_transcribe.py templates/configure/plat_setting_list.html.ep
# covers:    Vosk is a local transcription engine the role can name (local:vosk),
#           beside whisper.cpp; the model is chosen by language, a missing
#           language answers nothing instead of reading it with the wrong model,
#           the runner's error is "no transcript" so the caller falls back, the
#           Crew rail and the installer know the engine, and the Plat page only
#           offers it when it is installed.
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
require(root() . '/perl/crew.pl');

my $repo = root();
my $tmp  = tempdir(CLEANUP => 1);
my $vosk = "$tmp/vosk";

# A stand-in for the installed tree: the model directories the chooser reads,
# a "venv" interpreter that answers like the runner, and the runner itself.
make_path("$vosk/models/vosk-model-small-en-us-0.15");
make_path("$vosk/models/fr");
make_path("$vosk/venv/bin");
my $py = "$vosk/venv/bin/python3";
write_file($py, "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '{\"text\":\"my name is john\"}'\n");
chmod 0755, $py;
write_file("$tmp/vosk_transcribe.py", "# stand-in for scripts/vosk_transcribe.py\n");

local $ENV{'JAWNOS_VOSK_DIR'}    = $vosk;
local $ENV{'JAWNOS_VOSK_RUNNER'} = "$tmp/vosk_transcribe.py";

# ------------------------------------------------------------ the model chooser
is(subs::vosk_model_dir('en'), "$vosk/models/vosk-model-small-en-us-0.15",
	'a language finds the model whose directory names it');
is(subs::vosk_model_dir('fr'), "$vosk/models/fr",
	'a hand-dropped model named for its language is found');
is(subs::vosk_model_dir('de'), '',
	'a language with no model answers nothing, so whisper is tried instead');
is(subs::vosk_model_dir('auto'), "$vosk/models/vosk-model-small-en-us-0.15",
	'auto takes English when it exists');
is(subs::vosk_model_dir(''), "$vosk/models/vosk-model-small-en-us-0.15",
	'no language is the same as auto');

ok(subs::vosk_available(), 'runner + interpreter + model is an install');
unlink $py;
$subs::vosk_probe = undef;
{
	local $ENV{'PATH'} = '/nonexistent';
	ok(!subs::vosk_available(), 'an interpreter that cannot import vosk is not an install');
}
write_file($py, "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '{\"text\":\"my name is john\"}'\n");
chmod 0755, $py;
$subs::vosk_probe = undef;
ok(subs::vosk_available(), 'the installed engine is offered again');

# ------------------------------------------------------------ the engine
write_file($py, "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '{\"text\":\"my name is john\"}'\n");
chmod 0755, $py;
is(subs::vosk_transcribe('RIFF-not-really', 'en'), 'my name is john',
	'a clip goes through the runner and comes back as text');

write_file($py, "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '{\"error\":\"no model\"}'\n");
chmod 0755, $py;
is(subs::vosk_transcribe('RIFF-not-really', 'en'), '',
	'an engine error is no transcript, so the caller falls back');

is(subs::vosk_transcribe('RIFF-not-really', 'de'), '',
	'a language Vosk has no model for is not transcribed with another one');

is(ref(subs::transcribe_local_engine('local:vosk')), 'CODE', 'Vosk is a local engine');
is(ref(subs::transcribe_local_engine('local:whisper.cpp')), 'CODE', 'so is whisper.cpp');
is(subs::transcribe_local_engine('groq:whisper-large-v3'), undef, 'a cloud model is not local');

# ------------------------------------------------------------ the role route
# The transcription role naming Vosk is what the Guide, dictation and the
# screened call all read: the local engine answers before any cloud model.
&subs::setting_setter({ app => 'mail', setting => 'transcription_assistant', value => 'local:vosk' });
&subs::setting_setter({ app => 'mail', setting => 'transcription_assistant_fallback', value => '' });
write_file($py, "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '{\"text\":\"the role reached vosk\"}'\n");
chmod 0755, $py;
is(subs::whisper_transcribe('RIFF-not-really', 'en'), 'the role reached vosk',
	'a role that names local:vosk is answered by Vosk');
&subs::setting_setter({ app => 'mail', setting => 'transcription_assistant', value => '' });

# ------------------------------------------------------------ the Crew rail
my $kind = crew::job_kind('vosk.transcribe');
ok($kind, 'the Crew registry knows vosk.transcribe');
is_deeply($kind->{'needs'}, ['vosk'], 'and gates it on the engine being present');
is($kind->{'handler'} && ref($kind->{'handler'}), 'CODE', 'with a handler');

# ------------------------------------------------------------ the installer
my $deps = read_file("$repo/scripts/jawnos_deps.pl");
like($deps, qr{id => 'vosk'}, 'the installer offers Vosk as an optional application');
like($deps, qr{sub install_vosk}, 'and has an installer for it');
like($deps, qr{vosk-model-small-en-us-0\.15}, 'which brings one small model');
like($deps, qr{Termux \(Bionic\) has no Vosk wheel}, 'and says why Termux cannot run it');
like($deps, qr{'pip', '--version'}, 'a venv with no pip is checked, not trusted');
like($deps, qr{remove_tree\("\$vosk_dir/venv"\)}, 'and rebuilt rather than reused');

# ------------------------------------------------------------ the Plat page
my $plat = read_file("$repo/templates/configure/plat_setting_list.html.ep");
like($plat, qr/value="local:vosk"/, 'the transcription role offers Vosk');
like($plat, qr/&subs::vosk_available\(\)/, 'only when the engine is installed');
like($plat, qr/value="local:whisper\.cpp"/, 'and keeps whisper.cpp beside it');

# ------------------------------------------------------------ the runner
my $py3 = (grep { -x $_ } map { "$_/python3" } split /:/, $ENV{'PATH'})[0];
SKIP: {
	skip 'no python3 on PATH', 2 unless $py3;
	my $help = qx{'$py3' '$repo/scripts/vosk_transcribe.py' --help 2>&1};
	is($? >> 8, 0, 'the runner parses its arguments');
	like($help, qr/--model/, 'and documents the model it needs');
	# Whatever is installed here, a model that is not there is one JSON error
	# line on stdout and a non-zero exit - never a Perl-visible crash.
	my $out = qx{'$py3' '$repo/scripts/vosk_transcribe.py' --model /nonexistent/model 2>/dev/null};
	isnt($? >> 8, 0, 'a model that is not there is a failure');
	like($out, qr/\A\{"error"/, 'reported as one JSON line the caller can read');
}

done_testing();
