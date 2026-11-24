# tests-for: public/js/manager/studio/17_tools.js templates/studio/markup.html.ep templates/studio/style.html.ep
# covers:    The Tracks title bar's cursor/select/cut tool: the three buttons and
#            their pressed state, the cross-lane selection bar with Loop, Bounce
#            and Export, the viewer and ruler selection overlays, the
#            capture-phase pointer handlers that keep the Select drag and the Cut
#            razor away from the existing move/trim editing, and the sliced
#            whole-song render posted to the studio exporter. Structure only;
#            pixels are not asserted here.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root   = repo_root();
my $markup = read_file("$root/templates/studio/markup.html.ep");
my $style  = read_file("$root/templates/studio/style.html.ep");
my $js     = read_file("$root/public/js/manager/studio/17_tools.js");

# --- the title bar carries the three tools ----------------------------------
like($markup, qr/class="studio_tools"[^>]*role="toolbar"/,
	'the Tracks bar carries a timeline tool group');
for my $tool (qw(cursor select cut)) {
	like($markup, qr/class="studio_tool hover" data-tool="$tool" aria-pressed="(?:true|false)"/,
		"$tool has a tool button with a pressed state");
}
like($markup, qr/data-tool="cursor" aria-pressed="true"/, 'cursor starts pressed');
like($markup, qr/data-tool="select"[^>]*hint="<%= &subs::ui\('Select a time range across tracks'\) %>"/,
	'Select says what it selects');
like($markup, qr/data-tool="cut"[^>]*hint="<%= &subs::ui\('Click a clip to cut it at that point'\) %>"/,
	'Cut says what a click does');

# --- the selection bar and its four actions ---------------------------------
like($markup, qr/id="studio_selection_bar"/, 'the selection bar exists');
like($markup, qr/id="studio_selection_label"/, 'the bar names the chosen span');
for my $action (qw(studio_selection_loop studio_selection_bounce
	studio_selection_export studio_selection_clear)) {
	like($markup, qr/id="$action"/, "$action is present");
}
like($markup, qr/id="studio_selection_bar"[\s\S]*?id="studio_selection_overlay"/,
	'the selection UI sits before the viewer overlay');

# --- both overlays are in the markup ----------------------------------------
like($markup, qr/id="studio_selection_overlay"/, 'the lanes have a selection overlay');
like($markup, qr/id="studio_ruler_selection"/, 'the ruler has a selection overlay');

# --- tool state ---------------------------------------------------------------
like($js, qr/var studioTool = 'cursor';/, 'cursor is the default tool');
like($js, qr/\$\(document\)\.on\('click', '\.studio_tool'/, 'the tool buttons are delegated');
like($js, qr/studio_tool_select/, 'Select toggles its cursor class');
like($js, qr/studio_tool_cut/, 'Cut toggles its cursor class');
like($js, qr/\.toggle\('studio_tool_select', tool === 'select'\)/,
	'the Select class follows the chosen tool');
like($js, qr/\.toggle\('studio_tool_cut', tool === 'cut'\)/,
	'the Cut class follows the chosen tool');
like($js, qr/aria-pressed/, 'the buttons publish their pressed state');

# --- the selection model -----------------------------------------------------
like($js, qr/var studioSelection = null;/, 'there is one selection slot');
like($js, qr/function studioSelectionSet\(/, 'a finished drag becomes a selection');
like($js, qr/function studioSelectionClear\(/, 'the selection can be cleared');
like($js, qr/function studioSelectionDraw\(/, 'the selection is drawn from one function');
like($js, qr/function studioSelectionLabel\(/, 'the selection has a label');
like($js, qr/return \{ start: start, end: end, channels: picked, all: !!drag\.ruler \};/,
	'a selection carries its start, end, channels and whether it is whole-width');
like($js, qr/studioSelectionBarShow\(false\)[\s\S]*?studioSelectionStatus\(''\)[\s\S]*?innerHTML = ''/,
	'clearing hides the bar, its label and the overlay');

# --- capture-phase pointer handling -----------------------------------------
like($js, qr/document\.addEventListener\('pointerdown'[\s\S]*?\},\s*true\)/,
	'a pointerdown handler is registered in the capture phase');
like($js, qr/document\.addEventListener\('pointermove'[\s\S]*?\},\s*true\)/,
	'the drag tracks the pointer in the capture phase');
like($js, qr/document\.addEventListener\('pointerup'[\s\S]*?\},\s*true\)/,
	'the drag ends in the capture phase');
like($js, qr/event\.stopPropagation\(\)/, 'a drag keeps the editing handler from running');
like($js, qr/event\.preventDefault\(\)/, 'a drag suppresses the browser default');
like($js, qr/studioTool !== 'select'/, 'the Select handler stands down for the other tools');
like($js, qr/studioTool !== 'cut'/, 'the Cut handler stands down for the other tools');
like($js, qr/studioCanvasTime\(canvas, clientX\)/, 'a lane pointer maps through the lane time helper');
like($js, qr/studioTimelineWindowRect\(canvas\)/, 'the ruler maps through the zoomed window rect');
like($js, qr/studioToolSnap\(/, 'a selection edge snaps to the recording grid');
like($js, qr/studioSnapUnit\(\)/, 'the snap reads the transport\'s own unit');

# --- cross-lane selection ----------------------------------------------------
like($js, qr/function studioToolLaneOrder\(\)/, 'the lanes are read in row order');
like($js, qr/order\.indexOf\(String\(drag\.laneStart\)\)/, 'the drag remembers its first lane');
like($js, qr/order\.indexOf\(String\(drag\.laneEnd\)\)/, 'the drag follows the lane under the pointer');
like($js, qr/for \(var i = lo; i <= hi/, 'every lane between the two edges is selected');
like($js, qr/studioToolLaneOrder\(\)\.forEach\(function \(ch\) \{ picked\[ch\] = true; \}\)/,
	'a ruler drag selects every lane');
like($js, qr/studioSelectionChannels\(sel\)\.forEach/, 'each selected lane is drawn');
like($js, qr/studioTimelineXAt\(canvas, sel\.start\)/, 'a lane block starts at the range start');
like($js, qr/studioTimelineXAt\(canvas, sel\.end\)/, 'a lane block ends at the range end');
like($js, qr/\.studio_track\[data-channel="/, 'the lane row is found by channel');
like($js, qr/event\.target\.id !== 'studio_viewer'[\s\S]*?studioSelectionQueueDraw\(\)/,
	'a viewer scroll redraws the overlay');
like($js, qr/window\.addEventListener\('resize'/, 'a resize redraws the overlay');

# --- Cut ---------------------------------------------------------------------
like($js, qr/studioSplitTake\(ch, hit\.take, t\)/, 'Cut splits the take at the pointer time');
like($js, qr/studioCanvasHit\(canvas, drag\.x\)/, 'Cut finds the take under the razor line');
like($js, qr/lanes\.indexOf\(canvas\) === -1/, 'a vertical drag collects every lane it crosses');
like($js, qr/studioSaver\(\)[\s\S]*?studioTakesChanged\(\)/, 'a cut saves and reschedules the take');

# --- the bar's actions -------------------------------------------------------
like($js, qr/studioSetLoopRange\(sel\.start, sel\.end\)/, 'Loop asks the transport for the range');
like($js, qr/mixer\['time'\]\['loop_region'\] = \{ start: sel\.start, end: sel\.end, bars: bars \}/,
	'the fallback writes the same loop region');
like($js, qr/#studio_loop/, 'the fallback lights the transport loop control');
like($js, qr/studioBounceSelection\(sel\.start, sel\.end, sel\.channels\)/,
	'Bounce hands the whole selection to the bounce step');
like($js, qr/The bounce step is not ready yet\./, 'an unready bounce says so instead of throwing');
like($js, qr/studioSelectionSlice\(offline\.ctx, rendered, sel\.start, sel\.end\)/,
	'the whole-song render is sliced to the selection');
like($js, qr/ctx\.createBuffer\(channels, frames, rate\)/, 'the slice is a new AudioBuffer');
like($js, qr/from\.subarray\(first, first \+ frames\)/, 'each channel of the slice is copied');
like($js, qr/studioBufferToWav\(sliced\)/, 'the slice is encoded as a WAV');
like($js, qr/fetch\('\/manager\/studio\/export', \{ method: 'POST', body: form \}\)/,
	'the selection is posted to the studio exporter');
like($js, qr/form\.append\('name', name \+ ' selection'\)/, 'the export is filed under the song and "selection"');
like($js, qr/form\.append\('format', studioSelectionFormat\(\)\)/, 'the export honours the format control');
like($js, qr/form\.append\('bitrate', String\(studioSelectionBitrate\(\)\)\)/,
	'the export honours the bitrate control');
like($js, qr/form\.append\('master', includeMaster \? '1' : '0'\)/, 'the export honours the master box');
like($js, qr/studioSelectionStatus\(studioToolText\('Rendering the selection\\u2026'\)\)/,
	'the bar says the selection is rendering');
like($js, qr/studioSelectionStatus\(studioToolText\('Selection attached\.'\)\)/,
	'the bar says the selection was attached');
like($js, qr/There are no takes in the selection to export\./,
	'an empty selection is refused in words');

# --- the style ---------------------------------------------------------------
like($style, qr/\.studio_tools\s*\{[\s\S]*?display:\s*inline-flex/, 'the tools share a row');
like($style, qr/\.studio_tools \.studio_tool\[aria-pressed="true"\]/, 'the pressed tool reads pressed');
like($style, qr/#studio_viewer\.studio_tool_select canvas\.track,[\s\S]*?cursor:\s*var\(--jawnos-cursor-crosshair, crosshair\)/,
	'Select gives the lanes a crosshair');
like($style, qr/#studio_ruler\.studio_tool_select \.studio_ruler_canvas\s*\{[\s\S]*?cursor:\s*var\(--jawnos-cursor-crosshair, crosshair\)/,
	'Select gives the ruler a crosshair');
like($style, qr/#studio_viewer\.studio_tool_cut canvas\.track\s*\{[\s\S]*?cursor:\s*var\(--jawnos-cursor-cell, cell\)/,
	'Cut gives the lanes a cell cursor');
like($style, qr/\.studio_selection_bar\s*\{[\s\S]*?display:\s*flex/, 'the selection bar is a row');
like($style, qr/\.studio_selection_overlay\s*\{[\s\S]*?position:\s*absolute[\s\S]*?pointer-events:\s*none/,
	'the viewer overlay is a pointer-transparent layer');
like($style, qr/\.studio_selection_lane\s*\{[\s\S]*?position:\s*absolute/, 'a selected lane is a block');
like($style, qr/\.studio_ruler_selection\s*\{[\s\S]*?position:\s*absolute/, 'the ruler span is a block');

done_testing;
