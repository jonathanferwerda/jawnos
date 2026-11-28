# tests-for: lib/JawnOS/Manager/Part28.pm lib/JawnOS/Domain/Ai.pm lib/JawnOS/Domain/VoiceFunnel.pm lib/JawnOS/Controller/manager_misc10.pm lib/JawnOS/Manager/Index.pm perl/gb/03_engines_and_tools.pl perl/help/topics_features.pl perl/help/topics_web.pl docs/voice-funnel.md
# covers:    A spoken request can name another machine and tell it what to do.
#           `remote` is a common voice verb, the name is resolved by the same
#           helper the Network panel uses, the peer's Guide runs the words, and
#           the observation is spoken back. An unknown machine is named back.

use strict;
use warnings;
use utf8;
$| = 1;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JawnOSTest;
use File::Slurp qw(read_file);

require './perl/gb/03_engines_and_tools.pl';
require './perl/help.pl';
require 'JawnOS/Manager/Part28.pm';
require 'JawnOS/Domain/VoiceFunnel.pm';
&subs::preload('voice_brain');

# ------------------------------------------------------------ the name
local *subs::remote_machine_lister = sub {
	return [
		{ uuid => 'u-table', hostname => 'table', fqdn => 'table.jawnos.local', ip => '10.0.0.5' },
		{ uuid => 'u-phone', hostname => 'phone (mirror)', fqdn => 'phone.local', ip => '10.0.0.6' },
	];
};
is(Manager::remote_machine_by_words('the table'), 'u-table', 'a named machine is resolved');
is(Manager::remote_machine_by_words('PHONE'), 'u-phone', 'case and the mirror label do not matter');
is(Manager::remote_machine_by_words('tab'), 'u-table', 'a prefix finds the machine');
is(Manager::remote_machine_by_words('10.0.0.6'), 'u-phone', 'an address finds it too');
is(Manager::remote_machine_by_words('the attic'), '', 'an unknown machine resolves to nothing');
like(read_file('lib/JawnOS/Controller/manager_misc10.pm'), qr/remote_machine_by_words/,
	'the panel command box uses the same resolver');

# ------------------------------------------------------------ the verb and the prompt
my $verbs = subs::voice_funnel_verbs({ app => 'network', id => 'network' });
ok($verbs->{'remote'}, 'a scoped voice turn is offered remote');
like(help::actions_prompt(undef, 0, ''), qr/"action":"remote"/, 'the Guide prompt offers remote');
like(read_file('perl/help/topics_features.pl'), qr/tell the table to/, 'the Voice topic names the form');
like(read_file('perl/help/topics_web.pl'), qr/command box can also be spoken/,
	'the Network topic says the command box is speakable');

# ------------------------------------------------------------ the voice turn
{
	package TestLog;
	sub info { }
	sub warn { }
	sub error { }
	package main;
}
my @replied;
my @sent;
local $subs::log = bless {}, 'TestLog';
local *subs::voice_funnel_enabled = sub { 1 };
local *subs::voice_funnel_fast = sub { undef };
local *subs::voice_funnel_scope = sub {
	return {
		ok => 1, id => 'network', app => 'network', title => 'Network',
		briefing => 'Brief.', why => 'match', score => 90,
		verbs => { map { $_ => 1 } qw/say remote/ },
	};
};
local *subs::ai_role_models = sub { return ('test-model', '') };
my $model_reply = '{"action":"remote","machine":"the table","text":"play Ben Folds Five"}';
local *subs::evaluation_model_call_role = sub {
	return ($model_reply, undef);
};
local *subs::ai_role_thinking_effective = sub { 'off' };
local *subs::guide_resolve_action = sub { return $_[0] };
local *subs::controller_builder = sub { undef };
local *subs::watch_reply = sub { push @replied, $_[1]; return 1 };
local *Manager::remote_machine_by_words = sub { return 'u-table' };
local *Manager::remote_command_send = sub {
	my ($d) = @_;
	push @sent, $d;
	return { ok => 1, observation => 'played Ben Folds Five' };
};

my $turn = subs::voice_brain('tell the table to play Ben Folds Five', {
	chip_id => 'watch-test', ts => &subs::rightNow(),
});
ok($turn && $turn->{'handled'}, 'the voice turn claims the relay');
is($turn->{'action'}, 'remote', 'and records it as a remote command');
is($sent[0]{'uuid'}, 'u-table', 'the resolved machine is the one asked');
is($sent[0]{'text'}, 'play Ben Folds Five', 'the words are carried unchanged');
is($sent[0]{'inactivity_timeout'}, 10, 'a voice turn waits ten seconds, not the panel\'s thirty');
is($sent[0]{'request_timeout'}, 12, 'and bounds the whole request');
is($replied[0], 'played Ben Folds Five', 'the peer\'s observation is spoken back');

# An unknown machine is named back, not sent somewhere arbitrary.
@replied = ();
@sent = ();
$model_reply = '{"action":"remote","machine":"the attic","text":"play Ben Folds Five"}';
local *Manager::remote_machine_by_words = sub { return '' };
my $miss = subs::voice_brain('tell the attic to play Ben Folds Five', {
	chip_id => 'watch-test', ts => &subs::rightNow(),
});
ok($miss && $miss->{'handled'}, 'an unknown machine still claims the turn');
like($replied[0] // '', qr/do not know a machine called the attic/, 'and says which one it could not find');
is(scalar @sent, 0, 'nothing is sent');

like(read_file('docs/voice-funnel.md'), qr/remote_machine_by_words/,
	'the funnel doc names the resolver');

done_testing();
