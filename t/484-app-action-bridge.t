# tests-for: lib/JawnOS/Domain/VoiceFunnel.pm lib/JawnOS/Domain/Ai.pm lib/JawnOS/Manager/Part29.pm lib/JawnOS/Routes.pm perl/gb/03_engines_and_tools.pl perl/help.pl
# covers:    The app-action bridge: one validated `app` tool calls an app's own
#           route with that app's help in context. The registry is the whole
#           vocabulary (an undeclared app/do/parameter is refused), the route
#           must be in the server's own table, visibility uses the Guide's rule,
#           a write waits for confirmation unless the house turned it off, and
#           the scoped prompt names only the actions the executor accepts.

use strict;
use warnings;
use utf8;
$| = 1;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JawnOSTest;
use Mojolicious;
use Mojo::Transaction::HTTP;

require './perl/gb/03_engines_and_tools.pl';
require './perl/help.pl';
require 'JawnOS/Routes.pm';
require 'JawnOS/Manager/Part29.pm';
require 'JawnOS/Domain/VoiceFunnel.pm';
&subs::preload('voice_brain');

# ------------------------------------------------------------ the registry
# Every declared action names a route the server actually dispatches, and an app
# whose help topic exists. A read is a GET that cannot write; a write is a POST.
my $table = JawnOS::Routes->table;
my %route = map { lc($_->[1]) . ' ' . $_->[2] => $_->[3] } @{$table};
my %topic_app = map { (help::get($_->{'id'})->{'app'} // '') => 1 } help::catalogue();
foreach my $a ( @gb::app_actions ) {
	my $key = lc($a->{'method'}) . ' ' . $a->{'route'};
	ok($route{$key}, $a->{'app'} . ' ' . $a->{'do'} . ' names a real route');
	like($a->{'kind'} // '', qr/^(?:read|write)$/, $a->{'app'} . ' ' . $a->{'do'} . ' has a known kind');
	is(lc($a->{'method'}), $a->{'kind'} eq 'read' ? 'get' : 'post',
		$a->{'app'} . ' ' . $a->{'do'} . ' uses the method its kind requires');
	ok($topic_app{ $a->{'app'} }, $a->{'app'} . ' has a help topic');
	ok(ref $a->{'speech'} eq 'CODE', $a->{'app'} . ' ' . $a->{'do'} . ' can speak its result');
	foreach my $p ( sort keys %{ $a->{'params'} || {} } ) {
		like($p, qr/^[a-z][a-z0-9_]*$/, $a->{'app'} . ' parameter name is a plain key');
	}
}

# ------------------------------------------------------------ the executor
# The action handlers are stubs: the bridge is what is under test, and it must
# hand the route exactly the declared parameters and read only a JSON answer.
my ($calls, $last_folder, $last_text) = (0);
{
	no warnings 'redefine';
	*main::Manager::action_22738 = sub {
		my $c = shift;
		$c->render(json => {
			timers => [ { state => 'running' } ],
			alarms => [ { enabled => 1, next_at => time() * 1000 + 60000, label => 'Test' } ],
		});
	};
	*main::Manager::action_31717 = sub {
		my $c = shift;
		$calls++;
		$last_folder = $c->param('folder');
		$c->render(json => { total => 3 });
	};
	*main::Manager::action_3429 = sub {
		my $c = shift;
		$calls++;
		$last_text = $c->param('text');
		$c->render(json => { item => { text => $c->param('text') } });
	};
}

my $confirm_setting = 'on';
my $visible = 1;
local *Manager::help_app_visible = sub { $visible };
local *Manager::media_unlock_device = sub { 'device123' };
local *subs::setting_grabber = sub {
	my ($h) = @_;
	return $confirm_setting if (($h && $h->{'setting'}) // '') eq 'guide_confirm';
	return '';
};

my $fake_app;
sub fake_controller {
	$fake_app ||= Mojolicious->new(quiet => 1);
	my $tx = Mojo::Transaction::HTTP->new;
	$tx->req->method('GET');
	$tx->req->url->path('/manager/help/app');
	return $fake_app->build_controller($tx);
}
my $c = fake_controller();

my $read = Manager::app_action_execute($c,
	{ action => 'app', app => 'clock', do => 'timers' },
	{ voice => 1, scope_app => 'clock' });
ok($read->{'ok'}, 'a declared read runs');
like($read->{'speech'}, qr/1 timer running/, 'the read speech summarises the timers');
like($read->{'speech'}, qr/next alarm is "Test"/, 'and names the next alarm');

my $mail = Manager::app_action_execute($c,
	{ action => 'app', app => 'email', do => 'count', params => { folder => 'inbox' } },
	{ voice => 1, scope_app => 'email' });
ok($mail->{'ok'}, 'the mail count runs');
is($last_folder, 'inbox', 'the declared parameter reaches the route');
is($mail->{'speech'}, 'The inbox holds 3 threads.', 'the read speech counts the folder');

# A write waits for the Confirmation Requirement; a voice turn cannot say yes.
# The same turn with the requirement off runs, and the browser may confirm.
$confirm_setting = 'on';
$calls = 0;
my $write = Manager::app_action_execute($c,
	{ action => 'app', app => 'market', do => 'add_item', params => { text => 'milk' } },
	{ voice => 1, scope_app => 'market' });
ok($write->{'confirm'}, 'a voice write is proposed, not run');
is($calls, 0, 'the route is not called while the write waits');
like($write->{'speech'}, qr/shopping list/, 'the proposal says what it would do');

$write = Manager::app_action_execute($c,
	{ action => 'app', app => 'market', do => 'add_item', params => { text => 'milk' }, confirmed => 1 },
	{ voice => 1, scope_app => 'market' });
ok($write->{'confirm'}, 'a voice turn cannot certify its own confirmation');

$write = Manager::app_action_execute($c,
	{ action => 'app', app => 'market', do => 'add_item', params => { text => 'milk' }, confirmed => 1 },
	{ scope_app => 'market' });
ok($write->{'ok'}, 'the screen may confirm a write');
is($calls, 1, 'the route runs once after confirmation');
is($last_text, 'milk', 'the declared text reaches the route');
is($write->{'speech'}, 'Added milk to the shopping list.', 'the write speech reports the item');

$confirm_setting = 'off';
$calls = 0;
$write = Manager::app_action_execute($c,
	{ action => 'app', app => 'market', do => 'add_item', params => { text => 'eggs' } },
	{ voice => 1, scope_app => 'market' });
ok($write->{'ok'}, 'with the requirement off a voice write runs');
is($calls, 1, 'the route runs without a separate confirmation');

# ------------------------------------------------------------ the gates
$confirm_setting = 'on';
$visible = 0;
my $hidden = Manager::app_action_execute($c,
	{ action => 'app', app => 'clock', do => 'timers' }, { voice => 1, scope_app => 'clock' });
ok(!$hidden->{'ok'}, 'a hidden app is refused');
like($hidden->{'error'}, qr/hidden/, 'the refusal names visibility');
$visible = 1;

my $scope = Manager::app_action_execute($c,
	{ action => 'app', app => 'clock', do => 'timers' }, { voice => 1, scope_app => 'email' });
ok(!$scope->{'ok'}, 'an action outside the scoped app is refused');
like($scope->{'error'}, qr/different app/, 'the refusal names the scope');

my $unknown = Manager::app_action_execute($c,
	{ action => 'app', app => 'market', do => 'nope' }, { voice => 1 });
ok(!$unknown->{'ok'}, 'an undeclared do is refused');

$confirm_setting = 'off';
my $param = Manager::app_action_execute($c,
	{ action => 'app', app => 'market', do => 'add_item', params => { text => 'milk', evil => 'x' } },
	{ voice => 1, scope_app => 'market' });
ok(!$param->{'ok'}, 'an undeclared parameter is refused');
like($param->{'error'}, qr/"evil"/, 'the refusal names the parameter');

my $missing = Manager::app_action_execute($c,
	{ action => 'app', app => 'market', do => 'add_item' },
	{ voice => 1, scope_app => 'market' });
ok(!$missing->{'ok'}, 'a missing required parameter is refused');
like($missing->{'error'}, qr/need the item/, 'the refusal says what is missing');

{
	no warnings 'redefine';
	*main::Manager::action_22738 = sub { my $c = shift; $c->render(text => 'not json'); };
}
my $html = Manager::app_action_execute($c,
	{ action => 'app', app => 'clock', do => 'timers' }, { voice => 1, scope_app => 'clock' });
ok(!$html->{'ok'}, 'a non-JSON answer is refused');
like($html->{'error'}, qr/result I can read/, 'the refusal says the result was unreadable');

{
	no warnings 'redefine';
	*main::Manager::action_3429 = sub { my $c = shift; $c->render(json => { error => 'empty' }); };
}
my $refused = Manager::app_action_execute($c,
	{ action => 'app', app => 'market', do => 'add_item', params => { text => 'x' } },
	{ voice => 1, scope_app => 'market' });
ok(!$refused->{'ok'}, 'an app error is a failed action');
like($refused->{'error'}, qr/refused that: empty/, 'the app error is carried into the speech');

# The browser fallback runs the same bridge through guide_verb_execute.
{
	no warnings 'redefine';
	*main::Manager::action_22738 = sub {
		my $c = shift;
		$c->render(json => { timers => [ { state => 'running' } ], alarms => [] });
	};
}
my $verb = Manager::guide_verb_execute($c,
	{ action => 'app', app => 'clock', do => 'timers', confirmed => 1 });
like($verb, qr/1 timer running/, 'guide_verb_execute carries the app observation');

# ------------------------------------------------------------ the prompt
like(help::app_action_lines('market'), qr/APP ACTIONS for market/,
	'the scoped prompt has an app-action block');
like(help::app_action_lines('market'), qr/"add_item" \(write\)/,
	'the block names the declared write');
ok(subs::voice_funnel_verbs({ app => 'market', id => 'market' })->{'app'},
	'a market scope is offered the app verb');
ok(!subs::voice_funnel_verbs({ app => 'weather', id => 'weather' })->{'app'},
	'an app with no declared actions is not');

my $block = subs::voice_funnel_prompt_block({
	ok => 1, app => 'market', title => 'Market', briefing => 'Brief.',
});
like($block, qr/APP ACTIONS for market/, 'the prompt block carries the actions');
like($block, qr/only these "do" values/, 'and says the list is closed');

my $with = help::actions_prompt({ say => 1, app => 1 }, 0, '');
like($with, qr/"action":"app"/, 'a scoped turn is offered the app tool');
my $without = help::actions_prompt({ say => 1 }, 0, '');
unlike($without, qr/"action":"app"/, 'the full Guide is not offered the voice-only tool');

# ------------------------------------------------------------ the voice branch
package TestLog;
sub info { }
sub warn { }
sub error { }
package main;

my @replied;
local $subs::log = bless {}, 'TestLog';
local *subs::voice_funnel_enabled = sub { 1 };
local *subs::voice_funnel_fast = sub { undef };
local *subs::voice_funnel_scope = sub {
	return {
		ok => 1, id => 'market', app => 'market', title => 'Market',
		briefing => 'Brief.', why => 'match', score => 90,
		verbs => { map { $_ => 1 } qw/say ask done app/ },
	};
};
local *subs::ai_role_models = sub { return ('test-model', '') };
local *subs::evaluation_model_call_role = sub {
	return ('{"action":"app","app":"market","do":"add_item","params":{"text":"milk"}}', undef);
};
local *subs::ai_role_thinking_effective = sub { 'off' };
local *subs::guide_resolve_action = sub { return $_[0] };
local *subs::controller_builder = sub { return undef };
local *subs::watch_reply = sub { push @replied, $_[1]; return 1 };
local *Manager::app_action_execute = sub {
	return { ok => 1, speech => 'Added milk to the shopping list.' };
};
my $voice = subs::voice_brain('add milk to the shopping list', { chip_id => 'watch-test', ts => &subs::rightNow() });
ok($voice && $voice->{'handled'}, 'voice_brain claims a declared app action');
is($voice->{'action'}, 'app', 'the turn is recorded as the app bridge');
is($replied[0] // '', 'Added milk to the shopping list.', 'the app result is spoken back');

@replied = ();
local *Manager::app_action_execute = sub {
	return { ok => 0, confirm => 1, speech => 'I can add that to the shopping list. Confirm it and I will.' };
};
$voice = subs::voice_brain('add milk to the shopping list', { chip_id => 'watch-test', ts => &subs::rightNow() });
ok($voice && $voice->{'handled'}, 'a proposed write still claims the turn');
like($replied[0] // '', qr/Confirm it/, 'the confirmation question is spoken');

done_testing();
