# tests-for: public/js/manager/studio/11_drums.js templates/studio/drums.html.ep public/js/manager/studio/03_editing.js public/js/manager/studio/14_audio_file.js t/349-studio-drum-loops.t
# covers:    Saved drum loops: the library the panel publishes and persists, the
#            save/load/delete shape, the Add drum loop rows on a loop track's
#            context menu, the offline render of a pattern at the transport
#            tempo, and the looping WAV take it places on the track.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root = repo_root();
my $drums  = read_file("$root/templates/studio/drums.html.ep");
my $code   = read_file("$root/public/js/manager/studio/11_drums.js");
my $edit   = read_file("$root/public/js/manager/studio/03_editing.js");
my $audio  = read_file("$root/public/js/manager/studio/14_audio_file.js");
my $ctrl   = read_file("$root/public/js/manager/studio/06_controls.js");

# --- the library is published ----------------------------------------------
like($drums,
	qr/window\.jawnos_studio_drum_loops\s*=\s*<%==\s*Mojo::JSON::encode_json\(eval \{ Mojo::JSON::decode_json\(\$settings->\{'drum_loops'\} \|\| '\[\]'\) \} \|\| \[\]\)\s*%>;/,
	'the panel publishes the saved drum loops');
like($drums, qr/<% use Mojo::JSON; %>/, 'the panel has the JSON codec it publishes with');
like($drums, qr/eval \{ Mojo::JSON::decode_json\(/, 'a missing or broken setting is guarded');
like($code, qr/function studioDrumsLoopLibrary\(\)/, 'the browser reads the published array');
like($code, qr/var library = window\.jawnos_studio_drum_loops;/,
	'the library is the window array, not a second copy');
like($code, qr/window\.jawnos_studio_drum_loops = library;/,
	'an absent setting becomes a real array');

# --- the footer controls ----------------------------------------------------
for my $id (qw(studio_drums_save_name studio_drums_save_loop studio_drums_loops studio_drums_load_loop studio_drums_delete_loop)) {
	like($drums, qr/id="\Q$id\E"/, "the footer has $id");
}
like($drums, qr/<input id="studio_drums_save_name" class="studio_drums_save_name" placeholder="[^"]+" hint="[^\n]*Name this drum loop[^\n]*"/,
	'the name field explains itself');
like($drums, qr/id="studio_drums_save_loop" class="studio_drums_save_loop hover" hint="[^\n]*Save the drum pattern as a loop[^\n]*"/,
	'the save button says what it does');
like($drums, qr/<select id="studio_drums_loops" class="studio_drums_loops" hint="[^\n]*Choose a drum loop[^\n]*">/,
	'the loop list explains itself');
like($drums, qr/id="studio_drums_load_loop"[^\n]*hint="[^\n]*Load the chosen drum loop[^\n]*"/,
	'the load button says what it does');
like($drums, qr/id="studio_drums_delete_loop"[^\n]*hint="[^\n]*Delete the chosen drum loop[^\n]*"/,
	'the delete button says what it does');

# --- save: name, kit, length and a deep copy of every row -------------------
like($code, qr/function studioDrumsSaveLoop\(\)/, 'a loop has one save function');
like($code, qr/var name = String\(\$\('#studio_drums_save_name'\)\.val\(\) \|\| ''\)\.trim\(\);/,
	'save reads and trims the name');
like($code, qr/if \(!name\) \{ return false; \}/, 'save rejects an empty name');
like($code, qr/steps\[v\.name\] = \(studioDrums\.steps\[v\.name\] \|\| \[\]\)\.slice\(0, studioDrums\.lengthSteps\);/,
	'each row is copied to the chart length');
like($code, qr/library\.push\(\{ name: name, kit: studioDrums\.kit, length: studioDrums\.lengthSteps, steps: steps \}\);/,
	'a saved loop carries name, kit, length and steps');
like($code, qr/studioSaveSettings\(\[\{ setting: 'drum_loops', value: JSON\.stringify\(studioDrumsLoopLibrary\(\)\) \}\]\);/,
	'the library is persisted as the drum_loops app setting');
like($code, qr/studioDrumsLoopOptions\(\);/, 'save refreshes the loop list');
like($code, qr/\$\('#studio_drums_loops'\)\.val\(String\(library\.length - 1\)\);/,
	'the loop just saved becomes the chosen one');

# --- load: steps, length, kit and a save ------------------------------------
like($code, qr/function studioDrumsLoadLoop\(\)/, 'a loop has one load function');
like($code, qr/var item = studioDrumsChosenLoop\(\);/, 'load reads the chosen loop');
like($code, qr/studioDrums\.lengthSteps = studioDrumsNormaliseLength\(item\.length\);/,
	'load restores the saved length');
like($code, qr/var row = saved\[v\.name\] \|\| \[\];/, 'load reads each saved row');
like($code, qr/studioDrums\.steps\[v\.name\] = steps;/, 'load replaces the row');
like($code, qr/var kit = studioDrumsKitName\(item\.kit\);/, 'an unknown kit falls back to Acoustic');
like($code, qr/if \(kit !== studioDrums\.kit\) \{[\s\S]{0,220}studioDrumsBuild\(studioDrums\.ctx\);[\s\S]{0,40}\}/,
	'a different kit clears the buffers and rebuilds');
like($code, qr/studioDrumsRender\(\);\s*\n\s*studioSaver\(\);/, 'load renders and saves the song');

# --- delete ----------------------------------------------------------------
like($code, qr/function studioDrumsDeleteLoop\(\)/, 'a loop has one delete function');
like($code, qr/var index = parseInt\(select\.val\(\), 10\);/, 'delete reads the chosen index');
like($code, qr/library\.splice\(index, 1\);/, 'delete removes just that loop');
like($code, qr/library\.splice\(index, 1\);\s*\n\s*studioDrumsLoopPersist\(\);\s*\n\s*studioDrumsLoopOptions\(\);/,
	'delete persists and refreshes the list');

# --- the track menu offers a loop only on a loop track ---------------------
like($edit, qr/var ch = studioCanvasChannel\(this\);/, 'the menu reads the channel');
like($edit, qr/var loopTrack = mixer\[ch\] && mixer\[ch\]\.armed && mixer\[ch\]\.armed\.state == 'loop';/,
	'the menu asks whether the track is armed to loop');
like($edit, qr/if \(!loopTrack\) \{ return; \}/,
	'an empty lane opens the browser menu unless the track loops');
like($edit, qr/function studioCanvasTime\(canvas, clientX\)/, 'an empty-lane press becomes a time');
like($edit, qr/studioLoopMenu\(ch, studioCanvasTime\(this, e\.clientX\), e\.clientX, e\.clientY\);/,
	'the loop menu opens at the clicked time');
like($edit, qr/var t = \(\(clientX - rect\.left\) \/ rect\.width\) \* duration;/,
	'the time uses the same scale as the take hit test');
like($edit, qr/return Math\.max\(0, Math\.min\(duration, t\)\);/, 'the time is clamped to the song');

# --- the menu rows ---------------------------------------------------------
like($edit, qr/function studioLoopMenuRows\(menu\)/, 'one builder makes the loop rows');
like($edit, qr/\$\('<div class="studio_menu_head"><\/div>'\)\.text\(studioLayoutText\('Add drum loop'\)\)/,
	'the section is headed Add drum loop');
like($edit, qr/class="studio_menu_row studio_drums_loop_row"/, 'a saved loop is a menu row');
like($edit, qr/\.attr\('data-loop', index\)/, 'a row remembers its library index');
like($edit, qr/studioLayoutText\('No saved loops'\)/, 'an empty library says so');
like($edit, qr/prop\('disabled', !!disabled\)|class="studio_menu_row" disabled/,
	'the empty row is disabled');
like($edit, qr/var loopTrack = mixer\[hit\.ch\] && mixer\[hit\.ch\]\.armed && mixer\[hit\.ch\]\.armed\.state == 'loop';[\s\S]{0,80}?studioLoopMenuRows\(menu\);/, 'the clip menu carries the loop section on a loop track');
for my $command (qw(split cut copy paste)) {
	like($edit, qr/studioClipMenuRow\(menu, '\Q$command\E'/, "a hit take keeps $command");
}
like($edit, qr/var loop = row\.attr\('data-loop'\);/, 'a loop row is told apart from a clip command');
like($edit, qr/var item = studioDrumsLoopLibrary\(\)\[parseInt\(loop, 10\)\];/,
	'the clicked row resolves to the library item');
like($edit, qr/studioDrumsInsertLoop\(hit\.ch, hit\.t, item\);/, 'the row inserts the loop at the clicked time');

# --- the offline render ----------------------------------------------------
like($code, qr/function studioDrumsInsertLoop\(ch, at, item\)/, 'one function inserts a saved loop');
like($code, qr/var stepDur = 60 \/ bpm \/ 4;/, 'a step is a sixteenth at the transport tempo');
like($code, qr/var duration = length \* stepDur;/, 'the render lasts the saved number of steps');
like($code, qr/studioDrumsOfflineBuffers\(kit, rate\)\.then\(function \(kitBuffers\)/,
	'the render waits for the kit buffers');
like($code, qr/if \(kit === studioDrums\.kit\)/, 'the live kit is preferred when it is the same kit');
like($code, qr/if \(studioDrums\.buildState !== 'ready' \|\| studioDrums\.builtKit !== kit\)/,
	'a missing live build is waited for');
like($code, qr/studioDrumsVoiceSpec\(kit, v\.name\)/, 'a different kit uses the same voice specs');
like($code, qr/studioDrumsRenderVoice\(off, kit, v\.name\)/, 'a different kit renders into a temporary context');
like($code, qr/new Ctor\(1, Math\.ceil\(rate \* \(spec\.length \|\| 0\.6\)\), rate\)/,
	'the temporary kit is rendered at the transport sample rate');
like($code, qr/new Ctor\(2, Math\.ceil\(rate \* duration\), rate\)/,
	'the pattern renders in a stereo offline context');
like($code, qr/src\.buffer = buffer;/, 'a step reads a rendered kit buffer');
like($code, qr/gain\.gain\.value = Math\.min\(1, value \/ 100\);/, 'a step plays at value/100');
like($code, qr/src\.start\(i \* stepDur\);/, 'a step is placed on the offline clock');

# --- the WAV take ----------------------------------------------------------
like($code, qr/function studioDrumsLoopTake\(ch, at, buffer\)/, 'the rendered buffer becomes a take');
like($code, qr/var wav = studioBufferToWav\(buffer\);/, 'the take carries a WAV blob');
like($audio, qr/function studioBufferToWav\(buffer\)/, 'the shared WAV encoder exists');
like($audio, qr/new Blob\(\[view\], \{ type: 'audio\/wav' \}\)/, 'the encoder names a WAV blob');
like($code, qr/uuid: null,/, 'the take has no server uuid yet');
like($code, qr/startTime: at,/, 'the take starts at the clicked time');
like($code, qr/offset: 0,/, 'the take starts at its own beginning');
like($code, qr/duration: buffer\.duration,/, 'the take lasts the rendered buffer');
like($code, qr/status: 'stop',/, 'the take is not recording');
like($code, qr/buffer: buffer,/, 'the take keeps its decoded buffer');
like($code, qr/loop: true,/, 'the take repeats');
like($code, qr/encoding: 'audio\/wav',/, 'the take is a WAV');
like($code, qr/data: wav,/, 'the take carries the blob for upload');
like($code, qr/src: URL\.createObjectURL\(wav\)/, 'the take points at its own URL');
like($code, qr/var peaks = new Float32Array\(600\);/, 'the waveform is 600 buckets');
like($code, qr/var data = buffer\.getChannelData\(0\);/, 'the waveform reads channel 0');
like($code, qr/take\.waveform = peaks;/, 'the drawn take carries its waveform');
like($code, qr/m\.media\.out\.push\(take\);/, 'the take joins the channel');
like($code, qr/studioReindexTakes\(ch\);/, 'the channel is reindexed');
like($code, qr/mixer\['time'\]\['duration'\] = Math\.max\(mixer\['time'\]\['duration'\] \|\| 0, take\.startTime \+ take\.duration\);/,
	'the song grows to hold the take');
like($code, qr/studioDrawChannel\(ch\);/, 'the lane is redrawn');
like($code, qr/studioSaver\(\);/, 'the song is saved');
like($code, qr/studioTakesChanged\(\);/, 'a running transport picks the new take up');

# --- the upload keeps the extension ----------------------------------------
like($ctrl, qr/var ext = \(take\.data\.type && take\.data\.type\.indexOf\('wav'\) !== -1\) \? '\.wav' : '\.webm';/,
	'a WAV take uploads as .wav, not .webm');
like($ctrl, qr/formData\.append\('blob', take\.data, app \+ '_' \+ now \+ '_' \+ i \+ '_' \+ ir \+ ext\);/,
	'the upload names the blob with that extension');

done_testing();
