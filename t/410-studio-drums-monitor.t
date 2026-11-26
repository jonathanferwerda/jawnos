# tests-for: public/js/manager/studio/11_drums.js public/js/manager/studio.js public/js/manager/studio/05_inputs.js public/js/manager/studio/01_transport.js public/js/manager/studio/04_knobs.js public/js/manager/studio/06_controls.js perl/help/topics_apps.pl
# covers:    Every live input joins the channel's output path (fader, Out
#            pedals, output cord) while the In chain stays the recording path.
#            The drum kit is an instrument, not a player: its direct output is
#            never heard, and the channel that carries it is live only while
#            that channel is monitored; the synth stays live while patched.
#            Music mutes its own player; every app input builds its graph when
#            patched and again on load; Monitor swaps an app to the In chain and
#            gates a device's live path.

use strict;
use warnings;

use FindBin;
use Test::More;

sub slurp {
	my ($path) = @_;
	open my $fh, '<', $path or die "cannot read $path: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
}

my $root = $FindBin::Bin;
$root =~ s{/t$}{};

my $drums     = slurp("$root/public/js/manager/studio/11_drums.js");
my $studio    = slurp("$root/public/js/manager/studio.js");
my $inputs    = slurp("$root/public/js/manager/studio/05_inputs.js");
my $transport = slurp("$root/public/js/manager/studio/01_transport.js");
my $knobs     = slurp("$root/public/js/manager/studio/04_knobs.js");
my $controls  = slurp("$root/public/js/manager/studio/06_controls.js");
my $help      = slurp("$root/perl/help/topics_apps.pl");

# --- the channel owns a live path through the output ------------------------
like($studio, qr/live: ctx\.createGain\(\)/, 'the channel owns a live input gain');
like($studio, qr/c\.live\.connect\(c\.playBus\);/, 'the live path joins the fader');
like($studio, qr/c\.live\.gain\.value = 0;/, 'the live gain starts closed');
like($studio, qr/c\.source\.connect\(c\.trim\);[\s\S]{0,180}c\.source\.connect\(c\.live\);/,
	'a captured source feeds both the record and live paths');
like($studio, qr/c\.live\.gain\.value = \(typeof studioInputIsApp === 'function' && studioInputIsApp\(plug\)\) \? 1 : 0;/,
	'an app is live; a device waits for Monitor');

# --- the kit is an instrument: no dry feed, live only while monitored -------
like($drums, qr/studioDrums\.direct = ctx\.createGain\(\);/, 'the kit owns a direct gain');
like($drums, qr/studioDrums\.out\.connect\(studioDrums\.direct\);/, 'the kit output feeds it');
like($drums, qr/studioDrums\.direct\.connect\(studioAudio\.master\);/, 'and it reaches the master');
like($drums, qr/function studioDrumsPatchDirect\(\)/, 'one helper states the direct-feed rule');
like($drums, qr/studioDrums\.direct\.gain\.value = 0;/, 'the direct feed is never opened');
like($studio, qr/tap\.connect\(c\.trim\);[\s\S]{0,100}tap\.connect\(c\.live\);/,
	'the kit tap feeds the record and live paths');
like($studio, qr/c\.live\.gain\.value = 0;/, 'the kit attaches with its live path shut');
like($studio, qr/if \(typeof studioDrumsPatchDirect === 'function'\) \{ studioDrumsPatchDirect\(\); \}/,
	'attaching the kit keeps its direct feed shut');

# --- the synth is the same shape -------------------------------------------
like($studio, qr/function studioSynthPatchDirect\(\)/, 'the synth direct feed is managed too');
like($studio, qr/node\.disconnect\(ctx\.destination\)/, 'the synth direct edge is removed while patched');
like($studio, qr/node\.connect\(ctx\.destination\)/, 'and restored when no channel carries it');

# --- Monitor: apps swap to In, devices gate the live path -------------------
like($studio, qr/var app_monitor = ch_app && on && !!input;/, 'Monitor on an app selects the In chain');
like($studio, qr/var ch_drums = !!\(ch_app && ch_input && String\(ch_input\['app'\] \|\| ''\) === 'drums'\);/,
	'the kit is named apart from the other apps');
like($studio, qr/var live = \(!ch_drums && ch_app && !app_monitor\) \|\| \(on && !ch_app && !!input && !listening\);/,
	'the kit and devices are live only while monitored; other apps while patched');
like($studio, qr/c\.live\.gain\.value = live \? 1 : 0;/, 'the live path is the channel output');
like($studio, qr/c\.monGain\.gain\.value = app_monitor \? 1 : 0;/, 'the In tap is only the app monitor comparison');
like($studio, qr/if \(from_user && typeof studioEngineClipsChanged === 'function'\) \{ studioEngineClipsChanged\(\); \}/,
	'a Monitor press re-sends the engine kit routing');
like($transport, qr/if \(app === 'drums' && \(drums_monitor === null \|\| String\(drums_monitor\) !== String\(ch\)\)\) \{ gain = 0; \}/,
	'the engine kit is routed only through the monitored channel');
like($transport, qr/if \(!routing\.length\) \{[\s\S]{0,160}steps: \{\}/,
	'an unpatched kit reaches the engine as a silent chart, never unity');

# --- an engine take never monitors an unmonitored track ---------------------
like($studio, qr/var monitor = \(typeof studioMonitoredChannel === 'function' && studioMonitoredChannel\(\) !== null\);/,
	'an engine take monitors only a monitored track');
unlike($studio, qr/\|\| \(mixer\['time'\] && mixer\['time'\]\['monitor'\] == 'yes'\)/,
	'a stale app-wide Monitor setting cannot arm the take input');
like($studio, qr/studioEngineMonitorArmed = !!monitor;/, 'the take reports the state it armed');
like($controls, qr/mixer\['time'\]\['monitor'\] = \(studioMonitoredChannel\(\) !== null\) \? 'yes' : 'no';/,
	'the app-wide setting follows the per-track Monitor button');

# --- every app input owns its channel graph, including on reload -----------
like($inputs, qr/if \(direction == 'input' && type == 'app'\) \{/, 'patching any app has its own path');
like($inputs, qr/studioInputStreamGrabber\(channel, 'off'\);[\s\S]{0,180}studioAttachAppInput\(channel, app_plug\);/,
	'the old input is released, then the app graph is built');
like($inputs, qr/function studioAttachSavedAppInputs\(\)/, 'a saved app input is rebuilt on load');
like($knobs, qr/studioAttachSavedAppInputs\(\);[\s\S]{0,140}studioApplyMonitor\(false\);/,
	'the load re-applies the Monitor split after attaching');

# --- Music's own player is muted while the channel carries it --------------
like($inputs, qr/mixer\[ch\]\.media\.music_muted = player\.muted \? 'yes' : 'no';/,
	'Music remembers its own mute state');
like($inputs, qr/player\.muted = true;/, 'Music is muted while the channel carries it');
like($transport, qr/player\.muted = \(media\.music_muted === 'yes'\);/, 'and restored when the channel lets go');
like($transport, qr/if \(typeof studioDrumsPatchDirect === 'function'\) \{ studioDrumsPatchDirect\(\); \}/,
	'detaching restores the kit direct feed');
like($transport, qr/if \(typeof studioSynthPatchDirect === 'function'\) \{ studioSynthPatchDirect\(\); \}/,
	'detaching restores the synth direct feed');

# --- the help topic states the rule ----------------------------------------
like($help, qr/it is heard only while that channel is being monitored/,
	'help says the kit is heard only while its channel is monitored');
like($help, qr/own dry feed never reaches the master/,
	'and that the kit has no dry feed of its own');
like($help, qr/Synth, Music and Marker are different/, 'help separates the other apps');
like($help, qr/Monitor swaps it to the In chain/, 'and that Monitor swaps to the In chain');

done_testing();
