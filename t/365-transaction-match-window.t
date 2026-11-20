# tests-for: lib/JawnOS/Manager/Part19.pm
# covers:    the already-recorded transaction match is bounded by its 36-hour
#            window, not by whichever twenty rows SQLite scanned first; the
#            amount, the calendar day and the merchant still decide, and a row
#            with no merchant is taken on amount and day alone

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Temp qw(tempfile);
use Mojo::SQLite;
use Time::HiRes qw(time);

# A throwaway SQLite file installed as the holder, so the live database is
# never touched. The match is driven through the real query: a mocked db_query
# cannot show the bind-affinity bug this test exists for.
my ($fh, $dbfile) = tempfile('jawnos-tx-match-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table warehouse (uuid text, kind text, type text, movement text, '
	. 'account text, total real, amount real, timestamp text, vendor text, item text, server_time text)');
my @st = stat($dbfile);
$gb::database_holder = {
	server_time => &subs::rightNow(),
	database    => $dbfile,
	db          => $db,
	dbh         => $db->dbh,
	sql         => $sql,
	pid         => $$,
	dev         => $st[0],
	ino         => $st[1],
};
$subs::say_quiet = 1;

require JawnOS::Manager::Part18;
require JawnOS::Manager::Part19;

my $day   = 24 * 3600 * 1000;
my $now   = int(time * 1000);
my $amount = 45.20;

sub clear_rows { $db->query('delete from warehouse') }
sub add_expense {
	my (%r) = @_;
	$db->query('insert into warehouse (uuid,kind,type,movement,account,total,amount,timestamp,vendor,item,server_time) '
		. 'values (?,?,?,?,?,?,?,?,?,?,?)',
		$r{'uuid'} || ('tx-' . ($r{'timestamp'} || 0) . '-' . ($r{'vendor'} || '') . '-' . rand()),
		'money', 'transaction', 'expense', ($r{'account'} || 'koho'),
		$r{'total'}, $r{'amount'} // $r{'total'}, $r{'timestamp'} . '', ($r{'vendor'} // ''),
		($r{'item'} // ''), $r{'timestamp'} . '');
}
sub recorded {
	my (%payment) = @_;
	return Manager::notification_already_recorded(
		{ timestamp => $now }, \%payment, 'koho');
}

# Twenty older same-amount purchases fill the scan; unless the window bounds the
# SQL, the same-day row inserted last is the twenty-first and never seen.
clear_rows();
add_expense(account => 'koho', total => -$amount, timestamp => $now - 10 * $day - $_, vendor => "oldshop $_")
	for 1 .. 25;
add_expense(account => 'koho', total => -$amount, timestamp => $now, vendor => 'coffee');
is(recorded(amount => $amount, merchant => 'coffee'), 1,
	'a same-day purchase is found even behind twenty older same-amount rows');

clear_rows();
add_expense(account => 'koho', total => -$amount, timestamp => $now, vendor => 'coffee');
is(recorded(amount => $amount, merchant => 'coffee'), 1,
	'a same-day purchase at the same merchant is the recorded one');

clear_rows();
add_expense(account => 'koho', total => -$amount, timestamp => $now, vendor => 'coffee');
is(recorded(amount => $amount + 10, merchant => 'coffee'), 0,
	'a different amount is not the recorded purchase');

clear_rows();
add_expense(account => 'koho', total => -$amount, timestamp => $now, vendor => 'other_shop');
is(recorded(amount => $amount, merchant => 'coffee'), 0,
	'a different merchant is not the recorded purchase');

clear_rows();
add_expense(account => 'koho', total => -$amount, timestamp => $now - 10 * $day, vendor => 'coffee');
is(recorded(amount => $amount, merchant => 'coffee'), 0,
	'a matching purchase on another day is not today');

clear_rows();
add_expense(account => 'koho', total => -$amount, timestamp => $now, vendor => '');
is(recorded(amount => $amount, merchant => 'coffee'), 1,
	'a same-day row that names no merchant is taken on amount and day');

clear_rows();
add_expense(account => 'libro_chequing', total => -$amount, timestamp => $now, vendor => 'coffee');
is(recorded(amount => $amount, merchant => 'coffee'), 0,
	'another account is not this payment');

done_testing();
