# tests-for: jp/alarmclock/alarmclock_04_jobs_clock_config_net.ino
# covers:    A physical switch flip is a person's movement and must not be lost
#            to a transient network hiccup. handle_jobs deleted every https job
#            at the bottom of the loop even when https_request returned "no
#            ping" (homebaseOnline is 0 until the next 60 s ping), so flips were
#            dropped every other time or arrived up to a minute late. A
#            switch/button job now gets one attempt past the gate and a bounded
#            retry; its timestamp was stamped at the flip, so a retry still
#            records the real moment.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $src  = scalar read_file("$root/jp/alarmclock/alarmclock_04_jobs_clock_config_net.ino");

like($src, qr/bool critical = \(job_response == "switch" \|\| job_response == "button"\);/,
	'a switch/button job is marked critical');
like($src, qr/if \(critical\) \{ homebaseOnline = 1; \}/,
	'a critical event may attempt past the ping gate');
like($src, qr/bool failed = \(response == "failure" \|\| response == "no ping"\);/,
	'the sender recognises a transient failure');
like($src, qr/if \(failed\) \{\s*int tries/s, 'a failed job is retried instead of dropped');
like($src, qr/if \(tries < 4\)/, 'the retry is bounded');
like($src, qr/coreJobs\[coreKeys\[i\]\]\["next_at"\] = String\(\(unsigned long\)\(millis\(\) \+ 1500UL \* tries\)\);/,
	'the retry backs off');

done_testing();
