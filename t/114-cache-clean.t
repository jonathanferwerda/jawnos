# tests-for: perl/Music.pl scripts/cache_clean.pl
# covers:    a music window shell is keyed by the code revision and the queue,
#            so only the shell just written is reachable. The cleanup script
#            deletes the shells left by earlier revisions and keeps the live
#            one, and the music route drops its other shells when it writes.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file);
use DBI;

my $version = read_file("$FindBin::Bin/../VERSION");
$version =~ s/\s+$//;

my $dir = tempdir(CLEANUP => 1);
my $db = "$dir/cache.db";
my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0 });
$dbh->do(q{create table cache (timestamp VARCHAR(255), server_time VARCHAR(255), app LONGTEXT,
	context VARCHAR(255), warranty VARCHAR(25), subcontext VARCHAR(255), device VARCHAR(10),
	uuid VARCHAR(255), ost VARCHAR(25), data BLOB)});
my $insert = $dbh->prepare(q{insert into cache (app, context, subcontext, uuid, warranty, data) values (?,?,?,?,?,?)});
$insert->execute('music', 'content', "$version-locked", 'live', '9999999999999', 'live-shell');
$insert->execute('music', 'content', '0.0.1-locked', 'dead', '9999999999999', 'dead-shell');
$insert->execute('music', 'content', '0.0.1-locked-q123', 'oldqueue', '9999999999999', 'dead-shell-2');
$insert->execute('music', 'loudness', 'loudness-abc', 'loud', '9999999999999', 'loudness');
$insert->execute('music', 'player', undef, 'player', '9999999999999', 'player');
$insert->finish;
$dbh->disconnect;

my $script = "$FindBin::Bin/../scripts/cache_clean.pl";
my $out = qx{$^X "$script" --database="$db" --apply --no-backup 2>&1};
my $rc = $? >> 8;
is($rc, 0, 'the cleanup script runs against a database') or diag($out);

$dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0 });
my @left = map { $_->[0] } @{ $dbh->selectall_arrayref('select uuid from cache order by uuid') };
is_deeply(\@left, [ 'live', 'loud', 'player' ],
	'the stale-revision shells are gone and the live shell, loudness and player rows stay');
$dbh->disconnect;

# The route must not leave the other shells behind when it writes a new one.
my $music = read_file("$FindBin::Bin/../perl/Music.pl");
like($music, qr/delete from cache where app = 'music' and context = 'content'/,
	'the music route drops the shells an earlier revision or queue left behind');

done_testing();
