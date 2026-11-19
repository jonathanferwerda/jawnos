# tests-for: lib/JawnOS/Domain/Misc.pm lib/JawnOS/Domain/Migrations.pm
# covers:    A closed websocket is kept for a month instead of deleted. The row
#            already spans connect to last beat (`connected` to `server_time`),
#            so the clothesline - and any app that reads the house's liveness
#            later - has "this device was up". The warranty is bounded (a month,
#            never the app/me warranty that is years out), a second retire does
#            not move the close time, and the cull deletes the expired row by
#            uuid so a live sibling on the same tab survives.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest ();

my $now = JawnOSTest::ts(2026, 11, 18, 12, 0);
my $tab  = 'ws-session-test-tab-' . $$;
my $live = 'ws-session-test-live-' . $$;
my $old  = 'ws-session-test-old-' . $$;

my $add = sub {
	my ($uuid, %over) = @_;
	&subs::db_insert('websockets', {
		uuid => $uuid,
		app => 'tab',
		browser_tab_id => $tab,
		type => 'stayingAlive',
		connected => $now - 3600000,
		timestamp => $now,
		server_time => $now,
		warranty => &subs::ago_calc('-10y', $now),
		%over,
	});
};
$add->($live);
$add->($old, type => 'closed', warranty => $now - 1, server_time => $now - 86400000);

is(&subs::websocket_retire({ uuid => $live }, now => $now), 1,
	'a live session is retired, not deleted');
my $closed = &subs::db_query('select * from websockets where uuid = ?', $live)->hash;
is($closed->{'type'}, 'closed', 'the row says it is closed');
is(0 + $closed->{'server_time'}, $now, 'the close time is the last beat');
is(0 + $closed->{'warranty'}, 0 + &subs::ago_calc('-30d', $now),
	'and the warranty is one month, not the app warranty');
is(0 + $closed->{'connected'}, $now - 3600000,
	'while the connect time is kept, so the session still has a span');

is(&subs::websocket_retire({ uuid => $live }, now => $now + 1000), 0,
	'a closed row is not retired twice');
my $again = &subs::db_query('select * from websockets where uuid = ?', $live)->hash;
is(0 + $again->{'warranty'}, 0 + $closed->{'warranty'},
	'so a second pass does not extend it');

cmp_ok(&subs::websocket_sessions_cull($now), '>=', 1,
	'the cull removes the expired session');
ok(!defined(&subs::db_query('select * from websockets where uuid = ?', $old)->hash),
	'the expired row is gone');
ok(defined(&subs::db_query('select * from websockets where uuid = ?', $live)->hash),
	'and the row retired just now is not expired yet');

# The indexes the read side depends on: an app's sessions over time, any
# session over time, and the warranty cull.
&subs::update_database({});
my @indexes = map { $_->{'name'} } @{ &subs::db_query('select name from pragma_index_list(?)', 'websockets')->hashes };
is_deeply([ grep { /^idx[456]_ws$/ } sort @indexes ], [qw(idx4_ws idx5_ws idx6_ws)],
	'the session indexes are built');

&subs::db_query('delete from websockets where browser_tab_id = ?', $tab);

done_testing();
