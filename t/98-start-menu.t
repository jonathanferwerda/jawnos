# tests-for: templates/start_menu/start_menu.html.ep public/js/manager/manager/05_start_menu.js lib/JawnOS/Manager/Part11.pm
# covers:    the running list lists open sessions only, Internet is the one web entry
#            point, and every catalog-driven app label reads as a capitalised name

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use DBI;
use File::Slurp qw(read_file);
use Mojo::Template;
use JawnOSTest;

# The running list is built straight in the template. It used to take every
# `start`/`record` row, so a row a stop had already sealed (type=start,
# stop_seen=yes - the shape a stop/start race left behind) stayed on the menu
# forever. The query under test is lifted from the template itself and run
# against throwaway fixtures, so it is the shipped SQL that is pinned, not a
# copy. Nothing here touches the live database.

my $template = read_file(root() . '/templates/start_menu/start_menu.html.ep');

# The Web app is a component of Internet now; the start menu offers Internet
# alone, so two icons cannot open the same pages from different places.
unlike($template, qr/id="web_toggle"/, 'no separate Web icon in the start menu');
like($template, qr/id="internet_toggle"/, 'Internet is the one web entry point');
my $menu_js = read_file(root() . '/public/js/manager/manager/05_start_menu.js');
unlike($menu_js, qr/web_toggle/, 'the start menu no longer maps a Web icon');

my ($run_sql) = $template =~ /if \(\$menu eq 'run'\) \{\s*\$query = &subs::db_query\('([^']+)'/s;
ok(defined $run_sql, 'the run list has its own query');

like($run_sql, qr/\(\s*type=\?\s+or\s+type=\?\s*\)/,
	'the run list looks at start and record sessions');
like($run_sql, qr/stop_seen\s+is\s+null/,
	'the run list only lists a session that no stop has sealed');

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
	{ RaiseError => 1, PrintError => 0, AutoCommit => 1 });
$dbh->do('create table appointments (app text, type text, timestamp integer, stop_seen text)');

my $now = 1_790_000_000_000;
my $insert = $dbh->prepare(
	'insert into appointments (app, type, timestamp, stop_seen) values (?, ?, ?, ?)');

$insert->execute('brushing', 'start', $now - 60_000, undef);   # running now
$insert->execute('toothpaste', 'start', $now - 50_000, 'yes'); # a stop sealed it, the row still says start
$insert->execute('shower', 'record', $now - 40_000, 'yes');    # a sealed recording, same shape
$insert->execute('later', 'start', $now + 60_000, undef);      # begins in the future
$insert->execute('shower', 'stop', $now - 30_000, 'yes');      # an ordinary stop row
$insert->execute('toothpaste', 'usual', $now - 20_000, undef); # the usual template is not a session

my $rows = $dbh->selectall_arrayref($run_sql, undef, 'start', 'record', $now);
my @apps = map { $_->[0] } @{ $rows || [] };

is_deeply(\@apps, ['brushing'],
	'only the session still running is listed; a sealed start row is not');


like($template, qr/id="keyboard_toggle"/, 'the keyboard is a start-menu app');
like($template, qr/id="calculator_toggle"/, 'and the calculator');

# Every app label drawn through the core catalog must read as a label. A key
# with no entry in language.pl falls back to printing itself, which is how the
# keyboard icon stayed lowercase beside Clock and Sound. The catalogue is
# loaded by JawnOSTest; the English value is the one the fallback shows.
my @lang_hints = $template =~ /hint="<%=\s*&subs::lang\('([^']+)'\)\s*%>"/g;
ok(scalar(@lang_hints), 'the start menu draws app labels through the core catalog');
for my $key (@lang_hints) {
	my $label = language::translate('en', $key);
	isnt($label, $key, "the $key label has a catalog entry");
	like($label, qr/^[A-Z]/, "the $key label starts with a capital letter");
}

like($menu_js, qr/\.start_menu_toggle_copy/, 'a start button copied into an added bar answers');
like($menu_js, qr/closest\('#start_menu_toggle, \.start_menu_toggle_copy'\)/,
	'a press on the copy is not mistaken for an outside press');

# A desk and a phone have no DOSBox, so the games shelf carries the browser
# player's rows. The handheld keeps its native shelf, and the server sends an
# empty list there.
like($template, qr/dos_game_toggle/, 'the games shelf draws a row per DOS game');
like($template, qr/data-game="<%= \$dos_game->\{'id'\} %>"/,
	'the row carries the card id the player route resolves');
like($template, qr/manager\/games\/art\?id=/, 'and the card picture when the shelf has one');
like($menu_js, qr/\.dos_game_toggle/, 'a row press is the player opener');
like($menu_js, qr{url: '/manager/games/play'}, 'which asks the player route for the window');

# The template is rendered with `vars => 1`, so every name it uses has to be a
# key in the stash the caller passes; a missing one fails compilation and the
# route answers 500. /apps/start put the device in its stash, but the JSON
# route (/manager/start_menu) did not, and every refresh of its menu failed.
# Read the maker's own call so the test follows the names it actually hands in.
my $part11 = read_file(root() . '/lib/JawnOS/Manager/Part11.pm');
my ($maker_args) = $part11 =~ /render_to_string\(\s*template => 'start_menu\/start_menu',\s*(.*?)\n\t\);/s;
ok(defined $maker_args, 'the maker\'s start-menu render is readable');
my @stash_names = $maker_args =~ /(?:^|,)\s*(\w+)\s*=>/g;
ok(grep({ $_ eq 'device' } @stash_names), 'the maker hands the template a device');

my %stash = map {
	$_ => ($_ eq 'menu' ? 'app' : $_ eq 'device' ? 'computer' : ($_ eq 'config' || $_ eq 'parking_lot') ? {} : [])
} @stash_names;
local $SIG{'__WARN__'} = sub { };
my $mt = Mojo::Template->new(
	auto_escape => 1,
	vars => 1,
	# The renderer defines these in the template namespace; the early return
	# makes this a compile check, not an attempt to run the menu.
	prepend => 'sub _C { } sub include { } my $self = my $c = _C; return "compiled";'
);
my $rendered = eval { $mt->render($template, \%stash) };
my $error = ref $rendered ? "$rendered" : ($@ // '');
unlike($error, qr/Global symbol "\$(\w+)"/,
	'every name the template uses is in the stash the maker passes');

# The JSON route calls the maker with only the controller; the games rows are
# the maker's job there. The signature used to make that second argument
# mandatory, so the authenticated route died before the template was reached
# with "Too few arguments for subroutine 'Manager::start_menu_maker'". Call it
# the way the route does and keep every other read a stub.
require(root() . '/lib/JawnOS/Manager/Part11.pm');
{ package FakeStartMenuC;
	sub param { return undef }
	sub stash { return undef }
	sub render_to_string {
		my ($self, %args) = @_;
		$self->{'args'} = \%args;
		return '<div id="start_menu"></div>';
	}
}
{ package FakeStartMenuRows;
	sub new { return bless { rows => [] }, shift }
	sub hashes { return $_[0]->{'rows'} }
}
my $c = bless {}, 'FakeStartMenuC';
my $menu = do {
	no warnings 'redefine';
	local *help::welcome_seen = sub { 1 };
	local *Manager::parking_lot_grabber = sub { {} };
	local *Manager::start_menu_recent = sub { [] };
	local *Manager::start_menu_hidden_apps = sub { [] };
	local *subs::config_reader = sub { {} };
	local *subs::db_select = sub { FakeStartMenuRows->new };
	local *subs::game_menu_entries = sub { [] };
	local *subs::rightNow = sub { 123 };
	local *subs::icon_set = sub { undef };
	eval { Manager::start_menu_maker($c) };
};
is($@, '', 'the maker runs when its caller passes only the controller');
ok(ref $menu eq 'HASH' && ($menu->{'menu'} // '') eq 'app', 'and returns the app menu');
is($c->{'args'}->{'device'}, 'computer', 'with the config device the template needs');

done_testing();
