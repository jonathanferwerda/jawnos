# tests-for: lib/JawnOS/GameMapping.pm lib/JawnOS/Controller/manager_mapping.pm lib/JawnOS/Routes/manager_mapping.pm lib/JawnOS/Routes.pm templates/controller/mapping.html.ep perl/help/topics_people.pl
# covers:    The per-console control map: the physical button indices, the
#            Nintendo 64 GoldenEye default, the RetroArch remap it writes
#            (atomically), the two routes and their actions, the picture page
#            and its arm/assign script, and the controller help topic.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use File::Spec;
use Mojo::JSON qw(decode_json);
use RepoSource;
use JawnOS::GameMapping;

my $root = repo_root();

# --- the profile table --------------------------------------------------------
my %systems = map { $_->{'key'} => $_ } @{ JawnOS::GameMapping::system_list() };
ok($systems{'n64'}, 'Nintendo 64 is offered');
ok($systems{'psx'}, 'PlayStation is offered');
is($systems{'n64'}{'core'}, 'Mupen64Plus-Next', 'N64 names its core');
is($systems{'psx'}{'core'}, 'PCSX-ReARMed', 'PlayStation names its core');
ok(JawnOS::GameMapping::resolve_system('N64'), 'the system key is case-insensitive');
ok(!defined JawnOS::GameMapping::resolve_system('dreamcast'), 'an unknown system does not resolve');

# --- the physical indices the daemon reports ---------------------------------
is(JawnOS::GameMapping::physical_index('b'), 0, 'B is physical 0');
is(JawnOS::GameMapping::physical_index('a'), 1, 'A is physical 1');
is(JawnOS::GameMapping::physical_index('x'), 2, 'X is physical 2');
is(JawnOS::GameMapping::physical_index('y'), 3, 'Y is physical 3');
is(JawnOS::GameMapping::physical_index('select'), 4, 'Select is physical 4');
is(JawnOS::GameMapping::physical_index('start'), 5, 'Start is physical 5');
is(JawnOS::GameMapping::physical_index('dpad_up'), 6, 'D-pad Up is physical 6');
is(JawnOS::GameMapping::physical_index('dpad_down'), 7, 'D-pad Down is physical 7');
is(JawnOS::GameMapping::physical_index('dpad_left'), 8, 'D-pad Left is physical 8');
is(JawnOS::GameMapping::physical_index('dpad_right'), 9, 'D-pad Right is physical 9');
is(JawnOS::GameMapping::physical_index('l'), 10, 'L is physical 10');
is(JawnOS::GameMapping::physical_index('r'), 11, 'R is physical 11');
is(JawnOS::GameMapping::physical_index('l2'), 12, 'L2 is physical 12');
is(JawnOS::GameMapping::physical_index('r2'), 13, 'R2 is physical 13');

# --- the N64 default the person asked for ------------------------------------
my $n64 = JawnOS::GameMapping::default_mapping('n64');
is_deeply($n64, {
	a => 'c_down', b => 'c_right', x => 'c_up', y => 'c_left',
	r2 => 'a', l2 => 'b', r => 'z', l => 'r', start => 'start',
	dpad_up => 'dpad_up', dpad_down => 'dpad_down',
	dpad_left => 'dpad_left', dpad_right => 'dpad_right',
}, 'the N64 default is the GoldenEye scheme');

is_deeply(
	JawnOS::GameMapping::normalize_mapping('n64', { a => 'c_down', b => 'c_down', zzz => 'a', x => 'nope' }),
	{ b => 'c_down' },
	'unknown names are dropped and one console button keeps the first physical'
);
is_deeply(JawnOS::GameMapping::load_mapping('n64', '{}'), {}, 'an empty saved map stays empty');
is_deeply(JawnOS::GameMapping::load_mapping('n64', 'not json'), $n64, 'invalid JSON falls back to the default');

# --- the Remap -----------------------------------------------------------------
my $tmp = tempdir(CLEANUP => 1);
local $ENV{'JAWNOS_MAPPING_DIR'} = $tmp;
my $path = JawnOS::GameMapping::remap_path('n64');
is($path, File::Spec->catfile($tmp, 'Mupen64Plus-Next.rmp'), 'the remap lands under the RetroArch remaps folder');

my $written = JawnOS::GameMapping::write_remap('n64', $n64);
ok($written->{'ok'}, 'the N64 remap is written');
ok(-f $path, 'the file exists');
my %line;
for my $row (split /\n/, read_file($path)) {
	if ($row =~ /^input_player1_([a-z0-9]+)_btn = "(\d+)"$/) {
		$line{$1} = $2;
	}
}
is($line{'a'}, '1', 'RetroPad A is the physical A face button: N64 C-Down');
is($line{'x'}, '2', 'RetroPad X is the physical X face button: N64 C-Up');
is($line{'l'}, '3', 'RetroPad L is the physical Y face button: N64 C-Left');
is($line{'r'}, '0', 'RetroPad R is the physical B face button: N64 C-Right');
is($line{'b'}, '13', 'N64 A fires from the physical right trigger (R2)');
is($line{'y'}, '12', 'N64 B uses from the physical left trigger (L2)');
is($line{'l2'}, '11', 'N64 Z is the physical R shoulder');
is($line{'r2'}, '10', 'N64 R is the physical L shoulder');
is($line{'start'}, '5', 'N64 Start is the physical Start');
is($line{'up'}, '6', 'the D-pad Up is physical 6');
is($line{'down'}, '7', 'the D-pad Down is physical 7');
is($line{'left'}, '8', 'the D-pad Left is physical 8');
is($line{'right'}, '9', 'the D-pad Right is physical 9');
unlike(join("\n", keys %line), qr/select/, 'N64 has no Select and the remap omits it');

# --- the write is atomic ------------------------------------------------------
my $before = read_file($path);
my $changed = { %$n64 };
delete $changed->{'a'};
$changed->{'l'} = 'c_down';
my $seen;
my $second = JawnOS::GameMapping::write_remap('n64', $changed, {
	before_rename => sub {
		my ($temp, $target) = @_;
		$seen = { temp => $temp, target => $target, previous => scalar read_file($target), staged => -f $temp };
	},
});
ok($seen && $seen->{'staged'}, 'the new remap is staged in a temporary file');
is($seen->{'previous'}, $before, 'the old remap is untouched until the rename');
is(scalar read_file($path), $second->{'text'}, 'the rename replaces the whole file at once');
is(scalar(grep { /\.tmp$/ } (glob("$tmp/*"), glob("$tmp/.*"))), 0, 'no temporary file is left behind');

# --- a failure is reported, not thrown ---------------------------------------
my $unknown = JawnOS::GameMapping::write_remap('dreamcast', {});
ok(!$unknown->{'ok'}, 'an unknown system does not write a remap');
like($unknown->{'error'}, qr/Unknown system/, 'and says why');
ok(!defined JawnOS::GameMapping::normalize_mapping('dreamcast', {}), 'an unknown system has no mapping');

# --- the routes and their actions ---------------------------------------------
my $routes = read_file("$root/lib/JawnOS/Routes/manager_mapping.pm");
like($routes, qr/\[\s*44100\s*,\s*'get'\s*,\s*'\/manager\/games\/mapping'\s*,\s*'action_44100'\s*\]/,
	'GET /manager/games/mapping is registered');
like($routes, qr/\[\s*44101\s*,\s*'post'\s*,\s*'\/manager\/games\/mapping'\s*,\s*'action_44101'\s*\]/,
	'POST /manager/games/mapping is registered');

require "$root/lib/JawnOS/Routes.pm";
my %named = map { $_ => 1 } @JawnOS::Routes::NAMES;
ok($named{'manager_mapping'}, 'the route module is in @NAMES');

my $controller = read_file("$root/lib/JawnOS/Controller/manager_mapping.pm");
my ($get) = $controller =~ /(sub action_44100\b.*?\n\})/s;
my ($post) = $controller =~ /(sub action_44101\b.*?\n\})/s;
ok($get, 'action_44100 exists');
ok($post, 'action_44101 exists');
like($get, qr/template => 'controller\/mapping'/, 'the page renders the mapping template');
like($get, qr/&Manager::window_maker\(/, 'the page is served through the window maker');
like($get, qr/&subs::setting_grabber\(\{ app => 'games', setting => "mapping_\$system" \}\)/,
	'it reads the per-device mapping setting');
like($post, qr/&subs::setting_setter\(/, 'a save writes the mapping setting');
like($post, qr/&JawnOS::GameMapping::write_remap\(/, 'a save writes the RetroArch remap');
like($post, qr/decode_json/, 'the posted mapping is decoded');

# --- the picture page ---------------------------------------------------------
my $page = read_file("$root/templates/controller/mapping.html.ep");
like($page, qr/id="mapping_gou"/, 'the Gou panel is drawn');
like($page, qr/id="mapping_console"/, 'the console panel is drawn');
like($page, qr/id="gou_key_<%=\s*\$token\s*%>"/, 'the Gou face buttons have stable ids');
like($page, qr/token => 'r2'/, 'the Gou triggers have stable ids');
like($page, qr/id="console_key_<%= \$token %>"/, 'the console buttons have stable ids');
like($page, qr/data-physical="<%= \$token %>"/, 'each Gou button carries its physical token');
like($page, qr/data-console="<%= \$token %>"/, 'each console button carries its console token');
like($page, qr/id="mapping_system"/, 'the system picker is present');
like($page, qr/fetch\('\/manager\/games\/mapping'/, 'Save posts to the mapping route');
like($page, qr/id="mapping_note"/, 'the page has a note for the save result');
like($page, qr/aria-pressed/, 'the armed button is marked with aria-pressed');
like($page, qr/function arm\(/, 'the arm helper exists');
like($page, qr/function assign\(/, 'the assign helper exists');
like($page, qr/data-clear=/, 'each console row has a Clear button');
like($page, qr/Reset to default/, 'the page offers Reset to default');
unlike($page, qr/cursor:\s*(?:pointer|default|text|grab|move)\b/, 'no literal cursor value is used');

# --- the Guide ----------------------------------------------------------------
my $help = read_file("$root/perl/help/topics_people.pl");
like($help, qr{templates/controller/mapping\.html\.ep}, 'the controller topic claims the mapping page');
like($help, qr/Controller map/, 'the controller topic names the mapping page');

done_testing();
