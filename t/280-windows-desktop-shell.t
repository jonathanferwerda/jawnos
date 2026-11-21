# tests-for: desktop/jawnos_desktop/__init__.py desktop/jawnos_desktop/core_paths.py desktop/jawnos_desktop/core_process.py desktop/jawnos_desktop/core_secrets.py desktop/jawnos_desktop/core_shell.py desktop/jawnos_desktop/core_autostart.py desktop/jawnos_desktop/core.py desktop/jawnos_desktop/gpu.py desktop/jawnos_desktop/bridge.py desktop/jawnos_desktop/qt_panel.py desktop/jawnos_desktop/qt_shell.py
# covers:    the desktop shell's Windows lane: the supervisor's paths and boot
#            stamp, the bundled runtime's PATH and portable flags, the master's
#            pid record instead of /proc, DPAPI ticket storage, no Linux GPU
#            flags on Windows, and the pythonw.exe commands for the app and
#            Browse. The functional probe runs with os.name still Linux and the
#            modules' IS_WINDOWS seam turned on, so the decisions are exercised
#            without a Windows runner; the process and DPAPI calls themselves
#            are pinned as source invariants.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use RepoSource;

my $root = repo_root();

sub source {
	my ($rel) = @_;
	return read_file("$root/$rel");
}

my $init      = source('desktop/jawnos_desktop/__init__.py');
my $paths     = source('desktop/jawnos_desktop/core_paths.py');
my $process   = source('desktop/jawnos_desktop/core_process.py');
my $secrets   = source('desktop/jawnos_desktop/core_secrets.py');
my $shell     = source('desktop/jawnos_desktop/core_shell.py');
my $autostart = source('desktop/jawnos_desktop/core_autostart.py');
my $core      = source('desktop/jawnos_desktop/core.py');
my $gpu       = source('desktop/jawnos_desktop/gpu.py');
my $bridge    = source('desktop/jawnos_desktop/bridge.py');
my $panel     = source('desktop/jawnos_desktop/qt_panel.py');
my $qtshell   = source('desktop/jawnos_desktop/qt_shell.py');

# --- the Qt theme switch -----------------------------------------------------

like($init, qr/if sys\.platform\.startswith\("linux"\):\n    os\.environ\.setdefault\("QT_QPA_PLATFORMTHEME", "generic"\)/,
	'the generic Qt theme is asked for on Linux only');
unlike($init, qr/^os\.environ\.setdefault\("QT_QPA_PLATFORMTHEME"/m,
	'never unconditionally, where Windows has no generic theme plugin');

# --- paths ------------------------------------------------------------------

like($paths, qr/^IS_WINDOWS = os\.name == "nt"$/m, 'core_paths has a Windows switch');
like($paths, qr/^def _appdata\(\):/m, 'roaming APPDATA is a named root');
like($paths, qr/^def _local_appdata\(\):/m, 'LOCALAPPDATA is a named root');
like($paths, qr/def config_dir\(\):\n    if IS_WINDOWS:/,
	'config.json lives under APPDATA on Windows');
like($paths, qr/def state_dir\(\):\n    if IS_WINDOWS:/,
	'per-user state lives under LOCALAPPDATA on Windows');
like($paths, qr/def _windows_boot_id\(/, 'the boot stamp has a Windows source');
like($paths, qr/GetTickCount64/, 'it derives the boot epoch from GetTickCount64');
like($paths, qr/def default_jawn_dir\(\):/, 'the tree locator remains the same shape');
like($paths, qr/return os\.path\.join\(_local_appdata\(\), "JawnOS", "app"\)/,
	'a package copied away from the tree falls back to the installed app');

# --- process ----------------------------------------------------------------

like($process, qr/^IS_WINDOWS = os\.name == "nt"$/m, 'core_process has a Windows switch');
like($process, qr/^def _windows_process_name\(/m, 'liveness asks for the image name');
like($process, qr/QueryFullProcessImageNameW/,
	'not os.kill(pid, 0), which terminates on Windows');
like($process, qr/^def _windows_master_pids\(/m, 'the master is read from its pid record');
like($process, qr/\.president", "pid"/, 'the record is ~/.president/pid');
like($process, qr/name\.lower\(\)\.startswith\("perl"\)/,
	'a recycled pid that is not perl is not the master');
like($process, qr/creationflags=0x00000008 \| 0x00000200/,
	'the tree spawns detached, with its own process group');
like($process, qr/"taskkill", "\/PID", str\(pid\), "\/T", "\/F"/,
	'the forced stop is taskkill /T /F');
like($process, qr/runtime", "perl", "bin"/, 'the bundled perl is found from the tree');
like($process, qr/runtime", "c", "bin"/, 'c\\bin goes on PATH beside perl\\bin');
like($process, qr/"JAWNOS_PORTABLE", "1"/, 'the portable flag matches launch.bat');
like($process, qr/the BLE bridge is not available on Windows/,
	'the BlueZ bridge is a no-op on Windows');

# --- ticket storage ---------------------------------------------------------

like($secrets, qr/^IS_WINDOWS = os\.name == "nt"$/m, 'core_secrets has a Windows switch');
like($secrets, qr/CryptProtectData/, 'the ticket can be sealed with DPAPI');
like($secrets, qr/CryptUnprotectData/, 'and read back with DPAPI');
like($secrets, qr/def _dpapi_store\(/, 'DPAPI has a store');
like($secrets, qr/if _ss_store\(url\) or _dpapi_store\(url\) or _file_store\(url\)/,
	'DPAPI sits between the keyring and the Fernet file');
like($secrets, qr/"Windows DPAPI"/, 'the panel names the backend truthfully');

# --- shell, autostart, GPU --------------------------------------------------

like($shell, qr/^def desktop_argv\(\):/m, 'the app command is built in one place');
like($shell, qr/"pythonw\.exe"/, 'Windows starts the app with pythonw.exe');
like($shell, qr/CREATE_NEW_CONSOLE/, 'the console path asks for a real console');
like($autostart, qr/if IS_WINDOWS:\n        return False/, 'BLE autostart is off on Windows');
like($core, qr/"ble_with_jawn": not IS_WINDOWS/,
	'the BLE coupling defaults off on Windows');
like($core, qr/if IS_WINDOWS:\n        with_ble = False/,
	'and every start/stop/restart forces it off');
like($gpu, qr/^IS_WINDOWS = os\.name == "nt"$/m, 'gpu has a Windows switch');
like($gpu, qr/if IS_WINDOWS:\n        # VA-API/, 'the Linux GPU probe is skipped on Windows');
unlike($gpu, qr/if os\.name == "nt"/, 'the switch is one module constant, not a scattered test');

# --- panel and tray ---------------------------------------------------------

like($panel, qr/^IS_WINDOWS = os\.name == "nt"$/m, 'the panel has a Windows switch');
like($panel, qr/if IS_WINDOWS:\n            self\.ble_dot = self\.ble_state = None/,
	'the BLE status row is absent on Windows');
like($panel, qr/if not IS_WINDOWS:\n            bluetooth = self\._card/,
	'the Bluetooth card is absent on Windows');
like($qtshell, qr/if os\.name == "nt":\n            tray\.setToolTip\("JawnOS - jawn %s"/,
	'the tray tooltip drops the BLE line on Windows');

# --- functional probe -------------------------------------------------------

my $python = qx{python3 --version 2>/dev/null};

SKIP: {
	skip 'python3 is not installed', 19 unless $python;

	my $sandbox = tempdir(CLEANUP => 1);
	make_path(
		"$sandbox/app",
		"$sandbox/runtime/perl/bin",
		"$sandbox/runtime/c/bin",
		"$sandbox/home/.president",
		"$sandbox/bridge",
		"$sandbox/conf",
	);
	write_file("$sandbox/app/jawn", '');
	write_file("$sandbox/runtime/perl/bin/perl.exe", '');
	write_file("$sandbox/home/.president/pid", "1234\n");
	my $browse = "$sandbox/bridge/jawnos-browse";
	write_file($browse, '');

	my $py = "$sandbox/probe.py";
	write_file($py, <<'PY');
import os
import sys

root, sandbox = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "desktop"))
from jawnos_desktop import core_paths, core_process, core_shell, core_secrets, gpu, bridge

print("boot:" + core_paths._windows_boot_id(now=1000.0, tick_ms=100000))
print("boot-again:" + core_paths._windows_boot_id(now=1001.0, tick_ms=101000))
print("reboot:" + core_paths._windows_boot_id(now=1005.0, tick_ms=5000))

core_paths.IS_WINDOWS = True
os.environ["APPDATA"] = os.path.join(sandbox, "roaming")
os.environ["LOCALAPPDATA"] = os.path.join(sandbox, "local")
print("config:" + core_paths.config_dir())
print("state:" + core_paths.state_dir())
print("data:" + core_paths.data_dir())
print("jawn:" + core_paths.default_jawn_dir())

app = os.path.join(sandbox, "app")
core_process.IS_WINDOWS = True
print("perl:" + core_process._perl(app))
env = core_process._perl_env(app)
parts = env["PATH"].split(os.pathsep)
print("path0:" + parts[0])
print("path1:" + parts[1])
print("portable:" + env.get("JAWNOS_PORTABLE", ""))
print("jawn-dir:" + env.get("JAWNOS_DIR", ""))

core_process.home = lambda: os.path.join(sandbox, "home")
core_process.pid_alive = lambda pid: True
core_process._windows_process_name = lambda pid: "perl.exe"
print("master:" + repr(core_process._windows_master_pids()))
core_process._windows_process_name = lambda pid: "explorer.exe"
print("recycled:" + repr(core_process._windows_master_pids()))

core_secrets.IS_WINDOWS = True
print("dpapi:" + str(core_secrets._dpapi_store(
    "https://example.invalid/box_office/x?s=y")))

gpu.IS_WINDOWS = True
environ = {}
gpu.prepare_env(environ=environ, config_dir=os.path.join(sandbox, "conf"))
print("gpu:" + repr(environ.get("QTWEBENGINE_CHROMIUM_FLAGS")))

core_shell.IS_WINDOWS = True
argv = core_shell.desktop_argv()
print("shell-len:" + str(len(argv)))
print("shell-script:" + argv[-1])

bridge.IS_WINDOWS = True
bridge.DESKTOP_DIR = os.path.join(sandbox, "bridge")
print("browse-script:" + bridge.browse_launcher()[-1])
PY

	open(my $fh, '-|', 'python3', $py, $root, $sandbox) or die "python3: $!\n";
	my $out = do { local $/; <$fh> };
	close $fh;

	like($out, qr/^boot:15$/m, 'the boot stamp is the boot epoch in minutes');
	like($out, qr/^boot-again:15$/m, 'two calls in one boot agree');
	like($out, qr/^reboot:16$/m, 'a reboot makes a different stamp');
	like($out, qr/^config:\Q$sandbox\E\/roaming\/JawnOS$/m,
		'config is under APPDATA\\JawnOS');
	like($out, qr/^state:\Q$sandbox\E\/local\/JawnOS\/state$/m,
		'state is under LOCALAPPDATA\\JawnOS\\state');
	like($out, qr/^data:\Q$sandbox\E\/local\/JawnOS$/m,
		'data is the install root under LOCALAPPDATA');
	like($out, qr/^jawn:\Q$root\E$/m, 'the package still finds its own tree');
	like($out, qr/^perl:\Q$sandbox\E\/runtime\/perl\/bin\/perl\.exe$/m,
		'the bundled perl is chosen from the tree');
	like($out, qr/^path0:\Q$sandbox\E\/runtime\/c\/bin$/m, 'c\\bin comes first');
	like($out, qr/^path1:\Q$sandbox\E\/runtime\/perl\/bin$/m, 'then perl\\bin');
	like($out, qr/^portable:1$/m, 'the portable flag is set');
	like($out, qr/^jawn-dir:\Q$sandbox\E\/app$/m, 'JAWNOS_DIR names the tree');
	like($out, qr/^master:\[1234\]$/m, 'the pid record is the master');
	like($out, qr/^recycled:\[\]$/m, 'a recycled non-perl pid is ignored');
	like($out, qr/^dpapi:False$/m, 'DPAPI never crashes when it is not available');
	like($out, qr/^gpu:None$/m, 'no Linux GPU flags are set on Windows');
	like($out, qr/^shell-len:2$/m, 'the app is a two-part command');
	like($out, qr/^shell-script:.*jawnos-desktop$/m, 'ending in the app script');
	like($out, qr/^browse-script:.*jawnos-browse$/m, 'Browse gets the same interpreter');
}

done_testing();
