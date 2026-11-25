# tests-for: public/js/manager/studio/01_transport.js public/js/manager/studio/03_editing.js public/js/manager/studio/04_knobs.js public/js/manager/studio/05_inputs.js public/js/manager/studio/06_controls.js public/js/manager/studio/11_drums.js t/435-studio-synth-clips.t
# covers:    Synth note clips in Studio: the capture of the notes a synth take
#            played, the browser render cache and its re-render, the take fields
#            saved and loaded, restretching on a tempo change, the engine's note
#            clip plan and its wire field, the note menu, split/copy/paste/bounce,
#            the saved synth loop library and its track-menu insert, and the
#            drum key guard that hands the keys back to the synth.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root    = repo_root();
my $trans   = read_file("$root/public/js/manager/studio/01_transport.js");
my $editing = read_file("$root/public/js/manager/studio/03_editing.js");
my $knobs   = read_file("$root/public/js/manager/studio/04_knobs.js");
my $inputs  = read_file("$root/public/js/manager/studio/05_inputs.js");
my $ctrl    = read_file("$root/public/js/manager/studio/06_controls.js");
my $drums   = read_file("$root/public/js/manager/studio/11_drums.js");
my $notes   = read_file("$root/public/js/manager/studio/19_notes.js");

# --- capture: start ---------------------------------------------------------
like($inputs, qr/function studioSynthNoteCaptureStart\(ch, take\)/, 'a synth take starts one capture');
like($inputs, qr/var plug = \(typeof studioChannelInput === 'function'\) \? studioChannelInput\(ch\) : null;/,
	'the capture asks the channel its input');
like($inputs, qr/return \(plug && plug\['app'\] === 'synth'\) \? plug : null;/,
	'only a Synth input channel is captured');
like($inputs, qr/if \(!synth \|\| typeof synth\.onnote !== 'function'\) \{ return null; \}/,
	'a synth without the tap is left alone');
like($inputs, qr/capture\.off = synth\.onnote\(function \(event\)/, 'the capture subscribes to the note tap');
like($inputs, qr/capture\.events\.push\(\{ on: !!event\.on, note: note, velocity: velocity, time: time \}\);/,
	'every edge is stored raw');
like($inputs, qr/capture\.pairs\.push\(\{ note: note, t: started\.t, d: Math\.max\(0\.01, time - started\.t\), v: started\.v \}\);/,
	'an off pairs with the oldest open note of that pitch');
like($inputs, qr/capture\.anchor = seg\.ctx0 \+ \(punch - seg\.pos0\);/,
	'the punch is the capture anchor, not the latency-shifted audio start');
like($inputs, qr/ctx === studioAudio\.ctx && seg/,
	'the studio segment clock is used only on the synth\'s own context');
like($inputs, qr/take\.synthCapture = capture;/, 'the take remembers its capture');
like($inputs, qr/if \(typeof synth\.capture === 'function'\) \{ try \{ synth\.capture\(true\); \} catch \(e\) \{\} \}/,
	'the browser voices are asked to keep recording while the engine plays');
like($inputs, qr/if \(synth && typeof synth\.capture === 'function'\) \{ try \{ synth\.capture\(false\); \} catch \(e\) \{\} \}/,
	'and they are handed back at the stop');
like($inputs, qr/punchTime: from /, 'the take records its punch point');
like($inputs, qr/studioSynthNoteCaptureStart\(ch, take\);/, 'starting a take starts the capture');
like($inputs, qr/studioSynthNoteCaptureStop\(ch, take\);/, 'stopping a take stops the capture');
like($inputs, qr/if \(take\.note_clip\) \{ return; \}/,
	'the MediaRecorder blob never replaces a converted note clip');

# --- capture: stop and quantize --------------------------------------------
like($inputs, qr/if \(typeof capture\.off === 'function'\) \{ try \{ capture\.off\(\); \} catch \(e\) \{\} \}/,
	'stop unsubscribes the tap');
like($inputs, qr/Object\.keys\(capture\.open\)\.forEach\(function \(note\) \{/,
	'a note still held at the stop is closed');
like($inputs, qr/function studioSynthCaptureNotes\(capture, beat, beats, quantize\)/,
	'one function shapes the pairs into notes');
like($inputs, qr/t = Math\.round\(t \* 16\) \/ 16;/, 'a loop quantizes its starts to a sixteenth');
like($inputs, qr/d = Math\.max\(1 \/ 16, Math\.round\(d \* 16\) \/ 16\);/, 'and its lengths too');
like($inputs, qr/if \(t \+ d > beats\) \{ d = beats - t; \}/, 'a loop note is clipped to the loop length');
like($inputs, qr/beats = Math\.max\(1 \/ 16, Math\.round\(\(duration \/ beat\) \* 16\) \/ 16\);/,
	'the loop length becomes whole sixteenths of beats');
like($inputs, qr/notes = studioSynthCaptureNotes\(capture, beat, beats, true\);/,
	'a loop take is quantized');
like($inputs, qr/take\.notes = studioSynthCaptureNotes\(capture, beat, beats, false\);/,
	'a real take keeps its raw timing');
like($inputs, qr/beats = Math\.round\(\(duration \/ beat\) \* 10000\) \/ 10000;/,
	'a real take derives beats from its duration');
like($inputs, qr/take\.note_clip = 0;/, 'a real take stays ordinary audio');

# --- the loop take becomes a note clip --------------------------------------
like($inputs, qr/function studioSynthLoopTake\(ch, take, notes, patch, beats\)/,
	'one function turns a recorded loop into a note clip');
like($inputs, qr/take\.notes = notes \|\| \[\];/, 'the notes are written onto the take');
like($inputs, qr/take\.patch = patch \|\| null;/, 'the patch is written too');
like($inputs, qr/take\.beats = Number\(beats\) \|\| 0;/, 'the length is written in beats');
like($inputs, qr/take\.note_clip = 1;/, 'the take becomes a note clip');
like($inputs, qr/take\.clip_id = \(typeof studioNoteClipId === 'function'\) \? studioNoteClipId\(\) : null;/,
	'it gets a stable engine id');
like($inputs, qr/if \(take\.punchTime !== undefined && take\.punchTime !== null\) \{ take\.startTime = take\.punchTime; \}/,
	'it is placed on the punch point');
like($inputs, qr/take\.duration = studioNoteClipSeconds\(take\) \|\| take\.duration \|\| 0;/,
	'its length comes from its beats at the song tempo');
like($inputs, qr/studioNoteClipLoad\(take\)\.then\(function \(\) \{/, 'it is re-rendered and applied');

# --- the browser render cache ----------------------------------------------
like($trans, qr/function studioNoteClipBeats\(take\)/, 'one function reads the clip length in beats');
like($trans, qr/function studioNoteClipSeconds\(take\)/, 'one converts beats to seconds at the song tempo');
like($trans, qr/return beats \* 60 \/ bpm;/, 'beats * 60 / bpm is the rule');
like($trans, qr/function studioNoteClipId\(\)/, 'one function mints a clip id');
like($trans, qr/return 'synth_' \+ Date\.now\(\)/, 'the id names the synth and the moment');
like($trans, qr/function studioNoteClipRender\(take\)/, 'one function renders a clip');
like($trans, qr/if \(!take \|\| !synth \|\| typeof synth\.render !== 'function'\) \{/,
	'a missing renderer is refused');
like($trans, qr/return synth\.render\(\{/, 'the render goes through the browser synth');
like($trans, qr/notes: Array\.isArray\(take\.notes\) \? take\.notes : \[\],/, 'the notes ride the render');
like($trans, qr/patch: take\.patch \|\| null,/, 'the patch rides the render');
like($trans, qr/beats: studioNoteClipBeats\(take\),/, 'the beats ride the render');
like($trans, qr/rate: rate/, 'the sample rate rides the render');

like($trans, qr/function studioNoteClipApply\(take, buffer\)/, 'one function puts the cache on the take');
like($trans, qr/if \(take\.punchTime !== undefined && take\.punchTime !== null\) \{ take\.startTime = take\.punchTime; \}/,
	"a real take's first note edit moves the clip to the punch its notes were played on");
like($trans, qr/take\.data = studioBufferToWav\(buffer\);/, 'the cache is a WAV blob');
like($trans, qr/take\.src = URL\.createObjectURL\(take\.data\);/, 'the blob has a URL');
like($trans, qr/take\.encoding = 'audio\/wav';/, 'the take is a WAV');
like($trans, qr/take\.duration = studioNoteClipSeconds\(take\) \|\| buffer\.duration;/, 'its length is the musical one');
like($trans, qr/var peaks = new Float32Array\(600\);/, 'the waveform is 600 buckets');
like($trans, qr/studioWaveformCache\[take\.src\] = take\.waveform;/, 'the waveform is cached by URL');
like($trans, qr/take\.note_clip = 1;/, 'the take is marked a note clip');
like($trans, qr/take\.uuid = null;/, 'the cache has no server uuid');
like($trans, qr/if \(!take\.clip_id\) \{ take\.clip_id = studioNoteClipId\(\); \}/, 'the clip id is set once');
like($trans, qr/delete take\.engine_file;/, 'a stale engine file is dropped');
like($trans, qr/delete take\.engine_key;/, 'a stale engine key is dropped');
like($trans, qr/delete take\.engine_staging;/, 'a stale staging is dropped');
like($trans, qr/delete take\.engine_failed;/, 'a stale failure is dropped');
like($trans, qr/if \(take\.track\) \{ take\.track\.src = take\.src; \}/, 'the element plays the cache');
like($trans, qr/studioTakesChanged\(\);/, 'a running transport hears the new cache');

like($trans, qr/function studioNoteClipRerender\(ch, take\)/, 'one function re-renders after an edit');
like($trans, qr/var gen = \(take\.note_render_gen = \(take\.note_render_gen \|\| 0\) \+ 1\);/, 'a generation guards the render');
like($trans, qr/if \(take\.note_render_gen !== gen\) \{ resolve\(take\); return; \}/,
	'a stale render never lands');
like($trans, qr/\}, 140\);/, 'commits are debounced');
like($trans, qr/studioSaver\(\);/, 'the song is saved after a re-render');
like($trans, qr/studioDrawChannel\(ch\);/, 'the lane is redrawn after a re-render');
like($trans, qr/window\.studioNoteClipRerender = studioNoteClipRerender;/, 'the editor reaches it on window');

like($trans, qr/function studioNoteClipLoad\(take\)/, 'one function rebuilds a loaded clip');
like($trans, qr/el\.className = 'studio_video';/, 'a loaded clip can make its element');
like($trans, qr/take\.duration = studioNoteClipSeconds\(take\) \|\| take\.duration \|\| 0;/, 'it renders at the current tempo');
like($trans, qr/studioNoteClipRender\(take\)\.then\(function \(buffer\) \{/, 'it renders then applies');

# --- save and load ----------------------------------------------------------
like($knobs, qr/note_clip: take\.note_clip \? 1 : 0,/, 'the take saves its note_clip flag');
like($knobs, qr/notes: take\.notes \|\| null,/, 'the take saves its notes');
like($knobs, qr/patch: take\.patch \|\| null,/, 'the take saves its patch');
like($knobs, qr/beats: take\.beats \|\| 0,/, 'the take saves its beats');
like($knobs, qr/clip_id: take\.clip_id \|\| null/, 'the take saves its clip id');
like($knobs, qr/uuid: take\.note_clip \? null : take\.uuid,/, 'a note clip writes no uuid');
like($knobs, qr/src: take\.note_clip \? null : take\.src,/, 'and no stale blob URL');

like($ctrl, qr/if \(take && take\.data && take\.data\.size && !take\.uuid && !take\.note_clip\) \{/,
	'a note clip is never uploaded');
like($ctrl, qr/note_clip: vr\['note_clip'\] \? 1 : 0,/, 'load restores the note_clip flag');
like($ctrl, qr/notes: Array\.isArray\(vr\['notes'\]\) \? vr\['notes'\] : null,/, 'load restores the notes');
like($ctrl, qr/patch: vr\['patch'\] \|\| null,/, 'load restores the patch');
like($ctrl, qr/beats: studioKnobNumber\(vr\['beats'\], 0\) \|\| 0,/, 'load restores the stored beats');
like($ctrl, qr/clip_id: vr\['clip_id'\] \|\| null/, 'load restores the clip id');
like($ctrl, qr/studioNoteClipLoad\(loaded\);/, 'a loaded note clip is rendered, not fetched');
like($ctrl, qr/else \{\s*\n\s*studioTakeRequestBuffer\(loaded\);/, 'an ordinary take still fetches its file');

# --- restretch --------------------------------------------------------------
like($ctrl, qr/function studioNoteClipsRestretch\(\)/, 'one function restretches every note clip');
like($ctrl, qr/if \(!take \|\| !take\.note_clip\) \{ return; \}/, 'only note clips are restretched');
like($ctrl, qr/take\.duration = studioNoteClipSeconds\(take\);/, 'a note clip length follows the tempo');
like($ctrl, qr/studioNoteClipRerender\(ch, take\);/, 'each restretched clip re-renders its cache');
like($ctrl, qr/if \(typeof window\.studioNotesRefresh === 'function'\) \{ window\.studioNotesRefresh\(\); \}/,
	'the editor is told the tempo changed');
like($ctrl, qr/function studioTakesDuration\(\)/, 'the song end is recomputed from its takes');
like($ctrl, qr/if \(found\) \{ mixer\['time'\]\['duration'\] = studioTakesDuration\(\); \}/,
	'the transport length follows the restretch');
like($ctrl, qr/studioNoteClipsRestretch\(\);\s*\n\s*studioEngineTempoChanged\(\);/, 'the BPM change restretches and retunes');

# --- the engine tempo start -------------------------------------------------
like($ctrl, qr/function studioEngineTempoChanged\(\)/, 'one function tells the engine about a tempo change');
like($ctrl, qr/if \(!mixer\['time'\] \|\| !mixer\['time'\]\['engine_transport'\]\) \{ return; \}/,
	'only an engine-owned transport is retuned');
like($ctrl, qr/var fields = studioEngineTransportFields\(pos\);/, 'the current tempo fields ride the start');
like($ctrl, qr/fields\.synth_clips_json = JSON\.stringify\(studioEngineSynthClipPlan\(\)\);/, 'the note plan rides the start');
like($ctrl, qr/studioEngineTransportPost\('start', fields, function \(data\) \{/, 'the post is a start, not a clip update');

# --- the engine plan --------------------------------------------------------
like($trans, qr/function studioEngineSynthClipPlan\(\)/, 'the engine gets a note clip plan');
like($trans, qr/if \(!take \|\| !take\.note_clip\) \{ return; \}/, 'only note clips join the plan');
like($trans, qr/patch: take\.patch \|\| \{\},/, 'each clip carries its patch');
like($trans, qr/notes: take\.notes,/, 'each clip carries its notes');
like($trans, qr/start: Math\.max\(0, take\.startTime \|\| 0\),/, 'each clip carries its timeline start');
like($trans, qr/beats: beats,/, 'each clip carries its length in beats');
like($trans, qr/loop: take\.loop \? 1 : 0,/, 'each clip carries its loop flag');
like($trans, qr/channel: Number\(ch\),/, 'each clip names its channel');
like($trans, qr/gain: gain,/, 'each clip folds the fader and mute/solo');
like($trans, qr/pan: pan,/, 'each clip carries the strip pan');
like($trans, qr/inserts: inserts/, 'each clip carries its enabled Out inserts');
like($trans, qr/var clip = studioEngineAppRouting\('drums'\)|inserts\.push\(studioEffectKind\(ins\.name\)\);/, 'mirrors the app routing pedals');
like($trans, qr/return \{ clips: clips \};/, 'the plan is the wire shape');
# a note clip is not an audio file for the engine to stage
like($trans, qr/if \(take\.note_clip\) \{ return; \}\s*\n\s*if \(take\.encoding && take\.encoding\.indexOf\('video'\) !== -1\)/,
	'the audio clip plan skips note clips');
my @synth_json = ($trans =~ /fields\.synth_clips_json = JSON\.stringify\(studioEngineSynthClipPlan\(\)\);/g);
is(scalar(@synth_json), 2, 'synth_clips_json rides the first start and every update');

# --- clip editing -----------------------------------------------------------
like($editing, qr/if \(hit\.take\.note_clip \|\| hit\.take\.notes\) \{/, 'the clip menu offers Notes for a note-backed clip');
like($editing, qr/studioClipMenuRow\(menu, 'notes', studioLayoutText\('Notes'\), false\);/, 'the Notes row is a clip command');
like($editing, qr/if \(typeof window\.studioNotesOpen === 'function'\) \{ window\.studioNotesOpen\(hit\.ch, hit\.take\); \}/,
	'the row opens the note editor on this take');

like($editing, qr/note_clip: take\.note_clip \? 1 : 0,/, 'a copy carries the note_clip flag');
like($editing, qr/notes: take\.notes \? JSON\.parse\(JSON\.stringify\(take\.notes\)\) : null,/, 'a copy carries the notes');
like($editing, qr/patch: take\.patch \? JSON\.parse\(JSON\.stringify\(take\.patch\)\) : null,/, 'a copy carries the patch');
like($editing, qr/beats: take\.beats \|\| 0/, 'a copy carries the beats');
like($editing, qr/pasted\.clip_id = studioNoteClipId\(\);/, 'a pasted note clip gets a fresh id');
like($editing, qr/if \(pasted\.note_clip\) \{ studioNoteClipRerender\(ch, pasted\); \}/, 'a pasted note clip is rendered');

like($editing, qr/function studioNoteSplit\(notes, at\)/, 'one function cuts a note list');
like($editing, qr/left\.push\(copy\(t, at - t\)\);/, 'a spanning note keeps its attack on the left');
like($editing, qr/right\.push\(copy\(0, t \+ d - at\)\);/, 'and its remainder on the right');
like($editing, qr/var noteSplit = !!take\.note_clip;/, 'a split asks whether the clip is notes');
like($editing, qr/right\.clip_id = studioNoteClipId\(\);/, 'the right half gets its own engine id');
like($editing, qr/take\.clip_id = studioNoteClipId\(\);/, 'and so does the left half');
like($editing, qr/take\.beats = splitBeat;/, 'the left half is as long as its share of beats');
like($editing, qr/right\.beats = Math\.max\(0, studioNoteClipBeats\(take\) - splitBeat\);/, 'the right half keeps the rest');
like($editing, qr/studioNoteClipRerender\(ch, take\);\s*\n\s*studioNoteClipRerender\(ch, right\);/, 'both halves re-render');
like($editing, qr/if \(!noteSplit && !take\.uuid\) \{ right\.data = take\.data; \}/, 'a real take still splits as audio');

like($editing, qr/delete hit\.take\.note_clip;\s*\n\s*delete hit\.take\.notes;/, 'a bounce clears the notes');

# --- the synth loop library -------------------------------------------------
like($editing, qr/function studioSynthLoopLibrary\(\)/, 'the browser reads the published synth loops');
like($editing, qr/var library = window\.jawnos_studio_synth_loops;/, 'the library is the window array');
like($editing, qr/window\.jawnos_studio_synth_loops = library;/, 'an absent setting becomes a real array');
like($editing, qr/studioSaveSettings\(\[\{ setting: 'synth_loops', value: JSON\.stringify\(studioSynthLoopLibrary\(\)\) \}\]\);/,
	'the library is persisted as synth_loops');
like($editing, qr/function studioSynthSaveLoop\(\)/, 'a loop has one save function');
like($editing, qr/var seq = synth\.seq\.get\(\);/, 'save captures the sequencer grid');
like($editing, qr/function studioSynthSeqNotes\(seq, bpm\)/, 'the grid is laid out in beats');
like($editing, qr/n: root \+ row,/, 'a cell sounds at the row above the root');
like($editing, qr/t: \(step \* stepSeconds\) \/ beat,/, 'a step is its own time in beats');
like($editing, qr/d: gateSeconds \/ beat,/, 'the gate is 0.6 of a step in beats');
like($editing, qr/beats: \(steps \* stepSeconds\) \/ beat/, 'the clip length is steps/rate seconds in beats');
like($editing, qr/library\.push\(\{/, 'the saved loop is a library entry');
like($editing, qr/name: name,\s*\n\s*patch: \(typeof synth\.getPatch === 'function'\) \? synth\.getPatch\(\) : null,/,
	'a loop carries its name and patch');
like($editing, qr/notes: grid\.notes,\s*\n\s*beats: grid\.beats,\s*\n\s*seq: seq/, 'and its notes, beats and grid');
like($editing, qr/function studioSynthLoadLoop\(\)/, 'a loop has one load function');
like($editing, qr/synth\.seq\.set\(\{ rate: seq\.rate, steps: seq\.steps, root: seq\.root \}\);/, 'load restores the grid settings');
like($editing, qr/synth\.seq\.setCells\(seq\.cells \|\| \{\}\);/, 'load restores the cells');
like($editing, qr/\$\(document\)\.trigger\('jawnos_synth_panel'\);/, 'load asks the panel to rebuild the grid');
like($editing, qr/function studioSynthDeleteLoop\(\)/, 'a loop has one delete function');
like($editing, qr/library\.splice\(index, 1\);/, 'delete removes just that loop');
like($editing, qr/'#studio_synth_save_loop'/, 'the save control is bound');
like($editing, qr/'#studio_synth_load_loop'/, 'the load control is bound');
like($editing, qr/'#studio_synth_delete_loop'/, 'the delete control is bound');
like($editing, qr/#studio_synth_save_name/, 'save reads the name field');
like($editing, qr/#studio_synth_loops/, 'the list is read by the same id');

like($editing, qr/function studioSynthLoopMenuRows\(menu\)/, 'one builder makes the synth loop rows');
like($editing, qr/studioLayoutText\('Add synth loop'\)/, 'the section is headed Add synth loop');
like($editing, qr/\.attr\('data-synth-loop', index\)/, 'a row remembers its library index');
like($editing, qr/var synthItem = studioSynthLoopLibrary\(\)\[parseInt\(synthLoop, 10\)\];/, 'the clicked row resolves');
like($editing, qr/studioSynthInsertLoop\(hit\.ch, hit\.t, synthItem\);/, 'the row inserts at the clicked time');
like($editing, qr/function studioSynthInsertLoop\(ch, at, item\)/, 'one function inserts a saved synth loop');
like($editing, qr/note_clip: 1,/, 'the inserted take is a note clip');
like($editing, qr/loop: true,/, 'the inserted loop repeats');
like($editing, qr/clip_id: studioNoteClipId\(\),/, 'it gets its own engine id');
like($editing, qr/studioNoteClipLoad\(take\)\.then\(function \(\) \{ studioDrawChannel\(ch\); \}\);/, 'it is rendered');

like($editing, qr/\$\(document\)\.on\('jawnos_synth_panel', function \(\) \{ studioSynthLoopOptions\(\); \}\);/,
	'the list fills when the panel rebuilds its grid');

like($ctrl, qr/if \(take\.synthCapture\) \{/, 'closing a window mid-take closes its note capture');
like($ctrl, qr/take\.synthCapture\.off\(\);/, 'the capture unsubscribes on teardown');

# --- the drum key guard -----------------------------------------------------
like($drums, qr/typeof jawnosSynth !== 'undefined' && typeof jawnosSynth\.keysOn === 'function' && jawnosSynth\.keysOn\(\)/,
	'the drum map asks whether the synth keys are on');
like($drums, qr/&& jawnosSynth\.keysOwned\(e\.target\)\) \{ return; \}/,
	'and declines the key the synth owns');

# --- the editor is the one that calls the rerender --------------------------
like($notes, qr/window\.studioNoteClipRerender\(pendingCh, pendingTake\);/, 'the note editor calls the hook we publish');

done_testing();
