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

done_testing();
