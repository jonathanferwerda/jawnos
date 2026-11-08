# tests-for: jawn
# covers:    coding_worker in config.json switches the Coding worker off on a
#            machine that cannot spare the process (99 MB PSS on the Gou's
#            1.8 GB). Absent or unreadable means on, so an older config keeps
#            working; only an explicit off stops it. A worker left over from
#            before the switch is taken down once at master start, and the
#            supervisor does not bring it back.

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
like($sub, qr/return 1 unless defined \$value;/,
	'an older config without the key keeps the worker on');
like($sub, qr/return 0 if \$value =~ \/\^\\s\*\(\?:0\|no\|off\|false\)\\s\*\$\/i;/,
	'only an explicit off (0, no, off, false) stops it');

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
like($src, qr/Coding worker is off on this machine \(coding_worker in config\.json\)/,
	'the master says why no coding run is picked up');

done_testing();
