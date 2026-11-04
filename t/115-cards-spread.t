# tests-for: lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Domain/Name.pm lib/JawnOS/Manager/Part23.pm scripts/cards_spread_files.pl templates/cards.html.ep templates/cards/tarot.html.ep public/js/manager/manager/12_cards.js
# covers:    the tarot draw lists are one list for the house (device 'all'), a
#            read falls back to a device row until the house row exists, a
#            spread is three deck files not a stored montage, names with spaces
#            are unescaped and percent-encoded, and the page renders with every
#            stash key its routes pass.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../lib", 't/lib';
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Slurp qw(read_file);
use DBI;
use JSON::PP ();
use Mojo::Template;
use Mojo::SQLite;
use JawnOSTest;

my $json = JSON::PP->new->utf8;
my $dir = tempdir(CLEANUP => 1);
my $db = "$dir/cards.db";
my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0 });
$dbh->do(q{create table settings (uuid VARCHAR(255), app LONGTEXT, setting VARCHAR(255),
	device VARCHAR(10), value LONGTEXT, server_time VARCHAR(255), ost VARCHAR(25))});
my $history = [
	{ title => 'The Fool<br> The Star<br> The Moon<br> ', timestamp => 1000,
	  stream => 'data:image/png;base64,AAAA' },
	{ title => 'Not A Real Card<br> The Fool<br> ', timestamp => 900,
	  stream => 'data:image/png;base64,BBBB' },
];
my $insert = $dbh->prepare('insert into settings (uuid, app, setting, device, value, server_time) values (?,?,?,?,?,?)');
$insert->execute('row1', 'cards', 'spread', 'computer', $json->encode($history), '1000');
$insert->execute('row2', 'cards', 'free', 'computer', $json->encode([ { title => 'keep', stream => 'data:image/png;base64,CCCC' } ]), '1000');
$insert->finish;
$dbh->disconnect;

my $script = "$FindBin::Bin/../scripts/cards_spread_files.pl";
my $out = qx{$^X "$script" --database="$db" --apply --no-backup 2>&1};
my $rc = $? >> 8;
is($rc, 0, 'the migration runs against a database') or diag($out);

$dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0 });
my ($value) = $dbh->selectrow_array("select value from settings where uuid = 'row1'");
my $spread = $json->decode($value);
is_deeply($spread->[0]->{'cards'}, [ 'the fool.png', 'the star.png', 'the moon.png' ],
	'a spread keeps the three deck file names');
ok(!exists $spread->[0]->{'stream'}, 'the stored montage is gone');
is($spread->[1]->{'stream'}, 'data:image/png;base64,BBBB',
	'an entry with a card that left the deck keeps its picture');
ok(!exists $spread->[1]->{'cards'}, 'and gains no names');
my ($free) = $dbh->selectrow_array("select value from settings where uuid = 'row2'");
is_deeply($json->decode($free), [ { title => 'keep', stream => 'data:image/png;base64,CCCC' } ],
	'other card modes are untouched');
$dbh->disconnect;

my $template = read_file("$FindBin::Bin/../templates/cards.html.ep");
my $tarot = read_file("$FindBin::Bin/../templates/cards/tarot.html.ep");
my $js = read_file("$FindBin::Bin/../public/js/manager/manager/12_cards.js");
like($tarot, qr/ref \$his->\{'cards'\} eq 'ARRAY'/, 'the history draws a spread from its file names');
like($tarot, qr/id="deck_spread"/, 'the spread has a row of its own');
like($js, qr/function cardsShowSpread/, 'the browser draws the three pictures side by side');
like($js, qr/response\.cards/, 'from the names the reply carries');
like($template, qr/cards\/tarot/, 'the page includes the tarot pane');

my $controller = read_file("$FindBin::Bin/../lib/JawnOS/Controller/manager_misc9.pm");
like($controller, qr/if \(ref \$spread_cards eq 'ARRAY'\) \{ \$entry\{'cards'\} = \$spread_cards \}/,
	'a new spread stores names, not a montage');
like($controller, qr/cards => \$spread_cards/, 'and the reply carries the three names');
unlike($controller, qr/card_spread_stream/, 'no montage is built for the spread');
unlike($controller, qr/&subs::terminal_name/, 'a deck file name is not shell-escaped on the way into a URL');
like($controller, qr/&subs::cards_list\(/, 'a draw list comes from the house list');
like($controller, qr/&subs::cards_list_write\(/, 'and a draw writes it back to the house row');

# A template is compiled strictly with the stash keys it is given, so a render
# that leaves one out is a 500 on that route, not a missing value. The deal
# route re-renders the whole page for its history rail, and it used to omit the
# deck choice and the bank: every tarot deal answered 500.
my @card_renders;
while ($controller =~ /render_to_string\((.*?)\);/gs) {
	my $call = $1;
	push @card_renders, $call if $call =~ /template\s*=>\s*'cards'/;
}
ok(scalar @card_renders >= 2, 'the cards page is rendered from more than one route');
for my $call (@card_renders) {
	like($call, qr/variant\s*=>/, 'every cards render passes variant');
	like($call, qr/bank\s*=>/, 'every cards render passes bank');
	like($call, qr/blackjack_bank\s*=>/, 'every cards render passes blackjack_bank');
}

# The static check above names the three keys the page needs today; this renders
# the real page with a stand-in for the include helper, so a key added to a
# partial without being passed is a red test rather than a 500.
my $mt = Mojo::Template->new(vars => 1, namespace => 'CardsRenderTest');
my $read_template = sub {
	my ($name) = @_;
	return read_file("$FindBin::Bin/../templates/$name.html.ep");
};
{
	no warnings 'redefine';
	*CardsRenderTest::include = sub {
		my ($name, @pairs) = @_;
		my %stash = @pairs;
		my $src = $read_template->($name);
		return $mt->render($src, \%stash);
	};
}
my $rendered = eval {
	my $src = $read_template->('cards');
	$mt->render($src, {
		history => [ {
			title => 'The Fool \x{b7} The Star \x{b7} The Moon',
			timestamp => 1,
			cards => [ 'the fool.png', 'the star.png', 'the moon.png' ],
		} ],
		mode => 'spread',
		variant => 'solitaire',
		bank => 120,
		blackjack_bank => 500,
	});
};
is($@, '', 'the cards page renders with the stash its routes pass');
like($rendered // '', qr/id="cards_blackjack"/, 'and the blackjack pane is on the page');
like($rendered // '', qr{src="/images/cards/the%20fool\.png"}, 'a card name with a space is percent-encoded');
like($rendered // '', qr{data-cards="the fool\.png\|the star\.png\|the moon\.png"}, 'the history keeps the names for the browser');

# ---------------------------------------------------------- one list per house
# The draw lists live on the settings row every machine reads (device 'all'). A
# house from before that still has only a device row; it is read until a draw
# writes the house row, and the escaped names an early build left are repaired.
my ($bfh, $carddb) = tempfile('jawnos-cards-house-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $bfh;
my $csql = Mojo::SQLite->new('sqlite:' . $carddb);
my $cdb = $csql->db;
$cdb->query('create table settings (setting text, value text, timestamp text, '
	. 'id integer primary key autoincrement, app text, server_time text, device text, '
	. 'browser_tab_id text, uuid text, ost text, subsetting text)');
my @cst = stat($carddb);
$gb::database_holder = {
	server_time => &subs::rightNow(),
	database => $carddb,
	db => $cdb,
	dbh => $cdb->dbh,
	sql => $csql,
	pid => $$,
	dev => $cst[0],
	ino => $cst[1],
};
$subs::say_quiet = 1;
my $now = &subs::rightNow();

my $legacy = $json->encode([ { title => 'The Fool', timestamp => 5, cards => [ 'the\\ fool.png' ] } ]);
&subs::db_insert('settings', {
	app => 'cards', setting => 'free', value => $legacy, device => &subs::device_setter(),
	timestamp => $now, server_time => $now, uuid => 'cards-device-row',
});
my $list = &subs::cards_list('free');
is(scalar @{$list}, 1, 'a device list is read until the house has one');
is($list->[0]->{'cards'}[0], 'the fool.png', 'and its escaped names are repaired');

my $laptop = $json->encode([ { title => 'The Moon', timestamp => 7 } ]);
&subs::db_insert('settings', {
	app => 'cards', setting => 'free', value => $laptop, device => 'laptop',
	timestamp => $now, server_time => $now, uuid => 'cards-laptop-row',
});

&subs::cards_list_write('free', [ { title => 'The Star', timestamp => 6 } ]);
my $house = $cdb->query("select value from settings where app='cards' and setting='free' and device='all'")->hashes;
is(scalar @{$house}, 1, 'a draw write makes the house row');
is_deeply(&subs::cards_list('free'), [
	{ title => 'The Moon', timestamp => 7 },
	{ title => 'The Star', timestamp => 6 },
	{ title => 'The Fool', timestamp => 5, cards => [ 'the fool.png' ] },
], 'and every device reads one house list, newest first, with no draw lost');

done_testing();
