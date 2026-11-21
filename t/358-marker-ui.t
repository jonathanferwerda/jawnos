# tests-for: templates/marker.html.ep public/js/manager/marker.js public/js/manager/marker/01_painting.js public/js/manager/marker/02_input_panel.js public/js/manager/marker/03_selection.js public/js/manager/marker/04_stage.js public/css/manager.css lib/JawnOS/Controller/manager_misc13.pm lib/JawnOS/Routes/manager_misc13.pm perl/help/topics_apps.pl
# covers:    Marker's stage: the paper sizes Init offers, the rulers and status bar, the brush ring,
#            the incremental repaint, the cheap save, and the select/move/clipboard seams.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use RepoSource;

# Marker used to open on a board the size of the window and repaint all of it on
# every stroke segment, re-encoding every layer to PNG on each autosave. This
# pins the replacement: a document of a chosen paper shown inside rulers, a
# status bar that says where the cursor is, a brush ring instead of the system
# pointer, a repaint that follows the brush instead of the sheet, a save that
# re-encodes only what changed, and the selection seams Gimp hands expect.

my $root = repo_root();
my $marker_page = read_file("$root/templates/marker.html.ep");
my $marker_index = read_file("$root/public/js/manager/marker.js");
my $marker_paint = read_file("$root/public/js/manager/marker/01_painting.js");
my $marker_panel = read_file("$root/public/js/manager/marker/02_input_panel.js");
my $marker_select = read_file("$root/public/js/manager/marker/03_selection.js");
my $marker_stage = read_file("$root/public/js/manager/marker/04_stage.js");
my $marker_css = read_file("$root/public/css/manager.css");
my $misc13 = read_file("$root/lib/JawnOS/Controller/manager_misc13.pm");
my $routes = read_file("$root/lib/JawnOS/Routes/manager_misc13.pm");

# --- the shell: two rails around a stage --------------------------------------
like($marker_page, qr/<div id="marker_toolbox" class="marker_rail marker_rail_left"/,
	'the tools live in a left rail');
like($marker_page, qr/<div id="marker_toolbox_right" class="marker_rail marker_rail_right"/,
	'the portfolio lives in a right rail');
like($marker_page, qr/<div id="marker_stage">/, 'the board has its own stage column');
like($marker_page, qr/<canvas id="whiteboard"><\/canvas>/,
	'#whiteboard is still the composite: other apps capture it');
like($marker_page, qr/id="marker_ruler_top"/, 'a ruler runs along the top');
like($marker_page, qr/id="marker_ruler_left"/, 'a ruler runs down the left');
like($marker_page, qr/id="marker_status_bar"/, 'a status bar closes the stage');
for my $item (qw/marker_status_xy marker_status_xy_percent marker_status_size marker_status_zoom marker_status_layer/) {
	like($marker_page, qr/id="$item"/, "the status bar shows $item");
}
like($marker_page, qr/<div id="marker_brush_cursor"/, 'the brush ring is an element over the board');
like($marker_page, qr/<canvas id="marker_selection_overlay"/, 'selections have their own overlay');

# the folds the left rail promises
my ($left_rail) = $marker_page =~ /(<div id="marker_toolbox".*?)<div id="marker_stage">/s;
my @groups = ($left_rail =~ /class="marker_group_head" group="([a-z]+)"/g);
is_deeply(\@groups, [qw/tools selection animation brush document layers/],
	'the left rail folds the tools, the selection, the animation, the brush, the document and the layers');
my ($right_rail) = $marker_page =~ /(<div id="marker_toolbox_right".*?)<button class="button" id="marker_toolbox_show"/s;
my @right_groups = ($right_rail =~ /class="marker_group_head" group="([a-z]+)"/g);
is_deeply(\@right_groups, [qw/file portfolio sessions/],
	'the right rail folds the save row, the drawings and the sessions');

# --- Init asks for a paper ----------------------------------------------------
like($marker_page, qr/id="marker_size_dialog"/, 'Init opens a size dialog');
like($marker_page, qr/class="button marker_init hover" hint="Choose the size of a new drawing"/,
	'the Init button is labelled as the place to choose a size');
my @papers = ($marker_page =~ /class="button marker_size_choice" name="([^"]+)"/g);
is_deeply(\@papers,
	[ 'Letter', 'Legal', 'Poster', 'Flyer', 'CD cover', 'DVD cover', 'Business card', 'Screen' ],
	'the dialog offers the standard papers and the old window-sized board');
my @sizes = ($marker_page =~ /class="button marker_size_choice" name="[^"]+" w="(\d+)" h="(\d+)"/g);
is(scalar(@sizes), 16, 'every paper carries a width and a height');
like($marker_page, qr/name="Business card" w="336" h="192"/,
	'a business card is 3.5 by 2 inches at 96 to the inch');
like($marker_page, qr/name="CD cover" w="480" h="480"/, 'a CD cover is square');
like($marker_stage, qr/function markerDocNew\(name, w, h\)/,
	'one function makes a new sheet at a chosen size');
like($marker_stage, qr/function markerDocRemember\(name, w, h\)/,
	'the paper is remembered, so a reload shows the same sheet');
like($marker_stage, qr/function markerSizeByName\(name\)/, 'the paper table is looked up by name');

# --- the sheet is fitted, not stuck ------------------------------------------
unlike($marker_index, qr/Math\.min\(1, scale/, 'Fit no longer refuses to zoom a small sheet up');
like($marker_index, qr/markerView\.scale = Math\.max\(0\.02, Math\.min\(8, scale\)\)/,
	'Fit fits the sheet and shows a card larger than life');
like($marker_index, qr/function markerFirstLayer\(\)/,
	'a fresh board starts on the remembered paper, not the window');

# --- the repaint follows the brush, not the sheet ----------------------------
like($marker_index, qr/function markerComposeRegion\(rect\)/,
	'there is a rectangle repaint beside the whole-board one');
like($marker_index, qr/function markerComposeDirtyRect\(rect\)/,
	'the dirty rectangles are merged before the frame');
like($marker_index, qr/if \(markerComposeRect && markerComposedSeq === markerViewSeq\)/,
	'a queued rectangle is dropped when the view changed under it');
like($marker_paint, qr/markerComposeSoon\(\{ x: Math\.min\(x0, pos\.x\) - size/,
	'a stroke queues its own rectangle');
like($marker_paint, qr/markerComposeSoon\(\{ x: markerStroke\.x - size/, 'the spray queues its own rectangle');

# --- the save only re-encodes what changed -----------------------------------
like($marker_index, qr/function markerLayerEncoded\(layer\)/, 'a layer keeps its last encoded PNG');
like($marker_index, qr/if \(layer\.encoded && !layer\.sessionDirty\) \{ return layer\.encoded; \}/,
	'an unchanged layer is not encoded again');
like($marker_index, qr/layers\.push\(\{ name: layer\.name, visible: layer\.visible, image: markerLayerEncoded\(layer\) \}\)/,
	'the upload asks a layer for its encoded image');
like($marker_index, qr/function markerLayerDirty\(uuid\)/, 'a change marks the layer it touched');
like($marker_paint, qr/var markerAutosaveDelay = 8000;/, 'autosave waits for a quiet moment');
like($marker_paint, qr/if \(markerStroke\.drawing && !force\) \{/,
	'a save never lands mid-stroke, except the forced save when the tab goes');

# --- the undo snapshot is a copy, not a readback -----------------------------
like($marker_index, qr/function markerSnapshotCanvas\(width, height\)/,
	'the stroke snapshot is a scratch canvas');
like($marker_index, qr/ctx\.drawImage\(layer\.canvas, 0, 0\);/, 'the layer is copied on the GPU');
like($marker_index, qr/before\.copy\.getContext\('2d'\)\.getImageData\(x, y, w, h\)/,
	'only the dirty rectangle is read back, once');
unlike($marker_index, qr/markerImageDataCrop/, 'the per-stroke whole-layer crop is gone');

# --- the brush ring, the rulers and the status bar ---------------------------
like($marker_stage, qr/function markerBrushDiameter\(pressure\)/,
	'the ring is the size of the brush');
like($marker_stage, qr/size \* 2 \* \(0\.3 \+ 0\.7 \* pressure\) \* markerView\.scale/,
	'the ring is the brush width at the current zoom');
like($marker_stage, qr/marker && marker\.selected_marker_size/,
	'the ring shows the chosen size, not only the size of the last stroke');
like($marker_stage, qr/function markerRulersDraw\(\)/, 'the rulers are drawn from the view');
like($marker_stage, qr/function markerRulerStep\(scale\)/, 'the ruler picks a step that fits its labels');
like($marker_stage, qr/function markerStatusPointer\(point\)/,
	'the status bar reads the pointer');
like($marker_stage, qr/function markerViewChanged\(\)/,
	'one entry point moves the rulers, the edge and the ring');
like($marker_stage, qr/ResizeObserver/, 'the stage follows the window being resized');
like($marker_paint, qr/var markerCanvasRect = null;/, 'the canvas box is measured once, not per move');
like($marker_paint, qr/function markerSettingsLoad\(\)/, 'the sliders are read once, not per move');
like($marker_css, qr/#marker_viewport \{[^}]*overflow: hidden;/s, 'the stage clips the sheet');
like($marker_css, qr/\.marker_brush_cursor \{[^}]*border-radius: 50%;/s, 'the ring is round');
like($marker_css, qr/#whiteboard \{[^}]*cursor: var\(--jawnos-cursor-none, none\);/s,
	'the system pointer is hidden so the ring is the pointer');

# --- the Gimp-shaped seams ---------------------------------------------------
like($marker_page, qr/tool="select"/, 'a rectangle select tool is offered');
like($marker_page, qr/tool="lasso"/, 'a lasso is offered');
like($marker_page, qr/tool="move"/, 'a move tool is offered');
for my $act (qw/all none copy cut paste delete/) {
	like($marker_page, qr/marker_selection_action hover" act="$act"/, "the selection offers $act");
}
for my $duty (qw/modulate level gaussian-blur sharpen/) {
	like($marker_page, qr/marker_selection_effect hover" duty="$duty"/, "a selection takes the $duty effect");
}
for my $seam (qw/markerSelectionPointerDown markerSelectionPointerMove markerSelectionPointerUp markerSelectionRedraw markerSelectionOverlaySize/) {
	like($marker_select, qr/^function $seam\(/m, "the selection defines $seam");
}
like($marker_paint, qr/typeof markerSelectionPointerDown === 'function' && markerSelectionPointerDown/,
	'the pointer offers the press to the selection tools first');
like($marker_select, qr/markerLayerFilter\(/, 'a selection effect reuses the layer arithmetic');
like($marker_select, qr/function markerSelectionRectOf\(from, to, size\)/,
	'a drag in any direction becomes a positive rectangle');
like($marker_select, qr/markerSelectionAntsStop\(\)/, 'the marching ants stop with the selection');
like($marker_panel, qr/'pencil','brush','spray','blur','fill','kb','sample','select','lasso','move'/,
	'a selection tool survives a reload');

# --- Save to appointment -----------------------------------------------------
like($routes, qr/\[44905, 'get', '\/manager\/marker\/appointments', 'action_44905'\]/,
	'a route lists the appointments the picker offers');
like($misc13, qr/sub action_44905 \{/, 'the route action exists');
like($misc13, qr/and app != \? order by timestamp desc limit 40/,
	'the picker leaves out Marker drawings and stays short');
like($misc13, qr/my \$attach_uuid = \$c->param\('attach_uuid'\);/, 'a save can name an appointment');
like($misc13, qr/&subs::db_update\('appointments', \{ file => encode_json\(\$files\) \}, \{ uuid => \$attach_uuid \}\)/,
	'an attached drawing joins that record\'s own file list');

# --- the controls are wired ---------------------------------------------------
# A button that no handler answers is a button that does nothing: the shell was
# rewritten, so every control the rail shows is checked against the scripts that
# claim it (the rails' own toggles live on their ids).
my $all_js = join "\n", $marker_index, $marker_paint, $marker_panel, $marker_select, $marker_stage;
for my $name (qw(
	marker_init marker_size_choice marker_modal_cancel marker_save_appointment marker_attach_row
	marker_selection_action marker_selection_effect marker_group_head
	save_marker marker_session_save marker_tool marker_erase_toggle marker_transform marker_paper
	marker_delete flipbook play_marker record_marker marker_layer_add marker_layer_delete
	marker_undo marker_redo marker_zoom_in marker_zoom_out marker_zoom_fit marker_new_board
	marker_colour marker_colour_add marker_colour_remove marker_stylus_toggle
	marker_toolbox_hide marker_toolbox_show marker_toolbox_right_hide marker_toolbox_right_show
a)) {
	my $id = $name eq 'marker_paper' ? 'paper' : $name;
	like($all_js, qr/\.on\('[^']*',\s*'[^']*\Q$id\E/,
		"the $id control has a handler");
}

# --- the stage names its own stacking order ----------------------------------
# manager.css paints every canvas at z-index 99 (`canvas { z-index: 99 }`), and a
# grid item's z-index applies even when it is not positioned. A marker canvas
# that said nothing therefore painted over the brush ring, the marching ants and
# the rail buttons - which is how hiding a rail left its show button unclickable.
like($marker_css, qr/#whiteboard \{[^}]*z-index: 0;/s, 'the board sits at the bottom of the stage stack');
like($marker_css, qr/#marker_paper_edge \{[^}]*z-index: 1;/s, 'the paper edge sits over the board');
like($marker_css, qr/\.marker_cursor_guide \{[^}]*z-index: 2;/s, 'the cursor guides sit over the paper edge');
like($marker_css, qr/#marker_selection_overlay \{[^}]*z-index: 3;/s, 'the marching ants paint over the board');
like($marker_css, qr/\.marker_brush_cursor \{[^}]*z-index: 4;/s, 'the brush ring paints over the ants');
like($marker_css, qr/\.marker_ruler_top \{[^}]*z-index: 1;/s, 'the top ruler names its own level');
like($marker_css, qr/\.marker_ruler_left \{[^}]*z-index: 1;/s, 'the left ruler names its own level');
like($marker_page, qr/id="marker_toolbox_show"[^>]*z-index:1\d\d/, 'the toolbox show button outranks a canvas');
like($marker_page, qr/id="marker_toolbox_right_show"[^>]*z-index:1\d\d/, 'the portfolio show button outranks a canvas');

# --- the panel wears the desk's ink, not a fixed white plate ------------------
# On a dark desk the ink is light, so a white plate made the active brush white
# on white; the rail, the status bar and the ruler ticks had the same fault.
like($marker_css, qr/\.marker_tool\.selected[^{]*\{[^}]*color: var\(--ink/s,
	'the selected tool reads in the desk ink');
unlike($marker_css, qr/\.marker_tool\.selected[^{]*\{[^}]*rgba\(255,\s*255,\s*255/s,
	'the selected tool is not a fixed white plate');
like($marker_css, qr/\.marker_rail \{[^}]*background: var\(--panel-2/s,
	'the rail takes the theme surface and its ink');
like($marker_css, qr/\.marker_status_bar \{[^}]*color: var\(--ink/s,
	'the status bar reads in the desk ink');
like($marker_css, qr/\.marker_ruler \{[^}]*background: var\(--panel-2/s,
	'the rulers take the theme surface');
like($marker_stage, qr/getComputedStyle\(document\.body\)\.getPropertyValue\('--ink'\)/,
	'the ruler ticks are drawn in the desk ink');

# --- the incremental repaint leaves no seam ----------------------------------
# The repaint clears a device rectangle and paints the sheet inside it. If the
# paint is smaller than the clear by even the 2px of brush slack, every patch
# leaves a transparent frame: a stroke leaves a growing square outline around
# itself until the end-of-stroke repaint wipes it. markerRegionBox is that pair
# of rectangles, so it can be checked without a browser.
like($marker_index, qr/function markerRegionBox\(rect, size, view, width, height\)/,
	'the repaint geometry is one function');
like($marker_index, qr/ctx\.clearRect\(box\.sx, box\.sy, box\.ex - box\.sx, box\.ey - box\.sy\)/,
	'the clear uses the box');
like($marker_index, qr/ctx\.fillRect\(box\.fx, box\.fy, box\.fw, box\.fh\)/,
	'the sheet fill uses the box, not the unclamped rectangle');

# --- a pointer move repaints nothing but the ring ---------------------------------
# Moving the mouse used to redraw two ruler canvases and force a style recalc
# every 60ms, and to reach the ring through jQuery: the ring lagged the pointer
# and the board felt heavy. The rulers' cursor marks are DOM lines now.
like($marker_page, qr/id="marker_ruler_cursor_x"/, 'the top ruler has a cursor mark');
like($marker_page, qr/id="marker_ruler_cursor_y"/, 'the left ruler has a cursor mark');
like($marker_stage, qr/function markerCursorNode\(name, id\)/, 'the hover nodes are looked up once');
like($marker_stage, qr/cursor\.style\.transform = 'translate\('/, 'the ring is placed with a direct style write');
unlike($marker_stage, qr/function markerBrushCursorMove\(screen\) \{[^}]*markerRulersSoon/s,
	'a pointer move does not schedule a ruler redraw');
like($marker_css, qr/\.marker_ruler_cursor_x \{[^}]*width: 1px/s, 'the ruler mark is a thin line');

# the icons the toolbar calls for
for my $icon (qw/pencil brush spray blur fill sample keyboard eraser select lasso move/) {
	ok(-e "$root/public/images/marker/$icon.svg", "the $icon icon exists");
	like($marker_page, qr{/images/marker/\Q$icon\E\.svg}, "the toolbar asks icon_for for $icon");
}

# --- the scripts still run ----------------------------------------------------
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
if ($node && -x $node) {
	my ($fh, $harness) = tempfile(SUFFIX => '.js', UNLINK => 1);
	# Every part of Marker is concatenated into one script, so running them all
	# in one context is also the only check that they define no clashing global.
	print $fh <<'JS';
const fs = require('fs');
const vm = require('vm');
class ImageData {
	constructor(a, w, h) {
		if (typeof a === 'number') { this.width = a; this.height = w; this.data = new Uint8ClampedArray(a * w * 4); }
		else { this.data = a; this.width = w; this.height = h; }
	}
}
function fakeCanvas() {
	const canvas = { width: 0, height: 0 };
	canvas.getContext = function () { return {
		canvas: canvas, globalAlpha: 1, globalCompositeOperation: 'source-over',
		fillStyle: '#000', strokeStyle: '#000', lineWidth: 1, lineCap: 'butt', lineJoin: 'miter',
		save() {}, restore() {}, beginPath() {}, moveTo() {}, lineTo() {}, stroke() {},
		fillRect() {}, clearRect() {}, drawImage() {}, translate() {}, rotate() {}, setTransform() {},
		rect() {}, clip() {}, fillText() {}, fill() {}, createRadialGradient() { return { addColorStop() {} }; },
		getImageData(x, y, w, h) { return new ImageData(w, h); }, putImageData() {}
	}; };
	return canvas;
}
const store = {};
const sandbox = {
	ImageData, console,
	document: {
		getElementById() { return null; },
		createElement() { return fakeCanvas(); },
		addEventListener() {},
		hidden: false
	},
	localStorage: { getItem(k) { return k in store ? store[k] : null; }, setItem(k, v) { store[k] = String(v); }, removeItem(k) { delete store[k]; } },
	$: function () {
		const jq = {
			length: 0, on() { return jq; }, each() { return jq; }, val() { return undefined; },
			attr() { return undefined; }, css() { return jq; }, append() { return jq; },
			html() { return jq; }, text() { return jq; }, find() { return jq; }, closest() { return jq; },
			prop() { return jq; }, remove() { return jq; }, toggle() { return jq; },
			show() { return jq; }, hide() { return jq; }, slideToggle() { return jq; },
			is() { return false; }, offset() { return { top: 0, left: 0 }; }, trigger() { return jq; }
		};
		return jq;
	},
	setTimeout, clearTimeout, requestAnimationFrame() { return 1; }, cancelAnimationFrame() {},
	numeral: function () { return { value() { return 0; }, format() { return '0'; } }; },
	jawnosWhiteboardSet() {}, topWindow() { return 'marker'; }, say_it() {}, settingSetter() {},
	jawnosAlertText() {}, jawnosConfirm() {}, jawnosPrompt() {}, alert() {}, bti: 'tab',
	Uint8ClampedArray, Math, JSON, Date, parseFloat, isNaN, Number, String, Object, Array,
	navigator: { clipboard: undefined }, performance: { now() { return 0; } }, ResizeObserver: undefined
};
sandbox.window = sandbox;
sandbox.document.defaultView = sandbox.window;
vm.createContext(sandbox);

for (const file of process.argv.slice(3)) {
	vm.runInContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
}
const out = {};
out.loaded = typeof sandbox.markerComposeRegion === 'function' && typeof sandbox.markerSelectionPointerDown === 'function';

// the ruler picks a step whose labels do not collide
out.step_1 = sandbox.markerRulerStep(1);
out.step_quarter = sandbox.markerRulerStep(0.25);
out.step_4 = sandbox.markerRulerStep(4);

// the paper table
out.card_w = sandbox.markerSizeByName('Business card').w;
out.card_h = sandbox.markerSizeByName('Business card').h;
out.unknown = sandbox.markerSizeByName('not a paper').name;

// the paper is remembered
sandbox.markerDocRemember('Legal', 816, 1344);
out.remembered = sandbox.markerDocRemembered().name + ':' + sandbox.markerDocRemembered().w + 'x' + sandbox.markerDocRemembered().h;
sandbox.markerDocRemember('', 480, 480);
out.remembered_nameless = sandbox.markerDocName();

// a drag in any direction is a positive selection, clamped to the sheet
const box = sandbox.markerSelectionRectOf({ x: 90, y: 90 }, { x: 10, y: 20 }, { w: 100, h: 100 });
out.drag = [box.x, box.y, box.w, box.h].join(',');
const clamped = sandbox.markerSelectionRectOf({ x: -10, y: -10 }, { x: 200, y: 200 }, { w: 100, h: 50 });
out.clamped = [clamped.x, clamped.y, clamped.w, clamped.h].join(',');

// the ring is the stroke width at the current zoom
sandbox.markerStroke.size = 20;
sandbox.markerView.scale = 2;
out.ring = sandbox.markerBrushDiameter(1);

// one incremental repaint: the cleared rectangle and the part painted white
function region(rect) {
	const box = sandbox.markerRegionBox(rect, { w: 816, h: 1056 }, { scale: 0.5, x: 20, y: 30 }, 900, 600);
	return [box.sx, box.sy, box.ex - box.sx, box.ey - box.sy, box.fx - box.sx, box.fy - box.sy, box.fw, box.fh].join(':');
}
out.region_inside = region({ x: 100, y: 100, w: 40, h: 40 });
out.region_edge = region({ x: -50, y: 900, w: 100, h: 100 });
out.region_off = region({ x: -4000, y: -4000, w: 10, h: 10 });
// the invariant, not the arithmetic: the painted sheet inside a patch must
// cover the cleared rectangle exactly, leaving no transparent frame
function covered(rect) {
	const box = sandbox.markerRegionBox(rect, { w: 816, h: 1056 }, { scale: 0.5, x: 20, y: 30 }, 900, 600);
	return box.fx === box.sx && box.fy === box.sy && box.fw === box.ex - box.sx && box.fh === box.ey - box.sy;
}
out.covered_inside = covered({ x: 100, y: 100, w: 40, h: 40 });
out.covered_edge = covered({ x: -50, y: 900, w: 100, h: 100 });
out.covered_corner = covered({ x: 700, y: 1000, w: 200, h: 200 });

console.log(JSON.stringify(out));
JS
	close $fh;

	my $files = join ' ', map { "'$root/$_'" } qw(
		public/js/manager/marker.js
		public/js/manager/marker/01_painting.js
		public/js/manager/marker/02_input_panel.js
		public/js/manager/marker/03_selection.js
		public/js/manager/marker/04_stage.js
	);
	my $output = `$node "$harness" marker $files 2>&1`;
	my %got = ();
	my ($json) = $output =~ /(\{.*\})/s;
	if ($json) {
		my $decoded = eval {
			require Mojo::JSON;
			Mojo::JSON::decode_json($json);
		};
		%got = %{ $decoded || {} };
	}
	ok(scalar(keys %got), 'the marker scripts run together in one context')
		or diag($output);
	is($got{'loaded'}, 1, 'the compose and selection entry points exist after loading every part');
	is($got{'step_1'}, 50, 'at 1:1 the ruler labels every 50 pixels');
	is($got{'step_quarter'}, 200, 'zoomed out, the ruler labels further apart in document pixels');
	is($got{'step_4'}, 20, 'zoomed in, the ruler labels closer together');
	is($got{'card_w'}, 336, 'the business card is 336 pixels wide');
	is($got{'card_h'}, 192, 'the business card is 192 pixels tall');
	is($got{'unknown'}, 'Letter', 'an unknown paper falls back to Letter');
	is($got{'remembered'}, 'Legal:816x1344', 'the paper a drawing is on is remembered');
	is($got{'remembered_nameless'}, '', 'a remembered sheet with no name reports no name');
	is($got{'drag'}, '10,20,80,70', 'a drag from bottom-right to top-left is a positive rectangle');
	is($got{'clamped'}, '0,0,100,50', 'a drag past the sheet is clamped to it');
	is($got{'ring'}, 80, 'the ring is the stroke width times the zoom');
	# sx:sy:w:h of the clear, then the white fill's offset and size within it
	is($got{'covered_inside'}, 1, 'a patch inside the sheet clears and paints the same rectangle');
	is($got{'covered_edge'}, 1, 'a patch running off the sheet is clamped, clear and paint together');
	is($got{'covered_corner'}, 1, 'a patch over the sheet corner still leaves no frame');
	is($got{'region_off'}, '0:0:0:0:0:0:0:0', 'a patch nowhere near the board paints nothing');
}
else {
	diag('node is not installed; the marker script checks are skipped');
}

# --- the stage observer follows the window that is open now ------------------
like($marker_stage, qr/function markerStageTeardown\(\)/, 'Marker has a close hook of its own');
my ($stage_init) = $marker_stage =~ /function markerStageInit\(\) \{(.*?)\n\}/s;
ok(defined $stage_init, 'the stage init is found');
$stage_init = '' unless defined $stage_init;
like($stage_init, qr/if \(!markerStageObserver\) \{\s*markerStageObserver = new ResizeObserver/,
	'the observer is created only when absent');
like($stage_init, qr/markerStageObserver\.disconnect\(\);\s*markerStageObserver\.observe\(viewport\);/s,
	'and re-attached to this open\'s viewport every time');
unlike($marker_stage, qr/window\.ResizeObserver && !markerStageObserver/,
	'the old guard no longer skips observing on a reopen');
like($marker_stage, qr/jawnosAppTeardown\['marker'\] = markerStageTeardown/,
	'the shell registry learns about it');


done_testing();
