use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);
use RepoSource;

# The desktop's watcher is the supervisor the house was missing: it starts a
# tree that is down, and restarts one whose running version is not the on-disk
# version. A systemd --user unit keeps the watcher itself alive, without taking
# the tree down when the watcher stops.

my $root = repo_root();
my $core = read_file("$root/desktop/jawnos_desktop/core.py");
my $cli = read_file("$root/desktop/jawnos_desktop/cli.py");
my $unit = read_file("$root/desktop/systemd/jawnos-watch.service.in");
my $install = read_file("$root/desktop/install.sh");

like($core, qr/return "started", "jawn was down; started it/,
	'a down tree is started, not just reported');
like($core, qr/ok, message = start_all\(jawn_dir, with_ble=with_ble\)/,
	'it goes through the combined jawn + BLE start');
like($cli, qr/action in \("started", "restarted"\)/,
	'the watch cooldown covers a start');
like($cli, qr/action in \("started", "restarted", "failed", "down"\)/,
	'the watch reports a start');
like($unit, qr{^ExecStart=\@DESKTOP\@/jawnosctl watch --interval 10$}m,
	'the unit runs the watcher');
like($unit, qr/^Restart=always$/m, 'systemd restarts the watcher itself');
like($unit, qr/^KillMode=process$/m, 'stopping the watcher leaves the tree running');
like($install, qr/for unit in jawnos-bt jawnos jawnos-watch/, 'the installer writes the watcher unit');
like($install, qr/enable --now jawnos-watch\.service/, 'and enables it');

my $python = qx{python3 --version 2>/dev/null};

SKIP: {
	skip 'python3 is not installed', 2 unless $python;

	my $dir = tempdir(CLEANUP => 1);
	my $py = "$dir/probe.py";
	write_file($py, <<'PY');
import sys
sys.path.insert(0, sys.argv[1] + '/desktop')
from jawnos_desktop import core

core.version_mismatch = lambda d: None
core.jawn_up = lambda d: False
core.start_all = lambda d, with_ble=True: (True, 'starting jawn')
print('down:' + core.restart_if_stale('/x')[0])

core.version_mismatch = lambda d: ('1.0', '1.1')
core.restart_all = lambda d, with_ble=True: (True, 'restarted')
print('stale:' + core.restart_if_stale('/x')[0])
PY

	open(my $fh, '-|', 'python3', $py, $root) or die "python3: $!\n";
	my $out = do { local $/; <$fh> };
	close $fh;
	like($out, qr/^down:started$/m, 'restart_if_stale starts a down tree');
	like($out, qr/^stale:restarted$/m, 'and still restarts a stale one');
}

done_testing();
