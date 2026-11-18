# tests-for: lib/JawnOS/Domain/Games.pm lib/JawnOS/Domain/Remote.pm lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Routes/manager_misc9.pm templates/apps/games.html.ep perl/help/topics_people.pl lib/JawnOS/Domain/Loader.pm perl/hooks.pl
# covers:    the shared games library. One machine's ~/roms is the catalogue:
#            what a peer reads, what one game's pull carries (the folder, not a
#            bare file, and its cover), the pack and its refusal rules, and the
#            page section that offers a game this machine does not have.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file write_file);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Mojo::JSON ();
use RepoSource;
use JawnOSTest;
use JawnOS::Games;

my $root = repo_root();
my $scratch = tempdir(CLEANUP => 1);

# --- one game's pull carries its folder, and its cover -----------------------
{
	my $tree = "$scratch/members";
	make_path("$tree/nes/media", "$tree/dos/Smoke Test");

	my $nested = {
		id => JawnOS::Games::id_for('dos', 'Smoke Test/SMOKE.conf'),
		system => 'dos', title => 'SMOKE',
		file => "$tree/dos/Smoke Test/SMOKE.conf", art => undef,
	};
	is_deeply([ subs::game_pull_members($nested, $tree) ], [ 'dos/Smoke Test' ],
		'a DOS game travels as the folder it lives in');

	write_file("$tree/nes/Tetris (U) [!].nes", "rom");
	write_file("$tree/nes/media/Tetris (U) [!]-image.png", "png");
	my $flat = {
		id => JawnOS::Games::id_for('nes', 'Tetris (U) [!].nes'),
		system => 'nes', title => 'Tetris',
		file => "$tree/nes/Tetris (U) [!].nes",
		art => "$tree/nes/media/Tetris (U) [!]-image.png",
	};
	is_deeply([ subs::game_pull_members($flat, $tree) ],
		[ 'nes/Tetris (U) [!].nes', 'nes/media/Tetris (U) [!]-image.png' ],
		'a single ROM travels with the cover filed beside it');

	my $outside = { %$flat, file => '/etc/passwd' };
	is_deeply([ subs::game_pull_members($outside, $tree) ], [],
		'a game filed outside the root is refused');

	my $folder_size = subs::game_members_size($tree, 'nes');
	cmp_ok($folder_size, '>', 0, 'the size of a folder is measured');

	# A cover inside the game's own folder is already in the pack.
	write_file("$tree/dos/Smoke Test/cover.png", "png");
	my $inside = { %$nested, art => "$tree/dos/Smoke Test/cover.png" };
	is_deeply([ subs::game_pull_members($inside, $tree) ], [ 'dos/Smoke Test' ],
		'a cover inside the game folder is not packed twice');
}

# --- the catalogue a peer reads ----------------------------------------------
{
	local $ENV{'JAWNOS_GAMES_ROOT'} = "$scratch/members";
	make_path("$scratch/members/gb/media");
	write_file("$scratch/members/gb/Tetris.gb", "rom");
	write_file("$scratch/members/gb/media/Tetris-image.png", "PNGDATA");
	my $catalogue = subs::game_peer_catalogue();
	ok($catalogue->{'ok'}, 'a catalogue is produced');
	ok(length $catalogue->{'signatorial'}, 'it names this machine');
	my ($tetris) = grep { ($_->{'system'} // '') eq 'gb' } @{ $catalogue->{'games'} || [] };
	ok($tetris, 'a game is listed');
	is($tetris->{'size'}, length('rom') + length('PNGDATA'), 'with the size of the copy, the cover included');
	like($tetris->{'art'} // '', qr{^data:image/png;base64,}, 'and its cover inline');
	unlike(Mojo::JSON::encode_json($catalogue), qr{\Q$scratch\E}, 'no path leaves the machine');
}

# --- a pack and its unpack ---------------------------------------------------
{
	my $from = "$scratch/from";
	my $to = "$scratch/to";
	make_path("$from/nes", "$to/nes", "$from/nes/media");
	write_file("$from/nes/Mario.nes", "rom-bytes");
	write_file("$from/nes/media/Mario-image.png", "png");
	local $ENV{'JAWNOS_GAMES_ROOT'} = $from;
	my $id = JawnOS::Games::id_for('nes', 'Mario.nes');
	my $tmp = "$scratch/game.tgz";
	my $packed = subs::game_serve_tar($id, $tmp);
	ok($packed->{'ok'}, 'a game packs for a peer');
	ok(-s $tmp, 'the pack is a file with bytes');
	ok(!subs::game_serve_tar('not-an-id', "$scratch/none.tgz")->{'ok'}, 'an id that is not one is refused');
	ok(!subs::game_serve_tar(('0' x 40), "$scratch/none.tgz")->{'ok'}, 'a game that is not here is refused');

	local $ENV{'JAWNOS_GAMES_ROOT'} = $to;
	my $unpacked = subs::game_unpack($tmp);
	ok($unpacked->{'ok'}, 'the pack unpacks on the other machine');
	ok(-f "$to/nes/Mario.nes", 'the ROM is in the shelf');
	ok(-f "$to/nes/media/Mario-image.png", 'and so is its cover');

	# A pack that carries a link is refused: a later member could be written
	# through it, out of the shelf.
	make_path("$scratch/link/nes");
	symlink('/etc/passwd', "$scratch/link/nes/passwd.link");
	my $bad = "$scratch/link.tgz";
	system('tar', 'czf', $bad, '-C', "$scratch/link", 'nes/passwd.link');
	my $refused = subs::game_unpack($bad);
	ok(!$refused->{'ok'}, 'a pack with a link is refused');
}

# --- the page, the routes and the topic --------------------------------------
my $routes = read_file("$root/lib/JawnOS/Routes/manager_misc9.pm");
for my $row (
	[ 44026, 'get', '/manager/games/peer_library' ],
	[ 44027, 'get', '/manager/games/serve' ],
	[ 44028, 'get', '/manager/games/house' ],
	[ 44029, 'post', '/manager/games/pull' ],
) {
	my ($id, $verb, $path) = @{$row};
	like($routes, qr/\[\s*$id\s*,\s*'$verb'\s*,\s*'\Q$path\E'\s*,\s*'action_$id'\s*\]/,
		"$verb $path is registered");
}

my $controller = read_file("$root/lib/JawnOS/Controller/manager_misc9.pm");
like($controller, qr/sub action_44026/, 'the catalogue action exists');
like($controller, qr/sub action_44027/, 'the serve action exists');
like($controller, qr/sub action_44028/, 'the house action exists');
like($controller, qr/sub action_44029/, 'the pull action exists');
like($controller, qr/&subs::peer_verify\(\$c, \$rm\)/,
	'the peer routes are gated by the peer signature');
like($controller, qr/\$c->on\(finish => sub \{ unlink \$tmp \}\)/,
	'the pack is removed when the response finishes');

my $page = read_file("$root/templates/apps/games.html.ep");
like($page, qr/id="games_house"/, 'the shelf has a house section');
like($page, qr/id="games_house_grid"/, 'with a grid of its own');
like($page, qr/fetch\('\/manager\/games\/house'/, 'the page reads the house catalogue');
like($page, qr/\/manager\/games\/pull/, 'and Get posts a pull');
like($page, qr/house_card/, 'a house card is its own kind');
like($page, qr/game\.art/, 'the cover comes from the catalogue, not a second request');

my $help = read_file("$root/perl/help/topics_people.pl");
like($help, qr/Under From the house/, 'the Games topic describes the section');
like($help, qr/read from the server first and then the other machines/, 'and the order it asks in');

my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader, qr/for qw\(.*\bgame_pull\b.*\)/, 'the loader carries game_pull');
like($loader, qr/for qw\(.*\bpeer_candidates\b.*\)/, 'and peer_candidates');

# The app gate answers a sessionless request with the Gate page. A peer reading
# a shelf, or asking for one game, has no session on the machine that holds it,
# and the catalogue read that page as a peer with no games.
my $hooks = read_file("$root/perl/hooks.pl");
like($hooks, qr{\$path eq '/manager/games/peer_library'}, 'the gate steps aside for the catalogue');
like($hooks, qr{\$path eq '/manager/games/serve'}, 'and for one game');

done_testing();
