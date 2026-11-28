# tests-for: lib/JawnOS/Domain/Activity.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Ai.pm lib/JawnOS/Routes/manager_misc10.pm lib/JawnOS/Controller/manager_misc10.pm public/js/manager/voice_card.js public/js/manager/websocket/00_console_router.js public/css/manager.css lib/JawnOS/Manager/Core1_tables_hooks.pm perl/help/topics_features.pl docs/voice-funnel.md
# covers:    The machine the person last touched is stamped from page activity,
#           the newest stamp is read as the display target, and a voice reply
#           sends a voiceCard command with the question and answer. The route
#           writes a stamp, the card JS filters by device uuid, and the page
#           throttles its pings.

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

require 'JawnOS/Domain/Activity.pm';
require 'JawnOS/Routes.pm';
require 'JawnOS/Controller/manager_misc10.pm';
&subs::preload('db_select');
&subs::preload('setting_grabber');
&subs::preload('setting_setter');
&subs::preload('rightNow');
&subs::preload('voice_brain');

package FakeRows;
sub hashes { return $_[0]->{'rows'}; }
package main;

my %store;
local *subs::setting_grabber = sub { my ($h) = @_; return $store{ $h->{'device'} } // ''; };
local *subs::setting_setter = sub { my ($h) = @_; $store{ $h->{'device'} } = $h->{'value'}; return { ok => 1 }; };
local *subs::db_select = sub {
	my @rows = map { { device => $_, value => $store{$_} } } sort keys %store;
	return bless { rows => \@rows }, 'FakeRows';
};
my $now = 1_800_000_000_000;
local *subs::rightNow = sub { return $now };

is(subs::activity_touch('dev-a'), $now, 'the first stamp is written');
is($store{'dev-a'}, $now, 'and stored against the device');
$now += 1000;
is(subs::activity_touch('dev-a'), 1_800_000_000_000, 'a quick repeat is throttled');
$now += 25_000;
is(subs::activity_touch('dev-b'), $now, 'another machine stamps');
is(subs::activity_most_recent(), 'dev-b', 'the newest machine wins');
is(subs::activity_most_recent('dev-b'), 'dev-a', 'an excluded machine is skipped');
is(subs::activity_touch('bad/name'), 0, 'a device id with a slash is refused');
my $recent = subs::activity_recent(1);
is(scalar @{$recent}, 1, 'the recent list is bounded');
is($recent->[0]{'device'}, 'dev-b', 'and newest first');

# ------------------------------------------------------------ the card
my @sent;
{
	no warnings 'redefine';
	no warnings 'prototype';
	local *Websocket::console_command = sub { my ($cmd, @args) = @_; return { cmd => $cmd, args => \@args }; };
	local *Websocket::send = sub {
		my ($app, $msg) = @_;
		push @sent, { app => $app, msg => $msg };
		return 1;
	};
	ok(subs::voice_card_show('what is the weather', 'It is 4 degrees.'), 'the card is sent');
}
is($sent[0]{'app'}, 'server', 'on the server channel');
is($sent[0]{'msg'}{'console'}{'cmd'}, 'voiceCard', 'as the voice card command');
is($sent[0]{'msg'}{'console'}{'args'}[0]{'device_uuid'}, 'dev-b', 'to the newest machine');
is($sent[0]{'msg'}{'console'}{'args'}[0]{'question'}, 'what is the weather', 'with the question');
is($sent[0]{'msg'}{'console'}{'args'}[0]{'reply'}, 'It is 4 degrees.', 'and the reply');

# ------------------------------------------------------------ the route
my %route = map { lc($_->[1]) . ' ' . $_->[2] => $_->[3] } @{ JawnOS::Routes->table };
is($route{'post /manager/activity'}, 'action_92031', 'the activity route names its action');
ok(defined &main::Manager::action_92031, 'the activity action exists');
my $app = Mojolicious->new(quiet => 1);
my $tx = Mojo::Transaction::HTTP->new;
$tx->req->method('POST');
$tx->req->url->path('/manager/activity');
$tx->req->url->query({ device_uuid => 'dev-a' });
my $c = $app->build_controller($tx);
local *subs::activity_touch = sub { return 12345 };
&main::Manager::action_92031($c);
my $json = $c->res->json;
ok($json && $json->{'ok'}, 'the activity route answers');
is($json->{'at'}, 12345, 'and reports the stamp');

# ------------------------------------------------------------ the voice hook
{
	package TestLog;
	sub info { }
	sub warn { }
	sub error { }
	package main;
}
my @replied;
my @cards;
local $subs::log = bless {}, 'TestLog';
local *subs::voice_funnel_enabled = sub { 1 };
local *subs::voice_funnel_fast = sub { return { handled => 1, kind => 'weather', speech => 'It is 4 degrees.' } };
local *subs::watch_reply = sub { push @replied, $_[1]; return 1 };
local *subs::voice_card_show = sub { push @cards, [ @_ ] };
my $turn = subs::voice_brain("what's the weather", { chip_id => 'watch-test', ts => &subs::rightNow() });
ok($turn && $turn->{'handled'}, 'the voice turn still answers');
is($cards[0][0], "what's the weather", 'the card carries the question');
is($cards[0][1], 'It is 4 degrees.', 'and the spoken reply');
is($replied[0], 'It is 4 degrees.', 'the reply is still spoken to the watch');

# ------------------------------------------------------------ the page side
like(read_file('public/js/manager/voice_card.js'), qr/function jawnVoiceCardShow/,
	'the card script defines the drawing function');
like(read_file('public/js/manager/voice_card.js'), qr{/manager/activity},
	'and the page pings the activity route');
like(read_file('public/js/manager/voice_card.js'), qr/deviceorientation/,
	'a phone or tablet movement counts');
like(read_file('public/js/manager/websocket/00_console_router.js'), qr/voiceCard:\s*function/,
	'the console router knows the card');
like(read_file('public/css/manager.css'), qr/\.jawn_voice_card\b/,
	'the card has its own styles');
like(read_file('lib/JawnOS/Manager/Core1_tables_hooks.pm'), qr{/js/manager/voice_card\.js},
	'the card script is in the core bundle');
like(read_file('perl/help/topics_features.pl'), qr/machine you last touched/,
	'the Voice topic names the card');
like(read_file('docs/voice-funnel.md'), qr/voice_card_show/,
	'the funnel doc names the card');

done_testing();
