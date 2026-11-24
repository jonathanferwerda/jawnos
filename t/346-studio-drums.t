# tests-for: templates/studio/drums.html.ep templates/studio/markup.html.ep templates/studio/style.html.ep public/js/manager/studio.js public/js/manager/studio/04_knobs.js public/js/manager/studio/05_inputs.js public/js/manager/studio/06_controls.js public/js/manager/studio/07_layout.js public/js/manager/studio/11_drums.js perl/gb/05_abilities_and_studio.pl perl/help/topics_apps.pl t/346-studio-drums.t
# covers:    The Studio drum machine: the eight-voice table and the ten kits, a
#            chart of four to 128 sixteenths (a bar is sixteen, a beat four),
#            the transport/lookahead scheduler, the computer-key map with its
#            typing guard, Web MIDI, the song's admin.drums state, the saved
#            loop library, and the routing into the master rack and the
#            browser take.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root   = repo_root();
my $markup = read_file("$root/templates/studio/markup.html.ep");
my $drums  = read_file("$root/templates/studio/drums.html.ep");
my $style  = read_file("$root/templates/studio/style.html.ep");
my $index  = read_file("$root/public/js/manager/studio.js");
my $knobs  = read_file("$root/public/js/manager/studio/04_knobs.js");
my $inputs = read_file("$root/public/js/manager/studio/05_inputs.js");
my $ctrl   = read_file("$root/public/js/manager/studio/06_controls.js");
my $layout = read_file("$root/public/js/manager/studio/07_layout.js");
my $code   = read_file("$root/public/js/manager/studio/11_drums.js");
my $studio = read_file("$root/perl/gb/05_abilities_and_studio.pl");
my $help   = read_file("$root/perl/help/topics_apps.pl");

# --- the voice table --------------------------------------------------------
my ($table) = $studio =~ /drums\s*=>\s*\[(.*?)\n\t\],/s;
ok(defined $table, 'the studio data carries a drum voice table');
$table = '' unless defined $table;
my @voices = $table =~ /name\s*=>\s*'([^']+)'/g;
is(scalar(@voices), 8, 'there are eight drum voices');
is_deeply(\@voices,
	[qw(kick snare closed_hat open_hat clap low_tom high_tom rim)],
	'the voices are the eight the panel names');
for my $label ('Kick', 'Snare', 'Closed Hat', 'Open Hat', 'Clap', 'Low Tom', 'High Tom', 'Rim') {
	like($table, qr/label\s*=>\s*'\Q$label\E'/, "the table labels $label");
}
like($table, qr/\{ name => 'kick',[\s\S]*?key => 'a',[\s\S]*?note => 36/,
	'each voice carries a computer key and a MIDI note');
my @keys = $table =~ /key\s*=>\s*'([^']+)'/g;
is(scalar(@keys), 8, 'every voice starts with its own key');
is(scalar(keys %{{ map { $_ => 1 } @keys }}), 8, 'the starting keys are distinct');
my @notes = $table =~ /note\s*=>\s*(\d+)/g;
is(scalar(@notes), 8, 'every voice has a MIDI note');
is(scalar(keys %{{ map { $_ => 1 } @notes }}), 8, 'the MIDI notes are distinct');

# --- the kit table ----------------------------------------------------------
my ($kits) = $studio =~ /drum_kits\s*=>\s*\[(.*?)\n\t\],/s;
ok(defined $kits, 'the studio data carries a drum kit table');
$kits = '' unless defined $kits;
my @kit_names = $kits =~ /name\s*=>\s*'([^']+)'/g;
is_deeply(\@kit_names,
	[qw(acoustic electronic techno beats latin pearl tama gretsch 808 metal)],
	'the ten kits are the ones the panel offers, in order');
my @kit_labels = $kits =~ /label\s*=>\s*'([^']+)'/g;
is_deeply(\@kit_labels,
	[qw(Acoustic Electronic Techno Beats Latin Pearl Tama Gretsch 808 Metal)],
	'every kit has the label people read');
like($studio, qr/# The drum kits\. `name` is the wire name saved in the song/,
	'the table says the name is the wire name and the label is what people read');

# --- the panel is included once and is data-driven --------------------------
my @includes = $markup =~ /include 'studio\/drums'/g;
is(scalar(@includes), 1, 'the markup includes the drum panel once');
like($markup, qr/id="studio_drums"|include 'studio\/drums'/, 'the drum panel is a real include');
like($drums, qr/window\.jawnos_studio_drums/, 'the panel publishes its voice table');
like($drums, qr/window\.jawnos_studio_drum_kits/, 'the panel publishes its kit table');
like($drums, qr/id="studio_drums_kit"/, 'the panel has a Kit list');
like($drums, qr/id="studio_drums_kit"[^\n]*Choose a drum kit/, 'the Kit list explains itself');
like($drums, qr/<select id="studio_drums_kit" aria-label=/, 'the Kit list is named for a screen reader');
like($drums, qr/foreach my \$k \( \@\{\$gb::studio->\{'drum_kits'\}\} \)/,
	'the Kit options come from the table, not hard-coded markup');
like($drums, qr/<option value="<%=\s*\$k->\{'name'\}\s*%>"><%=\s*&subs::ui\(\$k->\{'label'\}\)\s*%><\/option>/,
	'a kit option carries its wire name and its label');
like($drums, qr/studio_drums_loop_label[\s\S]*studio_drums_kit_label/s,
	'the Kit list sits beside Loop in the panel bar');
like($drums, qr/foreach my \$v \( \@\{\$gb::studio->\{'drums'\}\} \)/,
	'the rows come from the table, not hard-coded markup');
my @steps = $drums =~ /for my \$step \(0 \.\. 127\)/g;
is(scalar(@steps), 2, 'the head and every row can hold up to 128 steps');
like($drums, qr/class="studio_drums_count" data-step="<%=\s*\$step\s*%>"/,
	'a step count carries its index so the length can hide it');
like($drums, qr/data-step="<%=\s*\$step\s*%>"/, 'a step carries its index');
like($drums, qr/hint="<%=\s*&subs::ui\('Click to place a beat, hold Shift for an accent, right-click to set its velocity'\)\s*%>"/,
	'a step says what a click, Shift-click and right-click do');
like($drums, qr/class="studio_drums_row" data-voice="<%=\s*\$v->\{'name'\}\s*%>"/,
	'a row is addressed by its voice name');
like($drums, qr/class="studio_drums_lamp[^"]*"[^>]*data-voice/, 'a voice carries a mute lamp');
like($drums, qr/class="studio_drums_key[^"]*"[^>]*data-voice/, 'a voice carries its key button');
like($drums, qr/id="studio_drums_loop"/, 'the panel has its own Loop switch');
like($drums, qr/id="studio_drums_clear"/, 'the panel can clear the chart');
like($drums, qr/id="studio_drums_key_state"/, 'the panel says whether the keys are live');
like($drums, qr/id="studio_drums_midi"/, 'the panel offers MIDI');
like($drums, qr/id="studio_drums_midi_input"/, 'the panel offers a MIDI input');
like($drums, qr/The browser take records the drums; the engine take does not yet/,
	'the panel states the engine take limitation');

# --- the scheduler: transport, tempo, lookahead ----------------------------
like($code, qr/function studioDrumsTransport\(on\)/, 'the transport starts and stops the chart');
like($ctrl, qr/studioDrumsTransport\(true\)/, 'Play and Record start the chart');
like($ctrl, qr/studioDrumsTransport\(false\)/, 'Stop stops it');
like($code, qr/setInterval\(studioDrumsSchedule, 25\)/, 'the scheduler runs on a 25ms timer');
like($code, qr/studioDrums\.nextTime < now \+ 0\.1/, 'it schedules 100ms ahead');
like($code, qr/var stepDur = 60 \/ bpm \/ 4;/, 'a step is a sixteenth at the transport tempo');
like($code, qr/studioKnobNumber\(mixer\['time'\]\['bpm'\], 120\)/, 'the tempo comes from the transport');
like($code, qr/if \(studioDrums\.step === 0 && !studioDrums\.loop\)/,
	'a chart without Loop plays once');
like($code, qr/studioDrums\.step = \(studioDrums\.step \+ 1\) % steps/,
	'the chart wraps after its length, not a fixed sixteen');
like($code, qr/var steps = studioDrums\.lengthSteps \|\| 16;/,
	'the scheduler reads the chart length');
like($code, qr/when !==|studioDrumsPlayRow\(studioDrums\.step, studioDrums\.nextTime\)/,
	'each step is placed on the audio clock, not a note per timer tick');
like($code, qr/studioDrumsHighlightStep/, 'the panel shows the sounding column');

# --- voices are built once, not per step -----------------------------------
like($code, qr/OfflineAudioContext|webkitOfflineAudioContext/, 'the one-shots use an offline context');
like($code, qr/startRendering\(\)/, 'the buffers are rendered once');
like($code, qr/studioDrumsNoiseBuffer/, 'noise is a generated buffer');
for my $voice (@voices) {
	like($code, qr/case '\Q$voice\E':/, "the synth has a $voice voice");
}
my ($play) = $code =~ /function studioDrumsPlay\(voice, when, velocity\) \{(.*?)\n\}/s;
ok(defined $play, 'the play path is found');
$play = '' unless defined $play;
unlike($play, qr/createBuffer\(|createOscillator\(|createBiquadFilter\(/,
	'a step allocates no buffer, oscillator or filter');
like($play, qr/createBufferSource\(\)/, 'a step reuses a rendered buffer');
like($code, qr/studioDrums\.sources\.push\(src\)/, 'the sources are tracked so Stop can silence them');
like($code, qr/studioDrumsStopSources/, 'Stop cancels scheduled hits');

# --- the key map and its focus guard ---------------------------------------
like($code, qr/function studioDrumsVoiceForKey/, 'a key is resolved to a voice');
like($code, qr/function studioDrumsAssignKey/, 'a voice can be given a key');
like($code, qr/studioDrums\.learn/, 'Learn captures the next keydown');
like($code, qr/e\.key === 'Escape'/, 'Escape cancels Learn');
like($code, qr/function studioDrumsTyping/, 'one guard decides whether the person is typing');
like($code, qr/tag === 'input' \|\| tag === 'textarea' \|\| tag === 'select'/,
	'a text field pauses the drum keys');
like($code, qr/el\.isContentEditable/, 'a contenteditable field pauses them too');
like($code, qr/if \(studioDrumsTyping\(\) \|\| !studioDrums\.focus \|\| e\.repeat\)/,
	'a mapped key needs the Studio window and a free keyboard');
like($code, qr/studioDrums\.focus = !!.*closest\('#studio'\)\.length/,
	'the last pointer press decides which window owns the keys');
like($code, qr/Typing: drum keys are paused/, 'the panel says when typing pauses the keys');
like($code, qr/Click Studio to play the drum keys/, 'the panel says when another window owns them');
like($code, qr/studioDrumsTrigger\(voice, e\.shiftKey \? 100 : 70, true\)/,
	'a mapped key plays 70, Shift plays a full accent, and in record writes the step');
like($code, qr/typeof studioSelectedTake !== 'undefined' && studioSelectedTake\) \{ return; \}/,
	'a selected take pauses the drum keys so S cannot play and split at once');
like($help, qr/no take is selected/, 'help names the selected-take pause');
like($code, qr/studioDrumsRecording\(\)/, 'recording follows the transport and armed tracks');

# --- Web MIDI ---------------------------------------------------------------
like($code, qr/navigator\.requestMIDIAccess/, 'Web MIDI is offered where it exists');
like($code, qr/Web MIDI is not available in this browser\./, 'the panel says plainly when it is absent');
like($code, qr/function studioDrumsVoiceForNote/, 'a MIDI note resolves to a voice');
like($code, qr/\(data\[0\] & 0xf0\) !== 0x90/, 'only note-on messages play');
like($code, qr/Math\.max\(1, Math\.round\(data\[2\] \/ 127 \* 100\)\)/,
	'MIDI velocity becomes a percent, with 1 as the softest hit');
like($code, qr/studioDrums\.midiInput/, 'the chosen MIDI input is remembered');

# --- the chart length -------------------------------------------------------
like($code, qr/lengthSteps: 16/, 'the chart opens at one bar of sixteen steps');
like($code, qr/function studioDrumsNormaliseLength\(value, fallback\)/,
	'one function normalises the chart length');
like($code, qr/n = Math\.round\(n \/ 4\) \* 4;/, 'the length is always a multiple of four');
like($code, qr/return Math\.max\(4, Math\.min\(128, n\)\);/, 'the length stays between one beat and eight bars');
like($code, qr/function studioDrumsZeroRow\(length\)/, 'a blank row follows the chart length');
like($code, qr/function studioDrumsSetLength\(length\)/, 'one setter grows or trims every row');
like($code, qr/\.slice\(0, length\)/, 'a shorter chart trims the rows');
like($code, qr/while \(row\.length < length\) \{ row\.push\(0\); \}/,
	'a longer chart appends zeroed steps');
like($code, qr/studioDrumsChangeLength\(16\)/, 'a bar is sixteen steps');
like($code, qr/studioDrumsChangeLength\(-16\)/, 'removing a bar is sixteen steps');
like($code, qr/studioDrumsChangeLength\(4\)/, 'a beat is four steps');
like($code, qr/studioDrumsChangeLength\(-4\)/, 'removing a beat is four steps');
like($code, qr/function studioDrumsRenderLength\(\)/, 'one function paints the length');
like($code, qr/repeat\(' \+ length \+ ', minmax\(12px, 1fr\)\)/,
	'the head and rows share the length-sized grid');
like($code, qr/\$\('#studio_drums \.studio_drums_head, #studio_drums \.studio_drums_row'\)\.css\('grid-template-columns', columns\)/,
	'every row gets the inline grid');
like($code, qr/\$\(this\)\.css\('display', step < length \? '' : 'none'\)/,
	'steps past the length are hidden and the rest are shown');
like($knobs, qr/studioApplyLayoutSettings\(\);[\s\S]{0,1200}studioDrumsInit\(\);/,
	'a first open lays the panels out before it trims the drum chart');
like($code, qr/bars \+ ' ' \+ \(bars === 1 \? 'bar' : 'bars'\)/,
	'the readout counts bars with the right plural');
like($code, qr/beats \+ ' ' \+ \(beats === 1 \? 'beat' : 'beats'\)/,
	'the readout counts beats with the right plural');
like($code, qr/\$\('#studio_drums_length_readout'\)\.text\(studioDrumsText\(text\)\)/,
	'the readout names the length');
like($code, qr/studioDrums\.lengthSteps = studioDrumsNormaliseLength\(data\.length\)/,
	'restore reads the saved length');
like($code, qr/studioDrumsZeroRow\(studioDrums\.lengthSteps\)/,
	'restore normalises every row to the length');
like($code, qr/length: studioDrums\.lengthSteps/, 'the saved song carries the length');

for my $id (qw(studio_drums_bar_add studio_drums_bar_remove studio_drums_beat_add studio_drums_beat_remove)) {
	like($drums, qr/id="\Q$id\E"/, "the footer has $id");
}
like($drums, qr/id="studio_drums_bar_add"[^\n]*>\+ Bar/, 'the bar button says + Bar');
like($drums, qr/id="studio_drums_bar_remove"[^\n]*>&minus; Bar/, 'the bar button says minus Bar');
like($drums, qr/id="studio_drums_beat_add"[^\n]*>\+ Beat/, 'the beat button says + Beat');
like($drums, qr/id="studio_drums_beat_remove"[^\n]*>&minus; Beat/, 'the beat button says minus Beat');
like($drums, qr/id="studio_drums_bar_add"[^>]*Add a bar to the drum loop/, 'the bar button explains itself');
like($drums, qr/id="studio_drums_bar_remove"[^>]*Remove a bar from the drum loop/, 'the bar remove explains itself');
like($drums, qr/id="studio_drums_beat_add"[^>]*Add a beat to the drum loop/, 'the beat button explains itself');
like($drums, qr/id="studio_drums_beat_remove"[^>]*Remove a beat from the drum loop/, 'the beat remove explains itself');
like($drums, qr/id="studio_drums_length_readout"/, 'the footer reads out the length');

# --- the saved drum loop library -------------------------------------------
like($drums, qr/window\.jawnos_studio_drum_loops = <%== Mojo::JSON::encode_json\(eval \{ Mojo::JSON::decode_json\(\$settings->\{'drum_loops'\} \|\| '\[\]'\) \} \|\| \[\]\) %>;/,
	'the panel publishes the saved drum loops');
like($drums, qr/id="studio_drums_save_name" class="studio_drums_save_name"[^\n]*Name this drum loop/,
	'a loop has a name field');
like($drums, qr/id="studio_drums_save_loop"[^>]*Save the drum pattern as a loop/,
	'the pattern can be saved under that name');
like($drums, qr/<select id="studio_drums_loops" class="studio_drums_loops"[^>]*Choose a drum loop/,
	'a saved loop can be chosen');
like($drums, qr/<option value="">[^\n]*No saved loop/, 'the empty choice says so');
like($drums, qr/id="studio_drums_load_loop"[^>]*Load the chosen drum loop/, 'a loop can be loaded');
like($drums, qr/id="studio_drums_delete_loop"[^>]*Delete the chosen drum loop/, 'a loop can be deleted');
like($code, qr/function studioDrumsLoopLibrary\(\)/, 'the browser reads the published library');
like($code, qr/function studioDrumsSaveLoop\(\)/, 'a loop has one save function');
like($code, qr/library\.push\(\{ name: name, kit: studioDrums\.kit, length: studioDrums\.lengthSteps, steps: steps \}\)/,
	'a saved loop carries its name, kit, length and steps');
like($code, qr/if \(!name\) \{ return false; \}/, 'a loop needs a name');
like($code, qr/studioSaveSettings\(\[\{ setting: 'drum_loops', value: JSON\.stringify\(studioDrumsLoopLibrary\(\)\) \}\]\)/,
	'the library is persisted as an app setting');
like($code, qr/function studioDrumsLoadLoop\(\)/, 'a loop has one load function');
like($code, qr/studioDrums\.lengthSteps = studioDrumsNormaliseLength\(item\.length\)/,
	'loading a loop restores its length');
like($code, qr/var kit = studioDrumsKitName\(item\.kit\)/, 'an unknown loop kit falls back to Acoustic');
like($code, qr/function studioDrumsDeleteLoop\(\)/, 'a loop has one delete function');
like($code, qr/library\.splice\(index, 1\)/, 'delete removes just the chosen loop');

# --- length and loop persistence -------------------------------------------
like($code, qr/function studioDrumsSave\(\)/, 'the chart has one save function');
like($code, qr/return \{ steps: steps, keys: keys, loop: studioDrums\.loop \? 1 : 0, voices: voices, midi: studioDrums\.midiInput \|\| '', kit: studioDrums\.kit, length: studioDrums\.lengthSteps \};/,
	'the saved shape is steps, keys, loop, voices, midi, kit and length');
like($knobs, qr/drums: studioDrumsSave\(\)/, 'the song stores the drum state in admin');
like($knobs, qr/studioDrumsRestore\(mixer\['admin'\] && mixer\['admin'\]\['drums'\]\)/,
	'loading a song restores it');
like($code, qr/function studioDrumsRestore\(data\)/, 'the restore has one entry point');
like($code, qr/studioDrums\.steps\[v\.name\] = studioDrumsZeroRow\(studioDrums\.lengthSteps\)/,
	'a cleared chart is a row of zeroes at the chart length, which is valid');
like($code, qr/if \(!\(value > 0\)\) \{ value = 0; \}/, 'an empty or nonsense step restores as off');
like($code, qr/else if \(value === 1\) \{ value = 70; \}/, 'a legacy beat (1) restores at 70');
like($code, qr/else if \(value === 2\) \{ value = 100; \}/, 'a legacy accent (2) restores at 100');
like($code, qr/else \{ value = Math\.min\(100, value\); \}/, 'a newer saved velocity is clamped to 100');
like($code, qr/studioSaver\(\)/, 'a chart edit saves the song');

# --- kits: the table, the choice and the rebuild ----------------------------
like($code, qr/kit: 'acoustic'/, 'the drum machine opens on Acoustic');
like($code, qr/function studioDrumsKits\(\)/, 'the browser reads the published kit table');
like($code, qr/window\.jawnos_studio_drum_kits/, 'the kit table is the one the panel published');
like($code, qr/function studioDrumsKitName\(name\)/, 'a saved kit is validated against the table');
like($code, qr/studioDrumsKitNames\(\)\.indexOf\(name\) >= 0/, 'an unknown kit falls back to Acoustic');
like($code, qr/studioDrums\.kit = studioDrumsKitName\(data\.kit\)/, 'restore reads the saved kit');
like($code, qr/studioDrums\.buffers = \{\};[\s\S]{0,160}studioDrumsBuild\(studioDrums\.ctx\)/,
	'a kit change clears the old buffers and builds the new set');
like($code, qr/if \(studioDrums\.ctx && studioDrums\.builtKit !== studioDrums\.kit\)/,
	'a restored song rebuilds when its kit is not the one in hand');
like($code, qr/var token = \+\+studioDrums\.buildGen;/, 'each build takes a generation token');
like($code, qr/if \(token !== studioDrums\.buildGen\) \{ return; \}/,
	'an older build cannot overwrite newer buffers');
like($code, qr/\$\('#studio_drums_kit'\)\.val\(studioDrums\.kit\)/, 'the Kit list shows the chosen kit');
like($code, qr/function studioDrumsVoiceSpec\(kit, name\)/, 'the voice spec is kit-aware');
like($code, qr/studioDrumsVoiceSpec\(kit, v\.name\)/, 'the build asks for the current kit');
like($code, qr/function studioDrumsRenderVoice\(off, kit, name\)/, 'the render takes the kit too');
like($code, qr/function studioDrumsBaseSpec\(name\)/, 'the acoustic eight are the base every kit overrides');
unlike($code, qr/^\tacoustic: \{/m, 'Acoustic is the base, not a table of duplicates');
for my $kit (grep { $_ ne 'acoustic' } @kit_names) {
	like($code, qr/^\t'?\Q$kit\E'?: \{/m, "the $kit kit overrides the acoustic voices");
}
like($code, qr/from: 110, to: 32/, 'Beats puts a long sub under the kick');
like($code, qr/from: 90, to: 28, dur: 0\.70/, '808 has a long sub kick');
like($code, qr/freq: 5000, dur: 0\.02, gain: 0\.45/, 'Metal has a clicky kick');
like($code, qr/from: 240, to: 150, dur: 0\.18/, 'Latin lifts the toms');

# --- velocity ---------------------------------------------------------------
like($code, qr/current \? 0 : \(e\.shiftKey \? 100 : 70\)/,
	'a plain click places 70, Shift places 100, and either removes');
like($code, qr/\.attr\('data-velocity', value \? String\(value\) : ''\)/, 'a step carries its velocity');
like($code, qr/value >= 100 \? 'yes' : 'no'/, 'a full beat keeps the accent look');
like($code, qr/setProperty\('--drums-velocity', String\(value \/ 100\)\)/, 'a placed beat fades with its velocity');
like($code, qr/removeProperty\('--drums-velocity'\)/, 'an empty step clears the custom property');
like($code, qr/el\.attr\('title', label \+ ' ' \+ value \+ '%'\)/, 'a placed beat names the voice and its percent');
like($code, qr/studioDrumsPlay\(v\.name, when, value \/ 100\)/, 'a step plays at value/100');
like($code, qr/var percent = Math\.max\(1, Math\.min\(100, Math\.round\(velocity \|\| 0\)\)\);/,
	'the trigger takes a percent');
like($code, qr/studioDrumsPlay\(voice, ctx\.currentTime \+ 0\.008, percent \/ 100\)/,
	'the play path still receives a 0..1 fraction');
like($code, qr/studioDrums\.steps\[voice\]\[step\] = percent;/, 'recording writes the same percent');
like($code, qr/studioDrumsTrigger\(\$\(this\)\.attr\('data-voice'\), 80, false\)/,
	'the voice button auditions at 80');

# --- the velocity menu ------------------------------------------------------
like($code, qr/function studioDrumsVelocityMenu\(voice, step, x, y\)/, 'a placed beat has a velocity menu');
like($code, qr/class="studio_menu studio_drums_velocity"/, 'the menu uses the shared theme card');
like($code, qr/studio_menu_head/, 'the menu names the drum');
like($code, qr/class="studio_menu_velocity"/, 'the menu has its velocity row');
like($code, qr/data-delta="-10"/, 'the menu can go softer');
like($code, qr/data-delta="10"/, 'the menu can go harder');
like($code, qr/Math\.max\(10, Math\.min\(100, /, 'the menu keeps a beat between 10 and 100');
like($code, qr/menu\.find\('\[data-value\]'\)\.text\(String\(value\)\)/,
	'the menu shows the new value while it stays open');
like($code, qr/studioDrumsTrigger\(voice, value, false\)/, 'a press auditions at the new velocity');
like($code, qr/if \(!value\) \{ return; \}[\s\S]{0,40}e\.preventDefault\(\);/,
	'an empty step opens no menu and the browser menu stands');
like($code, qr/closest\('#studio_drums_velocity'\)\.length\) \{ studioDrumsMenuClose\(\); \}/,
	'the next press elsewhere closes the menu');
like($code, qr/if \(e\.key === 'Escape'\) \{ studioDrumsMenuClose\(\); \}/, 'Escape closes the menu');
like($code, qr/addEventListener\('scroll', studioDrumsMenuClose, true\)/, 'a scroll closes the menu');
like($code, qr/studioDrumsMenuClose\(\);[\s\S]{0,60}studioDrumsVoices\(\)\.forEach/,
	'Clear closes the menu');
like($code, qr/function studioDrumsMenuPlace/, 'the menu is clamped to the viewport');
like($code, qr/Math\.max\(4, Math\.min\(x, viewW - width - 4\)\)/, 'its left edge stays inside the window');
like($code, qr/Math\.max\(4, Math\.min\(y, viewH - height - 4\)\)/, 'its top edge stays inside the window');

# --- routing ----------------------------------------------------------------
like($code, qr/studioDrums\.out\.connect\(studioDrums\.direct\)/,
	'the kit output first reaches its own direct gain');
like($code, qr/studioDrums\.direct\.connect\(studioAudio\.master\)/,
	'the direct drum bus enters the master bus');
like($code, qr/studioDrums\.rec\.connect\(c\.recDest\)/,
	'the recording tap feeds a channel recDest');
like($code, qr/function studioDrumsRouteSelection/, 'the tap follows the selected track');
my ($route) = $code =~ /function studioDrumsRouteSelection\(\) \{(.*?)\n\}/s;
ok(defined $route, 'the routing function is found');
$route = '' unless defined $route;
like($route, qr/if \(!ctx \|\| !studioDrums\.rec\) \{ return; \}/,
	'routing is safe before the bus is built');
like($route, qr/var info = \$\('\.studio_channel_information\[direction="input"\]\[channel="' \+ ch \+ '"\]'\)\.text\(\);/,
	'routing reads the channel input plug');
like($route, qr/var plug = isJson\(info\) \? JSON\.parse\(info\) : \{\};/,
	'a missing or non-JSON plug is empty');
like($route, qr/try \{ studioDrums\.rec\.disconnect\(\); \} catch \(e\) \{\}/,
	'the previous direct tap is removed first');
like($route, qr/if \(plug\['app'\] !== 'drums'\) \{ studioDrums\.rec\.connect\(c\.recDest\); \}/,
	'a non-drums input reconnects the direct tap');
unlike($route, qr/^\tstudioDrums\.rec\.connect\(c\.recDest\);/m,
	'a drums input leaves the direct tap disconnected, so the take is not doubled');
like($route, qr/studioDrums\.routedDest = c\.recDest;/,
	'routedDest still names the channel the drums serve');
unlike($route, qr/routedDest === c\.recDest\) \{ return; \}/,
	'a plug change away from drums is re-evaluated');
like($code, qr/native engine[\s\S]{0,20}take cannot record them yet/, 'the engine limitation is a code comment');
like($inputs, qr/studioDrums\.routedDest === drums_channel\.recDest/,
	'an armed, empty selected track can take the drums');
like($inputs, qr/media\.in = drums_channel\.recDest\.stream/,
	'the take records the drum destination stream');
like($code, qr/studioContext\(\)/, 'the drums ride the studio context');
like($code, qr/mastering rack/, 'the panel names the master path');

# --- the panel system and the interior drum window --------------------------
like($layout, qr/drums: '#studio_drums'/, 'the drums are a registered panel');
like($layout, qr/var studioPanelNames = \['transport', 'tracks', 'mixer', 'drums'\]/,
	'the drums are last in the panel taskbar');
like($layout, qr/function studioDefaultPanelLayout/, 'the drums take a place in the preset');
like($layout, qr/drums: \{ left: tracksWidth \+ gap, top: middleTop/,
	'the preset puts the drums beside the timeline');
like($drums, qr/class="studio_panel_min hover" data-panel="drums"/, 'the drums can be minimized');
like($drums, qr/class="studio_panel_max hover" data-panel="drums"/, 'the drums can be maximized');
like($drums, qr/data-studio-drag="drums"/, 'the drums can be moved by their title bar');
like($style, qr/\.studio_panel\.studio_panel_minimized\s*\{\s*display:\s*none/s,
	'minimizing hides the drum window');
like($code, qr/studioDrumsGridState/, 'the drum state hook still exists');
like($code, qr/studioPanelTaskbarRefresh/, 'the drum hook refreshes the taskbar');
like($style, qr/#studio_drums\s*\{[^}]*display:\s*flex/s, 'the panel is a flex column');
like($style, qr/\.studio_drums_scroll\s*\{[^}]*overflow:\s*auto/s, 'the chart scrolls inside the panel');
like($style, qr/\.studio_drums_head,[\s\S]*?repeat\(16, minmax\(12px, 1fr\)\)/s,
	'the sixteen columns share one grid');
like($style, qr/background:\s*var\(--accent\)/, 'a placed step takes the theme accent');
like($style, qr/var\(--runway-good/, 'the mute lamp takes the theme lamp colour');
like($style, qr/\.studio_drums_lamp\[aria-pressed="false"\]/, 'a muted voice reads dark');

# --- the split manifest names the new part ---------------------------------
like($index, qr/11_drums\.js/, 'the studio index names the drum part in its manifest');

# --- the help topic ---------------------------------------------------------
like($help, qr/Drums and keys/, 'help has a Drums and keys paragraph');
like($help, qr/eight synthesised voices - Kick, Snare, Closed Hat/, 'help names the voices');
like($help, qr/hold Shift and click for an accent/, 'help explains accents');
like($help, qr/The chart follows the transport/, 'help explains the transport');
like($help, qr/Keys only sound while no text field has focus/, 'help explains the focus guard');
like($help, qr/Connect MIDI/, 'help explains MIDI');
like($help, qr/The native engine take cannot record them yet/, 'help states the engine limitation');

my ($controls) = $help =~ /\$topic\{'studio'\} = \{([\s\S]*?)\n\t\};/;
ok(defined $controls, 'the studio help topic was found');
$controls = '' unless defined $controls;
$controls =~ s/\\'/'/g;
for my $label (
	'Drag to move the drums', 'Minimize this panel', 'Maximize or restore this panel',
	'Computer keys follow the Studio window', 'Repeat the drum chart each bar',
	'Clear the drum chart', 'Play this drum', 'Assign a computer key to this drum',
	'Mute this drum', 'Click to place a beat, hold Shift for an accent, right-click to set its velocity',
	'Choose a drum kit',
	'Connect a MIDI keyboard to the drums', 'Choose a MIDI input for the drums',
	'Add a bar to the drum loop', 'Remove a bar from the drum loop',
	'Add a beat to the drum loop', 'Remove a beat from the drum loop',
	'Name this drum loop', 'Save the drum pattern as a loop',
	'Choose a drum loop', 'Load the chosen drum loop', 'Delete the chosen drum loop') {
	like($controls, qr/'\Q$label\E'/, "the help controls list names '$label'");
}

done_testing();
