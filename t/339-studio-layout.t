# tests-for: templates/studio/studio.html.ep templates/studio/markup.html.ep templates/studio/style.html.ep public/js/manager/studio.js public/js/manager/studio/03_editing.js public/js/manager/studio/04_knobs.js public/js/manager/studio/06_controls.js public/js/manager/studio/07_layout.js public/js/manager/windows.js lib/JawnOS/Manager/Part22.pm perl/help/topics_apps.pl t/339-studio-layout.t
# covers:    The Studio layout: a compact panel beside every track with its five
#            controls, four remembered hide toggles, a Dock control and pointer
#            drag handlers for each floating panel, a dynamic track list with
#            Add track / a twice-pressed Delete, and a help topic that names
#            them. Structure only; pixels are not asserted here.

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
like($style, qr/rail|#studio_transport_panel[\s\S]*studio_controls|#studio_controls[\s\S]*right:130px/,
	'the transport is laid out clear of the jog wheel');

# --- the pedalboard can be closed -------------------------------------------
like($markup, qr/id="studio_pedalboard_close"/, 'the pedalboard has a close control');
like($layout, qr/'#studio_pedalboard_close'[\s\S]*pedalboard'\)\.hide/, 'the close control hides the pedalboard');

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

# --- the help topic names the new controls ----------------------------------
like($help, qr/'Add a track, up to 32'/, 'help names Add track and its cap');
like($help, qr/Show automation for this track/, 'help names the automation toggle');
like($help, qr/Delete this track/, 'help names the per-track delete');
like($help, qr/Hide the channel strips/, 'help names the strip hide toggle');
like($help, qr/Hide the transport/, 'help names the transport hide toggle');
like($help, qr/Hide the track listing/, 'help names the track hide toggle');
like($help, qr/Dock the tracks/, 'help names the Dock control');
like($help, qr/Close the pedalboard/, 'help names the pedalboard close');
like($help, qr/Every track has a compact panel/, 'help describes the per-track panel');

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
