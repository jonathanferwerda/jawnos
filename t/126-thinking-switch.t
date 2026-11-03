# tests-for: lib/JawnOS/Domain/Ai2.pm templates/configure/misc_setting_list.html.ep public/js/manager/configure/03_platform_misc.js templates/configure/plat_setting_list.html.ep
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
}

done_testing();
