# tests-for: lib/JawnOS/Domain/Key.pm lib/JawnOS/Manager/Part14.pm lib/JawnOS/Domain/Generate.pm lib/JawnOS/Domain/Warehouse.pm lib/JawnOS/Manager/Part13.pm lib/JawnOS/Controller/manager_misc4.pm perl/hooks.pl perl/subroutines.pl
# covers:    Every appointment says what started it - a press on the rail, an NFC
#            tag, a task's checkbox, a default option, a schedule's repeat - so the
#            clothesline learns only the steps the person took themselves. A press
#            stamps press, an explicit origin wins over it, a row written outside a
#            press carries none, and a stop or cancel never erases the origin the
#            row was written with.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use Mojo::SQLite;
use JawnOSTest;
use RepoSource;

my $root = repo_root();

my ($fh, $dbfile) = tempfile('jawnos-source-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table appointments (app text, uuid text, type text, timestamp text,
	server_time text, ost text, source text, source_uuid text, app_uuid text, stop_timestamp text)');
$db->query('create table settings (setting text, value text, timestamp text, id integer primary key autoincrement, '
	. 'app text, server_time text, device text, browser_tab_id text, uuid text, ost text, subsetting text)');
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

sub source_of {
	my ($uuid) = @_;
	my $row = $db->query('select source from appointments where uuid = ?', $uuid)->hash;
	return $row ? $row->{'source'} : undef;
}

# --- the insert stamps the request's origin --------------------------------
$subs::appointment_source = 'press';
&subs::db_insert('appointments', { app => 'banana', type => 'stop', timestamp => '1000', uuid => 'u-press' });
is(source_of('u-press'), 'press', 'a press stamps every row it writes');

&subs::db_insert('appointments', { app => 'milk', type => 'stop', timestamp => '1000', uuid => 'u-default', source => 'default' });
is(source_of('u-default'), 'default', 'a default option keeps its own origin inside the same press');

&subs::db_insert('appointments', { app => 'tagged', type => 'stop', timestamp => '1000', uuid => 'u-nfc', source => 'nfc' });
is(source_of('u-nfc'), 'nfc', 'a tag says so');

$subs::appointment_source = '';
&subs::db_insert('appointments', { app => 'weather', type => 'stop', timestamp => '1000', uuid => 'u-auto' });
ok(!defined source_of('u-auto') || !length source_of('u-auto'),
	'a row written outside a request of the person carries no origin');

# --- an update never erases the origin -------------------------------------
&subs::db_update('appointments', { type => 'usual', source => undef, uuid => 'u-press' }, { uuid => 'u-press' });
is(source_of('u-press'), 'press', 'a stop passes no origin, and the row keeps the one it was written with');

&subs::db_update('appointments', { type => 'start', source => 'nfc', uuid => 'u-default' }, { uuid => 'u-default' });
is(source_of('u-default'), 'nfc', 'but an origin the client does send is taken');

# --- each producer names its own -------------------------------------------
my %wiring = (
	'lib/JawnOS/Manager/Part14.pm'               => qr/\$subs::appointment_source = .*'press'/,
	'lib/JawnOS/Domain/Generate.pm'              => qr/source => 'default'/,
	'lib/JawnOS/Domain/Warehouse.pm'             => qr/source => 'task'/,
	'lib/JawnOS/Manager/Part13.pm'               => qr/source => 'schedule'/,
	'lib/JawnOS/Controller/manager_misc4.pm'     => qr/source => 'nfc'/,
	'perl/hooks.pl'                              => qr/\$subs::appointment_source = ''/,
);
foreach my $file ( sort keys %wiring ) {
	like(read_file($root . '/' . $file), $wiring{$file}, "$file names its origin");
}

done_testing();
