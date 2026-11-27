# tests-for: lib/JawnOS/Domain/Ai.pm perl/crew.pl scripts/jawnos_deps.pl scripts/whisper_tool.py templates/configure/plat_setting_list.html.ep
# covers:    whisper.cpp is the one local transcription engine the role can name
#           (local:whisper.cpp); the desktop wheel and the Termux native build,
#           their wrappers, the model chooser, a stored local:vosk read as
#           whisper.cpp, a machine without the engine using a house peer's
#           through the Crew whisper.transcribe job, the WAV conversion the
#           native server needs, and the Plat page offering the engine where it
#           can run.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use MIME::Base64 qw(decode_base64);
use File::Path qw(make_path remove_tree);
use File::Copy qw(copy);
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

# The file engine is the command and a model; the IVR's Python streamer is not
# part of it. The app runtime on a phone/tablet has no python3 and still works.
{
	local $ENV{'JAWNOS_WHISPER_STREAMER'} = '/no/such/streamer.py';
	local $ENV{'PATH'} = '/nonexistent';
	$subs::whisper_probe = undef;
	ok(subs::whisper_available(),
		'a command and a model are available without the IVR reader or Python');
}
$subs::whisper_probe = undef;

# ------------------------------------------------------------ how a copied engine runs
# Android's app runtime mounts the directory the app writes noexec: exec of a
# copied binary is refused even at 0755, while the system linker can still open
# it. The launcher names the linker there; a desktop runs the binary itself. A
# shell wrapper is always read by sh (exec of the script is refused there too).
{
	my $elf = $^X;
	local $ENV{'JAWNOS_ANDROID_LINKER'} = '/system/bin/linker64';
	is_deeply([subs::whisper_launch_argv($elf)], ['/system/bin/linker64', $elf],
		'the app runtime opens a binary with the linker');
	is_deeply([subs::whisper_launch_argv("$root/whisper-cli")], ['sh', "$root/whisper-cli"],
		'and reads a shell wrapper with sh');
}
{
	my $elf = $^X;
	local $ENV{'JAWNOS_ANDROID_LINKER'} = '';
	is_deeply([subs::whisper_launch_argv($elf)], [$elf], 'a desktop execs the binary as itself');
	is_deeply([subs::whisper_launch_argv('')], [], 'no command, no argv');
}
{
	my $py = "$tmp/py-console";
	write_file($py, "#!/usr/bin/env python3\nexit 0\n");
	local $ENV{'JAWNOS_ANDROID_LINKER'} = '/system/bin/linker64';
	is_deeply([subs::whisper_launch_argv($py)], [$py],
		'a Python console script keeps its own interpreter');
}

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

# ------------------------------------------------------------ a peer's engine
# A machine without the local engine (a phone) uses the house's: the Crew's
# whisper.transcribe job is placed on a peer that advertises the tool.
{
	my @sent;
	local *subs::whisper_available = sub { 0 };
	local *crew::dispatch = sub {
		my ($kind, $payload) = @_;
		push @sent, [ $kind, $payload ];
		return { ok => 1, result => { text => 'the peer heard this' } };
	};
	local *subs::ai_role_models = sub { ('local:whisper.cpp', '') };
	is(subs::whisper_transcribe('RIFF-peer', 'en'), 'the peer heard this',
		'a machine without the engine asks a peer that has it');
	is(scalar(@sent), 1, 'one Crew job is dispatched');
	is($sent[0][0], 'whisper.transcribe', 'the whisper.transcribe job');
	is(decode_base64($sent[0][1]{'audio_b64'}), 'RIFF-peer',
		'the clip rides base64 on the wire');
	is($sent[0][1]{'lang'}, 'en', 'with the language');
}

# When no peer answers, the role's own fallback is still tried.
{
	local *subs::whisper_available = sub { 0 };
	local *crew::dispatch = sub { return { ok => 0, error => 'no peer' } };
	local *subs::ai_transcribe_cloud = sub { return 'the cloud heard this' };
	local *subs::ai_role_models = sub { ('local:whisper.cpp', '@cf/openai/whisper') };
	is(subs::whisper_transcribe('RIFF-cloud', 'en'), 'the cloud heard this',
		'no peer leaves the role fallback in charge');
}

# An installed engine is used here, never dispatched away.
{
	local *subs::whisper_available = sub { 1 };
	local *crew::dispatch = sub { die 'must not dispatch' };
	local *subs::whisper_local_transcribe = sub { return 'the local engine heard this' };
	local *subs::ai_role_models = sub { ('local:whisper.cpp', '') };
	is(subs::whisper_transcribe('RIFF-local', 'en'), 'the local engine heard this',
		'the installed engine answers locally');
}

# A Crew whisper job must never dispatch the same clip onward.
{
	local $subs::whisper_no_peer = 1;
	local *subs::whisper_available = sub { 0 };
	local *crew::dispatch = sub { die 'must not dispatch' };
	local *subs::ai_role_models = sub { ('local:whisper.cpp', '') };
	is(subs::whisper_transcribe('RIFF', 'en'), '', 'a Crew job never dispatches onward');
}

# The Plat page offers the engine when this machine has it, or when a peer does.
{
	local *subs::whisper_available = sub { 0 };
	local *crew::place = sub { { ok => 1, local => 0, hostname => 'dev' } };
	ok(subs::whisper_house_available(), 'a peer with the engine makes it a house choice');
	local *crew::place = sub { { ok => 0, error => 'nothing can run it' } };
	ok(!subs::whisper_house_available(), 'no peer means it is not offered');
	local *subs::whisper_available = sub { 1 };
	ok(subs::whisper_house_available(), 'a local engine is offered without asking a peer');
}

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
like($deps, qr/WHISPER_BUILD_SERVER/, 'and builds the native CLI and server on Termux');
like($deps, qr/whisper-cli-native/, 'staging the native CLI beside the wrapper');
like($deps, qr/whisper_native_wrapper/, 'whose wrapper adapts the tree\'s --file - interface');
like($deps, qr/JAWNOS_WHISPER_PREBUILT/, 'with a prebuilt fallback for a slow or failed build');
like($deps, qr/pkg.*install/s, 'through Termux pkg');
like($deps, qr{'pip', '--version'}, 'a venv with no pip is checked, not trusted');
like($deps, qr{remove_tree\("\$whisper_dir/venv"\)}, 'and rebuilt rather than reused');

unlike($deps, qr{sub install_vosk}, 'the Vosk installer is gone');

# The installer's own probe must agree with whisper_available: a tree with the
# interpreter, the command wrapper and a model is still not an install when the
# repo's live reader is gone, because the reader is what the probe runs.
{
	my $tree = "$tmp/deps";
	my $fake = "$tmp/home";
	my $wd   = "$fake/.local/share/jawnos/whisper";
	make_path("$tree/scripts", "$wd/models", "$wd/venv/bin",
		"$fake/.local/share/jawnos/piper", "$fake/.local/share/jawnos/rtc/venv/bin");
	copy("$repo/scripts/jawnos_deps.pl", "$tree/scripts/jawnos_deps.pl");
	copy("$repo/scripts/whisper_stream.py", "$tree/scripts/whisper_stream.py");
	write_file("$wd/models/ggml-base.bin", 'base');
	foreach my $exe ("$wd/venv/bin/python3", "$wd/whisper-cli", "$wd/whisper-server",
		"$fake/.local/share/jawnos/piper/piper",
		"$fake/.local/share/jawnos/rtc/venv/bin/python3") {
		write_file($exe, "#!/bin/sh\nexit 0\n");
		chmod 0755, $exe;
	}
	local $ENV{'HOME'} = $fake;
	my $run = sub {
		my $out = qx{'$^X' '-I$repo/lib' '$tree/scripts/jawnos_deps.pl' --extras-only --report 2>&1};
		return $out . "\n" . ($? >> 8);
	};
	my $all = $run->();
	like($all, qr/Optional applications: all present/, 'four parts plus the reader is an install');
	like($all, qr/\n0\z/, 'and the installer reports nothing missing');

	# A native install (the Termux/Android build) needs no venv: a real ELF
	# server, the model and the reader are the whole thing.
	{
		my $true = -x '/bin/true' ? '/bin/true' : -x '/usr/bin/true' ? '/usr/bin/true' : '';
		SKIP: {
			skip 'no /bin/true to stand in for a native binary', 2 unless length $true;
			remove_tree("$wd/venv");
			unlink "$wd/whisper-cli";
			copy($true, "$wd/whisper-server");
			chmod 0755, "$wd/whisper-server";
			my $native = $run->();
			like($native, qr/Optional applications: all present/,
				'a native server, model and reader are an install with no venv');
			like($native, qr/\n0\z/, 'and the installer reports nothing missing');
		}
	}

	unlink "$tree/scripts/whisper_stream.py";
	my $gone = $run->();
	like($gone, qr/whisper\.cpp speech-to-text/, 'a tree without the live reader is missing the engine');
	like($gone, qr/\n1\z/, 'and the installer reports it instead of an install');
}

# ------------------------------------------------------------ the native prebuilt install
# The Termux build can be replaced by a prebuilt directory: the installer copies
# the two binaries, writes the CLI wrapper, and needs no pkg, cmake or network
# when the models are already there.
{
	my $tree = "$tmp/native-deps";
	my $fake = "$tmp/native-home";
	my $wd   = "$fake/.local/share/jawnos/whisper";
	my $pre  = "$tmp/prebuilt";
	make_path("$tree/scripts", "$wd/models", "$pre",
		"$fake/.local/share/jawnos/piper", "$fake/.local/share/jawnos/rtc/venv/bin");
	copy("$repo/scripts/jawnos_deps.pl", "$tree/scripts/jawnos_deps.pl");
	copy("$repo/scripts/whisper_stream.py", "$tree/scripts/whisper_stream.py");
	write_file("$wd/models/ggml-base.bin", 'base');
	write_file("$wd/models/ggml-tiny.bin", 'tiny');
	foreach my $exe ("$fake/.local/share/jawnos/piper/piper",
		"$fake/.local/share/jawnos/rtc/venv/bin/python3") {
		write_file($exe, "#!/bin/sh\nexit 0\n");
		chmod 0755, $exe;
	}
	my $true = -x '/bin/true' ? '/bin/true' : -x '/usr/bin/true' ? '/usr/bin/true' : '';
	SKIP: {
		skip 'no native ELF to stand in for the prebuilt', 7 unless length $true;
		copy($true, "$pre/whisper-cli");
		copy($true, "$pre/whisper-server");
		chmod 0755, "$pre/whisper-cli", "$pre/whisper-server";
		local $ENV{'HOME'} = $fake;
		local $ENV{'TERMUX_VERSION'} = '1';
		local $ENV{'JAWNOS_WHISPER_PREBUILT'} = $pre;
		my $out = qx{'$^X' '-I$repo/lib' '$tree/scripts/jawnos_deps.pl' --extras-only --install 2>&1};
		is($? >> 8, 0, 'the native prebuilt install runs without pkg or cmake');
		like($out, qr/staged the native CLI/, 'and says it staged the prebuilt');
		ok(-x "$wd/whisper-cli-native", 'the native CLI is installed');
		ok(-x "$wd/whisper-server", 'the server is installed');
		ok(-x "$wd/whisper-cli", 'and the CLI wrapper is executable');
		like(read_file("$wd/whisper-cli"), qr/whisper-cli-native.*-nt/s,
			'whose body calls the native binary and prints text');
		like(read_file("$wd/whisper-cli"), qr{/system/bin/linker64},
			'and opens a binary under app data with the system linker');
	}
}

# --only picks one extra. A phone that stages whisper has no use for Piper,
# whose Termux path wants the glibc bridge: the deploy names whisper alone.
{
	my $tree = "$tmp/native-deps";
	my $home = "$tmp/native-only-home";
	my $wd   = "$home/.local/share/jawnos/whisper";
	my $pre  = "$tmp/prebuilt";
	my $elf  = -x '/bin/true' ? '/bin/true' : -x '/usr/bin/true' ? '/usr/bin/true' : '';
	make_path("$wd/models", "$home/pfx/etc");
	write_file("$home/pfx/etc/jawnos-runtime.json", '{"version":"test"}');
	write_file("$wd/models/ggml-base.bin", 'base');
	write_file("$wd/models/ggml-tiny.bin", 'tiny');
	SKIP: {
		skip 'no native ELF to stand in for the prebuilt', 5 unless length $elf;
		local $ENV{'HOME'} = $home;
		local $ENV{'TERMUX_VERSION'} = '1';
		local $ENV{'PREFIX'} = "$home/pfx";
		local $ENV{'JAWNOS_WHISPER_PREBUILT'} = $pre;
		local $ENV{'PATH'} = '/nonexistent';
		my $out = qx{'$^X' '-I$repo/lib' '$tree/scripts/jawnos_deps.pl' --extras-only --install --only=whisper 2>&1};
		is($? >> 8, 0, '--only=whisper installs that extra and exits 0');
		like($out, qr/staged the native CLI/, 'and stages the prebuilt CLI on the app runtime');
		unlike($out, qr/piper:/, 'without reaching for Piper');
		ok(!-e "$home/.local/share/jawnos/piper", 'and leaves no Piper tree');
		my $full = qx{'$^X' '-I$repo/lib' '$tree/scripts/jawnos_deps.pl' --install 2>&1};
		like($full, qr/supplies every module and tool/,
			'while a full install still honors the runtime marker');
	}
}

# ------------------------------------------------------------ the warm-server upload
# The desktop wheel's server decodes webm; the native whisper.cpp server (the
# phone's) reads WAV only. The manager converts the clip before the POST.
{
	my $ffmpeg = `command -v ffmpeg 2>/dev/null`;
	chomp $ffmpeg;
	SKIP: {
		skip 'no ffmpeg on PATH', 2 unless length $ffmpeg;
		my $pcm = "\x00\x00" x 1600;
		my $wav = 'RIFF' . pack('V', 36 + length($pcm))
			. 'WAVEfmt ' . pack('VvvVVvv', 16, 1, 1, 16_000, 32_000, 2, 16)
			. 'data' . pack('V', length($pcm)) . $pcm;
		my $out = subs::whisper_server_wav($wav);
		like($out, qr/^RIFF....WAVE/s, 'the warm server is sent a WAV the native build can read');
		is(unpack('V', substr($out, 24, 4)), 16_000, 'at the model rate');
	}
}

# ------------------------------------------------------------ the Plat page
my $plat = read_file("$repo/templates/configure/plat_setting_list.html.ep");
like($plat, qr/value="local:whisper\.cpp"/, 'the transcription role offers whisper.cpp');
like($plat, qr/&subs::whisper_house_available\(\)/, 'when this machine has it, or a house machine does');
like($plat, qr/Another machine/, 'and labels a peer\'s engine as another machine');
like($plat, qr/my \$whisper_local = \(\$cap eq 'audio'\)/,
	'every transcription row offers whisper, not only the shared one and the call');
unlike($plat, qr/\$setting eq 'transcription_assistant' \|\| \$setting eq 'transcription_ivr'/,
	'the old two-row whisper restriction is gone');

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

# ------------------------------------------------------------ per-surface roles
# A surface row wins once the Plat page sets it; an unset row follows the shared
# transcription choice, so a house that never opened the new rows is unchanged.
&subs::setting_setter({ app => 'mail', setting => 'transcription_assistant', value => 'local:whisper.cpp' });
is(subs::transcription_role_for('keyboard'), 'transcription_assistant',
	'a surface with no row of its own follows the shared role');
&subs::setting_setter({ app => 'mail', setting => 'transcription_keyboard', value => '@cf/openai/whisper' });
is(subs::transcription_role_for('keyboard'), 'transcription_keyboard',
	'a surface that has a row of its own reads it');
is(subs::transcription_role_for('Keyboard!!'), 'transcription_keyboard',
	'a noisy name is reduced to the same role');
is(subs::transcription_role_for(''), 'transcription_assistant', 'no surface is the shared role');
is(subs::transcription_role_for('../../etc/passwd'), 'transcription_assistant',
	'a name that is not a surface never becomes a setting key');
&subs::setting_setter({ app => 'mail', setting => 'transcription_keyboard', value => '' });
is(subs::transcription_role_for('keyboard'), 'transcription_assistant',
	'clearing a surface row hands it back to the shared role');

# The consumer names the role the transcription reads.
&subs::setting_setter({ app => 'mail', setting => 'transcription_teletype', value => 'local:whisper.cpp' });
{
	my @asked;
	local *subs::ai_role_models = sub { push @asked, $_[0]; return ('local:whisper.cpp', '') };
	local *subs::whisper_local_transcribe = sub { return 'heard' };
	is(subs::whisper_transcribe('RIFF', 'en', 'teletype'), 'heard', 'the deck clip is transcribed');
	is($asked[0], 'transcription_teletype', 'through the deck own row');
	&subs::setting_setter({ app => 'mail', setting => 'transcription_teletype', value => '' });
}

# A watch or deck clip on a phone has no local engine: the house's whisper
# answers through the same whisper.transcribe job. An installed engine answers
# locally instead.
foreach my $surface (qw(watch teletype)) {
	{
		local *subs::ai_role_models = sub { ('local:whisper.cpp', '') };
		local *subs::whisper_available = sub { 0 };
		local *crew::dispatch = sub {
			return { ok => 1, result => { text => "the peer heard the $surface clip" } };
		};
		is(subs::whisper_transcribe('RIFF-' . $surface, 'en', $surface),
			"the peer heard the $surface clip",
			"a $surface clip on a machine without the engine uses the house peer");
	}
	{
		local *subs::ai_role_models = sub { ('local:whisper.cpp', '') };
		local *subs::whisper_available = sub { 1 };
		local *subs::whisper_local_transcribe = sub { "the local engine heard the $surface clip" };
		is(subs::whisper_transcribe('RIFF-' . $surface, 'en', $surface),
			"the local engine heard the $surface clip",
			"a $surface clip uses this machine's engine when it is installed");
	}
}

# The Guide and the soft keyboard can name either the phone recogniser or the
# free engine; the saved choice is the service the role resolves to.
foreach my $surface (qw(keyboard guide)) {
	my $role = 'transcription_' . $surface;
	&subs::setting_setter({ app => 'mail', setting => $role, value => 'android:oem' });
	is(subs::transcription_service_for($surface), 'android:oem',
		"$surface can name the phone recogniser");
	&subs::setting_setter({ app => 'mail', setting => $role, value => 'local:whisper.cpp' });
	is(subs::transcription_service_for($surface), 'local:whisper.cpp',
		"$surface can name whisper.cpp");
	&subs::setting_setter({ app => 'mail', setting => $role, value => '' });
}

# The phone recogniser is named but never run by the manager: a clip that finds
# it in a role moves on to the next service instead of posting anywhere.
{
	local *subs::ai_role_models = sub { ('android:oem', 'local:whisper.cpp') };
	local *subs::ai_transcribe_cloud = sub { die 'must not post audio to a client service' };
	local *subs::whisper_available = sub { 1 };
	local *subs::whisper_local_transcribe = sub { return 'the fallback heard this' };
	local *subs::transcription_service_is_client = sub { $_[0] eq 'android:oem' ? 1 : 0 };
	is(subs::whisper_transcribe('RIFF', 'en', 'keyboard'), 'the fallback heard this',
		'a clip skips the phone recogniser and uses the fallback');
}

ok(subs::transcription_service_is_client('android:oem'), 'the phone recogniser is a client service');
ok(!subs::transcription_service_is_client('local:whisper.cpp'), 'the local engine is not');
is((subs::ai_transcribe_test('android:oem'))[0], 1, 'its Test explains that it runs on the device');

# ------------------------------------------------------------ the Plat rows
like($plat, qr/transcription_keyboard/, 'the Plat page has a keyboard transcription row');
like($plat, qr/transcription_guide/, 'and a Guide row');
like($plat, qr/transcription_watch/, 'and a watch row');
like($plat, qr/transcription_teletype/, 'and a T-Deck row');
like($plat, qr/value="android:oem"/, 'the phone recogniser is offered');
like($plat, qr/\$live && \$setting ne 'transcription_assistant'/, 'only for the live surfaces');
like(read_file("$repo/perl/help/topics_functions.pl"), qr/Transcription has a row per surface/,
	'and the help topic says so');

done_testing();
