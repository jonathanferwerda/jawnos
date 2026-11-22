# tests-for: templates/configure/home_plate_map.html.ep templates/configure/home_plate.html.ep templates/configure/me_setting_list.html.ep public/js/manager/configure/09_home_plate_map.js public/js/manager/configure/04_currency_backup.js public/js/manager/configure/05_database_records.js public/js/manager/configure.js public/js/manager/mapmarkers.js public/js/manager/travel.js public/js/manager/travel/01_map_render_points.js lib/JawnOS/Controller/manager_configure5.pm lib/JawnOS/Routes/manager_configure5.pm lib/JawnOS/Controller/manager_misc10.pm
# covers:    the map editor is the only place a plate's ground is defined:
#            drag or click a flag, draw a circle/box/path/polygon, trace a river,
#            cache OSM branches for a pattern, and save the whole flag at once;
#            the editor loads the lazy travel basemap before it draws

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

my $root = root();

my $map_partial = read_file("$root/templates/configure/home_plate_map.html.ep");
my $panel        = read_file("$root/templates/configure/home_plate.html.ep");
my $me           = read_file("$root/templates/configure/me_setting_list.html.ep");
my $editor       = read_file("$root/public/js/manager/configure/09_home_plate_map.js");
my $ability      = read_file("$root/public/js/manager/configure/04_currency_backup.js");
my $records      = read_file("$root/public/js/manager/configure/05_database_records.js");
my $bundle       = read_file("$root/public/js/manager/configure.js");
my $markers      = read_file("$root/public/js/manager/mapmarkers.js");
my $travel       = read_file("$root/public/js/manager/travel.js");
my $travel_points= read_file("$root/public/js/manager/travel/01_map_render_points.js");
my $controller   = read_file("$root/lib/JawnOS/Controller/manager_configure5.pm");
my $routes       = read_file("$root/lib/JawnOS/Routes/manager_configure5.pm");
my $misc         = read_file("$root/lib/JawnOS/Controller/manager_misc10.pm");

# --------------------------------------------------------------- the map partial
like( $map_partial, qr/class="home_plate_editor"/, 'the partial renders the editor' );
like( $map_partial, qr/class="home_plate_map"/, 'with the jawnosMap canvas' );
like( $map_partial, qr/class="home_plate_flag_tool"[^>]*draggable="true"/, 'the flag can be dragged onto the map' );
like( $map_partial, qr/data-shape="circle"/, 'the circle tool is on the toolbar' );
like( $map_partial, qr/data-shape="box"/, 'the box tool is on the toolbar' );
like( $map_partial, qr/data-shape="path"/, 'the path tool is on the toolbar' );
like( $map_partial, qr/data-shape="polygon"/, 'the polygon tool is on the toolbar' );
like( $map_partial, qr/data-shape="trace"/, 'the trace tool is on the toolbar' );
like( $map_partial, qr/class="home_plate_add_pattern"/, 'a pattern flag can be added' );
like( $map_partial, qr/class="home_plate_find_branches"/, 'a pattern searches OSM branches' );
like( $map_partial, qr/class="home_plate_add_branch"/, 'and a branch can be placed by hand' );
like( $map_partial, qr/class="home_plate_data"/, 'the plate data rides as JSON' );
like( $map_partial, qr/<%== \$payload %>/, 'and is written unescaped inside the script tag' );

# ------------------------------------------------------------- the app panel
like( $panel, qr/include 'configure\/home_plate_map'/, 'the app panel includes the map' );
unlike( $panel, qr/class="manual_home_plate"/, 'the manual latitude input is gone' );
unlike( $panel, qr/setting="latitude"/, 'and the per-flag latitude input is gone' );
unlike( $panel, qr/setting="longitude"/, 'and the per-flag longitude input is gone' );
unlike( $panel, qr/setting="distance"/, 'and the per-flag radius input is gone' );
like( $panel, qr/class="home_plate_setting" setting="placement"/, 'placement stays on the card' );
like( $panel, qr/class="home_plate_setting" setting="action"/, 'action stays on the card' );
like( $panel, qr/class="home_plate_setting" setting="device"/, 'device stays on the card' );
like( $panel, qr/class="home_plate_edit"/, 'each flag can be opened on the map' );

# -------------------------------------------------------------- the Me panel
like( $me, qr/include 'configure\/home_plate_map'/, 'Me gets the same map editor' );
unlike( $me, qr/class="manual_home_plate"/, 'and loses the manual latitude/longitude inputs' );

# ------------------------------------------------------------------ the editor
like( $editor, qr/function homePlateInitAll/, 'the editor initialises every visible panel' );
like( $editor, qr/onMapDoubleClick/, 'double-click is the drawing gesture' );
like( $editor, qr/function homePlateNewFlag/, 'the toolbar flag creates a flag' );
like( $editor, qr/function homePlateFlagMenu/, 'the flag has a context menu' );
like( $editor, qr/Delete flag/, 'with a delete entry' );
like( $editor, qr/Duplicate flag/, 'and a duplicate entry' );
like( $editor, qr#/manager/travel/branches#, 'a pattern asks the branch lookup' );
like( $editor, qr/window\.homePlateTraceWater/, 'the trace is handed to the water reader' );
like( $editor, qr#/manager/configure/home_plate/shape#, 'the save posts the whole flag' );
like( $editor, qr/function homePlateDropFlag/, 'the card delete updates the map too' );
like( $editor, qr/mapOpts\.vector/, 'the map hands the engine the house vector basemap loader' );
like( $editor, qr/function homePlateBasemapReady/, 'the editor knows when that loader is present' );
like( $editor, qr/jawnosLoadApp\('travel'/, 'a Configure page asks for the lazy travel chunk instead of drawing a blank map' );
like( $editor, qr/!st\.basemapAsked/, 'and asks only once per editor' );
like( $editor, qr/st\.basemapPending/, 'a second init waits for the chunk instead of drawing the fallback' );
like( $editor, qr/provider = homePlateBasemapReady\(\) \? 'house' : 'osm'/, 'a ground of None still gives the editor the house map' );
like( $editor, qr/st\.ground\.provider = provider/, 'and the dropdown shows what is actually drawn' );
like( $editor, qr/setTimeout\(build, 10000\)/, 'a chunk that never arrives still builds the map' );

# ----------------------------------------------------------- the card handlers
unlike( $records, qr/\$\(document\)\.on\('change', '\.manual_home_plate'/, 'the manual lat/long handler is gone' );
like( $records, qr/\.home_plate_setting\[uuid="' \+ uuid \+ '"\]/, 'the card save reads its own fields (the selector is closed)' );
like( $records, qr/homePlateReload/, 'and reloads the map after a re-render' );
like( $records, qr/homePlateDropFlag/, 'and drops a flag from the map after a delete' );

like( $bundle, qr/09_home_plate_map\.js/, 'the split manifest names the editor' );
like( $bundle, qr/10_home_plate_trace\.js/, 'and the trace part' );
like( $bundle, qr/homePlateInitAll\(c\)/, 'opening a Configure tab initialises its map' );

# ------------------------------------------------------------- shared drawing
like( $markers, qr/function jawnosPlateAreaDraw/, 'the area painter is shared' );
like( $markers, qr/shape === 'polygon'/, 'and draws a polygon' );
like( $travel, qr/onDraw\(travelPlateAreasDraw\)/, 'Travel draws the plate ground' );
like( $travel_points, qr/function travelPlateAreasDraw/, 'from the /manager/home_plates answer' );
like( $misc, qr/areas => &subs::plate_areas\(\$ground\)/, 'the home_plates route hands the areas to the map' );

# --------------------------------------------------------------- the save route
like( $routes, qr#\[54102, 'post', '/manager/configure/home_plate/shape', 'action_54102'\]#, 'the shape route is in the route table' );
like( $controller, qr/sub action_54102/, 'and its action exists' );
like( $controller, qr/&subs::plate_normalize\(\$plate\)/, 'the saved flag is normalized' );
like( $controller, qr/my \(\$existing\) = grep \{ ref \$_ eq 'HASH' && \(\$_->\{'uuid'\} \|\| ''\) eq \(\$home_plate->\{'uuid'\} \|\| ''\) \}/, 'the card save merges into the stored flag' );
like( $controller, qr/home_plate_duties/, 'and a uuid joins the flags list' );

# --------------------------------------------- the browser-probe regressions
# A cleared flag is empty, not a legacy circle rebuilt from its old mirror.
like( $editor, qr/!\('areas' in plate\)/, 'the editor does not resurrect a cleared area list from the old point' );
like( $editor, qr/hit\.plate\.areas = \[\];/, 'deleting a legacy point clears its ground' );
like( $editor, qr/hit\.flat = i;/, 'an area hit carries its flattened entry index' );
like( $editor, qr/st\.area = \(hit\.flat !== undefined\) \? hit\.flat : hit\.index;/, 'selection uses the flattened index for branch areas' );
like( $editor, qr/legacy\.areas = legacy\.areas \|\| \[\];/, 'a legacy point is materialised before its radius is edited' );
like( $editor, qr/else \{ input\.val\(st\.width \|\| 200\); \}/, 'the radius box reflects the saved width after a reload' );
like( $editor, qr/if \(value <= 0\) \{ return; \}/, 'a blank or negative radius is not written' );
like( $editor, qr/homePlateSyncWidth\(st\);/, 'the map syncs the radius control after init, reload and select' );
like( $editor, qr/k === 'custom' \|\| k === 'lambton' \|\| k === 'none'/, 'the provider picker does not offer a blank None ground' );
like( $editor, qr/st\.ground\.provider = provider;/, 'choosing a provider updates the editor state' );
like( $editor, qr/document\.addEventListener\('toggle'/, 'a details card initialises its map when it opens' );
like( $editor, qr/st\.map\.canvas !== canvas/, 'a stale canvas is re-initialised on a click' );
like( $editor, qr/getData\('text\/plain'\)/, 'a drop must carry this editor\'s flag key' );
like( $editor, qr/home_plate_branch_results/, 'a second branch search replaces the first result box' );
like( $editor, qr/homePlateStatus\(freshState/, 'the save message survives the server re-render' );
like( $panel, qr/\$device_found/, 'a card keeps a device the current list no longer carries' );
like( $ability, qr/homePlateInitAll\(input\)/, 'opening the hidden Home Plate ability initialises the map' );
like( $records, qr/\.filter\(function\(\) \{/, 'the card save finds its app without a CSS attribute selector' );
unlike( $records, qr/console\.log/, 'the card save is not left logging its payload' );
like( $controller, qr/sub action_25688/, 'the legacy distance write still exists for old clients' );
like( $controller, qr/&subs::plate_normalize\(\$data\)/, 'it writes a real shape instead of a bare point' );
unlike( $controller, qr/my \$homeplate = eval/, 'and keeps no unused legacy plate read' );
like( $misc, qr/next unless ref \$d eq 'HASH'/, 'the home-plates route skips a malformed duty' );
like( $misc, qr/next unless scalar \@\{ &subs::plate_areas\(\$ground\) \}/, 'it does not draw a cleared flag' );

done_testing();
