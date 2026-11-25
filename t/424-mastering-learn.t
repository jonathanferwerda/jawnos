# tests-for: public/js/manager/studio/10_master.js
# covers:    The browser-only mastering Learn: a measurement mic picked from the
#            browser's audio inputs, two analysers (the mic and the pre-master
#            tap), a ten-second run over the ten master_eq octave bands, a
#            clamped +/- 6 dB correction against the Flat or House target,
#            Reset back to the manual curve, no mic edge to the destination, a
#            refusal while the engine owns the transport, and the saved song.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root   = repo_root();
my $js     = read_file("$root/public/js/manager/studio/10_master.js");
my $markup = read_file("$root/templates/studio/markup.html.ep");
my $style  = read_file("$root/templates/studio/style.html.ep");

# --- the mic picker ---------------------------------------------------------
# The browser's own audio inputs, enumerated after permission; no free-text
# device path and no plan node, because this slice is browser monitoring only.
like($js, qr/navigator\.mediaDevices\.enumerateDevices\(\)/, 'the picker enumerates the browser devices');
like($js, qr/item\.kind === 'audioinput'/, 'only audio inputs are offered');
like($js, qr/#studio_mastering_mic/, 'the picker is the mastering block\'s select');
like($js, qr/Default microphone/, 'the picker can fall back to the default microphone');
like($js, qr/getUserMedia/, 'Learn requests the chosen microphone');
like($js, qr/audio\.deviceId = \{ exact: pick \}/, 'a chosen device id is requested exactly');
like($js, qr/OverconstrainedError/, 'a stale device id falls back to the default microphone');
like($markup, qr/id="studio_mastering_mic"/, 'the rack markup carries the mic picker');
like($markup, qr/<option value="">[^<]*Default microphone|Default microphone/, 'the picker starts on the default microphone');

# The measurement must not be processed by the browser: AEC, NS and AGC off,
# exactly the constraints the input channel uses.
like($js, qr/echoCancellation: false/, 'echo cancellation is off for the measurement');
like($js, qr/noiseSuppression: false/, 'noise suppression is off for the measurement');
like($js, qr/autoGainControl: false/, 'automatic gain control is off for the measurement');

# --- two analysers ----------------------------------------------------------
my @analysers = ($js =~ /createAnalyser\(\)/g);
is(scalar @analysers, 2, 'the run builds exactly two analysers');
like($js, qr/state\.source\.connect\(state\.mic\)/, 'the mic feeds the first analyser');
like($js, qr/chain\.input\.connect\(state\.ref\)/, 'the pre-master rack input feeds the second analyser');
like($js, qr/pre-master/, 'the reference is named as the pre-master tap');

# The mic is an analyser source and nothing else, so a measurement cannot howl.
like($js, qr/never connected to ctx\.destination|never connected to\n?\/\/ the destination/, 'the source says the mic never reaches the destination');
unlike($js, qr/\bconnect\(\s*ctx\.destination\s*\)/, 'the mastering code never connects anything to ctx.destination');

# --- ten seconds, ten bands -------------------------------------------------
like($js, qr/studioMasteringSeconds = 10\b/, 'the window is ten seconds');
like($js, qr/studioMasteringSeconds \* 1000/, 'the timer runs for the whole ten seconds');
like($js, qr/setInterval\(/, 'the measurement samples on a timer');
like($js, qr/getFloatFrequencyData/, 'the bands are read from the analysers\' FFT');

for my $control (qw(b32 b64 b125 b250 b500 b1k b2k b4k b8k b16k)) {
	like($js, qr/'\Q$control\E'/, "the band $control is one of the ten");
}
for my $hz (qw(32 64 125 250 500 1000 2000 4000 8000 16000)) {
	like($js, qr/(?:^|[\s,\[])\Q$hz\E(?:[\s,\]]|$)/, "the octave centre $hz Hz is measured");
}
for my $control (qw(b32 b64 b125 b250 b500 b1k b2k b4k b8k b16k)) {
	like($markup, qr/\[\s*'\Q$control\E'/, "the rack markup lists the $control bar");
}
like($markup, qr/id="studio_mastering_bars"/, 'the ten bars sit in their own block');

# --- the correction and its bound ------------------------------------------
like($js, qr/studioMasteringLimit = 6/, 'the bound is +/- 6 dB');
like($js, qr/target\[i\] - measured/, 'the correction is the target minus the measured difference');
like($js, qr/studioMasteringClamp\(target\[i\] - measured, -studioMasteringLimit, studioMasteringLimit\)/,
	'the correction is clamped to the bound');
like($js, qr/var measured = micDb - refDb/, 'the measurement is mic minus reference');
like($js, qr/studioMasteringGateDb = -50/, 'a reference band below the gate is held');
like($js, qr/refDb < peakDb - 20/, 'a band far below its own peak is held');
like($js, qr/micDb < studioMasteringMicFloorDb/, 'a band the mic never heard is held');
like($js, qr/programme was too quiet to learn from/, 'a quiet programme refuses the Learn');

# --- the target: Flat or House ---------------------------------------------
like($js, qr/flat:\s*\[0, 0, 0, 0, 0, 0, 0, 0, 0, 0\]/, 'Flat is the ten-zero target');
like($js, qr/house:\s*\[3, 2, 1, 0\.5, 0, 0, -0\.5, -1, -1\.5, -2\]/, 'House is the gentle downward tilt');
like($markup, qr/name="studio_mastering_target" value="house"/, 'the UI offers House');
like($markup, qr/name="studio_mastering_target" value="flat"/, 'the UI offers Flat');
like($markup, qr/value="house" checked/, 'House is the default target');

# --- Reset restores the manual curve ---------------------------------------
like($js, qr/function studioMasteringManual\(\)/, 'the manual curve is captured first');
like($js, qr/function studioMasteringReset\(\)/, 'Reset is its own action');
like($js, qr/function studioMasteringRestoreManual\(manual\)/, 'Reset restores the captured values');
like($js, qr/studioMasterToggle\('master_eq', manual\.on === true\)/, 'Reset also restores the EQ footswitch');
like($markup, qr/id="studio_mastering_reset"/, 'the rack markup carries Reset');

# --- the run writes master_eq and saves the song ---------------------------
like($js, qr/studioMasterSet\('master_eq', band\.control, studioMasteringDbToValue\(band\.correction\)\)/,
	'the learned correction is written into the existing ten master_eq bands');
like($js, qr/studioMasterToggle\('master_eq', true\)/, 'the learned curve switches the EQ in');
like($js, qr/if \(typeof studioSave === 'function'\) \{ studioSave\(\); \}/, 'the song is saved after the Learn');
my @holds = ($js =~ /master_eq/g);
ok(scalar @holds > 5, 'the block drives master_eq rather than a second EQ');

# --- stopping the microphone -----------------------------------------------
like($js, qr/function studioMasteringMediaStop\(\)/, 'the media has its own stop');
like($js, qr/getTracks\(\)\.forEach/, 'every track is stopped');
like($js, qr/track\.stop\(\)/, 'the tracks are actually stopped');
like($js, qr/state\.source\.disconnect\(\)/, 'the mic source is disconnected');
like($js, qr/chain\.input\.disconnect\(state\.ref\)/, 'the pre-master tap is disconnected');
like($js, qr/function studioMasteringStop\(\)/, 'a Stop action exists');
like($js, qr/function studioMasteringReset\(\)[\s\S]*?studioMasteringMediaStop\(\)/, 'Reset stops the media too');

# --- refusals say why -------------------------------------------------------
like($js, qr/mixer\['time'\]\['engine_transport'\]/, 'Learn checks whether the engine owns the transport');
like($js, qr/engine owns playback, so the browser master chain is silent/i,
	'Learn refuses in a sentence while the engine plays');
like($js, qr/Learn is browser monitoring only/, 'the refusal says this slice is browser monitoring only');
like($js, qr/This browser cannot open a microphone/, 'a browser without getUserMedia gets a sentence');
like($js, qr/Could not open a microphone: permission denied or none is connected/,
	'permission denial and a missing mic get a sentence');
like($js, qr/#studio_mastering_status/, 'the status line is updated');
like($markup, qr/id="studio_mastering_status"/, 'the rack markup carries the status line');

# --- the rack keeps working -------------------------------------------------
like($js, qr/function studioMasterApply\(\)/, 'studioMasterApply is still there');
like($js, qr/function studioMasterRender\(\)/, 'studioMasterRender is still there');
like($js, qr/function studioMasterChain\(ctx\)/, 'studioMasterChain is still the fixed insert chain');
like($markup, qr/id="studio_master_rack"[\s\S]*id="studio_mastering"[\s\S]*studio_master_effect/,
	'the mastering block sits inside the rack, above the units');
like($markup, qr/id="studio_mastering"[\s\S]*studio_mastering_band[\s\S]*<\/div>/,
	'the bars are part of the mastering block');

# --- the block is styled as part of the rack -------------------------------
like($style, qr/\.studio_mastering\s*\{/, 'the block has its own faceplate style');
like($style, qr/\.studio_mastering_bars\s*\{/, 'the bars are a ten-column grid');
like($style, qr/grid-template-columns: repeat\(10, minmax\(0, 1fr\)\)/, 'exactly ten columns are drawn');
like($style, qr/\.studio_mastering_band_before\s*\{/, 'the measured bar is styled');
like($style, qr/\.studio_mastering_band_after\s*\{/, 'the applied bar is styled');
like($style, qr/\.studio_mastering_band_target\s*\{/, 'the target mark is styled');
like($style, qr/\.studio_mastering_learn\[aria-pressed=true\]/, 'the running button reads as armed');

done_testing;
