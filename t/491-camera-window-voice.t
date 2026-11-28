# tests-for: perl/gb/03_engines_and_tools.pl lib/JawnOS/Manager/Part28.pm lib/JawnOS/Manager/Part29.pm lib/JawnOS/Domain/Ai.pm lib/JawnOS/Domain/VoiceFunnel.pm lib/JawnOS/Controller/manager_misc6.pm lib/JawnOS/Routes/manager_misc6.pm public/js/manager/camera.js public/js/manager/windows/03_stack.js public/js/manager/websocket/00_console_router.js perl/help/topics_features.pl perl/help/topics_web.pl
# covers:    The camera and the window are reachable by the same funnel as the rest:
#           camera photo/video are declared app actions that press the open Camera
#           window's own buttons, close_app is the twin of open_app and runs the
#           window's own close press, both are offered to the voice turn, and the
#           Voice topic no longer claims the untrained Jawn Do wake phrase works.

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
require 'JawnOS/Manager/Part29.pm';
require 'JawnOS/Manager/Part28.pm';
require 'JawnOS/Domain/VoiceFunnel.pm';
require 'JawnOS/Controller/manager_misc6.pm';

# The server only builds a command; the browser is what presses the button. A
# recording Websocket is enough to see what the route asked for.
no warnings 'redefine';
no warnings 'prototype';
our @ws_sent;
local *Websocket::console_command = sub {
	my ($cmd, @args) = @_;
	return { cmd => $cmd, args => \@args };
};
local *Websocket::send = sub {
	my ($app, $msg) = @_;
	push @ws_sent, { app => $app, msg => $msg };
	return 1;
};

# ------------------------------------------------------------ the registry
my $photo = help::app_action_find('camera', 'photo');
ok($photo, 'camera photo is a declared app action');
is($photo->{'kind'}, 'write', 'and it is a write');
is(lc($photo->{'method'}), 'post', 'so its route is a POST');
is($photo->{'route'}, '/manager/camera/photo', 'and names the camera route');
my $video = help::app_action_find('camera', 'video');
ok($video, 'camera video is a declared app action');
is($video->{'route'}, '/manager/camera/video', 'and names its own route');

my %route = map { lc($_->[1]) . ' ' . $_->[2] => $_->[3] } @{ JawnOS::Routes->table };
is($route{'post /manager/camera/photo'}, 'action_92011', 'the photo route names its action');
is($route{'post /manager/camera/video'}, 'action_92012', 'the video route names its action');
ok(defined &main::Manager::action_92011, 'the photo action exists');
ok(defined &main::Manager::action_92012, 'the video action exists');

# ------------------------------------------------------------ the bridge runs it
my $mojo = Mojolicious->new(quiet => 1);
my @keep_tx;
my $controller = sub {
	my ($path) = @_;
	my $tx = Mojo::Transaction::HTTP->new;
	$tx->req->method('POST');
	$tx->req->url->path($path);
	push @keep_tx, $tx;
	return $mojo->build_controller($tx);
};
my $c = $controller->('/manager/help/verb');

local *Manager::help_app_visible = sub { 1 };
local *Manager::guide_resolve_action = sub { return $_[0] };
local *Manager::media_unlock_device = sub { 'device123' };
local *subs::setting_grabber = sub { '' };

@ws_sent = ();
my $ran = Manager::app_action_execute($c,
	{ action => 'app', app => 'camera', do => 'photo', confirmed => 1 },
	{});
ok($ran->{'ok'}, 'the camera photo action runs');
is($ran->{'speech'}, 'I asked the Camera to take a photo.', 'and speaks the press');
is(scalar @ws_sent, 1, 'one socket command is sent');
is($ws_sent[0]{'app'}, 'camera', 'on the camera app channel');
is($ws_sent[0]{'msg'}{'console'}{'cmd'}, 'cameraAction', 'as a camera action');
is_deeply($ws_sent[0]{'msg'}{'console'}{'args'}, ['photo'], 'naming the photo button');

# The route itself also answers JSON with no arguments, so the bridge can read it.
my $photo_c = $controller->('/manager/camera/photo');
@ws_sent = ();
&main::Manager::action_92011($photo_c);
my $photo_json = $photo_c->res->json;
ok($photo_json && $photo_json->{'ok'}, 'the photo route answers JSON');
is($photo_json->{'action'}, 'photo', 'and reports what it asked for');
is($ws_sent[0]{'msg'}{'console'}{'cmd'}, 'cameraAction', 'the route presses the button');

# ------------------------------------------------------------ the window close
@ws_sent = ();
my $closed = Manager::guide_verb_execute($c, { action => 'close_app', app => 'camera' });
is($closed, 'closed the camera window', 'close_app reports the app it closed');
is(scalar @ws_sent, 1, 'one close command is sent');
is($ws_sent[0]{'app'}, 'server', 'the close reaches the open tabs');
is($ws_sent[0]{'msg'}{'console'}{'cmd'}, 'appWindowCloser', 'as the window close press');
is_deeply($ws_sent[0]{'msg'}{'console'}{'args'}, ['camera'], 'naming the app');
is(Manager::guide_verb_execute($c, { action => 'close_app' }), 'no app named',
	'a close with no app is refused');

@ws_sent = ();
my $voice_close = Manager::remote_command_execute($c, { action => 'close_app', app => 'camera' });
is($voice_close, 'closed the camera window', 'the voice path closes the same window');
is($ws_sent[0]{'msg'}{'console'}{'cmd'}, 'appWindowCloser', 'through the same press');

# ------------------------------------------------------------ both are offered
my $live = help::live_verb_names();
ok($live->{'close_app'}, 'the Guide may choose close_app');
like(help::actions_prompt(undef, 0, ''), qr/"action":"close_app"/, 'and its prompt says so');
my $verbs = subs::voice_funnel_verbs({ app => 'camera', id => 'camera' });
ok($verbs->{'close_app'}, 'a scoped voice turn is offered close_app');
ok($verbs->{'app'}, 'and the camera scope is offered the app-action verb');
like(help::app_action_lines('camera'), qr/"photo" \(write\)/, 'the camera prompt lists photo');
like(help::app_action_lines('camera'), qr/"video" \(write\)/, 'and video');

# ------------------------------------------------------------ the browser side
my $router = read_file('public/js/manager/websocket/00_console_router.js');
like($router, qr/cameraAction:\s*function/, 'the console router knows the camera action');
like($router, qr/appWindowCloser:\s*function/, 'and the window closer');
like(read_file('public/js/manager/camera.js'), qr/function jawnCameraCommand/,
	'the camera app owns the press');
like(read_file('public/js/manager/windows/03_stack.js'), qr/function jawnAppWindowCloser/,
	'the window stack owns the close press');

# ------------------------------------------------------------ the help tells the truth
my $voice = read_file('perl/help/topics_features.pl');
like($voice, qr/Jawn Do.{0,400}not trained/s, 'the Voice topic says Jawn Do is not trained');
unlike($voice, qr/"Jawn Do"\) are the phrases it knows/, 'and does not call it a trained phrase');
like(read_file('perl/help/topics_web.pl'), qr/take a photo.*close Camera/s,
	'the Camera topic names the spoken press and close');

done_testing();
