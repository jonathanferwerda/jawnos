# tests-for: lib/JawnOS/Domain/Ai.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Sco/Gateway.pm lib/JawnOS/Manager/Part12.pm lib/JawnOS/Controller/manager_phone.pm templates/configure/plat_setting_list.html.ep templates/apps/phone.html.ep public/js/manager/phone.js perl/help/topics_web.pl
# covers:    A screened call's transcription is a role (transcription_ivr,
#           falling back to transcription_assistant): the gateway resolves it to
#           the local model it can actually run, keeps the base model and says
#           so when the role names a cloud model or the phone's recogniser, and
#           hands the concrete model file to whisper_stream.py. Also pins the
#           Plat row, the pane's select and the save that writes the role.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);

use RepoSource;
use JawnOSTest;

use lib repo_root() . '/lib';
use JawnOS::Sco::Gateway;

require(root() . '/lib/JawnOS/Domain/Ai.pm');
require(root() . '/lib/JawnOS/Manager/Part12.pm');

{ package FakeRows;
  sub new { my ($class, $rows) = @_; return bless { rows => $rows || [] }, $class; }
  sub hashes { return $_[0]->{'rows'}; }
}

my $repo = root();
my $tmp  = tempdir(CLEANUP => 1);
my $whisper = "$tmp/whisper";

# A stand-in for the installed tree: the two models whisper.cpp ships, plus an
# executable interpreter so the gateway's readiness check passes without a
# Python wheel. The streamer is the repo's own script (never run here).
make_path("$whisper/models");
write_file("$whisper/models/ggml-base.bin", 'base');
write_file("$whisper/models/ggml-tiny.bin", 'tiny');
my $python = "$tmp/python3";
write_file($python, "#!/bin/sh\nexit 0\n");
chmod 0755, $python;

local $ENV{'JAWNOS_WHISPER_DIR'}      = $whisper;
local $ENV{'JAWNOS_WHISPER_MODELS'}   = "$whisper/models";
local $ENV{'JAWNOS_WHISPER_STREAMER'} = "$repo/scripts/whisper_stream.py";
my $base = "$whisper/models/ggml-base.bin";

# The role rows the Plat page writes, as the resolver reads them. The real
# ai_role_models is the same pair of lookups, stubbed here so the test fixes the
# role's values directly and can see which role was asked for.
my @asked;
sub with_roles {
	my ($rows) = @_;
	@asked = ();
	local *subs::setting_grabber = sub {
		my ($request) = @_;
		return $rows->{ $request->{'setting'} };
	};
	local *subs::ai_role_models = sub {
		my ($role) = @_;
		push @asked, $role;
		return ($rows->{ $role }, $rows->{ $role . '_fallback' });
	};
	return &subs::whisper_stream_model('ivr');
}

# ------------------------------------------------------------ role resolution
{
	my ($model, $note) = with_roles({ transcription_ivr => 'local:whisper.cpp' });
	is($model, $base, 'the surface row naming whisper.cpp resolves to the installed base model');
	is($note, '', 'and there is nothing to explain');
	is($asked[0], 'transcription_ivr', 'the surface row is the one read');
}
{
	my ($model, $note) = with_roles({});
	is($model, $base, 'an unset surface row falls back to the shared choice, and then the base model');
	is($note, '', 'with no note: that is the ordinary case');
	is($asked[0], 'transcription_assistant', 'the shared role answers when the surface row is unset');
}
{
	my ($model, $note) = with_roles({ transcription_assistant => 'local:whisper.cpp' });
	is($model, $base, 'a shared role naming whisper.cpp resolves to the base model');
	is($note, '', 'and nothing needs explaining');
}
{
	my ($model, $note) = with_roles({ transcription_ivr => 'groq:whisper-large-v3-turbo' });
	is($model, $base, 'a cloud model cannot read a live call, so the base model is used');
	like($note, qr/groq:whisper-large-v3-turbo/, 'and the note names the role value');
	like($note, qr/base model/, 'and says what was used instead');
}
{
	my ($model, $note) = with_roles({ transcription_ivr => 'android:oem' });
	is($model, $base, 'the phone recogniser cannot read a live call on the gateway');
	like($note, qr/android:oem/, 'and the note names it');
}
{
	my ($model, $note) = with_roles({ transcription_ivr => 'acme:made-up' });
	is($model, $base, 'a service nobody knows is not a local engine');
	like($note, qr/acme:made-up/, 'and the note names the value rather than guessing');
}
{
	my ($model, $note) = with_roles({
		transcription_ivr => 'groq:whisper-large-v3-turbo',
		transcription_ivr_fallback => 'local:whisper.cpp',
	});
	is($model, $base, 'a cloud primary with a local fallback still reads on this gateway');
	is($note, '', 'and needs no note, because the role names a runnable service');
}

# ------------------------------------------------------------ the gateway argv
# The spawn is stubbed: the argv is recorded, and whisper is never started.
sub gateway_run {
	my ($rows) = @_;
	local *subs::setting_grabber = sub {
		my ($request) = @_;
		return $rows->{ $request->{'setting'} };
	};
	local *subs::ai_role_models = sub {
		my ($role) = @_;
		return ($rows->{ $role }, $rows->{ $role . '_fallback' });
	};
	local *subs::whisper_available = sub { return 1 };
	local *subs::whisper_server_wanted = sub { return 1 };
	local *subs::whisper_python = sub { return $python };
	local *subs::whisper_streamer = sub { return "$repo/scripts/whisper_stream.py" };
	local *JawnOS::Sco::Gateway::_spawn_transcript = sub {
		my ($self, @cmd) = @_;
		$self->{'test_argv'} = \@cmd;
		return 1;
	};
	my $gw = JawnOS::Sco::Gateway->new(
		dir => "$tmp/sco-" . (++$main::run),
		helper => ['/bin/false'],
		pipe => 1,
	);
	$gw->{'call_id'} = 'screen-test';
	my $started = $gw->_start_transcript();
	return ($gw, $started);
}
our $run = 0;

{
	my ($gw, $started) = gateway_run({ transcription_ivr => 'local:whisper.cpp' });
	ok($started, 'the reader starts with a local role');
	my $argv = $gw->{'test_argv'};
	is($argv->[0], $python, 'the gateway spawns the interpreter');
	is($argv->[1], "$repo/scripts/whisper_stream.py", 'and the repo streamer');
	my %arg;
	for (my $i = 2; $i < @{$argv}; $i += 2) { $arg{ $argv->[$i] } = $argv->[ $i + 1 ]; }
	is($arg{'--model'}, $base, 'the resolved model file is what the streamer is told to load');
	is($arg{'--rate'}, 8000, 'and the call rate is unchanged');
	is($gw->{'transcript_note'}, '', 'a runnable role leaves the transcript note empty');
}
{
	my ($gw, $started) = gateway_run({ transcription_ivr => 'groq:whisper-large-v3-turbo' });
	ok($started, 'the reader still starts when the role names a cloud model');
	my $argv = $gw->{'test_argv'};
	my %arg;
	for (my $i = 2; $i < @{$argv}; $i += 2) { $arg{ $argv->[$i] } = $argv->[ $i + 1 ]; }
	is($arg{'--model'}, $base, 'it loads the base model instead of running nowhere');
	like($gw->{'transcript_note'}, qr/groq:whisper-large-v3-turbo.*base model/,
		'and the status carries the note the pane shows under the transcript');
}

# ------------------------------------------------------------ the wiring
my $plat = read_file("$repo/templates/configure/plat_setting_list.html.ep");
like($plat, qr/\[\s*'transcription_ivr',\s*'Transcription · screened calls',\s*'audio'/,
	'the Plat page has a row for screened calls');
like($plat, qr/\$setting eq 'transcription_ivr'.*whisper_available/,
	'and offers whisper.cpp to that row, the engine a live call can use');

my $pane = read_file("$repo/templates/apps/phone.html.ep");
like($pane, qr/id="phone_ivr_transcription"/, 'the IVR pane has the transcription select');
like($pane, qr/Follow the shared transcription choice/, 'including the shared-choice option');
my $js = read_file("$repo/public/js/manager/phone.js");
like($js, qr/transcription:\s*\$\('#phone_app #phone_ivr_transcription'\)\.val\(\)/,
	'the pane posts the select with its save');
like($js, qr{url: '/manager/phone/ivr'}, 'through the same route every IVR field uses');

{
	# The save writes a mail-setting row, not a phone one: the role is the same
	# row the Plat page edits, so the two cannot disagree.
	local *subs::setting_grabber = sub { return undef };
	local *subs::db_select = sub { return FakeRows->new([]) };
	my @writes;
	local *subs::setting_setter = sub { push @writes, { %{ $_[0] } } };
	Manager::phone_ivr_save({ enabled => 'no', transcription => 'local:whisper.cpp' });
	my ($role) = grep { ($_->{'setting'} || '') eq 'transcription_ivr' } @writes;
	ok($role, 'an IVR save writes the transcription role');
	is($role->{'app'}, 'mail', 'in the app the Plat page keeps it in');
	is($role->{'value'}, 'local:whisper.cpp', 'with the chosen service');
	is($role->{'device'}, 'all', 'for the house, because the gateway reads it');
}
{
	local *subs::setting_grabber = sub { return undef };
	local *subs::db_select = sub { return FakeRows->new([]) };
	my @writes;
	local *subs::setting_setter = sub { push @writes, { %{ $_[0] } } };
	Manager::phone_ivr_save({ enabled => 'no', transcription => '' });
	my ($role) = grep { ($_->{'setting'} || '') eq 'transcription_ivr' } @writes;
	ok($role, 'choosing the shared choice writes the row too');
	is($role->{'value'}, '', 'with an empty value, which hands the call back to the shared role');
}
{
	local *subs::setting_grabber = sub { return undef };
	local *subs::db_select = sub { return FakeRows->new([]) };
	my @writes;
	local *subs::setting_setter = sub { push @writes, { %{ $_[0] } } };
	Manager::phone_ivr_save({ enabled => 'no' });
	my @roles = grep { ($_->{'setting'} || '') eq 'transcription_ivr' } @writes;
	is(scalar @roles, 0, 'an older app that does not post the field leaves the role alone');
}

# The help topic tells the person the same thing the pane does.
my $help = read_file("$repo/perl/help/topics_web.pl");
like($help, qr/Under the flow voice, Transcription chooses which service reads/,
	'the help topic explains the select in the on-screen words');
like($help, qr/leaves the transcript on the base model/,
	'and what happens to a choice the gateway cannot run');

# A surface may be set house-wide: the phone pane writes device 'all' because the
# gateway that reads it is another machine. The machine's own row still wins.
&subs::setting_setter({ app => 'mail', setting => 'transcription_ivr', value => 'local:whisper.cpp', device => 'all' });
is(subs::transcription_role_for('ivr'), 'transcription_ivr',
	'a house row answers when this machine has none of its own');
is((subs::ai_role_models('transcription_ivr'))[0], 'local:whisper.cpp',
	'and its model is read across the house');
&subs::setting_setter({ app => 'mail', setting => 'transcription_ivr', value => '@cf/openai/whisper' });
is((subs::ai_role_models('transcription_ivr'))[0], '@cf/openai/whisper',
	'a device row beats the house row');

done_testing();
