# tests-for: installer/windows/ jawn
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
my $jawn      = read_source('jawn');

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

# Strawberry is not a distro Perl: the seed's own requires and the manager's
# eager preamble are absent unless cpanm installed them. The probe is the last
# gate before the seed, and a gap used to surface only after "JawnOS is
# installed" (v0.1.2747 shipped without Crypt::Simple and could not seed).
for my $module (qw(Mojolicious Mojo::SQLite Minion DBD::SQLite Sereal::Encoder
		Sereal::Decoder Net::SSLeay CryptX File::Slurp Win32::API Win32API::File
		Crypt::Simple Time::Duration Date::Parse Clone URI::Encode File::Type
		HTML::Strip HTML::Parser Number::Format SQL::Abstract Data::UUID)) {
	like($install, qr/'-M\Q$module\E'/, "the runtime probe loads $module");
}

# config.json without the database is not an install: a run that died between
# the two used to skip the seed and print "JawnOS is installed" over an empty
# house. The database existing is what keeps its own unlock code valid.
like($install, qr/\$dbPath\s*=\s*Join-Path \$appDir 'database\\jawnos\.db'/,
	'install.ps1 names the database it must find');
like($install, qr/\$needDb\s*=\s*-not\s*\(Test-Path[^\n]*\$dbPath\)/,
	'install.ps1 notices a missing database, not just a missing config.json');
like($install, qr/if\s*\(\$needConfig\s*-or\s*\$needDb\)/,
	'a missing database still forces the seed');
like($install, qr/elseif\s*\(Test-Path -LiteralPath \$codePath\)/,
	'a kept database keeps its own unlock code instead of drawing a new one');

# The Setup.exe is a per-user install and Inno owns the shortcuts, the rule and
# the uninstall. These switches are what keep one owner for each.
like($install, qr/SkipShortcuts/, 'install.ps1 can leave the shortcuts to the Setup.exe');
like($install, qr/SkipFirewall/, 'install.ps1 can leave the firewall rule to the Setup.exe');
like($install, qr/firewall\.ps1/, 'install.ps1 delegates the rule to firewall.ps1');

# The Setup.exe asks for the house settings and hands them over in a small
# key=value file; a silent install keeps the seed's own defaults.
like($install, qr/AnswersFile/, 'install.ps1 reads the Setup.exe answers file');
like($install, qr/--email/, 'install.ps1 passes the chosen email to the seed');
like($install, qr/--domain/, 'install.ps1 passes the chosen domain to the seed');
like($install, qr/--language/, 'install.ps1 passes the chosen language to the seed');

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

# The Start menu and desktop icons open the interface; the Startup entry only
# starts the service. The icon used to run launch.bat alone, so a second click
# while the house was already serving did nothing and no browser ever opened.
# The interface is the bundled Qt shell when it is present; the browser is the
# fallback for a payload built without it.
like($install, qr/launch\.ps1/, 'install.ps1 generates the interface launcher');
like($install, qr/start\.vbs/, 'install.ps1 generates a service-only launcher');
like($install, qr/\$startArgs\s*=/, 'the Startup shortcut has its own arguments');
like($install, qr/New-JawnShortcut -LinkPath \$startupShortcut[^\n]*\$startArgs/,
	'the Startup shortcut starts the service only');
like($install, qr/Start-Process -FilePath \$wscript -ArgumentList \$startArgs/,
	'the installer starts the service while it waits, not the interface');
like($install, qr/Start-Process "https:\/\/127\.0\.0\.1:\$port\/manager"/,
	'the browser fallback opens the manager');
like($install, qr/Test-JawnPort/, 'the interface launcher checks the port first');

# The desktop shell is the interface when the payload carries it. It needs the
# Python runtime and both Qt WebEngine bindings; install.ps1 mints the ticket
# the shell signs in with, and an upgrade stops the running shell before the
# files it has open are replaced.
like($install, qr/'scripts\\app_ticket\.pl', 'desktop', '--save'/,
	'install.ps1 mints the desktop ticket');
like($install, qr/runtime\\python\\pythonw\.exe/, 'the shell uses the bundled pythonw');
like($install, qr/QtWebEngineCore\.pyd/, 'the shell needs Qt WebEngine');
like($install, qr/QtWebEngineWidgets\.pyd/, 'including the widgets binding');
like($install, qr/\$useWebView =/, 'the launcher decides once whether it has the WebView2 shell');
like($install, qr/if \(\$useWebView\)/, 'the interactive run starts the shell');
like($install, qr/if \(\$up -and -not \$NoBrowser -and -not \$useWebView -and -not \$useQt\)/,
	'and does not also open a browser');
like($install, qr/'--tray'/, 'the shell keeps its tray icon');
like($install, qr/Get-CimInstance Win32_Process/,
	'an upgrade stops a running shell before copying files');

# The shortcuts carry the house mark, the same logo the Linux .desktop and the
# Android launcher use, not the generic wscript script icon.
like($install, qr/IconLocation/, 'the shortcuts set their icon');
like($install, qr/jawnos\.ico/, 'install.ps1 names the icon file');

# The probe once froze the Setup: Inno's 32-bit PowerShell captured the 64-bit
# perl through `2>&1 | Out-String` and never saw the pipeline close. It then
# used Start-Process -PassThru without -Wait, whose ExitCode is empty on Windows
# PowerShell 5.1: the probe printed "ok" and the installer still refused the
# runtime. The capture owns a Process and drains both streams concurrently.
like($install, qr/System\.Diagnostics\.ProcessStartInfo/, 'the capture owns a real Process object');
like($install, qr/ReadToEndAsync/, 'both native streams are drained concurrently, not through a pipe');
like($install, qr/\$proc\.ExitCode/, 'the capture reads the real exit code');
like($install, qr/\$startInfo\.WorkingDirectory\s*=\s*\$PWD\.ProviderPath/,
	'the capture runs in the caller\'s directory, so the seed\'s relative path resolves');
like($install, qr/WaitForExit\(\$TimeoutSeconds \* 1000\)/, 'the capture wait is bounded');
unlike($install, qr/Start-Process -FilePath \$FilePath -ArgumentList \$argLine -PassThru/,
	'the capture does not use Start-Process -PassThru, whose ExitCode can be empty');
unlike($install, qr/& \$FilePath \@Arguments 2>&1/, 'the probe does not capture through a pipeline');
like($install, qr/ConvertTo-QuotedArgument/, 'an argument with spaces stays one argument');

unlike($install, qr{C:\\Strawberry}i, 'install.ps1 does not hardcode C:\Strawberry');

# --- build-portable.ps1 -----------------------------------------------------

like($build, qr/\[string\]\$PythonDir/, 'build-portable.ps1 takes a Python runtime');
like($build, qr/PythonDir is not a Python \+ PySide6 tree/,
	'and validates pythonw plus both Qt WebEngine bindings');
like($build, qr/Join-Path \$stage 'runtime\\python'/,
	'copying it to runtime\python');
like($build, qr/No -PythonDir/, 'a build without it still works, with a warning');
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
like($iss, qr/ArchitecturesInstallIn64BitMode=x64/,
	'Setup runs in 64-bit mode, so {sys} is the native PowerShell');

# config.json is written by the installer, not by a web wizard, and the
# uninstaller has to remove the files Inno did not install.
like($iss, qr/DisableDirPage\s*=\s*yes/, 'Setup does not offer a Program Files install');
like($iss, qr/CreateInputQueryPage/, 'Setup asks for the house settings');
like($iss, qr/SaveStringToFile/, 'Setup writes the answers file');
like($iss, qr/-AnswersFile/, 'install.ps1 receives the answers file');
like($iss, qr/\[UninstallDelete\]/, 'the uninstaller removes generated files');
like($iss, qr/\{app\}\\app/, 'the app tree is removed on uninstall');
like($iss, qr/\{group\}\\JawnOS[^\n]*launch\.vbs/,
	'the Start menu icon opens the interface');
like($iss, qr/\{userstartup\}\\JawnOS[^\n]*start\.vbs/,
	'the Startup shortcut starts the service only');
like($iss, qr/\{app\}\\launch\.ps1/, 'the uninstaller removes the interface launcher');
like($iss, qr/\{app\}\\start\.vbs/, 'the uninstaller removes the service launcher');
like($iss, qr/IconFilename:\s*"\{app\}\\jawnos\.ico"/, 'the Inno shortcuts use the JawnOS icon');
like($iss, qr/UninstallDisplayIcon=\{app\}\\jawnos\.ico/, 'Apps & features shows the JawnOS icon');
like($iss, qr/PrepareToInstall/, 'an upgrade stops the running house before replacing files');
like($uninstall, qr/Get-CimInstance Win32_Process/,
	'the uninstaller looks for a running desktop shell');
like($uninstall, qr/Name='pythonw\.exe' OR Name='python\.exe'/,
	'including a python.exe debug run');
like($uninstall, qr/jawnos-desktop/, 'identified by its own command line');

# The icon is a real multi-size Windows ICO, shipped with the installer and the
# bundle. A missing or empty file would leave every shortcut with the wscript
# script icon again.
my $icon_path = "$root/installer/windows/jawnos.ico";
ok(-s $icon_path, 'the launcher icon is in the tree');
if (-s $icon_path) {
	open(my $icon_fh, '<:raw', $icon_path) or die "read jawnos.ico: $!\n";
	read($icon_fh, my $icon_head, 4);
	close $icon_fh;
	is($icon_head, "\x00\x00\x01\x00", 'the icon file is a Windows ICO');
}
like($build, qr/jawnos\.ico/, 'build-portable.ps1 stages the icon');

# The master creates manager.log without a shell. `touch` is Unix-only; on
# Windows it wrote "not recognized" into the log file it was creating.
unlike($jawn, qr/`\s*touch\s+\$logfile\s*`/, 'jawn does not run the Unix touch command');
like($jawn, qr/open\(my \$log_fh,\s*'>>',\s*\$logfile\)/, 'jawn creates manager.log portably');

done_testing();
