# tests-for: lib/JawnOS/Games.pm lib/JawnOS/Domain/Games.pm lib/JawnOS/Domain/Loader.pm scripts/jawnos_game_install.pl scripts/jawnos_dosbox.pl scripts/jawnos_game_launch.pl lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Routes/manager_misc9.pm templates/apps/games.html.ep templates/apps/games/player.html.ep templates/start_menu/start_menu.html.ep templates/manager.html.ep public/js/manager/manager/05_start_menu.js lib/JawnOS/Manager/Part11.pm lib/JawnOS/Controller/manager_misc4.pm lib/JawnOS.pm perl/help/topics_people.pl perl/help/topics_features.pl
# covers:    The emulated shelf: the ROM scan under ~/roms, the system table and
#            package list, the two install actions, the launch helper that gives
#            the emulator the panel and Home, and the page that draws the cards.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use RepoSource;
use JawnOS::Games;

my $root = repo_root();

# --- the scan -----------------------------------------------------------------
my $tmp = tempdir(CLEANUP => 1);
make_path("$tmp/snes/media", "$tmp/nes", "$tmp/n64/Perfect Dark (U) (V1.1) [!]");
write_file("$tmp/snes/Super Mario World (U) [!].smc", 'rom');
write_file("$tmp/nes/Tetris (U) [!].nes", 'rom');
write_file("$tmp/n64/Perfect Dark (U) (V1.1) [!]/Perfect Dark (U) (V1.1) [!].z64", 'rom');
write_file("$tmp/nes/readme.txt", 'not a rom');
write_file("$tmp/snes/media/Super Mario World (U) [!]-image.png", 'png');

my $library = JawnOS::Games::scan($tmp);
ok($library->{'ok'}, 'the shelf scans');
is(scalar @{ $library->{'games'} }, 3, 'three ROMs found and a text file is not one');
my %by_title = map { $_->{'title'} => $_ } @{ $library->{'games'} };
ok($by_title{'Super Mario World'}, 'the region and dump tags are stripped from the title');
ok($by_title{'Tetris'}, 'a second system is read too');
ok($by_title{'Perfect Dark'}, 'a ROM under its own folder is found');
is($by_title{'Super Mario World'}->{'art'}, "$tmp/snes/media/Super Mario World (U) [!]-image.png",
	'a picture beside the ROM is the card art');
ok(!defined $by_title{'Tetris'}->{'art'}, 'a ROM with no picture has no art');
is(JawnOS::Games::clean_title('Super_Mario_World (U) [!]'), 'Super Mario World', 'underscores read as spaces');
like($by_title{'Tetris'}->{'id'}, qr/^[0-9a-f]{40}$/, 'every card carries an id');
is(JawnOS::Games::find($tmp, $by_title{'Tetris'}->{'id'})->{'title'}, 'Tetris', 'an id finds its game');
ok(!defined JawnOS::Games::find($tmp, 'x' x 40), 'an id that is not in the library finds nothing');
is(scalar @{ $library->{'systems'} }, 3, 'the systems with games are listed');

# --- the art index ------------------------------------------------------------
# A card asks for its picture once, and a page of cards used to mean a full tree
# walk behind every image - the shelf's request loop was pinned for as long as a
# page took to draw. The scan writes one small id -> picture map and the route
# reads it instead.
my $art_index = "$tmp/art-index.json";
$ENV{'JAWNOS_GAMES_ART_INDEX'} = $art_index;
JawnOS::Games::scan($tmp, { art_index => 1 });
ok(-f $art_index, 'the scan writes the art index');
my $mario_id = $by_title{'Super Mario World'}->{'id'};
is(JawnOS::Games::art_path($tmp, $mario_id), "$tmp/snes/media/Super Mario World (U) [!]-image.png",
	'the index answers a card picture without a second scan');
ok(!defined JawnOS::Games::art_path($tmp, ('0' x 40)), 'an id that is not in the index has no picture');
ok(!defined JawnOS::Games::art_path($tmp, $by_title{'Tetris'}->{'id'}), 'a game with no picture has none');

# Fetch covers writes <roms>/<system>/images/<rom>.png; the next scan must find
# that exact file, or every visit would offer to fetch the same cover again.
make_path("$tmp/nes/images");
write_file("$tmp/nes/images/Tetris (U) [!].png", 'png');
my $covered = JawnOS::Games::scan($tmp, { art_index => 1 });
my ($tetris) = grep { $_->{'title'} eq 'Tetris' } @{ $covered->{'games'} };
is($tetris->{'art'}, "$tmp/nes/images/Tetris (U) [!].png",
	'a cover saved where Fetch covers puts it becomes the card art');
is(JawnOS::Games::art_path($tmp, $tetris->{'id'}), "$tmp/nes/images/Tetris (U) [!].png",
	'and the refreshed index answers it without another walk');
delete $ENV{'JAWNOS_GAMES_ART_INDEX'};
# A DOS folder is a folder of files, not one ROM: the config and the
# program beside it are both cards.
my $dos = tempdir(CLEANUP => 1);
make_path("$dos/dos");
write_file("$dos/dos/TEST.conf", 'config');
write_file("$dos/dos/GAME.EXE", 'exe');
my $dos_library = JawnOS::Games::scan($dos);
is(scalar @{ $dos_library->{'games'} }, 2, 'a DOS config and a DOS program both reach the shelf');
is($dos_library->{'systems'}->[0]->{'label'}, 'DOS', 'the DOS folder is labelled DOS');

# --- the system table ---------------------------------------------------------
is(JawnOS::Games::system_label('snes'), 'Super Nintendo', 'the table names a system');
is(JawnOS::Games::system_label('weird_system'), 'Weird System', 'an unknown folder still has a label');
is(JawnOS::Games::core_for('snes')->{'core'}, 'snes9x_libretro.so', 'a known system names its core');
ok(!JawnOS::Games::core_for('weird_system'), 'an unknown system has no core');
my @packages = JawnOS::Games::packages();
my %seen;
is(scalar(grep { $seen{$_}++ } @packages), 0, 'the package list has no duplicates');
ok((grep { $_ eq 'libretro-snes9x' } @packages), 'the list carries the SNES core package');
is($packages[0], 'retroarch', 'the frontend is installed first');
ok(!(grep { $_ eq 'libretro-ppsspp' } @packages), 'a core the repositories lack is not asked for');

# DOS runs in DOSBox, not through a libretro core.
my $systems = JawnOS::Games::systems();
is($systems->{'dos'}->{'label'}, 'DOS', 'the table names the DOS system');
is($systems->{'dos'}->{'standalone'}, 'jawnos-dosbox', 'DOS runs through the DOSBox wrapper');
is($systems->{'dos'}->{'package'}, 'dosbox', 'DOS asks for the dosbox package');
my $dos_runner = JawnOS::Games::runner_for('dos');
is($dos_runner->{'kind'}, 'standalone', 'DOS is a standalone emulator, not a RetroArch core');
is($dos_runner->{'package'}, 'dosbox', 'the DOS runner names its package');
ok((grep { $_ eq 'dosbox' } @packages), 'the package list carries DOSBox');

my %extension = map { $_ => 1 } @JawnOS::Games::EXTENSION;
for my $suffix (qw(exe com bat conf zip img iso cue bin)) {
	ok($extension{$suffix}, "the library accepts .$suffix as a DOS game");
}

# --- the domain seam ----------------------------------------------------------
my $domain = read_file("$root/lib/JawnOS/Domain/Games.pm");
like($domain, qr/JAWNOS_GAMES_ROOT/, 'the tests can point the domain at a folder');
like($domain, qr/sub game_library/, 'the domain exposes the scan');
like($domain, qr/scan\(&game_root\(\), \{ art_index => 1 \}\)/, 'the shelf scan keeps the art index current');
like($domain, qr/JawnOS::Games::art_path/, 'and a card picture is read from the index');
like($domain, qr/sub game_runner/, 'and the runner the launch route checks');
like(read_file("$root/lib/JawnOS/Domain/Loader.pm"),
	qr/'JawnOS::Domain::Games' for qw\([^)]*game_library[^)]*game_runner/,
	'the loader registers the Games subs');

# --- the install helper -------------------------------------------------------
my $install = read_file("$root/scripts/jawnos_game_install.pl");
like($install, qr/JawnOS::Games::packages\(\)/, 'the installer uses the one package list');
like($install, qr/system\('pacman', '-S', '--needed', '--noconfirm', \$package\)/,
	'packages are installed from a fixed argv');
like($install, qr/system\('cp', '-a', '-n'/, 'a ROM import never overwrites a file');
like($install, qr/install\.json/, 'it reports through one status row');
like($install, qr/eq 'emulators'/, 'it knows the emulator install');
like($install, qr/eq 'roms'/, 'and the ROM import');
like($install, qr|/media/emmc/opt/libretro|, 'cores the repositories lack come from the emmc');
like($install, qr/db\.lck/, 'a stale pacman lock is cleared only when no pacman runs');

# --- the launch helper --------------------------------------------------------
my $launch = read_file("$root/scripts/jawnos_game_launch.pl");
like($launch, qr/HOME_KEY = 102/, 'Home is the key that ends a game');
like($launch, qr/sub hide_kiosk/, 'the kiosk window is hidden, not stopped');
like($launch, qr/windowunmap/, 'hidden with one X request, so the browser stays warm');
like($launch, qr/xdotool\('windowmap'/, 'and shown again when the game ends');
like($launch, qr/'--signal=SIGSTOP'/, 'the browser is frozen so the emulator has the machine');
like($launch, qr/'--signal=SIGCONT'/, 'and woken before it is shown again');
like($launch, qr/system\('systemctl', 'restart', 'jawnos-kiosk'\)/, 'a kiosk that cannot be shown is restarted');
like($launch, qr/gou-games/, 'the games marker arms the virtual gamepad');
like($launch, qr/POSIX::setuid\(\$uid\)/, 'the emulator runs as the person, not root');
like($launch, qr/--init-groups/, 'with the persons groups, so the sound card opens');
like($launch, qr/JawnOS::Games::retroarch_binary/, 'the frontend is the desktop-GL build when it is installed');
like($launch, qr/governor_set\('performance'\)/, 'the CPU is held at performance while a game runs');
like($launch, qr/governor_restore\(\)/, 'and the saved governor is put back on the way out');
like($launch, qr/\$STATE.governor/, 'what to go back to is left for the guard to find');
like(read_file("$root/lib/JawnOS/Games.pm"), qr|/opt/retroarch-gl/cores|, 'the cores built beside that frontend are searched first');

like($launch, qr/\@command = \(\$retroarch, '-f', '-L'/, 'and the core runs inside that frontend, full screen');
like(read_file("$root/lib/JawnOS/Games.pm"), qr|/opt/retroarch-gl/bin/retroarch|, 'Games.pm knows where the GL build goes');

like($launch, qr/JawnOS::Games::runner_by_id/, 'the runner is the same one the route checked');
like($launch, qr/--appendconfig/, 'the game gets the config that names the card');
like($launch, qr/sub kiosk_active/, 'the restore waits for the kiosk, not just starts it');
like($launch, qr/game-launch-/, 'a launch writes one log file of its own');
like($launch, qr/chown\(\$uid, \$gid, \$CACHE\)/, 'the launch cache is handed to the person, not left root-only');
like($launch, qr/chmod 0755, \$CACHE/, 'and is readable');
like($launch, qr/chmod 0644, \$LOG/, 'so the log a failed launch names can be read');
like($launch, qr/open\(STDERR, '>&', \$LOGFH\)/, 'the emulator\'s own words go to that log');
like($launch, qr/sub log_tail/, 'and a launch that dies keeps its last words');
like($launch, qr/The emulator stopped at once/, 'an emulator that exits at once reports why instead of ending silently');
like($launch, qr/\$home_pressed/, 'Home is not mistaken for a failure');
like($launch, qr/log_line\("kiosk hidden/, 'and the helper records what it hid');
like($launch, qr/\$STATUS\{'log'\} = \$LOG/, 'the status row names the log');
like(read_file("$root/lib/JawnOS/Controller/manager_misc9.pm"), qr/sub action_44018/,
	'the launch status action exists');
like(read_file("$root/lib/JawnOS/Routes/manager_misc9.pm"), qr{/manager/games/launch_status},
	'and its route');
like($install, qr/input_player1_joypad_index/, 'the gamepad is player one, not the keys device');
like($install, qr/JawnOS Gamepad\.cfg/, 'the virtual pad gets an autoconfig profile');
like($install, qr/input_start_btn = "5"/, 'Start is mapped by the pad key position');
like($install, qr/audio_device = \\"hw:0,0\\"/, 'the installer writes the ALSA device the panel has');

my $games_pm = read_file("$root/lib/JawnOS/Games.pm");
like($games_pm, qr/-e "\$root\/\$system\/\$stem\.cue"/, 'a .bin beside its .cue is not a second game');
like($install, qr|/home/jawn/\.config/dosbox|, 'the installer writes DOSBox settings in the persons config folder');
like($install, qr/fullscreen=true/, 'DOSBox starts full screen');
like($install, qr/jawnos-dosbox/, 'the installer places the wrapper the shelf names');

# --- the DOSBox wrapper -------------------------------------------------------
my $dosbox = read_file("$root/scripts/jawnos_dosbox.pl");
like($dosbox, qr/'-fullscreen'/, 'the wrapper asks DOSBox for the whole panel');
like($dosbox, qr/'-exit'/, 'and asks it to leave when the game does');
like($dosbox, qr/'-conf'/, 'a DOS config is handed to DOSBox as its config');
like($dosbox, qr/eq '-e'/, 'the wrapper reads the launch helpers file argument');
like($dosbox, qr|/home/jawn/\.config/dosbox|, 'and names the person config the installer wrote');

# --- the routes and the page --------------------------------------------------
my $routes = read_file("$root/lib/JawnOS/Routes/manager_misc9.pm");
for my $row (
	[44005, 'get', '/manager/games/library', 'action_44005'],
	[44006, 'get', '/manager/games/art', 'action_44006'],
	[44007, 'post', '/manager/games/install', 'action_44007'],
	[44008, 'get', '/manager/games/install_status', 'action_44008'],
	[44009, 'post', '/manager/games/launch', 'action_44009'],
	[44015, 'post', '/manager/games/emulator', 'action_44015'],
	[44016, 'post', '/manager/games/covers', 'action_44016'],
	[44017, 'get', '/manager/games/covers/status', 'action_44017'],
	[44024, 'get', '/manager/games/play', 'action_44024'],
	[44025, 'get', '/manager/games/dos_bundle', 'action_44025'],
) {
	my ($id, $verb, $path, $action) = @{$row};
	like($routes, qr/\[\s*$id\s*,\s*'$verb'\s*,\s*'\Q$path\E'\s*,\s*'$action'\s*\]/,
		"$verb $path is registered");
}

my $controller = read_file("$root/lib/JawnOS/Controller/manager_misc9.pm");
like($controller, qr/my \$view = .* eq 'emulated'/, 'the page has an emulated view');
like($controller, qr/game_runner\(\$game->\{'system'\}\)/, 'the launch route checks the runner first');
like($controller, qr/retroarch/, 'and refuses a launch with no emulator');
like($controller, qr/sub game_helper_start/, 'the helper is detached from the request');
like($controller, qr/POSIX::setsid/, 'under its own session, so no warranty kills the game');

my $page = read_file("$root/templates/apps/games.html.ep");
like($page, qr/id="games_install_emulators"/, 'the shelf has an install-emulators button');
like($page, qr/id="games_install_roms"/, 'the shelf has an install-ROMs button');
like($page, qr/class="game_card"/, 'a game is a card');
like($page, qr|/manager/games/art\?id=|, 'the card asks for its art');
like($page, qr/data-game="<%= \$game->\{'id'\} %>"/, 'the card carries its id');
like($page, qr/No games yet/, 'an empty shelf says so');

# The art route used to set the content asset and return without finishing the
# response, so every cover request stayed open until the browser gave up (five
# minutes), pinned the page's connections, and the shelf never drew. reply->file
# finishes the response and serves the same file.
like($controller, qr/\$c->reply->file\(\$path\)/, 'the art route finishes the response with the cover file');
unlike($controller, qr/\$c->res->content->asset\(Mojo::Asset::File->new\(path => \$path\)\)/,
	'and no longer leaves the request open by only setting the asset');
like($page, qr/decoding="async"/, 'a cover decodes asynchronously');


my $help = read_file("$root/perl/help/topics_people.pl");
like($help, qr/Install emulators fetches RetroArch/, 'the Guide describes the shelf');
like($help, qr/cover is kept beside the ROM/, 'and says a fetched cover is kept, not fetched again');
like($help, qr/Home button above the arrow keys ends it/, 'and says how a game ends');

# --- the runner table ---------------------------------------------------------
# Availability is a filesystem fact, so the checks point @CORE_DIR at a folder
# they own: the answer must not depend on what this machine happens to have.
{
	my $cores = tempdir(CLEANUP => 1);
	write_file("$cores/mupen64plus_next_libretro.so.opt", 'core');
	write_file("$cores/mupen64plus_next_libretro.so", 'core');
	local @JawnOS::Games::CORE_DIR = ($cores);

	my $runners = JawnOS::Games::runners_for('n64');
	is(scalar @{ $runners }, 3, 'the N64 offers three runners');
	is($runners->[0]->{'id'}, 'retroarch-opt', 'the optimized build is offered first');
	ok($runners->[0]->{'available'}, 'and is available when its core is installed');
	is($runners->[1]->{'id'}, 'retroarch', 'the packaged core is the second');
	ok($runners->[1]->{'available'}, 'it is available too');
	is($runners->[2]->{'id'}, 'stock', 'the eMMC emulator is the third');
	ok(!$runners->[2]->{'available'}, 'and can never be chosen on this kernel');
	like($runners->[2]->{'reason'}, qr/Mali/, 'because it needs a driver this kernel does not load');
	is(JawnOS::Games::default_runner('n64')->{'id'}, 'retroarch-opt', 'the optimized build is the default');
	is(JawnOS::Games::runner_by_id('n64', 'stock')->{'available'}, 0, 'a blocked runner resolves as unavailable');
	is(JawnOS::Games::runner_by_id('n64', 'nonsense')->{'id'}, 'retroarch-opt', 'an unknown id falls back to the default');
	my $chosen = JawnOS::Games::runner_for('n64', 'retroarch');
	is($chosen->{'id'}, 'retroarch', 'runner_for honors the chosen id');
	is($chosen->{'core_name'}, 'mupen64plus_next_libretro.so', 'and resolves that runner\'s core');
	is(scalar @{ JawnOS::Games::runners_for('weird_system') }, 0, 'an unknown system has no runners');

	my $scan = JawnOS::Games::scan($tmp, { chosen => { n64 => 'retroarch' } });
	my ($n64row) = grep { $_->{'id'} eq 'n64' } @{ $scan->{'systems'} };
	is($n64row->{'chosen'}, 'retroarch', 'a saved pick is the chosen runner');
	is(scalar @{ $n64row->{'runners'} }, 3, 'a system with a choice reports every runner');
	ok(!exists $n64row->{'runners'}[0]->{'core'}, 'the page-facing copy carries no core path');
	my ($stockrow) = grep { $_->{'id'} eq 'stock' } @{ $n64row->{'runners'} };
	ok(!$stockrow->{'available'}, 'the blocked runner is drawn disabled');
	like($stockrow->{'reason'}, qr/Mali/, 'with its reason');

	my $blocked = JawnOS::Games::scan($tmp, { chosen => { n64 => 'stock' } });
	($n64row) = grep { $_->{'id'} eq 'n64' } @{ $blocked->{'systems'} };
	is($n64row->{'chosen'}, 'retroarch-opt', 'an unavailable pick is never chosen');
	my $unknown = JawnOS::Games::scan($tmp, { chosen => { n64 => 'nonsense' } });
	($n64row) = grep { $_->{'id'} eq 'n64' } @{ $unknown->{'systems'} };
	is($n64row->{'chosen'}, 'retroarch-opt', 'an unknown pick falls back to the default');
	my ($snesrow) = grep { $_->{'id'} eq 'snes' } @{ $scan->{'systems'} };
	ok(!exists $snesrow->{'runners'}, 'a single-runner system draws no picker');

	unlink "$cores/mupen64plus_next_libretro.so.opt";
	is(JawnOS::Games::default_runner('n64')->{'id'}, 'retroarch', 'a missing optimized core falls back to the packaged one');
}

# --- the new seams ------------------------------------------------------------
like(read_file("$root/lib/JawnOS/Domain/Loader.pm"),
	qr/'JawnOS::Domain::Games' for qw\([^)]*game_runners[^)]*game_runner_choice[^)]*game_runner_choose/,
	'the loader registers the runner subs');
like($controller, qr/sub action_44015/, 'the emulator choice has an action');
like($controller, qr/&subs::game_runner_choose/, 'and saves through the domain');
like($controller, qr/sub action_44016/, 'the cover lookup has an action');
like($controller, qr/sub action_44017/, 'and a status action');
my ($covers_action) = $controller =~ /(sub action_44016\b.*?\n\})/s;
ok($covers_action, 'the cover action can be read on its own');
unlike($covers_action, qr/game_library\(\)/, 'a cover press does not scan the shelf in the request');
like($covers_action, qr/game_helper_start\(\$script\)/, 'the whole lookup is handed to the detached helper');
like($controller, qr/cache_control\('private, max-age=300'\)/, 'a card picture is cached by the browser');
like($controller, qr/game_helper_start\(\$script, \$game->\{'id'\}, \$runner->\{'id'\}\)/,
	'the launch hands the chosen runner to the helper');
like($launch, qr/\$RUNNER_ID/, 'the helper takes the runner id');
like($launch, qr/\@\{ \$runner->\{'args'\} \/\/ \['-b', '-e'\] \}/, 'a standalone emulator gets its own or the default arguments');

# --- the cover module ---------------------------------------------------------
like(read_file("$root/lib/JawnOS/RomCovers.pm"), qr/sub best_match/, 'the cover matcher is a pure module');
like(read_file("$root/scripts/rom_covers.pl"), qr/JawnOS::RomCovers/, 'the helper uses it');


# --- the browser player -------------------------------------------------------
# A desk and a phone have no DOSBox, so a DOS card also runs inside the page.
# It is the same folder the handheld mounts: a js-dos bundle is a zip with
# .jsdos/dosbox.conf and the game's files.
my $browser = tempdir(CLEANUP => 1);
make_path("$browser/dos/TESTGAME");
write_file("$browser/dos/TESTGAME/GAME.EXE", 'exe');
write_file("$browser/dos/TESTGAME/DATA.DAT", 'data');
write_file("$browser/dos/TESTGAME/RUN.conf", "[autoexec]\nmount c .\nc:\nGAME.EXE\n");
write_file("$browser/dos/ARCHIVE.ZIP", 'zip');
my $browser_library = JawnOS::Games::scan($browser);
my ($exe_card) = grep { $_->{'title'} eq 'GAME' } @{ $browser_library->{'games'} };
my ($conf_card) = grep { $_->{'title'} eq 'RUN' } @{ $browser_library->{'games'} };
my ($zip_card) = grep { $_->{'title'} eq 'ARCHIVE' } @{ $browser_library->{'games'} };
ok(JawnOS::Games::browser_runnable($exe_card), 'a DOS programme can run in the browser');
ok(JawnOS::Games::browser_runnable($conf_card), 'and so can a DOS config');
ok(!JawnOS::Games::browser_runnable($zip_card), 'a zip names no programme to run');
my ($snes_card) = grep { $_->{'system'} eq 'snes' } @{ $library->{'games'} };
ok(!JawnOS::Games::browser_runnable($snes_card), 'a console ROM is not a browser game');

like(JawnOS::Games::bundle_config($exe_card), qr/^mount c \.$/m,
	'the generated config mounts the game folder as C:');
like(JawnOS::Games::bundle_config($exe_card), qr/^GAME\.EXE$/m,
	'and runs the card by name');
like(JawnOS::Games::bundle_config($conf_card), qr/^mount c \.$/m,
	'a .conf is passed through as the DOSBox config');

my $cache = "$browser/cache";
my $bundle = JawnOS::Games::browser_bundle($exe_card, $cache);
ok($bundle->{'ok'}, 'a DOS card builds a browser bundle');
ok(defined $bundle->{'path'} && -f $bundle->{'path'}, 'the bundle is a file on disk');
my %member;
{
	require IO::Uncompress::Unzip;
	my $zip = IO::Uncompress::Unzip->new($bundle->{'path'})
		or die $IO::Uncompress::Unzip::UnzipError;
	do {
		my $name = $zip->getHeaderInfo->{'Name'};
		local $/;
		$member{$name} = <$zip>;
	} while ($zip->nextStream);
}
ok(exists $member{'.jsdos/dosbox.conf'}, 'the bundle carries the config js-dos requires');
is($member{'GAME.EXE'}, 'exe', 'and the programme itself');
is($member{'DATA.DAT'}, 'data', 'and the files beside it');

my $again = JawnOS::Games::browser_bundle($exe_card, $cache);
is($again->{'path'}, $bundle->{'path'}, 'a second press reuses the bundle');
write_file("$browser/dos/TESTGAME/DATA.DAT", 'data changed');
my $changed = JawnOS::Games::browser_bundle($exe_card, $cache);
isnt($changed->{'path'}, $bundle->{'path'}, 'a changed game file builds a fresh bundle');
ok(!-f $bundle->{'path'}, 'and the stale bundle is removed');

for my $asset (qw(
	public/js/dos/js-dos.js public/js/dos/js-dos.css
	public/js/dos/emulators/emulators.js public/js/dos/emulators/wdosbox.js
	public/js/dos/emulators/wdosbox.wasm public/js/dos/emulators/wlibzip.js
	public/js/dos/emulators/wlibzip.wasm public/js/dos/COPYING public/js/dos/SOURCE.txt
)) {
	ok(-s "$root/$asset", "$asset is vendored");
}

my $player = read_file("$root/templates/apps/games/player.html.ep");
like($player, qr/autoStart:\s*true/, 'the player starts the game without a second press');
like($player, qr/noCloud:\s*true/, 'and asks for no cloud key');
like($player, qr/noNetworking:\s*true/, 'and makes no network calls');
like($player, qr|pathPrefix:\s*'/js/dos/emulators/'|, 'the emulator is the vendored copy');
like($player, qr{/manager/games/dos_bundle\?id=}, 'the game comes from the bundle route');
like($player, qr/closeWindow/, 'Close ends the window');

like($controller, qr/sub action_44024\b/, 'the player page has an action');
like($controller, qr/sub action_44025\b/, 'and the bundle has one');
like($controller, qr/game_browser_runnable/, 'the player asks the domain what can run');
like($controller, qr/game_browser_bundle/, 'the bundle route goes through the domain');
like(read_file("$root/lib/JawnOS.pm"), qr/type\(wasm => 'application\/wasm'\)/,
	'a wasm asset is served as wasm');

my $menu = read_file("$root/templates/start_menu/start_menu.html.ep");
like($menu, qr/dos_game_toggle/, 'the games shelf carries a row per DOS game');
like($menu, qr/data-game="<%= \$dos_game->\{'id'\} %>"/, 'the row carries the card id');
my $menu_js = read_file("$root/public/js/manager/manager/05_start_menu.js");
like($menu_js, qr/\.dos_game_toggle/, 'the row opens the browser player');
like($menu_js, qr{/manager/games/play}, 'through the player route');
like(read_file("$root/lib/JawnOS/Manager/Part11.pm"),
	qr/dos_games => \(exists \$opts->\{'dos_games'\} \? \$opts->\{'dos_games'\} : &subs::game_menu_entries\(\)\)/,
	'the menu maker hands the list to the template');
like(read_file("$root/lib/JawnOS/Controller/apps_misc.pm"),
	qr/start_menu_maker\(\$c, \{ dos_games => \[\] \}\)/,
	'the public app list does not ask for the games shelf');
like(read_file("$root/templates/manager.html.ep"),
	qr/dos_games => \(\$c->stash\('dos_games'\)/,
	'the pre-rendered menu carries it too');

my $domain_src = read_file("$root/lib/JawnOS/Domain/Games.pm");
like($domain_src, qr/sub game_menu_entries/, 'the domain exposes the games-shelf rows');
like($domain_src, qr/sub game_browser_bundle/, 'and the browser bundle');
like($domain_src, qr/sub game_browser_runnable/, 'and the runnable test the player asks');
like(read_file("$root/lib/JawnOS/Domain/Loader.pm"),
	qr/'JawnOS::Domain::Games' for qw\([^)]*game_browser_runnable[^)]*game_browser_bundle[^)]*game_menu_entries/,
	'the loader registers them');

like($help, qr/browser player/, 'the Guide describes the browser player');
like(read_file("$root/perl/help/topics_features.pl"),
	qr/DOS game the browser can run/, 'and the start menu topic names its rows');
like(read_file("$root/docs/THIRD-PARTY.md"), qr/js-dos 8\.3\.0/,
	'the vendored player is in the third-party notices');

done_testing();
