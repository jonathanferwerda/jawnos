# tests-for: public/js/manager/mapengine/01_engine.js public/js/manager/travel.js public/js/manager/travel/05_basemap.js public/js/manager/travel/02_maps_config_guess.js public/js/manager/windows/03_stack.js
# covers:    the house's own vector basemap as a provider in the shared map
#            engine: MapLibre draws behind the engine's canvas without taking
#            its gestures, the engine drives its view, the plates and pins stay
#            on top, and a missing library or archive falls back to raster

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $engine = read_file("$root/public/js/manager/mapengine/01_engine.js");
my $travel = read_file("$root/public/js/manager/travel.js");
my $basemap = read_file("$root/public/js/manager/travel/05_basemap.js");
my $config = read_file("$root/public/js/manager/travel/02_maps_config_guess.js");
my $stack = read_file("$root/public/js/manager/windows/03_stack.js");

# ---- the provider row is a picker entry with its own group -----------------
like($engine, qr/\bhouse: \{ name: 'House street map'[^}]*group: 'house'[^}]*vector: true/s,
	'the house basemap is a provider row in its own group, marked vector');
like($engine, qr/\bhouse: \{[^}]*credit: '[^']*OpenStreetMap contributors'/s,
	'its credit names OpenStreetMap');
like($travel, qr/house: 'The house\\'s own street map'/,
	'the picker gives that group its own label');
like($config, qr/settingSetter\(\{ 'app': 'travel', 'setting': 'map_provider', 'value': value \}\)/,
	'choosing it is remembered by the existing map_provider setting');

# ---- the vector layer is behind the canvas and lets every gesture through --
like($engine, qr/box\.style\.cssText = 'position:absolute;z-index:0;pointer-events:none;overflow:hidden;'/,
	'the MapLibre box is absolute and passes pointer events through');
like($engine, qr/parent\.insertBefore\(box, canvas\)/,
	'it is inserted behind the engine canvas');
like($engine, qr/new window\.maplibregl\.Map\(\{/,
	'MapLibre is constructed from the same installed build');
like($engine, qr/\binteractive: false,/,
	'its own interaction is off: the engine owns the gestures');
like($engine, qr/canvas\.style\.zIndex = '1'/,
	'the canvas is lifted so plates, pins and labels stay on top');

# ---- draw() drives MapLibre from the engine's view ------------------------
like($engine, qr/jumpTo\(\{ center: \[at\.lon, at\.lat\], zoom: at\.z \}\)/,
	'every draw pushes the engine centre and zoom at MapLibre');
like($engine, qr/^\s+zoom: view\.z,$/m,
	'and the camera opens at the engine zoom, not one step off it');
like($engine, qr/var TILE_RATIO = 2;/, 'the backdrop is built at twice the canvas box');
like($engine, qr/MapLibre 4\.7 wedges on that for a vector source/,
	'and the source cannot declare 256-px tiles instead: MapLibre wedges on it');
like($engine, qr/if \(!vectorOn\) \{\n\t\t\t\tctx\.fillStyle = '#e9edf1';\n\t\t\t\tctx\.fillRect\(0, 0, dim\.w, dim\.h\);\n\t\t\t\tdrawTiles\(o, dim\.w, dim\.h\);\n\t\t\t\}/,
	'the raster fill and tile fetch are skipped only when the vector layer is up');
like($engine, qr/drawMaps\(o, dim\.w, dim\.h, view\.z\);\n\t\t\tdrawLines\(o, dim\.w, dim\.h, view\.z\);\n\t\t\tdrawMarkers\(o, dim\.w, dim\.h, view\.z\);/,
	'measured maps, guessed gaps and pins are drawn unchanged over it');
like($engine, qr/if \(isVectorKey\(providerKey\)\) \{ vectorEnsure\(\); \}/,
	'only the vector provider asks for the vector layer');

# ---- the archive header sets the ceiling ----------------------------------
like($engine, qr/readMax\(v\.url \|\| '\/manager\/travel\/basemap'/,
	'the same house route supplies the archive header');
like($engine, qr/vector\.maxZoom = parseInt\(maxzoom, 10\) \|\| \(providers\.house\.max \|\| ZMAX\)/,
	'the deepest zoom comes from the archive, not a pinned number');
like($engine, qr/maxZoom: vector\.maxZoom,/,
	'MapLibre is held to that ceiling');
like($engine, qr/return Math\.max\(ZMIN, Math\.min\(ZMAX, vector\.maxZoom \|\| \(p && p\.max\) \|\| ZMAX\)\)/,
	'and clampZ cannot zoom past what the archive holds');
like($basemap, qr/done\(isFinite\(n\) && n > 0 \? n : TRAVEL_BASEMAP_DEFAULT_MAXZOOM, read\);/,
	'the shared header reader also reports whether the archive answered');

# ---- one loader, shared with the long-press view -------------------------
like($basemap, qr/^function travelBasemapLoad\(done\)/m, 'the chunk keeps its one loader');
like($travel, qr/load: function\(done\) \{ travelBasemapLoad\(done\); \}/,
	'the engine is handed that loader, not a second copy');
like($travel, qr/register: function\(\) \{ travelBasemapRegister\(\); \}/,
	'and the one protocol registration');
like($travel, qr/style: function\(maxzoom\) \{ return travelBasemapStyle\(maxzoom\); \}/,
	'and the one hand-written style');
like($travel, qr/url: '\/manager\/travel\/basemap'/,
	'with the same same-origin archive route');
like($travel, qr/onStatus: function\(text\) \{ \$\('#travel_map_status'\)\.text\(text \|\| ''\); \}/,
	'the engine reports in the map\'s own status text');

# ---- failure says so, then falls back ------------------------------------
like($engine, qr/The house\\'s street map is not installed - run scripts\/fetch_basemap_libs\.sh/,
	'a missing library names the installer');
like($engine, qr/The house has no street map archive yet - run perl scripts\/osm_basemap\.pl --all/,
	'a missing archive says how to build one');
like($engine, qr/function rasterFallback\(\)/,
	'the raster fallback is the previous provider');
like($engine, qr/if \(rasterKey && providers\[rasterKey\] && !providers\[rasterKey\]\.vector && rasterKey !== 'none'\)/,
	'which is the last raster provider chosen, never the vector one');

# ---- teardown -------------------------------------------------------------
like($engine, qr/function vectorDispose\(\)/, 'the engine has a disposer');
like($engine, qr/try \{ vector\.map\.remove\(\); \} catch \(e\) \{\}/,
	'which drops the MapLibre map, its worker and its listeners');
like($engine, qr/destroy: function \(\) \{ destroyed = true; vectorDispose\(\); setStatus\(''\); \},/,
	'and is exposed as destroy(), which stops a late redraw from rebuilding it');
like($engine, qr/if \(isVectorKey\(providerKey\) && key !== providerKey\) \{ vectorDispose\(\); \}/,
	'switching provider disposes it');
like($engine, qr/if \(window\.maplibregl && window\.pmtiles\) \{ vector\.loading = false; withLibraries\(\); return; \}/,
	'an already installed MapLibre is reused, not re-executed (its PMTiles registration is once per page)');
like($stack, qr/if \(app == 'travel' && typeof travelMap !== 'undefined' && travelMap && typeof travelMap\.destroy === 'function'\)/,
	'closing the Travel window disposes it too');

# ---- the rules, run against a fake DOM and a fake MapLibre ----------------
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
SKIP: {
	skip 'node is not installed', 3 unless $node && -x $node;
	my $out = `$node "$root/t/lib/mapengine_vector.js" "$root/public/js/manager/mapengine/01_engine.js" 2>&1`;
	my $status = $? >> 8;
	is($status, 0, 'the engine behaviour harness exits clean');
	my @lines = split /\n/, (defined $out ? $out : '');
	my @bad = grep { /^not ok/ } @lines;
	is_deeply(\@bad, [], 'every engine behaviour assertion passed') or diag join "\n", @bad;
	my $count = grep { /^ok / } @lines;
	cmp_ok($count, '>=', 40, "the harness ran its cases ($count assertions)");
}

done_testing();
