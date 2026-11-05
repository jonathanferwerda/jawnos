# tests-for: lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Domain/Name.pm lib/JawnOS/Manager/Part23.pm lib/JawnOS/Manager/Part17.pm scripts/cards_spread_files.pl templates/cards.html.ep templates/cards/tarot.html.ep public/js/manager/manager/12_cards.js
# covers:    the tarot draw lists are one list for the house (device 'all'), a
#            read falls back to a device row until the house row exists, a
#            spread is three deck files not a stored montage, names with spaces
#            are unescaped and percent-encoded, the page renders with every
#            stash key its routes pass, the allowed cards rows (mode, variant,
#            draws) merge while a protected app's house row and the app's local
#            state do not, and a period deal's reply carries the draw it just
#            stored.

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
$cdb->query('create table sync_log (id integer primary key autoincrement, '
	. 'server_time text, signatorial text, tbl text, app text, uuid text, '
	. 'scope text, additional text, ost text)');
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

# --------------------------------------------------- the draws ride the sync
# `cards` is a protected app, so its banks and file-browser state stay local,
# but the tarot mode/variant and the draw lists are house facts. A draw list is
# a house-wide row (device 'all'), and the merge must keep it one or a peer's
# draws never arrive.
my $card_part17 = root() . '/lib/JawnOS/Manager/Part17.pm';
require $card_part17;
my $sync_device = &subs::device_setter();

sub merge_peer_setting {
	my ($row) = @_;
	my $served = 0;
	my $next = sub { return $served++ ? undef : $row; };
	my $ctx = {
		configuration      => {},
		misc_settings      => {},
		device             => $sync_device,
		deletions          => [],
		universal_settings => {},
		updateables        => [],
		sync_job           => undef,
		auuid              => 'test-auuid',
		colour             => '#000000',
	};
	return Manager::merge_table_rows($ctx, 'settings', $next, 1, 1, 1);
}

my $peer_time = $now + 2000;
merge_peer_setting({
	uuid => 'cards-day-peer', app => 'cards', setting => 'day', device => 'all',
	value => $json->encode([ { title => 'The Star', timestamp => 7 } ]),
	timestamp => $peer_time, server_time => $peer_time,
});
my $peer_house = $cdb->query("select value, device from settings where app='cards' and setting='day'")->hashes;
is(scalar @{$peer_house}, 1, 'a house-wide cards draw from a peer merges');
is($peer_house->[0]->{'device'}, 'all', 'and stays a house row, not a local device copy');
is_deeply(&subs::cards_list('day'), [ { title => 'The Star', timestamp => 7 } ],
	'so every machine reads the draw from the house list');

# The tarot mode and variant are the cards choices that do sync; they join
# this device's own row, the way every other per-device setting does.
merge_peer_setting({
	uuid => 'cards-mode-peer', app => 'cards', setting => 'mode', device => $sync_device,
	value => 'day', timestamp => $peer_time + 1, server_time => $peer_time + 1,
});
my $peer_mode = $cdb->query("select value, device from settings where app='cards' and setting='mode'")->hashes;
is(scalar @{$peer_mode}, 1, 'the tarot mode rides the sync');
is($peer_mode->[0]->{'device'}, $sync_device, 'stored on this device, so setting_grabber reads it');

merge_peer_setting({
	uuid => 'cards-variant-peer', app => 'cards', setting => 'variant', device => $sync_device,
	value => 'solitaire', timestamp => $peer_time + 2, server_time => $peer_time + 2,
});
my $peer_variant = $cdb->query("select value from settings where app='cards' and setting='variant'")->hashes;
is($peer_variant->[0]->{'value'}, 'solitaire', 'and so does the chosen deck');

# The app's local state still never merges, even as a house row, and neither
# does a protected app's house row.
merge_peer_setting({
	uuid => 'cards-errors-peer', app => 'cards', setting => 'errors', device => 'all',
	value => 'peer errors', timestamp => $peer_time + 3, server_time => $peer_time + 3,
});
my $peer_errors = $cdb->query("select 1 from settings where app='cards' and setting='errors'")->hashes;
is(scalar @{$peer_errors}, 0, 'local churn stays out even when it claims to be a house row');

merge_peer_setting({
	uuid => 'cards-bank-peer', app => 'cards', setting => 'solitaire_bank', device => $sync_device,
	value => '999', timestamp => $peer_time + 4, server_time => $peer_time + 4,
});
my $peer_bank = $cdb->query("select 1 from settings where app='cards' and setting='solitaire_bank'")->hashes;
is(scalar @{$peer_bank}, 0, 'the game banks stay machine-local');

merge_peer_setting({
	uuid => 'pres-qanight-peer', app => '__president', setting => 'qa_nightly_device', device => 'all',
	value => 'peer', timestamp => $peer_time + 5, server_time => $peer_time + 5,
});
my $pres_row = $cdb->query("select 1 from settings where app='__president' and setting='qa_nightly_device'")->hashes;
is(scalar @{$pres_row}, 0, "a protected app's house row still does not carry over");

# ------------------------------------------------- a deal refreshes the rail
# The day/week/month/year writer stores the new draw itself, after the route has
# read the history it renders. It must read that list again, or the draw appears
# in the rail only when the person clicks a second time.
&subs::cards_list_write('day', [ { title => 'The Moon', timestamp => $now + 3000 } ]);
my $cards_controller = root() . '/lib/JawnOS/Controller/manager_misc9.pm';
require $cards_controller;

my $captured;
{
	package CardsTestController;
	sub new { bless {}, shift }
	sub param {
		my ($self, $key) = @_;
		return 'new' if $key eq 'new_card';
		return '';
	}
	sub render_to_string { return '<div id="deck_history"></div>'; }
	sub render {
		my ($self, @args) = @_;
		$captured = { @args };
		return 1;
	}
}
{
	no warnings 'redefine';
	local *Manager::card_of_the_day = sub {
		&subs::cards_list_write('day', [
			{ title => 'The Star', timestamp => $now + 4000 },
			@{ &subs::cards_list('day') },
		]);
		return 'the star.png';
	};
	local *subs::inventory_grabber = sub { return {}; };
	Manager::action_28170(CardsTestController->new());
}
my $reply = $captured->{'json'};
ok(ref $reply eq 'HASH', 'the deal answered with a JSON reply');
is($reply->{'history'}->[0]->{'title'}, 'The Star',
	'the deal reply carries the draw it just stored, in the same click');
is($reply->{'history'}->[1]->{'title'}, 'The Moon', 'with the older draws behind it');

done_testing();
