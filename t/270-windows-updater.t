# tests-for: lib/JawnOS/Domain/WindowsUpdate.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Routes/manager_misc3.pm lib/JawnOS/Controller/manager_misc3.pm lib/JawnOS/Manager/Part08.pm lib/JawnOS/Manager/Index.pm lib/JawnOS/Manager/Declarations.pm templates/configure/device_lister/body.html.ep public/js/manager/configure/01_update_controls.js perl/help/topics_configure.pl
# covers:    the Windows self-updater - version codes, the release feed, the
#           detached PowerShell helper's one-owner update sequence (stop, wait,
#           install, verify, start once) and the non-Windows no-op

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);

# The Windows install is a git-archive copy with no .git, so the code watcher
# has nothing to pull. This updater is the Windows answer: a release manifest,
# a Setup.exe downloaded and verified by a detached helper, and the installer
# bringing the house back afterwards. Most of it cannot run on this Linux host,
# so the parts that decide anything are pinned here and the parts that only act
# on Windows are pinned by their source.
require JawnOS::Domain::WindowsUpdate;

my $root = "$FindBin::Bin/..";

my $manifest = {
	product     => 'windows',
	version     => '0.1.2727',
	versionCode => 1002727,
	filename    => 'JawnOS-0.1.2727-Setup.exe',
	sha256      => 'a' x 64,
	size        => 123456789,
	url         => 'https://github.com/jonathanferwerda/jawnos/releases/download/releases/JawnOS-0.1.2727-Setup.exe',
	notes       => 'the next Windows build',
	min_os      => '10.0.19044',
	signed      => 0,
};

# --- versionCode is the major/minor/patch number the feed uses ---------------
is(subs::windows_version_code('0.1.2727'), 1002727, '0.1.2727 is 1002727');
is(subs::windows_version_code('0.1.2724'), 1002724, '0.1.2724 is 1002724');
is(subs::windows_version_code('1.2.3'), 102000003, '1.2.3 is 102000003');
is(subs::windows_version_code('v0.1.2727'), 1002727, 'a leading v is tolerated');
is(subs::windows_version_code('nonsense'), 0, 'an unreadable VERSION is code 0');
ok(subs::windows_version_code('0.1.2727') > subs::windows_version_code('0.1.2724'),
	'a newer patch compares newer');

# --- the feed is this product and this filename ------------------------------
ok(subs::windows_release_valid($manifest), 'the agreed feed validates');

my %bad = (
	'product is app' => { %$manifest, product => 'app' },
	'filename is not the Setup' => { %$manifest, filename => 'JawnOS-0.1.2727-Setup.msi' },
	'filename is not ours' => { %$manifest, filename => 'evil-Setup.exe' },
	'no versionCode' => { %$manifest, versionCode => 0 },
	'sha256 is short' => { %$manifest, sha256 => 'abc' },
	'no size' => { %$manifest, size => 0 },
	'not a github download' => { %$manifest, url => 'https://example.com/JawnOS-0.1.2727-Setup.exe' },
);
foreach my $why (sort keys %bad) {
	ok(!subs::windows_release_valid($bad{$why}), "refused: $why");
}

is(subs::windows_update_url({ %$manifest, url => undef, base => 'https://github.com/o/r/releases/download/releases' }),
	'https://github.com/o/r/releases/download/releases/JawnOS-0.1.2727-Setup.exe',
	'a feed without url uses the asset beside the manifest');

# --- only a newer build is offered -------------------------------------------
my $offer = subs::windows_release_available({ manifest => $manifest, version => '0.1.2724' });
ok($offer, 'a newer versionCode is offered');
is($offer->{'version'}, '0.1.2727', 'with the feed version');
is($offer->{'running'}, '0.1.2724', 'and the running version');
is($offer->{'url'}, $manifest->{'url'}, 'and the verified download');

is(subs::windows_release_available({ manifest => $manifest, version => '0.1.2727' }), undef,
	'the same versionCode is not an update');
is(subs::windows_release_available({ manifest => $manifest, version => '0.1.2728' }), undef,
	'an older feed is not offered');

# --- the helper script carries the manifest -----------------------------------
my $script = subs::windows_update_helper_script($manifest);
like($script, qr/Get-FileHash -LiteralPath \$setup -Algorithm SHA256/,
	'the helper hashes the Setup');
like($script, qr/\Q$manifest->{'sha256'}\E/, 'with the feed sha256');
like($script, qr/\Q$manifest->{'size'}\E/, 'and the feed size');
like($script, qr/\Q$manifest->{'url'}\E/, 'and the feed url');
like($script, qr/\Q$manifest->{'filename'}\E/, 'and the Setup filename');
like($script, qr{/VERYSILENT}, 'the installer runs silently');
like($script, qr{/SUPPRESSMSGBOXES}, 'with no dialogs');
like($script, qr{/NORESTART}, 'without restarting Windows');
like($script, qr{/MERGETASKS=!lanaccess}, 'and without the LAN access task');
like($script, qr{/LOG=}, 'writing an installer log');
like($script, qr/wscript\.exe/, 'the house is started again through wscript');
like($script, qr/launch\.vbs/, 'with the installer\'s launch.vbs');
like($script, qr/jawnos-update\.log/, 'and the helper logs to %TEMP%');
like($script, qr/curl\.exe|Invoke-WebRequest/, 'the download has a Windows tool');
unlike($script, qr/__URL__|__SHA__|__SIZE__|__FILENAME__|__INSTALLDIR__/, 'no placeholder is left in it');

# --- the helper is one ordered sequence: stop, install, verify, start -------
# The script only runs on Windows, so its order is pinned here. Inno cannot
# replace a locked perl.exe and a second master would fight for the ports, so
# the house must be stopped before the Setup runs; and it must be started once,
# only after the installer has left a tree the updater can prove.
my $install_root = 'C:\\Users\\me\\AppData\\Local\\JawnOS';
my $ordered = subs::windows_update_helper_script($manifest, { install_dir => $install_root });

like($ordered, qr/\$installed = '\Q$install_root\E'/,
	'the install the updater runs from is embedded, not assumed');
like($ordered, qr/Join-Path \$env:LOCALAPPDATA 'JawnOS'/,
	'%LOCALAPPDATA%\\JawnOS is the fallback');
like($ordered, qr/\.president\\pid/, 'the master pid record is read');
like($ordered, qr/working_port/, 'the configured ports are read');
like($ordered, qr/config\.json/, 'the install is judged by config.json');
like($ordered, qr/database\\jawnos\.db/, 'and by the database');
like($ordered, qr/jawnos-update\.log/, 'every step goes to the update log');
like($ordered, qr/TotalSeconds/, 'including how long each wait took');

my $stop_at   = index($ordered, "scripts\\manager_killer.pl");
my $wait_at   = index($ordered, 'Wait-HouseStopped $masterPid $ports 30');
my $kill_at   = index($ordered, 'Stop-Process -Id $masterPid -Force');
my $setup_at  = index($ordered, 'Start-Process -FilePath $setup');
my $exit_at   = index($ordered, '$proc.ExitCode -ne 0');
my $verify_at = index($ordered, 'Test-InstallTree $root');
my $launch_at = index($ordered, "Start-Process -FilePath 'wscript.exe'");

ok($stop_at >= 0 && $setup_at > $stop_at,
	'the house is asked to stop before the Setup.exe runs');
ok($wait_at > $stop_at && $wait_at < $setup_at,
	'and the stop is waited for, bounded, before the install');
ok($kill_at > $wait_at && $kill_at < $setup_at,
	'with the master pid terminated when the polite stop does not finish');
ok($exit_at > $setup_at && $exit_at < $launch_at,
	'a failed installer is reported instead of starting the house');
ok($verify_at > $exit_at && $verify_at < $launch_at,
	'and the install tree is proven before the house is started');

my $starts = () = $ordered =~ /Start-Process -FilePath 'wscript\.exe'/g;
is($starts, 1, 'the house is started exactly once');

# --- non-Windows is a named no-op --------------------------------------------
SKIP: {
	skip 'the no-op is for a host that is not Windows', 1 if $^O eq 'MSWin32';
	my $result = subs::windows_update_start({ manifest => $manifest });
	is_deeply($result, { ok => 0, error => 'not this platform' },
		'a Linux manager refuses the Windows updater and touches nothing');
}

# --- the routes, panel and help name the same thing --------------------------
my $routes = read_file("$root/lib/JawnOS/Routes/manager_misc3.pm");
like($routes, qr{\[11741, 'get', '/manager/windows_update', 'action_11741'\]},
	'GET /manager/windows_update is routed');
like($routes, qr{\[11742, 'post', '/manager/windows_update', 'action_11742'\]},
	'POST /manager/windows_update is routed');

my $controller = read_file("$root/lib/JawnOS/Controller/manager_misc3.pm");
like($controller, qr/sub action_11741\b/, 'the GET action exists');
like($controller, qr/sub action_11742\b/, 'the POST action exists');
like($controller, qr/not this platform/, 'both say so off Windows');
like($controller, qr/windows_update_gate\(\$c\)/, 'the status route uses the shared gate');
my ($install_action) = $controller =~ /(sub action_11742\b.*?)(?=\nsub |\z)/s;
like($install_action, qr/session\('authentication'\)/, 'installing is an approved local session');
unlike($install_action, qr/windows_update_gate\(\$c\)/, 'a peer cannot start an install');

my $manager_part = read_file("$root/lib/JawnOS/Manager/Part08.pm");
like($manager_part, qr/sub windows_update_gate\b/, 'the gate lives in the manager part');
like($manager_part, qr/peer_allows\(\$c, \$rm, 'member'\)/,
	'the peer rail keeps the app_release gate');

my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader, qr/JawnOS::Domain::WindowsUpdate' for qw\([^)]*windows_update_start/,
	'the domain loader maps the updater');

my $template = read_file("$root/templates/configure/device_lister/body.html.ep");
like($template, qr/id="windows_update_card"/, 'the Dev panel has the Windows card');
like($template, qr/id="windows_update_button"/, 'with its update button');

my $js = read_file("$root/public/js/manager/configure/01_update_controls.js");
like($js, qr/windowsUpdateCheck/, 'the panel checks for an update');
like($js, qr{url: '/manager/windows_update'}, 'against the routed path');

my $help = read_file("$root/perl/help/topics_configure.pl");
like($help, qr/Update Windows app/, 'the Configure help explains the button');
like($help, qr/stops the running house first and waits/, 'and says the house is stopped and waited for');

done_testing();
