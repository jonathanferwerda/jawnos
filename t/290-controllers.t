# tests-for: lib/JawnOS/Routes/manager_controllers.pm lib/JawnOS/Controller/manager_controllers.pm lib/JawnOS/Routes.pm templates/controllers/controllers.html.ep templates/controllers/style.html.ep templates/controllers/body.html.ep public/js/manager/controllers.js lib/JawnOS/Manager/Core1_tables_hooks.pm templates/start_menu/start_menu.html.ep public/js/manager/manager/05_start_menu.js public/js/manager/windows/01_storage.js perl/gb/02_labels_and_collectives.pl perl/help/topics_apps.pl scripts/gou_provision.pl
# covers:    The Controller app: its four routes and their action ids, the page and
#            its partials, the bundle entry, the start-menu toggle, the label row
#            and the help topic. The handheld's own /manager/controller app is a
#            different thing and must stay untouched, so the plural path is checked
#            to the word. The window it opens is registered as 'controllers', so a
#            reload restores this roster and not the handheld launcher.

use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use Test::More;
use File::Slurp qw(read_file);
use IPC::Open2 qw(open2);
use JSON::PP ();

my $root = "$Bin/..";

sub slurp {
	my ($file) = @_;
	return read_file("$root/$file");
}

my $routes = slurp('lib/JawnOS/Routes/manager_controllers.pm');
ok($routes =~ m{/manager/controllers['\s]}, 'the page route');
ok($routes =~ m{/manager/controllers/list}, 'the roster route');
ok($routes =~ m{/manager/controllers/request}, 'the request route');
ok($routes =~ m{/manager/controllers/approve}, 'the approve route');
ok($routes =~ m{/manager/controllers/new/scan}, 'the New scan route');
ok($routes =~ m{/manager/controllers/new/flash}, 'the New flash route');
ok($routes =~ m{/manager/controllers/storage}, 'the storage route');
ok($routes =~ m{/manager/controllers/roms}, 'the roms route');
ok($routes =~ m{/manager/controllers/card}, 'the card choice route');

foreach my $id (54001 .. 54015) {
	like($routes, qr/\[\Q$id\E,\s*'\w+',\s*'\/manager\/controllers[^']*',\s*'action_\Q$id\E'\]/,
		"row $id names action_$id");
}

my $controller = slurp('lib/JawnOS/Controller/manager_controllers.pm');
like($controller, qr/^package Manager;/m, 'the controller is in package Manager');
foreach my $id (54001 .. 54015) {
	like($controller, qr/^sub action_\Q$id\E\b/m, "action_$id is defined");
}

# The window this route draws belongs to Controllers, not to the handheld app.
# The app attribute is what windowSaver() writes and windowRetriever() reads, so
# the singular name sent a reload to /manager/controller instead of /manager/controllers.
my ($page_action) = $controller =~ /(sub action_54001 \{.*?\n\})/s;
ok($page_action, 'action_54001 is readable');
like($page_action, qr/window_maker\(\{[^}]*app => 'controllers'/, 'the page window is registered as controllers');
unlike($page_action, qr/app => 'controller'[^s]/, 'and not under the singular name');
like($page_action, qr/title => &subs::ui\('Controllers'\)/, 'its window title is Controllers');

# A reload opens the app through appWindowOpenerNow(), which carries a branch per
# bespoke app. Without one here the window came back with its roster never read.
my $storage_js = slurp('public/js/manager/windows/01_storage.js');
like($storage_js, qr/else if \(i == 'controllers'\) \{\s*if \(typeof controllerOpener === 'function'\) \{ controllerOpener\(\); \}/,
	'a reload opens Controllers through its own opener');

my $provision = slurp('scripts/gou_provision.pl');
like($provision, qr/--scan/, 'the provisioning script can scan');
like($provision, qr/--flash/, 'the provisioning script can flash');
like($provision, qr/30_?535_?680/, 'the script knows the eMMC sector count');

# The board joins this computer's Wi-Fi, read from the Network app at New time;
# nothing is typed on the page and the key stays on the server.
my $body = slurp('templates/controllers/body.html.ep');
like($body, qr/id="controllers_hostname"/, 'the New section asks for the board name');
like($body, qr/for="controllers_hostname"/, 'the name has a label');
unlike($body, qr/id="controllers_wifi_ssid"/, 'the network name is not typed');
unlike($body, qr/id="controllers_wifi_psk"/, 'the password is not typed');
like($body, qr/id="controllers_network_note"/, 'the page names the network the board will join');

like($controller, qr/network_helper\(\['wifi_current'\]\)/, 'the flash reads the Wi-Fi this computer is on from the Network app');
like($controller, qr/push \@args, \('--wifi-ssid', \$wifi_ssid\)/, 'the flash passes the network name');
like($controller, qr/push \@args, '--wifi-psk-stdin'/, 'the password is named on stdin, not argv');
unlike($controller, qr/'--wifi-psk',/, 'the password never reaches the argv');
like($controller, qr/File::Temp::tempfile\('gou_flash_psk_XXXXXXXX'/, 'the password is written to a private file for stdin');
like($controller, qr/open\(STDIN, '<', \$psk_path\).*?unlink \$psk_path;/s, 'the child opens it before the name is removed');
like($controller, qr/POSIX::setsid\(\)/, 'the flash runs in its own session, so a restart does not kill it');
like($controller, qr/push \@args, \('--progress', \$job_path\)/, 'the progress file is named for the page');

# The password arrives on the pipe, and the same shapes the page refuses are
# refused here before a board is looked for, so a typo is answered at once.
sub run_provision {
	my ($stdin, @args) = @_;
	my $pid = open2(my $out, my $in, $^X, "$root/scripts/gou_provision.pl", @args);
	print {$in} $stdin if defined $stdin;
	close $in;
	my $said = do { local $/; <$out> };
	close $out;
	waitpid($pid, 0);
	my $answer = eval { JSON::PP::decode_json($said) };
	return (($answer || {}), $? >> 8);
}

{
	my ($answer, $code) = run_provision("short\n", '--flash', '--wifi-ssid', 'cafe', '--wifi-psk-stdin');
	is($answer->{'error'}, 'invalid WiFi password', 'a short password on stdin is refused');
	is($code, 4, 'with the option exit code');
}
{
	my ($answer, $code) = run_provision(undef, '--flash', '--wifi-ssid', 'cafe');
	is($answer->{'error'}, 'give both the WiFi name and its password', 'a name without a password is refused');
	is($code, 4, 'with the option exit code');
}
{
	my ($answer) = run_provision("longenough\n", '--flash', '--wifi-ssid', 'cafe', '--wifi-psk', 'longenough', '--wifi-psk-stdin');
	is($answer->{'error'}, 'give one of --wifi-psk and --wifi-psk-stdin', 'the two ways of naming the password are not mixed');
}

my $controllers_js = slurp('public/js/manager/controllers.js');
like($controllers_js, qr/function controllerCurrentNetwork\(\)/, 'the page reads the network from the Network app');
like($controllers_js, qr{url: '/manager/network/status'}, 'through the Network app status route');
unlike($controllers_js, qr/'wifi-ssid'/, 'the flash sends no typed network name');
unlike($controllers_js, qr/'wifi-psk'/, 'and no typed password');
unlike($controllers_js, qr/function controllerNewNetwork\(\)/, 'the old field reader is gone');
like($controllers_js, qr/var controllerNewFields = \{/, 'the filled-in list keeps its words');
like($controllers_js, qr/identity: 'Machine identity'/, 'and names the identity the flash clears');

# The card the controller found: the page draws it, offers the choice, and asks
# once more before formatting.
like($controllers_js, qr/function controllerCardDraw\(data\)/, 'the card the controller found is drawn');
like($controllers_js, qr{url: '/manager/controllers/card'}, 'and its answer is posted');
like($controllers_js, qr/jawnosConfirm\(controllerT\('Format the card in this controller/, 'formatting is asked twice');
like($controller, qr/sub _controller_card_finding/, 'the page reads what the board reported');
like($controller, qr/that card already holds the archive/, 'the card holding the archive is never formatted from the page');

# The card's fate is chosen here because the card is in the board; the network
# is no longer a field, only the note the page fills from the Network app.
like($body, qr/id="controllers_card_choice"/, 'the New section asks what to do with the card');
like($controllers_js, qr/card: \(\$\('#controllers_card_choice'\)/, 'the card answer travels with the flash');
like($controllers_js, qr/The board will join \{0\}\./, 'the page names the network it will join');
like($controller, qr/card => \(\$card =~ \/\^\(adopt\|format\)\$\//, 'the token carries it to the board');

# The storage card owns the archive folder, so it also owns the backup share
# and the Backups folder the sealed snapshots are mirrored into.
like($controller, qr/qw\/Documents Downloads Recordings Games Scans Pictures Videos Music Backups\//,
	'the storage folder list includes Backups');
like($controller, qr/backup_quota/, 'the storage route reads and writes the backup quota');
like($controllers_js, qr/id="controllers_backup_quota"/, 'the storage card has a backup-space picker');
like($controllers_js, qr/backup_quota: quota/, 'the save carries the chosen quota');
like($body, qr/Backups folder/, 'the page explains where the backups live');

# The storage walkthrough steps over the same answer Save produces, and the
# route now says which of the folders are actually on the card.
like($controller, qr/my \$readable = .*archive_card_mounted\(\$dir\)/, 'a card that is not mounted makes no folder readable');
like($controller, qr/present => .*archive_card_mounted\(\$dir\)/s, 'the storage answer says whether the card is present');
like($controller, qr/sub _controller_rom_root.*archive_card_mounted/s, 'the ROM shelf checks the card before reading it');
like($controller, qr/!\$remote_to && !&subs::archive_card_mounted\(\$sd_dir\)/, 'copying to a local card waits for the mount');
like($body, qr/id="controllers_walkthrough_button"/, 'the Storage section offers the walkthrough');
like($body, qr/id="controllers_walkthrough"/, 'and a panel for its steps');
like($controllers_js, qr/function controllerWalkthroughSteps\(data\)/, 'the walkthrough has its steps');
like($controllers_js, qr/done: made >= controllerFolderNames\.length/, 'it knows when the eight folders are made');
like($controllers_js, qr/done: dir\.length > 0/, 'and when the folder has been typed');
like($controllers_js, qr/act: 'save'/, 'a step presses Save');
like($controllers_js, qr/\.attr\('data-act', step\.act\)/, 'each step button names what it presses');
like($controllers_js, qr/controllerWalkthroughDraw\(data\);/, 'a storage answer redraws the walkthrough');

# A controller that is not this computer is reached over ssh. These checks pin
# the shape: the address names the sshd, the eMMC side stays this computer's own
# shelf, and only the SD column waits on the peer.
like($controller, qr/sub _controller_ssh_target/, 'a peer controller gets an ssh target');
like($controller, qr/'ssh', '-p'/, 'the target runs ssh with its port');
like($controller, qr/'scp', '-r', '-p', '-P'/, 'a copy runs scp with its port');
like($controller, qr/sub _controller_remote_list/, 'a peer card is listed over ssh');
like($controller, qr/sub _controller_shell_quote/, 'a remote path is quoted for the remote shell');
like($controller, qr/address in Storage, then try again/, 'a missing address is named');
like($controller, qr/\$where eq 'sd' && !&_controller_is_this/, 'only the SD column waits on a peer');
like($controller, qr/address => \$address/, 'the storage save answers with the address');
like($controllers_js, qr/id="controllers_address"/, 'Storage asks for the controller address');
like($controllers_js, qr/address: address/, 'the save carries the address');

# Dropping a game writes it into the controller's own ~/roms/<system>/, which
# is what its Games shelf scans. The detect route names the system first; the
# upload route writes each file locally or over ssh.
like($routes, qr{/manager/controllers/roms/detect}, 'the detect route');
like($routes, qr{/manager/controllers/roms/upload}, 'the upload route');
like($controller, qr/sub action_54014/, 'detect is an action');
like($controller, qr/sub action_54015/, 'upload is an action');
like($controller, qr/sub _controller_console_root/, 'the controller shelf has a root');
like($controller, qr/sub _controller_rel_path_ok/, 'a dropped path is checked');
like($controller, qr/game_system_for_paths/, 'the system comes from the games map');
like($controller, qr/req->upload\('file'\)/, 'the file arrives as an upload');
like($body, qr/id="controllers_drop"/, 'the ROMs section takes a drop');
like($controllers_js, qr/function controllerDropGroups/, 'the page groups a drop');
like($controllers_js, qr/function controllerDropDir/, 'and walks a dropped folder');
like($controllers_js, qr{/manager/controllers/roms/upload}, 'each file is posted');
like($controllers_js, qr{/manager/controllers/roms/detect}, 'after the system is named');
like(slurp('lib/JawnOS.pm'), qr/max_request_size/, 'a ROM upload is not capped at the form limit');

my $names = slurp('lib/JawnOS/Routes.pm');
like($names, qr/\bmanager_controllers\b/, 'the module is registered in @NAMES');

foreach my $partial (qw(controllers.html.ep style.html.ep body.html.ep)) {
	ok(-e "$root/templates/controllers/$partial", "templates/controllers/$partial exists");
}
my $page = slurp('templates/controllers/controllers.html.ep');
like($page, qr{controllers/style}, 'the page includes its style partial');
like($page, qr{controllers/body}, 'the page includes its body partial');

my $core = slurp('lib/JawnOS/Manager/Core1_tables_hooks.pm');
like($core, qr{/js/manager/controllers\.js}, 'the JS is in the manager bundle');
ok(-e "$root/public/js/manager/controllers.js", 'public/js/manager/controllers.js exists');

my $menu = slurp('templates/start_menu/start_menu.html.ep');
like($menu, qr/id="controllers_toggle"/, 'the start menu carries the toggle');

my $start = slurp('public/js/manager/manager/05_start_menu.js');
like($start, qr/controllers_toggle\s*:\s*'controllers'/, 'the toggle maps to the app');

my $labels = slurp('perl/gb/02_labels_and_collectives.pl');
like($labels, qr/\bcontrollers\s*=>\s*\{\s*icon/, 'the app has a known-app row');

my $help = slurp('perl/help/topics_apps.pl');
like($help, qr/\$topic\{'controllers'\}/, 'the help topic is registered as controllers');
like($help, qr/read over SSH/, 'the help says a peer card is read over SSH');
like($help, qr/Drop a game file or folder/, 'the help explains dropping a game');

# Every template the topic claims must exist, or t/11 would fail for the wrong reason.
my ($topic_block) = $help =~ /(\$topic\{'controllers'\}\s*=\s*\{.*?\n\t+\};)/s;
ok($topic_block, 'the topic block is complete');
if ($topic_block) {
	my ($templates) = $topic_block =~ /templates\s*=>\s*\[([^\]]*)\]/;
	foreach my $path ($templates =~ /'([^']+)'/g) {
		ok(-e "$root/$path", "the topic's $path exists") if $path =~ m{^(templates|public)/};
	}
}

# A controller that joined with a token has no paired_devices row; the roster
# must still list it from remote_machines (device 'controller').
like($controller, qr/device\s*=>\s*'controller'/,
	'the roster also reads token-joined controllers from remote_machines');
like($controller, qr/joined\s*=>\s*1/,
	'and marks a token-joined controller as joined');

done_testing();
