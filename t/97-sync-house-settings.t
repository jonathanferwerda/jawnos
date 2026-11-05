# tests-for: lib/JawnOS/Domain/Backup.pm
#
# A house-wide settings row (`device = 'all'`) must be able to start a sync even
# when its app is otherwise protected/local. The 06:00 QA nightly choice is one:
# a phone saves where the night runs, and the table must hear it before 06:00,
# not whenever some unrelated appointment happens to pull a snapshot.
#
# The durable digest is the trigger, and the band map reads the same WHERE, so a
# row that moves the digest is also the row the next pull can localise. Both
# halves are pinned here against a throwaway database.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file);
use DBI;

# The protected list lives in perl/gb/01_state_and_defaults.pl, which needs the
# whole app to load. Read just the list so this standalone test sees the same
# app exclusion the manager does (cards among them).
my $gb_source = read_file("$FindBin::Bin/../perl/gb/01_state_and_defaults.pl");
my (undef, $protected_list) = $gb_source =~ /our \@protected = qw(.)([^\n]*?)\1/;
{
	no warnings 'once';
	@gb::protected = split ' ', ($protected_list // '');
}

require JawnOS::Domain::Backup;

my $where = subs::durable_settings_where();
like($where, qr/device = 'all'/, 'the durable WHERE admits house-wide rows');
like($where, qr/app not in/, 'the per-device app exclusion is still there');
like($where, qr/app = 'cards' and setting in \('mode','variant'\)/,
	'the cards mode/variant rows are triggers on a protected app');

my $dir = tempdir(CLEANUP => 1);
my $db  = "$dir/jawnos.db";
my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '',
	{ RaiseError => 1, PrintError => 0 });
$dbh->do('create table settings (app text, setting text, device text, value text, server_time text)');

my @rows = (
	# the house rows that must count
	[ '__president', 'qa_nightly_device', 'all',   'abc', '1000' ],
	[ 'home',        'budget',            'all',   '1',   '1000' ],
	[ 'me',          'warranty',          'all',   '1',   '1000' ],
	[ 'misc',        'language',          'all',   'en',  '1000' ],
	# a per-device copy of the same choice is not house data
	[ '__president', 'qa_nightly_device', 'phone', 'abc', '1000' ],
	[ '__president', 'open_tabs',         'phone', 'x',   '1000' ],
	# named local churn stays out even when it claims to be house-wide
	[ '__president', 'remote_backup_lock', 'all',  'x',   '1000' ],
	[ '__president', 'open_tabs',          'all',  'x',   '1000' ],
	# the cards choices that are allowed to sync, and the app's local state
	[ 'cards',       'mode',               'phone', 'day', '1000' ],
	[ 'cards',       'variant',            'phone', 'solitaire', '1000' ],
	[ 'cards',       'day',                'all',   '[]',  '1000' ],
	[ 'cards',       'errors',             'phone', 'x',   '1000' ],
	[ 'cards',       'solitaire_bank',     'phone', '500', '1000' ],
);
for my $r (@rows) {
	$dbh->do('insert into settings (app, setting, device, value, server_time) values (?,?,?,?,?)', undef, @{$r});
}

sub count_where {
	my ($sql) = @_;
	return $dbh->selectrow_array("select count(*) from settings where $sql");
}
sub digest {
	my ($sql) = @_;
	my $row = $dbh->selectrow_hashref(
		"select count(*) as c, coalesce(sum(cast(server_time as integer)),0) as s,"
		. " coalesce(max(server_time),0) as m from settings where $sql");
	return join ':', map { $row->{$_} } qw(c s m);
}

is(count_where($where), 7, 'the house rows and the allowed cards rows count, the local rows do not');

my $house = 'app = \'__president\' and setting = \'qa_nightly_device\' and device = \'all\'';
my $local = 'app = \'__president\' and setting = \'qa_nightly_device\' and device = \'phone\'';
my $before = digest($where);

$dbh->do("update settings set server_time = '2000' where $house");
my $after = digest($where);
isnt($after, $before, 'changing the house choice moves the sync digest');

$before = digest($where);
$dbh->do("update settings set server_time = '3000' where $local");
is(digest($where), $before, 'a per-device copy alone does not start a pull');

$dbh->do("update settings set server_time = '4000' where app = '__president' and setting = 'remote_backup_lock'");
is(digest($where), $before, 'a named local row stays out of the trigger');

$before = digest($where);
$dbh->do("update settings set server_time = '5000' where app = 'cards' and setting = 'mode'");
isnt(digest($where), $before, 'changing the cards mode starts a pull');

$before = digest($where);
$dbh->do("update settings set server_time = '6000' where app = 'cards' and setting = 'errors'");
is(digest($where), $before, 'cards errors stay out of the trigger');

$before = digest($where);
$dbh->do("update settings set server_time = '7000' where app = 'cards' and setting = 'solitaire_bank'");
is(digest($where), $before, 'the cards bank stays out of the trigger');

$dbh->disconnect;
done_testing();
