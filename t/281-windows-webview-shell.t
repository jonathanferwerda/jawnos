# tests-for: installer/windows/JawnOSShell.cs installer/windows/prepare-webview.ps1 installer/windows/install.ps1 installer/windows/build-portable.ps1 installer/windows/uninstall.ps1 .gitignore
# covers:    the WebView2 Windows shell and the lane that ships it. The VM200
#            session proved the shell renders and signs in; these are the
#            source invariants behind that session: the same ticket the Linux
#            shell uses, the per-origin certificate decision, the tray's
#            controls, the single-instance mutex with a show signal, and the
#            installer preferring webview\ over Qt and the browser when the
#            Evergreen runtime is present.

use strict;
use warnings;

use FindBin;
use Test::More;

my $root = "$FindBin::Bin/..";

sub read_source {
	my ($rel) = @_;
	open(my $fh, '<', "$root/$rel") or die "read $rel: $!\n";
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}

my $cs        = read_source('installer/windows/JawnOSShell.cs');
my $prepare   = read_source('installer/windows/prepare-webview.ps1');
my $install   = read_source('installer/windows/install.ps1');
my $build     = read_source('installer/windows/build-portable.ps1');
my $uninstall = read_source('installer/windows/uninstall.ps1');
my $ignore    = read_source('.gitignore');

# --- the shell: same sign-in as Linux ---------------------------------------

like($cs, qr/^\s*\[STAThread\]$/m, 'the shell is a single-threaded WinForms app');
like($cs, qr/using Microsoft\.Web\.WebView2\.WinForms;/,
	'the shell compiles against the WebView2 WinForms SDK');
like($cs, qr/new WebView2\(\)/, 'the window embeds a WebView2 control');
like($cs, qr/Path\.Combine\(appDir, "\.shots", "ticket\.txt"\)/,
	'it reads the ticket file install.ps1 mints');
like($cs, qr/"JawnOS", "webview2"/,
	'the profile lives under LOCALAPPDATA, so the cookie survives a restart');
like($cs, qr/web\.CoreWebView2\.Navigate\(ticket\)/,
	'it loads the ticket first, which mints the president cookie');
like($cs, qr/managerUrl = "https:\/\/" \+ host \+ ":" \+ port \+ "\/manager"/,
	'then the Manager on the ticket host');
like($cs, qr/StringComparison\.OrdinalIgnoreCase[\s\S]{0,200}domain/,
	'a ticket host is matched against the house domain');

# The house serves its own certificate. Accepting it by default would abort
# the load, so the decision is per origin: AlwaysAllow for a house host, the
# engine's Default otherwise.
like($cs, qr/CoreWebView2ServerCertificateErrorAction\.AlwaysAllow/,
	'a house certificate is allowed for this origin');
like($cs, qr/IsHouseHost\([^)]*Host\)/, 'the certificate decision asks who the host is');
like($cs, qr/CoreWebView2ServerCertificateErrorAction\.Default/,
	'any other certificate error stays an error');
like($cs, qr/CoreWebView2PermissionKind\.Microphone/, 'the microphone is offered to the house');
like($cs, qr/CoreWebView2PermissionKind\.Camera/, 'so is the camera');
like($cs, qr/CoreWebView2PermissionKind\.ClipboardRead/, 'and clipboard reads');

# --- the shell: window, tray and quit ---------------------------------------

like($cs, qr/AddScriptToExecuteOnDocumentCreatedAsync/, 'the page gets a document-created script');
like($cs, qr/html\{background:#000/, 'that script paints the page black before the app loads');
like($cs, qr/web\.DefaultBackgroundColor = Color\.Black/,
	'the control itself is black, not transparent');
like($cs, qr/Math\.Min\(1100, Math\.Max\(800, area\.Width - 80\)\)/,
	'the window never exceeds the screen it opens on');
like($cs, qr/Math\.Min\(820, Math\.Max\(600, area\.Height - 80\)\)/,
	'nor is it taller than the working area');

like($cs, qr/new NotifyIcon\(\)/, 'the tray icon is created');
like($cs, qr/iconGreen = MakeIcon/, 'a green dot means jawn is up');
like($cs, qr/iconRed = MakeIcon/, 'a red dot means jawn is down');
for my $item (
	'Show JawnOS', 'Reload view', 'Start jawn', 'Stop jawn',
	'Restart jawn', 'Log', 'Open in browser', 'Quit and stop jawn'
) {
	like($cs, qr/\Q$item\E/, "the tray offers $item");
}
like($cs, qr/Path\.Combine\(appDir, "scripts", "manager_killer\.pl"\)/,
	'stopping jawn uses the house script, not a blind kill');
like($cs, qr/Path\.Combine\(install, "start\.vbs"\)/, 'starting jawn uses start.vbs');
like($cs, qr/StartPosition = FormStartPosition\.CenterScreen/, 'the window opens centered');
like($cs, qr/override void OnFormClosing/, 'closing the window is handled');
like($cs, qr/Hide\(\);/, 'closing hides to the tray instead of quitting');
like($cs, qr/Application\.Run\(new ShellForm/, 'the form is the app lifetime');

# --- the shell: one instance, and a second launch shows the first -----------

like($cs, qr/new Mutex\(true, "JawnOS\.WebViewShell", out created\)/,
	'a second launch is refused by a named mutex');
like($cs, qr/if \(!created\)/, 'the second process takes the not-created branch');
like($cs, qr/EventWaitHandle\.OpenExisting\("JawnOS\.WebViewShell\.Show"\)/,
	'the second launch signals the first');
like($cs, qr/new EventWaitHandle\(false, EventResetMode\.AutoReset, "JawnOS\.WebViewShell\.Show"\)/,
	'the first owns the show event');
like($cs, qr/ThreadPool\.RegisterWaitForSingleObject\(showEvent/,
	'it waits on that event');
like($cs, qr/BeginInvoke\(new MethodInvoker\(ShowWindow\)\)/,
	'and shows the window on the UI thread');

# --- prepare-webview.ps1 ----------------------------------------------------

like($prepare, qr/\$Version = '1\.0\.3351\.48'/,
	'the SDK version is pinned, so a build is reproducible');
like($prepare, qr#https://www\.nuget\.org/api/v2/package/Microsoft\.Web\.WebView2/\$Version#,
	'the SDK comes from nuget');
like($prepare, qr/lib\\net462\\Microsoft\.Web\.WebView2\.Core\.dll/, 'it stages the Core DLL');
like($prepare, qr/lib\\net462\\Microsoft\.Web\.WebView2\.WinForms\.dll/, 'it stages the WinForms DLL');
like($prepare, qr/Where-Object \{ \$_.FullName -match 'x64\|win-x64' \}/,
	'it picks the 64-bit WebView2Loader.dll');
like($prepare, qr/Microsoft\.NET\\Framework64\\v4\.0\.30319\\csc\.exe/,
	'it compiles with the .NET Framework compiler');
like($prepare, qr#/target:winexe#, 'the shell is a GUI program, with no console window');
like($prepare, qr#/win32icon:#, 'the executable carries the JawnOS icon');
like($prepare, qr/Join-Path \$PSScriptRoot 'jawnos\.ico'/, 'from the tree icon');
unlike($prepare, qr/param\([^)]*\$PSScriptRoot/s,
	'-OutDir is resolved in the body: $PSScriptRoot is empty in a -File param default');
like($prepare, qr/if \(\[string\]::IsNullOrWhiteSpace\(\$OutDir\)\) \{\n\s*\$OutDir = Join-Path \$PSScriptRoot 'webview'/,
	'and it defaults to webview\ beside the script');

# --- install.ps1 ------------------------------------------------------------

like($install, qr/\$webviewShell = Join-Path \$InstallDir 'webview\\JawnOSShell\.exe'/,
	'install.ps1 knows the staged shell');
like($install, qr/\$webViewRuntime = \$false/, 'the runtime probe starts false');
like($install, qr/WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5\}/,
	'it looks for the Evergreen runtime in the machine registry');
like($install, qr/HKCU:\\Software\\Microsoft\\EdgeUpdate\\Clients/,
	'and in the user registry');
like($install, qr/Microsoft\\EdgeWebView\\Application/,
	'and in Program Files, where a per-user install lands');
like($install, qr/\$hasWebView = \(Test-Path -LiteralPath \$webviewShell\) -and \$webViewRuntime/,
	'the shell needs both the binary and the machine runtime');
like($install, qr/Invoke-Robocopy \(Join-Path \$SourceDir 'webview'\)/,
	'install.ps1 copies webview\ into the install');
like($install, qr/\$useWebView = \$hasWebView -and \(-not \$NoBrowser\)/,
	'first run prefers the WebView2 shell');
like($install, qr/\$useQt = \$hasShell -and \(-not \$useWebView\)/,
	'Qt is the second choice');
like($install, qr/Start-Process -FilePath \$webviewShell -ArgumentList \('--install "' \+ \$InstallDir \+ '"'\)/,
	'and it starts the shell with the install directory');

# launch.ps1 is generated by install.ps1; the same preference chain lives there.
like($install, qr/\$webview = Join-Path \$install 'webview\\JawnOSShell\.exe'/,
	'launch.ps1 finds the staged shell');
like($install, qr/if \(\(Test-Path -LiteralPath \$webview\) -and \$webviewRuntime\) \{/,
	'launch.ps1 takes it only when the runtime is there');
like($install, qr/Start-Process -FilePath \$webview -ArgumentList \('--install "' \+ \$install \+ '"'\)/,
	'and starts it with the install directory');
like($install, qr/\$pythonw = Join-Path \$install 'runtime\\python\\pythonw\.exe'/,
	'launch.ps1 still falls back to the Qt shell');
like($install, qr/Start-Process -FilePath \$pythonw -ArgumentList @\(\('"' \+ \$desktop \+ '"'\), '--tray'\)/,
	'with the tray flag');
like($install, qr/Start-Process -FilePath \$wscript -ArgumentList \$startArgs/,
	'and to the browser when neither shell is present');

# An upgrade stops the shell that is holding the old DLLs.
like($install, qr/Name='JawnOSShell\.exe'/, 'an upgrade looks for a running WebView2 shell');

# --- build-portable.ps1, uninstall.ps1, .gitignore --------------------------

like($build, qr/prepare-webview\.ps1/, 'the bundle builds the WebView2 shell');
like($build, qr/Invoke-Robocopy \$webview \(Join-Path \$stage 'webview'\)/,
	'and stages it as webview\\');
like($build, qr/installer\\windows\\webview/,
	'the plain copy skips the build output');
like($uninstall, qr/Name='JawnOSShell\.exe'/, 'the uninstaller stops the WebView2 shell');
like($uninstall, qr/jawnos-desktop/, 'and the Qt shell, by its command line');
like($ignore, qr/^installer\/windows\/webview\/$/m, 'the build output is gitignored');

# PowerShell 5.1 reads "$Variable: ..." as a drive-qualified variable and fails
# to parse the file. Both new scripts are parsed on the build machine.
my $scope = qr/(?:env|global|script|local|private|variable|function|alias|using)\b/;
for my $script (['prepare-webview.ps1', $prepare], ['install.ps1', $install]) {
	unlike($script->[1], qr/\$(?!$scope)[A-Za-z_][A-Za-z0-9_]*:/,
		"$script->[0] has no unbraced \$Variable: interpolation");
}

done_testing();
