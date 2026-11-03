# tests-for: scripts/log_rotate.pl
# covers:    a log a live process appends to (Mojo::Log '>>', systemd
#            StandardOutput=append:) can be cut in place: the last N lines stay
#            live, the earlier bytes go to a gzip archive, and a file with no
#            more than N lines is left alone.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(write_file read_file);
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);

my $dir = tempdir(CLEANUP => 1);
my $script = "$FindBin::Bin/../scripts/log_rotate.pl";

my $log = "$dir/manager.log";
write_file($log, join('', map { "line $_\n" } 1 .. 50));

my $out = qx{$^X "$script" --apply --keep 10 --min-bytes 0 "$log" 2>&1};
my $rc = $? >> 8;
is($rc, 0, 'the rotation runs') or diag($out);

my $live = read_file($log);
is($live, join('', map { "line $_\n" } 41 .. 50), 'the live log keeps the last ten lines');

my ($archive) = glob("$dir/manager.log.*.gz");
ok($archive && -e $archive, 'an archive was written beside the log');
my $head = '';
gunzip($archive => \$head) or fail("gunzip: $GunzipError");
is($head, join('', map { "line $_\n" } 1 .. 40), 'the archive holds the earlier lines');

my $before = glob("$dir/manager.log.*.gz");
my $again = qx{$^X "$script" --apply --keep 10 --min-bytes 0 "$log" 2>&1};
my $after = glob("$dir/manager.log.*.gz");
is($after, $before, 'a second pass with no more than ten lines writes no new archive');
like($again, qr/at most 10 lines/, 'and says why it skipped');

# no trailing newline: the final partial line counts
my $partial = "$dir/partial.log";
write_file($partial, join('', map { "row $_\n" } 1 .. 19) . 'row 20');
qx{$^X "$script" --apply --keep 5 --min-bytes 0 "$partial" 2>&1};
is(read_file($partial), join('', map { "row $_\n" } 16 .. 19) . 'row 20', 'a partial final line is kept in the tail');
my ($partial_gz) = glob("$dir/partial.log.*.gz");
my $partial_head = '';
gunzip($partial_gz => \$partial_head) or fail("gunzip: $GunzipError");
is($partial_head, join('', map { "row $_\n" } 1 .. 15), 'and the archive stops before the kept tail');

# fewer lines than --keep: nothing to do
my $small = "$dir/small.log";
write_file($small, "one\ntwo\nthree\n");
my $small_out = qx{$^X "$script" --apply --keep 10 --min-bytes 0 "$small" 2>&1};
is(read_file($small), "one\ntwo\nthree\n", 'a short log is not touched');
like($small_out, qr/at most 10 lines/, 'the short log is reported as skipped');

done_testing();
