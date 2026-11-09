# tests-for: lib/JawnOS/Games.pm lib/JawnOS/Domain/Games.pm lib/JawnOS/Domain/Loader.pm scripts/jawnos_game_install.pl scripts/jawnos_game_launch.pl lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Routes/manager_misc9.pm templates/apps/games.html.ep perl/help/topics_people.pl
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

# --- the domain seam ----------------------------------------------------------
my $domain = read_file("$root/lib/JawnOS/Domain/Games.pm");
like($domain, qr/JAWNOS_GAMES_ROOT/, 'the tests can point the domain at a folder');
like($domain, qr/sub game_library/, 'the domain exposes the scan');
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
like($launch, qr/system\('systemctl', 'stop', 'jawnos-kiosk'\)/, 'the kiosk yields the panel');
like($launch, qr/system\('systemctl', 'start', 'jawnos-kiosk'\)/, 'and is started again on the way out');
like($launch, qr/gou-games/, 'the games marker arms the virtual gamepad');
like($launch, qr/POSIX::setuid\(\$uid\)/, 'the emulator runs as the person, not root');
like($launch, qr/POSIX::setgroups/, 'with the persons groups, so the sound card opens');
like($launch, qr|'/usr/bin/retroarch', '-f', '-L'|, 'RetroArch is run full screen with its core');
like($launch, qr/JawnOS::Games::runner_for/, 'the runner is the same one the route checked');
like($launch, qr/--appendconfig/, 'the game gets the config that names the card');
like($install, qr/audio_device = \\"hw:0,0\\"/, 'the installer writes the ALSA device the panel has');

# --- the routes and the page --------------------------------------------------
my $routes = read_file("$root/lib/JawnOS/Routes/manager_misc9.pm");
for my $row (
	[44005, 'get', '/manager/games/library', 'action_44005'],
	[44006, 'get', '/manager/games/art', 'action_44006'],
	[44007, 'post', '/manager/games/install', 'action_44007'],
	[44008, 'get', '/manager/games/install_status', 'action_44008'],
	[44009, 'post', '/manager/games/launch', 'action_44009'],
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

my $help = read_file("$root/perl/help/topics_people.pl");
like($help, qr/Install emulators fetches RetroArch/, 'the Guide describes the shelf');
like($help, qr/Home button above the arrow keys ends it/, 'and says how a game ends');

done_testing();
