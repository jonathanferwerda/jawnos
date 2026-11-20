# tests-for: lib/JawnOS/Domain/Generate.pm lib/JawnOS/Manager/Part17.pm
# covers:    a stopped parent never leaves a running default child on a peer.
#            The stop is pressed on one machine and the model/option child is
#            written on the one that started the app; either row can arrive at a
#            peer first, so the merge reconciles the pair in both orders. A
#            catalogue row deleted in Configure also keeps a durable tombstone,
#            so a stale peer cannot hand the deleted model or option back.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Temp qw(tempfile);
use Mojo::SQLite;

my ($fh, $dbfile) = tempfile('jawnos-default-child-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table appointments (
	app text, uuid text, type text, timestamp text, server_time text,
	source_uuid text, source text, seen text, stop_seen text, stop_timestamp text,
	duration text, model text, options text, ost text, app_uuid text
)');
$db->query('create table model (
	app text, name text, uuid text, server_time text, timestamp text, ost text,
	def text, save_app text, quantity text, unit text
)');
$db->query('create table settings (setting text, value text, timestamp text, '
	. 'id integer primary key autoincrement, app text, server_time text, device text, '
	. 'browser_tab_id text, uuid text, ost text, subsetting text)');
$db->query('create table cache (app text, context text, subcontext text, data text, '
	. 'device text, timestamp text, server_time text, uuid text, ost text)');
$db->query('create table remote_machines (uuid text, signatorial text, deletions text, server_time text, ost text)');
$db->query('create table sync_log (id integer primary key autoincrement, '
	. 'server_time text, signatorial text, tbl text, app text, uuid text, '
	. 'scope text, additional text, ost text)');
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

require JawnOS::Manager::Part17;

my $device = &subs::device_setter();

sub merge_row {
	my ($table, $row) = @_;
	my $served = 0;
	my $next = sub { return $served++ ? undef : $row; };
	my $ctx = {
		configuration      => {},
		misc_settings      => {},
		device             => $device,
		deletions          => [],
		universal_settings => {},
		updateables        => [],
		sync_job           => undef,
		auuid              => 'test-auuid',
		colour             => '#000000',
	};
	return Manager::merge_table_rows($ctx, $table, $next, 1, 1, 1);
}

sub appointment {
	my ($uuid) = @_;
	return $db->query('select * from appointments where uuid = ?', $uuid)->hash;
}

# --- the parent's stop arrives after the child ------------------------------
$db->insert('appointments', {
	app => 'programming', uuid => 'p1', type => 'start', timestamp => '1000',
	server_time => '1000', seen => 'yes',
});
$db->insert('appointments', {
	app => 'vibe_coding', uuid => 'c1', type => 'start', timestamp => '1000',
	server_time => '1200', source_uuid => 'p1', source => 'default', seen => 'yes',
});
merge_row('appointments', {
	app => 'programming', uuid => 'p1', type => 'stop', timestamp => '1000',
	stop_timestamp => '5000', duration => '-4000', stop_seen => 'yes',
	server_time => '5000', seen => 'yes',
});
my $child = appointment('c1');
is($child->{'stop_seen'}, 'yes', 'the stop that arrived second closes the running child');
is($child->{'type'}, 'stop', 'as a stop');
is($child->{'stop_timestamp'}, '5000', 'ending at the parent stop');
is($child->{'duration'}, '-4000', 'over the child\'s own span');

# --- the child arrives after the parent's stop ------------------------------
$db->insert('appointments', {
	app => 'programming', uuid => 'p2', type => 'stop', timestamp => '1000',
	stop_timestamp => '6000', duration => '-5000', stop_seen => 'yes',
	server_time => '6000', seen => 'yes',
});
merge_row('appointments', {
	app => 'vibe_coding', uuid => 'c2', type => 'start', timestamp => '1000',
	server_time => '1300', source_uuid => 'p2', source => 'default', seen => 'yes',
});
my $late = appointment('c2');
is($late->{'stop_seen'}, 'yes', 'a child that arrives after the stop is written closed');
is($late->{'type'}, 'stop', 'as a stop');
is($late->{'stop_timestamp'}, '6000', 'ending at the parent stop');

# --- a child of another kind is not a model/option session ------------------
$db->insert('appointments', {
	app => 'programming', uuid => 'p3', type => 'stop', timestamp => '1000',
	stop_timestamp => '7000', duration => '-6000', stop_seen => 'yes',
	server_time => '7000', seen => 'yes',
});
merge_row('appointments', {
	app => 'store', uuid => 'c3', type => 'purchase', timestamp => '1000',
	server_time => '1400', source_uuid => 'p3', source => 'default', seen => 'yes',
});
my $purchase = appointment('c3');
ok(!defined $purchase->{'stop_seen'} || !length $purchase->{'stop_seen'},
	'a purchase that shares source_uuid is left alone');
is($purchase->{'type'}, 'purchase', 'and keeps its own type');

# --- the close follows a chain of children ----------------------------------
$db->insert('appointments', {
	app => 'programming', uuid => 'p4', type => 'stop', timestamp => '1000',
	stop_timestamp => '8000', duration => '-7000', stop_seen => 'yes',
	server_time => '8000', seen => 'yes',
});
$db->insert('appointments', {
	app => 'vibe_coding', uuid => 'c4', type => 'start', timestamp => '1000',
	server_time => '1500', source_uuid => 'p4', source => 'default', seen => 'yes',
});
$db->insert('appointments', {
	app => 'cocoa', uuid => 'g4', type => 'start', timestamp => '1000',
	server_time => '1600', source_uuid => 'c4', source => 'default', seen => 'yes',
});
merge_row('appointments', {
	app => 'programming', uuid => 'p4', type => 'stop', timestamp => '1000',
	stop_timestamp => '8000', duration => '-7000', stop_seen => 'yes',
	server_time => '8000', seen => 'yes',
});
is(appointment('c4')->{'stop_seen'}, 'yes', 'a child of the stop is closed');
is(appointment('g4')->{'stop_seen'}, 'yes', 'and its own child follows it');

# --- a resume is not undone by the parent's older stop ----------------------
$db->insert('appointments', {
	app => 'programming', uuid => 'p5', type => 'stop', timestamp => '1000',
	stop_timestamp => '9000', duration => '-8000', stop_seen => 'yes',
	server_time => '9000', seen => 'yes',
});
$db->insert('appointments', {
	app => 'vibe_coding', uuid => 'c5', type => 'stop', timestamp => '1000',
	stop_timestamp => '9000', duration => '-8000', stop_seen => 'yes',
	server_time => '9100', seen => 'yes', source_uuid => 'p5', source => 'default',
});
merge_row('appointments', {
	app => 'vibe_coding', uuid => 'c5', type => 'start', timestamp => '1000',
	server_time => '9500', source_uuid => 'p5', source => 'default', seen => 'yes',
	stop_seen => undef, stop_timestamp => undef, duration => undef,
});
my $resumed = appointment('c5');
is($resumed->{'type'}, 'start', 'a child reopened for a resume is left running');
ok(!defined $resumed->{'stop_seen'} || !length $resumed->{'stop_seen'},
	'even though the parent copy here is still the older stop');

# --- a stale stop replay does not close a newer open session ----------------
$db->insert('appointments', {
	app => 'programming', uuid => 'p6', type => 'start', timestamp => '1000',
	server_time => '11000', seen => 'yes',
});
$db->insert('appointments', {
	app => 'vibe_coding', uuid => 'c6', type => 'start', timestamp => '1000',
	server_time => '11000', source_uuid => 'p6', source => 'default', seen => 'yes',
});
merge_row('appointments', {
	app => 'programming', uuid => 'p6', type => 'stop', timestamp => '1000',
	stop_timestamp => '10000', duration => '-9000', stop_seen => 'yes',
	server_time => '10000', seen => 'yes',
});
is(appointment('p6')->{'type'}, 'start', 'an older stop copy does not overwrite the open parent');
ok(!defined appointment('c6')->{'stop_seen'} || !length appointment('c6')->{'stop_seen'},
	'and it does not close the child a resume is running');

# --- a deleted catalogue row is not handed back -----------------------------
$db->insert('sync_log', {
	tbl => 'model', uuid => 'gone', scope => 'single', server_time => '900',
});
merge_row('model', {
	app => 'tea', name => 'camomile', uuid => 'gone', server_time => '1000',
});
is(scalar @{ $db->query('select uuid from model where uuid = ?', 'gone')->hashes }, 0,
	'a stale peer cannot restore a model deleted in Configure');

merge_row('model', {
	app => 'tea', name => 'english_breakfast', uuid => 'kept', server_time => '1000',
});
is(scalar @{ $db->query('select uuid from model where uuid = ?', 'kept')->hashes }, 1,
	'while another catalogue row still merges');

done_testing();
