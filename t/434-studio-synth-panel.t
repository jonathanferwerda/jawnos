# tests-for: templates/studio/synth.html.ep templates/studio/markup.html.ep templates/studio/style.html.ep public/js/manager/studio/07_layout.js public/js/manager/studio.js
# covers:    The Synth and Notes panels as the fifth and sixth interior Studio
#            windows: the Synth partial carries the whole shared synth surface in
#            its own #synth, a title bar with the panel buttons, drag/resize grips
#            and a saved-loop library published as jawnos_studio_synth_loops; the
#            taskbar offers both windows; the layout registry, the default/Arrange
#            boxes and Ctrl+Alt+1..6 cover six names; the note editor starts
#            minimized with no saved record and Arrange leaves it minimized until
#            a clip is open; the studio.js manifest names the note part; and the
#            stylesheet gives both windows their box and scrolling. Structure
#            only; pixels are not asserted here.

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

my $root    = $FindBin::Bin;
$root =~ s{/t$}{};
my $synth   = slurp("$root/templates/studio/synth.html.ep");
my $markup  = slurp("$root/templates/studio/markup.html.ep");
my $style   = slurp("$root/templates/studio/style.html.ep");
my $layout  = slurp("$root/public/js/manager/studio/07_layout.js");
my $js      = slurp("$root/public/js/manager/studio.js");
my $notes   = slurp("$root/templates/studio/notes.html.ep");

# --- the Synth panel is an interior window ------------------------------------
like($synth, qr/<div id="studio_synth" class="studio_panel">/,
	'the synth is a panel window on the desk');
like($synth, qr/class="studio_drag_handle" data-studio-drag="synth"[^>]*hint="[^"]*"[^>]*>.*?Synth/,
	'the synth title bar carries a drag handle');
like($synth, qr/class="studio_panel_pin hover" data-panel="synth"[^>]*hint="<%= &subs::ui\('Keep this panel above the others'\) %>"/,
	'the synth can be pinned');
like($synth, qr/class="studio_panel_min hover" data-panel="synth"[^>]*hint="<%= &subs::ui\('Minimize this panel'\) %>"/,
	'the synth can be minimized');
like($synth, qr/class="studio_panel_max hover" data-panel="synth"[^>]*hint="<%= &subs::ui\('Maximize or restore this panel'\) %>"/,
	'the synth can be maximized');
like($synth, qr/class="studio_resize_handle" data-studio-resize="synth"[^>]*hint="<%= &subs::ui\('Drag to resize this panel'\) %>"/,
	'the synth has a corner resize grip');
like($synth, qr/class="studio_panel_bottom" data-studio-bottom="synth"[^>]*hint="<%= &subs::ui\('Drag the bottom edge to resize this panel\\'s height'\) %>"/,
	'the synth has a bottom edge grip');

# --- the full Synth surface lives in the panel body --------------------------
like($synth, qr{<div id="synth" class="studio_synth_body"><%= include 'synth_inner' %></div>},
	'the panel body is the shared #synth surface the engine init expects');
like($synth, qr/<%= include 'synth_style' %>/, 'the shared synth styles render once for the panel');
unlike($synth, qr/piano_key|synth_toolbar/, 'the panel does not duplicate the shared surface');

# --- the saved loop library is published with the panel ----------------------
like($synth, qr/<% use Mojo::JSON; %>/, 'the partial imports the JSON encoder');
like($synth,
	qr/window\.jawnos_studio_synth_loops = <%== Mojo::JSON::encode_json\(eval \{ Mojo::JSON::decode_json\(\$settings->\{'synth_loops'\} \|\| '\[\]'\) \} \|\| \[\]\) %>;/,
	'the saved loops are published as an array, safe when the setting is absent');
like($synth, qr/<input id="studio_synth_save_name"[\s\S]*?hint="<%= &subs::ui\('Name this synth loop'\) %>"/,
	'the library names a loop before saving it');
like($synth, qr/<button id="studio_synth_save_loop"[^>]*hint="<%= &subs::ui\('Save the synth patch as a loop'\) %>"/,
	'the library saves the current patch as a loop');
like($synth, qr/<select id="studio_synth_loops"[^>]*hint="<%= &subs::ui\('Choose a synth loop'\) %>"><option value=""><%= &subs::ui\('No saved loop'\) %>/,
	'the library select starts with No saved loop');
like($synth, qr/<button id="studio_synth_load_loop"[^>]*hint="<%= &subs::ui\('Load the chosen synth loop'\) %>"/,
	'the library loads the chosen loop');
like($synth, qr/<button id="studio_synth_delete_loop"[^>]*hint="<%= &subs::ui\('Delete the chosen synth loop'\) %>"/,
	'the library deletes the chosen loop');
like($synth, qr/class="studio_synth_library"/, 'the library controls share one row');

# --- both panels are included on the desk, beside the drums ------------------
like($markup, qr/<%= include 'studio\/drums' %>\n\t<%= include 'studio\/synth' %>\n\t<%= include 'studio\/notes' %>/,
	'the grid includes drums, synth and notes in that order');
like($markup, qr/<button class="studio_panel_task hover" data-panel="synth"[\s\S]*?<%= &subs::ui\('Synth'\) %><\/button>/,
	'the taskbar offers the Synth');
like($markup, qr/<button class="studio_panel_task hover" data-panel="notes"[\s\S]*?<%= &subs::ui\('Notes'\) %><\/button>/,
	'the taskbar offers the Notes');
like($markup, qr/data-panel="drums"[\s\S]*?data-panel="synth"[\s\S]*?data-panel="notes"/,
	'the two new entries follow Drums in the taskbar');

# --- the registry names six panels -------------------------------------------
like($layout, qr/synth: '#studio_synth',\n\tnotes: '#studio_notes'/,
	'both new windows are registered selectors');
like($layout, qr/var studioPanelNames = \['transport', 'tracks', 'mixer', 'drums', 'synth', 'notes'\]/,
	'the registry order names six panels');
like($layout, qr/synth: 'hide_synth',\n\tnotes: 'hide_notes'/,
	'the legacy Hide setting covers both new panels');

# --- the default and Arrange layout has a box for every name -----------------
like($layout, qr/var synthHeight = Math\.max\(150, Math\.min\(220, Math\.round\(height \* 0\.25\)\)\);/,
	'the wide desk gives the synth a readable band');
like($layout, qr/synth: \{ left: 0, top: synthTop, width: width, height: synthHeight \},/,
	'the synth band spans the desk between the middle band and the console');
like($layout, qr/var notesWidth = Math\.round\(width \* 0\.70\);/,
	'the notes window is 70% of the middle band');
like($layout, qr/var notesHeight = Math\.round\(middleHeight \* 0\.70\);/,
	'the notes window is 70% of the middle band height');
like($layout, qr/left: Math\.round\(\(width - notesWidth\) \/ 2\),\n\t\t\ttop: middleTop \+ Math\.round\(\(middleHeight - notesHeight\) \/ 2\),/,
	'the notes window is centred over the middle band');
like($layout, qr/var synthH = Math\.max\(110, Math\.min\(190, Math\.round\(height \* 0\.22\)\)\);/,
	'the narrow desk gives the synth its own band too');
like($layout, qr/var synthTop = drumsTop \+ drumsH \+ gap;/,
	'the narrow stack puts the synth under the drums');
like($layout, qr/mixer: \{ left: 0, top: mixerTop, width: width, height: mixerH \},\n\t\t\tnotes: \{/,
	'the narrow stack puts the console under the synth, then the notes overlay');
like($layout, qr/if \(name === 'notes' && !saved\) \{ state\.minimized = true; \}/,
	'a first open leaves the notes window minimized');
like($layout, qr/var notes_open = \$\('#studio_notes'\)\.attr\('data-studio-notes-open'\) === '1';/,
	'Arrange reads the note editor open flag');
like($layout, qr/if \(name === 'notes' && !notes_open\) \{ state\.minimized = true; \}/,
	'Arrange keeps the closed note editor minimized');

# --- Ctrl+Alt+1..6 raise all six ---------------------------------------------
like($layout, qr/'1': 'transport', '2': 'tracks', '3': 'mixer', '4': 'drums', '5': 'synth', '6': 'notes'/,
	'the shortcuts name all six panels');
like($layout, qr/if \(key === '0'\) \{ studioPanelToggleAllMinimized\(true\);/, 'Ctrl+Alt+0 still toggles');

# --- the manifest loads the note part ----------------------------------------
like($js, qr/\b19_notes\.js\b[^\n]*-[^\n]*note editor/,
	'the studio index names the note editor part');
like($js, qr/^ {5}19_notes\.js/m, 'the note part sits in the manifest like the others');

# --- the stylesheet gives both windows a box and a scroller ------------------
like($style, qr/#studio_synth,\n\t#studio_notes \{\n\t\tdisplay: flex;\n\t\tflex-direction: column;/,
	'both new panels are flex columns');
like($style, qr/#studio_synth \.studio_synth_body \{\n\t\tflex: 1 1 auto;\n\t\tmin-height: 0;\n\t\toverflow: auto;/,
	'the synth surface scrolls inside the panel');
like($style, qr/#studio_synth \.studio_synth_library \{[^}]*flex-wrap: wrap/s,
	'the library row wraps in a narrow panel');
like($style, qr/#studio_notes #studio_notes_body \{[^}]*flex: 1 1 auto;[^}]*min-height: 0;/s,
	'the note editor body fills its panel');
like($style, qr/\.studio_panel_taskbar \{[^}]*flex-wrap: wrap/s,
	'the six-entry taskbar wraps instead of clipping');
like($notes, qr/data-studio-notes-open="0"/, 'the note editor starts closed');

done_testing();
