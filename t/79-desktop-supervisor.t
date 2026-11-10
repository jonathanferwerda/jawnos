# tests-for: desktop/install.sh desktop/jawnos_desktop/cli.py desktop/jawnos_desktop/core.py desktop/jawnos_desktop/core_paths.py desktop/jawnos_desktop/core_process.py desktop/jawnos_desktop/core_secrets.py desktop/jawnos_desktop/core_autostart.py desktop/jawnos_desktop/core_shell.py desktop/systemd/jawnos-watch.service.in
# covers:    The desktop's watcher is the supervisor the house was missing: it starts a tree that is down, and restarts one...

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
my $core_paths = read_file("$root/desktop/jawnos_desktop/core_paths.py");
my $core_process = read_file("$root/desktop/jawnos_desktop/core_process.py");
my $core_secrets = read_file("$root/desktop/jawnos_desktop/core_secrets.py");
my $core_autostart = read_file("$root/desktop/jawnos_desktop/core_autostart.py");
my $core_shell = read_file("$root/desktop/jawnos_desktop/core_shell.py");
my $cli = read_file("$root/desktop/jawnos_desktop/cli.py");
my $unit = read_file("$root/desktop/systemd/jawnos-watch.service.in");
my $install = read_file("$root/desktop/install.sh");

like($core, qr/return "started", "jawn was down; started it/,
	'a down tree is started, not just reported');
like($core, qr/ok, message = start_all\(jawn_dir, with_ble=with_ble\)/,
	'it goes through the combined jawn + BLE start');
like($core_paths, qr/def is_held\(\):/, 'a deliberate stop is remembered');
like($core, qr/return "held", "stopped by request"/, 'the watcher leaves a stopped tree alone');
like($cli, qr/action in \("started", "restarted"\)/,
	'the watch cooldown covers a start');
like($cli, qr/action in \("started", "restarted", "failed", "down", "held"\)/,
	'the watch reports a start and a hold');
like($unit, qr{^ExecStart=\@DESKTOP\@/jawnosctl watch --interval 10$}m,
	'the unit runs the watcher');
like($unit, qr/^Restart=always$/m, 'systemd restarts the watcher itself');
like($unit, qr/^KillMode=process$/m, 'stopping the watcher leaves the tree running');
like($install, qr/for unit in jawnos-bt jawnos jawnos-watch/, 'the installer writes the watcher unit');
like($install, qr/enable --now jawnos-watch\.service/, 'and enables it');
like($install, qr/requires PySide6 with Qt WebEngine/,
	'the installer names Qt WebEngine as the one desktop engine');
unlike($install, qr/web[K]it2gtk|gst-inspect-1\.0|gstreamer1\.0/,
	'and no longer checks for WebKitGTK or the GStreamer stack');

# desktop/mkosi is the image build tree. A build can leave root-owned .stage or
# output files there; copying the whole desktop aborted the table's install on
# exactly those. The app's own entries are copied and mkosi is skipped.
like($install, qr/for entry in "\$DESKTOP_SRC"\/\*/, 'the installer copies the app entries');
like($install, qr/mkosi\) continue/, 'and skips the image build tree');
like($install, qr/rm -rf "\$DEST\/mkosi"/, 'an older install loses the build tree');
unlike($install, qr/cp -R "\$DESKTOP_SRC\/\." "\$DEST\/"/,
	'never copies the whole desktop including mkosi');

# The supervisor is split by platform surface: spawn/kill, paths, secrets,
# autostart and shell helpers live in their own modules, and core.py keeps the
# public names by re-exporting them so no caller changes its imports.
like($core_paths, qr/^def config_dir\(\):/m, 'paths live in core_paths');
like($core_paths, qr/^def default_jawn_dir\(\):/m, 'including the tree locator');
like($core_process, qr/^def spawn_detached\(/m, 'detached spawn lives in core_process');
like($core_process, qr/start_new_session=True/, 'with the same session flag');
like($core_process, qr/^def _jawn_master_pids\(\):/m, 'and the /proc master scan');
like($core_process, qr/^def start_jawn\(/m, 'and the jawn lifecycle');
like($core_secrets, qr/^def _secret_tool\(\):/m, 'the keyring store lives in core_secrets');
like($core_secrets, qr/^def _fernet\(/m, 'with the Fernet fallback');
like($core_autostart, qr/^def set_autostart\(/m, 'autostart lives in core_autostart');
like($core_autostart, qr/jawnos-bt\.desktop/, 'with the same XDG unit name');
like($core_shell, qr/^def open_console\(/m, 'the terminal launcher lives in core_shell');
like($core_shell, qr/webbrowser\.open/, 'and the browser open');
like($core, qr/from \.core_paths import/, 'core re-exports the path helpers');
like($core, qr/from \.core_process import/, 'the process helpers');
like($core, qr/from \.core_autostart import/, 'autostart');
like($core, qr/from \.core_shell import/, 'and the shell helpers');
like($core, qr/from \.core_secrets import manager_host/, 'and the ticket host');
unlike($core, qr/^def spawn_detached\(/m, 'core.py no longer defines the process primitives');
unlike($core, qr/^def config_dir\(\):/m, 'nor the path helpers');

my $python = qx{python3 --version 2>/dev/null};

SKIP: {
	skip 'python3 is not installed', 6 unless $python;

	my $dir = tempdir(CLEANUP => 1);
	my $state = tempdir(CLEANUP => 1);
	my $py = "$dir/probe.py";
	write_file($py, <<'PY');
import os
import sys

os.environ['XDG_STATE_HOME'] = sys.argv[2]
sys.path.insert(0, sys.argv[1] + '/desktop')
from jawnos_desktop import core
from jawnos_desktop import core_autostart, core_paths, core_process, core_secrets, core_shell

print('split:' + str(
    core.config_dir is core_paths.config_dir
    and core.spawn_detached is core_process.spawn_detached
    and core.start_jawn is core_process.start_jawn
    and core.autostart_path is core_autostart.autostart_path
    and core.open_console is core_shell.open_console
    and core.manager_host is core_secrets.manager_host))

core.set_held(True)
print('held:' + str(core.is_held()))
core.version_mismatch = lambda d: None
core.jawn_up = lambda d: False
print('downheld:' + core.restart_if_stale('/x')[0])
core.set_held(False)
print('cleared:' + str(core.is_held()))

core.start_all = lambda d, with_ble=True: (True, 'starting jawn')
print('down:' + core.restart_if_stale('/x')[0])

core.version_mismatch = lambda d: ('1.0', '1.1')
core.restart_all = lambda d, with_ble=True: (True, 'restarted')
print('stale:' + core.restart_if_stale('/x')[0])
PY

	open(my $fh, '-|', 'python3', $py, $root, $state) or die "python3: $!\n";
	my $out = do { local $/; <$fh> };
	close $fh;
	like($out, qr/^held:True$/m, 'a stop is held for this boot');
	like($out, qr/^downheld:held$/m, 'the watcher does not resurrect a stopped tree');
	like($out, qr/^cleared:False$/m, 'a start clears the hold');
	like($out, qr/^down:started$/m, 'restart_if_stale starts a down tree');
	like($out, qr/^stale:restarted$/m, 'and still restarts a stale one');
	like($out, qr/^split:True$/m, 'core re-exports the split modules');
}

done_testing();
