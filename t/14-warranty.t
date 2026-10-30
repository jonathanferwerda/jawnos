use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Temp qw(tempfile);
use Mojo::SQLite;

# A warranty is one value for the house, not one per device, and a renewal
# re-anchors every record to the warranty the person chose - not to whatever the
# stored setting happened to say. These are the pure pieces the settings and the
# renew action share.
#
# The database tests write only to a throwaway SQLite file this test creates and
# installs as the holder, so they never touch the live database.

# ---------------------------------------------------------------- pure helpers
is(&subs::warranty_device(), 'all', 'a warranty lives on the house row');

my $anchor   = ts(2026, 1, 1, 12, 0, 0);
my $warranty = ts(2036, 1, 1, 12, 0, 0);   # ten years ahead of the anchor
my $offset   = $warranty - $anchor;

is(&subs::warranty_renewed($warranty, $anchor, ts(2025, 7, 4)),
   ts(2035, 7, 4), 'a renewal lands the same offset on an older record');
# the offset is a fixed span, so a record whose own ten years contain a
# different number of leap days lands within a day of the calendar date
my $newer = &subs::warranty_renewed($warranty, $anchor, ts(2026, 10, 30));
ok(abs($newer - ts(2036, 10, 30)) <= 86400000,
	'a renewal stays within a day of the calendar span on a newer record');

foreach my $row ( ts(2024, 1, 1), ts(2024, 2, 29), ts(2025, 7, 4), ts(2026, 10, 30) ) {
	is(&subs::warranty_renewed($warranty, $anchor, $row) - $row, $offset,
		'every record keeps the same offset');
}

ok(&subs::warranty_renewal_ok($warranty, $anchor), 'a warranty ahead of now may renew');
ok(!&subs::warranty_renewal_ok($anchor - 1000, $anchor), 'a warranty already past may not renew');
ok(!&subs::warranty_renewal_ok(undef, $anchor), 'a missing warranty may not renew');
ok(!&subs::warranty_renewal_ok('', $anchor), 'a blank warranty may not renew');

# ------------------------------------------------------------- a house setting
my ($fh, $dbfile) = tempfile('jawnos-warranty-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table settings (setting text, value text, timestamp text, '
	. 'id integer primary key autoincrement, app text, server_time text, device text, '
	. 'browser_tab_id text, uuid text, ost text, subsetting text)');
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

my $now = &subs::rightNow();
&subs::setting_setter({
	app => 'driving', setting => 'warranty', value => '-10y', timestamp => $now,
});

my $rows = $db->query("select device, value from settings where app = 'driving' and setting = 'warranty'")->hashes;
is(scalar @{$rows}, 1, 'a warranty write makes exactly one row');
is($rows->[0]->{'device'}, 'all', 'and that row is the house row');
is($rows->[0]->{'value'}, '-10y', 'carrying the chosen value');
is(&subs::setting_grabber({ app => 'driving', setting => 'warranty' }), '-10y',
	'the house value is read back');
is(&subs::settings_grabber({ app => 'driving' })->{'warranty'}, '-10y',
	'the settings hash the panels read carries the house value');

# an older build's per-device row still answers when no house row exists yet
&subs::db_insert('settings', {
	app => 'legacy', setting => 'warranty', value => '-7y', device => 'computer',
	timestamp => $now, server_time => $now, uuid => 'legacy-row',
});
is(&subs::setting_grabber({ app => 'legacy', setting => 'warranty' }), '-7y',
	'a legacy per-device row is still read until the house row exists');

# and once both exist, the house row is the one that wins
&subs::db_insert('settings', {
	app => 'both', setting => 'warranty', value => '-7y', device => 'computer',
	timestamp => $now, server_time => $now, uuid => 'both-device',
});
&subs::db_insert('settings', {
	app => 'both', setting => 'warranty', value => '-20y', device => 'all',
	timestamp => $now, server_time => $now, uuid => 'both-house',
});
is(&subs::setting_grabber({ app => 'both', setting => 'warranty' }), '-20y',
	'the house row wins over a per-device row');

# ------------------------------------------------------------- the backfill
&subs::db_insert('settings', {
	app => 'old', setting => 'warranty', value => '-2y', device => 'mobile',
	timestamp => $now - 2000, server_time => $now - 2000, uuid => 'old-mobile',
});
&subs::db_insert('settings', {
	app => 'old', setting => 'warranty', value => '-1y', device => 'computer',
	timestamp => $now - 1000, server_time => $now - 1000, uuid => 'old-computer',
});

my $backfill = &subs::backfills()->{'warranty_house_wide'};
ok($backfill, 'the warranty backfill is registered');
$backfill->();
is(&subs::setting_grabber({ app => 'old', setting => 'warranty' }), '-1y',
	'the backfill collapses an app to its most recently written value');

$backfill->();
my $n = $db->query("select count(*) as n from settings where app = 'old' and setting = 'warranty' and device = 'all'")->hashes->[0]->{'n'};
is($n + 0, 1, 'running the backfill again does not make a second house row');

# it does not overwrite a house row that is already there
&subs::db_insert('settings', {
	app => 'old', setting => 'warranty', value => '-3y', device => 'computer',
	timestamp => $now + 1000, server_time => $now + 1000, uuid => 'old-later',
});
$backfill->();
is(&subs::setting_grabber({ app => 'old', setting => 'warranty' }), '-1y',
	'a later per-device row cannot take over the house value');

done_testing();
