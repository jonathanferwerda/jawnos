# tests-for: public/js/universal/07_hints_long_press_multiselect.js
# covers:    a single <select>'s own list could open downward past the foot of
#           the page, so the model lists on Configure -> Plat -> AI showed only
#           the first few options. Where the list would not fit below the box,
#           the press is taken and the list is drawn on screen instead - above
#           the box when that has the room, scrollable when it does not.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $js = read_file("$root/public/js/universal/07_hints_long_press_multiselect.js");

# --- the press is taken only when the browser's own list would not fit --------
like($js, qr/function jawnosSelectMenuHeight\(sel\)/,
	'the picker estimates the height of the list');
like($js, qr/function jawnosSelectMenuNeeds\(sel\)/,
	'and asks whether the native list has room below the box');
like($js, qr/return \(floor - rect\.bottom - 6\) < jawnosSelectMenuHeight\(sel\);/,
	'a list that fits keeps the native menu; one that would not is taken');
like($js, qr/window\.visualViewport\.offsetTop/,
	'the room is measured on the visible page, where a platform keyboard lives');

# --- the list is drawn on screen, on the side with the room ------------------
like($js, qr/var place_below = below >= above;/,
	'the side with more room takes the list');
like($js, qr/var top = place_below \? \(rect\.bottom \+ gap\) : \(rect\.top - gap - height\);/,
	'a box near the foot opens its list above itself');
like($js, qr/top = Math\.max\(top_edge \+ 4, Math\.min\(top, floor - height - 4\)\);/,
	'and the list is clamped inside the visible page');
like($js, qr/\$\(document\)\.on\('mousedown', 'select:not\(\[multiple\]\)'/,
	'a single select takes the press before the native menu opens');
like($js, qr/e\.preventDefault\(\);/,
	'and stops the browser drawing its own list off the page');

# --- every option stays reachable --------------------------------------------
like($js, qr/if \(this\.tagName == 'OPTGROUP'\)/,
	'groups are drawn as headings');
like($js, qr/if \(o\.prop\('disabled'\) \|\| \(group\.length && group\.prop\('disabled'\)\)\) \{ row\.addClass\('ms-disabled'\); \}/,
	'a disabled option (or a disabled group) stays disabled');
like($js, qr/option\.selected = true;\s*\n\s*sel\.dispatchEvent\(new Event\('change', \{ bubbles: true \}\)\);/,
	'choosing a row writes the real select and fires its change');
like($js, qr/if \(sel\.size > 1\) \{ return false; \}/,
	'a list box (size > 1) keeps its own list on the page');
like($js, qr/\.ms-popup \{ box-sizing:border-box;/,
	'the picker\'s border is counted in its height');
like($js, qr/ArrowDown/,
	'the list answers the keyboard');
like($js, qr/scrollIntoView\(\{ block: 'nearest' \}\)/,
	'the chosen row is brought into view');

# --- it never lingers over the page ------------------------------------------
like($js, qr/e\.key === 'Escape'/,
	'Escape puts the list away');
like($js, qr/\.on\('resize', jawnosSelectMenuClose\)/,
	'a resize puts it away');
like($js, qr/e\.target\.closest\('\.jawnos_select_popup'\)/,
	'a scroll elsewhere puts it away, its own scroll does not');

my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
if ($node && -x $node) {
	my $out = `$node --check "$root/public/js/universal/07_hints_long_press_multiselect.js" 2>&1`;
	my $status = $?;
	diag($out) if $status != 0;
	is($status, 0, 'node --check accepts the universal script');
}
else {
	diag('node is not installed; the syntax check is skipped');
}

done_testing();
