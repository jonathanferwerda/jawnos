# tests-for: lib/JawnOS/Controller/manager_misc9.pm scripts/cards_spread_files.pl templates/cards.html.ep
# covers:    a spread is three deck files, not a stored montage. The history
#            keeps the names, the template draws them from /images/cards/, and
#            the migration takes an old data-URI montage out of the row while
#            leaving an entry whose card is no longer in the deck alone.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file);
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
like($template, qr/ref \$his->\{'cards'\} eq 'ARRAY'/, 'the history draws a spread from its file names');

my $controller = read_file("$FindBin::Bin/../lib/JawnOS/Controller/manager_misc9.pm");
like($controller, qr/if \(ref \$spread_cards eq 'ARRAY'\) \{ \$entry\{'cards'\} = \$spread_cards \}/,
	'a new spread stores names, not a montage');
like($controller, qr/sub card_spread_stream/, 'the montage is built for the reply only');

done_testing();
