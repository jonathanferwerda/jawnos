# tests-for: lib/JawnOS/Domain/VoiceFunnel.pm lib/JawnOS/Domain/Ai.pm lib/JawnOS/Manager/Part28.pm perl/help/topics_features.pl
# covers:    A spoken request is funnelled to one help topic before the Guide is
#           asked, so the prompt carries one app's help instead of every app's.
#           The deterministic matcher must not match a short app name inside a
#           longer word, a weak match goes to the tiny router agent, the scoped
#           verb set is smaller than the full Guide vocabulary, and "me" reads
#           as Jonathan Ferwerda when the house has no my_name row. Weather is
#           the first resolver that answers without a model at all.

use strict;
use warnings;
use utf8;
$| = 1;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JawnOSTest;
use Mojo::SQLite;

binmode Test::More->builder->output,         ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';

require './perl/help.pl';
require 'JawnOS/Domain/VoiceFunnel.pm';

# A throwaway database holds only what the identity and measure paths read.
my $dbfile = "$JawnOSTest::SANDBOX/voice-funnel-unit.sqlite";
unlink $dbfile if -e $dbfile;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db = $sql->db;
$db->query('create table people (app text, name text, status text)');
$db->query('create table settings (app text, setting text, value text, device text, server_time text)');
$db->query("insert into people (app, name, status) values ('jon_ferwerda', 'Jonathan Ferwerda', 'active')");
$db->query("insert into people (app, name, status) values ('jon_ferwerda', 'Jonathan Ferwerda', 'active')");
$db->query("insert into people (app, name, status) values ('brian_coulbeck', 'Brian Coulbeck', 'active')");
my @st = stat($dbfile);
$gb::database_holder = {
	server_time => &subs::rightNow(),
	database    => $dbfile,
	db          => $db,
	dbh         => $db->dbh,
	sql         => $sql,
	pid         => $$,
	dev         => $st[0],
	ino         => $st[1],
};
$subs::say_quiet = 1;
$subs::sync_table_cache = undef;

# ------------------------------------------------------------ the matcher
my @weather = &subs::voice_funnel_match("what's the weather tomorrow");
ok(@weather, 'weather words produce candidates');
is($weather[0]->{'id'}, 'weather', 'the weather topic wins a weather question');
cmp_ok($weather[0]->{'score'}, '>=', 40, 'a clear app word scores well');

my @market = &subs::voice_funnel_match('add milk to the shopping list');
ok(@market, 'shopping words produce candidates');
is($market[0]->{'id'}, 'market', 'the shopping list is Market');

my @spend = &subs::voice_funnel_match('how much did i spend this month');
ok(!(grep { $_->{'id'} eq 'pen' && $_->{'score'} > 20 } @spend),
	'a short app name is not matched inside a longer word');

my @weight = &subs::voice_funnel_match('what do i weigh');
ok(@weight, 'a weight question produces candidates');
is($weight[0]->{'id'}, 'measures', 'the measures page is the best deterministic match');

# ------------------------------------------------------------ the scope
my $scope = &subs::voice_funnel_scope("what's the weather tomorrow");
ok($scope->{'ok'}, 'a clear question gets a scope');
is($scope->{'id'}, 'weather', 'the scope names the weather topic');
like($scope->{'briefing'}, qr/Title: Weather/, 'the scoped prompt carries the weather help');
ok($scope->{'verbs'}->{'where_when'}, 'the weather scope may read a place');
ok(!($scope->{'verbs'}->{'create'}), 'the weather scope is not offered the appointment verbs');
cmp_ok(scalar(keys %{ $scope->{'verbs'} }), '<=', 10, 'the scoped verb set stays small');

my $market_scope = &subs::voice_funnel_scope('add milk to the shopping list');
ok($market_scope->{'ok'}, 'the shopping list gets a scope');
is($market_scope->{'id'}, 'market', 'the scope names Market');
like($market_scope->{'briefing'}, qr/Title: Market/, 'the Market help is the prompt context');

# ------------------------------------------------------------ the router agent
# The real router is one model call; here it is a stub so the test is offline
# and proves only the contract: a tiny catalogue in, one topic id out.
&subs::preload('json_from_model');
&subs::preload('evaluation_model_call_role');
local *subs::evaluation_model_call_role = sub {
	return ('{"id":"market","confidence":0.91}', undef);
};
my $routed = &subs::voice_funnel_router('add milk to the list', 'test-router');
ok($routed->{'ok'}, 'the router returns a scope');
is($routed->{'id'}, 'market', 'the router picked the topic it answered');
is($routed->{'why'}, 'router', 'the scope records how it was chosen');

# ------------------------------------------------------------ identity
my $identity = &subs::voice_funnel_identity();
is($identity->{'app'}, 'jon_ferwerda', 'the self person is jon_ferwerda');
is($identity->{'name'}, 'Jonathan Ferwerda', 'the display name is read from people');
ok((grep { $_ eq 'jon' } @{ $identity->{'aliases'} || [] }), 'both Jon and Jonathan answer for the person');
is(&subs::voice_funnel_self_app(), 'jon_ferwerda', 'the measure fallback can name the self app');
like(&subs::voice_funnel_identity_prompt(), qr/Jonathan Ferwerda/,
	'the Guide prompt names the person');

ok(&subs::voice_funnel_enabled(), 'the funnel is on by default');
{
	local *subs::setting_grabber = sub { return 'off' };
	ok(!&subs::voice_funnel_enabled(), 'the voice_funnel setting can turn it off');
}

my $block = &subs::voice_funnel_prompt_block($scope);
like($block, qr/MATCHED HELP TOPIC: Weather/, 'the prompt block names the matched topic');
like($block, qr/Jonathan Ferwerda/, 'the prompt block carries the person');

# ------------------------------------------------------------ weather fast path
my $key = &subs::weather_day_key(&subs::rightNow() + 86400000);
local *subs::signatorial_designer = sub { return 'test-device' };
local *subs::weather_device_fix = sub { return { lat => 42.97, lon => -82.40 } };
local *subs::weather_fetch = sub {
	return {
		current => { temperature => 4, feels_like => 1, condition => 'Cloudy', wind_speed => 12 },
		daily => [ { date => $key, high => 6, low => -1, condition => 'Light rain', precip_prob => 70 } ],
		hourly => [],
	};
};
my $answer = &subs::voice_funnel_weather_answer('tomorrow', 'now', 'what is the weather tomorrow');
ok($answer && $answer->{'handled'}, 'weather is answered without a Guide model');
like($answer->{'speech'}, qr/Tomorrow/, 'the answer names tomorrow');
like($answer->{'speech'}, qr/high 6/, 'the answer carries the high');

# ------------------------------------------------------------ measure identity fallback
# help_measure used to require me/my_name; the funnel self app is the fallback.
require "$FindBin::Bin/../lib/JawnOS/Manager/Part28.pm";
local *subs::settings_grabber = sub { return {} };
local *Manager::help_weight_projection = sub {
	return { readings => 1, latest => 172, target => 180, slope_per_week => '-0.1', days => 30, when => 'December 27, 2026' };
};
my $measure = &Manager::help_measure('weight', 'month', '');
ok($measure->{'text'}, 'weight is answered without a my_name row');
like($measure->{'text'}, qr/172/, 'the reading comes from the self person');

# ------------------------------------------------------------ voice_brain wiring
# The funnel is only useful if voice_brain actually uses it. Stub the model and
# observe the system prompt: it must carry the matched topic, not the full set
# of apps.
package TestLog;
sub info { }
sub warn { }
sub error { }
package main;

&subs::preload('voice_brain');
&subs::preload('ai_role_models');
&subs::preload('evaluation_model_call_role');
&subs::preload('ai_role_thinking_effective');
&subs::preload('json_from_model');
&subs::preload('guide_resolve_action');

my @captured;
my @replied;
local $subs::log = bless {}, 'TestLog';
local *subs::voice_funnel_fast = sub { return undef };
local *subs::voice_funnel_scope = sub {
	return {
		ok => 1, id => 'weather', app => 'weather', title => 'Weather',
		briefing => 'Title: Weather\nSummary: The forecast.', why => 'match', score => 90,
		verbs => { map { $_ => 1 } qw/say ask done find open_app alias unalias where_when/ },
	};
};
local *subs::ai_role_models = sub { return ('test-model', '') };
local *subs::evaluation_model_call_role = sub {
	my ($role, $system, $user) = @_;
	push @captured, $system;
	return ('{"action":"say","text":"It is cold."}', undef);
};
local *subs::ai_role_thinking_effective = sub { return 'off' };
local *subs::setting_grabber = sub { return '' };
local *subs::watch_reply = sub { push @replied, $_[1]; return 1 };
my $wired = &subs::voice_brain("what's the weather", { chip_id => 'watch-test', ts => &subs::rightNow() });
ok($wired && $wired->{'handled'}, 'voice_brain claims a scoped turn');
like($captured[0] // '', qr/MATCHED HELP TOPIC: Weather/,
	'the Guide prompt carries the matched topic');
like($captured[0] // '', qr/Only the actions listed above exist on this turn/,
	'the prompt says the scoped list is the whole list');
is($replied[0] // '', 'It is cold.', 'the Guide answer is spoken back');

# The weather fast path claims the turn before the model is chosen.
my @fast_replied;
local *subs::voice_funnel_fast = sub {
	return { handled => 1, kind => 'weather', speech => 'It is 4 degrees.' };
};
local *subs::watch_reply = sub { push @fast_replied, $_[1]; return 1 };
my $fast = &subs::voice_brain('what is the weather', { chip_id => 'watch-test', ts => &subs::rightNow() });
ok($fast && $fast->{'action'} eq 'funnel', 'the fast weather path claims the turn');
is($fast_replied[0] // '', 'It is 4 degrees.', 'the fast answer is spoken directly');

# Turning the funnel off restores the old unscoped prompt; the fast resolvers
# must not run either.
@captured = ();
{
	local *subs::voice_funnel_enabled = sub { return 0 };
	local *subs::voice_funnel_fast = sub { die 'fast resolver ran with the funnel off' };
	local *subs::voice_funnel_scope = sub { die 'scope ran with the funnel off' };
	my $off = &subs::voice_brain("what's the weather", { chip_id => 'watch-test', ts => &subs::rightNow() });
	ok($off && $off->{'handled'}, 'voice still answers with the funnel off');
	unlike($captured[0] // '', qr/MATCHED HELP TOPIC/,
		'the off path keeps the old unscoped prompt');
}

done_testing();
