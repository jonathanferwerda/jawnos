# tests-for: lib/JawnOS/Domain/Sync.pm
# covers:    a whole-table row read resumes from the last merged batch after a
#            restart instead of walking the table from row one again.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JawnOSTest;

subs::preload('sync_resume_get');
subs::preload('sync_resume_put');
subs::preload('sync_resume_clear');

my $peer  = 'e9ce731a06afcab8f8b4b502637a717d';
my $other = 'de3f1c63ba2b3cfe3910ad2742c5a556';

ok(!defined subs::sync_resume_get($peer, 'appointments', 0), 'no marker before a read');

ok(!subs::sync_resume_put($peer, 'appointments', { cut => 0, after => '', total => 10, watermark => 1 }),
	'an empty cursor is not a resume point');
ok(!subs::sync_resume_put($peer, 'appointments', { cut => 0, after => '9', total => 0, watermark => 1 }),
	'a marker with no count is not stored');

ok(subs::sync_resume_put($peer, 'appointments', { cut => 0, after => '12000', total => 122000, watermark => 999 }),
	'a merged batch is remembered');

my $slot = subs::sync_resume_get($peer, 'appointments', 0);
is(ref $slot, 'HASH', 'the marker reads back');
is($slot->{'after'}, '12000', 'it names the last merged rowid');
is($slot->{'total'}, 122000, 'it keeps the count a resumed read cannot re-derive');
is($slot->{'watermark'}, 999, 'and the high-water server_time already merged');

ok(!defined subs::sync_resume_get($peer, 'appointments', 5),
	'a different cut is a different read and starts fresh');
ok(!defined subs::sync_resume_get($other, 'appointments', 0),
	'another peer does not inherit the cursor');
ok(!defined subs::sync_resume_get($peer, 'settings', 0),
	'another table does not inherit the cursor');

subs::sync_resume_clear($peer, 'appointments');
ok(!defined subs::sync_resume_get($peer, 'appointments', 0), 'a finished table clears its marker');

# A marker older than the window is not trusted: the peer may have been
# restored or rebuilt under it.
subs::sync_resume_put($peer, 'appointments', { cut => 0, after => '7', total => 10, watermark => 1 });
{
	my $now = subs::rightNow();
	local *subs::rightNow = sub { $now + 7 * 60 * 60 * 1000 };
	ok(!defined subs::sync_resume_get($peer, 'appointments', 0),
		'a marker older than six hours is ignored');
}
ok(defined subs::sync_resume_get($peer, 'appointments', 0), 'and a fresh one is still honoured');

done_testing();
