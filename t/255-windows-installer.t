# tests-for: installer/windows/
# covers:    the Windows bundle and first-run installer keep the promises the
#            VM200 measurements depend on: both bundled PATH directories, the
#            non-interactive seed, the unlock-code file, the program-scoped
#            firewall rule, the Startup shortcut, and no fixed Strawberry path.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;

# These are source invariants because the scripts can only be executed on
# Windows. A regression that drops c\bin from PATH, or swaps the program rule
# for a port rule, is visible here without a VM.

my $root = "$FindBin::Bin/..";

sub read_source {
	my ($rel) = @_;
	open(my $fh, '<', "$root/$rel") or die "read $rel: $!\n";
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}

my $install   = read_source('installer/windows/install.ps1');
my $build     = read_source('installer/windows/build-portable.ps1');
my $uninstall = read_source('installer/windows/uninstall.ps1');
my $bat       = read_source('installer/windows/Install.bat');
my $iss       = read_source('installer/windows/jawnos.iss');

# --- install.ps1 ------------------------------------------------------------

like($install, qr/runtime\\c\\bin/, 'install.ps1 puts runtime\c\bin on PATH');
like($install, qr/runtime\\perl\\bin/, 'install.ps1 puts runtime\perl\bin on PATH');
like($install, qr/JAWNOS_PORTABLE/, 'install.ps1 sets JAWNOS_PORTABLE for every child');
like($install, qr/JAWNOS_TRANSPORT/, 'install.ps1 sets JAWNOS_TRANSPORT for every child');
like($install, qr/JAWNOS_DIR/, 'install.ps1 sets JAWNOS_DIR for every child');

like($install, qr/jawnos_setup\.pl/, 'install.ps1 runs the seeded setup');
like($install, qr/--seed/, 'install.ps1 seeds without the wizard');
like($install, qr/--code/, 'install.ps1 passes an unlock code to the seed');
like($install, qr/Get-Random\s+-Minimum\s+100000\s+-Maximum\s+999999/,
	'the generated unlock code is six digits');
like($install, qr/unlock-code\.txt/, 'install.ps1 writes unlock-code.txt');

like($install, qr/program=/, 'the firewall rule is program-scoped, not port-scoped');
like($install, qr/perl\.exe/, 'the firewall rule names the bundled perl.exe');
like($install, qr/Startup/, 'install.ps1 creates the Startup shortcut');

unlike($install, qr{C:\\Strawberry}i, 'install.ps1 does not hardcode C:\Strawberry');

# --- build-portable.ps1 -----------------------------------------------------

like($build, qr/git/, 'build-portable.ps1 calls git');
like($build, qr/\barchive\b/, 'build-portable.ps1 takes app\ from git archive');
like($build, qr/RuntimeDir/, 'build-portable.ps1 names its prepared runtime');
like($build, qr/Mandatory\s*=\s*\$true/, 'build-portable.ps1 requires -RuntimeDir');
like($build, qr/README\.txt/, 'build-portable.ps1 stages README.txt');
unlike($build, qr{C:\\Strawberry}i, 'build-portable.ps1 does not hardcode C:\Strawberry');

# VM200 has no git, so a staged tree must still build. The script probes for a
# work tree and otherwise copies it with the same local state excluded.
like($build, qr/rev-parse/, 'build-portable.ps1 probes for a git work tree');
like($build, qr/is-inside-work-tree/, 'the probe asks rev-parse for the work tree');
like($build, qr/plain copy/, 'build-portable.ps1 names the non-git fallback');
like($build, qr/App payload:/, 'build-portable.ps1 reports the app file count');
like($build, qr{/XD}, 'the fallback sends directory exclusions through /XD');
like($build, qr{/XF}, 'the fallback sends file exclusions through /XF');

like($build, qr/Join-Path \$TreeDir '\.git'/, 'plain copy excludes .git');
like($build, qr/Join-Path \$TreeDir '\.worktrees'/, 'plain copy excludes .worktrees');
like($build, qr/Join-Path \$TreeDir 'releases'/, 'plain copy excludes releases');
like($build, qr/Join-Path \$TreeDir '\.shots'/, 'plain copy excludes .shots');
like($build, qr/Join-Path \$TreeDir 'database\\jawnos\.db'/,
	'plain copy excludes the live database');
	like($build, qr/'jawnos\.db-\*'/, 'database sidecars excluded by bare name');
like($build, qr/Join-Path \$TreeDir 'server\\fullchain\.pem'/,
	'plain copy excludes the TLS material');

# --- uninstall.ps1 ----------------------------------------------------------

like($uninstall, qr/advfirewall/, 'uninstall.ps1 talks to the firewall');
like($uninstall, qr/delete/, 'uninstall.ps1 deletes the named rule');
like($uninstall, qr/name=JawnOS/, 'uninstall.ps1 names the JawnOS rule');
like($uninstall, qr/Startup/, 'uninstall.ps1 removes the Startup shortcut');
unlike($uninstall, qr{C:\\Strawberry}i, 'uninstall.ps1 does not hardcode C:\Strawberry');

# --- Install.bat ------------------------------------------------------------

like($bat, qr/install\.ps1/, 'Install.bat runs install.ps1');
like($bat, qr/Bypass/, 'Install.bat bypasses the execution policy');
like($bat, qr/pause/i, 'Install.bat pauses for a double-click');

# --- jawnos.iss -------------------------------------------------------------

like($iss, qr/\{app\}/, 'jawnos.iss installs into {app}');
like($iss, qr/install\.ps1/, 'jawnos.iss runs install.ps1');
like($iss, qr/PrivilegesRequired\s*=\s*admin/i, 'jawnos.iss asks for admin for the firewall');
like($iss, qr/\[Tasks\]/, 'jawnos.iss offers autostart and desktop tasks');
like($iss, qr/\[UninstallRun\]/, 'jawnos.iss runs the uninstaller');

done_testing();
