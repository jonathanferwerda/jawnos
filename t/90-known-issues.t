use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# Known defects, pinned as TODO tests so the suite stays green but a fix shows up
# as a passing (unexpectedly succeeding) TODO and a regression does not vanish.
#
# time_abbrev_translator (subroutines.pl:687) reads a unit from the whole string
# only when the string is exactly a unit name with the digits and separators
# stripped ("day", "hour"). A leading space left by "2 days", or a unit written
# into the same token ("2days"), misses that test, so the unit falls back to the
# token's last letter (2days -> seconds) or to minutes (2 days -> minutes). The
# interval reader (interval_parse) already handles these spellings correctly;
# this is the other door.
TODO: {
	local $TODO = 'time_abbrev_translator loses a unit written with a space or joined (subroutines.pl:687)';

	my $from = ts(2024, 1, 1);
	is(&subs::time_abbrev_translator('2 days', $from), 172800000, '"2 days" is two days');
	is(&subs::time_abbrev_translator('2days',  $from), 172800000, '"2days" is two days');
	is(&subs::time_abbrev_translator('1 hour 30 minutes', $from), 5400000,
		'"1 hour 30 minutes" is ninety minutes');
}

done_testing();
