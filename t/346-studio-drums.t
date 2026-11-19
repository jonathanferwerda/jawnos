# tests-for: templates/studio/drums.html.ep templates/studio/markup.html.ep templates/studio/style.html.ep public/js/manager/studio.js public/js/manager/studio/04_knobs.js public/js/manager/studio/05_inputs.js public/js/manager/studio/06_controls.js public/js/manager/studio/07_layout.js public/js/manager/studio/11_drums.js perl/gb/05_abilities_and_studio.pl perl/help/topics_apps.pl t/346-studio-drums.t
# covers:    The Studio drum machine: the eight-voice table, a one-bar chart of
#            sixteen steps, the transport/lookahead scheduler, the computer-key
#            map with its typing guard, Web MIDI, the song's admin.drums state,
#            and the routing into the master rack and the browser take.

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

# --- the panel is included once and is data-driven --------------------------
my @includes = $markup =~ /include 'studio\/drums'/g;
is(scalar(@includes), 1, 'the markup includes the drum panel once');
like($markup, qr/id="studio_drums"|include 'studio\/drums'/, 'the drum panel is a real include');
like($drums, qr/window\.jawnos_studio_drums/, 'the panel publishes its voice table');
like($drums, qr/foreach my \$v \( \@\{\$gb::studio->\{'drums'\}\} \)/,
	'the rows come from the table, not hard-coded markup');
my @steps = $drums =~ /for my \$step \(0 \.\. 15\)/g;
is(scalar(@steps), 2, 'the head and every row count sixteen steps');
like($drums, qr/data-step="<%=\s*\$step\s*%>"/, 'a step carries its index');
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
like($code, qr/studioDrums\.step = \(studioDrums\.step \+ 1\) % 16/,
	'the bar wraps after sixteen steps');
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
like($code, qr/studioDrumsTrigger\(voice, e\.shiftKey \? 2 : 1, true\)/,
	'a mapped key plays and, in record, writes the current step');
like($code, qr/typeof studioSelectedTake !== 'undefined' && studioSelectedTake\) \{ return; \}/,
	'a selected take pauses the drum keys so S cannot play and split at once');
like($help, qr/no take is selected/, 'help names the selected-take pause');
like($code, qr/studioDrumsRecording\(\)/, 'recording follows the transport and armed tracks');

# --- Web MIDI ---------------------------------------------------------------
like($code, qr/navigator\.requestMIDIAccess/, 'Web MIDI is offered where it exists');
like($code, qr/Web MIDI is not available in this browser\./, 'the panel says plainly when it is absent');
like($code, qr/function studioDrumsVoiceForNote/, 'a MIDI note resolves to a voice');
like($code, qr/\(data\[0\] & 0xf0\) !== 0x90/, 'only note-on messages play');
like($code, qr/data\[2\] > 96 \? 2 : 1/, 'MIDI velocity chooses the accent');
like($code, qr/studioDrums\.midiInput/, 'the chosen MIDI input is remembered');

# --- persistence ------------------------------------------------------------
like($code, qr/function studioDrumsSave\(\)/, 'the chart has one save function');
like($code, qr/return \{ steps: steps, keys: keys, loop: studioDrums\.loop \? 1 : 0, voices: voices, midi:/,
	'the saved shape is steps, keys, loop, voices and midi');
like($knobs, qr/drums: studioDrumsSave\(\)/, 'the song stores the drum state in admin');
like($knobs, qr/studioDrumsRestore\(mixer\['admin'\] && mixer\['admin'\]\['drums'\]\)/,
	'loading a song restores it');
like($code, qr/function studioDrumsRestore\(data\)/, 'the restore has one entry point');
like($code, qr/studioDrums\.steps\[v\.name\] = \[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0\]/,
	'a cleared chart is sixteen zeroes, which is valid');
like($code, qr/value === 1 \|\| value === 2/, 'a step restores as off, on or accent');
like($code, qr/studioSaver\(\)/, 'a chart edit saves the song');

# --- routing ----------------------------------------------------------------
like($code, qr/studioDrums\.out\.connect\(studioAudio\.master\)/,
	'the drum bus enters the master bus');
like($code, qr/studioDrums\.rec\.connect\(c\.recDest\)/,
	'the recording tap feeds a channel recDest');
like($code, qr/function studioDrumsRouteSelection/, 'the tap follows the selected track');
like($code, qr/native engine[\s\S]{0,20}take cannot record them yet/, 'the engine limitation is a code comment');
like($inputs, qr/studioDrums\.routedDest === drums_channel\.recDest/,
	'an armed, empty selected track can take the drums');
like($inputs, qr/media\.in = drums_channel\.recDest\.stream/,
	'the take records the drum destination stream');
like($code, qr/studioContext\(\)/, 'the drums ride the studio context');
like($code, qr/mastering rack/, 'the panel names the master path');

# --- the panel system and the arranged grid --------------------------------
like($layout, qr/drums: '#studio_drums'/, 'the drums are a registered panel');
like($layout, qr/drums: 'hide_drums'/, 'the drums have their own hide setting');
like($layout, qr/var studioPanelNames = \['synth', 'drums', 'tracks', 'mixer', 'transport'\]/,
	'the drums are in the manual packing order');
like($layout, qr/studioPanelSpan = \{ synth: 1, drums: 1,/, 'the drums have a span');
like($style, qr/#studio_grid\.studio_arranged\.studio_drums_open\s*\{[\s\S]*?"transport transport transport"[\s\S]*?"tracks synth drums"[\s\S]*?"mixer mixer mixer"/,
	'arranged mode gives the drums a column beside the synth');
like($style, qr/#studio_grid\.studio_arranged\.studio_drums_open > #studio_drums\s*\{[^}]*grid-area:\s*drums !important/s,
	'the drums own that area');
like($style, qr/#studio_grid\.studio_arranged_compact\.studio_drums_open\s*\{[\s\S]*?"transport"[\s\S]*?"tracks"[\s\S]*?"mixer"[\s\S]*?"synth"[\s\S]*?"drums"/s,
	'a narrow window stacks the drums last');
like($layout, qr/studioDrumsGridState/, 'hiding or floating the panel hands its column back');
like($style, qr/#studio_grid\.studio_arranged\s*\{[\s\S]*?"tracks tracks synth"/s,
	'the drum-free three-column arrangement is unchanged');
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
	'Drag to move the drums', 'Dock the drums', 'Float the drums', 'Hide the drums',
	'Computer keys follow the Studio window', 'Repeat the drum chart each bar',
	'Clear the drum chart', 'Play this drum', 'Assign a computer key to this drum',
	'Mute this drum', 'Click to place a beat, hold Shift for an accent',
	'Connect a MIDI keyboard to the drums', 'Choose a MIDI input for the drums') {
	like($controls, qr/'\Q$label\E'/, "the help controls list names '$label'");
}

done_testing();
