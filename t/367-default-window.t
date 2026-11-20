# tests-for: lib/JawnOS/Domain/Generate.pm
# covers:    a default model/option window is read on the house clock, not the
#            box's UTC, and when more than one model carries the default flag the
#            press picks one deterministically (a matching window, then the
#            oldest configured row) instead of whatever order the database
#            happens to return.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Temp qw(tempfile);
use Mojo::SQLite;
use POSIX ();
use Time::Local qw(timegm);

require JawnOS::Domain::Generate;

my ($fh, $dbfile) = tempfile('jawnos-default-window-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table model (
	app text, name text, uuid text, quantity text, unit text,
	delay_start text, delay_stop text, def text, save_app text,
	def_month text, def_day text, def_hour text, def_wday text,
	timestamp text, server_time text, characteristics text, manufacturer text
)');
$db->query('create table option (
	app text, name text, uuid text, quantity text, unit text,
	delay_start text, delay_stop text, def text, save_app text,
	def_month text, def_day text, def_hour text, def_wday text,
	timestamp text, server_time text, characteristics text
)');
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

# The box keeps UTC; the house reads Eastern. 2026-01-15 12:00 UTC is 07:00 in
# New York, so a window that names 7am only matches if the house clock is used.
my $had = exists $ENV{'TZ'};
my $old = $ENV{'TZ'};
$ENV{'TZ'} = 'UTC';
POSIX::tzset();
my $noon_utc = timegm(0, 0, 12, 15, 0, 2026) * 1000;

{
	no warnings 'redefine';
	local *subs::clock_zone_house = sub { return 'America/New_York' };

	is(&subs::default_attribute_time_checker({ def_hour => '["7am"]' }, $noon_utc), 'yes',
		'a default that names the house hour matches while the box reads UTC');
	is(&subs::default_attribute_time_checker({ def_hour => '["12pm"]' }, $noon_utc), 'no',
		'a default that names the box hour does not');
	is(&subs::default_attribute_time_checker({}, $noon_utc), 'yes',
		'an empty window means every hour');

	# Two models are flagged default (a size and a drink, or a twin a migration
	# left behind). The oldest configured one is the app's default, on every
	# machine, whatever order the rows were merged in.
	$db->insert('model', {
		app => 'tea-test', name => 'second', uuid => 'm2', def => 'on', save_app => '',
		server_time => '200', timestamp => '200',
	});
	$db->insert('model', {
		app => 'tea-test', name => 'first', uuid => 'm1', def => 'on', save_app => '',
		server_time => '100', timestamp => '100',
	});
	my ($model) = &subs::usual_appointment_maker({ app => 'tea-test', type => 'start', timestamp => $noon_utc }, {});
	ok($model && $model->{'uuid'}, 'a default model is chosen');
	is($model->{'name'}, 'first', 'and it is the oldest matching default, not the first row the database returns');

	# A window that does not contain the house hour is skipped.
	$db->query('delete from model');
	$db->insert('model', {
		app => 'tea-test', name => 'morning', uuid => 'm3', def => 'on', save_app => '',
		server_time => '100', timestamp => '100', def_hour => '["7am"]',
	});
	($model) = &subs::usual_appointment_maker({ app => 'tea-test', type => 'start', timestamp => $noon_utc }, {});
	ok($model && $model->{'uuid'}, 'the matching window is used');
	is($model->{'name'}, 'morning', 'and names that default');

	$db->query('update model set def_hour = ? where uuid = ?', '["12pm"]', 'm3');
	($model) = &subs::usual_appointment_maker({ app => 'tea-test', type => 'start', timestamp => $noon_utc }, {});
	ok(!defined $model, 'and a default outside its window starts nothing');
}

if ($had) { $ENV{'TZ'} = $old } else { delete $ENV{'TZ'} }
POSIX::tzset();

done_testing();
