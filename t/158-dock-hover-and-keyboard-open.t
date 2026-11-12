# tests-for: public/js/manager/keyboard.js public/js/manager/keyboard/01_side_dock.js public/js/manager/soft_keyboard.js
# covers:    Opening the keyboard or calculator from the dock with no field
#            removed the dock (body.soft_kb_open) but never raised the keys,
#            which sat at their closed translateY(100%) until a refresh. And the
#            dock's hider read the pointer through window.event, which is unset
#            in the timer that runs it, so it could tuck the dock while the
#            pointer was resting on it. The hider now keeps the live pointer and
#            tests the dock's showing box, its faces and the tucked strip. A
#            dock with only widgets or pins used to be unreachable while its
#            strip was the search row: an idle empty search row now opens the
#            dock menu (a search with text or focus keeps paste), and an empty
#            dock never hides itself, so its menu can always put a face back.

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
like($dock, qr/var pseudonymPointerX = null;/, 'the live pointer x is kept');
like($dock, qr/var pseudonymPointerY = null;/, 'the live pointer y is kept');
like($dock, qr/\$\(document\)\.on\('mousemove', function \(e\) \{\s*pseudonymPointerX = e\.clientX;/s,
	'every move updates the pointer');

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

# --- the hider uses them, not a stale window.event --------------------------
my ($hider) = $dock =~ /function pseudonymHomeHider\(interval\) \{(.*?)\n\}/s;
ok(defined $hider && length $hider, 'the hider is found');
like($hider, qr/var x = pseudonymPointerX;/, 'the hider reads the live pointer');
like($hider, qr/if \(x === null \|\| y === null\) \{\s*var m = mouse_position\(\);/s,
	'mouse_position is only the before-first-move fallback');
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
like($kbd, qr/target\.closest\('#pseudonym_bar \.pseudonym'\)\.length/,
	'a face still keeps its own menu');
like($kbd, qr/if \(typeof jawnosDockReveal == 'function'\) \{ jawnosDockReveal\(\); \}\s*jawnosDockMenuPlace\(jawnosDockContextBuild\(\), e\.clientX, e\.clientY\);/,
	'opening the menu calls the dock out of a tuck');
like($shower, qr/jawnosDockFaceAlwaysOn\(kbg\)/,
	'a dock-owned face is shown by the reveal too');

# --- an empty dock keeps a way back to its menu ------------------------------
like($kbd, qr/home\.toggleClass\('dock_empty', visible\.length == 0\)/,
	'an empty dock is marked');
like($kbd, qr/if \(icons_hidden && !search_in_dock\)/,
	'an empty row dock stays on screen unless Hide icons was chosen');
like($hider, qr/hasClass\('dock_empty'\)/,
	'the hider leaves an empty dock on screen');
like($hider, qr/'bottom': \(\(typeof jawnosDockBottomOffset == 'function'\) \? jawnosDockBottomOffset\(\) : 0\)/,
	'and lowers it back from a tuck');
like($dock, qr/if \(tucked && \$\('#pseudonym_home'\)\.hasClass\('dock_empty'\)\) \{ tucked = 0; \}/,
	'a side dock does not tuck when empty');
like($dock, qr/if \(home\.hasClass\('dock_empty'\)\) \{ home\.css\(\{ 'top': jawnosDockTopOffset\(\) \}\); return 1; \}/,
	'a top dock does not tuck when empty');

done_testing();
