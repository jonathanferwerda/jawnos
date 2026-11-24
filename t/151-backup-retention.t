# tests-for: lib/JawnOS/Domain/Backup.pm
# covers:    the backup prune deletes archives even where `shred` is missing
#            (Termux), the daily limit resolves per machine then per device class,
#            and the GFS plan keeps the first of a week/month/year in addition to
#            the daily snapshots.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(write_file read_file);
use Time::Piece;
use JawnOSTest;

require JawnOS::Domain::Backup;

ok( subs::provides('backup_limit'), 'the domain loader maps backup_limit' );
ok( subs::provides('backup_prune_remove'), 'and backup_prune_remove' );
ok( subs::provides('backup_prune'), 'and backup_prune' );
ok( subs::provides('backup_retention_keep'), 'and backup_retention_keep' );

# A Termux box has no `shred`. The old prune ran it anyway, then deleted the
# registry rows, so the deletion looked done while the file stayed - the phone
# reached 108 archives against a limit of 20. With no shred tool the unlink
# must still remove the file.
my $dir = tempdir(CLEANUP => 1);
my $archive = "$dir/jawnos_1793491202867.enc";
write_file($archive, 'not really a backup');
{
	local *subs::backup_shred_tool = sub { '' };
	ok( subs::backup_prune_remove($archive), 'the prune reports the removal' );
}
ok( !-e $archive, 'and the archive is gone with no shred on the box' );

# The daily limit: this machine's own row wins, then the device class, then
# seven days. Weekly, monthly and yearly archives are kept in addition by
# backup_retention_keep, so this value is a daily tier, not a total cap.
sub limit_with {
	my ($table) = @_;
	local *subs::misc_setting_list = sub { $table };
	local *subs::signatorial_designer = sub { 'e397332d' };
	local *subs::device_setter = sub { 'mobile' };
	return subs::backup_limit();
}
is( limit_with({ mobile => { max_backups => 20 }, e397332d => { max_backups => 10 } }),
	10, 'this machine\'s own max_backups wins' );
is( limit_with({ mobile => { max_backups => 20 } }),
	20, 'the device class is the fallback' );
is( limit_with({ server => { max_backups => 31 } }),
	7, 'a machine with no row of its own keeps seven days' );
is( limit_with({ mobile => { max_backups => 0 } }),
	0, 'zero is a real choice, not "unset"' );
is( limit_with({ mobile => { max_backups => 'lots' } }),
	7, 'a non-numeric row is not a limit' );

# The four Enc fields resolve the same way: this machine's own row wins, then
# the device class, then the default.
{
	local *subs::misc_setting_list = sub {
		return {
			mobile => { backup_weeks => 6, backup_months => 5, backup_years => 2 },
			e397332d => { backup_weeks => 8 },
		};
	};
	local *subs::signatorial_designer = sub { 'e397332d' };
	local *subs::device_setter = sub { 'mobile' };
	my $tiers = subs::backup_retention_settings();
	is( $tiers->{'weeks'}, 8, 'the machine override wins for weeks' );
	is( $tiers->{'months'}, 5, 'the device class supplies months' );
	is( $tiers->{'years'}, 2, 'the device class supplies years' );
	is( $tiers->{'days'}, 7, 'days falls back to seven when max_backups is unset' );
}

# The prune keeps the GFS plan, never the current snapshot, and removes the
# rest. Fixtures in a temp dir; no database is touched.
{
	package FakeRows;
	sub new { my ($class, $rows) = @_; return bless { rows => $rows }, $class; }
	sub hashes { return $_[0]->{'rows'}; }
}

sub archive_for {
	my ($dir, $date) = @_;
	my $epoch = Time::Piece->strptime($date . ' 12:00:00', '%Y-%m-%d %H:%M:%S')->epoch;
	my $file = "$dir/jawnos_" . ($epoch * 1000) . '.enc';
	write_file($file, 'archive');
	return $file;
}

my $dir = tempdir(CLEANUP => 1);
my @files = map { archive_for($dir, $_) } qw(2026-11-01 2026-11-02 2026-11-03 2026-11-04 2026-11-05);
write_file("$dir/jawnos.enc", 'current');
my %by_date;
foreach my $file (@files) {
	my ($stamp) = $file =~ /_(\d+)\.enc$/;
	my $date = Time::Piece->new(int($stamp / 1000))->strftime('%Y-%m-%d');
	$by_date{$date} = $file;
}
my $result;
{
	local *subs::backups_dir = sub { $dir };
	local *subs::database_grabber = sub { (undef, "$dir/jawnos.db", undef) };
	local *subs::backup_limit = sub { 2 };
	local *subs::backup_retention_settings = sub { { days => 2, weeks => 4, months => 12, years => 3 } };
	local *subs::db_select = sub { FakeRows->new([]) };
	local *subs::db_delete = sub { 1 };
	local *subs::deletion_registration = sub { 1 };
	local *subs::backup_archive_prune = sub { {} };
	$result = subs::backup_prune();
}
is( $result->{'seen'}, 5, 'five dated archives were seen' );
is( $result->{'limit'}, 2, 'the daily tier is two days' );
is( $result->{'removed'}, 1, 'the middle of the week was removed' );
ok( -e $by_date{'2026-11-05'}, 'the newest snapshot survives' );
ok( -e $by_date{'2026-11-04'}, 'the second daily survives' );
ok( -e $by_date{'2026-11-01'}, 'the first of the month/year survives' );
ok( -e $by_date{'2026-11-02'}, 'the first of the next week survives' );
ok( !-e $by_date{'2026-11-03'}, 'the middle snapshot is gone' );
ok( -e "$dir/jawnos.enc", 'the current snapshot is never pruned' );

done_testing();
