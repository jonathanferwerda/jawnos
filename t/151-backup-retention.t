# tests-for: lib/JawnOS/Domain/Backup.pm
# covers:    the backup prune deletes archives even where `shred` is missing
#            (Termux), and the limit resolves per machine then per device class.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(write_file read_file);
use JawnOSTest;

require JawnOS::Domain::Backup;

ok( subs::provides('backup_limit'), 'the domain loader maps backup_limit' );
ok( subs::provides('backup_prune_remove'), 'and backup_prune_remove' );
ok( subs::provides('backup_prune'), 'and backup_prune' );

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

# The limit: this machine's own row wins, then the device class, then three.
# misc_setting_list is keyed by device class and by signatorial.
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
	3, 'a machine with no row of its own keeps three' );
is( limit_with({ mobile => { max_backups => 0 } }),
	0, 'zero is a real choice, not "unset"' );
is( limit_with({ mobile => { max_backups => 'lots' } }),
	3, 'a non-numeric row is not a limit' );

# The prune keeps the newest `limit` archives, never the current snapshot, and
# removes the rest. Fixtures in a temp dir; no database is touched.
{
	package FakeRows;
	sub new { my ($class, $rows) = @_; return bless { rows => $rows }, $class; }
	sub hashes { return $_[0]->{'rows'}; }
}
my $dir = tempdir(CLEANUP => 1);
foreach my $n (1 .. 5) {
	my $f = "$dir/jawnos_$n.enc";
	write_file($f, 'archive');
	utime(1_700_000_000 + $n, 1_700_000_000 + $n, $f);
}
write_file("$dir/jawnos.enc", 'current');
my $result;
{
	local *subs::backups_dir = sub { $dir };
	local *subs::database_grabber = sub { (undef, "$dir/jawnos.db", undef) };
	local *subs::backup_limit = sub { 2 };
	local *subs::db_select = sub { FakeRows->new([]) };
	local *subs::db_delete = sub { 1 };
	local *subs::deletion_registration = sub { 1 };
	$result = subs::backup_prune();
}
is( $result->{'seen'}, 5, 'five dated archives were seen' );
is( $result->{'removed'}, 3, 'the three older ones were removed' );
is( scalar( () = glob("$dir/jawnos_*.enc") ), 2, 'the two newest survive' );
ok( -e "$dir/jawnos.enc", 'the current snapshot is never pruned' );

done_testing();
