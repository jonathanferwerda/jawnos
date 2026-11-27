# tests-for: lib/JawnOS/Games.pm lib/JawnOS/Domain/Games.pm
# covers:    The suffix-to-system map a dropped game is filed by, and the cheap
#            shelf revision the Games page polls so a new ROM appears by itself.

use strict;
use warnings;

use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

use lib "$Bin/../lib";
require JawnOS::Games;

is(JawnOS::Games::system_for_paths('', ['Tetris (JUE) (V1.1) [!].gb']), 'gb', 'a .gb is a Game Boy game');
is(JawnOS::Games::system_for_paths('', ['Tetris.GB']), 'gb', 'the suffix is read case-insensitively');
is(JawnOS::Games::system_for_paths('', ['Game.smc']), 'snes', 'a .smc is a SNES game');
is(JawnOS::Games::system_for_paths('', ['Game.z64']), 'n64', 'a .z64 is an N64 game');
is(JawnOS::Games::system_for_paths('', ['GAME.EXE']), 'dos', 'a .exe is a DOS game');
is(JawnOS::Games::system_for_paths('', ['Game.gdi']), 'dreamcast', 'a .gdi is a Dreamcast game');
is(JawnOS::Games::system_for_paths('', ['Game.cso']), 'psp', 'a .cso is a PSP game');

is(JawnOS::Games::system_for_paths('dos', ['TEST.COM', 'SMOKE.conf']), 'dos', 'a folder named after a system wins');
is(JawnOS::Games::system_for_paths('psx', ['Game.iso']), 'psx', 'a folder name answers an ambiguous disc image');
is(JawnOS::Games::system_for_paths('', ['Game.iso']), undef, 'a bare .iso names no single system');
is(JawnOS::Games::system_for_paths('', ['Game.zip']), undef, 'a zip names no single system');
is(JawnOS::Games::system_for_paths('', ['Game.cue']), undef, 'a cue names no single system');

is(JawnOS::Games::system_for_paths('', ['a.gb', 'b.nes']), undef, 'a tie is not a guess');
is(JawnOS::Games::system_for_paths('', ['a.gb', 'b.gbc']), undef, 'two systems tie');
is(JawnOS::Games::system_for_paths('', ['a.gb', 'b.gb']), 'gb', 'two of one system agree');
is(JawnOS::Games::system_for_paths('', []), undef, 'nothing is no system');

my $root = tempdir(CLEANUP => 1);
my $first = JawnOS::Games::revision($root);
make_path("$root/gb");
my $second = JawnOS::Games::revision($root);
isnt($second, $first, 'adding a system folder moves the revision');
my $later = time + 5;
utime $later, $later, "$root/gb";
utime $later, $later, $root;
my $third = JawnOS::Games::revision($root);
isnt($third, $second, 'a touched system folder moves the revision');

done_testing();
