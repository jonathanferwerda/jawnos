# tests-for: lib/JawnOS/Domain/Notify.pm lib/JawnOS/Domain/Name.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Manager/Part17.pm lib/JawnOS/Manager/Part32.pm t/162-settings-key-doubling.t
# covers:    a deleted settings key is tombstoned by (app, setting, subsetting,
#            device), an older peer row cannot bring it back on the next merge,
#            a deliberate re-add at a newer server_time still lands, a legacy
#            uuid/table deletion record is untouched, and the record survives
#            the JSON shapes the sync rail carries.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Temp qw(tempfile);
use Mojo::SQLite;
use Mojo::JSON qw(decode_json encode_json);

# The deletion record and the merge decision are driven on a throwaway SQLite
# file installed as the holder, so the live database is never touched.

my ($fh, $dbfile) = tempfile('jawnos-settings-deletions-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table settings (setting text, value text, timestamp text, '
	. 'id integer primary key autoincrement, app text, server_time text, device text, '
	. 'browser_tab_id text, uuid text, ost text, subsetting text)');
$db->query('create table cache (app text, context text, subcontext text, data text, '
	. 'device text, timestamp text, server_time text, uuid text, ost text)');
$db->query('create table remote_machines (uuid text, signatorial text, deletions text, server_time text, ost text)');
$db->query('create table sync_log (id integer primary key autoincrement, '
	. 'server_time text, signatorial text, tbl text, app text, uuid text, '
	. 'scope text, additional text, ost text)');
$db->query('create table notes (uuid text, app text, text text, timestamp text, '
	. 'server_time text, ost text)');
$db->query('create table appointments (uuid text, app text, timestamp text, '
	. 'server_time text, ost text)');
$db->query('create table continent (uuid text, app text, timestamp text, '
	. 'server_time text, ost text)');
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
$subs::sync_table_cache = undef;

# A fixed identity keeps the tombstone rows deterministic.
local *subs::signatorial_designer = sub { 'test-signatorial' };

# The two Manager parts define package Manager subs directly; requiring the
# files is enough (Manager.pm itself wants a live Mojolicious app).
require JawnOS::Manager::Part17;
require JawnOS::Manager::Part32;

my $device = &subs::device_setter();

# One peer table's row, driven through the same merge the sync uses.
sub merge_settings_row {
	my ($row, $deletions) = @_;
	my $served = 0;
	my $next = sub { return $served++ ? undef : $row; };
	my $ctx = {
		configuration      => {},
		misc_settings      => {},
		device             => $device,
		deletions          => $deletions || [],
		universal_settings => {},
		updateables        => [],
		sync_job           => undef,
		auuid              => 'test-auuid',
		colour             => '#000000',
	};
	return Manager::merge_table_rows($ctx, 'settings', $next, 1, 1, 1);
}

sub setting_rows {
	my ($app, $setting) = @_;
	return &subs::db_query(
		'select * from settings where app = ? and setting = ?', $app, $setting
	)->hashes || [];
}

# ---------------------------------------------------------------- the helpers
ok(&subs::provides('settings_deletion_key'), 'the key helper is on the domain map');
ok(&subs::provides('settings_deletion_time'), 'the time helper is on the domain map');
ok(&subs::provides('settings_deletion_index'), 'the index helper is on the domain map');
ok(&subs::provides('settings_deletion_blocks'), 'the decision helper is on the domain map');

# A byte-string key (what a pre-unicode peer hands over) names the same row as
# the character string the settings write gate stored.
my $name = "i\x{2019}m_confident";
my $bytes = $name;
utf8::encode($bytes);
my $key_chars = &subs::settings_deletion_key({ app => $name, setting => 'theme', device => $device });
my $key_bytes = &subs::settings_deletion_key({ app => $bytes, setting => 'theme', device => $device });
is($key_bytes, $key_chars, 'a byte-string key and a character key describe one row');
is(&subs::settings_deletion_key({ app => $name, setting => 'theme', subsetting => undef, device => $device }),
	&subs::settings_deletion_key({ app => $name, setting => 'theme', subsetting => '', device => $device }),
	'NULL and empty subsetting are the same key');

# A legacy uuid/table record is not a settings key, so it keeps the uuid path.
is(&subs::settings_deletion_key({ table => 'appointments', uuid => 'a1' }), undef,
	'an appointments uuid/table record is not a settings key');
is(&subs::settings_deletion_key({ table => 'settings', uuid => 's1' }), undef,
	'a settings record with no key names no row');

my $tomb = {
	table => 'settings', app => 'helpmath', setting => 'theme', device => $device,
	server_time => '1500',
};
is(&subs::settings_deletion_blocks(
	{ app => 'helpmath', setting => 'theme', device => $device, server_time => '1400' }, [$tomb]),
	1, 'an older row is held back');
is(&subs::settings_deletion_blocks(
	{ app => 'helpmath', setting => 'theme', device => $device, server_time => '1500' }, [$tomb]),
	1, 'a row stamped at the deletion moment is held back too');
is(&subs::settings_deletion_blocks(
	{ app => 'helpmath', setting => 'theme', device => $device, server_time => '1501' }, [$tomb]),
	0, 'a newer row is a re-add and is not held back');
is(&subs::settings_deletion_blocks(
	{ app => 'helpmath', setting => 'colour', device => $device, server_time => '1400' }, [$tomb]),
	0, 'another setting is unaffected');
is(&subs::settings_deletion_blocks(
	{ app => 'helpmath', setting => 'theme', device => 'mobile', server_time => '1400' }, [$tomb]),
	0, 'another device is unaffected');
is(&subs::settings_deletion_blocks(
	{ app => 'helpmath', setting => 'theme', device => $device, server_time => '1400' },
	[{ table => 'appointments', uuid => 'a1' }]),
	0, 'a legacy uuid/table record does not hold a settings row back');

# A merge builds the index once; the decision must be the same as the list path.
my $index = &subs::settings_deletion_index([$tomb]);
is(&subs::settings_deletion_blocks(
	{ app => 'helpmath', setting => 'theme', device => $device, server_time => '1400' }, $index),
	1, 'the prebuilt index holds an older row back');
is(&subs::settings_deletion_blocks(
	{ app => 'helpmath', setting => 'theme', device => $device, server_time => '1501' }, $index),
	0, 'and lets a newer row through');

# ---------------------------------------------------- the record on the wire
# One peer row exists so deletion_registration has a queue to append to.
$db->query('insert into remote_machines (uuid, signatorial, deletions) values (?,?,?)',
	'rm1', 'peer-1', '[]');

&subs::setting_setter({ app => 'solo', setting => 'theme', value => 'dark',
	device => $device, server_time => '1000', sync => 1 });
is(scalar @{ setting_rows('solo', 'theme') }, 1, 'the setting exists before the delete');

&subs::setting_deleter({ app => 'solo', setting => 'theme', device => $device, server_time => '1500' });
is(scalar @{ setting_rows('solo', 'theme') }, 0, 'the delete removes the row');

my $durable = &subs::db_query("select * from sync_log where tbl = 'settings'")->hashes;
is(scalar @{$durable}, 1, 'the delete wrote one durable tombstone');
my $durable_extra = decode_json($durable->[0]->{'additional'});
is($durable_extra->{'setting'}, 'theme', 'the durable tombstone carries the setting name');
is($durable_extra->{'device'}, $device, 'and the device');
is($durable_extra->{'server_time'} + 0, 1500, 'and the moment of the delete');

my $queued = decode_json(&subs::db_query(
	"select deletions from remote_machines where uuid = 'rm1'")->hash->{'deletions'});
my ($queued_record) = grep { ($_->{'table'} || '') eq 'settings' } @{$queued};
ok($queued_record, 'the short-lived deletion list names the settings delete');
is($queued_record->{'setting'}, 'theme', 'with the setting at the top level');
is($queued_record->{'device'}, $device, 'with the device at the top level');
is($queued_record->{'server_time'} + 0, 1500, 'with the moment of the delete');

# The short-lived list is a plain JSON array; a peer re-encodes and decodes it.
my $wire = decode_json(encode_json($queued));
is(&subs::settings_deletion_key($wire->[0]), &subs::settings_deletion_key($queued_record),
	'the key round-trips through the queued JSON');
is(&subs::settings_deletion_time($wire->[0]), 1500, 'and so does the moment');

# The durable log rides as {tbl, app, additional, server_time} (apply_peer_tombstones
# mapping), so the key and the delete moment must survive that shape too.
my $sync_shape = decode_json(encode_json({ tombstones => [ {
	tbl => $durable->[0]->{'tbl'}, app => $durable->[0]->{'app'},
	additional => $durable->[0]->{'additional'},
	server_time => $durable->[0]->{'server_time'},
} ] }));
is(&subs::settings_deletion_key($sync_shape->{'tombstones'}->[0]),
	&subs::settings_deletion_key($queued_record),
	'the durable tombstone names the same key after a round trip');
is(&subs::settings_deletion_time($sync_shape->{'tombstones'}->[0]), 1500,
	'the durable shape keeps the delete moment, not the log write time');

# ---------------------------------------- an older peer row cannot come back
my $older = {
	app => 'solo', setting => 'theme', value => 'stale', device => $device,
	server_time => '1000', timestamp => '1000', uuid => 'peer-old',
};
&merge_settings_row($older, []);
is(scalar @{ setting_rows('solo', 'theme') }, 0,
	'a peer row older than the tombstone does not return');

# A deliberately re-added row is newer than the delete and must land.
my $newer = {
	app => 'solo', setting => 'theme', value => 'light', device => $device,
	server_time => '2000', timestamp => '2000', uuid => 'peer-new',
};
&merge_settings_row($newer, []);
my $readded = setting_rows('solo', 'theme');
is(scalar @{$readded}, 1, 'a deliberate re-add lands');
is($readded->[0]->{'value'}, 'light', 'with its own value');
is($readded->[0]->{'server_time'} + 0, 2000, 'and its newer stamp');

# An unrelated key is untouched by that tombstone.
my $other = {
	app => 'solo', setting => 'accent', value => 'blue', device => $device,
	server_time => '1000', timestamp => '1000', uuid => 'peer-accent',
};
&merge_settings_row($other, []);
is(scalar @{ setting_rows('solo', 'accent') }, 1, 'an unrelated setting still lands');

my $other_subsetting = {
	app => 'solo', setting => 'theme', subsetting => 'second', value => 'grey',
	device => $device, server_time => '1000', timestamp => '1000', uuid => 'peer-sub',
};
&merge_settings_row($other_subsetting, []);
is(scalar @{ setting_rows('solo', 'theme') }, 2, 'a different subsetting is a different key');

# ------------------------------------------- the deletions list applies too
# A peer's queued record (the shape merge_database collects) blocks the same
# stale row even when this machine's own sync_log has been pruned.
&subs::db_query("delete from sync_log where tbl = 'settings'");
$db->query('delete from settings where app = ? and setting = ?', 'queued', 'theme');
my $queued_for_other = { %{$queued_record}, app => 'queued' };
&merge_settings_row({
	app => 'queued', setting => 'theme', value => 'from-peer', device => $device,
	server_time => '1000', timestamp => '1000', uuid => 'queued-new',
}, [ $queued_for_other ]);
is(scalar @{ setting_rows('queued', 'theme') }, 0, 'a peer queued deletion still blocks the row');

# ------------------------------------- applying a peer tombstone after the merge
# deletion_performer is the path apply_peer_tombstones uses for the durable log.
my $peer_tombstone = {
	table => 'settings', app => 'applied', setting => 'theme', device => $device,
	server_time => '9999999999999',
	additional => encode_json({ setting => 'theme', device => $device, server_time => 2000 }),
};
&subs::setting_setter({ app => 'applied', setting => 'theme', value => 'old',
	device => $device, server_time => '1000', sync => 1 });
my $applied = Manager::deletion_performer(encode_json([ $peer_tombstone ]));
is(scalar @{$applied}, 1, 'the peer tombstone is applied');
is(scalar @{ setting_rows('applied', 'theme') }, 0, 'a row at or before the tombstone is removed');

&subs::setting_setter({ app => 'applied', setting => 'theme', value => 'fresh',
	device => $device, server_time => '3000', sync => 1 });
Manager::deletion_performer(encode_json([ $peer_tombstone ]));
my $survivor = setting_rows('applied', 'theme');
is(scalar @{$survivor}, 1, 'a newer re-add survives a stale peer tombstone');
is($survivor->[0]->{'value'}, 'fresh', 'with its value intact');

# ---------------------------------------- the legacy uuid/table path is intact
# A record that names only a uuid and a table still drops that row before the
# insert: the new settings key never captures it.
my $served = 0;
my $next = sub {
	return $served++ ? undef : {
		uuid => 'note-1', app => 'notes', text => 'peer copy',
		timestamp => '200', server_time => '200', ost => '200',
	};
};
Manager::merge_table_rows({
	configuration => {}, misc_settings => {}, device => $device,
	deletions => [ { table => 'notes', uuid => 'note-1', scope => 'single', server_time => '100' } ],
	universal_settings => {}, updateables => [], sync_job => undef,
	auuid => 'test-auuid', colour => '#000000',
}, 'notes', $next, 1, 1, 1);
is(scalar @{ &subs::db_query("select * from notes where uuid = 'note-1'")->hashes }, 0,
	'a legacy uuid/table record still blocks the peer row');

# And deletion_performer still takes the generic uuid route for a non-settings table.
$db->query('insert into notes (uuid, app, text, timestamp, server_time, ost) '
	. 'values (?,?,?,?,?,?)', 'note-2', 'notes', 'delete me', '100', '100', '100');
Manager::deletion_performer(encode_json([ { table => 'notes', uuid => 'note-2' } ]));
is(scalar @{ &subs::db_query("select * from notes where uuid = 'note-2'")->hashes }, 0,
	'a legacy uuid/table deletion still removes the row');

# ---------------------------------------- a readings-only app retirement
# The old web Weather and the new Weather UI share an app key, so retiring the
# old readings must not take the app's settings with them.
$db->query('insert into appointments (uuid, app, timestamp, server_time) '
	. 'values (?,?,?,?)', 'weather-old-1', 'weather', '100', '100');
$db->query('insert into continent (uuid, app, timestamp, server_time) '
	. 'values (?,?,?,?)', 'weather-old-1', 'weather', '100', '100');
$db->query('insert into settings (app, setting, value, server_time, device) '
	. 'values (?,?,?,?,?)', 'weather', 'locations', '[]', '300', $device);
Manager::deletion_performer(encode_json([
	{ table => 'appointments', app => 'weather', scope => 'appointments' },
]));
is(scalar @{ &subs::db_query("select * from appointments where app = 'weather'")->hashes }, 0,
	'the old readings leave the app');
is(scalar @{ &subs::db_query("select * from continent where app = 'weather'")->hashes }, 0,
	'and their place rows');
is(scalar @{ setting_rows('weather', 'locations') }, 1,
	'while the app settings the new UI uses stay');

done_testing();
