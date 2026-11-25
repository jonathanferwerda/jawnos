# tests-for: public/js/manager/studio/11_drums.js public/js/manager/studio.js public/js/manager/studio/05_inputs.js public/js/manager/studio/01_transport.js public/js/manager/studio/04_knobs.js public/js/manager/studio/06_controls.js perl/help/topics_apps.pl
# covers:    Every live input joins the channel's output path (fader, Out
#            pedals, output cord) while the In chain stays the recording path.
#            The drum and synth buses mute their own direct output while a
#            channel carries them; Music mutes its own player; every app input
#            builds its graph when patched and again on load; Monitor swaps an
#            app to the In chain and gates a device's live path.

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

# --- the kit is live through the channel, its dry feed muted while patched --
like($drums, qr/studioDrums\.direct = ctx\.createGain\(\);/, 'the kit owns a direct gain');
like($drums, qr/studioDrums\.out\.connect\(studioDrums\.direct\);/, 'the kit output feeds it');
like($drums, qr/studioDrums\.direct\.connect\(studioAudio\.master\);/, 'and it reaches the master');
like($drums, qr/function studioDrumsPatchDirect\(\)/, 'the direct feed follows whether a channel carries the kit');
like($drums, qr/studioDrums\.direct\.gain\.value = patched \? 0 : 1;/, 'it is muted while patched, restored otherwise');
like($studio, qr/tap\.connect\(c\.trim\);[\s\S]{0,100}tap\.connect\(c\.live\);/,
	'the kit tap feeds the record and live paths');
like($studio, qr/c\.live\.gain\.value = 1;/, 'the kit is live through the channel output');
like($studio, qr/if \(typeof studioDrumsPatchDirect === 'function'\) \{ studioDrumsPatchDirect\(\); \}/,
	'attaching the kit mutes its direct feed');

# --- the synth is the same shape -------------------------------------------
like($studio, qr/function studioSynthPatchDirect\(\)/, 'the synth direct feed is managed too');
like($studio, qr/node\.disconnect\(ctx\.destination\)/, 'the synth direct edge is removed while patched');
like($studio, qr/node\.connect\(ctx\.destination\)/, 'and restored when no channel carries it');

# --- Monitor: apps swap to In, devices gate the live path -------------------
like($studio, qr/var app_monitor = ch_app && on && !!input;/, 'Monitor on an app selects the In chain');
like($studio, qr/var live = \(ch_app && !app_monitor\) \|\| \(on && !ch_app && !!input && !listening\);/,
	'apps live while patched; devices only while monitored');
like($studio, qr/c\.live\.gain\.value = live \? 1 : 0;/, 'the live path is the channel output');
like($studio, qr/c\.monGain\.gain\.value = app_monitor \? 1 : 0;/, 'the In tap is only the app monitor comparison');

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
like($help, qr/the kit is heard through the channel\\'s output/,
	'help says the kit follows the channel output');
like($help, qr/its own dry feed is muted while patched/, 'and that the dry feed is muted while patched');
like($help, qr/Synth, Music and Marker follow the same rule/, 'help says every app input follows the rule');
like($help, qr/press Monitor on an app to hear the In chain/, 'and that Monitor swaps to the In chain');

done_testing();
