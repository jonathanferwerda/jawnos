# tests-for: t/lib/JawnOSTest.pm scripts/run_tests_fork.pl
# covers:    The suite's scratch dirs on tmpfs. File::Temp's CLEANUP runs only
#            on a normal exit, so a killed or orphaned run left one full copy of
#            the house database per test file behind (29G of RAM in /tmp on this
#            box). The harness now owns its dirs - keyed by pid, so a forked
#            child never removes the sandbox its siblings share - and removes
#            them recursively at exit and on INT/TERM/HUP. The fork runner sweeps
#            what a SIGKILLed run could not: each dir carries its owner's pid and
#            /proc starttime, so the sweep removes a dead owner's dir at once and
#            still keeps a live run's, which no cwd or open file points at.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use File::Temp qw(tempdir);
use Test::More;
use JawnOSTest;

sub put {
	my ($path, $text) = @_;
	open(my $fh, '>', $path) or die "put $path: $!\n";
	print $fh $text;
	close $fh;
}

# --- the harness removes what it created -------------------------------------

my $owned = tempdir('jawnos-test-XXXXXX', TMPDIR => 1, CLEANUP => 0);
mkdir "$owned/database" or die "mkdir $owned/database: $!\n";
put("$owned/database/jawnos.db", 'x' x 64);
JawnOSTest::_track_scratch($owned, 0);
JawnOSTest::_scratch_cleanup(0);
ok(!-e $owned, 'cleanup removes the dir and the database copy inside it');

# A forked child inherits the registry. It must remove only its own isolated
# dir, never the sandbox the parent and its siblings are still using.
my $shared = tempdir('jawnos-test-XXXXXX', TMPDIR => 1, CLEANUP => 0);
mkdir "$shared/database" or die "mkdir $shared/database: $!\n";
JawnOSTest::_track_scratch($shared, 0);
JawnOSTest::_scratch_cleanup(999_999);
ok(-d $shared, "a child does not remove another process's scratch dir");
JawnOSTest::_scratch_cleanup(0);
ok(!-e $shared, 'and the owner still removes it');

# --- the runner sweeps what a dead run left ----------------------------------

my $tmp = tempdir('jawnos-sweep-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $old   = "$tmp/jawnos-test-dead01";
my $fresh = "$tmp/jawnos-test-live01";
my $tap   = "$tmp/jawnos-tap-dead01";
my $hints = "$tmp/jawnos-test-times-999999";
mkdir $old or die "mkdir $old: $!\n";
mkdir "$old/database" or die "mkdir $old/database: $!\n";
put("$old/database/jawnos.db", 'x' x 64);
mkdir $fresh or die "mkdir $fresh: $!\n";
put($tap, "1..1\nok 1\n");
put($hints, "1.0\tt/01-names.t\n");
my $past = time() - 7200;
utime($past, $past, $old, $tap) or die "utime: $!\n";

my $removed = JawnOSTest::sweep_stale_scratch(dir => $tmp, max_age => 60);
ok(!-e $old, 'an abandoned sandbox is swept, database copy included');
ok(!-e $tap, 'and its TAP spill file');
ok(-d $fresh, 'a fresh dir is left for the run using it');
ok(-f $hints, 'the duration-hints file is not scratch');
cmp_ok($removed, '>=', 2, 'the sweep reports what it removed');

# --- the owner stamp decides without waiting out the age ---------------------

my $live = "$tmp/jawnos-test-live02";
mkdir $live or die "mkdir $live: $!\n";
JawnOSTest::_stamp_owner($live);          # this process, and its starttime
utime($past, $past, $live) or die "utime: $!\n";
JawnOSTest::sweep_stale_scratch(dir => $tmp, max_age => 60);
ok(-d $live, 'a stamped dir whose owner is still running is kept, however old');

my $dead = "$tmp/jawnos-test-dead02";
mkdir $dead or die "mkdir $dead: $!\n";
JawnOSTest::_stamp_owner($dead, 999_999, 1);
JawnOSTest::sweep_stale_scratch(dir => $tmp, max_age => 3600);
ok(!-e $dead, 'a young dir stamped by a dead pid is swept at once');

my $reused = "$tmp/jawnos-test-reused";
mkdir $reused or die "mkdir $reused: $!\n";
JawnOSTest::_stamp_owner($reused, $$, 1);  # same pid, wrong starttime
JawnOSTest::sweep_stale_scratch(dir => $tmp, max_age => 3600);
ok(!-e $reused, 'a stamp whose pid was reused (starttime differs) is swept');

done_testing();
