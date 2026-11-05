# tests-for: lib/JawnOS/Domain/Backup.pm
# covers:    an abandoned backup scratch copy in ~/.president is discarded; a copy still in use and
#           the agent's own files there are kept

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use JawnOSTest;

my $root = root();
require "$root/lib/JawnOS/Domain/Backup.pm";

my $home = tempdir(CLEANUP => 1);
my $dir = "$home/.president/";
mkdir $dir or die "cannot make $dir: $!";

# A build writes <random>.sql, an export writes <random>.sql plus its schema,
# and sqlite may leave a -journal beside either. All three go when abandoned.
my @swept = ('dead.sql', 'dead.sql-journal', 'dead.sql.schema.sql');
# A build running now (young), and the agent's own databases in the same folder,
# must survive; nothing here may take the coding queue or the minion with it.
my @kept = ('live.sql', 'live.sql-journal', 'coding-queue.db', 'minion.db');

my $old = time - (4 * 60 * 60);
sub write_one {
	my ($path, $when) = @_;
	open(my $fh, '>', $path) or die "$path: $!";
	print $fh "x";
	close $fh;
	utime $when, $when, $path if defined $when;
}

&write_one($dir . $_, $old) for @swept;
&write_one($dir . $_, undef) for @kept;

my @notes;
{
	local *subs::home = sub { my ($path) = @_; $path =~ s{^~}{$home}; $path };
	local *subs::log_writer = sub { push @notes, $_[0] };
	is(&subs::backup_scratch_tidy(), scalar @swept, 'every abandoned copy is counted as gone');
}

ok(!-e $dir . $_, "swept: $_") for @swept;
ok(-e $dir . $_, "kept: $_") for @kept;
like(join(' ', @notes), qr/discarded 3 leftover/, 'the tidy reports what it removed');

# A machine with no ~/.president (a fresh tree) is not an error and says nothing.
{
	local *subs::home = sub { '/nonexistent-jawnos-test/.president/' };
	local *subs::log_writer = sub { push @notes, 'should not log' };
	is(&subs::backup_scratch_tidy(), 0, 'a missing ~/.president returns zero');
}

done_testing();
