# tests-for: engine/src/effect.rs engine/src/effect/stereo_panner.rs engine/src/mixer.rs lib/JawnOS/Audio/Plan.pm
# covers:    Stereo Panner is a native insert: a pass-through effect that hands a
#            rate/depth/shape LFO to the channel's pan stage, which applies it
#            around the channel's own pan. Depth 0 is the plain pan exactly, the
#            last panner in chain order wins, a bypassed panner configures
#            nothing, and `sync` stays a browser-only tempo string. The browser
#            builder (08_effects.js) is unchanged; t/345 covers that side.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root   = repo_root();
my $effect = read_file("$root/engine/src/effect.rs");
my $panner = read_file("$root/engine/src/effect/stereo_panner.rs");
my $mixer  = read_file("$root/engine/src/mixer.rs");
my $plan   = read_file("$root/lib/JawnOS/Audio/Plan.pm");
my $doc    = read_file("$root/docs/studio-effects.md");
my $audit  = read_file("$root/docs/pedal-audit.md");

# --- the insert kinds agree on both sides ------------------------------------
like($effect, qr/^\s*mod stereo_panner;$/m, 'effect.rs declares the panner module');
like($effect, qr/pub use stereo_panner::\{PanLfo, StereoPanner\};/,
	'and re-exports the effect and its LFO');
like($effect, qr/^\s*StereoPanner,$/m, 'InsertKind has a StereoPanner variant');
like($effect, qr/"stereo_panner"\s*=>\s*Some\(InsertKind::StereoPanner\)/,
	'parse accepts the browser wire name');
like($effect, qr/InsertKind::StereoPanner\s*=>\s*"stereo_panner"/,
	'and the engine reports the same name');
like($effect, qr/InsertKind::StereoPanner\s*=>\s*&\s*\["rate", "depth", "shape"\]/,
	'the three controls are the contract');
like($effect, qr/InsertKind::StereoPanner\s*=>\s*15/,
	'the wire code is 15, after tremolo');
like($effect, qr/15\s*=>\s*InsertKind::StereoPanner/,
	'and the code round-trips');
like($effect, qr/InsertKind::StereoPanner\s*=>\s*Box::new\(StereoPanner::new\(5\.0, 0\.5, 0\)\)/,
	'the default build is 5 Hz / half depth / sine');

# --- the effect is a pass-through that only configures the pan ---------------
like($effect, qr/fn pan_lfo\(&self\) -> Option<PanLfo> \{\s*\n\s*None\s*\n\s*\}/,
	'Effect::pan_lfo is defaulted, so no effect must implement it');
like($panner, qr/pub struct PanLfo/, 'the LFO travels as a plain value');
like($panner, qr/pub struct StereoPanner\s*\{[\s\S]*?hz: f32,[\s\S]*?depth: f32,[\s\S]*?shape: u8,/,
	'the effect holds only the three knobs');
like($panner, qr/fn process\(&mut self, _block: &mut \[f32\]\) \{\s*\n[\s\S]*?pass-through/,
	'process is a documented no-op, so the mono signal is untouched');
like($panner, qr/fn pan_lfo\(&self\) -> Option<PanLfo> \{\s*\n\s*Some\(self\.lfo\(\)\)\s*\n\s*\}/,
	'and it exposes its configuration');
like($panner, qr/0 sine, 1 triangle, 2 square/, 'the shape indexes are documented');
like($panner, qr/1 => 1\.0 - 4\.0 \* \(phase - 0\.5\)\.abs\(\)/,
	'the triangle matches the tremolo and the browser');
like($panner, qr/2 => \{\s*\n\s*if phase < 0\.5 \{/, 'the square keeps its two levels');
like($panner, qr/std::f32::consts::TAU \* phase\)\.sin\(\)/, 'the sine is the shared shape');
like($panner, qr/pub fn phase_step\(&self, sample_rate: u32\) -> f32/,
	'the channel asks for its per-sample step');
like($panner, qr/self\.hz = value\.clamp\(Self::MIN_RATE_HZ, Self::MAX_RATE_HZ\)/,
	'the rate clamps to 0.1..20 Hz');
like($panner, qr/self\.depth = value\.clamp\(0\.0, 1\.0\)/, 'the depth clamps to 0..1');
like($panner, qr/self\.shape = value\.round\(\)\.clamp\(0\.0, 2\.0\) as u8/,
	'the shape is a whole 0..2 index');
unlike($panner, qr/"sync"\s*=>/, 'sync is not an engine control');

# --- the channel applies the LFO at the pan stage -----------------------------
like($effect, qr/pan_phase: f32/, 'the channel owns the LFO phase');
like($effect, qr/fn place_mono\(/, 'the pan placement is one function for both paths');
like($effect, qr/Some\(lfo\) if lfo\.depth > 0\.0 =>/,
	'a positive depth is the only per-sample modulated path');
like($effect, qr/let position = \(pan \+ lfo\.depth \* lfo\.value\(\*phase\)\)\.clamp\(-1\.0, 1\.0\);/,
	'the LFO moves the channel pan and is clamped to the field');
like($effect, qr/let _ = mix_mono_into_stereo_with_gains\(stereo, mono, left, right\);/,
	'zero depth keeps the exact plain-pan arithmetic');
like($effect, qr/pub fn pan_lfo\(&self\) -> Option<PanLfo> \{\s*\n\s*let mut lfo = None;[\s\S]*?lfo = Some\(config\);/s,
	'the chain takes the last panner in order');
like($effect, qr/if slot\.bypassed \{\s*\n\s*continue;/, 'a bypassed panner is skipped');
like($effect, qr/self\.pan_phase = 0\.0;\s*\n\s*\}/, 'reset and prepare restart the phase');
like($mixer, qr/pub fn pan_into\(&mut self, index: usize/,
	'the mixer pan tap can advance the track phase');

# --- the plan and the docs agree ---------------------------------------------
my ($plan_names) = $plan =~ /our \@audio_plan_insert_names = qw\((.*?)\);/s;
like($plan_names, qr/\bstereo_panner\b/, 'the source plan offers stereo_panner');
like($plan, qr/stereo_panner\s*=>\s*\[qw\(rate depth shape\)\]/,
	'with the three native controls');
like($plan, qr/stereo_panner\s*=>\s*\{ shape\s*=> 1 \}/,
	'and shape is a whole index on the write path');
unlike($plan_names, qr/\bstereowidener\b/,
	'stereowidener stays absent from the source vocabulary');

like($doc, qr/`stereo_panner` is \*\*native\*\*/, 'the contract calls the panner native');
like($doc, qr/transparent pass-through that carries an LFO configuration/,
	'and says the pan stage applies it');
like($doc, qr/depth 0 is exactly the plain pan and is bit-identical/,
	'depth 0 is documented as bit-identical');
like($doc, qr/last one in chain order wins/, 'the two-panner rule is stated');
like($doc, qr/`stereowidener` is a \*\*browser-only\*\* insert/,
	'stereowidener remains the browser-only one');
like($doc, qr/It is \*\*not\*\* an engine\ncontrol/, 'sync remains UI-only');

like($audit, qr/^\| `stereo_panner` \|/m, 'the pedal audit has a panner row');
like($audit, qr/engine\/src\/effect\/stereo_panner\.rs/,
	'and names the native module');
like($audit, qr/The panner is not an L\/R insert/,
	'and says the pan point is the channel, not a stereo insert');

done_testing();
