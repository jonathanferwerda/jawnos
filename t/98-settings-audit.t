# tests-for: scripts/settings_audit.pl
# covers:    the settings audit CLI - the diff it reports and the two refusals
#           that stand between a bulk restore and the live table

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use DBI;
use JSON::PP ();
use File::Temp qw(tempdir);
use File::Slurp qw(write_file);
use Test::More;

# settings_audit compares the live settings table with a sealed snapshot and, with
# --apply, writes the snapshot's values back. It is a sync-corruption repair tool,
# so the two refusals matter more than the report: no fresh snapshot, and no bulk
# restore without a filter. Stubbed domain subs, no database.

package FakeDB;
sub new   { my ($class, $rows) = @_; return bless { rows => $rows }, $class }
sub hashes { return $_[0]->{'rows'} }
package main;

my $root = "$FindBin::Bin/..";
require "$root/scripts/settings_audit.pl";

my ($SETTER, @SETTER_CALLS, %STUB);
$SETTER = 0;

{
	no warnings 'redefine';
	*subs::backups_dir = sub { return $STUB{'backups'} };
	*subs::records_backup_decrypt = sub { return $STUB{'old_db'} };
	*subs::db_query = sub { return FakeDB->new($STUB{'live'} || []) };
	*subs::durable_settings_where = sub { return '1 = 1' };
	*subs::iso_local = sub { return '2026-11-02 12:00:00' };
	*subs::rightNow = sub { return '9999' };
	*subs::records_backup_ensure_fresh = sub { return $STUB{'fresh'} || { 'fresh' => 1, 'made' => 1, 'path' => '/tmp/snap.enc' } };
	*subs::setting_setter = sub {
		my ($arg) = @_;
		push @SETTER_CALLS, $arg;
		return 1;
	};
}

# A snapshot database with a settings table, the way the sealed backup unpacks.
sub old_db {
	my (@rows) = @_;
	my $dir = tempdir(CLEANUP => 1);
	my $file = "$dir/old.db";
	my $dbh = DBI->connect("dbi:SQLite:dbname=$file", '', '', { RaiseError => 1 });
	$dbh->do('CREATE TABLE settings (app TEXT, setting TEXT, subsetting TEXT, device TEXT, value TEXT, server_time TEXT, uuid TEXT)');
	$dbh->do('INSERT INTO settings (app, setting, subsetting, device, value, server_time, uuid) VALUES (?,?,?,?,?,?,?)',
		undef, @{$_}{qw(app setting subsetting device value server_time uuid)}) for @rows;
	$dbh->disconnect;
	return $file;
}

sub row {
	my (%a) = @_;
	return {
		'app' => $a{'app'} // 'store', 'setting' => $a{'setting'} // 'pos',
		'subsetting' => $a{'subsetting'} // '', 'device' => $a{'device'} // 'this',
		'value' => $a{'value'} // '', 'server_time' => $a{'server_time'} // '100',
		'uuid' => $a{'uuid'} // ('u' . ($a{'setting'} // 'pos')),
	};
}

sub fixture {
	my (%a) = @_;
	my $backups = tempdir(CLEANUP => 1);
	write_file("$backups/jawnos_1700000000000.enc", "sealed\n");
	$STUB{'backups'} = $backups;
	$STUB{'old_db'}  = old_db(@{ $a{'old'} });
	$STUB{'live'}    = $a{'live'};
	$STUB{'fresh'}   = $a{'fresh'};
	@SETTER_CALLS = ();
	return $backups;
}

sub run_cli {
	my @args = @_;
	my $buf = '';
	open my $fh, '>', \$buf or die "capture: $!";
	my $rc;
	{
		local *STDOUT = $fh;
		$rc = main(@args);
	}
	close $fh;
	return ($rc, $buf);
}

# --- --list ------------------------------------------------------------------
{
	fixture(old => [], live => []);
	my ($rc, $out) = run_cli('--list');
	is($rc, 0, '--list exits 0');
	like($out, qr/jawnos_1700000000000\.enc/, 'and names the snapshot it found');
}

# --- no snapshot is a refusal ------------------------------------------------
{
	my $empty = tempdir(CLEANUP => 1);
	$STUB{'backups'} = $empty;
	my ($rc, $out) = run_cli();
	is($rc, 1, 'no snapshot exits 1');
	like($out, qr/there is no snapshot to compare against \(run --list\)/, 'and says what to do');
}

# --- the report --------------------------------------------------------------
{
	fixture(
		old  => [ row(value => 'old', setting => 'pos'), row(value => 'same', setting => 'mab'), row(value => 'gone', setting => 'dropme') ],
		live => [ row(value => 'new', setting => 'pos', server_time => '200'), row(value => 'same', setting => 'mab') ],
	);
	my ($rc, $out) = run_cli('--json');
	is($rc, 0, '--json exits 0');
	my $data = eval { JSON::PP::decode_json($out) };
	is(ref $data, 'HASH', 'the report is JSON');
	my %by_status = map { $_->{'status'} => $_ } @{ $data->{'changes'} || [] };
	ok($by_status{'changed'}, 'a row whose value moved is "changed"');
	is($by_status{'changed'}{'old'}{'value'}, 'old', 'the snapshot value is carried');
	is($by_status{'changed'}{'live'}{'value'}, 'new', 'and the live one');
	ok($by_status{'dropped'}, 'a row the live table no longer has is "dropped"');
	ok(!$by_status{'mab'}, 'an unchanged row is not listed');
	is($SETTER, 0, 'and nothing is written');
	is(scalar @SETTER_CALLS, 0, 'no setter call without --apply');
}

# --- the bulk refusal --------------------------------------------------------
{
	my @old = map { row(setting => "s$_", value => 'old') } 1 .. 25;
	my @live = map { row(setting => "s$_", value => 'new', server_time => '200') } 1 .. 25;
	fixture(old => \@old, live => \@live);
	my ($rc, $out) = run_cli('--apply');
	is($rc, 1, 'a bulk restore with no filter is refused');
	like($out, qr/refusing to restore 25 rows without a filter/, 'naming the count');
	is(scalar @SETTER_CALLS, 0, 'and writing nothing');
}

# --- the fresh-snapshot refusal ---------------------------------------------
{
	fixture(
		old => [ row(setting => 'pos', value => 'old') ],
		live => [ row(setting => 'pos', value => 'new', server_time => '200') ],
		fresh => { 'fresh' => 0 },
	);
	my ($rc, $out) = run_cli('--apply', '--setting', 'pos');
	is($rc, 1, '--apply without a fresh snapshot is refused');
	like($out, qr/refusing to apply: no snapshot younger than ten minutes/, 'by name');
	is(scalar @SETTER_CALLS, 0, 'and writing nothing');
}

# --- a filtered restore writes exactly the matching rows ---------------------
{
	fixture(
		old => [
			row(setting => 'pos',  value => 'old-pos'),
			row(setting => 'size', value => 'old-size'),
		],
		live => [
			row(setting => 'pos',  value => 'new-pos',  server_time => '200'),
			row(setting => 'size', value => 'new-size', server_time => '200'),
		],
	);
	my ($rc, $out) = run_cli('--apply', '--setting', 'pos');
	is($rc, 0, 'a filtered restore runs');
	is(scalar @SETTER_CALLS, 1, 'one row is written, not both');
	is($SETTER_CALLS[0]{'setting'}, 'pos', 'the named setting');
	is($SETTER_CALLS[0]{'value'}, 'old-pos', 'with the snapshot value');
	is($SETTER_CALLS[0]{'server_time'}, '9999', 'stamped with the current time, so it syncs');
	like($out, qr/settings audit APPLIED: 1 restored, 0 failed/, 'and reports it');
}

done_testing();
