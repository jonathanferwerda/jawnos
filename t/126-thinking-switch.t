# tests-for: lib/JawnOS/Domain/Ai2.pm lib/JawnOS/Domain/Ai.pm templates/configure/misc_setting_list.html.ep public/js/manager/configure/03_platform_misc.js templates/configure/plat_setting_list.html.ep templates/configure/qa_panel.html.ep
# covers:    the per-device thinking off switch - ai_role_thinking_allowed and
#           ai_role_thinking_effective, the `thinking_off` setting they read, the
#           role call that drops the level, and the Misc panel and JS that write it.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Slurp qw(read_file);
use Test::More;

require JawnOS::Domain::Ai2;
require JawnOS::Domain::Ai;

# this machine, as a worker knows it: the switch is read for it when no device
# is named
local *subs::device_setter = sub { 'computer' };

my $root = "$FindBin::Bin/..";

# The settings the test pretends the house holds. The mail app's rows are keyed by
# their setting name (ai_role_models reads the role name itself for a primary),
# the others by "app/setting"; every read goes through the grabber below.
my %row = (
	'coding_assistant'    => 'deepseek:deepseek-flash',
	'coding_assistant_thinking' => 'high',
	'help_assistant'      => 'deepseek:deepseek-flash',
	'help_assistant_thinking' => 'max',
	'coding_thinking_off' => undef,
	'guide_thinking_off'  => undef,
	'misc/thinking_off'        => undef,
);
my $asked;
{
	local *subs::setting_grabber = sub {
		my $s = shift;
		$asked->{ ($s->{'setting'} // '') . '/' . ($s->{'device'} // '') }++ if ($s->{'setting'} // '') eq 'thinking_off';
		return $row{ (($s->{'app'} // '') eq 'mail' ? '' : ($s->{'app'} // '') . '/') . ($s->{'setting'} // '') };
	};

	# nothing turned off: every language agent may think
	is( subs::ai_role_thinking_allowed('coding_assistant'), 1, 'no switch: the Coding agent may think' );
	is( subs::ai_role_thinking_allowed('help_assistant'), 1, 'no switch: the Help guide may think' );
	is( subs::ai_role_thinking_allowed('chatbot_model'), 1, 'no switch: the Pen may think' );

	# the switch names the Coding agent - and only it
	$row{'misc/thinking_off'} = 'coding_assistant';
	is( subs::ai_role_thinking_allowed('coding_assistant'), 0, 'the switch names the Coding agent: it may not think' );
	is( subs::ai_role_thinking_allowed('help_assistant'), 1, 'a role the switch does not name still thinks' );
	is( subs::ai_role_thinking_effective('coding_assistant'), '', 'the effective level of a silenced role is none' );
	is( subs::ai_role_thinking_effective('help_assistant'), 'max', 'a role left on keeps its chosen level' );

	# a spaced, comma-separated list of several roles
	$row{'misc/thinking_off'} = 'coding_assistant, eval_assistant,visual_assistant';
	is( subs::ai_role_thinking_allowed('eval_assistant'), 0, 'a comma list silences each of its roles' );
	is( subs::ai_role_thinking_allowed('visual_assistant'), 0, 'no space is needed after a comma' );
	is( subs::ai_role_thinking_allowed('help_assistant'), 1, 'a role outside the list is untouched' );

	# the two roles with their own long-standing 'off' answer that too, so a
	# build that has not written the switch yet is still honoured
	$row{'misc/thinking_off'} = '';
	$row{'coding_thinking_off'} = 'off';
	is( subs::ai_role_thinking_allowed('coding_assistant'), 0, 'the Coding agent\'s own off switch still silences it' );
	$row{'guide_thinking_off'} = 'off';
	is( subs::ai_role_thinking_allowed('help_assistant'), 0, 'the Guide\'s own off switch silences it' );
	$row{'coding_thinking_off'} = 'on';
	is( subs::ai_role_thinking_allowed('coding_assistant'), 1, 'anything but off leaves the Coding agent thinking' );
	$row{'guide_thinking_off'} = 'on';

	# the device the switch is read for is the one asked for, else this machine
	subs::ai_role_thinking_allowed('chatbot_model', 'tablet');
	ok( exists $asked->{'thinking_off/tablet'}, 'a named device is the one the switch is read for' );
	$asked = undef;
	subs::ai_role_thinking_allowed('chatbot_model');
	ok( exists $asked->{'thinking_off/computer'}, 'with no device named the person\'s machine is read' );
	ok( !exists $asked->{'thinking_off/tablet'}, 'and not the one named last time' );
}

# The role call drops a level this device has switched off, whatever the caller
# carried; the model and the messages are untouched.
my @calls;
{
	$row{'misc/thinking_off'} = 'coding_assistant';
	$row{'coding_assistant'} = 'deepseek:deepseek-flash';
	$row{'coding_assistant_thinking'} = 'high';
	$row{'coding_thinking_off'} = undef;
	$row{'guide_thinking_off'} = undef;
	local *subs::setting_grabber = sub {
		my $s = shift;
		# the mail app's rows are keyed by setting alone; the rest carry app/setting
		my $v = $row{ (($s->{'app'} // '') eq 'mail' ? '' : ($s->{'app'} // '') . '/') . $s->{'setting'} };
		return (defined $v ? $v : undef);
	};
	# the placement step (crew::choose_model) is absent in this file, so the
	# configured model is the one called
	no warnings 'redefine';
	local *subs::ai_model_device = sub { 'computer' };
	local *subs::ai_chat_parts = sub {
		my ($model, $messages, $thinking, $role) = @_;
		push @calls, { model => $model, thinking => $thinking, role => $role };
		return ( [ { type => 'text', text => 'ok' } ], undef );
	};
	my $msgs = [ { role => 'user', content => 'hi' } ];
	my ($parts, $err) = subs::ai_chat_parts_role('coding_assistant', $msgs, 'high');
	is( $err, undef, 'a silenced role still answers' );
	is( $calls[0]{'model'}, 'deepseek:deepseek-flash', 'the model itself is untouched' );
	is( $calls[0]{'thinking'}, '', 'the level the caller carried is dropped for a silenced role' );
	($parts, $err) = subs::ai_chat_parts_role('help_assistant', $msgs, 'max');
	is( $calls[1]{'thinking'}, 'max', 'a role left on keeps the level it was given' );
}

# The panel writes the list, and the role calls read it.
{
	my $misc = read_file("$root/templates/configure/misc_setting_list.html.ep");
	like( $misc, qr/setting="thinking_off" role=/, 'Misc offers a Thinking switch per agent' );
	like( $misc, qr/'coding_assistant', 'Coding agent'/, 'the switch names the Coding agent' );
	like( $misc, qr/'help_assistant'/, 'and the Help guide' );
	unlike( $misc, qr/'text_to_image_assistant'/, 'image generation has no switch, because it never reasons' );

	my $js = read_file("$root/public/js/manager/configure/03_platform_misc.js");
	like( $js, qr/\.misc_setting\[setting="thinking_off"\]/, 'the JS collects the thinking switches' );
	like( $js, qr/setting: 'thinking_off', value: off\.join\(','\)/, 'and saves them as one comma list per device' );

	my $plat = read_file("$root/templates/configure/plat_setting_list.html.ep");
	like( $plat, qr/\$thinking_cap = 0 unless \$allowed_of->\(\$setting\);/, 'Plat hides the Thinking row for a silenced role' );
	like( $plat, qr/class="button ai_model_test"/, 'Plat puts a Test button beside a model' );
	like( $plat, qr/class="cfg-inline ai_model_picker"/, 'the Test button shares the model row, beside the dropdown' );
	like( $plat, qr/\$test_hint/, 'each role says what its Test does in the hover hint' );
	like( $plat, qr/\$cap eq 'video-gen'/, 'the generation roles name their Test too' );
	like( $plat, qr/\$cap eq 'audio'/, 'and so does transcription' );
	like( $plat, qr/id="qa_ux_model"/, 'the UX judgment model lives in the AI tab' );
	like( $plat, qr/setting="qa_ux_model"/, 'and is a model row of its own' );
	my $qa_panel = read_file("$root/templates/configure/qa_panel.html.ep");
	unlike( $qa_panel, qr/id="qa_ux_model"/, 'and has left the QA Nightly tab' );
	like( $js, qr#/manager/configure/ai_model_test#, 'the Test button posts to the model-test route' );
	like( $js, qr/setting: role\.attr\('setting'\)/, 'and names the role whose model it tests' );
	like( $js, qr/\.ai_model_test_status/, 'the answer is shown under the row' );
	like( $js, qr/may cost money/, 'the Test warns that it may cost money' );
	like( $js, qr/jawnosT\(ask\)/, 'and the warning is translatable' );
	like( $js, qr/confirm\(ask\)/, 'and asks before it runs' );
	my $ask_at = index($js, 'confirm(ask)');
	my $post_at = index($js, "url: '/manager/configure/ai_model_test'");
	ok( $ask_at >= 0 && $ask_at < $post_at, 'the confirmation comes before the request' );
}

# The Test button's answer comes from the model itself: ai_chat_raw, not the
# ai_chat_parts wrapper, so a paid model that is stood down is still tried and a
# failure is reported rather than papered over by the free-model fallback.
{
	my @asked;
	local *subs::ai_chat_raw = sub {
		my ($model, $messages, $thinking, $role) = @_;
		push @asked, { model => $model, messages => $messages, thinking => $thinking, role => $role };
		return ({ 'message' => { 'content' => "  OK \n" } }, undef);
	};
	no warnings 'redefine';
	local *subs::ai_chat_parts = sub { die 'ai_chat_parts must not be used by the test' };

	my ($ok, $message) = subs::ai_model_test('  deepseek:deepseek-flash  ', 'help_assistant');
	is( $ok, 1, 'a model that answers passes the test' );
	is( $message, 'the model answered: OK', 'the reply is reported back, whitespace squeezed' );
	is( $asked[0]{'model'}, 'deepseek:deepseek-flash', 'the model is trimmed before the call' );
	is( $asked[0]{'role'}, 'help_assistant', 'the role rides along for spend accounting' );
	like( $asked[0]{'messages'}[0]{'content'}, qr/connection test/, 'one small line is said to the model' );
	is( $asked[0]{'thinking'}, undef, 'the test does not turn thinking on' );

	($ok, $message) = subs::ai_model_test('', 'help_assistant');
	is( $ok, 0, 'no model is not a pass' );
	like( $message, qr/Pick a model first/, 'and says so' );

	local *subs::ai_chat_raw = sub { return (undef, 'the model answered 401: unauthorized') };
	($ok, $message) = subs::ai_model_test('openai:gpt-5', 'help_assistant');
	is( $ok, 0, 'a provider error fails the test' );
	is( $message, 'the model answered 401: unauthorized', 'and the provider\'s reason is carried back' );

	local *subs::ai_chat_raw = sub { return ({ 'message' => { 'content' => "  \n " } }, undef) };
	($ok, $message) = subs::ai_model_test('openai:gpt-5', 'help_assistant');
	is( $ok, 0, 'an empty answer is not a pass' );
	like( $message, qr/nothing readable/, 'and reads as nothing readable' );
}

# The generation roles are tested in their own kind, and transcription through
# its own handshake: none of them is asked a line of text.
{
	my @asked;
	local *subs::data_size = sub { $_[0] . ' bytes' };
	local *subs::ai_text_to_image = sub {
		push @asked, [ 'image', $_[0] ];
		return ('PNGDATA', 'image/png', undef);
	};
	local *subs::ai_text_to_media = sub {
		my ($kind, $data) = @_;
		push @asked, [ $kind, $data ];
		return ('MEDIADATA', $kind . '/test', undef);
	};

	my ($ok, $message) = subs::ai_model_test('openai:gpt-image-1', 'text_to_image_assistant');
	is( $ok, 1, 'an image model that returns bytes passes' );
	like( $message, qr/returned an image \(7 bytes\)/, 'and the image is reported with its size' );
	is( $asked[0][0], 'image', 'the image role uses the image generator' );
	like( $asked[0][1]{'prompt'}, qr/red square/, 'with a tiny test prompt' );
	is( $asked[0][1]{'model'}, 'openai:gpt-image-1', 'and the picked model' );

	($ok, $message) = subs::ai_model_test('openai:tts-1', 'text_to_audio_assistant');
	is( $ok, 1, 'an audio model that returns bytes passes' );
	like( $message, qr/returned audio/, 'and the audio is reported' );
	is( $asked[1][0], 'audio', 'the audio role uses the audio generator' );

	($ok, $message) = subs::ai_model_test('google:veo-3', 'text_to_video_assistant');
	is( $ok, 1, 'a video model that returns bytes passes' );
	like( $message, qr/returned a video/, 'and the video is reported' );
	is( $asked[2][0], 'video', 'the video role uses the video generator' );

	local *subs::ai_text_to_image = sub { return (undef, undef, 'the model answered 403: forbidden') };
	($ok, $message) = subs::ai_model_test('openai:gpt-image-1', 'text_to_image_assistant');
	is( $ok, 0, 'a generation error fails the test' );
	is( $message, 'the model answered 403: forbidden', 'and the provider reason is carried back' );

	local *subs::ai_transcribe_test = sub {
		my ($model) = @_;
		push @asked, [ 'transcribe', $model ];
		return (1, 'the transcription model answered');
	};
	($ok, $message) = subs::ai_model_test('openai:whisper-1', 'transcription_assistant');
	is( $ok, 1, 'the transcription role has its own test' );
	is( $message, 'the transcription model answered', 'and its own answer' );
	is( $asked[3][0], 'transcribe', 'which is not sent through the chat layer' );
	is( $asked[3][1], 'openai:whisper-1', 'the transcription model is the one tested' );
}

# The transcription Test's own handshake: whisper.cpp is judged by readiness,
# a cloud model by the provider's answer to half a second of silence.
{
	local *subs::whisper_available = sub { 1 };
	my ($ok, $message) = subs::ai_transcribe_test('local:whisper.cpp');
	is( $ok, 1, 'whisper.cpp ready here passes' );
	local *subs::whisper_available = sub { 0 };
	($ok, $message) = subs::ai_transcribe_test('local:whisper.cpp');
	is( $ok, 0, 'whisper.cpp missing here fails' );
	like( $message, qr/not installed/, 'and says so' );

	my @asked;
	local *subs::ai_transcribe_cloud_result = sub {
		my ($model, $raw, $lang) = @_;
		push @asked, [ $model, $raw, $lang ];
		return ('', undef);
	};
	($ok, $message) = subs::ai_transcribe_test('openai:whisper-1');
	is( $ok, 1, 'a 2xx with an empty transcript is a pass, because silence is not speech' );
	is( $asked[0][0], 'openai:whisper-1', 'the picked model is the one asked' );
	is( substr($asked[0][1], 0, 4), 'RIFF', 'a small WAV clip is sent' );
	is( $asked[0][2], 'en', 'and it is marked English' );

	local *subs::ai_transcribe_cloud_result = sub { return (undef, 'the transcription model answered 401: unauthorized') };
	($ok, $message) = subs::ai_transcribe_test('openai:whisper-1');
	is( $ok, 0, 'a provider error fails the transcription test' );
	is( $message, 'the transcription model answered 401: unauthorized', 'and its reason is carried back' );
}

done_testing();
