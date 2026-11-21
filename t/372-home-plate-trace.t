# tests-for: public/js/manager/mapengine/01_engine.js public/js/manager/configure/10_home_plate_trace.js
# covers:    the map engine's read-back contract for the home-plate water
#            trace: unproject, a double-click that does not also fire single
#            clicks, CORS on every raster provider and canReadTiles, plus the
#            trace's own pixel read, polygon result and unprojection

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $engine = read_file("$root/public/js/manager/mapengine/01_engine.js");
my $trace = read_file("$root/public/js/manager/configure/10_home_plate_trace.js");

# ---- the engine exposes the inverse of project() --------------------------
like($engine, qr/unproject: function \(sx, sy\)/,
	'the engine exposes unproject(sx, sy)');
like($engine, qr/return geoAt\(o\.x \+ sx, o\.y \+ sy, view\.z\);/,
	'unproject uses the same originFor/geoAt projection as the taps and pins');

# ---- a double-click reaches the page, without two single clicks -----------
like($engine, qr/onMapDoubleClick: function \(fn\) \{ doubleClickHandler = fn; \}/,
	'the engine exposes onMapDoubleClick(fn)');
like($engine, qr/canvas\.addEventListener\('dblclick', function \(e\) \{/,
	'a mouse dblclick listener is installed');
like($engine, qr/if \(!doubleClickHandler\) \{ return; \}/,
	'with no handler the dblclick listener changes nothing');
like($engine, qr/if \(inBand\(e\.clientY\)\) \{ return; \}/,
	'the dblclick respects the furniture band guard');
like($engine, qr/cancelPendingClick\(\);\n\t\t\tvar dim = size\(\);/,
	'a dblclick cancels the delayed single-click callback');
like($engine, qr/function fireMapClickSoon\(sx, sy\) \{/,
	'a plain click can be delayed while a double-click is possible');
like($engine, qr/\}, 260\);/,
	'the single-click delay is about 260 ms');
like($engine, qr/if \(doubleClickHandler\) \{\n\t\t\t\t\t\t\tvar dim = size\(\);/,
	'a touch double-tap reaches the handler too');

# ---- CORS: the provider rows say which services can be read back ----------
like($engine, qr/im\.crossOrigin = 'anonymous';/,
	'the tile loader asks for CORS');
like($engine, qr/im\.crossOrigin = 'anonymous';.*?im\.src = u;/s,
	'crossOrigin is set before the tile url is requested');
like($engine, qr/var plain = new Image\(\);/,
	'a tile that refuses CORS is retried once without it');
like($engine, qr/tileReadFailed\[key\] = true;/,
	'that fallback is remembered');
like($engine, qr/canReadTiles: function \(\) \{/,
	'the engine exposes canReadTiles()');
like($engine, qr/return !!\(p && p\.cors\) && !tileReadFailed\[k\];/,
	'it is true only for a CORS provider with no failed tile');

my @cors = qw(osm topo osm_hot cyclosm esri esri_street esri_topo esri_light
	esri_natgeo carto maptiler mapbox stadia thunderforest lambton custom);
for my $key (@cors) {
	like($engine, qr/^\s*\Q$key\E:\s*\{[^\n]*cors: true/m,
		"provider $key carries cors: true");
}
for my $key (qw(none house)) {
	unlike($engine, qr/^\s*\Q$key\E:\s*\{[^\n]*cors:/m,
		"provider $key does not claim CORS");
}

# ---- the trace itself ------------------------------------------------------
like($trace, qr/function homePlateTraceWater\(opts\) \{/,
	'the trace script defines homePlateTraceWater(opts)');
like($trace, qr/window\.homePlateTraceWater = homePlateTraceWater;/,
	'it is exported on window');
like($trace, qr/ctx\.getImageData\(0, 0, W, H\)/,
	'it reads the map canvas pixels with getImageData');
like($trace, qr/map\.canReadTiles\(\)/,
	'it refuses a canvas the engine says cannot be read');
like($trace, qr/ok: false, error:/,
	'a refusal is returned as ok:false with an error');
like($trace, qr/shape: 'polygon'/,
	'a successful trace returns a polygon area');
like($trace, qr/map\.unproject\(simple\[i\]\[0\], simple\[i\]\[1\]\)/,
	'each polygon point is converted with map.unproject');
like($trace, qr/4-connected|reachIf\(match, core, visited, stack/,
	'growth is 4-connected and may cross the line\'s own stroke');
like($trace, qr/simplifyLoop\(poly, 2, MAX_POINTS\)/,
	'the boundary is simplified with Douglas-Peucker');
like($trace, qr/var MAX_POINTS = 120;/,
	'the polygon cap is 120 points');

done_testing();
