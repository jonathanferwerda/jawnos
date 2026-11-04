# tests-for: lib/JawnOS/Domain/Name.pm
# covers:    a settings write decodes a byte-string app name once, so a
#            non-ASCII key survives byte-for-byte and does not double per save

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Temp qw(tempfile);
use Mojo::SQLite;

# A name with a typographic apostrophe is the shape that corrupted the house:
# three UTF-8 bytes (E2 80 99) that become six when a byte string is handed to
# SQLite as characters, and double again on every later save. This drives the
# settings layer, where every settings write meets, on a throwaway database.
#
# The database tests write only to a SQLite file this test creates and installs
# as the holder, so they never touch the live database.

my ($fh, $dbfile) = tempfile('jawnos-key-doubling-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table settings (setting text, value text, timestamp text, '
	. 'id integer primary key autoincrement, app text, server_time text, device text, '
	. 'browser_tab_id text, uuid text, ost text, subsetting text)');
$db->query('create table cache (app text, context text, subcontext text, data text, '
	. 'device text, timestamp text, server_time text, uuid text, ost text)');
# setting_deleter now records a durable tombstone, so the fixture carries the two
# tables that path writes: the short-lived deletions list and the sync log.
$db->query('create table remote_machines (uuid text, signatorial text, deletions text)');
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

sub app_bytes {
	my ($chars) = @_;
	my $bytes = $chars;
	utf8::encode($bytes);
	return $bytes;
}

my $name = "i\x{2019}m_confident";
my $bytes = app_bytes($name);
ok(!utf8::is_utf8($bytes), 'the request-side name is a byte string');

# A byte string is what a caller on the far side of a form, a legacy worker or a
# pre-unicode SQLite handle hands this layer. The gate must decode it once, not
# store its UTF-8 bytes as Latin-1 characters.
&subs::setting_setter({
	app => $bytes, setting => 'toggle', value => 'on', source => 'test', sync => 1,
});

my $rows = $db->query("select app, value from settings where setting = 'toggle'")->hashes;
is(scalar @{$rows}, 1, 'one write makes one toggle row');
is($rows->[0]->{'app'}, $name, 'the stored key is the name itself');
my $stored = $rows->[0]->{'app'};
utf8::encode($stored) if utf8::is_utf8($stored);
is(unpack('H*', $stored), '69e280996d5f636f6e666964656e74',
	'the stored bytes are one UTF-8 encoding, not mojibake');

# The cascade: a write that reads a byte string back and writes it again used to
# add a layer each time (15 -> 18 -> 24 -> ... bytes) until the key was unusable.
for my $pass (1 .. 4) {
	&subs::setting_setter({
		app => $bytes, setting => 'toggle', value => ($pass % 2 ? 'off' : 'on'),
		source => 'test', sync => 1,
	});
	my $after = $db->query("select app from settings where setting = 'toggle'")->hashes;
	is(scalar @{$after}, 1, "pass $pass still leaves exactly one toggle row");
	is($after->[0]->{'app'}, $name, "pass $pass keeps the key byte-for-byte");
}

# A read with the same byte string must find that row, or a caller's save looks
# like a new app and the grabber writes a second uuid.
is(&subs::setting_grabber({ app => $bytes, setting => 'toggle', benign => 1 }), 'on',
	'a byte-string read finds the stored setting');
my $settings = &subs::settings_grabber({ app => $bytes, benign => 1 });
is($settings->{'app'}, $name, 'the settings map reports the name, not its bytes');
is(scalar @{ $db->query("select uuid from settings where setting = 'uuid'")->hashes }, 0,
	'a read does not invent a second uuid row for the byte string');

# Deleting with the byte string must remove the row the character string named.
&subs::setting_deleter({ app => $bytes, setting => 'toggle', device => &subs::device_setter() });
is(scalar @{ $db->query("select app from settings where setting = 'toggle'")->hashes }, 0,
	'a byte-string delete removes the character-string row');

# A character string (the sync and JSON paths) is still written untouched.
&subs::setting_setter({ app => $name, setting => 'toggle', value => 'on', source => 'test', sync => 1 });
my $synced = $db->query("select app from settings where setting = 'toggle'")->hashes->[0]->{'app'};
is($synced, $name, 'a character-string write round-trips unchanged');

done_testing();
