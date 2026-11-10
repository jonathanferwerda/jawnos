# tests-for: perl/utility_jobs.pl
# covers:    A tree that just started does not run its whole past-due utility backlog in one tick,
#           and the cap is never the undefined a job process could inherit.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# Every utility's next slot is rebuilt from its persisted last_run, so a tree
# that restarts has the whole backlog due at once. The old first pass started
# every due job in one tick, and a job may fork a subprocessor - a copy of the
# grown process as far as the kernel's accounting is concerned. Android charges
# each fork's RSS to the app's uid, so the first pass could look like a
# gigabyte to the low-memory killer (35 processes / ~1 GB RSS on the phone) and
# the app was reaped every few seconds.
#
# Two things keep the boot small: a short grace before the runner does anything,
# and a cap on how many due jobs one pass may start. The rest stay due for the
# next tick instead of all starting together.

my $src = read_file(repo_root() . '/perl/utility_jobs.pl');

my ($functions) = $src =~ /(sub utility_functions\(\) \{.*?\n\})/s;
ok($functions, 'utility_functions is still one sub');
like($functions, qr/\$utility_boot_at = &subs::rightNow\(\);/,
	'the utility child records when it came up');

my ($runner) = $src =~ /(sub utility_runner\(\) \{.*?\n\}\n)/s;
ok($runner, 'utility_runner is still one sub');
like($runner, qr/return if \$utility_boot_at && &subs::rightNow\(\) - \$utility_boot_at < 20000;/,
	'the first twenty seconds after boot run no job');

like($src, qr/our \$utility_pass_cap = 2;/, 'one pass starts at most two jobs');
like($runner, qr/my \$pass_cap = &subs::utility_pass_cap_value\(\$utility_pass_cap\);/, 'the cap is resolved before the pass: 0 >= undef is true');

my $cap_at = index($runner, 'if ($started >= $pass_cap)');
my $stamp_at = index($runner, q{$u->{'last_attempt'} = $now;});
ok($cap_at >= 0, 'the pass checks its count before starting a job');
ok($stamp_at > $cap_at,
	'a job held back by the cap is not stamped as attempted');

like($runner, qr/if \(\$started >= \$pass_cap\) \{\s*\$pending = 1;.*?\bnext;/s,
	'a job over the cap waits for the next tick');
like($runner, qr/if \(!\$ran && !\$pending &&/,
	'a pass that still has work due does not write the idle marker');

my $ran_at = index($runner, 'my $ran = 0;');
my $pending_decl = index($runner, 'my $pending = 0;');
ok($pending_decl > $ran_at, 'the pending flag is declared with the pass state');

done_testing();
