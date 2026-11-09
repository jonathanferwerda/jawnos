# tests-for: lib/JawnOS/Sco/Gateway.pm lib/JawnOS/Sco/Mixer.pm lib/JawnOS/Controller/manager_sco.pm lib/JawnOS/Routes/manager_sco.pm scripts/rtc_bridge.py scripts/jawnos_deps.pl public/js/manager/phone.js templates/apps/phone.html.ep public/js/manager/websocket/01_message_handler.js
# covers:    Connect me, as far as the house can see it: the route and its action,
#           the bridge's own audio streams, the gateway keeping signalled state
#           and not letting the plan's timer end a call somebody joined, the
#           bridge's honest answer when aiortc is missing, and the pane button.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file);

use RepoSource;
use JawnOSTest;

use lib repo_root() . '/lib';
use JawnOS::Sco::Gateway;
use JawnOS::Sco::Mixer;

my $repo = root();
my $dir  = tempdir(CLEANUP => 1);

# ------------------------------------------------------------- the route
my $routes = read_file("$repo/lib/JawnOS/Routes/manager_sco.pm");
my $controller = read_file("$repo/lib/JawnOS/Controller/manager_sco.pm");
like($routes, qr/\[\s*52006\s*,\s*'post'\s*,\s*'\/manager\/sco\/rtc'\s*,\s*'action_52006'\s*\]/,
	'POST /manager/sco/rtc is action_52006');
like($controller, qr/^sub action_52006\b/m, 'and the action exists');
like($controller, qr/cmd => 'rtc'/, 'it asks the gateway daemon, which owns the call');
like($controller, qr/action => \$action/, 'and carries the bridge action through');

# ------------------------------------------------------------- the audio pair
my $mixer = JawnOS::Sco::Mixer->new();
my $cap = $mixer->bridge_capture_command();
like($cap, qr/--client-name=jawn-sco-bridge/, 'the bridge names its capture stream');
like($cap, qr/--rate=48000/, 'at the rate Opus speaks');
like($cap, qr/--device=jawn_call_in\.monitor/, 'and takes the caller from the gateway sink');
my $play = $mixer->bridge_playback_command();
like($play, qr/--playback/, 'the other direction plays');
like($play, qr/--device=jawn_prompt/, 'into what the caller hears');

# The launcher's phone channel scales everything the caller hears. pacat takes
# the level as a percentage, and a machine with no setting row keeps it at 100.
{
	no warnings 'redefine';
	local *subs::sound_channel_gain = sub { 0.5 };
	like($mixer->playback_command(), qr/--volume=50%/,
		'the prompt player carries the phone channel gain');
	like($mixer->bridge_playback_command(), qr/--volume=50%/, 'and so does the bridge');
}
{
	no warnings 'redefine';
	local *subs::sound_channel_gain = sub { 0 };
	like($mixer->playback_command(), qr/--volume=0%/, 'a muted phone channel is silence');
}
{
	no warnings 'redefine';
	local *subs::sound_channel_gain = sub { die "no database\n" };
	like($mixer->playback_command(), qr/--volume=100%/, 'a channel that cannot be read keeps full level');
}

# ------------------------------------------------------------- the gateway
my $gw = JawnOS::Sco::Gateway->new(
	dir => $dir,
	helper => ['/bin/false'],
	status_path => "$dir/sco.json",
	pipe => 1,
);
$gw->{'call_id'} = 'rtc-call';
$gw->{'state'} = 'in_call';

is($gw->rtc({ action => 'nonsense' })->{'ok'}, 0, 'an unknown bridge action is refused');
is($gw->rtc({ action => 'signal', message => {} })->{'ok'}, 0,
	'signalling without a bridge is refused, not fatal');

{
	# the bridge is not installed here, and saying so must not start anything
	local $ENV{'JAWNOS_RTC_BRIDGE'} = '/nonexistent/rtc_bridge.py';
	my $started = $gw->rtc({ action => 'start' });
	is($started->{'ok'}, 0, 'a machine with no bridge cannot start one');
	like($started->{'error'}, qr/not installed/, 'and says so');
	is($gw->status->{'rtc'}->{'state'}, 'unavailable', 'the status carries the reason');
}

# the signalling path, fed the bridge's own events
$gw->_rtc_event({ event => 'ready' });
is($gw->status->{'rtc'}->{'state'}, 'ready', 'the bridge reports itself ready');
$gw->_rtc_event({ event => 'answer', sdp => 'v=0', type => 'answer' });
is($gw->status->{'rtc'}->{'state'}, 'answering', 'an answer moves the bridge on');
$gw->_rtc_event({ event => 'state', state => 'connected' });
is($gw->{'rtc_up'}, 1, 'a connected bridge holds the call open');
$gw->_rtc_event({ event => 'state', state => 'closed' });
is($gw->{'rtc_up'}, 0, 'when it closes the plan may end the call again');
$gw->_rtc_event({ event => 'error', error => 'no route' });
is($gw->status->{'rtc'}->{'error'}, 'no route', 'a bridge error is kept for the pane');

# the plan's timer must not end a call somebody joined
my $gateway_pm = read_file("$repo/lib/JawnOS/Sco/Gateway.pm");
my $guard = q{end_call($why) if length $why && !$self->{'rtc_up'}};
like($gateway_pm, qr/\Q$guard\E/,
	'a bridged call is not ended by the plan timer');

# ------------------------------------------------------------- the bridge's answer
my ($venv_py) = grep { -x } map { "$_/python3" }
	("$ENV{'HOME'}/.local/share/jawnos/rtc/venv/bin",
	 "$ENV{'HOME'}/.local/share/jawnos/vosk/venv/bin");
my $py3 = (grep { -x } map { "$_/python3" } split /:/, ($ENV{'PATH'} || ''))[0];
SKIP: {
	skip 'no python3 on PATH', 2 unless $py3;
	my $out = qx{'$py3' '$repo/scripts/rtc_bridge.py' --in-cmd cat --out-cmd cat 2>/dev/null </dev/null};
	my $rc = $? >> 8;
	like($out, qr/\{"event": "error"/, 'without aiortc the bridge says so on the wire');
	isnt($rc, 0, 'and exits non-zero');
}
SKIP: {
	skip 'no gateway venv on this machine', 2 unless $venv_py;
	my $has = system($venv_py, '-c', 'import aiortc') == 0;
	skip 'aiortc is not installed in the venv', 2 unless $has;
	my $help = qx{'$venv_py' '$repo/scripts/rtc_bridge.py' --help 2>&1};
	is($? >> 8, 0, 'the bridge parses its arguments');
	like($help, qr/--in-cmd/, 'and names the caller capture it needs');
}

# ------------------------------------------------------------- the pane and the panel
my $js = read_file("$repo/public/js/manager/phone.js");
my $panel_js = read_file("$repo/public/js/manager/screening.js");
like($js, qr/function jawnPhoneRtcConnect/, 'the Phone pane can start a bridge');
like($js, qr/jawnScreenRtcConnect/, 'through the one every page loads');
like($js, qr/connect=me/, 'the face opens the page with the connect query');
like($js, qr/jawnPhoneConnectMeWanted/, 'and the page presses Connect me once a call is up');
like($js, qr/history\.replaceState/, 'stripping the query so a reload does not connect a second time');
like($panel_js, qr/function jawnScreenRtcConnect/, 'the shared bridge can start a call');
like($panel_js, qr/echoCancellation: true/, 'with the browser echo canceller on, which is the point');
like($panel_js, qr/iceServers: \[\]/, 'and no public relay: the tailnet owns the path');
like($panel_js, qr/action: 'start'/, 'telling the gateway to start');
like($panel_js, qr/function jawnScreenRtcPushed/, 'and applying the answer that comes back on the socket');
like($panel_js, qr/function jawnScreenPushed/, 'the screening announcement opens a panel');
like($panel_js, qr/jawn_screening_lines/, 'with the transcript as bubbles');
like($panel_js, qr#/manager/sco/status#, 'polled while it is up');
like($panel_js, qr/state !== 'in_call' && state !== 'done'/,
	'an armed gateway does not open the panel by itself');
like($panel_js, qr/\$\(function \(\) \{/, 'and a window that loads mid-call asks once');
my $ws = read_file("$repo/public/js/manager/websocket/01_message_handler.js");
like($ws, qr/sco_rtc/, 'the websocket dispatcher knows the bridge event');
like($ws, qr/sco_screen/, 'and the screening announcement');
like($ws, qr/jawnScreenPoll\(\)/, 'a reconnecting window asks whether a call is up');
my $bundle = read_file("$repo/lib/JawnOS/Manager/Core1_tables_hooks.pm");
like($bundle, qr{/js/manager/screening\.js}, 'the panel loads on every page, not only in the Phone app');
my $tpl = read_file("$repo/templates/apps/phone.html.ep");
like($tpl, qr/id="phone_transcript_connect"/, 'the pane has the button');
like($tpl, qr/Connect me/, 'labelled Connect me');

# the gateway tells every open window, and the line going free closes the panel
like($gateway_pm, qr/_push_screen\('started'\)/, 'the gateway announces a screening');
like($gateway_pm, qr/_push_screen\('ended'\)/, 'and that the line is free again');
like($gateway_pm, qr/&Websocket::send\('tab'/, 'on the channel every window keeps open');

# ------------------------------------------------------------- the installer
my $deps = read_file("$repo/scripts/jawnos_deps.pl");
like($deps, qr/id => 'rtc'/, 'the installer offers the bridge as an extra');
like($deps, qr{sub install_rtc}, 'with an installer');
like($deps, qr/'aiortc'/, 'that installs aiortc into the gateway venv');

done_testing();
