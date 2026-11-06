# tests-for: public/js/manager/manager/04_search.js public/js/manager/keyboard/01_side_dock.js public/js/manager/soft_keyboard.js public/css/soft_keyboard.css
# covers:    the app-search dropdown under the dock's search box was measured
#           against window.innerHeight, which a phone's or tablet's keyboard
#           does not change, and typing on an input method never drew it at
#           all: the list was placed under the keys, and a composed character
#           only fires `input`, not `keyup`.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# The dock's search box sits at the screen's foot and its app list is placed in
# script. The JawnOS keyboard is an element in the page, so its own top edge is
# known; a platform keyboard only shrinks the visual viewport, so the placement
# has to ask the visual viewport where the visible page ends. The keyboard also
# lifts the box flush to that edge (no band between them), and an input method
# commits text without a keyup, so the box listens for `input` too.

my $root = repo_root();
my $search = read_file("$root/public/js/manager/manager/04_search.js");
my $dock = read_file("$root/public/js/manager/keyboard/01_side_dock.js");
my $kb = read_file("$root/public/js/manager/soft_keyboard.js");
my $css = read_file("$root/public/css/soft_keyboard.css");

# --- the visible page, not the layout viewport -------------------------------
like($search, qr/window\.visualViewport\.offsetTop/,
	'the dropdown reads the visual viewport, where a platform keyboard lives');
like($search, qr/view_bottom = Math\.min\(view_bottom, view_top \+ window\.visualViewport\.height\)/,
	'the visible floor is the visual viewport bottom, never past the window');
like($search, qr/var input_visible = rect\.top < view_bottom;/,
	'a box behind the keyboard is detected');
like($search, qr/place_below = input_visible &&/,
	'a covered box is never answered with a list below it');
like($search, qr/drop\['bottom'\] = vh - \(input_visible \? rect\.top : view_bottom\) \+ gap;/,
	'an otherwise hidden list hooks onto the keyboard top');
like($search, qr/getPropertyValue\('--soft_kb_h'\)/,
	'the in-page keyboard bounds the list by its lifted edge');
like($search, qr/visualViewport\.addEventListener\('resize', jawnosSearchResultsReposition\)/,
	'the list follows the keyboard as it slides in and out');
like($search, qr/visualViewport\.addEventListener\('scroll', jawnosSearchResultsReposition\)/,
	'and follows a panned visual viewport');

# --- a bottom dock owns the room below the box -------------------------------
like($search, qr/var dock_bottom = in_dock/,
	'the placement knows when the box rides a bottom dock');
like($search, qr/place_below = input_visible && !dock_bottom &&/,
	'a bottom dock never answers with a list drawn across its own row');

# --- an input method types without keyup -------------------------------------
like($search, qr/\$\(document\)\.on\('input keyup click', '#search'/,
	'the box draws the list from `input` as well as `keyup`');
like($search, qr/else if \(e\.type == 'input'\) \{/,
	'an input-method commit clears the chosen Enter like typing does');

# --- the keyboard measures its own top edge ----------------------------------
like($kb, qr/function softKbLift\(dock\)/,
	'the keyboard measures the lift it gives the bars');
like($kb, qr/getBoundingClientRect\(\)\.top/,
	'from its own top edge, not only its outer height');
like($kb, qr/var lift = softKbLift\(dock\);/,
	'both the search lift and the field reserve use that edge');
like($kb, qr/setProperty\('--soft_kb_h', lift \+ 'px'\)/,
	'the lift the stylesheet reads is the measured edge');
like($kb, qr/softKbReserve\(\);\s*\}, softKbSlideMs\(\) \+ 60\);/,
	'the lift is measured again once the keyboard has settled');

# --- the box sits on the keys, not 8px above them ----------------------------
like($css, qr/bottom: var\(--soft_kb_h, 0px\) !important;/,
	'the lifted search box sits flush on the keyboard');
unlike($css, qr/--soft_kb_h, 0px\) \+ 8px/,
	'the band that used to sit between them is gone');

# --- one placement helper, not three hand-rolled offsets ---------------------
unlike($dock, qr/\$\('#search_results'\)\.css\(/,
	'the dock no longer positions the dropdown by hand');
unlike($dock, qr/\$\('window'\)\.height\(\) - o\.top/,
	'the layout-viewport offset that put the list under the keys is gone');
my @shared = ($dock =~ /jawnosSearchResultsPlace\(\)/g);
is(scalar @shared, 3,
	'the three dock show/tuck paths all ask the shared, keyboard-aware placement');

done_testing();
