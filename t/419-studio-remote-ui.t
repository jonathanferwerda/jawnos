# tests-for: public/js/manager/studio/07_layout.js public/js/manager/websocket/00_console_router.js templates/studio/markup.html.ep templates/studio/style.html.ep
# covers:    The Studio's remote-control UI - the top-bar machine picker, the
#            "Controlling" badge, the 500 ms state poll, the target's bounded
#            publish, the controller's command hooks and the console-router
#            entry that applies a command name and its data (never source).

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use Cwd qw(abs_path);

my $root = abs_path("$FindBin::Bin/..");

my $markup = read_file("$root/templates/studio/markup.html.ep");
my $style  = read_file("$root/templates/studio/style.html.ep");
my $layout = read_file("$root/public/js/manager/studio/07_layout.js");
my $router = read_file("$root/public/js/manager/websocket/00_console_router.js");

# --- the top bar -------------------------------------------------------------
like($markup, qr/id="studio_remote_machine"/, 'the top bar carries the machine picker');
like($markup, qr/<option value="">.*?This machine/s, 'the first option is this machine');
like($markup, qr/id="studio_remote_status"/, 'and a badge for the machine being driven');
like($markup, qr/studio_remote_picker/, 'the picker has its own top-bar group');
like($markup, qr/Choose the machine this Studio controls/, 'the picker says what it chooses');
like($markup, qr/subs::ui\('Control another machine'\)/,
	'the remote words are translatable');
unlike($markup, qr/id="studio_remote_machine"[^>]*multiple/,
	'the picker chooses one machine at a time');

like($style, qr/\.studio_remote_picker/, 'the picker has top-bar styles');
like($style, qr/\.studio_remote_machine/, 'the select is styled');
like($style, qr/\.studio_remote_status\.on/, 'the badge appears only in remote mode');
like($style, qr/studio_remote_controller/, 'the controller top bar has its own cue');

# --- the picker and the controller -------------------------------------------
like($layout, qr/function studioRemotePickerLoad\(\)/,
	'the picker has one loader');
like($layout, qr{url: '/manager/studio/remote_machines'},
	'it asks the remote_machines route');
like($layout, qr/reply\.machines/, 'and builds one option per peer');
like($layout, qr/\$\(('<option>'|"<option>")\)\.val\(''\)\.text\(studioRemoteText\('This machine'\)\)/,
	'reloading keeps this machine first');
like($layout, qr{url: '/manager/studio/remote_target'},
	'a choice is posted to remote_target');
like($layout, qr/studioRemoteTargetSet\(String\(reply\.target \|\| target\)\)/,
	'the change handler enters or leaves the chosen target');
like($layout, qr/studioRemoteText\('Controlling'\)/,
	'the badge names the machine being controlled');
like($layout, qr/function studioRemoteLocalSnapshotSave\(\)/,
	'the local song is remembered before the mirror paints');
like($layout, qr/function studioRemoteLocalRestore\(\)/,
	'and reloaded when the picker returns to this machine');
like($layout, qr/function studioRemoteLocalSilence\(\)/,
	'a controller stops its own transport and monitoring');
like($layout, qr/typeof studioStop === 'function'\) \{ studioStop\(\); \}/,
	'the local transport is stopped');
like($layout, qr/studioListenStop\(\)/, 'and any live listen is stopped');

# --- the mirror --------------------------------------------------------------
like($layout, qr/function studioRemoteStateLoad\(\)/,
	'the controller asks for the peer state');
like($layout, qr{url: '/manager/studio/remote_state'},
	'through remote_state');
like($layout, qr/studioRemotePollTimer = setInterval\([\s\S]{0,240}?\}, 500\)/,
	'once every 500 ms');
like($layout, qr/function studioRemoteRender\(state\)/, 'one renderer paints the answer');
like($layout, qr/studioRemoteLoopPaint\(\);/, 'the transport loop is painted');
like($layout, qr/studioRemoteMetronomePaint\(studioRemoteTruthy\(tr\.metronome\)\)/,
	'the metronome is painted');
like($layout, qr/mixer\['time'\]\['bpm'\] = bpm;/, 'the BPM is painted');
like($layout, qr/\$\('#studio_bpm'\)\.val\(bpm\)/, 'and shown in the transport field');
like($layout, qr/tracks = state\.tracks \|\| \[\]/, 'the track list is read from the state');
like($layout, qr/studioEnsureTracks\(highest\)/, 'the mirror builds rows for a larger peer song');
like($layout, qr/mixer\[ch\]\.armed = \{ state: armed, text: arm_text \}/,
	'each track arm state is painted');
like($layout, qr/\.channel_volume\[channel="' \+ ch \+ '"\]'\)\.val\(studioKnobNumber\(track\.gain, 1\)\)/,
	'each fader is painted');
like($layout, qr/pan_el\.val\(studioKnobNumber\(track\.pan, 50\)\)/, 'each pan is painted');
like($layout, qr/mixer\[ch\]\.mute = studioRemoteTruthy\(track\.mute\)/,
	'each mute is painted');
like($layout, qr/mixer\[ch\]\.solo = studioRemoteTruthy\(track\.solo\)/,
	'each solo is painted');
like($layout, qr/studioStripMuteSoloRender\(\)/, 'the strips repaint from that state');
like($layout, qr/studioMasterRestore\(state\.master\)/, 'the master rack is restored');

# --- the target publishes ----------------------------------------------------
like($layout, qr/function studioRemoteStateBuild\(\)/, 'the target builds the state shape');
like($layout, qr/ok: 1,[\s\S]{0,80}at: Date\.now\(\)/, 'the state says when it was made');
like($layout, qr/song: \{/, 'it carries the song');
like($layout, qr/transport: \{/, 'the transport');
like($layout, qr/tracks: tracks,/, 'the tracks');
like($layout, qr/clips: clips,/, 'the clips');
like($layout, qr/master: master/, 'and the master rack');
like($layout, qr/clips\.length >= 128/, 'the clip list is bounded');
like($layout, qr/function studioRemotePublish\(\)/, 'the target publishes');
like($layout, qr{url: '/manager/studio/remote_publish'},
	'through remote_publish');
like($layout, qr/state: JSON\.stringify\(state\)/, 'as JSON in the state field');
like($layout, qr/studioRemotePublishTimer = setInterval\([\s\S]{0,600}?\}, 1000\)/,
	'once a second while the Studio is open');
like($layout, qr/studioRemotePublishSoon\(\);/, 'and after a transport move or a save');
like($layout, qr/if \(studioRemoteTarget \|\| studioRemoteRestoring\) \{ return false; \}/,
	'a controller never publishes its mirror');

# --- the controller's commands ----------------------------------------------
like($layout, qr/function studioRemoteCommand\(command, payload\)/,
	'one sender names a command and its data');
like($layout, qr{url: '/manager/studio/remote_command'}, 'it posts to remote_command');
like($layout, qr/target: target, command: String\(command\), payload: JSON\.stringify\(payload \|\| \{\}\)/,
	'with the target, the command name and a JSON payload');
like($layout, qr/function studioRemoteInterceptClick\(event\)/,
	'a capture listener catches a controller press before the local handler');
like($layout, qr/studioRemoteCommand\('transport', \{ action: 'play' \}\)/,
	'play is routed while remote');
like($layout, qr/studioRemoteCommand\('transport', \{ action: 'stop' \}\)/,
	'stop is routed');
like($layout, qr/studioRemoteCommand\('transport', \{ action: 'seek', value: at \}\)/,
	'a ruler click is routed as a seek');
like($layout, qr/studioRemoteCommand\('record', \{ action: 'start' \}\)/,
	'record is routed');
like($layout, qr/studioRemoteCommand\('record', \{ action: 'arm', track:/,
	'arm is routed with its track');
like($layout, qr/studioRemoteCommand\('track', \{ action: 'select', index: pch \}\)/,
	'track selection is routed');
like($layout, qr/control: 'mute', value:/, 'mute is routed as a mixer value');
like($layout, qr/control: 'solo', value:/, 'solo is routed as a mixer value');
like($layout, qr/control: 'gain', value:/, 'the fader is routed');
like($layout, qr/control: 'pan', value:/, 'the pan is routed');
like($layout, qr/studioRemoteCommand\('master'/, 'the master rack is routed');
like($layout, qr/studioRemoteCommand\('song', \{ action: 'save' \}\)/,
	'Save is routed to the peer');
like($layout, qr/function studioRemoteInterceptInput\(event\)/,
	'a drag never reaches the local channel graph');

# --- the driven machine ------------------------------------------------------
like($layout, qr/function studioRemoteApply\(command, payload\)/,
	'the target has one command applier');
like($layout, qr/if \(!\$\('#studio'\)\.length\) \{ return false; \}/,
	'a closed Studio applies nothing');
like($layout, qr/command === 'transport'/, 'transport commands are applied');
like($layout, qr/command === 'record'/, 'record commands are applied');
like($layout, qr/command === 'track'/, 'track commands are applied');
like($layout, qr/command === 'mixer'/, 'mixer commands are applied');
like($layout, qr/command === 'master'/, 'master commands are applied');
like($layout, qr/command === 'song'/, 'song commands are applied');
like($layout, qr/command === 'select'/, 'select commands are applied');
like($layout, qr/studioChannelVolumeSet\(ch, payload\.value\)/,
	'a mixer gain uses the existing fader function');
like($layout, qr/studioMasterSet\(name, mcontrol, payload\.value\)/,
	'a master control uses the existing rack setter');
like($layout, qr/studioMasterToggle\(name, studioRemoteTruthy\(payload\.on\)\)/,
	'a master footswitch uses the existing toggle');
like($layout, qr/studioSeek\(studioKnobNumber\(payload\.value, 0\)\)/,
	'a seek uses the existing transport');
like($layout, qr/studioInit\.studioRemoteWrapped/, 'the window open hook is installed once');

my ($remote) = $layout =~ /(\/\/ Remote control: drive another machine.*)/s;
ok($remote && length($remote), 'the remote block is present');
unlike($remote // '', qr/(?<![A-Za-z_.])eval\s*\(/,
	'the remote block never evaluates a string');
like($remote // '', qr/JSON\.parse/, 'a payload string is parsed as data only');

# --- the console router ------------------------------------------------------
my ($handler) = $router =~ /(studioRemoteCommand: function \(a\).*?\n\t\},)/s;
ok($handler && length($handler), 'the router whitelists studioRemoteCommand');
like($handler // '', qr/studioRemoteApply\(String\(a\[0\] \|\| ''\), a\[1\] \|\| \{\}\)/,
	'and hands the name and data to studioRemoteApply');
unlike($handler // '', qr/(?<![A-Za-z_.])eval\s*\(/,
	'the router entry evaluates nothing');
unlike($handler // '', qr/Function\s*\(/, 'and builds no function from the frame');

done_testing;
