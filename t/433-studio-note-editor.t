# tests-for: templates/studio/notes.html.ep public/js/manager/studio/19_notes.js
# covers:    The Notes panel shell (drag handle, pin/min/max/Close, toolbar,
#            grid + key strip, velocity lane and the empty state) and the note
#            editor's contract: notes and beats in BEATS, drag time/pitch,
#            right-edge duration, click-to-add, the velocity menu, Delete and
#            Escape, snapping and clamping, the take fields written, the
#            debounced studioNoteClipRerender hook and the three window
#            functions. Source shape only; pixels are not asserted here.

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

# A checked-in token must appear verbatim. The source is the contract here, so a
# substring check says exactly what changed when it fails.
sub has {
	my ($text, $needle, $name) = @_;
	my $at = index($text, $needle);
	ok($at >= 0, $name) or diag("missing: $needle");
	return $at >= 0;
}

sub hasnt {
	my ($text, $needle, $name) = @_;
	ok(index($text, $needle) < 0, $name) or diag("unexpected: $needle");
}

my $root = $FindBin::Bin;
$root =~ s{/t$}{};
my $tmpl = slurp("$root/templates/studio/notes.html.ep");
my $js   = slurp("$root/public/js/manager/studio/19_notes.js");

# --- the panel is a sixth interior Studio window ----------------------------
has($tmpl, '<div id="studio_notes" class="studio_panel', 'the panel is a Studio panel');
has($tmpl, 'studio_notes_empty', 'it starts able to show the empty state');
has($tmpl, 'data-studio-notes-open="0"', 'it records whether a clip is open');
has($tmpl, 'class="studio_panel_bar"', 'it has the shared title bar');
has($tmpl, 'class="studio_drag_handle" data-studio-drag="notes"', 'the bar carries the Notes drag handle');
has($tmpl, 'class="studio_panel_pin hover" data-panel="notes"', 'the pin button targets notes');
has($tmpl, 'class="studio_panel_min hover" data-panel="notes"', 'the Minimize button targets notes');
has($tmpl, 'class="studio_panel_max hover" data-panel="notes"', 'the Maximize button targets notes');
has($tmpl, 'id="studio_notes_close" class="studio_panel_close studio_notes_close hover"', 'the bar has a Close button');
has($tmpl, 'data-studio-resize="notes"', 'the corner grip names notes');
has($tmpl, 'data-studio-bottom="notes"', 'the bottom grip names notes');
has($tmpl, 'id="studio_notes_body"', 'the body is the editor host');

# --- what the person reads -------------------------------------------------
has($tmpl, 'id="studio_notes_title"', 'the clip track is in the title');
has($tmpl, 'id="studio_notes_meta"', 'length, BPM and the patch have a readout');
has($tmpl, 'id="studio_notes_zoom_out"', 'zoom out is in the toolbar');
has($tmpl, 'id="studio_notes_zoom_in"', 'zoom in is in the toolbar');
has($tmpl, 'id="studio_notes_snap"', 'the toolbar carries the Snap list');
has($tmpl, '<option value="0"><%= &subs::ui(\'Off\') %></option>', 'Snap offers Off');
has($tmpl, '<option value="0.25">1/4</option>', 'Snap offers 1/4 beat');
has($tmpl, '<option value="0.125">1/8</option>', 'Snap offers 1/8 beat');
has($tmpl, '<option value="0.0625" selected>1/16</option>', 'Snap defaults to 1/16 beat');
has($tmpl, '<option value="0.03125">1/32</option>', 'Snap offers 1/32 beat');
has($tmpl, 'id="studio_notes_clear"', 'Clear is in the toolbar');
has($tmpl, 'class="studio_notes_close hover"', 'the toolbar also closes the editor');
has($tmpl, 'hint="<%= &subs::ui(\'Drag to move the note editor\') %>"', 'the drag handle is hint-translated');
has($tmpl, 'hint="<%= &subs::ui(\'See more of the clip\') %>"', 'a toolbar button is hint-translated');

# --- the grid, the key strip and the velocity lane -------------------------
has($tmpl, 'id="studio_notes_editor" class="studio_notes_editor"', 'the grid host exists');
has($tmpl, 'id="studio_notes_keys" class="studio_notes_keys"', 'the vertical piano-key strip is a canvas');
has($tmpl, 'id="studio_notes_grid" class="studio_notes_grid"', 'the beat grid is a canvas');
has($tmpl, 'id="studio_notes_velocity_canvas"', 'the velocity lane is a canvas');
has($tmpl, 'id="studio_notes_velocity_readout"', 'the selected velocity has a readout');
has($tmpl, '<%= &subs::ui(\'Right-click a synth loop to edit its notes.\') %>', 'the empty state says how to open a clip');
has($tmpl, '<style>', 'the panel carries its own style block');
has($tmpl, '#studio_notes .studio_notes_editor', 'the style block is scoped to the panel');
has($tmpl, '#studio_notes.studio_notes_empty .studio_notes_hint', 'the style reveals the empty state');
hasnt($tmpl, '<script>', 'the shell carries no inline logic');

# --- state and the public surface ------------------------------------------
has($js, 'var studioNotesState = {', 'the editor keeps its state in one object');
has($js, 'ch: null,', 'the state names the channel');
has($js, 'take: null,', 'the state names the take');
has($js, 'ppb: 48,', 'the zoom is pixels per beat');
has($js, 'snap: 0.0625,', 'the starting snap is 1/16 beat');
has($js, 'topNote: 84,', 'the state keeps the top piano row');
has($js, 'leftBeat: 0,', 'the state keeps the left beat');
has($js, 'drag: null,', 'the state keeps the drag');
has($js, 'function studioNotesOpen(ch, take) {', 'studioNotesOpen takes a channel and a take');
has($js, 'function studioNotesClose() {', 'studioNotesClose exists');
has($js, 'function studioNotesRefresh() {', 'studioNotesRefresh exists');
has($js, 'window.studioNotesOpen = studioNotesOpen;', 'studioNotesOpen is published');
has($js, 'window.studioNotesClose = studioNotesClose;', 'studioNotesClose is published');
has($js, 'window.studioNotesRefresh = studioNotesRefresh;', 'studioNotesRefresh is published');
has($js, 'if (!panel) { return; }', 'opening with no panel does not throw');
has($js, 'panel.classList.remove(\'studio_panel_minimized\');', 'opening restores a minimized panel');
has($js, 'panel.setAttribute(\'data-studio-notes-open\', st.take ? \'1\' : \'0\');', 'opening sets the open flag');
has($js, 'panel.classList.toggle(\'studio_notes_empty\', !st.take);', 'a missing take shows the empty state');
has($js, 'panel.classList.add(\'studio_panel_minimized\');', 'closing hides the panel');
has($js, 'st.take = null;', 'closing empties the current clip');
has($js, 'st.beatsPerBar = studioNotesBeatsPerBar();', 'refresh re-reads the signature');

# --- the take fields read and written --------------------------------------
has($js, 'take.notes = st.notes;', 'a change writes take.notes');
has($js, 'take.beats = studioNotesEnsureBeats(take);', 'a change writes take.beats');
has($js, 'if (typeof studioSaver === \'function\') { studioSaver(); }', 'a change saves the song');
has($js, 'var patch = st.take.patch || {};', 'the readout reads take.patch');
has($js, 'patch.name || patch.family', 'the readout knows the patch or preset name');
has($js, 'take.startTime', 'the playhead reads the timeline placement');
has($js, 'if (take && take.loop && beats > 0) {', 'a loop clip is drawn as repeats');
has($js, 'studioNotesText(bars === 1 ? \'bar\' : \'bars\')', 'the length reads in bars');
has($js, 'Math.round(studioNotesBpm()) + \' BPM\'', 'the readout carries the tempo');

# --- beats, snapping, clamping ---------------------------------------------
has($js, 'function studioNotesEnsureBeats(take) {', 'the clip length has one derivation');
has($js, 'if (maxEnd > beats) { beats = Math.ceil(maxEnd * 4) / 4; }', 'a note reaching past the loop grows the loop to hold it');
has($js, 'function studioNotesSnapBeat(beat) {', 'beats snap to the grid');
has($js, 'return (snap > 0) ? snap : 0.25;', 'Off still has a quarter-beat floor');
has($js, 'function studioNotesClampNote(note, beats, minDur) {', 'every note has one clamp');
has($js, 'note.n = Math.round(studioNotesClamp(isFinite(pitch) ? pitch : 60, 0, 127));', 'pitch is clamped to MIDI 0..127');
has($js, 'note.v = isFinite(velocity) ? studioNotesClamp(velocity, 0, 1) : 0.8;', 'velocity is clamped to 0..1');
has($js, 'note.t = Math.max(0, Math.min(Math.max(0, beats - note.d), Number(note.t) || 0));', 'a note starts inside the loop');
has($js, 'note.d = Math.max(min, Math.min(note.d, beats - note.t));', 'a note never ends past the loop');

# --- canvas drawing --------------------------------------------------------
has($js, 'getContext(\'2d\')', 'the editor draws on a 2D canvas');
has($js, 'window.devicePixelRatio || 1', 'the canvas follows the device pixel ratio');
has($js, 'ctx.setTransform(dpr, 0, 0, dpr, 0, 0);', 'the drawing is scaled back to CSS pixels');
has($js, 'typeof ResizeObserver === \'function\'', 'a ResizeObserver redraws the grid');
has($js, '$(window).on(\'resize\'', 'the window resize is the fallback');
has($js, 'function studioNotesDrawBlock(ctx, theme, note, offset, selected, w, h) {', 'a note block is one drawing routine');
has($js, 'var bw = Math.max(3, (Number(note.d) || 0.0625) * st.ppb);', 'a block is sized by its duration');
has($js, 'ctx.globalAlpha = 0.34 + v * 0.6;', 'a block is coloured by its velocity');
has($js, 'function studioNotesDrawKeys(theme) {', 'the key strip is drawn');
has($js, 'studioNotesIsBlack(note)', 'the rows know the black keys');
has($js, 'var isBar = (k % perBar) === 0;', 'bars and beats are different lines');
has($js, 'studioNotesDrawBlock(ctx, theme, st.notes[g], pass * beats, false, w, h);', 'a loop ghost repeats the notes at every pass');

# --- pointer editing -------------------------------------------------------
has($js, '$(document).on(\'pointerdown\', \'#studio_notes_grid\', function (e) {', 'the grid has a pointerdown handler');
has($js, 'studioNotesStartDrag(hit.mode, hit, pos, false);', 'a pressed note starts the drag its edge chose');
has($js, 'var edge = Math.min(8, Math.max(3, bw / 4));', 'the right edge has a grab band');
has($js, 'mode: (x >= nx + bw - edge) ? \'resize\' : \'move\'', 'the right edge resizes and the body moves');
has($js, 'var wanted = studioNotesSnapBeat(drag.t + deltaBeats);', 'a move snaps its time');
has($js, 'drag.n - Math.round((pos.y - drag.startY) / STUDIO_NOTES_ROW)', 'a move changes pitch by whole semitones');
has($js, 'var maxDur = Math.max(0.015625, beats - drag.t);', 'a resize cannot pass the loop');
has($js, 'var duration = Math.max(minStep, Math.min(maxDur, end - drag.t));', 'a resize keeps one snap step and clamps');
has($js, 'function studioNotesAddAt(pos) {', 'an empty grid click adds a note');
has($js, 'var note = { n: pitch, t: t, d: duration, v: st.lastVelocity };', 'a new note carries pitch, time, one step and the last velocity');

my ($move_body) = $js =~ /(function studioNotesPointerMove\(e\) \{.*?\n\})/s;
ok($move_body, 'the move handler is a self-contained function');
unlike($move_body, qr/studioNotesCommit|studioSaver/, 'a drag redraws without saving on every move');

my ($up_body) = $js =~ /(function studioNotesPointerUp\(\) \{.*?\n\})/s;
ok($up_body, 'the press end is its own function');
like($up_body, qr/studioNotesCommit\(true\)/, 'the press end commits and asks for a rerender');

# --- the velocity menu, Delete and Escape ----------------------------------
has($js, '$(document).on(\'contextmenu\', \'#studio_notes_grid\', function (e) {', 'right-click opens the note menu');
has($js, 'studioNotesVelocityMenu(hit.index, e.clientX, e.clientY);', 'the menu sits at the pointer');
has($js, '\'<div class="studio_menu studio_notes_velocity_menu"></div>\'', 'the menu uses the shared card');
has($js, 'data-delta="-10"', 'the menu has Softer');
has($js, 'data-delta="10"', 'the menu has Harder');
has($js, 'data-value', 'the menu shows the value');
has($js, 'data-action="delete"', 'the menu can delete the note');
has($js, 'function studioNotesDelete(index) {', 'deleting a note is one routine');
has($js, 'if ((e.key === \'Delete\' || e.key === \'Backspace\') && st.selected >= 0) {', 'Delete and Backspace remove the selected note');
has($js, 'if (e.key === \'Escape\') {', 'Escape is handled');
has($js, 'function studioNotesCancelDrag() {', 'Escape can put a drag back');
has($js, 'drag.note.t = drag.t;', 'a cancelled drag restores the time');
has($js, 'drag.note.d = drag.d;', 'a cancelled drag restores the duration');

# --- audition and the rerender hook ---------------------------------------
has($js, 'var synth = window.jawnosSynth;', 'the editor reads the synth globally');
has($js, 'if (!synth || typeof synth.noteOn !== \'function\') { return; }', 'a missing synth is guarded');
has($js, 'synth.noteOn(n, studioNotesClamp(velocity, 0, 1));', 'adding and dragging audition through noteOn');
has($js, 'synth.noteOff(n);', 'the gate ends through noteOff');
has($js, '}, 220);', 'the audition gate is short');
has($js, 'typeof window.studioNoteClipRerender === \'function\'', 'the rerender hook is called through typeof');
has($js, 'window.studioNoteClipRerender(pendingCh, pendingTake);', 'the hook gets (ch, take)');
has($js, 'if (st.rerenderTimer) { clearTimeout(st.rerenderTimer); }', 'a second change debounces the first rerender');
has($js, '}, 140);', 'the rerender waits for the edit to settle');

# --- no new libraries ------------------------------------------------------
hasnt($js, 'require(', 'the editor needs no module loader');
hasnt($js, 'import ', 'the editor needs no ES modules');
hasnt($js, 'new AudioContext', 'the editor does not build its own audio graph');

done_testing();
