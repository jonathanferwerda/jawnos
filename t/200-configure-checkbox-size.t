# tests-for: templates/configure/configure.html.ep templates/configure/appointment_list/style.html.ep
# covers:    The Configure panels' row-sizing rules skip a checkbox and a radio.
#            `.cfg-row > input { flex:1 1 220px }` matched every input, so a
#            toggle grew to the row's 220px basis - a 244x13 bar instead of a
#            30x30 box. The same exclusion holds in the narrow (<=560px) row,
#            and for an input inside a `.cfg-row > span` on the App panel.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);

my $root = "$FindBin::Bin/..";
my $configure = read_file("$root/templates/configure/configure.html.ep");
my $app_style = read_file("$root/templates/configure/appointment_list/style.html.ep");

# The wide row: a text field takes the 220px basis, a checkbox keeps its square.
like($configure,
	qr/\.cfg-row\s*>\s*input:not\(\[type=checkbox\]\):not\(\[type=radio\]\)[^{]*\{[^}]*flex:\s*1\s+1\s+220px/,
	'the wide row gives a checkbox/radio its own box, not the 220px basis');

# The narrow row (<=560px) is a column, and its full width must not reach a box.
like($configure,
	qr/\.cfg-row\s*>\s*input:not\(\[type=checkbox\]\):not\(\[type=radio\]\)[^{]*\{[^}]*width:100%/,
	'the narrow row does not stretch a checkbox to 100%');

# The App panel gives a span's field the full span; the checkbox in a span (the
# clock-alarm toggle) keeps its square too.
like($app_style,
	qr/\.cfg-row\s*>\s*span\s*>\s*input:not\(\[type=checkbox\]\):not\(\[type=radio\]\)[^{]*\{[^}]*width:100%/,
	'an App card checkbox inside a row span is not stretched');

# Guard: no unqualified flex rule is left that would take the 220px basis again.
unlike($configure,
	qr/\.cfg-row\s*>\s*input\s*,\s*\.cfg-row\s*>\s*select[^{]*\{[^}]*flex:\s*1\s+1\s+220px/,
	'no raw .cfg-row > input rule still takes the 220px basis');

done_testing();
