# tests-for: lib/JawnOS/Domain/Ai.pm lib/JawnOS/Controller/manager_configure.pm templates/configure/plat_setting_list.html.ep public/js/manager/configure/03_platform_misc.js
# covers:    The Plat panel's Test beside the transcription role sends the
#           committed known sentence (public/sounds/transcribe-test.wav, 16 kHz
#           mono) instead of silence, so a cloud model must return words and the
#           answer names what it heard; whisper.cpp runs the same clip when it is
#           installed, and its absence is reported rather than passed. The phone
#           recogniser is a client service and says so here. The button, its
#           route and the template are pinned together.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);

use JawnOSTest;

my $root = root();
require($root . '/lib/JawnOS/Domain/Ai.pm');

my $clip = "$root/public/sounds/transcribe-test.wav";

# ------------------------------------------------------------ the fixture
ok(-f $clip, 'the transcription test sentence is committed with the tree');
my $bytes = read_file($clip, binmode => ':raw');
is(substr($bytes, 0, 4), 'RIFF', 'the clip is a RIFF file');
is(substr($bytes, 8, 4), 'WAVE', 'the clip is a WAV');
my $fmt = index($bytes, 'fmt ');
my $rate = unpack('V', substr($bytes, $fmt + 12, 4));
my $channels = unpack('v', substr($bytes, $fmt + 10, 2));
my $bits = unpack('v', substr($bytes, $fmt + 22, 2));
is($rate, 16000, 'the clip is 16 kHz, what whisper.cpp expects');
is($channels, 1, 'the clip is mono');
is($bits, 16, 'the clip is 16-bit');
ok(length($bytes) > 44 + 16000, 'the clip holds more than half a second of speech');

# The dialog's own reader resolves it even when the test's install dir is a
# sandbox: the committed path is relative to the tree the test runs from.
local $subs::install_dir = $root;
my $read = &subs::transcription_test_wav();
ok(defined $read && substr($read, 0, 4) eq 'RIFF', 'transcription_test_wav reads the committed clip');

# ------------------------------------------------------------ the branches
sub test_cloud {
	my ($model, $reply, $err) = @_;
	no warnings 'redefine';
	local *subs::ai_transcribe_cloud_result = sub {
		my ($m, $raw, $lang) = @_;
		$main::seen_model = $m;
		$main::seen_raw = $raw;
		$main::seen_lang = $lang;
		return ($reply, $err);
	};
	return &subs::ai_transcribe_test($model);
}

my ($ok, $msg) = &subs::ai_transcribe_test('');
is($ok, 0, 'an empty role is refused');
like($msg, qr/Pick a model/, 'and says to pick one');

($ok, $msg) = &subs::ai_transcribe_test('android:oem');
is($ok, 1, 'the phone recogniser is a pass here');
like($msg, qr/runs on the device/, 'and says it runs on the device');

($ok, $msg) = test_cloud('groq:whisper-large-v3', 'This is a test of the house voice.', undef);
is($ok, 1, 'a cloud model that hears the sentence passes');
like($msg, qr/heard: This is a test of the house voice/, 'and names what it heard');
is($main::seen_lang, 'en', 'the clip is sent as English');
is(substr($main::seen_raw, 0, 4), 'RIFF', 'the bytes sent are the WAV, not silence');
is(length($main::seen_raw), length($bytes), 'the whole committed clip is sent');

($ok, $msg) = test_cloud('groq:whisper-large-v3', undef, 'the provider is down');
is($ok, 0, 'a provider error fails the test');
is($msg, 'the provider is down', 'and its reason is reported');

($ok, $msg) = test_cloud('groq:whisper-large-v3', '', undef);
is($ok, 1, 'a 2xx with no words still passes');
like($msg, qr/answered, but heard nothing/, 'but it does not claim the model works');

# ------------------------------------------------------------ whisper.cpp
{
	no warnings 'redefine';
	local *subs::whisper_available = sub { 0 };
	($ok, $msg) = &subs::ai_transcribe_test('local:whisper.cpp');
	is($ok, 0, 'a machine without whisper.cpp fails the local test');
	like($msg, qr/not installed/, 'and says so');
}
{
	no warnings 'redefine';
	local *subs::whisper_available = sub { 1 };
	local *subs::whisper_cli_transcribe = sub {
		my ($raw, $lang) = @_;
		$main::seen_local = $raw;
		return 'This is a test of the house voice.';
	};
	($ok, $msg) = &subs::ai_transcribe_test('local:whisper.cpp');
	is($ok, 1, 'whisper.cpp passes when it hears the sentence');
	like($msg, qr/whisper\.cpp heard: This is a test/, 'and names what it heard');
	is(substr($main::seen_local, 0, 4), 'RIFF', 'the local engine is given the same clip');
}
{
	no warnings 'redefine';
	local *subs::whisper_available = sub { 1 };
	local *subs::whisper_cli_transcribe = sub { return ''; };
	($ok, $msg) = &subs::ai_transcribe_test('local:whisper.cpp');
	is($ok, 0, 'a whisper.cpp that hears nothing fails');
	like($msg, qr/did not hear/, 'and says the model did not hear it');
}

# ------------------------------------------------------------ the button wiring
my $template = read_file("$root/templates/configure/plat_setting_list.html.ep");
like($template, qr/class="button ai_model_test"/, 'the Plat panel draws the Test button');
my $js = read_file("$root/public/js/manager/configure/03_platform_misc.js");
like($js, qr#url: '/manager/configure/ai_model_test'#, 'the button posts to the test route');
my $ctl = read_file("$root/lib/JawnOS/Controller/manager_configure.pm");
like($ctl, qr/sub action_9542[\s\S]*?ai_model_test\(\$model, \$role\)/, 'the route runs the model test with the role');

done_testing();
