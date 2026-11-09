# tests-for: scripts/jawnos_deps.pl scripts/jawnos_update.pl lib/JawnOS/Domain/Run.pm lib/JawnOS/Domain/Git.pm lib/JawnOS/Domain/Records2.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_configure2.pm lib/JawnOS/Routes/manager_configure2.pm public/js/manager/configure/01_update_controls.js templates/configure/device_lister/body.html.ep perl/help/topics_configure.pl
# covers:    A code update checks the system packages the new tree names. When
#            sudo needs no password they are installed silently; otherwise the
#            update leaves a request that the manager answers with the root
#            password, at the machine that owns the packages.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
sub slurp_rel { my $t = read_file("$root/$_[0]"); return defined $t ? $t : '' }

my $deps = slurp_rel('scripts/jawnos_deps.pl');
my $boot = slurp_rel('scripts/jawnos_update.pl');
my $run  = slurp_rel('lib/JawnOS/Domain/Run.pm');
my $git  = slurp_rel('lib/JawnOS/Domain/Git.pm');
my $rec  = slurp_rel('lib/JawnOS/Domain/Records2.pm');
my $load = slurp_rel('lib/JawnOS/Domain/Loader.pm');
my $ctl  = slurp_rel('lib/JawnOS/Controller/manager_configure2.pm');
my $routes = slurp_rel('lib/JawnOS/Routes/manager_configure2.pm');
my $js   = slurp_rel('public/js/manager/configure/01_update_controls.js');
my $tpl  = slurp_rel('templates/configure/device_lister/body.html.ep');
my $help = slurp_rel('perl/help/topics_configure.pl');

# --- the checker grows one non-interactive mode ------------------------------
like($deps, qr/'after-update'\s*=>\s*\\\$after_update/, 'the checker knows --after-update');
like($deps, qr/sub after_update_run/, 'and the mode has one implementation');
like($deps, qr/deps-pending\.json/, 'a request is left where the manager can find it');
like($deps, qr/JAWNOS_DEPS_RESULT=/, 'the answer is machine-readable');
like($deps, qr/sudo -n true/, 'it tests sudo without a password');
like($deps, qr/LOCK_EX \| LOCK_NB/, 'two update paths cannot run two package managers at once');

# Arch does not support partial upgrades. The automatic path must not run -Sy
# behind the person's back; a stale sync database is theirs to refresh.
my ($spc) = $deps =~ /(sub system_package_commands \{.*?\n\})/s;
ok(length $spc, 'the package commands are in one place');
like($spc, qr/pacman', '-S', '--needed', '--noconfirm'/, 'Arch installs from the sync database it has');
(my $spc_code = $spc) =~ s/^\s*#.*$//mg;
unlike($spc_code, qr/'-Sy'/, 'the automatic path never refreshes half the system');

# --after-update installs neither Perl modules nor optional apps: the update
# hook already owns those, and both are user-side.
like($deps, qr/if \(\$after_update\) \{\s*\$desktop = 1;\s*\$no_extras = 1;/s,
	'after-update asks for the desktop extras and leaves the optional apps alone');

# --- every update path calls it ----------------------------------------------
like($git, qr/install_system_dependencies\('\.'\)/, 'the git watcher checks after a GitHub or peer pull');
like($rec, qr/install_system_dependencies\(\$repo\)/, 'Update now checks whichever source moved the tree');
like($rec, qr/\(defined \$dependencies \? \(dependencies => \$dependencies\) : \(\)\)/,
	'and the result rides back to the caller');
like($boot, qr/'--after-update'/, 'the boot updater checks after a GitHub pull');

# --- the domain helpers exist and are reachable ------------------------------
like($run, qr/^sub install_system_dependencies \{/m, 'Run.pm runs the check');
like($run, qr/^sub deps_pending_read \{/m, 'Run.pm reads the request');
like($load, qr/install_system_dependencies deps_pending_read/, 'both are in the domain loader');

# --- the manager asks, and only on the machine that owns the packages --------
like($routes, qr{\[50009, 'get', '/manager/configure/deps_pending', 'action_50009'\]}, 'the request has a route');
like($routes, qr{\[50010, 'post', '/manager/configure/deps_install', 'action_50010'\]}, 'and the answer does too');
like($ctl, qr/^sub action_50009 \{/m, 'the read action exists');
like($ctl, qr/^sub action_50010 \{/m, 'the install action exists');
like($ctl, qr/^sub deps_request_is_local \{/m, 'there is one local-only rule');
like($ctl, qr/sudo', '-S', '-p', '', '-v'/, 'the password is spent on sudo -v');
like($ctl, qr/print \$fh \$password, "\\n";/, 'and only written to sudo\'s stdin');
like($ctl, qr/^\t\$password = '';/m, 'the password is cleared after use');
unlike($ctl, qr/(?:logfile|rightNow\(\)|log->\w+\(|render\(json)[^\n]*\$password/,
	'the password never reaches a log line or a response');

like($js, qr{/manager/configure/deps_install}, 'the manager posts the answer');
like($js, qr/id="deps_root_password"/, 'it asks for the password');
like($js, qr/field\.val\(''\)/, 'the field is cleared before the request');
like($js, qr/deps_pending_button/, 'the Dev panel keeps an entry point after a dismissal');
like($tpl, qr/id="deps_pending_button"/, 'the Dev panel carries that entry point');
like($help, qr/root password/, 'the help topic explains the prompt');

# --- the mode runs (user-scoped, so it touches no system packages) -----------
my $tmp = tempdir(CLEANUP => 1);
my $out = `cd "$root" && HOME="$tmp" $^X scripts/jawnos_deps.pl --after-update --local-lib "$tmp/perl5" 2>&1`;
like($out, qr/^JAWNOS_DEPS_RESULT=.*"skipped":"local-lib"/m,
	'--after-update answers with the one-line result');
ok(!-e "$tmp/.president/deps-pending.json",
	'and leaves no request when it installed nothing');

# --- syntax ------------------------------------------------------------------
my $perl = `$^X -c "$root/scripts/jawnos_deps.pl" 2>&1`;
like($perl, qr/syntax OK/, 'the dependency checker compiles');
for my $module (qw(Run Git Records2 Loader)) {
	my $check = `cd "$root" && $^X -Ilib -c lib/JawnOS/Domain/$module.pm 2>&1`;
	like($check, qr/syntax OK/, "$module.pm compiles");
}
my $controller = `cd "$root" && $^X -Ilib -c lib/JawnOS/Controller/manager_configure2.pm 2>&1`;
like($controller, qr/syntax OK/, 'the controller compiles');

my $node = `command -v node 2>/dev/null`;
chomp $node;
if ($node) {
	my $js_check = `$node --check "$root/public/js/manager/configure/01_update_controls.js" 2>&1`;
	is($js_check, '', 'the update controls parse');
}
else {
	pass('node is not installed; the JavaScript parse is covered by the browser');
}

done_testing();
