# tests-for: installer/windows/
# covers:    the Windows bundle, first-run installer and Inno wrapper keep the
#            promises the VM200 measurements depend on: both bundled PATH
#            directories, the non-interactive seed, the unlock-code file, the
#            single program-scoped firewall rule, the Startup shortcut, and the
#            per-user split (Inno owns files/shortcuts/uninstall).

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
my $firewall  = read_source('installer/windows/firewall.ps1');
my $bat       = read_source('installer/windows/Install.bat');
my $iss       = read_source('installer/windows/jawnos.iss');

# PowerShell 5.1 reads "$Variable: ..." inside a double-quoted string as a
# drive-qualified variable and fails to parse the file. env: and the other
# scopes are the legitimate exceptions; a drive letter (C:) has no leading $.
my $scope = qr/(?:env|global|script|local|private|variable|function|alias|using)\b/;
for my $script (['install.ps1', $install], ['build-portable.ps1', $build], ['uninstall.ps1', $uninstall], ['firewall.ps1', $firewall]) {
	unlike($script->[1], qr/\$(?!$scope)[A-Za-z_][A-Za-z0-9_]*:/,
		"$script->[0] has no unbraced \$Variable: interpolation");
}

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

# The Setup.exe is a per-user install and Inno owns the shortcuts, the rule and
# the uninstall. These switches are what keep one owner for each.
like($install, qr/SkipShortcuts/, 'install.ps1 can leave the shortcuts to the Setup.exe');
like($install, qr/SkipFirewall/, 'install.ps1 can leave the firewall rule to the Setup.exe');
like($install, qr/firewall\.ps1/, 'install.ps1 delegates the rule to firewall.ps1');

like($install, qr/Startup/, 'install.ps1 creates the Startup shortcut');

like($install, qr/System\.Net\.Sockets\.TcpClient/, 'readiness uses a TCP client');
like($install, qr/ConnectAsync/, 'readiness polls a TCP connect');
like($install, qr/listening on 127\.0\.0\.1/, 'a successful probe says listening on the port');
unlike($install, qr/Invoke-WebRequest/, 'readiness does not depend on the HTTP/TLS stack');
like($install, qr/Resolve-ShortcutDirectory/, 'shortcut folders resolve through fallbacks');
like($install, qr/Join-Path \$env:APPDATA 'Microsoft\\Windows\\Start Menu\\Programs'/,
	'the Start menu falls back to APPDATA');
like($install, qr/Join-Path \$env:ProgramData 'Microsoft\\Windows\\Start Menu\\Programs'/,
	'and then to ProgramData');
like($install, qr/New-Item -ItemType Directory -Force -Path \$candidate/,
	'the resolved shortcut folder is created');
like($install, qr/"%~dp0runtime\\perl\\bin\\perl\.exe" jawn/,
	'launch.bat names the bundled perl by its full path');

unlike($install, qr{C:\\Strawberry}i, 'install.ps1 does not hardcode C:\Strawberry');

# --- build-portable.ps1 -----------------------------------------------------

like($build, qr/git/, 'build-portable.ps1 calls git');
like($build, qr/\barchive\b/, 'build-portable.ps1 takes app\ from git archive');
like($build, qr/firewall\.ps1/, 'build-portable.ps1 stages firewall.ps1');
like($build, qr/RuntimeDir/, 'build-portable.ps1 names its prepared runtime');
like($build, qr/Mandatory\s*=\s*\$true/, 'build-portable.ps1 requires -RuntimeDir');
like($build, qr/README\.txt/, 'build-portable.ps1 stages README.txt');
like($build, qr/\$\{Destination\}/, 'the robocopy error braces Destination safely');
like($build, qr/Join-Path \$TreeDir 'desktop\\mkosi'/,
	'plain copy excludes the mkosi image tree');
like($build, qr/robocopy failed \(exit \$code\)/, 'a robocopy failure is a build error');
like($build, qr/copying \$Source to \$\{Destination\}/,
	'a robocopy failure names the copy');

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

# --- firewall.ps1 -----------------------------------------------------------
# One implementation of the rule, shared by the script installer, the uninstall
# and the Setup.exe. A port rule or a second name would drift between them.

like($firewall, qr/\$ruleName\s*=\s*'JawnOS'/, 'firewall.ps1 names the JawnOS rule');
like($firewall, qr/name=\$ruleName/, 'both netsh calls use the one rule name');
like($firewall, qr/program=/, 'the rule is program-scoped, not port-scoped');
like($firewall, qr/perl\.exe/, 'the rule names the bundled perl.exe');
like($firewall, qr/advfirewall/, 'firewall.ps1 talks to the firewall');
like($firewall, qr/\bdelete\b/, 'a reinstall replaces the rule instead of adding a second');
like($firewall, qr/profile=private/, 'the rule is private-profile only');
like($firewall, qr/\bRunAs\b/, 'firewall.ps1 can elevate itself for a per-user install');
unlike($firewall, qr/C:\\Strawberry/i, 'firewall.ps1 does not hardcode C:\Strawberry');

# --- uninstall.ps1 ----------------------------------------------------------

like($uninstall, qr/firewall\.ps1/, 'uninstall.ps1 delegates the rule to firewall.ps1');
like($uninstall, qr/-Remove/, 'uninstall.ps1 asks firewall.ps1 to remove the rule');
like($uninstall, qr/KeepFolder/, 'uninstall.ps1 can leave the folder to the Setup.exe');
like($uninstall, qr/SkipShortcuts/, 'uninstall.ps1 can leave the shortcuts to the Setup.exe');
like($uninstall, qr/SkipFirewall/, 'uninstall.ps1 can leave the rule to the Setup.exe');
like($uninstall, qr/Startup/, 'uninstall.ps1 removes the Startup shortcut');
like($uninstall, qr/Join-Path \$env:APPDATA 'Microsoft\\Windows\\Start Menu\\Programs'/,
	'uninstall.ps1 falls back to APPDATA for the Start menu');
like($uninstall, qr/Join-Path \$env:ProgramData 'Microsoft\\Windows\\Start Menu\\Programs'/,
	'uninstall.ps1 falls back to ProgramData');
like($uninstall, qr/Join-Path \$env:USERPROFILE 'Desktop'/,
	'uninstall.ps1 falls back to the user profile Desktop');
like($uninstall, qr/Join-Path \$env:APPDATA 'Microsoft\\Windows\\Start Menu\\Programs\\Startup'/,
	'uninstall.ps1 falls back to the APPDATA Startup folder');
like($uninstall, qr/'Programs', 'Desktop', 'Startup'/,
	'uninstall.ps1 removes all three shortcut kinds');
like($uninstall, qr/Removed shortcut \$link/,
	'uninstall.ps1 prints each removed shortcut');
unlike($uninstall, qr{C:\\Strawberry}i, 'uninstall.ps1 does not hardcode C:\Strawberry');

# --- Install.bat ------------------------------------------------------------

like($bat, qr/install\.ps1/, 'Install.bat runs install.ps1');
like($bat, qr/Bypass/, 'Install.bat bypasses the execution policy');
like($bat, qr/pause/i, 'Install.bat pauses for a double-click');

# --- jawnos.iss -------------------------------------------------------------

like($iss, qr/\{app\}/, 'jawnos.iss installs into {app}');
like($iss, qr/DefaultDirName=\{localappdata\}/, 'the install is per user under LOCALAPPDATA');
like($iss, qr/PrivilegesRequired\s*=\s*lowest/i, 'Setup does not require administrator rights');
like($iss, qr/install\.ps1/, 'jawnos.iss runs install.ps1');
like($iss, qr/-SkipShortcuts/, 'install.ps1 does not also create the Inno shortcuts');
like($iss, qr/firewall\.ps1/, 'jawnos.iss runs the shared firewall script');
like($iss, qr/\[Tasks\]/, 'jawnos.iss offers autostart and desktop tasks');
like($iss, qr/\[Icons\]/, 'Inno owns the shortcuts');
like($iss, qr/\[UninstallRun\]/, 'jawnos.iss runs the uninstaller');
like($iss, qr/-KeepFolder/, 'the Inno uninstaller owns the folder');
like($iss, qr/WizardIsTaskSelected\('lanaccess'\)/, 'the firewall entry follows the LAN task');
like($iss, qr/PrepareToInstall/, 'an upgrade stops the running house before replacing files');

done_testing();
