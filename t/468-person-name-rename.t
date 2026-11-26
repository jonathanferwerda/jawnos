# tests-for: lib/JawnOS/Domain/Name.pm lib/JawnOS/Domain/Embedded2.pm
# covers:    a person's own name is the app their records are filed under, so
#            saving a new spelling into me/my_name renames that app instead of
#            starting a second one. The pedometer's steps, the weight and every
#            other row follow; a target that already held a few rows from the
#            earlier spelling merges its established settings and its contacts;
#            a built-in name, a sync replay and a change that keeps the same app
#            key move nothing.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use Mojo::SQLite;
use Mojo::JSON qw(encode_json decode_json);
use JawnOSTest;

my $root = root();
my $dir  = tempdir(CLEANUP => 1);

my $schema = do {
	open(my $in, '<', "$root/database/schema.sql") or die $!;
	local $/;
	my $text = <$in>;
	close $in;
	$text;
};

my $path = "$dir/rename.db";
my $pipe = open(my $fh, '|-', 'sqlite3', $path) or die "sqlite3: $!";
print {$fh} $schema;
close $fh;
die "no database at $path" unless -e $path && -s $path > 5000;

my $sql = Mojo::SQLite->new('sqlite:' . $path, sqlite_use_immediate_transaction => 0);
$sql->options({ AutoCommit => 1 });
my $db = $sql->db;
my @st = stat($path);
$gb::database_holder = {
	server_time => &subs::rightNow(),
	database    => $path,
	db          => $db,
	dbh         => $db->dbh,
	sql         => $sql,
	pid         => $$,
	dev         => $st[0],
	ino         => $st[1],
};
$subs::say_quiet = 1;
$subs::sync_table_cache = undef;

{
	no warnings 'redefine';
	*Websocket::send = sub { return 1 };
	*Websocket::console_command = sub { return '' };
}

my $now = &subs::rightNow();
my $setting = sub {
	my ($app, $name, $value, $device) = @_;
	$db->query('insert into settings (app, setting, value, device, server_time) values (?,?,?,?,?)',
		$app, $name, $value, ($device || 'computer'), $now);
};
my $appointment = sub {
	my ($uuid, $app, $type) = @_;
	$db->query('insert into appointments (uuid, app, type, timestamp, server_time) values (?,?,?,?,?)',
		$uuid, $app, $type, $now, $now);
};

# The person before the name changed: the established app with history.
$setting->('me', 'my_name', 'Jonathan Ferwerda');
$setting->('jonathan_ferwerda', 'uuid', 'OLD-APP-UUID');
$setting->('jonathan_ferwerda', 'pos', 'person');
$setting->('jonathan_ferwerda', 'notification_text', 'Jonathan Ferwerda');
$setting->('jonathan_ferwerda', 'phones', encode_json([ { uuid => 'p1', value => '+15550001' } ]));
$appointment->('old-1', 'jonathan_ferwerda', 'measure');
$appointment->('old-2', 'jonathan_ferwerda', 'note');

# The fork the short spelling started: a couple of rows already under the new key.
$setting->('jon_ferwerda', 'uuid', 'NEW-APP-UUID');
$setting->('jon_ferwerda', 'pos', 'idea');
$setting->('jon_ferwerda', 'notification_text', 'Jon Ferwerda');
$setting->('jon_ferwerda', 'phones', encode_json([ { uuid => 'p2', value => '+15550002' } ]));
$appointment->('new-1', 'jon_ferwerda', 'measure');

# An unrelated app that must not move.
$appointment->('other-1', 'breakfast', 'measure');

my $count = sub {
	my ($table, $where, @args) = @_;
	return $db->query("select count(*) from $table where $where", @args)->arrays->[0][0];
};
my $value = sub {
	my ($app, $name) = @_;
	my $row = $db->query('select value from settings where app = ? and setting = ?', $app, $name)->hash;
	return $row ? $row->{'value'} : undef;
};

# --- a new spelling renames the person's app and carries the history over ----
&subs::setting_setter({ app => 'me', setting => 'my_name', value => 'Jon Ferwerda',
	device => 'computer', timestamp => $now, source => 'panel' });

is($value->('me', 'my_name'), 'Jon Ferwerda', 'the name is saved');
is($count->('appointments', 'app = ?', 'jonathan_ferwerda'), 0, 'no history is left under the old spelling');
is($count->('appointments', 'app = ?', 'jon_ferwerda'), 3, 'every row now lives under the new spelling');
is($count->('appointments', 'app = ?', 'breakfast'), 1, 'an unrelated app is untouched');
is($value->('jon_ferwerda', 'uuid'), 'OLD-APP-UUID', 'the established app identity survives the merge');
is($value->('jon_ferwerda', 'pos'), 'person', 'the established part of speech survives, not the born default');
is($count->('settings', "app = 'jon_ferwerda' and setting = 'uuid'"), 1, 'only one identity row is left');
my $phones = decode_json($value->('jon_ferwerda', 'phones') || '[]');
is(scalar @{$phones}, 2, 'the contacts either spelling held are kept');
my $marker = $db->query("select app, value from settings where setting = 'name_change'")->hashes;
is(scalar @{$marker}, 1, 'one name_change marker records the rename for a peer');
is($marker->[0]->{'app'}, 'jon_ferwerda', 'the marker names the app it landed on');

# --- a spelling that gives the same app key moves nothing --------------------
&subs::setting_setter({ app => 'me', setting => 'my_name', value => 'Jon  Ferwerda',
	device => 'computer', timestamp => $now + 1, source => 'panel' });
is($count->('appointments', 'app = ?', 'jon_ferwerda'), 3, 'an equivalent spelling keeps the same app');
is($count->('settings', "setting = 'name_change'"), 1, 'and writes no second rename');

# --- a peer replay is written, but does not rename here ----------------------
&subs::setting_setter({ app => 'me', setting => 'my_name', value => 'Someone Else',
	device => 'computer', timestamp => $now + 2, source => 'panel', sync => 1 });
is($value->('me', 'my_name'), 'Someone Else', 'the replayed name is written');
is($count->('appointments', 'app = ?', 'jon_ferwerda'), 3, 'the replay moves no history');

# --- a built-in app is never a rename target --------------------------------
&subs::setting_setter({ app => 'me', setting => 'my_name', value => 'Me',
	device => 'computer', timestamp => $now + 3, source => 'panel' });
is($count->('appointments', 'app = ?', 'jon_ferwerda'), 3, 'a protected name moves no history');
is($value->('me', 'my_name'), 'Me', 'the name itself is still saved');

done_testing();
