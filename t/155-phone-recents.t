# tests-for: lib/JawnOS/Controller/manager_phone.pm lib/JawnOS/Manager/Part12.pm templates/apps/phone.html.ep perl/help/topics_web.pl
# covers:    Recent showed a blocked number's cancelled call - the house's record of the refusal, not a call to read.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use RepoSource;
use JawnOSTest;

# The pane's filter is a Manager helper (Part12); the app loads the part lazily,
# so a test loads it directly, the way t/15 loads Part30.
require(root() . '/lib/JawnOS/Manager/Part12.pm');

my $blocked = '5199188319';

my @calls = (
	{ app => 'Someone Known', account => $blocked,              uuid => 'blocked-plain' },
	{ app => 'Unknown',       account => '555 0100',            uuid => 'stranger' },
	{ app => 'Someone Known', account => "+1 ($blocked)",       uuid => 'blocked-formatted' },
	{ app => 'phone',         account => '',                    uuid => 'no-account' },
	{ app => 'phone',                                           uuid => 'no-key' },
	{ app => 'phone',         account => undef,                 uuid => 'undef-account' },
);

my $kept = Manager::phone_recent_unblocked(\@calls, [ $blocked ]);
is scalar @{$kept}, 4, 'both copies of the blocked caller are dropped from Recent';
is_deeply [ map { $_->{'uuid'} } @{$kept} ],
	[ qw(stranger no-account no-key undef-account) ],
	'every other call stays, in order';

# The blacklist stores what the desk typed; the call's account may be stored the
# same way or with a country code, dashes and spaces. Both sides are reduced to
# the house's digits before they meet.
my $formatted = Manager::phone_recent_unblocked(
	[ { account => $blocked, uuid => 'plain' } ],
	[ "+1 ($blocked)" ],
);
is scalar @{$formatted}, 0, 'a formatted blacklist entry still matches a plain account';

my $plain = Manager::phone_recent_unblocked(
	[ { account => "+1 ($blocked)", uuid => 'formatted' } ],
	[ $blocked ],
);
is scalar @{$plain}, 0, 'a formatted account still matches a plain blacklist entry';

# Nothing blocked, nothing to hide - and no input at all is not a crash.
is scalar @{ Manager::phone_recent_unblocked(\@calls, []) }, 6, 'an empty blacklist keeps every call';
is scalar @{ Manager::phone_recent_unblocked(undef, undef) }, 0, 'no calls is an empty list';
is scalar @{ Manager::phone_recent_unblocked(\@calls, undef) }, 6, 'no blacklist keeps every call';

# The route has to use it: a helper nobody calls would pass the tests above.
my $manager = manager_source();
like($manager, qr/my \$calls = &phone_recent_unblocked\(/,
	'the Phone route filters Recent through the blacklist helper');

# The help topic promises the new behaviour, not the old one.
my $help = help_source();
like($help, qr/Recent leaves it out/, 'the help topic says a blocked call is left out of Recent');
unlike($help, qr/so it still shows in Recent/, 'the old promise that it still shows is gone');

done_testing();
