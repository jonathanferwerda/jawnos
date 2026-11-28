# tests-for: perl/gb/03_engines_and_tools.pl perl/help.pl lib/JawnOS/Controller/manager_help.pm lib/JawnOS/Routes/manager_help.pm public/js/manager/help.js lib/JawnOS/Domain/VoiceFunnel.pm
# covers:    The Guide window and its associate have the watch's answers: the app
#           tool is no longer voice-only, the full Guide prompt offers app,
#           weather and history, the weather/history routes read the same
#           resolvers the wrist uses, and the Associate executes them in the
#           browser. A no-argument route call is an error, not a forecast fetch.

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
use Mojolicious;
use Mojo::Transaction::HTTP;

require './perl/gb/03_engines_and_tools.pl';
require './perl/help.pl';
require 'JawnOS/Routes.pm';
require 'JawnOS/Controller/manager_help.pm';

# ------------------------------------------------------------ the vocabulary
my $live = &help::live_verb_names();
ok($live->{'app'}, 'the full Guide may choose the app tool');
ok($live->{'weather'}, 'and the weather tool');
ok($live->{'history'}, 'and the history tool');

my $prompt = &help::actions_prompt(undef, 0, '');
like($prompt, qr/"action":"app"/, 'the Guide prompt offers app');
like($prompt, qr/"action":"weather"/, 'the Guide prompt offers weather');
like($prompt, qr/"action":"history"/, 'the Guide prompt offers history');
like(&help::app_action_lines('market'), qr/"add_item"/,
	'a Market turn carries its declared app actions');

my $help_src = read_file('perl/help.pl');
unlike($help_src, qr/voice_only/, 'no voice-only gate remains in the Guide registry');
my $gb_src = read_file('perl/gb/03_engines_and_tools.pl');
unlike($gb_src, qr/voice_only/, 'and no tool is marked voice-only');

# ------------------------------------------------------------ the routes
my %route = map { lc($_->[1]) . ' ' . $_->[2] => $_->[3] } @{ JawnOS::Routes->table };
is($route{'get /manager/help/weather'}, 'action_37703', 'the weather route names its action');
is($route{'get /manager/help/history'}, 'action_37704', 'the history route names its action');
ok(defined &main::Manager::action_37703, 'the weather action exists');
ok(defined &main::Manager::action_37704, 'the history action exists');

my $app = Mojolicious->new(quiet => 1);
my @keep_tx;
my $controller = sub {
	my ($path) = @_;
	my $tx = Mojo::Transaction::HTTP->new;
	$tx->req->method('GET');
	$tx->req->url->path($path);
	push @keep_tx, $tx;
	return $app->build_controller($tx);
};

# ------------------------------------------------------------ weather
local *subs::voice_funnel_weather_answer = sub {
	my ($when, $what, $text) = @_;
	return { handled => 1, speech => 'It is 4 and cloudy' . (length($text) ? " $text" : '') . '.' };
};
my $c = $controller->('/manager/help/weather');
$c->req->url->query({ when => 'now', where => 'Sarnia', what => 'now' });
&main::Manager::action_37703($c);
my $w = $c->res->json;
ok($w && $w->{'ok'}, 'the weather route answers');
is($w->{'speech'}, 'It is 4 and cloudy in Sarnia.', 'the weather speech carries the place');

$c = $controller->('/manager/help/weather');
&main::Manager::action_37703($c);
my $bare = $c->res->json;
ok($bare && !$bare->{'ok'}, 'a no-argument weather call is an error');
like($bare->{'error'}, qr/weather/i, 'and says what to ask');

# ------------------------------------------------------------ history
local *Manager::media_unlock_device = sub { return 'device123' };
local *subs::voice_funnel_history_answer = sub {
	my ($text, $meta) = @_;
	return { handled => 1, speech => 'You last saw Brian Coulbeck on Wednesday (' . $text . ').' };
};
$c = $controller->('/manager/help/history');
$c->req->url->query({ query => 'Brian Coulbeck', which => 'last', kind => 'person' });
&main::Manager::action_37704($c);
my $h = $c->res->json;
ok($h && $h->{'ok'}, 'the history route answers');
like($h->{'speech'}, qr/Brian Coulbeck/, 'the history speech names the person');
like($h->{'speech'}, qr/when did i last see Brian Coulbeck/, 'the structured fields shape the resolver question');

$c = $controller->('/manager/help/history');
&main::Manager::action_37704($c);
my $bare_h = $c->res->json;
ok($bare_h && !$bare_h->{'ok'}, 'a no-argument history call is an error');

# ------------------------------------------------------------ the screen's executor
my $js = read_file('public/js/manager/help.js');
like($js, qr{/manager/help/weather}, 'the Associate asks for the weather');
like($js, qr{/manager/help/history}, 'the Associate asks for history');
like($js, qr/could not read the forecast/i, 'and has a failure line for weather');

my $ctl = read_file('lib/JawnOS/Controller/manager_help.pm');
like($ctl, qr/app_action_lines/, 'the Guide prompt carries the app action list');
like($ctl, qr/confirmed.*1/, 'and tells the model to confirm a write');
like($ctl, qr/voice_funnel_scope/, 'a general Guide turn can find the app by its words');

done_testing();
