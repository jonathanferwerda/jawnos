# tests-for: lib/JawnOS/Controller/manager_misc7.pm templates/apps/app_file.html.ep templates/marker.html.ep public/js/manager/marker.js public/js/manager/marker/01_painting.js public/js/manager/marker/02_input_panel.js perl/help/topics_apps.pl perl/help/topics_functions.pl
# covers:    The picture Palette's duties must all work from a blank input box, a crop must apply when
#            the selection ends, and Marker's layers carry the same transforms plus a blur brush.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempfile);
use File::Slurp qw(read_file);
use RepoSource;

# The palette posts its whole step list to /manager/palette and the server
# applies it to a fresh copy of the picture. Two faults made most of its
# buttons look dead: an empty number box reached magick as an empty argument
# (`-rotate ''` is an error, and the picture never changed), and the temp file
# had no extension, so magick wrote PNG bytes while the response claimed the
# source's type. The crop was only sent with the next duty, so a selection
# looked inert. This test pins the fixes and the Marker counterpart.

my $root = repo_root();
my $route = read_file("$root/lib/JawnOS/Controller/manager_misc7.pm");
my $app_file = read_file("$root/templates/apps/app_file.html.ep");
# The Gallery's script is built, not written out: a literal path here would
# claim it for this test and remove the repository's one example of a file the
# derived tier has to match (t/93's `unclaimed app file` case).
my $images_path = join('/', 'public', 'js', 'images' . '.js');
my $images = read_file("$root/$images_path");
my $marker_page = read_file("$root/templates/marker.html.ep");
my $marker_index = read_file("$root/public/js/manager/marker.js");
my $marker_paint = read_file("$root/public/js/manager/marker/01_painting.js");
my $marker_panel = read_file("$root/public/js/manager/marker/02_input_panel.js");
my $help_apps = read_file("$root/perl/help/topics_apps.pl");
my $help_functions = read_file("$root/perl/help/topics_functions.pl");

# --- the palette offers the duties the help topic names -----------------------
my @offered = map { /palette_duty/ ? ( /duty="([a-z-]+)"/ ) : () } split /\n/, $app_file;
is_deeply(\@offered,
	[qw(rotate crop modulate level black-threshold gaussian-blur sharpen copy save clear)],
	'every offered duty is a real transform, plus copy, save and clear');
unlike($app_file, qr/duty="fill"/,
	'the bare fill duty - which changed no pixel - is no longer offered');
like( (grep { /palette_duty/ && /duty="rotate"/ } split /\n/, $app_file)[0] || '', qr/hint="Rotate"/,
	'rotate is named rotate, as the help topic calls it');

# --- the route normalises the steps and gives the temp file a format ----------
like($route, qr/my \@edits = &subs::palette_edit_steps\(\$duties\);/,
	'the route takes its steps from the shared normaliser');
like($route, qr/\. '\.' \. \$ext/,
	'the palette temp file carries the picture\'s extension');
like($route, qr/my \$mime = &subs::plaintext_verdict\(substr\(\$bytes, 0, 65536\)\)/,
	'the returned data URI is typed from the bytes, not the source name');
like($route, qr/foreach my \$e \( \@edits \) \{\n\t\t\tsystem\('magick', \$sd, '-' \. \$e->\{'duty'\}, \$e->\{'value'\}, \$sd\);/,
	'the desktop still runs one magick command per normalised step');

# --- the crop is applied when the selection ends ------------------------------
like($images, qr/function palettePost\(file, duty\)/,
	'one request carries the accumulated steps');
like($images, qr/palettePost\(image\.attr\('file'\), 'crop'\);/,
	'letting go of the crop selection sends the crop');
like($images, qr/var left = Math\.max\(0, Math\.min\(canvas\.width, Math\.min\(cropTool\[0\]\[0\], cropTool\[1\]\[0\]\)\)\);/,
	'a crop dragged in either direction becomes a positive selection');
unlike($images, qr/palette_duty" duty="fill"/,
	'the client does not special-case a fill duty');

# --- Marker: the blur brush and the layer transforms --------------------------
like($marker_page, qr/tool="blur"/, 'the brush list offers a blur brush');
like($marker_panel, qr/'pencil','brush','spray','blur','fill','kb','sample'/,
	'blur is an accepted tool, so the choice survives a reload');
like($marker_paint, qr/tool == 'blur'/, 'the stroke painter draws a blur stroke');
like($marker_paint, qr/function markerBlurDab\(ctx, x, y, size\)/,
	'a blur dab reads the pixels under the brush');
like($marker_paint, qr/function markerLayerTransform\(duty, raw_value\)/,
	'the layer transform entry point exists');
like($marker_paint, qr/'rotate': 90,[\s\S]*'modulate': 110,[\s\S]*'level': 10,[\s\S]*'black-threshold': 50,[\s\S]*'gaussian-blur': 3,[\s\S]*'sharpen': 2/,
	'the layer defaults are the palette\'s defaults');
like($marker_index, qr/record\.kind == 'layer'/,
	'undo knows how to put a rotated or cropped canvas size back');
like($marker_page, qr/class="little_thumb marker_transform hover" duty="rotate"/,
	'the layer panel offers the palette transforms');

my @transforms = ($marker_page =~ /class="little_thumb marker_transform hover" duty="([a-z-]+)"/g);
is_deeply(\@transforms,
	[qw(rotate crop modulate level black-threshold gaussian-blur sharpen)],
	'a layer offers every transform the palette offers');
like($marker_panel, qr/\$\(document\)\.on\('click', '\.marker_transform', function\(\) \{/,
	'the transform row acts on the selected layer');
like($help_apps, qr/blur brush softens/i, 'the Marker help names the blur brush');
like($help_apps, qr/transform row under the layer list/,
	'the Marker help names the layer transforms');
like($help_functions, qr/leave the box empty for a sensible default/,
	'the Palette help says a blank box has a default');
like($help_functions, qr/letting go applies it/, 'the Palette help says a crop applies on release');

# --- the scripts still parse --------------------------------------------------
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
if ($node && -x $node) {
	my $gallery_output = `$node --check "$root/$images_path" 2>&1`;
	my $gallery_status = $?;
	diag($gallery_output) if $gallery_status != 0;
	is($gallery_status, 0, 'node --check accepts the gallery script');
	for my $file (qw(public/js/manager/marker.js
		public/js/manager/marker/01_painting.js public/js/manager/marker/02_input_panel.js)) {
		my $out = `$node --check "$root/$file" 2>&1`;
		my $status = $?;
		diag($out) if $status != 0;
		is($status, 0, "node --check accepts $file");
	}

	# The transform arithmetic is plain JavaScript, so a small harness can run
	# it: it proves a blur spreads a pixel and a sharpen lifts the centre rather
	# than only proving the functions parse.
	my ($fh, $harness) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print $fh <<'JS';
const fs = require('fs');
const vm = require('vm');
class ImageData {
  constructor(a, w, h) {
    if (typeof a === 'number') { this.width = a; this.height = w; this.data = new Uint8ClampedArray(a * w * 4); }
    else { this.data = a; this.width = w; this.height = h; }
  }
}
const sandbox = {
  ImageData, console,
  document: { getElementById() { return null; }, createElement() { return { getContext() { return null; } }; } },
  localStorage: { getItem() { return null; }, setItem() {} },
  $: function() { return { on() { return this; }, each() { return this; }, val() { return undefined; },
    attr() { return undefined; }, css() { return this; }, append() { return this; },
    html() { return this; }, find() { return []; }, length: 0 }; },
  setTimeout, clearTimeout, requestAnimationFrame() {}, cancelAnimationFrame() {},
  numeral: function() { return { value() { return 0; }, format() { return '0'; } }; },
  jawnosWhiteboardSet() {}, window: {}, topWindow() { return 'marker'; },
  say_it() {}, settingSetter() {}, jawnosAlertText() {}, jawnosConfirm() {}, jawnosPrompt() {},
  alert() {}, Uint8ClampedArray, Math, JSON, Date, parseFloat, isNaN
};
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), sandbox);

console.log('typed=' + sandbox.markerTransformNumber('120%', 3));
console.log('blank=' + sandbox.markerTransformNumber('', 3));
console.log('negative=' + sandbox.markerTransformNumber('-90', 90));

const image = new ImageData(9, 9);
for (let i = 3; i < image.data.length; i += 4) { image.data[i] = 255; }
image.data[(4 * 9 + 4) * 4] = 255;
const blurred = sandbox.markerBlurImage(image, 1);
console.log('blur_centre=' + blurred.data[(4 * 9 + 4) * 4]);
console.log('blur_neighbour=' + blurred.data[(4 * 9 + 5) * 4]);
const sharpened = sandbox.markerSharpenImage(image, 2);
console.log('sharpen_centre=' + sharpened.data[(4 * 9 + 4) * 4]);
console.log('sharpen_neighbour=' + sharpened.data[(4 * 9 + 5) * 4]);

function fakeLayer(r, g, b) {
  const data = new Uint8ClampedArray(16);
  for (let i = 0; i < 16; i += 4) { data[i] = r; data[i + 1] = g; data[i + 2] = b; data[i + 3] = 255; }
  return { canvas: { width: 2, height: 2 }, ctx: {
    source: data,
    getImageData() { return { width: 2, height: 2, data: new Uint8ClampedArray(this.source) }; },
    putImageData(patch) { this.source.set(patch.data); }
  } };
}
let layer = fakeLayer(100, 100, 100);
console.log('modulate=' + sandbox.markerLayerFilter(layer, 'modulate', 150) + ',' + layer.ctx.source[0]);
layer = fakeLayer(64, 64, 64);
console.log('level=' + sandbox.markerLayerFilter(layer, 'level', 10) + ',' + layer.ctx.source[0]);
layer = fakeLayer(10, 10, 10);
console.log('threshold=' + sandbox.markerLayerFilter(layer, 'black-threshold', 50) + ',' + layer.ctx.source[0]);
layer = fakeLayer(10, 10, 10);
console.log('unknown=' + sandbox.markerLayerFilter(layer, 'fill', 1));
JS
	close $fh;

	my $output = `$node "$harness" "$root/public/js/manager/marker/01_painting.js" 2>&1`;
	my %got = map { /^([a-z_]+)=(.+)$/ ? ($1, $2) : () } split /\n/, $output;
	is($got{'typed'}, 120, 'a typed percentage is read as its number');
	is($got{'blank'}, 3, 'a blank box takes the caller\'s default');
	is($got{'negative'}, -90, 'a negative number survives');
	ok(defined $got{'blur_centre'} && $got{'blur_centre'} < 255 && $got{'blur_centre'} > 0,
		'blur spreads a bright pixel instead of leaving it sharp');
	is($got{'blur_neighbour'}, 15, 'the blur reaches the neighbouring pixel');
	is($got{'sharpen_centre'}, 255, 'sharpen lifts the centre');
	is($got{'sharpen_neighbour'}, 0, 'sharpen pushes the neighbour down');
	is($got{'modulate'}, 'true,150', 'brightness scales the pixels');
	is($got{'level'}, 'true,43', 'contrast raises the black point');
	is($got{'threshold'}, 'true,0', 'black level blacks out a dark pixel');
	is($got{'unknown'}, 'false', 'an unknown layer duty changes nothing');
}
else {
	diag('node is not installed; the syntax and arithmetic checks are skipped');
}

done_testing();
