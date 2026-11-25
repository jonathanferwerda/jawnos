# tests-for: public/js/manager/studio.js public/js/manager/studio/08_effects.js docs/studio-effects.md
# covers:    The stereo panner acts after the pedalboard, as the native engine
#            does: the browser insert is a pass-through carrying `fx.panner`
#            (rate/depth/shape), and the channel's own pan stage - `playPan`,
#            after the Out chain - sums the channel pan with `depth * lfo`.
#            Pins that the insert no longer owns a StereoPannerNode, that
#            studioChannelEngine wires an oscillator and depth gain into
#            playPan.pan, that studioPanLfoAll is called from both rebuilds,
#            that the precedence is Out chain then In chain with the last
#            enabled panner winning, and that the contract says so.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root   = repo_root();
my $studio = read_file("$root/public/js/manager/studio.js");
my $fx     = read_file("$root/public/js/manager/studio/08_effects.js");
my $docs   = read_file("$root/docs/studio-effects.md");

# The insert: a pass-through that owns no panner node.
my ($pan) = $fx =~ /(function studioEffectStereoPanner\(ctx, name\) \{.*?\n\})/s;
ok(defined $pan, 'studioEffectStereoPanner is a builder');

like($pan // '', qr/fx\.input\.connect\(fx\.wet\)/,
	'the panner insert passes the signal straight through');
unlike($pan // '', qr/createStereoPanner/,
	'the insert builds no StereoPannerNode');
unlike($pan // '', qr/fx\.input\.connect\(panner\)\.connect\(fx\.wet\)/,
	'the panner is no longer baked into the insert chain');
unlike($pan // '', qr/panner\.pan/,
	'the insert no longer modulates a pan param of its own');

like($pan // '', qr/fx\.panner = \{ rate: 1, depth: 0, shape: 0 \};/,
	'the insert exposes the resolved fx.panner configuration');
like($pan // '', qr/fx\.panner\.rate = studioEffectClamp\(hz, 0\.1, 20\);/,
	'the rate setter stores the clamped hertz on fx.panner');
like($pan // '', qr/fx\.panner\.depth = studioEffectClamp\(studioEffectNatural\(fx\.name, 'depth', v\), 0, 1\);/,
	'the depth setter stores the 0..1 swing on fx.panner');
like($pan // '', qr/fx\.panner\.shape = Math\.round\(studioEffectNatural\(fx\.name, 'shape', v\)\);/,
	'the shape setter stores the shared shape index on fx.panner');
like($pan // '', qr/studioEffectTempo\(fx, applyRate\)/,
	'a tempo-synced rate still resolves to Hz through the natural setter');
like($pan // '', qr/fx\.set\('rate', 25\);\s*\n\s*fx\.set\('depth', 50\);\s*\n\s*fx\.set\('shape', 0\);/,
	'the builder keeps the rate/depth/shape defaults');
like($pan // '', qr/if \(typeof studioPanLfoAll === 'function'\) \{ studioPanLfoAll\(\); \}/,
	'a control change re-reads the channel pan stage');
like($pan // '', qr/var shellBypass = fx\.setBypass;\s*\n\s*fx\.setBypass = function \(on\) \{ shellBypass\(on\); apply\(\); \};/,
	'the footswitch tells the pan stage to stop modulating');

# The channel's pan stage: an oscillator and a depth gain on playPan.pan.
my ($engine) = $studio =~ /(function studioChannelEngine\(ch\) \{.*?\n\})/s;
ok(defined $engine, 'studioChannelEngine is the channel graph');
like($engine // '', qr/playPan: ctx\.createStereoPanner\(\)/,
	'the channel pan is a real StereoPannerNode');
like($engine // '', qr/panLfo: ctx\.createOscillator\(\),\s*\n\s*panLfoDepth: ctx\.createGain\(\),/,
	'each channel owns a pan-stage oscillator and depth gain');
like($engine // '', qr/c\.panLfo\.type = 'sine';/,
	'the pan LFO starts as a sine');
like($engine // '', qr/c\.panLfoDepth\.gain\.value = 0;/,
	'the depth starts at zero, so the plain channel pan is heard');
like($engine // '', qr/c\.panLfo\.connect\(c\.panLfoDepth\)\.connect\(c\.playPan\.pan\);/,
	'the LFO is summed into playPan.pan, the stage after the pedalboard');
like($engine // '', qr/try \{ c\.panLfo\.start\(0\); \} catch \(e\) \{\}/,
	'the oscillator is started');

# studioPanLfoAll: the scan that hands the last enabled panner to the stage.
like($studio, qr/^function studioPanLfoAll\(\)/m, 'studioPanLfoAll exists');
like($studio, qr/\[c\.outInserts, c\.inserts\]\.some/,
	'the playback (Out) chain is asked first, then the In chain');
like($studio, qr/!item\.bypassed && item\.panner/,
	'a bypassed panner is not handed to the pan stage');
like($studio, qr/c\.panLfo\.type = \(shape === 1\) \? 'triangle' : \(\(shape === 2\) \? 'square' : 'sine'\);/,
	'the shared shape index drives the oscillator type');
like($studio, qr/c\.panLfo\.frequency\.value = config \? Math\.max\(0\.1, Math\.min\(20, config\.rate\)\) : 1;/,
	'the LFO rate is the panner rate, clamped to the shared band');
like($studio, qr/c\.panLfoDepth\.gain\.value = config \? Math\.max\(0, Math\.min\(1, config\.depth\)\) : 0;/,
	'no panner means depth 0');

my ($rebuild_in)  = $studio =~ /(function studioRebuildInserts\(ch\) \{.*?\n\})/s;
my ($rebuild_out) = $studio =~ /(function studioRebuildOutputs\(ch\) \{.*?\n\})/s;
ok(defined $rebuild_in,  'studioRebuildInserts is found');
ok(defined $rebuild_out, 'studioRebuildOutputs is found');
like($rebuild_in  // '', qr/studioPanLfoAll\(\);/, 'the In-chain rebuild refreshes the pan stage');
like($rebuild_out // '', qr/studioPanLfoAll\(\);/, 'the Out-chain rebuild refreshes the pan stage');

# The contract.
like($docs, qr/`stereo_panner` is \*\*native\*\*, and it is not a mono insert on either side\./,
	'the contract says the panner is a pass-through on both sides');
like($docs, qr/The\nbrowser mirrors this: `studioEffectStereoPanner` is a pass-through exposing\n`fx\.panner`/,
	'the contract names the browser pass-through and fx.panner');
like($docs, qr/`studioPanLfoAll` applies the last enabled panner at the\nchannel's pan stage after the chain/,
	'the contract says the browser applies the LFO at the pan stage');
like($docs, qr/Because that stage is a mix stage, the panner is\nheard on playback; it is not printed into a take/,
	'the contract notes the panner is a mix stage, not printed into a take');
unlike($docs, qr/The browser keeps\n`studioEffectStereoPanner` with a `StereoPannerNode`/,
	'the old claim that the browser keeps the node inside the insert is gone');
unlike($docs, qr/The browser's `StereoPannerNode` is the mirror,/,
	'the old mirror sentence is gone');

done_testing();
