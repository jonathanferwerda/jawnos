# tests-for: database/schema.sql lib/JawnOS/Domain/Migrations.pm
# covers:    The clothesline names the ground from the last two days of fixes,
#            and reads the stays around it from two months of them. Both
#            queries cast continent's text columns, so neither of the existing
#            indexes could serve them and each scanned the whole position
#            history - 123k rows on the house box, and a phone that has run
#            longer has more. A fresh database carries the two expression
#            indexes; an existing one gains them from the migration list, and
#            each query shape reads its index.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use Mojo::SQLite;
use RepoSource;

my $root = repo_root();

my $schema = read_file("$root/database/schema.sql");
like($schema, qr/create index idx7_continent on continent \(cast\(timestamp as integer\)\)/i,
	'a fresh database indexes the position history by its timestamp');
like($schema, qr/create index idx8_continent on continent \(cast\(latitude as real\), cast\(longitude as real\), cast\(timestamp as integer\)\)/i,
	'and by the place a fix was taken');

my $migrations = read_file("$root/lib/JawnOS/Domain/Migrations.pm");
like($migrations, qr/create index if not exists idx7_continent on continent \(cast\(timestamp as integer\)\)/i,
	'an existing database gains the timestamp index');
like($migrations, qr/create index if not exists idx8_continent on continent \(cast\(latitude as real\), cast\(longitude as real\), cast\(timestamp as integer\)\)/i,
	'and the place index');

# The two query shapes the clothesline uses, against the indexes the schema
# builds. The cast in the query must match the index expression exactly, or
# SQLite ignores the index and scans.
my ($fh, $dbfile) = tempfile('jawnos-continent-index-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db = $sql->db;
$db->query('create table continent (latitude text, longitude text, timestamp text)');
$db->query('create index idx7_continent on continent (cast(timestamp as integer))');
$db->query('create index idx8_continent on continent (cast(latitude as real), cast(longitude as real), cast(timestamp as integer))');

my $base = 1794810077324;
for my $i (0 .. 200) {
	my $lat = 43.0023935 + (($i % 20) - 10) * 0.0002;
	my $lon = -81.9421425 + (($i % 20) - 10) * 0.0002;
	$db->query('insert into continent (latitude, longitude, timestamp) values (?,?,?)',
		$lat, $lon, $base - ($i * 3600000))->hashes;
}

my $place_plan = join ' ', map { $_->{'detail'} // '' } @{
	$db->query('explain query plan select count(*) from continent where latitude is not null and latitude != ? and longitude is not null and longitude != ? and cast(timestamp as integer) >= ? and cast(timestamp as integer) <= ?',
		'', '', $base - (48 * 3600000), $base)->hashes
};
like($place_plan, qr/idx7_continent/, 'the current-place read uses the timestamp index');

my $days_plan = join ' ', map { $_->{'detail'} // '' } @{
	$db->query('explain query plan select cast(cast(timestamp as integer) / 86400000 as integer) d, min(cast(timestamp as integer)) mn, max(cast(timestamp as integer)) mx from continent where cast(latitude as real) between ? and ? and cast(longitude as real) between ? and ? and cast(timestamp as integer) >= ? and cast(timestamp as integer) <= ? group by d order by d asc',
		42.993384492, 43.011402508, -81.9544605, -81.9298245, $base - (60 * 86400000), $base)->hashes
};
like($days_plan, qr/idx8_continent/, 'the near-place stays use the place index');

done_testing();
