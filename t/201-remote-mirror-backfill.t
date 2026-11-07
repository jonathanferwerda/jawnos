# tests-for: lib/JawnOS/Domain/Warehouse.pm lib/JawnOS/Domain/Accounting.pm
# covers:    the one-time backfill that rewrites old remote_machines data and
#           mirrors blobs through the same views the live write paths use

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Temp qw(tempfile);
use Mojo::SQLite;
use Mojo::JSON qw(encode_json decode_json);

# Rows written by older builds still carry the full login body in `data` and
# each peer's whole row in `mirrors`. The backfill is the at-rest half of the
# pruning; it must rewrite those blobs, leave server_time alone, and be safe to
# run again. The database tests use only a throwaway SQLite file.

my ($fh, $dbfile) = tempfile('jawnos-remote-backfill-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table remote_machines (uuid text, signatorial text, data text, mirrors text, server_time text)');
$db->query('create table backfills (name text, server_time text)');

my $server_time = '1600000000000';
my $old_data = encode_json({
	database => '/house.db', device => 'mobile', ssh_port => 8022,
	manager_colour => '#123456', manager_file => 'face.html',
	debriefer => 'x' x 5000, browser_tab_id => 'tab', pwd => '/home/peer',
});
my $old_mirrors = encode_json([
	{
		uuid => 'm1', signatorial => 's1', hostname => 'Phone', pubkey => 'pk',
		manager => 'https://phone:45545', ip => '192.168.1.9',
		network => '{"lan":{"ip":"192.168.1.9"}}',
		data => '{"debriefer":"big"}', cookie => '[{"name":"president"}]',
		deletions => '[]', mirrors => '[{"uuid":"nested"}]', log => 'noise',
	},
	{ uuid => 'm2', signatorial => 's2', hostname => 'Laptop', manager => 'https://laptop:45545' },
	'not-a-hash',
]);
$db->query('insert into remote_machines (uuid, signatorial, data, mirrors, server_time) values (?,?,?,?,?)',
	'row1', 'sig1', $old_data, $old_mirrors, $server_time);
$db->query('insert into remote_machines (uuid, signatorial, data, mirrors, server_time) values (?,?,?,?,?)',
	'row2', 'sig2', '{"database":"house.db"}', '[]', $server_time);
$db->query('insert into remote_machines (uuid, signatorial, data, mirrors, server_time) values (?,?,?,?,?)',
	'row3', 'sig3', 'not-json', 'null', $server_time);

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

my $backfill = &subs::backfills()->{'remote_machine_payload_prune_v1'};
ok($backfill, 'the remote payload backfill is registered');
ok($backfill->(), 'the first pass records success');

my $row1 = $db->query('select data, mirrors, server_time from remote_machines where uuid = ?', 'row1')->hashes->[0];
my $data = decode_json($row1->{'data'});
is_deeply([ sort keys %{$data} ],
	[ sort qw(database device ssh_port manager_colour manager_file) ],
	'the login body keeps only the fields a peer row reads');
is($row1->{'server_time'}, $server_time, 'the backfill does not refresh server_time');

my $mirrors = decode_json($row1->{'mirrors'});
is(scalar @{$mirrors}, 2, 'both valid mirror entries survive and the junk one is dropped');
for my $dropped (qw(data cookie deletions mirrors log)) {
	ok(!exists $mirrors->[0]->{$dropped}, "a mirror entry drops $dropped");
}
is($mirrors->[0]->{'manager'}, 'https://phone:45545', 'a mirror entry keeps the route');
is($mirrors->[0]->{'pubkey'}, 'pk', 'a mirror entry keeps the roster proof');
is($mirrors->[0]->{'network'}, '{"lan":{"ip":"192.168.1.9"}}', 'a mirror entry keeps the LAN map');

my $row2 = $db->query('select data, mirrors from remote_machines where uuid = ?', 'row2')->hashes->[0];
is($row2->{'data'}, '{"database":"house.db"}', 'an already-pruned body is left byte for byte');
is($row2->{'mirrors'}, '[]', 'an already-pruned mirror list is left byte for byte');

my $row3 = $db->query('select data, mirrors from remote_machines where uuid = ?', 'row3')->hashes->[0];
is($row3->{'data'}, 'not-json', 'a malformed body is left for the next handshake, not destroyed');
is($row3->{'mirrors'}, 'null', 'a non-array mirror value is left alone too');

my $first_data = $row1->{'data'};
my $first_mirrors = $row1->{'mirrors'};
ok($backfill->(), 'a second pass succeeds');
my $again = $db->query('select data, mirrors from remote_machines where uuid = ?', 'row1')->hashes->[0];
is($again->{'data'}, $first_data, 'a second pass does not rewrite data');
is($again->{'mirrors'}, $first_mirrors, 'a second pass does not rewrite mirrors');

done_testing();
