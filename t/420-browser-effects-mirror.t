# tests-for: public/js/manager/studio/08_effects.js
# covers:    The browser mirrors of the engine's pedal circuits. The master rack
#            gets a ten-band graphic EQ (b32..b16k, each 0..100 -> -12..+12 dB,
#            peaking Q 1.4) with the old low/mid/high names aliased onto 125 Hz,
#            1 kHz and 8 kHz; the distortion is the ProCo RAT's 2..200 gain stage
#            with an asymmetric diode shaper and a 4 kHz two-pole lowpass; the
#            delay is the DM-2's companded line with a feedback lowpass that
#            follows the delay time; the compressor gains the Dyna Comp's tanh
#            output stage; the flanger is the Electric Mistress with a triangle
#            LFO, filtered wet and feedback, and the fixed `dry = 1 - mix`; the
#            reverb builds the spring as two combs plus allpasses and the plate
#            as dense early reflections; the equalizer is the Baxandall coupled
#            section through IIRFilterNode with a biquad fallback; and the
#            limiter/maximizer carry the 1176 FET detector as an inline
#            AudioWorklet with a synchronous 20:1 + hard-ceiling fallback.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root = repo_root();
my $fx   = read_file("$root/public/js/manager/studio/08_effects.js");

# --- the master graphic EQ: ten bands ---------------------------------------
my @bands = qw(b32 b64 b125 b250 b500 b1k b2k b4k b8k b16k);
for my $band (@bands) {
	like($fx, qr/control:\s*'\Q$band\E'/, "the master EQ carries the $band band");
}

my @hz = (32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000);
for my $i (0 .. $#bands) {
	like($fx, qr/control:\s*'\Q$bands[$i]\E',\s*hz:\s*\Q$hz[$i]\E/,
		"$bands[$i] is centred on $hz[$i] Hz");
}

like($fx, qr/filter\.type = 'peaking';/, 'the bands are peaking filters');
like($fx, qr/filter\.frequency\.value = Math\.min\(band\.hz, ctx\.sampleRate \* 0\.49\);?/,
	'a band cannot sit past Nyquist');
like($fx, qr/filter\.Q\.value = 1\.4;/, 'the bands have Q 1.4');
like($fx, qr/function studioMasterEqDb\(value\) \{\s*\n\s*return -12 \+ studioEffectClamp\(value, 0, 100\) \/ 100 \* 24;/,
	'each 0..100 slider maps to -12..+12 dB');
like($fx, qr/var legacy = \{ low: 'b125', mid: 'b1k', high: 'b8k' \};/,
	'low, mid and high are shortcuts onto 125 Hz, 1 kHz and 8 kHz');
like($fx, qr/^function studioEffectMasterEq\(ctx, name\)/m,
	'the master EQ builder takes a context and a name');
like($fx, qr/\bmaster_eq\s*:\s*studioEffectMasterEq/,
	'the builder table registers studioInsert(ctx, \'master_eq\')');
like($fx, qr/if \(Object\.prototype\.hasOwnProperty\.call\(studioEffectBuilders, name\)\)/,
	'an exact builder name wins over its alias kind');

# --- the ProCo RAT -----------------------------------------------------------
like($fx, qr/^function studioRatCurve\(\)/m, 'the RAT has its own transfer table');
like($fx, qr/forward = \(x < 0\) \? 0\.74 : 0\.66;/,
	'the two silicon diodes are not matched, so the clip is asymmetric');
like($fx, qr/preGain\.gain\.value = 2 \+ travel \* travel \* 198;/,
	'the LM308 stage runs from 2 to 200 over the drive travel');
like($fx, qr/shaper\.oversample = '4x';/, 'the diode clip is 4x oversampled');
like($fx, qr/lp1\.frequency\.value = 4000;[\s\S]*?lp2\.frequency\.value = 4000;/,
	'a two-pole 4 kHz lowpass follows the clip');
like($fx, qr/trim\.gain\.value = 0\.7;/, 'the output is trimmed like the engine');

# --- the Boss DM-2 -----------------------------------------------------------
like($fx, qr/^function studioDm2Bandwidth\(seconds\)/m,
	'the BBD bandwidth follows the delay time');
like($fx, qr/Math\.sqrt\(0\.02 \/ time\)/, 'it uses the engine square-root clock law');
like($fx, qr/var delay = ctx\.createDelay\(8\);/, 'the line is an 8 s DelayNode, enough for four bars at 120 BPM');
like($fx, qr/fx\.input\.connect\(inputHP\)\.connect\(comp\)\.connect\(delay\);/,
	'the input compressor sits before the line');
like($fx, qr/delay\.connect\(feedbackLP\)\.connect\(feedback\)\.connect\(delay\);/,
	'the feedback runs through the lowpass');
like($fx, qr/delay\.delayTime\.value = time;/,
	'the wet path is exactly the resolved time, so the first echo lands there');
like($fx, qr/feedbackLP\.frequency\.value = studioDm2Bandwidth\(time\);/,
	'the feedback corner follows the delay time');

# --- the MXR Dyna Comp -------------------------------------------------------
like($fx, qr/^function studioTanhCurve\(\)/m, 'the shared tanh output stage exists');
like($fx, qr/fx\.input\.connect\(comp\)\.connect\(shaper\)\.connect\(wet\)\.connect\(fx\.wet\);/,
	'the compressor runs into the tanh stage before the dry/wet mix');
like($fx, qr/The extra slope the OTA's control\s*\n\/\/\s*current adds at high level/,
	'the level-dependent squash is documented as the approximation');

# --- the Electric Mistress ---------------------------------------------------
like($fx, qr/lfo\.type = 'triangle';/, 'the flanger LFO is a triangle');
like($fx, qr/preGain\.gain\.value = 2;/, 'the input is pre-amplified about 6 dB');
like($fx, qr/wetLP\.frequency\.value = 6800;[\s\S]*?wetHP\.frequency\.value = 160;/,
	'the wet path is lowpassed at 6.8 kHz and highpassed at 160 Hz');
like($fx, qr/colorLP\.frequency\.value = 6800;[\s\S]*?colorHP\.frequency\.value = 160;/,
	'the feedback path carries the same pair');
like($fx, qr/wet\.gain\.value = n;\s*\n\s*dry\.gain\.value = 1 - n;/,
	'dry is 1 - mix, the fixed bug (not 1 - mix * 0.5)');
unlike($fx, qr/dry\.gain\.value = 1 - n \* 0\.5;/, 'the half-dry flanger bug is gone');
like($fx, qr/var studioFlangerMinDelay = 0\.0007;[\s\S]*?var studioFlangerMaxSweep = 0\.0043;/,
	'the sweep is the BBD 0.7..5 ms range');

# --- the reverb tanks --------------------------------------------------------
like($fx, qr/^function studioSpringImpulse\(ctx, shape\)/m,
	'the spring has a tank impulse builder');
like($fx, qr/var combs = \[0\.0293, 0\.0341\];/, 'the spring has two comb loops');
like($fx, qr/var allpasses = \[0\.0017, 0\.0053\];/, 'and two allpass sections');
like($fx, qr/^function studioPlateImpulse\(ctx, shape\)/m,
	'the plate has its own impulse builder');
like($fx, qr/var taps = 64;/, 'the plate is dense early reflections');
like($fx, qr/^function studioNoiseImpulse\(ctx, shape\)/m,
	'Room, Hall and Cave keep the generated-noise shape');
like($fx, qr/name: 'Spring', seconds: 1\.8/, 'the spring keeps its 1.8 s length');
like($fx, qr/name: 'Plate',\s+seconds: 2\.2/, 'the plate keeps its 2.2 s length');
like($fx, qr/if \(shape\.spring\) \{ impulse = studioSpringImpulse\(ctx, shape\); \}\s*\n\s*else if \(shape\.plate\) \{ impulse = studioPlateImpulse\(ctx, shape\); \}/,
	'the model number chooses the tank');
like($fx, qr/studioReverbImpulse\(ctx, m\)/, 'the model setter still swaps the buffer');

# --- the Baxandall equalizer -------------------------------------------------
like($fx, qr/^function studioBaxandallCoefficients\(rate, lowDb, highDb\)/m,
	'the coupled bass/treble section has one coefficient design');
like($fx, qr/var shift = Math\.pow\(bass \/ treble, 0\.15\);?/,
	'the shared feedback loop shifts the two poles by the balance');
like($fx, qr/coupled = ctx\.createIIRFilter\(\[1, 0, 0\], \[1, 0, 0\]\);/,
	'flat starts as the identity IIRFilterNode');
like($fx, qr/next = ctx\.createIIRFilter\(coefficients\.feedforward, coefficients\.feedback\)/,
	'a knob move rebuilds the coupled section synchronously');
like($fx, qr/No IIRFilterNode: the cheap approximation, three independent filters\./,
	'without IIRFilterNode the three-biquad fallback is stated');

# --- the 1176 limiter / maximizer -------------------------------------------
like($fx, qr/registerProcessor\('jawnos-fet', JawnosFetProcessor\);/,
	'the FET detector is an inline AudioWorkletProcessor');
like($fx, qr/this\.attack = 1 - Math\.exp\(-1 \/ \(20e-6 \* sampleRate\)\);/,
	'the worklet has the 1176 fixed 20 us attack');
like($fx, qr/const kneeDb = 2\.5, kneeBow = kneeDb \/ 4, kneeTop = Math\.pow\(10, kneeDb \/ 20\);/,
	'and the soft 2.5 dB knee above the ceiling');
like($fx, qr/const r = fast \+ \(slow - fast\) \* st\.sustain;/,
	'and the program-dependent release through the sustain memory');
like($fx, qr/^function studioFetWorkletReady\(ctx\)/m, 'the module loads through a Blob URL');
like($fx, qr/URL\.createObjectURL\(new Blob\(\[studioFetWorkletSource\]/,
	'following the StudioLatencyProbe pattern');
like($fx, qr/comp\.ratio\.value = 20;/, 'the synchronous fallback is a 20:1 compressor');
like($fx, qr/ceilingShaper\.curve = studioFetCeilingCurve\(ceiling\);?/,
	'with a hard-ceiling WaveShaper');
like($fx, qr/fx\.input\.connect\(makeup\)\.connect\(comp\)\.connect\(ceilingShaper\)\.connect\(fx\.wet\);/,
	'and it is wired before the module resolves');
like($fx, qr/node = new AudioWorkletNode\(ctx, 'jawnos-fet'\);/,
	'the worklet replaces the fallback when it loads');
like($fx, qr/state\.drive = amount \* 18;/, 'loudness is the engine\'s 0..18 dB drive');
like($fx, qr/^function studioEffectLimiter\(ctx, name\)/m, 'the limiter keeps its builder signature');
like($fx, qr/^function studioEffectMaximizer\(ctx, name\)/m, 'the maximizer keeps its builder signature');

# --- the FMV tone stack stays honest ---------------------------------------
like($fx, qr/ToneStack in\s*\n\/\/ engine\/src\/effect\.rs/, 'the tone stack names the engine model');
like($fx, qr/exact interaction needs an AudioWorklet/,
	'and says why the three biquads remain');

done_testing();
