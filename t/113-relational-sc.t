# tests-for: lib/JawnOS/Domain/Name.pm scripts/relational_sc_clean.pl
# covers:    the relational membership arrays are sets. A uuid appears once, an
#            app never names itself, and (when the caller has the house view) a
#            uuid that no longer resolves to an app is dropped. The pos hook
#            writes through the same rule, so a stale list cannot grow again.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

subs::preload('sc_list_clean');

is_deeply(
	[ @{ &subs::sc_list_clean([ 'a', 'a', 'b', 'a' ], undef, undef) } ],
	[ 'a', 'b' ],
	'a repeated uuid is kept once, in first-appearance order',
);

is_deeply(
	[ @{ &subs::sc_list_clean([ 'a', 'self', 'b' ], 'self', undef) } ],
	[ 'a', 'b' ],
	'an app never names itself',
);

is_deeply(
	[ @{ &subs::sc_list_clean([ 'a', 'all', '', undef, 'b' ], undef, undef) } ],
	[ 'a', 'b' ],
	'the all marker, empty strings and undef are not members',
);

is_deeply(
	[ @{ &subs::sc_list_clean([ 'a', 'stale', 'b' ], undef, { a => 1, b => 1 }) } ],
	[ 'a', 'b' ],
	'a uuid that names no app is dropped when the house view is supplied',
);

is_deeply(
	[ @{ &subs::sc_list_clean([ 'a', 'not_seen_here' ], undef, undef) } ],
	[ 'a', 'not_seen_here' ],
	'without the house view an unseen uuid is kept (a peer may have it)',
);

is_deeply(
	[ @{ &subs::sc_list_clean('not an array', undef, undef) } ],
	[],
	'a value that is not an array reads as no members',
);

is_deeply(
	[ @{ &subs::sc_list_clean([ 'b', 'a', 'b', 'a' ], undef, undef) } ],
	[ 'b', 'a' ],
	'cleaning is order-stable',
);

# The root cause: the pos hook used to push the app's uuid into every member's
# list with no duplicate guard. It must go through sc_list_clean now.
my $source = read_file("$FindBin::Bin/../lib/JawnOS/Domain/Name.pm");
like($source, qr/sc_list_clean/, 'the pos hook cleans a membership list before writing it');
unlike($source, qr/push\s+\@\{\$ntsc\},\s*\$old_settings->\{'uuid'\}/, 'the unguarded push is gone');

done_testing();
