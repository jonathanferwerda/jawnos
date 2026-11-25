# tests-for: public/js/manager/studio/03_editing.js public/js/manager/studio/07_layout.js templates/studio/style.html.ep
# covers:    The Studio pedalboard as a row of the Tracks panel instead of a
#            bottom sheet: opening carries #pedalboard into #studio_viewer,
#            right after the calling track's row, with the inline class and a
#            data-channel; the board follows the selection (a track panel, a
#            mixer strip, a colour swatch, a delete and a remote select) and
#            closes when there is no row left to sit under; an FX press on the
#            track the board already sits under folds it away; the CSS stops
#            the absolute bottom-sheet placement inside the viewer; and the
#            Synth taskbar entry is a pure visibility toggle. Structure only;
#            pixels are not asserted here.

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
my $edit   = slurp("$root/public/js/manager/studio/03_editing.js");
my $layout = slurp("$root/public/js/manager/studio/07_layout.js");
my $style  = slurp("$root/templates/studio/style.html.ep");

# --- the board is placed under the calling track's row ----------------------
like($edit, qr/function\s+studioPedalboardTrackRow\s*\(/,
	'the board has one notion of the row it belongs under');
like($edit, qr/studioPedalboardTrackRow\s*\([\s\S]*?'#studio_track_row_'\s*\+\s*ch/,
	'that row is the selected channel\'s track row');
like($edit, qr/function\s+studioPedalboardPlace\s*\(/,
	'the placement is one helper');
like($edit, qr/function\s+studioPedalboardPlace\s*\([\s\S]*?\.insertAfter\(\s*row\s*\)/,
	'the board is carried into the panel after the track row');
like($edit, qr/function\s+studioPedalboardPlace\s*\([\s\S]*?studio_board_inline/,
	'the inline placement wears its own class');
like($edit, qr/function\s+studioPedalboardPlace\s*\([\s\S]*?\.attr\(\s*'data-channel'/,
	'the inline board names the track it belongs to');
like($edit, qr/function\s+studioPedalboardOpen\s*\(show\)\s*\{[\s\S]*?board\.show\(\);[\s\S]*?studioPedalboardPlace\(\);/,
	'opening places the board under the selected track before it is drawn');

# --- it follows the selection, and closes when the row is gone --------------
like($edit, qr/function\s+studioPedalboardFollow\s*\(/,
	'a follow helper exists');
like($edit,
	qr/function\s+studioPedalboardFollow\s*\(\)\s*\{[\s\S]*?is\(\s*':visible'\s*\)[\s\S]*?studioPedalboardPlace\(\)[\s\S]*?studioPedalboardOpen\(\s*false\s*\)/,
	'a visible board re-places itself, and closes when it has no row');
like($layout,
	qr/'#studio_pedalboard_close'[\s\S]*?studioPedalboardOpen\(\s*false\s*\)/,
	'the Close button still hides it');

# --- FX folds an already-open board for its own track -----------------------
like($layout,
	qr/'\.studio_track_fx'[\s\S]*?is\(\s*':visible'\s*\)[\s\S]*?attr\(\s*'data-channel'\s*\)[\s\S]*?studioPedalboardOpen\(\s*false\s*\)[\s\S]*?return;[\s\S]*?studioRackRender\(\s*ch\s*\)/,
	'FX on the track the board is under closes it; any other track opens it');
like($layout,
	qr/'\.studio_track_fx'[\s\S]*?studioPedalboardOpen\(\s*true\s*\)/,
	'FX still opens the board');

# --- the selection clicks move the board ------------------------------------
like($layout,
	qr/click',\s*'\.studio_track_panel,\s*\.channel,\s*\.studio_track_colour'[\s\S]*?studioPedalboardFollow\(\)/,
	'a click on a track panel, a strip or a colour swatch moves the board');
like($layout,
	qr/studioRemoveTrack\(\s*button\.attr\(\s*'channel'\s*\)\s*\);[\s\S]*?studioPedalboardFollow\(\)/,
	'a deleted track leaves the board following the new selection');
like($layout,
	qr/function\s+studioRemoteSelectTrack[\s\S]*?studioSelectedChannel\s*=\s*ch;[\s\S]*?studioPedalboardFollow\(\)/,
	'a remote select moves the board with the selection');

# --- the inline CSS clears the bottom sheet's absolute placement ------------
like($style, qr/#studio_viewer\s*>\s*#pedalboard/,
	'the panel placement is scoped to the viewer, or to the inline class');
like($style, qr/#pedalboard\.studio_board_inline/,
	'the inline class is styled');
like($style,
	qr/#pedalboard\.studio_board_inline\s*\{[^}]*position:\s*relative/s,
	'the inline board is in the flow, not absolute');
like($style,
	qr/#pedalboard\.studio_board_inline\s*\{[^}]*left:\s*auto/s,
	'left:auto clears the sheet');
like($style,
	qr/#pedalboard\.studio_board_inline\s*\{[^}]*bottom:\s*auto/s,
	'bottom:auto clears the sheet');
like($style,
	qr/#pedalboard\.studio_board_inline\s*\{[^}]*z-index:\s*3/s,
	'the board sits above the selection overlay');
like($style,
	qr/#studio_pedalboard_rack\s*\{[^}]*overflow-x:\s*auto/s,
	'the rack keeps its horizontal scroll');
like($style, qr/#pedalboard\s*\{[^}]*position:\s*absolute/s,
	'the bottom-sheet rule stays for the moment before the reparent');

# --- the Synth taskbar entry hides as well as shows -------------------------
like($layout,
	qr/click',\s*'\.studio_panel_task'[\s\S]*?name\s*===\s*'synth'[\s\S]*?studioPanelSetMinimized\(\s*name,\s*true,\s*true\s*\)[\s\S]*?return;/,
	'the Synth entry minimizes the panel even when it is not in front');
like($layout,
	qr/click',\s*'\.studio_panel_task'[\s\S]*?if\s*\(state\.minimized\)\s*\{\s*studioPanelSetMinimized\(\s*name,\s*false,\s*true\s*\);\s*studioPanelRaise\(\s*name\s*\);/,
	'a minimized panel, Synth included, still comes back and is raised');
like($layout,
	qr/'\.studio_panel_task'[\s\S]*?studioPanelFront\(\)\s*===\s*name[\s\S]*?studioPanelRaise\(\s*name\s*\)/,
	'the other five entries keep the front-panel/raise rule');
like($layout,
	qr/panel_keys[\s\S]*?'5':\s*'synth'[\s\S]*?studioPanelSetMinimized\(\s*panel_keys\[key\],\s*false,\s*true\s*\);[\s\S]*?studioPanelRaise\(\s*panel_keys\[key\]\s*\)/,
	'Ctrl+Alt+5 still shows the synth');

done_testing;
