# tests-for: lib/JawnOS/Domain/Render.pm perl/President.pl
# covers:    the utility pass cap never resolves to undef/0; the optional value of 2

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

my $root = root();
require "$root/lib/JawnOS/Domain/Render.pm";

# The cap is assigned in the parent after the utility child is forked, so the
# child sees undef. `$started >= undef` is true, which skipped every due job.
is(&subs::utility_pass_cap_value(undef), 2, 'an undefined cap falls back to two');
is(&subs::utility_pass_cap_value(0), 2, 'a zero cap falls back to two');
is(&subs::utility_pass_cap_value(''), 2, 'an empty cap falls back to two');
is(&subs::utility_pass_cap_value('nope'), 2, 'a non-numeric cap falls back to two');
is(&subs::utility_pass_cap_value(-3), 2, 'a negative cap falls back to two');
is(&subs::utility_pass_cap_value(3), 3, 'a real cap is kept');
is(&subs::utility_pass_cap_value('4'), 4, 'a numeric string is kept (blobs store strings)');

done_testing();
