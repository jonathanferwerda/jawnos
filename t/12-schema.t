use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use DBI;

# database/schema.sql is the tracked shape of the house database. Loading it into
# an in-memory SQLite proves every statement is valid and that the sync columns
# are where the rail expects them.

my $root = JawnOSTest::root();
my $sql = do {
	local $/;
	open(my $fh, '<', "$root/database/schema.sql") or die "schema.sql: $!";
	<$fh>;
};
ok(defined $sql && length $sql, 'schema.sql is readable');

# The file separates statements with ";\n"; there are no triggers or literals
# holding a semicolon, so a split is exact (the app's own bootstrap reads it the
# same way).
my @statements = grep { /\S/ } split /;[ \t]*\n/, $sql;
cmp_ok(scalar(@statements), '>', 50, 'the schema is a set of statements');

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
	{ RaiseError => 1, PrintError => 0 });
ok($dbh, 'an in-memory SQLite database opens');

my @failed;
for my $i (0 .. $#statements) {
	my $ok = eval { $dbh->do($statements[$i]); 1 };
	push @failed, 'statement ' . ($i + 1) . ': ' . ($@ || 'failed')
		unless $ok;
}
is_deeply(\@failed, [], 'every schema statement executes')
	or diag(join("\n", @failed));

my $tables = $dbh->selectall_arrayref(
	"SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
);
my %has = map { $_->[0] => 1 } @$tables;

# The tables the app's core data model names (AGENTS.md "Data model").
for my $table (qw(
	appointments mailbox notes warehouse model option subcategory continent
	magazine credentials devices staged_appointments
)) {
	ok($has{$table}, "schema has table $table");
}

# AGENTS.md: every synced table carries ost and server_time, or the rail skips
# it. The only exceptions are the two pieces of local sync bookkeeping.
my @missing;
for my $row (@$tables) {
	my $table = $row->[0];
	my $columns = $dbh->selectall_arrayref(qq{PRAGMA table_info("$table")});
	my %column = map { $_->[1] => 1 } @$columns;
	push @missing, $table unless $column{ost} && $column{server_time};
}
is_deeply(\@missing, [ 'sync_cursors', 'sync_jobs' ],
	'only the two sync bookkeeping tables lack ost/server_time')
	or diag('tables without both columns: ' . join(', ', @missing));

my $indexes = $dbh->selectall_arrayref(
	"SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'"
);
cmp_ok(scalar(@$indexes), '>', 0, 'the schema creates indexes');

done_testing();
