# tests-for: lib/JawnOS/Controller/manager_misc9.pm scripts/cards_spread_files.pl templates/cards.html.ep templates/cards/tarot.html.ep public/js/manager/manager/12_cards.js
# covers:    a spread is three deck files, not a stored montage. The history
#            keeps the names, the template draws them side by side from
#            /images/cards/, the reply carries the names, and the migration
#            takes an old data-URI montage out of the row while leaving an
#            entry whose card is no longer in the deck alone.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file);
use Mojo::Template;
use DBI;
use JSON::PP ();

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
		history => [],
		mode => 'spread',
		variant => 'solitaire',
		bank => 120,
		blackjack_bank => 500,
	});
};
is($@, '', 'the cards page renders with the stash its routes pass');
like($rendered // '', qr/id="cards_blackjack"/, 'and the blackjack pane is on the page');

done_testing();
