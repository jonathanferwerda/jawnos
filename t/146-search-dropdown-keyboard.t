# tests-for: public/js/manager/manager/04_search.js public/js/manager/keyboard/01_side_dock.js
# covers:    the app-search dropdown under the dock's search box was measured
#           against window.innerHeight, which a phone's or tablet's platform
#           keyboard does not change: the list was placed below the box and
#           drew under the keys.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# The dock's search box sits at the screen's foot and its app list is placed in
# script. The JawnOS keyboard is an element in the page, so its top is known;
# a platform keyboard only shrinks the visual viewport, so the placement has to
# ask the visual viewport where the visible page ends.

my $root = repo_root();
my $search = read_file("$root/public/js/manager/manager/04_search.js");
my $dock = read_file("$root/public/js/manager/keyboard/01_side_dock.js");

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
like($search, qr/kb_top = vh - \(kb\.outerHeight\(\) \|\| 0\)/,
	'the in-page JawnOS keyboard still caps the list');
like($search, qr/visualViewport\.addEventListener\('resize', jawnosSearchResultsReposition\)/,
	'the list follows the keyboard as it slides in and out');
like($search, qr/visualViewport\.addEventListener\('scroll', jawnosSearchResultsReposition\)/,
	'and follows a panned visual viewport');

# --- one placement helper, not three hand-rolled offsets ---------------------
unlike($dock, qr/\$\('#search_results'\)\.css\(/,
	'the dock no longer positions the dropdown by hand');
unlike($dock, qr/\$\('window'\)\.height\(\) - o\.top/,
	'the layout-viewport offset that put the list under the keys is gone');
my @shared = ($dock =~ /jawnosSearchResultsPlace\(\)/g);
is(scalar @shared, 3,
	'the three dock show/tuck paths all ask the shared, keyboard-aware placement');

done_testing();
