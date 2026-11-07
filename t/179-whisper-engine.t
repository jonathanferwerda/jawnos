# tests-for: lib/JawnOS/Domain/Ai.pm perl/crew.pl scripts/jawnos_deps.pl scripts/whisper_tool.py templates/configure/plat_setting_list.html.ep
# covers:    whisper.cpp is the one local transcription engine the role can name
#           (local:whisper.cpp); the wheel install and its wrappers, the model
#           chooser, a stored local:vosk read as whisper.cpp, the Crew rail,
#           and the Plat page offering only the engine that is installed.
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
my $root = "$tmp/whisper";

# A stand-in for the installed tree: two models, a venv interpreter and the two
# command wrappers the installer writes beside them.
make_path("$root/models", "$root/venv/bin");
write_file("$root/models/ggml-base.bin", 'base');
write_file("$root/models/ggml-tiny.bin", 'tiny');
my $py = "$root/venv/bin/python3";
write_file($py, "#!/bin/sh\nexit 0\n");
chmod 0755, $py;
foreach my $name (qw(whisper-cli whisper-server)) {
	write_file("$root/$name", "#!/bin/sh\nexit 0\n");
	chmod 0755, "$root/$name";
}

local $ENV{'JAWNOS_WHISPER_DIR'}     = $root;
local $ENV{'JAWNOS_WHISPER_MODELS'}  = "$root/models";
local $ENV{'JAWNOS_WHISPER_CLI'}     = "$root/whisper-cli";
local $ENV{'JAWNOS_WHISPER_SERVER'}  = "$root/whisper-server";
local $ENV{'JAWNOS_WHISPER_STREAMER'}= "$repo/scripts/whisper_stream.py";

# ------------------------------------------------------------ the install
is(subs::whisper_root(), $root, 'the installed tree is where the wrappers live');
is(subs::whisper_models_dir(), "$root/models", 'and its models directory');
is(subs::whisper_model_file('base'), "$root/models/ggml-base.bin",
	'a name finds its ggml file');
is(subs::whisper_model_file('tiny'), "$root/models/ggml-tiny.bin", 'tiny too');
is(subs::whisper_model_file('de'), '', 'a model that is not installed answers nothing');
is(subs::whisper_model_file("$root/models/ggml-base.bin"), "$root/models/ggml-base.bin",
	'a direct path is used as given');
is(subs::whisper_python(), $py, 'the venv interpreter is the runner');
is(subs::whisper_cli_bin(), "$root/whisper-cli", 'the wheel wrapper is the CLI');
is(subs::whisper_server_bin(), "$root/whisper-server", 'and the warm server');
is(subs::whisper_streamer(), "$repo/scripts/whisper_stream.py", 'the live reader is the repo script');

ok(subs::whisper_available(), 'streamer + model + interpreter + command is an install');
unlink "$root/models/ggml-base.bin";
unlink "$root/models/ggml-tiny.bin";
$subs::whisper_probe = undef;
ok(!subs::whisper_available(), 'a tree with no model is not an install');
write_file("$root/models/ggml-base.bin", 'base');
$subs::whisper_probe = undef;
ok(subs::whisper_available(), 'the installed engine is offered again');

# ------------------------------------------------------------ the engine
is(ref(subs::transcribe_local_engine('local:whisper.cpp')), 'CODE', 'whisper.cpp is a local engine');
is(ref(subs::transcribe_local_engine('local:vosk')), 'CODE',
	'a stored local:vosk is read as whisper.cpp');
is(subs::transcribe_local_engine('groq:whisper-large-v3'), undef, 'a cloud model is not local');

# The transcription role naming the old engine is what the Guide, dictation and
# the screened call all read: it must reach whisper.cpp without an edit.
&subs::setting_setter({ app => 'mail', setting => 'transcription_assistant', value => 'local:vosk' });
&subs::setting_setter({ app => 'mail', setting => 'transcription_assistant_fallback', value => '' });
{
	no warnings 'redefine', 'once';
	local *subs::whisper_local_transcribe = sub { return 'the role reached whisper' };
	is(subs::whisper_transcribe('RIFF-not-really', 'en'), 'the role reached whisper',
		'a role that names local:vosk is answered by whisper.cpp');
}
&subs::setting_setter({ app => 'mail', setting => 'transcription_assistant', value => '' });

# ------------------------------------------------------------ the Crew rail
my $kind = crew::job_kind('whisper.transcribe');
ok($kind, 'the Crew registry knows whisper.transcribe');
is_deeply($kind->{'needs'}, ['whisper'], 'and gates it on the engine being present');
ok(!crew::job_kind('vosk.transcribe'), 'the Vosk job kind is gone');

# ------------------------------------------------------------ the installer
my $deps = read_file("$repo/scripts/jawnos_deps.pl");
like($deps, qr{id => 'whisper'}, 'the installer offers whisper.cpp as an optional application');
like($deps, qr{sub install_whisper}, 'and has an installer for it');
like($deps, qr{pywhispercpp}, 'from the wheel, with no cmake');
like($deps, qr{qw\(base tiny\)}, 'which brings the base and tiny models');
like($deps, qr{Termux \(Bionic\) has no pywhispercpp wheel}, 'and says why Termux cannot run it');
like($deps, qr{'pip', '--version'}, 'a venv with no pip is checked, not trusted');
like($deps, qr{remove_tree\("\$whisper_dir/venv"\)}, 'and rebuilt rather than reused');
unlike($deps, qr{sub install_vosk}, 'the Vosk installer is gone');

# ------------------------------------------------------------ the Plat page
my $plat = read_file("$repo/templates/configure/plat_setting_list.html.ep");
like($plat, qr/value="local:whisper\.cpp"/, 'the transcription role offers whisper.cpp');
like($plat, qr/&subs::whisper_available\(\)/, 'only when the engine is installed');
unlike($plat, qr/value="local:vosk"/, 'and no longer offers Vosk');
like($plat, qr{\$current = 'local:whisper\.cpp' if \$current eq 'local:vosk'},
	'a stored local:vosk is shown as whisper.cpp');
unlike($plat, qr/\$vosk_here/, 'no dead Vosk probe is left in the page');

# ------------------------------------------------------------ the commands
my $py3 = (grep { -x $_ } map { "$_/python3" } split /:/, $ENV{'PATH'})[0];
SKIP: {
	skip 'no python3 on PATH', 5 unless $py3;
	my $help = qx{'$py3' '$repo/scripts/whisper_tool.py' cli --help 2>&1};
	is($? >> 8, 0, 'the engine tool parses its arguments');
	like($help, qr/-m/, 'and documents the model it needs');
	my $out = qx{'$py3' '$repo/scripts/whisper_tool.py' cli -m /nonexistent/model -f /dev/null 2>&1};
	isnt($? >> 8, 0, 'a model that is not there is a failure');
	like($out, qr/no model at/, 'reported in words the person can read');
	my $stream = qx{'$py3' '$repo/scripts/whisper_stream.py' --help 2>&1};
	is($? >> 8, 0, 'the streamer parses its arguments');
}

done_testing();
