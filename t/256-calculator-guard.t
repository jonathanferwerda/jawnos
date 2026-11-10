# tests-for: lib/JawnOS/Manager/Part32.pm lib/JawnOS/Controller/manager_misc12.pm
# covers:    formula_calculator only sends arithmetic to eval. A formula typed
#           at the keyboard (or posted to /manager/calculate) cannot smuggle
#           Perl syntax, quotes, a shell, a variable or a semicolon into it.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

require(root() . '/lib/JawnOS/Manager/Part32.pm');

sub calc {
	my ($f) = @_;
	my ($formula, $evaluation, $uom, $format) = Manager::formula_calculator($f);
	return $evaluation;
}

is(calc('2 + 2 * 3'), 8, 'ordinary arithmetic still evaluates');
is(calc('10 % 4'), 2, 'modulo evaluates');
is(calc('(2 + 3) * 2'), 10, 'parentheses evaluate');

for my $f ( '1; print 1', '1;`id`', '1;$0', '1;system("id")', '1 @ARGV', '1 { 2 }' ) {
	my $ev = calc($f);
	ok(!defined $ev || $ev eq '', "formula '$f' is refused") or diag('got: ' . (defined $ev ? $ev : 'undef'));
}
is(calc('x' x 501), undef, 'an overlong formula is refused');

done_testing();
