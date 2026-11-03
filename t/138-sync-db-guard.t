# tests-for: lib/JawnOS/Domain/Sync.pm
# covers:    A missing database or table must not crash the boot path's sync_jobs calls.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# President.pl calls subs::sync_jobs_reap(0) while the tree comes up. On a
# half-seeded house (a 0-byte jawnos.db) db_query returns undef and the old
# `->hashes` dereference killed the process, so the watchdog restarted it in a
# loop and the guest never painted a frame (VM 103). The three sync-job helpers
# must treat an unreadable table as "nothing to do", not as a fatal error.

local *subs::db_query = sub { return undef };

my ($n, $ok);
$ok = eval { $n = subs::sync_jobs_reap(0); 1 };
ok( $ok, 'sync_jobs_reap does not die when the query returns undef' ) or diag($@);
is( $n, 0, 'sync_jobs_reap reports no reaped jobs' );

my $step;
$ok = eval { $step = subs::sync_job_step('uuid-1', 'tables', { label => 'Tables' }); 1 };
ok( $ok, 'sync_job_step does not die when the query returns undef' ) or diag($@);
is( ref $step, 'HASH', 'sync_job_step still returns the step it was asked about' );
is( $step->{'key'}, 'tables', 'and keeps its key' );

$ok = eval { subs::sync_job_finish('uuid-1', 'failed', 'test'); 1 };
ok( $ok, 'sync_job_finish does not die when the query returns undef' ) or diag($@);

done_testing();
