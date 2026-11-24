# tests-for: public/js/manager/keyboard.js public/js/manager/keyboard/01_side_dock.js public/js/manager/soft_keyboard.js public/js/manager/leaderboardprinter.js public/js/manager/printer_common.js
# covers:    Opening the keyboard or calculator from the dock with no field
#            removed the dock (body.soft_kb_open) but never raised the keys,
#            which sat at their closed translateY(100%) until a refresh. And the
#            dock's hider read the pointer through window.event, which is unset
#            in the timer that runs it, so it could tuck the dock while the
#            pointer was resting on it. The hider now reads the shared pointer
#            the universal recorder keeps (a capture-phase native listener),
#            and a tap moves that pointer to the tap point; it then tests the
#            dock's showing box, its faces and the tucked strip. A
#            dock with only widgets or pins used to be unreachable while its
#            strip was the search row: an idle empty search row now opens the
#            dock menu (a search with text or focus keeps paste). An empty dock
#            tucks like any other rather than sitting out full size: the strip it
#            keeps is still the way back to the menu that puts a face in it. A
#            touch screen has no hover, so a tap on the background now tucks the
#            dock the way a mouse leaving it does.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use RepoSource;

my $dock = js_source('public/js/manager/keyboard/01_side_dock.js');
my $kbd = js_source('public/js/manager/keyboard.js');
my $kb = js_source('public/js/manager/soft_keyboard.js');

# --- no field still raises the keys -----------------------------------------
my ($dock_open) = $kb =~ /function softKbDockOpen\(mode\) \{(.*?)\n\}/s;
ok(defined $dock_open && length $dock_open, 'the dock open handler is found');
like($dock_open, qr/softKbPlace\(null\);\s*dock\.prop\('hidden', false\)[\s\S]*?softKbSlideUp\(dock\);/,
	'the no-field path raises the keys instead of leaving them closed');
like($dock_open, qr/softKbSlideUp\(dock\);\s*\$\('body'\)\.addClass\('soft_kb_open'\)/,
	'the keys rise before the dock is hidden for them');
unlike($dock_open, qr/dock\.prop\('hidden', false\)\.attr\('aria-hidden', 'false'\);\s*\$\('body'\)\.addClass\('soft_kb_open'\)/,
	'the bug - unhiding without sliding - is gone');

# --- the hider knows where the pointer is -----------------------------------
unlike($dock, qr/\$\(document\)\.on\('mousemove'/, 'the dock keeps no second pointer listener');
unlike($dock, qr/pseudonymPointerX/, 'and no separate copy of the point');

# --- the hider knows both dock geometries -----------------------------------
like($dock, qr/function pseudonymDockPointOnDock\(x, y\)/,
	'one helper answers whether a point is on the dock');
like($dock, qr/getBoundingClientRect\(\)/, 'it measures the dock as it is laid out');
like($dock, qr/getElementById\('pseudonym_home'\)/,
	'the home box covers the showing row and the tucked strip');
like($dock, qr/find\('\.pseudonym, #search_entanglement'\)/,
	'the faces cover a row that overhangs the box');
like($dock, qr/pseudonymDockStrip\(\)/, 'the tucked strip is measured too');
like($dock, qr/jawnosDockTop\(\)/, 'the top edge has its own strip');
like($dock, qr/jawnosSideDock\(\)/, 'a side dock has its own strip');

# --- the hider uses them, through the shared pointer -----------------------
my ($hider) = $dock =~ /function pseudonymHomeHider\(interval\) \{(.*?)\n\}/s;
ok(defined $hider && length $hider, 'the hider is found');
like($hider, qr/var m = mouse_position\(\);\s*var x = m\.x;\s*var y = m\.y;/, 'the hider reads the live pointer');
unlike($hider, qr/pseudonymPointerX/, 'there is no separate copy to fall back to');
like($hider, qr/pseudonymDockPointOnDock\(x, y\)/,
	'a point inside either dock position counts as on the dock');
my ($shower) = $dock =~ /function pseudonymHomeShower\(x,y,interval\) \{(.*?)\n\}/s;
ok(defined $shower && length $shower, 'the shower is found');
like($shower, qr/pseudonymDockPointOnDock\(x, y\)/,
	'the shower uses the same position test');

# --- a search strip still holds a way to the dock menu ----------------------
# The tucked strip is the search row when the search rides the dock. A dock
# carrying only widgets or pins had no other way out, and its only background is
# the search. An idle empty search row now opens the dock menu; a search with
# text or the focus keeps its native paste menu.
like($kbd, qr/var typing = input\.length && \(input\.val\(\) \|\| input\.is\(':focus'\)\);/,
	'a search with text or focus keeps its own menu');
like($kbd, qr/if \(typing \|\| results\) \{ return; \}/,
	'an idle empty search row opens the dock menu');
like($kbd, qr/target\.closest\('\.pseudonym_bar \.pseudonym'\)\.length/,
	'a face still keeps its own menu');
like($kbd, qr/if \(typeof jawnosDockReveal == 'function'\) \{ jawnosDockReveal\(\); \}\s*jawnosDockMenuPlace\(jawnosDockContextBuild\(\$\(this\)\), e\.clientX, e\.clientY\);/,
	'opening the menu calls the dock out of a tuck');
like($shower, qr/pseudonymDockFacesShow\(\);/, 'the reveal calls for every face the dock switches allow');
like($dock, qr/function pseudonymDockFacesShow\(\)[\s\S]{0,400}jawnosDockFaceAlwaysOn\(icon\)/,
	'a dock-owned face is shown by the reveal too');

# --- a tuck carries the row's faces, not just its backing -------------------
like($dock, qr/function pseudonymDockFacesShift\(dy\)[\s\S]{0,300}translateY/,
	'a row tuck shifts the faces by the same distance');
like($hider, qr/pseudonymDockFacesShift\(edge - diff\);/,
	'the bottom hider carries the faces down with the home');
like($dock, qr/var tuck = Math\.min\(0, pseudonymDockStrip\(\) - home\.outerHeight\(\)\);[\s\S]{0,120}pseudonymDockFacesShift\(tuck\);/,
	'the top settle carries them up');
like($kbd, qr/var tucked_edge = row_style \? parseFloat\(dock_top \? row_style\.top : row_style\.bottom\) : NaN;/,
	'the finder reads the tucked inline edge');
like($kbd, qr/pseudonymDockFacesShift\(dock_top \? Math\.min\(0, strip_now - home_h\) : Math\.max\(0, home_h - strip_now\)\)/,
	'and recomputes the shift for the new layout, or clears it once revealed');

# --- an empty dock tucks to its strip, not out full size --------------------
like($kbd, qr/home\.toggleClass\('dock_empty', visible\.length == 0\)/,
	'an empty dock is marked');
like($kbd, qr/if \(icons_hidden && !search_in_dock\)/,
	'an empty row dock stays on screen unless Hide icons was chosen');
# The strip the tuck keeps is the search row (or the sliver) - the same target
# that opens the dock menu and calls the row back out.
unlike($hider, qr/hasClass\('dock_empty'\)/,
	'the hider does not spare an empty dock');
like($hider, qr/var diff = Math\.min\(0, pseudonymDockStrip\(\) - h\) \+ edge;/,
	'an empty dock tucks to the same strip as any other row');
unlike($dock, qr/if \(tucked && \$\('#pseudonym_home'\)\.hasClass\('dock_empty'\)\)/,
	'a side dock tucks even when empty');
unlike($dock, qr/if \(home\.hasClass\('dock_empty'\)\)/,
	'a top dock tucks even when empty');

# --- a background tap tucks the dock on a touch screen -----------------------
like($dock, qr/function pseudonymHomeTapper\(x, y\) \{/,
	'one handler answers a tap on the background');
like($dock, qr/mouse_position_set\(x, y\);/, 'the tap moves the shared pointer away from the dock');
like($dock, qr/if \(typeof pseudonymDockPointOnDock == 'function' && pseudonymDockPointOnDock\(x, y\)\)/,
	'a tap on the strip still calls the row out');
like($dock, qr/pseudonymHomeHider\(1\);/,
	'a tap elsewhere tucks without waiting out the idle interval');
my $common = js_source('public/js/manager/printer_common.js');
like($common, qr/if \(app_clicked == 0 && device == 'mobile' && typeof pseudonymHomeTapper == 'function'\) \{[\s\S]*?pseudonymHomeTapper\(e\.clientX, e\.clientY\);/,
	'the background tap handler hands the touch to the tapper');
unlike($common, qr/pseudonymHomeShower\(ph\.left \+ 3, ph\.top \+ 3\);/,
	'the reveal is no longer hand-rolled in the background handler');
unlike(js_source('public/js/manager/leaderboardprinter.js'), qr/pseudonymHomeTapper\(e\.clientX, e\.clientY\);/,
	'the tap handler is in the core file, not the lazy printer');

done_testing();
