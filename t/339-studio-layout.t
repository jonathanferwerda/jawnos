# tests-for: templates/studio/studio.html.ep templates/studio/markup.html.ep templates/studio/style.html.ep public/js/manager/studio.js public/js/manager/studio/03_editing.js public/js/manager/studio/04_knobs.js public/js/manager/studio/06_controls.js public/js/manager/studio/07_layout.js public/js/manager/windows.js public/js/manager/windows/02_fit.js lib/JawnOS/Manager/Part22.pm perl/help/topics_apps.pl t/339-studio-layout.t
# covers:    The Studio layout: a compact panel beside every track with its five
#            controls, four remembered hide toggles, a Dock control and pointer
#            drag/resize handlers, a packing grid where an ordered panel can span
#            one or two columns, a channel-strips panel that scrolls its faders
#            into reach, a jog wheel in the transport's button row, a dynamic
#            track list with Add track / a twice-pressed Delete, and a help topic
#            that names them. Structure only; pixels are not asserted here.

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

my $root = $FindBin::Bin;
$root =~ s{/t$}{};
my $markup = slurp("$root/templates/studio/markup.html.ep");
my $sheet  = slurp("$root/templates/studio/studio.html.ep");
my $style  = slurp("$root/templates/studio/style.html.ep");
my $js     = slurp("$root/public/js/manager/studio.js");
my $edit   = slurp("$root/public/js/manager/studio/03_editing.js");
my $knobs  = slurp("$root/public/js/manager/studio/04_knobs.js");
my $ctrl   = slurp("$root/public/js/manager/studio/06_controls.js");
my $layout = slurp("$root/public/js/manager/studio/07_layout.js");
my $winjs  = slurp("$root/public/js/manager/windows.js");
my $fitjs  = slurp("$root/public/js/manager/windows/02_fit.js");
my $maker  = slurp("$root/lib/JawnOS/Manager/Part22.pm");
my $help   = slurp("$root/perl/help/topics_apps.pl");

# --- one compact panel per track, with its controls -------------------------
like($markup, qr/class="studio_track_panel"/, 'the track row carries a compact panel');
like($markup, qr/class="armed studio_track_arm"[^>]*channel="<%=\s*\$ch\s*%>"/,
	'the panel has the Off/Record/Play/Loop arm control');
like($markup, qr/class="channel_volume studio_track_volume"/,
	'the panel has the existing channel volume control');
like($markup, qr/class="studio_track_fx hover"/, 'the panel has an FX control');
like($markup, qr/class="studio_track_automation hover"/, 'the panel has an automation view toggle');
like($markup, qr/class="studio_track_name"/, 'the panel has an editable name');
like($markup, qr/id="studio_track_row_<%=\s*\$ch\s*%>"/, 'each row is addressable by channel');

# --- four independent hide toggles, each with a setting name ----------------
my %hide = (
	hide_synth           => 'synth',
	hide_channel_strips  => 'mixer',
	hide_transport       => 'transport',
	hide_tracks          => 'tracks',
);
for my $setting (sort keys %hide) {
	like($markup, qr/data-setting="$setting"/, "the $setting toggle is in the markup");
}
like($markup, qr/data-panel="mixer"[^>]*data-setting="hide_channel_strips"/s,
	'the channel-strip toggle names its panel');
like($markup, qr/data-panel="transport"[^>]*data-setting="hide_transport"/s,
	'the transport toggle names its panel');
like($markup, qr/data-panel="tracks"[^>]*data-setting="hide_tracks"/s,
	'the track-listing toggle names its panel');
like($layout, qr/studioHideSettings\s*=\s*\{/s, 'the layout part maps the toggles to settings');
like($layout, qr/studioSetPanelHidden/, 'one function hides and shows a panel');
like($layout, qr/mixer\.settings\[studioHideSettings\[name\]\] = hidden \? 'yes' : 'no'/,
	'the hide choice is stored as a Studio setting');

# --- floating panels: a Dock control and pointer drag for each --------------
for my $panel (qw(synth mixer transport tracks)) {
	like($markup, qr/class="studio_dock hover" data-panel="$panel"/,
		"$panel has a Dock control");
	like($markup, qr/data-studio-drag="$panel"/, "$panel has a drag handle");
}
like($layout, qr/'pointerdown', '\.studio_drag_handle'/, 'dragging starts on pointerdown');
like($layout, qr/'pointermove'/, 'the drag follows pointermove');
like($layout, qr/'pointerup pointercancel'/, 'the drag ends on pointerup');
like($layout, qr/studio_panel_dragging/, 'a dragged panel carries a class');
like($layout, qr/studio_panel_floating/, 'a detached panel carries a class');
like($layout, qr/studio_panel_position_/, 'each panel position is stored as a setting');
like($layout, qr/#studio'\)\.append\(panel\)/, 'a floating panel is positioned inside the Studio window');

# --- dynamic tracks: Add track, Delete twice, cap 32 ------------------------
like($markup, qr/id="studio_add_track"/, 'the Add track control exists');
like($markup, qr/title="[^"]*32[^"]*"/, 'the Add track title states the 32-track cap');
like($markup, qr/class="studio_track_delete hover"/, 'each track has a delete control');
like($markup, qr/class="studio_track_delete hover"[^\n]*armed="no"/, 'delete starts unarmed');
like($layout, qr/button\.attr\('armed'\) != 'yes'/, 'the first delete press only arms the button');
like($layout, qr/studioDeleteTimer/, 'the delete confirmation expires like the house destructive controls');
like($layout, qr/studioRemoveTrack/, 'the second press removes the track');
like($layout, qr/STUDIO_MAX_TRACKS = 32/, 'the layout cap matches the engine');
like($layout, qr/studioChannelEngine\(ch\)/, 'a new track creates its engine channel');
like($layout, qr/studioSaveTrackCount/, 'the track count is persisted');
like($layout, qr/studioEnsureTracksForSong/, 'a loaded song restores its own track rows');
like($style, qr/studio_track_automation_lane/, 'an automation lane exists for the view toggle');
like($style, qr/#studio_mixer_strips[\s\S]*overflow-x: auto/, 'the strips scroll instead of clipping');
like($style, qr/#studio_controls\s*\{[^}]*right:\s*0/s,
	'the transport controls use the panel width instead of reserving a wheel rail');

# --- the pedalboard is a bottom sheet, opened from the layout bar ----------
like($markup, qr/id="studio_pedalboard_close"/, 'the pedalboard has a close control');
like($edit, qr/function studioPedalboardOpen\(show\)/, 'one open/close path serves every control');
like($edit, qr/\$\('#studio_pedals'\)\.attr\('aria-pressed'/, 'the Pedals button follows the sheet');
like($edit, qr/'#studio_pedals, #pedalboard_hamburger'/, 'the Pedals button and the old burger both toggle it');
like($layout, qr/'#studio_pedalboard_close'[\s\S]*studioPedalboardOpen\(false\)/, 'the close control hides the sheet');
like($layout, qr/if \(open\) \{ studioPedalboardOpen\(true\); \}/, 'FX opens the sheet through the same path');
like($edit, qr/studioPedalboardOpen\(true\);[\s\S]*scroller\.scrollLeft/, 'a channel badge opens the sheet and scrolls to the pedal');
like($markup, qr/id="studio_layout_bar"[\s\S]*id="studio_pedals"[^>]*hint="[^"]*Open or close the pedalboard/,
	'the Pedals button sits in the layout bar');
like($markup, qr/id="studio_pedals"[^>]*aria-pressed="false"/, 'the Pedals button starts closed');
like($markup, qr/id="studio_layout_bar"[\s\S]*id="studio_config_toggle"[\s\S]*id="studio_loop"[\s\S]*id="studio_grid"/,
	'Configure and Loop moved into the layout bar');
like($markup, qr/top:190px[\s\S]*id="pedalboard_hamburger"/, 'the old burger stays in the transport');
like($style, qr/#pedalboard\s*\{[^}]*position:\s*absolute/s, 'the pedalboard is a sheet, not a flex row');
like($style, qr/#pedalboard\s*\{[^}]*left:\s*0[^}]*right:\s*0[^}]*bottom:\s*0/s, 'the sheet pins to the window foot');
like($style, qr/#pedalboard\s*\{[^}]*z-index:\s*70002/s, 'the sheet floats above the panels and floats');
like($style, qr/#pedalboard\s*\{[^}]*background-color:\s*#3c200c/s, 'the sheet is opaque');
like($markup, qr/class="studio_pedalboard_bar"[\s\S]*id="studio_pedalboard_close"/,
	'the close control sits in the sheet\'s own bar');
like($markup, qr/id="studio_pedalboard_pedals"/, 'the tiles live in their own scroller');
like($style, qr/#studio_pedalboard_pedals\s*\{[^}]*position:\s*static/s, 'the flex row is static inside the dock');
like($style, qr/#studio_pedalboard_pedals\s*\{[^}]*display:\s*flex/s, 'the tiles are a flex row');
like($style, qr/#studio_pedalboard_pedals\s*\{[^}]*overflow:\s*auto/s, 'the row scrolls sideways and, only if it must, down');
like($style, qr/#studio_pedalboard_pedals\s*\{[^}]*scrollbar-width:\s*thin/s, 'the scrollbar is thin enough for the tile budget');
like($style, qr/\.pedal\s*\{[^}]*flex:\s*0 0 auto/s, 'a tile keeps its width in the row');
like($style, qr/\.pedal\s*\{[^}]*position:\s*relative/s, 'a tile is positioned in the row');
like($style, qr/\.pedal\s*\{[^}]*left:\s*auto/s, 'the fixed left offset is gone');
like($style, qr/\.pedal\s*\{[^}]*height:\s*140px/s, 'every tile is 140px tall');
like($style, qr/#pedalboard\s*\{[^}]*max-height:\s*170px/s, 'the dock fits a 600px-tall window');
like($style, qr/#studio_pedalboard_pedals\s*\{[^}]*max-height:\s*150px/s, 'the tile row keeps within the dock');
like($style, qr/\.pedal_background\s*\{[^}]*object-fit:\s*contain/s, 'the artwork fits inside the tile');
unlike($markup, qr/count\s*\*\s*175/, 'no tile is placed by counted pixels');

# --- overflow is contained, never painted over -----------------------------
like($style, qr/\.studio_grid > div\s*\{[^}]*min-height:\s*0/s, 'every docked panel may shrink');
like($style, qr/\.studio_grid > div\s*\{[^}]*overflow:\s*auto/s, 'every docked panel scrolls its own content');
like($style, qr/#studio_mixer_strips\s*\{[^}]*min-height:\s*0/s, 'the strips block may shrink');
like($style, qr/#studio_viewer\s*\{[^}]*min-height:\s*0/s, 'the track area may shrink');
like($markup, qr/id="studio_mixer_strips"[\s\S]*id="studio_master_rack"[\s\S]*id="studio_transport_panel"/,
	'the master rack is the last child of the strips row');
like($style, qr/\.studio_master_rack\s*\{[^}]*flex:\s*0 0 \d+px/s, 'the master rack is a compact strip');
like($style, qr/\.studio_master_rack\s*\{[^}]*overflow:\s*auto/s, 'the master rack scrolls in place');

# --- Arrange is one button for the DAW-informed arrangement ----------------
like($markup, qr/id="studio_arrange"[^>]*hint="[^"]*Arrange the panels/,
	'the Arrange control names its preset');
like($layout, qr/var studioArrangeWide = \{[\s\S]*?order: \['transport', 'tracks', 'synth', 'mixer'\]/,
	'the wide preset runs transport, timeline, synth, console');
like($layout, qr/var studioArrangeWide = \{[\s\S]*?span: \{ transport: 2, tracks: 2, synth: 1, mixer: 1 \}/,
	'the transport and timeline span the window, the synth and console share the foot');
like($layout, qr/var studioArrangeCompact = \{[\s\S]*?order: \['transport', 'tracks', 'mixer', 'synth'\]/,
	'the compact preset stacks the panels');
like($layout, qr/var studioArrangeCompact = \{[\s\S]*?span: \{ transport: 2, tracks: 2, mixer: 2, synth: 2 \}/,
	'the compact preset gives every panel the full width');
like($layout, qr/function studioApplyArrange\(persist\)/, 'one function applies a preset');
like($layout, qr/\$\(document\)\.on\('click', '#studio_arrange'/, 'the button applies the preset');
like($layout, qr/if \(!any_saved\) \{[\s\S]*?studioApplyArrange\(true\)/,
	'a first open with no saved order starts from the preset');
like($layout, qr/if \(studioPanelElement\(name\)\.hasClass\('studio_panel_floating'\)\) \{[\s\S]*?studioDockPanel\(name, false\)/,
	'Arrange brings a floated panel home');

# --- arranged mode is an explicit DAW grid, left by any manual move --------
like($style, qr/#studio_grid\.studio_arranged\s*\{[\s\S]*?grid-template-rows:\s*auto minmax\(0,\s*1fr\) auto/s,
	'the arranged rows are auto, a dominant timeline, then auto');
like($style, qr/#studio_grid\.studio_arranged\s*\{[\s\S]*?"transport transport transport"[\s\S]*?"tracks tracks synth"[\s\S]*?"mixer mixer mixer"/s,
	'the wide areas run transport, tracks beside the synth, then the console');
like($style, qr/#studio_grid\.studio_arranged > #studio_transport_panel\s*\{[^}]*grid-area:\s*transport !important/s,
	'the transport owns the top area');
like($style, qr/#studio_grid\.studio_arranged > #studio_tracks_panel\s*\{[^}]*grid-area:\s*tracks !important/s,
	'the timeline owns the middle area');
like($style, qr/#studio_grid\.studio_arranged > #studio_mixer\s*\{[^}]*grid-area:\s*mixer !important/s,
	'the console owns the bottom area');
like($style, qr/#studio_grid\.studio_arranged\s*\{[\s\S]*?grid-template-rows:\s*auto minmax\(0,\s*1fr\) auto/s,
	'the console row is auto rather than eating the timeline');
like($style, qr/#studio_grid\.studio_arranged\s*\{[\s\S]*?overflow-y:\s*auto/s,
	'a very short arranged window scrolls the grid instead of clipping an area');
like($style, qr/#studio_grid\.studio_arranged > #studio_mixer\s*\{[^}]*max-height:\s*132px/s,
	'the console keeps its compact auto height');
like($style, qr/#studio_grid\.studio_arranged > #studio_transport_panel\s*\{[^}]*height:\s*96px/s,
	'the transport takes 96px, not a whole equal row');
like($style, qr/#studio_grid\.studio_arranged_compact > #studio_transport_panel\s*\{[^}]*height:\s*88px/s,
	'the compact transport is shorter still');
like($style, qr/#studio_grid\.studio_arranged_compact\s*\{[^}]*grid-template-columns:\s*minmax\(0,\s*1fr\)/s,
	'the compact arranged grid is one column');
like($style, qr/#studio_grid\.studio_arranged_compact\s*\{[\s\S]*?grid-template-rows:\s*auto minmax\(0,\s*1fr\) auto auto/s,
	'the compact rows are transport, timeline, console, synth');
like($style, qr/#studio_grid\.studio_arranged_compact\s*\{[\s\S]*?"transport"[\s\S]*?"tracks"[\s\S]*?"mixer"[\s\S]*?"synth"/s,
	'the compact areas stack in that order');
like($layout, qr/function studioSetArranged\(on, persist\)/, 'one function enters and leaves the mode');
like($layout, qr/function studioExitArrange\(persist\)/, 'leaving the mode has its own helper');
like($layout, qr/studioExitArrange\(true\);\n\tstudioFloatPanel\(name\);/, 'a drag leaves the mode');
like($layout, qr/studioExitArrange\(true\);\n\tstudioDockPanel\(\$\(this\)\.attr\('data-panel'\)\);/, 'a Dock leaves the mode');
like($layout, qr/studioExitArrange\(true\);\n\tstudioPanelSpan\[name\]/, 'a width change leaves the mode');
like($layout, qr/function studioReorderDockedPanel\(name, target\) \{\n\tstudioExitArrange\(true\);/, 'a re-order leaves the mode');
like($layout, qr/studioExitArrange\(true\);\n\tif \(panel\.hasClass\('studio_panel_floating'\)\)/, 'the float control leaves the mode');
like($layout, qr/mixer\.settings\['studio_panel_arranged'\] = on \? 'yes' : 'no'/, 'the mode is remembered as a setting');
like($layout, qr/var arranged = String\([\s\S]*?studio_panel_arranged[\s\S]*?== 'yes'/, 'a reopen follows the remembered mode');
like($layout, qr/if \(arranged && !\$\('\.studio_panel_floating'\)\.length\)/, 'a saved float hands the grid back');
like($layout, qr/toggleClass\('studio_arranged_compact', studioIsNarrow\(\)\)/, 'a resize re-evaluates the compact mode');
like($help, qr/Arrange is a mode, not a lock/, 'help says Arrange is a mode that manual moves leave');
like($help, qr/the track timeline takes the large middle with the synth beside it/, 'help describes the arranged areas');

# --- the Studio window opens at a desk size and stays inside itself --------
like($maker, qr/%app_default_size\s*=\s*\(\s*studio\s*=>\s*\{\s*width\s*=>\s*1000,\s*height\s*=>\s*760/,
	'Studio asks the window helper for a 1000x760 default');
like($maker, qr/default_width="' \. \$default_width \. '" default_height="' \. \$default_height \. '"/,
	'the window element carries its default size for the tile joiner');
like($winjs, qr/win\.attr\('default_width'\)\) \|\| windowTileDefaultWidth/,
	'the tile joiner uses the app default and keeps 480 as the fallback');
like($style, qr/\.wind\[app="studio"\]\s*\{\s*z-index:\s*39999 !important/s,
	'Studio is above the dock and taskbar');
like($markup, qr/id="studio_tracks_panel"[\s\S]*id="studio_track_container"[\s\S]*id="studio_mixer"/,
	'the hidden media container lives inside the track area');
like($style, qr/#studio_track_container\s*\{[^}]*width:\s*1px[^}]*overflow:\s*hidden/s,
	'the hidden media container is clipped');
unlike($style, qr/#studio_track_container\s*\{[^}]*right:\s*-130px/s,
	'the old off-window track container is gone');
like($style, qr/#studio_transport_panel\s*\{[^}]*overflow:\s*auto/s,
	'the transport clips or scrolls its own content');
like($markup, qr/id="studio_transport_panel"[\s\S]*id="studio_controls"[\s\S]*id="studio_time_display"/,
	'the control row and time display are inside the transport panel');
like($layout, qr/function studioClampPanelPosition/,
	'a saved float position has a clamp helper');
like($layout, qr/studioFloatPanel\(name, position, false\)/,
	'applying a saved position goes through the clamp');
like($layout, qr/\$\(window\)\.on\('resize'[\s\S]*studioClampPanelPosition/,
	'a resize re-clamps floating panels');

# --- the packing grid, scrolling strips, resize grip and jog wheel row -----
like($markup, qr/id="studio_grid"/, 'the four docked panels share a grid container');
like($style, qr/grid-auto-flow:\s*dense/, 'auto-flow dense packs the panels into the gaps');
like($style, qr/grid-column:\s*span/, 'a panel is sized by a column span');
like($style, qr/grid-auto-rows:\s*minmax\(0,\s*1fr\)/, 'the implicit rows share the desk height');
unlike($style, qr/\.studio_grid\s*\{[^}]*grid-template-areas/s,
	'the manual grid still has no fixed named cells');
like($style, qr/#studio_grid\.studio_arranged\s*\{[^}]*grid-template-areas/s,
	'the arranged grid names its cells');
unlike($style, qr/^\s*#studio_mixer\s*\{[^}]*grid-area:/ms,
	'the channel strips are not pinned to a fixed cell by their own rule');
unlike($style, qr/^\s*#studio_transport_panel\s*\{[^}]*grid-area:/ms,
	'the transport is not pinned to a fixed cell by its own rule');
like($style, qr/#studio_mixer_strips\s*\{[^}]*overflow-y:\s*auto/s,
	'the strips panel scrolls vertically so every fader is reachable');
like($style, qr/#studio_mixer_strips\s*\{[^}]*overflow-x:\s*auto/s,
	'many strips still scroll sideways');
like($layout, qr/studioReorderDockedPanel/, 'a docked panel dropped on another is inserted before it');
like($layout, qr/studioPanelOrder\.splice\(to, 0, name\)/, 'the dropped panel moves into the target position');
like($layout, qr/function studioApplyPanelOrder/, 'the shared order is applied to the grid items');
like($layout, qr/order:\s*studioPanelOrderIndex\(name\)/, 'a docked panel saves its order');

# --- the width control gives a docked panel a second column ----------------
for my $panel (qw(synth mixer transport tracks)) {
	like($markup, qr/class="studio_span_toggle hover" data-panel="$panel"/,
		"$panel has a Narrow/Wide control");
}
like($markup, qr/&subs::ui\('Wide'\)/, 'the width control starts in its translatable narrow state');
like($layout, qr/studioApplyPanelSpan/, 'one function applies a panel span');
like($layout, qr/studioPanelSpan\[name\] = \(studioPanelSpanValue\(name\) >= STUDIO_PANEL_MAX_SPAN\)/,
	'the control cycles one and two columns');
like($layout, qr/grid-column', 'span ' \+ span/, 'the span reaches the grid');
like($layout, qr/span:\s*studioPanelSpanValue\(name\)/, 'the span is persisted with the order');
like($style, qr/\.studio_panel_floating \.studio_span_toggle\s*\{\s*display:\s*none/s,
	'a floated panel hides the width control');

# --- drag moves both axes and keeps the box ---------------------------------
like($layout, qr/left: clamped\.left \+ 'px', top: clamped\.top \+ 'px'/,
	'the drag writes both left and top');
like($layout, qr/function studioPanelBox[\s\S]*left:[\s\S]*top:[\s\S]*width:[\s\S]*height:/s,
	'the saved box is left, top, width and height');
like($layout, qr/studioPersistPanelPosition\(drag\.name, studioFloatState/,
	'the drag persists width and height with the position');
like($layout, qr/if \(!drag\.wasFloating && e\.type == 'pointerup'\)/,
	'only a panel that started docked can swap cells');

# --- the resize grip --------------------------------------------------------
like($markup, qr/class="studio_resize_handle" data-studio-resize="mixer"/,
	'the channel strips have a resize grip');
like($markup, qr/data-studio-resize="transport"/, 'the transport has a resize grip');
like($layout, qr/'pointerdown', '\.studio_resize_handle'/,
	'a resize starts on the grip');
like($layout, qr/studioPanelResize/, 'the resize is tracked while the pointer moves');
like($layout, qr/studioPersistPanelPosition\(resize\.name, studioFloatState/,
	'the resize persists width and height');
like($style, qr/\.studio_panel_floating \.studio_resize_handle\s*\{\s*display:\s*block/, 
	'the grip appears only on a floated panel');

# --- the jog wheel shares the transport row --------------------------------
like($markup, qr/id="studio_controls"[\s\S]*class="studio_transport_row"[\s\S]*id="studio_jog_wheel"/s,
	'the jog wheel sits in the transport button row');
like($style, qr/\.studio_transport_row\s*\{[^}]*display:\s*flex/s,
	'the buttons and wheel share one flex row');
unlike($style, qr/#studio_jog_wheel\s*\{[^}]*right:/s,
	'the wheel no longer hangs off the panel\'s right edge');

# --- full screen is the window's shared control, not a Studio gesture -------
unlike($winjs, qr/studioWindowFullSelector/, 'no double-press is bound to the maximize control');
unlike($style, qr/window_full_viewport/, 'Studio keeps no full-viewport rule of its own');
like($fitjs, qr/windowFullViewportEnter/, 'the window keeps its own full-view control');
like($help, qr/full-screen button - behind the app icon/, 'the help names the shared full-screen button');

# --- the help topic names the new controls ----------------------------------
like($help, qr/'Add a track, up to 32'/, 'help names Add track and its cap');
like($help, qr/Arrange the panels/, 'help names the Arrange control');
like($help, qr/Every docked panel is its own scroll box/, 'help explains the no-overflow rule');
like($help, qr/the master rack is the strips\\' last strip on the right/, 'help puts the master strip at the far right');
like($help, qr/Show automation for this track/, 'help names the automation toggle');
like($help, qr/Delete this track/, 'help names the per-track delete');
like($help, qr/Hide the channel strips/, 'help names the strip hide toggle');
like($help, qr/Hide the transport/, 'help names the transport hide toggle');
like($help, qr/Hide the track listing/, 'help names the track hide toggle');
like($help, qr/Dock the tracks/, 'help names the Dock control');
like($help, qr/Close the pedalboard/, 'help names the pedalboard close');
like($help, qr/Open or close the pedalboard/, 'help names the Pedals button');
like($help, qr/The Pedals button in the layout bar opens the pedalboard as a 170px sheet/,
	'help describes the sheet over the console');
like($help, qr/Every track has a compact panel/, 'help describes the per-track panel');
like($help, qr/Drag to resize this panel/, 'help names the floated panel resize grip');
like($help, qr/pack into a two-column grid/, 'help describes the packing grid');
like($help, qr/Narrow\/Wide control/, 'help names the width control');
like($help, qr/Drop a dragged docked panel/, 'help describes dropping a docked panel');
like($help, qr/sits beside the strips/, 'help describes the transport beside the strips');
like($help, qr/jog wheel shares the transport/, 'help describes the jog wheel in the button row');

# --- the old fixed count is gone --------------------------------------------
unlike($sheet, qr/\|\|\s*4\b/, 'the page no longer falls back to four tracks');
unlike($knobs, qr/channel_count[^\n]*\|\|\s*4\b/, 'the initialiser no longer falls back to four tracks');
like($sheet, qr/\|\|\s*1\b/, 'the page starts with one track');
like($markup, qr/data-max-tracks="<%=\s*\$max_tracks\s*%>"/, 'the viewer carries the dynamic cap');
unlike($markup, qr/channel_count\s*\|\|\s*4\b/, 'the markup no longer fixes the track count at four');

# --- the split manifest names the new part ----------------------------------
like($js, qr/07_layout\.js/, 'the studio index names the layout part');
like($ctrl, qr/studioSyncTrackList/, 'loading a song restores the tracks it was saved with');
like($edit, qr/'channel_count', 'value': '1'/, 'New song asks for a single track');

done_testing();
