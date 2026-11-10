# tests-for: database/schema.sql lib/JawnOS/Domain/Migrations.pm
# covers:    The manager warms its app search on page load and on focus with a
#            count and a distinct over appointments by account. No existing
#            index has account as a prefix, so both scanned the whole table -
#            117k rows on the house box, and a phone that has run longer has
#            more. A fresh database carries the index; an existing one gains it
#            from the migration list.

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
like($schema, qr/create index if not exists idx15_appts on appointments \(account\)/i,
	'a fresh database indexes appointments by account');

my $migrations = read_file("$root/lib/JawnOS/Domain/Migrations.pm");
like($migrations, qr/create index if not exists idx15_appts on appointments \(account\)/i,
	'an existing database gains the same index');

# The query shape the search warm-up uses, against the index the schema builds.
my ($fh, $dbfile) = tempfile('jawnos-account-index-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db = $sql->db;
$db->query('create table appointments (account text, app text, timestamp text)');
$db->query('create index idx15_appts on appointments (account)');
$db->query('insert into appointments (account, app, timestamp) values (?,?,?)',
	'gallery', 'track' . $_, 1000 + $_) for 1 .. 200;

my $count_plan = join ' ', map { $_->{'detail'} // '' } @{
	$db->query('explain query plan select count(*) from appointments where account = ?', 'gallery')->hashes
};
like($count_plan, qr/idx15_appts/,
	'the search signature count reads the account index');

my $list_plan = join ' ', map { $_->{'detail'} // '' } @{
	$db->query('explain query plan select distinct app from appointments where account = ?', 'gallery')->hashes
};
like($list_plan, qr/idx15_appts/,
	'the app list reads the account index');

done_testing();
