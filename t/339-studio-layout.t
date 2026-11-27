# tests-for: templates/studio/studio.html.ep templates/studio/markup.html.ep templates/studio/style.html.ep templates/studio/drums.html.ep public/js/manager/studio.js public/js/manager/studio/03_editing.js public/js/manager/studio/04_knobs.js public/js/manager/studio/05_inputs.js public/js/manager/studio/06_controls.js public/js/manager/studio/07_layout.js public/js/manager/studio/09_pedals.js public/js/manager/studio/11_drums.js public/js/manager/windows.js public/js/manager/windows/02_fit.js public/js/manager/taskbar.js lib/JawnOS/Manager/Part22.pm perl/help/topics_apps.pl t/339-studio-layout.t
# covers:    The Studio layout as six interior panel windows: a taskbar in the
#            top bar, a title bar with Minimize and Maximize, a drag handle, a
#            corner resize grip and a remembered box for the transport, the
#            tracks, the channels, the drums, the synth and the notes; the
#            panel stack raises on a press and the taskbar restores or
#            minimizes; the compact per-track panel with its controls; a dynamic
#            track list with Add track and a twice-pressed Delete; the pedalboard
#            as the one FX surface; a help topic that names the new controls; and
#            a Studio window that follows the shared window stack instead of
#            pinning its own z-index. Structure only; pixels are not asserted here.

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
my $markup  = slurp("$root/templates/studio/markup.html.ep");
my $drums   = slurp("$root/templates/studio/drums.html.ep");
my $sheet   = slurp("$root/templates/studio/studio.html.ep");
my $style   = slurp("$root/templates/studio/style.html.ep");
my $js      = slurp("$root/public/js/manager/studio.js");
my $edit    = slurp("$root/public/js/manager/studio/03_editing.js");
my $knobs   = slurp("$root/public/js/manager/studio/04_knobs.js");
my $ctrl    = slurp("$root/public/js/manager/studio/06_controls.js");
my $inputs  = slurp("$root/public/js/manager/studio/05_inputs.js");
my $layout  = slurp("$root/public/js/manager/studio/07_layout.js");
my $pedals  = slurp("$root/public/js/manager/studio/09_pedals.js");
my $drumsjs = slurp("$root/public/js/manager/studio/11_drums.js");
my $winjs   = slurp("$root/public/js/manager/windows.js");
my $fitjs   = slurp("$root/public/js/manager/windows/02_fit.js");
my $taskbar = slurp("$root/public/js/manager/taskbar.js");
my $maker   = slurp("$root/lib/JawnOS/Manager/Part22.pm");
my $help    = slurp("$root/perl/help/topics_apps.pl");
my $all     = $markup . $drums;

# --- one compact panel per track, with its controls -------------------------
like($markup, qr/class="studio_track_panel"/, 'the track row carries a compact panel');
like($markup, qr/class="armed studio_track_arm"[^>]*channel="<%=\s*\$ch\s*%>"/,
	'the panel has the Off/Record/Play/Loop arm control');
like($markup, qr/class="channel_volume studio_track_volume"/,
	'the panel has the existing channel volume control');
like($markup, qr/class="studio_track_fx hover"/, 'the panel has an FX control');
like($markup, qr/class="channel_jacks"[\s\S]*?studio_jack[\s\S]*?studio_cord/,
	'the channel\'s output cord sits beside its input jack');
like($style, qr/\.channel_jacks\s*\{[^}]*flex-direction:\s*row/s, 'the two jacks share one row');
like($markup, qr/class="studio_track_automation hover"/, 'the panel has an automation view toggle');
like($markup, qr/class="studio_track_name"/, 'the panel has an editable name');
like($markup, qr/id="studio_track_row_<%=\s*\$ch\s*%>"/, 'each row is addressable by channel');

# --- the top bar is the panels' taskbar -------------------------------------
like($markup, qr/id="studio_panel_taskbar"[^>]*class="studio_panel_taskbar"/,
	'the layout bar carries the panel taskbar');
like($markup, qr/id="studio_layout_bar"[\s\S]*id="studio_arrange"[\s\S]*id="studio_panel_taskbar"[\s\S]*id="studio_add_track"/,
	'the taskbar sits between Arrange and Add track');
for my $panel (qw(transport tracks mixer drums synth notes)) {
	like($markup, qr/class="studio_panel_task hover" data-panel="$panel"/,
		"$panel has a taskbar entry");
}
like($markup, qr/class="studio_panel_task hover"[^>]*hint="<%= &subs::ui\('Show this panel, or minimize it'\) %>"/,
	'the taskbar entry says what a press does');
like($style, qr/\.studio_panel_taskbar\s*\{[^}]*display:\s*flex/s, 'the taskbar is a flex row');
like($style, qr/\.studio_panel_taskbar\s*\{[^}]*overflow-x:\s*auto/s, 'a long taskbar scrolls');
like($style, qr/\.studio_panel_taskbar button\.studio_task_active\s*\{/s,
	'the front panel wears the active state');
like($style, qr/\.studio_panel_taskbar button\.studio_task_minimized\s*\{/s,
	'a minimized panel reads as minimized in the taskbar');

# --- every panel is an interior window with its own controls ----------------
for my $panel (qw(tracks mixer transport)) {
	like($markup, qr/class="studio_panel_min hover" data-panel="$panel"[^>]*hint="<%= &subs::ui\('Minimize this panel'\) %>"/,
		"$panel has a Minimize button");
	like($markup, qr/class="studio_panel_max hover" data-panel="$panel"[^>]*hint="<%= &subs::ui\('Maximize or restore this panel'\) %>"/,
		"$panel has a Maximize button");
	like($markup, qr/data-studio-drag="$panel"/, "$panel has a drag handle");
	like($markup, qr/class="studio_resize_handle" data-studio-resize="$panel"/,
		"$panel has a resize grip");
}
like($drums, qr/data-studio-drag="drums"/, 'the drums have a drag handle');
like($drums, qr/class="studio_panel_min hover" data-panel="drums"/, 'the drums have a Minimize button');
like($drums, qr/class="studio_panel_max hover" data-panel="drums"/, 'the drums have a Maximize button');
like($drums, qr/class="studio_resize_handle" data-studio-resize="drums"/,
	'the drums have a resize grip');
like($markup, qr/class="studio_panel_buttons"/, 'the title-bar buttons share a group');
like($style, qr/\.studio_panel_buttons\s*\{[^}]*margin-left:\s*auto/s,
	'the buttons sit at the far end of the title bar');
unlike($all, qr/studio_dock|studio_span_toggle|studio_width_handle|studio_hide_toggle|studio_float_toggle/,
	'the old Dock, Narrow/Wide, width grip, Hide and Float controls are gone');
unlike($all, qr/Dock the (?:tracks|drums|transport|channel strips)/,
	'the old Dock labels are gone');
unlike($all, qr/Float the (?:channel strips|transport|track listing|drums)/,
	'the old Float labels are gone');

for my $panel (qw(tracks mixer transport)) {
	like($markup, qr/class="studio_panel_bottom" data-studio-bottom="$panel"/,
		"$panel has a bottom edge grip");
}
like($drums, qr/class="studio_panel_bottom" data-studio-bottom="drums"/,
	'the drums have a bottom edge grip');
like($style, qr/\.studio_panel_bottom[\s\S]*?z-index:\s*30/s, 'the edge grip sits above the panel content');
like($style, qr/\.studio_panel_bottom\s*\{[^}]*ns-resize/s, 'the bottom edge resizes height');
like($style, qr/\.studio_resize_handle\s*\{[^}]*z-index:\s*31/s,
	'the corner grip stays above a track bottom grip');
like($layout, qr/function studioPanelBeginResize\(name, panel, e, axis, handle\)/,
	'one function begins a panel resize');
like($layout, qr/'pointerdown', '\.studio_panel_bottom'/, 'the bottom edge is wired');
like($layout, qr/studioPanelBeginResize\(name, panel, e, 'y', this\)/, 'the bottom edge is height-only');
like($layout, qr/studioPanelResize\.axis === 'y'/, 'the drag keeps width on a height-only resize');

# --- right-click presets and keyboard shortcuts ----------------------------
like($layout, qr/function studioCascadeWindows\(persist\)/, 'Cascade is its own preset');
like($layout, qr/state\.left = left;\n\t\tstate\.top = top;/, 'Cascade steps every window down and right');
like($layout, qr/function studioPanelToggleAllMinimized\(persist\)/, 'one function toggles every window');
like($layout, qr/function studioPanelMenu\(x, y\)/, 'the taskbar has its own menu');
like($layout, qr/data-studio-panel-action/, 'each menu row names its action');
like($layout, qr/row\('tile', 'Tile all'\)/, 'the menu offers Tile all');
like($layout, qr/row\('cascade', 'Cascade'\)/, 'the menu offers Cascade');
like($layout, qr/row\('minimize', studioPanelAnyVisible\(\) \? 'Minimize all' : 'Restore all'\)/,
	'the menu toggles Minimize all / Restore all');
like($layout, qr/'contextmenu', '#studio_panel_taskbar'/, 'a right-click on the taskbar opens the menu');
like($layout, qr/'.studio_panel_menu \.studio_menu_row'/, 'the menu rows are wired');
like($layout, qr/if \(!e\.ctrlKey \|\| !e\.altKey \|\| e\.metaKey \|\| e\.shiftKey\) \{ return; \}/,
	'the shortcut handler requires Ctrl+Alt and no other modifier');
like($layout, qr/'1': 'transport', '2': 'tracks', '3': 'mixer', '4': 'drums', '5': 'synth', '6': 'notes'/,
	'Ctrl+Alt+1..6 name the six panels');
like($layout, qr/if \(key === '0'\) \{ studioPanelToggleAllMinimized\(true\);/, 'Ctrl+Alt+0 toggles all');
like($layout, qr/if \(key === 't'\) \{ studioArrangeWindows\(true\);/, 'Ctrl+Alt+T tiles');
like($layout, qr/if \(key === 'c'\) \{ studioCascadeWindows\(true\);/, 'Ctrl+Alt+C cascades');
like($layout, qr/function studioPanelShortcutTyping\(e\)/, 'typing in a field does not fire a preset');
like($help, qr/right-click menu/, 'help names the taskbar menu');
like($help, qr/Ctrl\+Alt\+1 to Ctrl\+Alt\+6/, 'help names the panel shortcuts');
like($help, qr/Ctrl\+Alt\+T tiles and Ctrl\+Alt\+C cascades/, 'help names the tile/cascade shortcuts');
like($help, qr/The bottom edge resizes the window/, 'help names the bottom edge grip');

# --- the stylesheet makes each panel a window on a desk ---------------------
like($style, qr/\.studio_panel\s*\{[^}]*position:\s*absolute/s, 'a panel is positioned on the desk');
like($style, qr/\.studio_panel\s*\{[^}]*display:\s*flex/s, 'a panel stacks its title bar over its content');
like($style, qr/\.studio_panel\s*\{[^}]*overflow:\s*hidden/s, 'a panel clips to its own box');
like($style, qr/\.studio_panel\s*\{[^}]*border-radius:\s*8px/s, 'a panel reads as its own window');
like($style, qr/\.studio_grid\s*\{[^}]*position:\s*relative/s, 'the grid is the desk');
like($style, qr/\.studio_grid\s*\{[^}]*overflow:\s*hidden/s, 'the desk contains every window');
like($style, qr/\.studio_panel\.studio_panel_minimized\s*\{\s*display:\s*none/s,
	'minimizing hides the window');
like($style, qr/\.studio_panel\s*\{[^}]*padding-bottom:\s*6px/s,
	'the bottom grip gets its own strip below the content');
like($style, qr/\.studio_panel\.studio_panel_maximized\s*\{/s, 'a maximized window has its own state');
like($style, qr/\.studio_panel\.studio_panel_raised\s*\{/s, 'the front window is marked');
like($style, qr/\.studio_panel_dragging\s*\{[^}]*opacity/s, 'a dragged window reads as moving');
like($style, qr/\.studio_resize_handle\s*\{[^}]*nwse-resize/s, 'the corner grip resizes both axes');
like($style, qr/\.studio_drag_handle\s*\{[^}]*cursor:\s*var\(--jawnos-cursor-grab/s,
	'the title handle shows the grabbing cursor');
like($style, qr/\.studio_panel_bar \.studio_drag_handle\s*\{[^}]*flex:\s*1 1 auto/s,
	'the title handle spans the bar so the empty room drags');
like($style, qr/\.studio_panel_bar\s*\{[^}]*flex-wrap:\s*wrap/s, 'a short panel title bar wraps');
like($style, qr/#studio_transport_panel\s*\{[^}]*overflow:\s*hidden/s,
	'the transport title bar stays put');
like($style, qr/#studio_controls\s*\{[^}]*overflow:\s*auto/s, 'the transport controls scroll inside');
like($style, qr/#studio_tracks_panel\s*\{[^}]*overflow:\s*hidden/s,
	'the tracks title bar stays put');
like($style, qr/#studio_mixer_strips\s*\{[^}]*overflow-x:\s*auto/s, 'the strips scroll sideways');
like($style, qr/#studio_mixer_strips\s*\{[^}]*overflow-y:\s*auto/s, 'the strips scroll vertically');
unlike($style, qr/studio_panel_floating|studio_grid_row|studio_arranged|studio_drums_open|studio_width_handle|studio_dock\b|studio_span_toggle/,
	'the old packing and float rules are gone');

# --- the Studio window follows the shared z-index stack --------------------
# The old rule pinned the window at 39999 !important. That kept it above the
# dock, but it also wrote the value into every restored stack, so every other
# window rose past it and Studio could never be raised again.
unlike($style, qr/\.wind\[app="studio"\]/, 'Studio no longer pins its window z-index');
unlike($style, qr/z-index:\s*39999\s*!important/, 'the sticky z-index override is gone');
like($maker, qr/%app_default_size\s*=\s*\(\s*studio\s*=>\s*\{\s*width\s*=>\s*1000,\s*height\s*=>\s*760/,
	'Studio asks the window helper for a 1000x760 default');
like($maker, qr/default_width="' \. \$default_width \. '" default_height="' \. \$default_height \. '"/,
	'the window element carries its default size for the tile joiner');
like($winjs, qr/win\.attr\('default_width'\)\) \|\| windowTileDefaultWidth/,
	'the tile joiner uses the app default and keeps 480 as the fallback');

# --- the window always has a drag handle -----------------------------------
like($markup, qr/class="studio_window_grip hover"[^>]*hint="<%= &subs::ui\('Drag to move the Studio window'\) %>"/,
	'the layout bar carries a window drag grip');
like($style, qr/\.studio_window_grip\s*\{[^}]*cursor:\s*var\(--jawnos-cursor-grab/s,
	'the grip shows the grab cursor');
like($fitjs, qr/win\.attr\('app'\) === 'studio' && win\.hasClass\('ui-draggable'\)/,
	'Studio gets its own drag handle option');
like($fitjs, qr/'\.top_navbar, \.studio_window_grip'/, 'the title bar and the app-bar grip both drag the window');
like($fitjs, qr/winTop < top_limit/, 'the fit keeps a title bar below a top bar');
like($fitjs, qr/if \(box\) \{[\s\S]*?windowFit\(win\);/, 'leaving full screen fits the window again');
like($taskbar, qr/\.each\(function \(\) \{ windowFit\(\$\(this\)\); \}\)/,
	'a bar move re-fits every window');
like($maker, qr/defined \$settings->\{'dimensions'\}->\{'left'\}/,
	'a window with no saved place still gets a valid left');
unlike($maker, qr/left:' \. \(\$settings->\{'dimensions'\}->\{'left'\}\) \. 'px'/,
	'the undefined left is never written as left:px');

# --- one layout engine owns the panel windows -------------------------------
like($layout, qr/var studioPanelNames = \['transport', 'tracks', 'mixer', 'drums', 'synth', 'notes'\]/,
	'the panels have a fixed taskbar order');
like($layout, qr/function studioPanelElement\(name\)/, 'one helper finds a panel');
like($layout, qr/function studioPanelStateFor\(name\)/, 'one helper owns a panel state');
like($layout, qr/function studioDefaultPanelLayout\(size\)/, 'one preset places the panels');
like($layout, qr/function studioArrangeWindows\(persist\)/, 'Arrange applies that preset');
like($layout, qr/'#studio_arrange'/, 'the Arrange button runs the preset');
like($layout, qr/function studioApplyPanelGeometry\(name\)/, 'one function applies a panel box');
like($layout, qr/function studioCapturePanelBox\(name\)/, 'a moved window records its box');
like($layout, qr/function studioPersistPanelState\(name\)/, 'a window box is saved');
like($layout, qr/'studio_panel_position_' \+ name/, 'the box is one setting per panel');
like($layout, qr/minimized: !!state\.minimized/, 'the minimized state is saved with the box');
like($layout, qr/maximized: !!state\.maximized/, 'the maximized state is saved with the box');
like($layout, qr/function studioLoadPanelStates\(\)/, 'saved states are restored');
like($layout, qr/studioLegacyHidden/, 'the old Hide setting is read once on upgrade');
like($layout, qr/function studioRaisePanel|function studioPanelRaise\(name\)/, 'one function raises a panel');
like($layout, qr/studioPanelZ \+= 1/, 'the panel stack climbs');
like($layout, qr/function studioPanelFront\(\)/, 'one helper reads the front panel');
like($layout, qr/function studioPanelTaskbarRefresh\(\)/, 'one helper paints the taskbar');
like($layout, qr/function studioPanelSetMinimized\(name, minimized, persist\)/,
	'one function minimizes and restores');
like($layout, qr/function studioPanelToggleMaximized\(name, persist\)/,
	'one function maximizes and restores');
like($layout, qr/click', '\.studio_panel_min'/, 'the Minimize button is wired');
like($layout, qr/click', '\.studio_panel_max'/, 'the Maximize button is wired');
like($layout, qr/click', '\.studio_panel_task'/, 'the taskbar is wired');
like($layout, qr/studioPanelFront\(\) === name/, 'the front panel minimizes from the taskbar');
like($layout, qr/studioPanelSetMinimized\(name, false, true\);[\s\S]*?studioPanelRaise\(name\);/,
	'a minimized panel comes back raised');
like($layout, qr/'pointerdown', '\.studio_drag_handle'/, 'dragging starts on pointerdown');
like($layout, qr/'pointerdown', '\.studio_resize_handle'/, 'resizing starts on pointerdown');
like($layout, qr/'pointermove'/, 'the drag and resize follow pointermove');
like($layout, qr/'pointerup pointercancel'/, 'the drag and resize end on pointerup');
like($layout, qr/'pointerdown', '\.studio_panel'/, 'a press inside a panel raises it');
like($layout, qr/function studioPanelBox\(/, 'one clamp keeps a window on the desk');
like($layout, qr/function studioPanelClampAll\(\)/, 'a window is pulled back onto the desk');
like($layout, qr/studioPanelObserveDesk\(\)/, 'a desk resize re-clamps the windows');
like($layout, qr/ResizeObserver/, 'the desk resize is observed');
like($layout, qr/function studioSnapTo\(value, candidates\)/, 'a drag snaps to the grid');
like($layout, qr/studioSnapTo\(studioPanelResize\.width/, 'a resize snaps both axes');
like($layout, qr/if \(state\.maximized\) \{\s*state\.maximized = false;/, 'dragging restores a maximized window first');
unlike($layout, qr/studio_panel_floating|studioManualReflow|studioExitArrange|studioSetPanelHidden|studioFloatPanel|studioDockPanel/,
	'the old float/dock/packing engine is gone');

# --- Arrange lays the windows in the DAW order ------------------------------
like($layout, qr/var transportHeight = Math\.max\(112, Math\.min\(120/, 'the transport window keeps a band tall enough for the jog wheel and the two-line clock');
like($layout, qr/drums: \{ left: tracksWidth \+ gap, top: middleTop/, 'the drums sit beside the timeline');
like($layout, qr/mixer: \{ left: 0, top: height - mixerHeight/, 'the console sits at the foot');
like($layout, qr/if \(width < 720\)/, 'a narrow desk stacks the windows');
like($layout, qr/synth: \{ left: 0, top: synthTop, width: width, height: synthHeight \},\n\t\tmixer/,
	'the synth is a full-width band above the console');
# Arrange restores every window except the note editor, which only counts as
# open when a clip is loaded; otherwise it would cover the tracks and drums.
like($layout, qr/var notes_open = \$\('#studio_notes'\)\.attr\('data-studio-notes-open'\) === '1';/,
	'Arrange asks whether a note clip is open');
like($layout, qr/if \(name === 'notes' && !notes_open\) \{ state\.minimized = true; \}/,
	'Arrange leaves the closed note editor minimized');
like($layout, qr/state\.minimized = false;\n\t\tstate\.maximized = false;\n\t\tif \(name === 'notes' && !notes_open\)/,
	'Arrange brings the other windows back');
like($help, qr/Arrange, beside the panel taskbar/, 'help describes Arrange beside the taskbar');
like($help, qr/the drum machine sits beside it/, 'help puts the drums beside the timeline');

# --- dynamic tracks: Add track, Delete twice, cap 32 ------------------------
like($markup, qr/id="studio_add_track"/, 'the Add track control exists');
like($markup, qr/title="[^"]*32[^"]*"/, 'the Add track title states the 32-track cap');
unlike($markup, qr/class="studio_track_delete/, 'the panel no longer carries its own Delete button');
like($layout, qr/row\('delete', 'Delete track'\)/, 'Delete lives in the track panel menu');
like($layout, qr/data-armed'\) !== 'yes'/, 'the first delete press only arms the menu row');
like($layout, qr/studio_menu_delete_armed/, 'the armed row turns red');
like($layout, qr/studioDeleteTimer/, 'the delete confirmation expires like the house destructive controls');
like($layout, qr/studioRemoveTrack\(ch\)/, 'the second press removes the track');
like($style, qr/\.studio_track_menu \.studio_menu_row\[data-studio-track-action="delete"\]\s*\{[^}]*margin-top:\s*10px/s,
	'Delete is set apart from Channel out');
like($layout, qr/STUDIO_MAX_TRACKS = 32/, 'the layout cap matches the engine');
like($layout, qr/studioChannelEngine\(ch\)/, 'a new track creates its engine channel');
like($layout, qr/studioSaveTrackCount/, 'the track count is persisted');
like($layout, qr/studioEnsureTracksForSong/, 'a loaded song restores its own track rows');
like($style, qr/studio_track_automation_lane/, 'an automation lane exists for the view toggle');

# --- the pedalboard is a bottom sheet, opened from the layout bar ----------
like($markup, qr/id="studio_pedalboard_close"/, 'the pedalboard has a close control');
like($edit, qr/function studioPedalboardOpen\(show\)/, 'one open/close path serves every control');
unlike($edit, qr/#studio_pedals/, 'no Pedals button is left to mirror');
unlike($edit, qr/pedalboard_hamburger/, 'the transport burger is gone from the open path');
like($layout, qr/'#studio_pedalboard_close'[\s\S]*studioPedalboardOpen\(false\)/, 'the close control hides the sheet');
like($layout, qr/studioPedalboardOpen\(true\)/, 'FX opens the sheet rather than toggling it');
like($layout, qr/click', '\.studio_track_fx'[\s\S]*?studioRackRender\(ch\)[\s\S]*?studioPedalboardOpen\(true\);/,
	'FX selects the track, draws its chain and opens the pedalboard');
unlike($layout, qr/studio_fx_open/, 'FX no longer opens a rack inside the track row');
like($markup, qr/id="studio_layout_bar"[\s\S]*id="studio_audio_path"[^>]*hint="[^"]*Which side is recording and playing/,
	'the Engine/Browser badge sits where the Pedals button was');
unlike($markup, qr/id="studio_pedals"/, 'the layout bar has no Pedals button');
unlike($markup, qr/id="pedalboard_hamburger"/, 'the transport carries no pedalboard button');
like($markup, qr/class="studio_transport_row"[\s\S]*id="studio_time_display"[\s\S]*id="studio_loop"/,
	'the repeat button now lives in the transport, after the clock');
like($markup, qr/id="studio_layout_bar"[\s\S]*id="studio_config_toggle"[\s\S]*id="studio_audio_path"/,
	'Configure and the Engine/Browser badge share the layout bar');
like($style, qr/#pedalboard\s*\{[^}]*position:\s*absolute/s, 'the pedalboard is a sheet, not a flex row');
like($style, qr/#pedalboard\s*\{[^}]*left:\s*0[^}]*right:\s*0[^}]*bottom:\s*0/s, 'the sheet pins to the window foot');
like($style, qr/#pedalboard\s*\{[^}]*z-index:\s*70002/s, 'the sheet floats above the panels and windows');
like($style, qr/#pedalboard\s*\{[^}]*background-color:\s*var\(--panel-2\)/s, 'the sheet is opaque');
like($markup, qr/class="studio_pedalboard_bar"[\s\S]*id="studio_palette_effect"/,
	'the effect palette select sits in the sheet\'s own bar');
like($markup, qr/class="studio_pedalboard_bar"[\s\S]*id="studio_palette_add"/,
	'the Add button sits beside the palette select');
my @racks = $markup =~ /class="studio_channel_rack"/g;
is(scalar(@racks), 1, 'the markup carries exactly one chain container');
like($markup, qr/id="pedalboard"[\s\S]*?class="studio_pedalboard_bar"[\s\S]*?id="studio_palette_add"[\s\S]*?id="studio_pedalboard_rack"/,
	'the Add palette sits in the bar above the chain it adds to');
like($pedals, qr/var holder = \$\('#studio_pedalboard_rack'\);/, 'the rack renders into the pedalboard');
for my $action (qw(studio_rack_led studio_rack_bypass studio_rack_up studio_rack_down studio_rack_remove)) {
	like($pedals, qr/'\.$action/, "the rack keeps its $action action");
}

# --- the track panel never bleeds over the canvas ---------------------------
like($markup, qr/class="studio_track_line studio_track_actions"/,
	'FX and Monitor have their own line under the volume, with Auto on the next');
my @action_lines = $markup =~ /class="studio_track_line studio_track_actions"/g;
is(scalar(@action_lines), 2, 'two action lines: FX and Monitor, then Auto');
like($style, qr/\.studio_track_fx,\s*\n\s*\.studio_track_monitor\s*\{[^}]*font-size:\s*12px/s,
	'FX and Monitor are a little bigger than the other panel buttons');
like($style, qr/\.studio_track_panel\s*\{[^}]*overflow:\s*hidden/s,
	'the track panel clips its own content');
like($style, qr/\.studio_track_actions\s*\{[^}]*overflow:\s*hidden/s,
	'the actions line clips rather than reaching across');
like($style, qr/\@media \(max-width: 800px\)[\s\S]*?\.studio_track_panel\s*\{[^}]*flex-basis:\s*118px/s,
	'a phone width narrows the panel instead of overlaying the canvas');

# --- tracks keep their own height and the transport keeps its row ----------
like($style, qr/\.studio_track\s*\{[^}]*height:\s*var\(--studio_track_height, 90px\)/s,
	'a track has a 90px default row rather than the whole panel');
like($style, qr/\.studio_track_resize\s*\{[^}]*cursor:/s, 'the track bottom edge is a resize grip');
like($markup, qr/class="studio_track_resize hover"[^>]*channel="<%=\s*\$ch\s*%>"/,
	'every track row carries the grip');
like($layout, qr/'pointerdown', '\.studio_track_resize'/, 'the grip starts a track resize');
like($layout, qr/function studioTrackHeightClamp/, 'the track height is clamped');
like($knobs, qr/song\[ch\]\['track_height'\] = h;/, 'the height is saved with the song');
like($markup, qr/id="studio_transport_row"/, 'the transport row is addressable');
like($markup, qr/class="studio_transport_field"[^>]*id="studio_bpm"/, 'tempo sits in the row');
like($style, qr/\.studio_transport_row\s*\{[^}]*flex-wrap:\s*wrap/s,
	'the row wraps only when the window is genuinely narrow');

# --- the console fills its width, master at the far right -------------------
like($style, qr/#studio_mixer_strips \.channel\s*\{[^}]*flex:\s*1 1/s,
	'the strips stretch to fill the console instead of leaving a gap');
like($style, qr/#studio_mixer_strips \.channel\s*\{[^}]*min-width:\s*76px/s,
	'every strip keeps a readable floor and the row scrolls only past it');
like($markup, qr/class="studio_strip_body"[\s\S]*class="studio_strip_knobs"/,
	'the strip puts its knobs and its fader in one row');
like($markup, qr/control="volume"[\s\S]{0,400}?class="channel_volume studio_strip_volume"/,
	'the strip fader is the same volume control as the track slider');
like($style, qr/\.studio_strip_body\s*\{[^}]*flex-direction:\s*row/s, 'the fader sits beside the knobs');
like($style, qr/\.studio_strip_fader_group\s*\{[^}]*height:\s*100%/s, 'the volume group takes the whole control column');
like($style, qr/\.studio_strip_fader_group\s*\{[^}]*flex:\s*1 1 auto/s, 'and grows into the room the mute/solo row leaves');
like($knobs, qr/function studioChannelVolumeSet\(ch, value\)/, 'one setter owns the track volume');
like($style, qr/#studio_mixer\s*\{[^}]*overflow:\s*hidden/s, 'the console contains its own content');
like($markup, qr/id="studio_mixer_strips"[\s\S]*id="studio_master_rack"[\s\S]*id="studio_transport_panel"/,
	'the master rack is the last child of the strips row');

# --- theme colours, never a palette of its own -----------------------------
unlike($style, qr/\b(?:tan|brown|lightblue|lightgreen)\b/, 'Studio names no colour of its own');
like($style, qr/background-color:\s*var\(--panel-2\)/, 'panels take the theme panel');
like($style, qr/color:\s*var\(--ink\)/, 'text takes the theme ink');
like($style, qr/color-mix\(in srgb, var\(--accent\)/, 'tints are mixed from the theme accent');

# --- full screen is the window's shared control, not a Studio gesture -------
unlike($winjs, qr/studioWindowFullSelector/, 'no double-press is bound to the maximize control');
unlike($style, qr/window_full_viewport/, 'Studio keeps no full-viewport rule of its own');
like($fitjs, qr/windowFullViewportEnter/, 'the window keeps its own full-view control');
like($help, qr/full-screen button - behind the app icon/, 'the help names the shared full-screen button');

# --- the help topic names the window controls -------------------------------
like($help, qr/an interior window of the Studio desk/, 'help calls each panel an interior window');
like($help, qr/Minimize and Maximize buttons/, 'help names the title-bar buttons');
like($help, qr/its taskbar entry brings it back/, 'help explains the taskbar restore');
like($help, qr/The taskbar entry for the panel at the front minimizes it/,
	'help explains the taskbar toggle');
like($help, qr/Every panel is an interior window of its own/, 'help explains moving and resizing');
like($help, qr/Maximize fills the desk with that window/, 'help explains maximizing');
like($help, qr/'Minimize this panel'/, 'help lists the Minimize control');
like($help, qr/'Maximize or restore this panel'/, 'help lists the Maximize control');
like($help, qr/'Show this panel, or minimize it'/, 'help lists the taskbar control');
like($help, qr/'Drag the bottom edge to resize this panel\\'s height'/, 'help lists the bottom edge grip');
like($help, qr/'Drag to move the Studio window'/, 'help lists the window drag grip');
like($help, qr/'Take another channel\\'s output as this channel\\'s input'/, 'help lists the input channel send');
like($help, qr/'Send this channel\\'s output to another channel'/, 'help lists the output channel send');
like($help, qr/'Drag to resize this panel'/, 'help lists the corner grip');
like($help, qr/'Drag to move the channel strips'/, 'help lists the drag handle');
like($help, qr/'Add a track, up to 32'/, 'help names Add track and its cap');
like($help, qr/'Arrange the panels'/, 'help names the Arrange control');
like($help, qr/Every panel window is its own scroll box/, 'help explains the scroll rule');
like($help, qr/the master rack is the strips\\' last strip on the right/, 'help puts the master strip at the far right');
like($help, qr/'Show automation for this track'/, 'help names the automation toggle');
like($help, qr/Delete track, which asks twice and turns red on the first press/,
	'help names the track menu\'s two-press Delete');
like($help, qr/'Open the pedalboard for this track'/, 'help names the FX button');
like($help, qr/'Close the pedalboard'/, 'help names the pedalboard close');
like($help, qr/'Tap to select; press and hold for channel in, out and delete'/,
	'help names the track panel\'s hold menu');
like($help, qr/never lists effects/, 'help says the track panel keeps its height');
like($help, qr/Every track has a compact panel/, 'help describes the per-track panel');
like($help, qr/panel window of its own/, 'help describes the drum window');
like($help, qr/jog wheel shares the transport/, 'help describes the jog wheel in the button row');
unlike($help, qr/Float the (?:channel strips|transport|track listing|drums)/,
	'help no longer names Float');
unlike($help, qr/Dock the (?:channel strips|transport|tracks|drums)/,
	'help no longer names Dock');
unlike($help, qr/Narrow\/Wide control/, 'help no longer names the width control');
unlike($help, qr/pack into a two-column grid/, 'help no longer describes the packing grid');

# --- the old fixed count is gone --------------------------------------------
unlike($sheet, qr/\|\|\s*4\b/, 'the page no longer falls back to four tracks');
unlike($knobs, qr/channel_count[^\n]*\|\|\s*4\b/, 'the initialiser no longer falls back to four tracks');
like($sheet, qr/\|\|\s*1\b/, 'the page starts with one track');
like($markup, qr/data-max-tracks="<%=\s*\$max_tracks\s*%>"/, 'the viewer carries the dynamic cap');
unlike($markup, qr/channel_count\s*\|\|\s*4\b/, 'the markup no longer fixes the track count at four');
like($js, qr/07_layout\.js/, 'the studio index names the layout part');
like($ctrl, qr/studioSyncTrackList/, 'loading a song restores the tracks it was saved with');
like($edit, qr/'channel_count', 'value': '1'/, 'New song asks for a single track');

# --- the drum panel is one window, so its grid class is gone ---------------
like($drumsjs, qr/function studioDrumsGridState\(\)/, 'the drums keep their state hook');
like($drumsjs, qr/studioPanelTaskbarRefresh/, 'the hook refreshes the taskbar');
unlike($drumsjs, qr/studio_panel_floating|studio_drums_open/, 'the old docked-grid state is gone');

done_testing();
