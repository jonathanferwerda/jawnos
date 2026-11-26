# tests-for: lib/JawnOS/Domain/Edt.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Manager/Part17.pm perl/help/topics_functions.pl
# covers:    one gateway is one row. Two machines that discover the same router
#            give it different uuids, and a renamed NIC spells it again; the
#            merge matches the router by its MAC (or its address when the MAC is
#            unknown) instead of inserting a second card. Duplicates already in
#            the table and the settings rows a damaged database salvaged into it
#            are removed with single tombstones, so a peer cannot hand them
#            back. The smallest uuid survives, so every machine agrees.

use strict;
use warnings;
no warnings 'once';
no warnings 'redefine';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Temp qw(tempfile);
use Mojo::SQLite;

my ($fh, $dbfile) = tempfile('jawnos-router-identity-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table routers (uuid varchar(255) unique, ip varchar(64), mac varchar(64), '
	. 'nic varchar(64), name varchar(255), model varchar(255), manager varchar(255), '
	. 'last_seen varchar(25), timestamp varchar(25), server_time varchar(25), ost varchar(25))');
$db->query('create table sync_log (id integer primary key autoincrement, server_time text, '
	. 'signatorial text, tbl text, app text, uuid text, scope text, additional text, ost text)');
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

# The sandbox has no house identity; a fixed signatorial keeps the tombstone log
# readable without the designer's warning.
local *subs::signatorial_designer = sub { 'test-signatorial' };

# ---- identity --------------------------------------------------------------
ok( subs::router_same_gateway(
	{ ip => '192.168.1.1', mac => 'D8:EC:5E:02:87:40' },
	{ ip => '10.0.0.5',    mac => 'd8-ec-5e-02-87-40' }),
	'the same MAC at a new address is the same gateway' );
ok( !subs::router_same_gateway(
	{ ip => '192.168.1.1', mac => 'aa:aa:aa:aa:aa:aa' },
	{ ip => '192.168.1.1', mac => 'bb:bb:bb:bb:bb:bb' }),
	'two MACs on one address stay two gateways' );
ok( subs::router_same_gateway(
	{ ip => '192.168.1.1', mac => '' },
	{ ip => '192.168.1.1', mac => 'aa:aa:aa:aa:aa:aa' }),
	'a missing MAC falls back to the address' );
ok( !subs::router_same_gateway(
	{ ip => '192.168.1.1', mac => '' },
	{ ip => '192.168.2.1', mac => '' }),
	'different addresses with no MAC are different gateways' );
ok( subs::router_row_valid({ ip => '192.168.1.1' }), 'a real address is a gateway row' );
ok( !subs::router_row_valid({ ip => '1795657226175', mac => '__president' }),
	'a salvaged settings row is not a gateway' );
ok( !subs::router_row_valid({ ip => '999.1.1.1' }), 'an octet over 255 is not a gateway' );

# ---- dedupe existing rows --------------------------------------------------
sub add_router {
	my ($row) = @_;
	$row->{'timestamp'} //= $row->{'server_time'};
	$row->{'ost'} //= $row->{'server_time'};
	&subs::db_insert('routers', $row);
}

add_router({ uuid => 'a-small',  ip => '192.168.1.1', mac => 'd8:ec:5e:02:87:40',
	nic => 'wlo1',   name => 'Linksys Smart Wi-Fi', last_seen => 100, server_time => 100 });
add_router({ uuid => 'b-dup',    ip => '192.168.1.1', mac => 'd8:ec:5e:02:87:40',
	nic => 'wlp1s0', name => 'Linksys Smart Wi-Fi', last_seen => 200, server_time => 200 });
add_router({ uuid => 'c-iponly', ip => '192.168.1.1', mac => '',
	nic => 'wlan0',  name => 'Linksys Smart Wi-Fi', last_seen => 150, server_time => 150 });
add_router({ uuid => 'd-garbage', ip => '1795657226175', mac => '__president',
	nic => 'ai_alert', name => '1795830026175', model => 'state', manager => 'computer',
	last_seen => 'Mohi0lhN8HVjLmbCHiWFLozNB', timestamp => '1793653600003',
	server_time => '1795657528559', ost => '1795657528559' });
add_router({ uuid => 'e-other',  ip => '10.0.0.1', mac => 'aa:aa:aa:aa:aa:aa',
	nic => 'eth0', name => 'Router', last_seen => 120, server_time => 120 });

is( subs::router_dedupe(), 3, 'two duplicates and the foreign row were removed' );
my $rows = &subs::db_select('routers')->hashes;
is( scalar @{$rows}, 2, 'one row per gateway survives' );
my ($kept) = grep { $_->{'uuid'} eq 'a-small' } @{$rows};
ok( $kept, 'the smallest uuid is the survivor' );
is( $kept->{'last_seen'}, 200, 'and it took the newest sighting' );
is( $kept->{'nic'}, 'wlp1s0', 'with that sighting NIC' );
is( $kept->{'ip'}, '192.168.1.1', 'and its address' );
my @tombs = map { $_->{'uuid'} } @{ &subs::db_query(
	"select uuid from sync_log where tbl = 'routers' and scope = 'single' order by uuid")->hashes };
is_deeply( \@tombs, [ 'b-dup', 'c-iponly', 'd-garbage' ],
	'the duplicates and the foreign row are tombstoned' );
ok( !(grep { $_ eq 'a-small' } @tombs), 'the survivor is not tombstoned' );
is( subs::router_dedupe(), 0, 'a second pass removes nothing' );
is( scalar @{ &subs::db_query("select uuid from sync_log where tbl = 'routers'")->hashes }, 3,
	'and writes no more tombstones' );

# ---- merge matches the gateway, not the uuid -------------------------------
require JawnOS::Manager::Part17;

&subs::db_query('delete from routers');
&subs::db_query('delete from sync_log');
add_router({ uuid => 'a-small', ip => '192.168.1.1', mac => 'd8:ec:5e:02:87:40',
	nic => 'wlo1', name => 'Linksys Smart Wi-Fi', last_seen => 100, server_time => 100 });

my $ctx = {
	configuration      => {},
	misc_settings      => {},
	device             => &subs::device_setter(),
	deletions          => [],
	universal_settings => {},
	updateables        => [],
	sync_job           => undef,
	sync_trace         => 'T',
	auuid              => 'test-auuid',
	colour             => '#000000',
};

sub merge_router_row {
	my ($row) = @_;
	my $served = 0;
	my $next = sub { return $served++ ? undef : $row; };
	return Manager::merge_table_rows($ctx, 'routers', $next, 0, 1, 1, 1);
}

my ($short, $errors) = merge_router_row({
	uuid => 'peer-row', ip => '10.0.0.5', mac => 'd8:ec:5e:02:87:40', nic => 'wlo1',
	name => 'Linksys Smart Wi-Fi', last_seen => 300, timestamp => 300, server_time => 300, ost => 300,
});
is( $short, 0, 'the peer spelling merged without a short table' );
is( $errors, 0, 'and without a refused row' );
$rows = &subs::db_select('routers')->hashes;
is( scalar @{$rows}, 1, 'the same gateway is still one row' );
is( $rows->[0]->{'uuid'}, 'a-small', 'the survivor keeps its uuid' );
is( $rows->[0]->{'ip'}, '10.0.0.5', 'and takes the newest address' );
is( $rows->[0]->{'server_time'}, 300, 'and the newest sighting time' );
is( scalar @{ &subs::db_query("select uuid from sync_log where tbl = 'routers'")->hashes }, 0,
	'the peer row is not tombstoned just for having another uuid' );

merge_router_row({
	uuid => 'junk-row', ip => '1795657226175', mac => '__president', nic => 'ai_alert',
	name => '1795830026175', last_seen => 'Mohi0lhN8HVjLmbCHiWFLozNB',
	timestamp => '1793653600003', server_time => '1795657528559', ost => '1795657528559',
});
is( scalar @{ &subs::db_select('routers')->hashes }, 1,
	'a salvaged settings row arriving from a peer is not written as a router' );

# ---- discovery updates the survivor ---------------------------------------
&subs::db_query('delete from routers');
&subs::db_query('delete from sync_log');
add_router({ uuid => 'a-small', ip => '192.168.1.1', mac => 'd8:ec:5e:02:87:40',
	nic => 'wlo1', name => 'Old name', last_seen => 100, server_time => 100 });
add_router({ uuid => 'b-dup', ip => '192.168.1.1', mac => 'd8:ec:5e:02:87:40',
	nic => 'wlp1s0', name => 'Old name', last_seen => 150, server_time => 150 });

local *subs::cache_get = sub { undef };
local *subs::cache_set = sub { };
local *subs::rightNow = sub { 500 };
local *subs::network_interface_reporter = sub {
	return { wlo1 => { gw => '192.168.1.1', gw_mac => 'd8:ec:5e:02:87:40' } };
};
local *subs::router_probe = sub {
	return { name => 'Linksys Smart Wi-Fi', firmware => 'OpenWrt', manager => 'http://192.168.1.1/' };
};
local *subs::random_string_creator = sub { 'new-row' };

ok( subs::router_discover(), 'discovery runs' );
$rows = &subs::db_select('routers')->hashes;
is( scalar @{$rows}, 1, 'discovery leaves one row for the gateway' );
is( $rows->[0]->{'uuid'}, 'a-small', 'on the survivor' );
is( $rows->[0]->{'last_seen'}, 500, 'with the new sighting' );
is( $rows->[0]->{'name'}, 'Linksys Smart Wi-Fi', 'and the probed name' );
is( scalar @{ &subs::db_query("select uuid from sync_log where tbl = 'routers' and uuid = 'b-dup'")->hashes }, 1,
	'and the duplicate it found is tombstoned' );

done_testing();
