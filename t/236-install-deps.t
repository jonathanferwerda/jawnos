# tests-for: desktop/install.sh scripts/jawnos_deps.pl
# covers:    a desktop install is not "Done." unless the window can start. A
#           clean Debian box has no fc-list (fontconfig arrives with PySide6),
#           so the emoji probe reads the font directories too; the final verdict
#           asks the dependency checker and exits nonzero with the exact
#           --install command. The checker's desktop set names PyGObject, dbus
#           and BlueZ for the BLE bridge, and --install refuses to run apt as
#           the invoking user when sudo is absent.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
sub slurp { my $t = read_file("$root/$_[0]"); return defined $t ? $t : '' }

my $install = slurp('desktop/install.sh');
my $deps = slurp('scripts/jawnos_deps.pl');

# --- the emoji guard does not need fc-list ----------------------------------
# `command -v fc-list && ...` skipped the check on exactly the clean machine
# this guard exists for, because fontconfig is pulled in by PySide6.
unlike($install, qr/command -v fc-list >\/dev\/null 2>&1 && ! fc-list/,
	'the emoji check is not skipped when fontconfig is absent');
like($install, qr{\.local/share/fonts/\*Emoji\*},
	'it looks in the user font directory');
like($install, qr{/usr/share/fonts/\*/\*Emoji\*},
	'and in the system font directories');

# --- a missing window marks the install incomplete ---------------------------
my ($qt) = $install =~ /(if ! "\$PYTHON" -c 'import PySide6\.QtWebEngineWidgets'.*?\nfi\n)/s;
ok(length $qt, 'the installer still probes the Qt WebEngine import');
like($qt, qr/DESKTOP_INCOMPLETE=1/, 'a missing view marks the desktop incomplete');

my $incomplete = () = $install =~ /DESKTOP_INCOMPLETE=1/g;
cmp_ok($incomplete, '>=', 2, 'both the view and the emoji font can mark it incomplete');

# --- the final verdict asks the checker and refuses success -----------------
my ($verdict) = $install =~ /(# --- final verdict.*)\z/s;
ok(length $verdict, 'the installer ends with a final verdict');
like($verdict, qr/jawnos_deps\.pl"?\s+--desktop\s+--report/,
	'it runs the dependency checker for the desktop set');
like($verdict, qr/--desktop\s+--install/, 'it prints the exact install command');
like($verdict, qr/exit 1/, 'and exits nonzero instead of printing Done.');

# --- the desktop dependency set names the BLE bridge ------------------------
my ($desktop) = $deps =~ /(my \@desktop = \(.*?\n\);)/s;
ok(length $desktop, 'the checker keeps its desktop extras in one list');

for my $pair ( [ 'python3-gi', 'python-gobject' ],
               [ 'python3-dbus', 'python-dbus' ],
               [ 'bluez', 'bluez' ] ) {
	my ($deb, $arch) = @$pair;
	like($desktop, qr/\bapt\s*=>\s*'\Q$deb\E'/, "the Debian desktop set carries $deb");
	like($desktop, qr/\bpacman\s*=>\s*'\Q$arch\E'/, "the Arch desktop set carries $arch");
}

like($deps, qr/^sub have_python_module \{/m, 'the PyGObject/dbus probes share one Python-import helper');
like($deps, qr/system\("[^"]*-c 'import \$module'/,
	'and the helper imports the module it is asked about');
like($deps, qr/^sub have_bluetoothctl \{/m, 'bluetoothctl has its own probe');

# --- --install refuses to run apt without root ------------------------------
like($deps, qr/^sub need_root_without_sudo \{/m, 'one rule decides when root is missing');
like($deps, qr/return 0 if -x '\/usr\/bin\/sudo';/, 'it accepts an installed sudo');
like($deps, qr/return 0 if \$> == 0;/, 'root needs no sudo');
like($deps, qr/return 1;/, 'and otherwise refuses');

my ($guard) = $deps =~ /(if \(need_root_without_sudo\(\)\) \{.*?exit 1;\s*\n\s*\})/s;
ok(length $guard, 'the install path consults the rule before running a package manager');
like($guard, qr/system_package_commands\(\@pkgs\)/, 'it prints the commands root must run');
like($guard, qr/--install/, 'and tells the person how to resume');
like($guard, qr/exit 1/, 'and exits nonzero');

# The no-sudo path must not reach apt-get as this user: the package manager
# calls stay inside the branch that follows the guard.
my ($block) = $deps =~ /(# Core tools and any opted-in desktop extras.*?\n\})/s;
ok(length $block, 'the package-manager block is in one place');
my ($before_guard, $after_guard) = split /if \(need_root_without_sudo\(\)\) \{/, $block, 2;
ok(defined $after_guard, 'the guard comes first');
unlike($before_guard, qr/apt-get|pacman/, 'nothing runs a package manager before it');

# --- syntax ------------------------------------------------------------------
is(`sh -n "$root/desktop/install.sh" 2>&1`, '', 'install.sh is valid POSIX shell');
like(`$^X -c "$root/scripts/jawnos_deps.pl" 2>&1`, qr/syntax OK/,
	'the dependency checker compiles');

done_testing();
