# tests-for: jawn
# covers:    coding_worker in config.json switches the Coding worker off on a
#            machine that cannot spare the process (99 MB PSS on the Gou's
#            1.8 GB). Absent means on where the platform can fork, so an older
#            config keeps working, and off where it cannot (Minion dies with
#            "fork emulation"); only an explicit off stops it on a forking
#            machine. A worker left over from before the switch is taken down
#            once at master start, and the supervisor does not bring it back.
#            Also the boot order: $status starts 'off' before the tree is
#            spawned, so the spawn handler's 'started' is not clobbered.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $src = read_file(repo_root() . '/jawn');

# --- the key ---------------------------------------------------------------
my ($sub) = $src =~ /(sub coding_worker_enabled \{.*?\n\})/s;
ok($sub, 'jawn carries coding_worker_enabled');
like($sub, qr/my \$config = eval \{ decode_json\(scalar read_file\(\$file\)\) \};/,
	'it reads config.json, the machine own file');
like($sub, qr/return 1 unless ref \$config eq 'HASH';/,
	'an unreadable config leaves the worker on rather than silently stopping it');
like($sub, qr/my \$value = \$config->\{'coding_worker'\};/,
	'the key is coding_worker');
like($sub, qr/return 0 if \$value =~ \/\^\\s\*\(\?:0\|no\|off\|false\)\\s\*\$\/i;/,
	'only an explicit off (0, no, off, false) stops it');
like($sub, qr/exists \$opt\{'use_fork'\} \? \$opt\{'use_fork'\} : JawnOS::Platform::use_fork\(\)/,
	'the fork answer can be passed in, so every branch is testable');
like($sub, qr/config => \{\}, use_fork => 0/,
	'and the optional-argument form is documented in the sub');

# --- the branches ----------------------------------------------------------
# Run the extracted sub with an explicit config hash, never the real file, so a
# test on any machine sees the same answers.
my $gate_pkg = 'JawnOS::Test::CodingGate';
{
	my $ok = eval "package $gate_pkg; $sub\n1;";
	is($@, '', 'the extracted gate compiles under strict');
	ok($ok, 'and loads');
}
my $gate = $gate_pkg->can('coding_worker_enabled');
ok($gate, 'the branch harness can call coding_worker_enabled');

is($gate->(config => {}, use_fork => 0), 0,
	'no fork and no coding_worker key: the worker is off by default');
is($gate->(config => { coding_worker => 'on' }, use_fork => 0), 1,
	'no fork but an explicit on: the user asked for it, so it stays on');
is($gate->(config => { coding_worker => 1 }, use_fork => 0), 1,
	'and 1 is an explicit on too');
is($gate->(config => { coding_worker => 'off' }, use_fork => 0), 0,
	'no fork and an explicit off: off');
is($gate->(config => { coding_worker => 0 }, use_fork => 0), 0,
	'and 0 is an explicit off too');
is($gate->(config => {}, use_fork => 1), 1,
	'a fork platform and no key: an older config keeps the worker on');
is($gate->(config => { coding_worker => 'off' }, use_fork => 1), 0,
	'a fork platform and an explicit off: off');

# --- the two places that start it -----------------------------------------
like($src, qr/my \$coding_enabled = &coding_worker_enabled\(\);/,
	'the answer is read once at master start');
like($src, qr/if \(\$coding_enabled\) \{ &coding_start\(\) \}/,
	'coding_start is gated on it');
unlike($src, qr/^\&coding_start\(\);$/m,
	'nothing starts the worker unconditionally any more');
like($src, qr/&coding_supervise\(\) if \$coding_enabled;/,
	'the one-second supervisor tick leaves it down too');
like($src, qr/&coding_stop\(\) if &coding_running\(\);/,
	'a worker left over from before the switch is stopped once, not left idle');

# --- the reason is said out loud ------------------------------------------
like($src, qr/Coding worker is off on this machine/,
	'the master says why no coding run is picked up');
like($src, qr/coding_worker in config\.json/,
	'and names the config key');
like($src, qr/no fork here, so Minion cannot run/,
	'and names the platform reason when there is no fork');

# --- the boot order --------------------------------------------------------
# The pty runner's spawn handler sets $status = 'started' synchronously while it
# is called. A `my $status = 'off';` after that call runs its initialiser on the
# same variable and overwrites 'started', so a fresh master reports `off` and the
# liveness watchdog never watches its own tree.
my $status_pos = index($src, "my \$status = 'off';");
my $why_pos    = index($src, "my \$status_why = '';");
my $watch_pos  = index($src, 'my ($master_boot_watch, $master_boot_tries);');
my $spawn_pos  = index($src, '$fork = &terminal_pty_runner(&president_process());');
ok($status_pos >= 0, 'the master declares its status');
ok($why_pos >= 0, 'and its restart reason');
ok($watch_pos >= 0, 'and the boot watch');
ok($spawn_pos >= 0, 'the tree is started through terminal_pty_runner');
ok($status_pos >= 0 && $status_pos < $spawn_pos,
	'$status starts off before the spawn, so the handler is not clobbered');
ok($why_pos >= 0 && $why_pos < $spawn_pos,
	'$status_why is declared before the spawn too');
ok($watch_pos >= 0 && $watch_pos < $spawn_pos,
	'$master_boot_watch is declared before arm_boot_watch uses it');
my @status_decl = $src =~ /^[ \t]*my \$status = 'off';/mg;
is(scalar @status_decl, 1, 'the status is declared exactly once');

my ($spawn) = $src =~ /(\$fork->on\(spawn => sub\(\) \{.*?\n\t\}\);)/s;
ok($spawn, 'the spawn handler is found');
like($spawn, qr/\$status = 'started';/, 'a spawn sets the master to started');
like($spawn, qr/\$status_why = '';/, 'and clears the restart reason');
like($src, qr/if \(\$status eq 'started' && !\$master_boot_watch\)/,
	'the liveness watchdog runs for a started tree');

done_testing();
