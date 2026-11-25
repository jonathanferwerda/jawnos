# tests-for: public/js/manager/synth/01_engine.js templates/synth.html.ep templates/synth_inner.html.ep templates/synth_style.html.ep
# covers:    the browser synth's note tap and offline renderer (what Studio records
#            and plays) and the shared full-panel markup. The engine stays the one
#            singleton: onnote reports one on and one off per voice at the lowest
#            layer, render speaks the same voices and master chain on a fresh
#            OfflineAudioContext without touching the live graph, capture keeps the
#            browser audible for a Studio take without doubling the engine voice,
#            and the computer keyboard only plays for the synth host that owns the
#            last press. The standalone page is the shared surface plus the shared
#            scoped styles, which the Studio panel includes inside its own #synth.

use strict;
use warnings;

use Cwd qw(abs_path);
use FindBin;
use File::Slurp qw(read_file);
use Test::More;

my $root = abs_path("$FindBin::Bin/..");

my $engine  = read_file("$root/public/js/manager/synth/01_engine.js");
my $presets = read_file("$root/public/js/manager/synth_presets.js");
my $synth   = read_file("$root/templates/synth.html.ep");
my $inner   = read_file("$root/templates/synth_inner.html.ep");
my $style   = read_file("$root/templates/synth_style.html.ep");

# --- the preset library the engine builds from still rides this page ---------
like( $presets, qr/window\.jawnosSynthFamilies\s*=\s*\[/, 'the preset library is still data the engine reads' );

# --- onnote: subscribe, unsubscribe, the event shape --------------------------
like( $engine, qr/onnote:\s*subscribeNote/, 'onnote is part of the browser synth API' );
like( $engine, qr/function subscribeNote\(fn\)/, 'one subscriber function owns the list' );
like( $engine, qr/noteListeners\.push\(fn\)/, 'a subscriber is added' );
like( $engine, qr/return function \(\) \{\s*var at = noteListeners\.indexOf\(fn\)/s,
	'and the return value unsubscribes' );
like( $engine, qr/noteListeners\.splice\(at, 1\)/, 'by removing exactly that function' );
like( $engine, qr/var event = \{ on: !!on, note: note, velocity: velocity, time: time \}/,
	'each edge is { on, note, velocity, time }' );
like( $engine, qr/var time = \(S\.ctx && !offlineRendering\) \? S\.ctx\.currentTime : at/,
	'a live edge is stamped with the live context clock' );

# --- the tap is at the lowest voice layer, exactly one off per voice ----------
like( $engine, qr/function noteTapOn\(voice, at\)/, 'a voice reports its on' );
like( $engine, qr/function noteTapOff\(voice, at\)/, 'and its off' );
is( scalar( () = $engine =~ /noteTapOn\(voice, t0\)/g ), 2,
	'both voice engines (pluck and subtractive) tap the same layer' );
like( $engine, qr/if \(!voice \|\| !voice\.tapped \|\| voice\.tappedOff\) \{ return; \}/,
	'a voice can only report one off' );
like( $engine, qr/voice\.tappedOff = true;/, 'the guard is set before the event' );
is( scalar( () = $engine =~ /noteTapOff\(voice, t1\)/g ), 2,
	'a normal release in either voice engine reports the off' );
like( $engine, qr/noteTapOff\(voice, S\.ctx \? S\.ctx\.currentTime : voice\.started\)/,
	'a killed (stolen or detached) voice still owes its off' );
like( $engine, qr/function soundNote\(note, velocity, glideFrom\) \{\s*var v = newVoice\(/s,
	'Arp, Seq and MIDI all reach the same soundNote -> newVoice path' );

# --- the tap is disabled for the offline renderer -----------------------------
like( $engine, qr/var offlineRendering = false;/, 'a module flag pauses the tap' );
like( $engine, qr/if \(!voice \|\| offlineRendering\) \{ return; \}/,
	'a renderer voice never reports an on' );
like( $engine, qr/offlineRendering = true;/, 'the renderer sets the flag while it schedules' );
like( $engine, qr/offlineRendering = false;/, 'and clears it when scheduling ends' );
like( $engine, qr/if \(!voice \|\| !voice\.tapped \|\| voice\.tappedOff\)/, 'the off guard is shared' );

# --- render: the API, the fresh context, beats -> seconds ---------------------
like( $engine, qr/render:\s*render,/, 'render is part of the browser synth API' );
like( $engine, qr/function render\(opts\)/, 'one offline render entry point' );
like( $engine, qr/opts = \{ notes: \[\{ n, t, d, v \}\], patch, bpm, beats, rate \}/,
	'the options are the promised note clip' );
like( $engine, qr/var Ctor = window\.OfflineAudioContext \|\| window\.webkitOfflineAudioContext/,
	'a fresh OfflineAudioContext, never the live one' );
like( $engine, qr/try \{ ctx = new Ctor\(2, length, rate\); \}/,
	'a stereo buffer at the asked sample rate' );
like( $engine, qr/var length = Math\.max\(1, Math\.ceil\(beats \* 60 \/ bpm \* rate\)\)/,
	'the buffer length is ceil(beats * 60 / bpm * rate)' );
like( $engine, qr/var secondsPerBeat = 60 \/ bpm;/, 'beats become seconds through the tempo' );
like( $engine, qr/var at = Math\.max\(0, \(Number\(n\.t\) \|\| 0\) \* secondsPerBeat\)/,
	'a note start is its beat offset in seconds' );
like( $engine, qr/var d = Math\.max\(0\.01, \(Number\(n\.d\) \|\| 0\) \* secondsPerBeat\)/,
	'and its duration is its beat length in seconds' );
like( $engine, qr/notes\.sort\(function \(a, b\) \{ return \(Number\(a\.t\) \|\| 0\) - \(Number\(b\.t\) \|\| 0\); \}\);/,
	'notes are scheduled in time order' );

# --- render uses the live voice DSP and the live master chain -----------------
like( $engine, qr/out\.connect\(shaper\)\.connect\(comp\)\.connect\(post\)\.connect\(ctx\.destination\)/,
	'drive -> compressor -> post is the live order' );
like( $engine, qr/comp\.threshold\.value = -12;/, 'the same compressor threshold' );
like( $engine, qr/comp\.ratio\.value = 4;/, 'and ratio' );
like( $engine, qr/post\.gain\.value = 1;/, 'a mute-free post gain' );
like( $engine, qr/var curve = driveCurve\(patch\.drive\);/, 'the same drive curve' );
like( $engine, qr/lfoPitch\.gain\.value = depths\.pitch \* 1200;/, 'the same LFO pitch depth' );
like( $engine, qr/lfoCutoff\.gain\.value = depths\.cutoff \* 2400;/, 'the same filter depth' );
like( $engine, qr/lfoAmp\.gain\.value = depths\.amp \* 0\.5;/, 'the same tremolo depth' );
like( $engine, qr/ctx: ctx, patch: patch, out: out, start: at,/, 'the renderer passes its own context and patch' );
like( $engine, qr/offline: true/, 'and marks the voice offline' );
like( $engine, qr/var mono = !!patch\.mono;/, 'mono clips render as one moving voice' );
like( $engine, qr/glideFrom = \(patch\.glide > 0\) \? lastFreq : 0;/, 'with glide where the patch asks' );

# --- live path unchanged: the DSP formulas and the engine bridge still there --
like( $engine, qr/0\.25 \+ velocity \* 0\.6/, 'the subtractive amp peak is unchanged' );
like( $engine, qr/0\.5 \+ velocity \* 0\.5/, 'the pluck amp peak is unchanged' );
like( $engine, qr/damp\.frequency\.value = Math\.min\(18000, freq \* \(2 \+ \(p\.brightness \|\| 0\.5\) \* 12\) \* \(0\.6 \+ 0\.8 \* velocity\)\)/,
	'the pluck loop brightness is unchanged' );
like( $engine, qr/mix\.connect\(filter\)\.connect\(amp\)/, 'the subtractive mixer -> filter -> amp is unchanged' );
like( $engine, qr/filterEnv\(filter, \(\(p\.filter && p\.filter\.cutoff\) \|\| 3000\)/, 'the filter envelope is unchanged' );
like( $engine, qr/var detune = host\.bend \* 200 \+ \(o\.detune \|\| 0\) \+ \(host\.mod \* 50\);/,
	'bend and mod reach the oscillators as before' );
like( $engine, qr/function liveVoiceContext\(\)/, 'the live path now names its own context explicitly' );
like( $engine, qr/ctx: S\.ctx,/, 'the live context is the live one' );
like( $engine, qr/out: S\.out,/, 'and its live output' );
like( $engine, qr/start: S\.ctx\.currentTime,/, 'and the live start time' );
is( scalar( () = $engine =~ /if \(!host\.offline\) \{ setTimeout/g ), 2,
	'both cleanup timers only run for live voices' );
like( $engine, qr/engineApi\('note'/, 'the engine note bridge still exists' );
like( $engine, qr/engineApi\('all_off'/, 'and the all-off bridge' );
like( $engine, qr/outputNode: function \(\) \{ return S\.post/, 'the studio tap is unchanged' );
like( $engine, qr/mute: function \(on\)/, 'mute is unchanged' );

# --- capture: a Studio take records the browser graph -------------------------
like( $engine, qr/capture: synthCapture,/, 'capture is on the public browser synth API' );
like( $engine, qr/function synthCapture\(on\) \{/, 'one capture switch' );
like( $engine, qr/if \(on === S\.capture\) \{ return S\.capture; \}/, 'repeating the same choice is harmless' );
like( $engine, qr/S\.capture = on;/, 'the flag is stored' );
like( $engine, qr/engineAllOff\(\);\s*\/\/ the browser take owns the live notes now/,
	'turning capture on silences the engine once' );
like( $engine, qr/applyMute\(false\);\s*\/\/ the take records post/, 'and makes the browser voices audible' );
like( $engine, qr/else \{\s*engineSyncOutput\(\);\s*\}/, 'turning it off restores the normal Sound choice' );
like( $engine, qr/applyMute\(!S\.capture && S\.sound === 'engine' && S\.enginePlaying\)/,
	'every engine sync respects capture' );
like( $engine, qr/if \(S\.capture \|\| !engineLive\(\)\) \{ return; \}/,
	'no live note reaches the engine while capturing' );
my ($capture_body) = $engine =~ /function synthCapture\(on\) \{(.*?)\n\t\}/s;
ok( defined $capture_body, 'the capture body is readable' );
unlike( $capture_body || '', qr/S\.sound\s*=|jawnos_synth_sound/,
	'capture never changes the saved Sound choice or its select' );
like( $engine, qr/current\.state === 'suspended'[\s\S]{0,120}current\.resume\(\)/s,
	'the first key resumes a context built before the gesture' );
like( $engine, qr/function setPatch\(obj\)/, 'the patch API is unchanged' );
like( $engine, qr/function loadPreset\(name\)/, 'the preset API is unchanged' );
like( $engine, qr/function arpTick\(\)/, 'the arpeggiator still plays' );
like( $engine, qr/function seqTick\(\)/, 'the sequencer still plays' );
like( $engine, qr/function noteFromMidimessage\(e\)/, 'MIDI still plays' );
like( $engine, qr/function synthBuildKeys\(\)/, 'the 88-key roll still builds' );
like( $engine, qr/var SYNTH_FIRST = 21, SYNTH_LAST = 108/, 'the full 88-key range is unchanged' );
like( $engine, qr/function synthPopulatePresets\(\)/, 'the preset picker still fills' );
like( $engine, qr/function synthSyncSliders\(\)/, 'the knobs still follow the patch' );

# --- page init: once, and when the Studio panel arrives later -----------------
like( $engine, qr/var synthPageInited = false;/, 'page init is guarded' );
like( $engine, qr/function synthPageInit\(\) \{\s*if \(synthPageInited \|\| !\$\('#synth'\)\.length\)/s,
	'and only runs where a #synth host exists' );
like( $engine, qr/new MutationObserver\(function \(records\)/, 'a late Studio panel is watched for' );
like( $engine, qr/node\.querySelector && node\.querySelector\('#synth'\)/, 'the watcher looks for a newly inserted synth host' );
like( $engine, qr/window\.pianoInit = function \(\)/, 'pianoInit still exists for the window opener' );

# --- the computer keyboard only plays for the host that owns the last press ---
like( $engine, qr/var keyboardOwner = null;/, 'one owner is remembered' );
like( $engine, qr/function synthOwnerFor\(el\)/, 'one question names the owner of an element' );
like( $engine, qr/if \(\$el\.closest\('#studio_synth'\)\.length\) \{ return 'studio'; \}/,
	'the Studio panel is an owner' );
like( $engine, qr/\$el\.closest\('\.wind\[app="synth"\]'\)\.length/,
	'the standalone Synth window (its title bar included) is an owner' );
like( $engine, qr/\$el\.closest\('#synth'\)\.length && !\$el\.closest\('#studio'\)\.length/,
	'and the standalone Synth window is the other' );
like( $engine, qr/function keysOwned\(el\)/, 'keysOwned answers the drum map' );
like( $engine, qr/keysOn: function \(\) \{ return keyboardOn; \}/, 'keysOn reports whether Keys is on' );
like( $engine, qr/keysOwned: keysOwned,/, 'keysOwned is on the browser synth API' );
like( $engine, qr/\$\(document\)\.on\('pointerdown'/,
	'a press decides the owner' );
like( $engine, qr/keyboardOwner = synthOwnerFor\(e\.target\);/, 'the last press is the owner, or nobody' );
like( $engine, qr/if \(!synthKeysOwned\(e\)\) \{ return; \}/, 'the key handler declines when no synth host owns it' );

# --- the shared markup: standalone wrapper, inner surface, scoped style -------
like( $synth, qr/<div id="synth"><%= include 'synth_inner' %><\/div>/,
	'the standalone page is the shared surface inside #synth' );
like( $synth, qr/<%= include 'synth_style' %>/, 'plus the shared styles' );
unlike( $synth, qr/<style>/i, 'the standalone page keeps no style of its own' );

unlike( $inner, qr/<div id="synth"/, 'the inner surface has no outer #synth' );
unlike( $inner, qr/<style/i, 'and no style block' );
like( $inner, qr/id="synth_preset"/, 'it holds the preset picker' );
like( $inner, qr/id="synth_sound"/, 'the Sound list' );
like( $inner, qr/id="synth_midi"/, 'the MIDI device picker' );
like( $inner, qr/id="synth_midi_connect"/, 'the Connect button' );
like( $inner, qr/id="synth_keyboard_toggle"/, 'the Keys toggle' );
like( $inner, qr/id="synth_arp_toggle"/, 'the Arp toggle' );
like( $inner, qr/id="synth_arp_rate".*id="synth_arp_mode".*id="synth_arp_octaves"/s,
	'its rate, mode and octaves' );
like( $inner, qr/id="synth_mono_toggle"/, 'Mono' );
like( $inner, qr/id="synth_glide"/, 'with Glide' );
like( $inner, qr/id="synth_learn_param"/, 'the MIDI learn parameter' );
like( $inner, qr/id="synth_learn"/, 'the Learn button' );
like( $inner, qr/id="synth_keys"/, 'the 88-key roll host' );
like( $inner, qr/id="synth_seq"/, 'the step sequencer grid' );
is( scalar( () = $inner =~ /class="synth_knob"/g ), 10, 'all ten knobs are present' );
like( $inner, qr/In Studio, arm a channel whose input is Synth/, 'the hint makes sense in both hosts' );

like( $style, qr/#synth \{ padding: 8px;/, 'the base #synth style is kept' );
like( $style, qr/#synth \.synth_controls \{/, 'and the controls are scoped to #synth' );
like( $style, qr/#synth \.synth_seq_cell\.on \{/, 'the sequencer too' );
like( $style, qr/#synth \.piano_key\.white\.piano_key_on/, 'and the piano keys' );
unlike( $style, qr/^\s*\.synth_controls \{/m, 'no unscoped Studio-wide rule leaks out' );

done_testing();
