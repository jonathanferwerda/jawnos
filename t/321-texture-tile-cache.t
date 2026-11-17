# tests-for: public/js/manager/texture.js
# covers:    A material's grain tile is built once and then answered from the
#            cache. soft is the default material and has no tile of its own, so
#            asking for one answered null by allocating a canvas and dropping it;
#            the clothesline is repainted whole on every appointment poll with one
#            pill per garment, so the page leaked a canvas - a node, a 2D context
#            and its memory - per garment per poll until the next GC.
#
# The measured symptom (a real desktop shell, 60 s idle, Desk layout):
#   DOM nodes 3,356 -> 4,593, listeners 510 -> 688, renderer RSS 392 -> 417 MB.
# The probe's node census named it: create:canvas <- jawnosTextureTile <-
# jawnosTextureGrain <- jawnosTexturePill <- clotheslineHanger <- deskShow <-
# calculator, ~4 canvases a second with 12 garments on a 3 s poll.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use Mojo::JSON qw(decode_json);
use RepoSource;

my $root = repo_root();
my $js = js_source('public/js/manager/texture.js');

# --- the tile is looked up, and a miss is an answer -------------------------

like($js, qr/if\s*\(\s*key\s+in\s+jawnosTextureTiles\s*\)\s*\{\s*return\s+jawnosTextureTiles\[\s*key\s*\];\s*\}/,
	'a remembered miss is answered, so a material without a tile is asked once');

my ($fn) = $js =~ /(function jawnosTextureTile\(kind, dark\) \{.*?\n\})/s;
ok(defined $fn && length $fn, 'the tile builder is found');

# --- the guard comes before any canvas exists ------------------------------

my $guard_at = index($fn, 'jawnosTextureTileKinds[kind]');
my $canvas_at = index($fn, "document.createElement('canvas')");
ok($guard_at >= 0, 'the builder asks whether this material has a tile');
ok($canvas_at > $guard_at, 'that question is asked before a canvas is built');

# --- the list of tile materials and the builder agree ----------------------

# the list is written as a map of names, so read the names themselves
my ($map) = $js =~ /var jawnosTextureTileKinds = \{([^}]*)\};/s;
my @named = sort(($map // '') =~ /([a-z]+)\s*:\s*1/g);
is_deeply(\@named, [qw(fabric glass metal paper sandglass wood)],
	'the materials with a grain tile are named once');

my @built = sort(($fn =~ /kind === '([a-z]+)'/g));
is_deeply(\@built, \@named,
	'every material the builder handles is in that list, and no other is');

# --- behaviour: a canvas is built only for a material that has a tile ------

my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
if ($node && -x $node) {
	my $stub = <<'JS';
var __created = 0;
function __canvas() {
	var ctx = {
		createImageData: function (w, h) { return { data: new Array(w * h * 4).fill(0) }; },
		putImageData: function () {},
		createLinearGradient: function () { return { addColorStop: function () {} }; },
		fillRect: function () {}, fill: function () {}, stroke: function () {},
		beginPath: function () {}, moveTo: function () {}, lineTo: function () {},
		fillStyle: '', strokeStyle: '', lineWidth: 1
	};
	return { width: 0, height: 0, getContext: function () { return ctx; } };
}
var document = {
	createElement: function (tag) {
		if (tag !== 'canvas') { throw new Error('unexpected element ' + tag); }
		__created++;
		return __canvas();
	}
};
JS
	my ($defs) = $js =~ /(var jawnosTextureTiles = \{\};\nvar jawnosTextureTileKinds = \{[^}]*\};\n)/;
	ok(defined $defs, 'the cache and the tile list are found');

	my $harness = $stub . ($defs // '') . $fn . <<'JS';
var out = {};
out.soft1 = jawnosTextureTile('soft', false);
out.soft2 = jawnosTextureTile('soft', false);
out.after_soft = __created;
var p1 = jawnosTextureTile('paper', false);
var p2 = jawnosTextureTile('paper', false);
out.one_paper = (p1 === p2 && !!p1);
out.after_paper = __created;
jawnosTextureTile('paper', true);
out.after_dark = __created;
out.bare_null = ['plain', 'round', 'classic'].every(function (k) {
	return jawnosTextureTile(k, false) === null;
});
out.after_bare = __created;
out.is_null = (out.soft1 === null && out.soft2 === null);
console.log(JSON.stringify(out));
JS
	my $dir = tempdir(CLEANUP => 1);
	my $file = "$dir/tile.js";
	open(my $fh, '>', $file) or die "$file: $!";
	print {$fh} $harness;
	close $fh;

	my $json = `$node "$file" 2>&1`;
	my $status = $?;
	is($status, 0, 'the tile builder runs against a stub document')
		or diag($json);
	my $r = eval { decode_json($json) } || {};
	is($r->{after_soft}, 0, 'soft builds no canvas at all');
	ok($r->{is_null}, 'soft answers null both times');
	is($r->{after_paper}, 1, 'paper builds one canvas, and the second ask is a hit');
	ok($r->{one_paper}, 'both paper asks return the same kept tile');
	is($r->{after_dark}, 2, 'the dark ink is its own tile');
	ok($r->{bare_null}, 'plain, round and classic answer null');
	is($r->{after_bare}, 2, 'and building none of them');

	my $out = `$node --check "$root/public/js/manager/texture.js" 2>&1`;
	my $check = $?;
	diag($out) if $check != 0;
	is($check, 0, 'node --check accepts the texture script');
}
else {
	diag('node is not installed; the tile behaviour check is skipped');
}

done_testing();
