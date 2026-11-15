# tests-for: templates/travel/travel.html.ep public/js/manager/travel.js public/js/manager/travel/03_near3d.js public/js/manager/travel/04_globe.js public/js/three.min.js scripts/fetch_cesium.sh perl/help/topics_people.pl lib/JawnOS.pm
# covers:    the Travel long press's menu and the three views behind it: the
#            street preview, the three.js model of measured maps and places, and
#            the Cesium globe (local build only, no third-party script origin)

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

my $root = root();

# ---- the window has a layer for each new view ----------------------------
# The overlays live in the template, the same shape as #travel_street, so the
# renderers only own their stage and never have to invent window chrome.
my $template = read_file("$root/templates/travel/travel.html.ep");
for my $id (qw(travel_3d travel_3d_stage travel_3d_title travel_3d_close travel_3d_reset travel_3d_note
		travel_globe travel_globe_stage travel_globe_title travel_globe_close travel_globe_status)) {
	like( $template, qr/id="$id"/, "the window carries #$id" );
}
like( $template, qr/long-press for street view, 3D or globe/, 'the hint names the three views' );

# ---- the long press asks, rather than assuming street view ----------------
my $travel_js = read_file("$root/public/js/manager/travel.js");
like( $travel_js, qr/onLongPress\(function\(lat, lon, sx, sy\) \{ travelViewMenu\(lat, lon, sx, sy\); \}\)/,
	'the long press opens the view menu at the press point' );
like( $travel_js, qr/function travelViewMenu\(lat, lon, sx, sy\)/, 'the menu is built there' );
like( $travel_js, qr/jawnosT\('Photos \/ street view'\)/, 'one row is the existing street preview' );
like( $travel_js, qr/jawnosT\('3D model'\)/, 'one row is the three.js model' );
like( $travel_js, qr/jawnosT\('Globe'\)/, 'one row is the globe' );
like( $travel_js, qr/travelStreetPreview\(at\.lat, at\.lon, at\.sx, at\.sy\)/,
	'Photos / street view still calls the preview card, where Set a plate here lives' );
like( $travel_js, qr/travelNear3dOpen\(at\.lat, at\.lon\)/, '3D model calls the three.js view' );
like( $travel_js, qr/travelGlobeOpen\(at\.lat, at\.lon\)/, 'Globe calls the Cesium view' );
like( $travel_js, qr/'background-color': 'var\(--panel\)'/, 'the menu wears the guess menu\'s panel colour' );
like( $travel_js, qr/border: '2px solid var\(--line\)'/, 'and its 2px line and rounded edge' );
like( $travel_js, qr/closest\('#travel_view_menu'\)/, 'a press away folds the menu' );

# ---- the 3D model: three.js on demand, local metres on the ground ---------
my $near3d = read_file("$root/public/js/manager/travel/03_near3d.js");
like( $near3d, qr/^function travelNear3dOpen\(lat, lon\)/m, 'travelNear3dOpen is the view\'s entry point' );
like( $near3d, qr{script\.src = '/js/three\.min\.js'}, 'three.js is injected on first use' );
like( $near3d, qr/window\.THREE/, 'and reused once it is present' );
like( $near3d, qr/window\.jawnosMap\.mapBounds\(m\)/, 'each measured map is placed by the engine\'s bounds' );
like( $near3d, qr/var MPD = 111194\.9;/, 'the projection uses metres per degree' );
like( $near3d, qr/Math\.cos\(centre\.lat \* Math\.PI \/ 180\)/, 'narrowed by cos(latitude), as jawnosMarkerMetres is' );
like( $near3d, qr/z: -\(latitude - centre\.lat\) \* MPD/, 'and z is negated so north is -z' );
like( $near3d, qr/var covers = centre\.lat <= bounds\.nw\.lat && centre\.lat >= bounds\.se\.lat/,
	'only a map that covers the pressed ground sets the opening distance' );
like( $near3d, qr/if \(covers\) \{ span = Math\.max\(span, widthM, heightM\); \}/,
	'a measured map elsewhere in the county still draws without pulling the camera to it' );
like( $near3d, qr/var pinSpan = 0, pinSeen = 0;/, 'the places near the press frame the opening view' );
like( $near3d, qr/var framed = pinSeen > 0 \? Math\.max\(40, pinSpan\) : span;/,
	'a house\'s places beat the county map that covers them, and the map is the fallback' );
like( $near3d, qr/function declutterTags\(\)/, 'labels that would sit on each other are dropped' );
like( $near3d, qr/^\t\tdeclutterTags\(\);$/m, 'and the declutter runs on every render' );
like( $near3d, qr/tags\.unshift\(\{ sprite: hereTag/, 'the machine\'s own tag keeps the first place on screen' );
like( $near3d, qr/fine\.position\.y = 0\.08;/, 'the grid draws above the map plates, not under a pale one' );
like( $near3d, qr/travelAllMaps/, 'the last atlas answer supplies the maps' );
like( $near3d, qr/mapData && mapData\.near/, 'the nearby places come from the viewer response' );
like( $near3d, qr/travelPlateList/, 'home plates are drawn as houses' );
like( $near3d, qr/guessed \? 0\.32 : 1/, 'a guessed gap is drawn at lower opacity' );
like( $near3d, qr/LineDashedMaterial/, 'and wears a dashed edge' );
like( $near3d, qr/This browser cannot draw WebGL/, 'no WebGL is said in the overlay, not thrown' );
like( $near3d, qr/function travelNear3dClose/, 'the view has a close' );
like( $near3d, qr/\.dispose\(\)/, 'and disposes its scene on close' );
like( $near3d, qr/window\.removeEventListener\('resize'/, 'and lets go of its resize handler' );
unlike( $near3d, qr/\$\('#travel_3d_stage'\)\.empty\(\)/,
	'close leaves the template\'s note element in the stage' );
like( $near3d, qr/st\.canvas\.parentNode\.removeChild\(st\.canvas\)/,
	'and removes only the renderer canvas' );

# ---- the globe: the local build only, and it says so when absent ---------
my $globe = read_file("$root/public/js/manager/travel/04_globe.js");
like( $globe, qr/^function travelGlobeOpen\(lat, lon\)/m, 'travelGlobeOpen is the globe\'s entry point' );
like( $globe, qr/window\.CESIUM_BASE_URL = '\/js\/cesium\/'/, 'CESIUM_BASE_URL points at the local build' );
like( $globe, qr{'/js/cesium/Cesium.js'}, 'the local Cesium.js path is there' );
unlike( $globe, qr/jsdelivr/, 'no third-party script origin is used' );
like( $globe, qr/CesiumJS is not installed on this machine/, 'a missing build says how to install it' );
like( $globe, qr/new Cesium\.OpenStreetMapImageryProvider/, 'imagery is keyless OpenStreetMap' );
like( $globe, qr/baseLayerPicker: false/, 'the base layer picker is off' );
like( $globe, qr/geocoder: false/, 'the geocoder is off' );
like( $globe, qr/animation: false/, 'animation is off' );
like( $globe, qr/timeline: false/, 'the timeline is off' );
like( $globe, qr/sceneModePicker: false/, 'the scene mode picker is off' );
like( $globe, qr/navigationHelpButton: false/, 'the navigation help is off' );
like( $globe, qr/infoBox: false/, 'the info box is off' );
like( $globe, qr/selectionIndicator: false/, 'the selection indicator is off' );
like( $globe, qr/viewer\.camera\.flyTo/, 'the camera flies to the pressed ground' );
like( $globe, qr/viewer\.destroy\(\)/, 'close destroys the viewer' );

# ---- the installer keeps the local path fit for the loader ---------------
my $fetch = "$root/scripts/fetch_cesium.sh";
ok( -f $fetch, 'scripts/fetch_cesium.sh exists' );
ok( -x $fetch, 'and is executable' );
my $fetch_text = read_file($fetch);
like( $fetch_text, qr/^#!\/bin\/sh/m, 'it is POSIX sh' );
like( $fetch_text, qr/VERSION=1\.120/, 'the npm build is pinned' );
like( $fetch_text, qr{public/js/cesium}, 'it unpacks into the loader\'s local path' );
like( $fetch_text, qr{package/Build/Cesium}, 'from the npm tarball\'s Build/Cesium' );
like( read_file("$root/.gitignore"), qr{^public/js/cesium/$}m, 'the installed bundle is gitignored' );

# ---- vendored three.js is a real UMD build, not a stub -------------------
my $three = "$root/public/js/three.min.js";
ok( -f $three, 'public/js/three.min.js is committed' );
cmp_ok( -s $three, '>', 500_000, 'it is the full build' );
my $three_text = read_file($three);
like( $three_text, qr/Three\.js Authors/, 'and carries the three.js licence' );
like( $three_text, qr/THREE/, 'and defines the THREE global' );

# ---- no third-party script origin is admitted for a bonus view -----------
my $jawnos = read_file("$root/lib/JawnOS.pm");
unlike( $jawnos, qr/cdn\.jsdelivr\.net/, 'the policy still names no third-party script or style origin' );
like( $jawnos, qr/"script-src 'self' 'unsafe-inline' 'unsafe-eval'"/, 'and script-src stays the house\'s own origin' );

# ---- the help topic says what the long press now does --------------------
my $help = read_file("$root/perl/help/topics_people.pl");
my ($travel_help) = $help =~ /(\$topic\{'travel'\} = \{.*?\n\t\};)/s;
ok( $travel_help, 'the travel topic is found' );
like( $travel_help, qr/Photos \/ street view/, 'the topic names the street preview' );
like( $travel_help, qr/3D model builds a small scene with three\.js/, 'the topic names the 3D model' );
like( $travel_help, qr/Globe draws the whole world with CesiumJS/, 'the topic names the globe' );
like( $travel_help, qr/fetch_cesium\.sh/, 'and how to install Cesium locally' );
like( $travel_help, qr/Nothing is fetched from the open internet/, 'and that the globe fetches nothing from the open internet' );

done_testing();
