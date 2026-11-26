# tests-for: lib/JawnOS/Domain/Key.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_configure4.pm templates/configure/system_setting_list.html.ep perl/help/topics_configure.pl
# covers:    one table the database cannot count must not turn Configure -> Sys
#           into a 500. A damaged page answers no count at all, and the panel
#           used to dereference that empty row; now the table keeps its place
#           with an unreadable marker and every other total still draws.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Slurp qw(read_file);

# The shapes db_query hands back: a list of table names, a count row, and a
# failed read whose ->hash is empty (a malformed page).
{
	package FakeResults;
	sub new { my ($class, $rows) = @_; return bless { rows => $rows }, $class }
	sub hashes { return $_[0]->{'rows'} }

	package FakeCount;
	sub new { my ($class, $hash) = @_; return bless { hash => $hash }, $class }
	sub hash { return $_[0]->{'hash'} }
}

my $sql_seen;
no warnings 'redefine';
local *subs::db_query = sub {
	my ($query) = @_;
	push @{$sql_seen}, $query;
	return FakeResults->new([ { name => 'good' }, { name => 'empty' }, { name => 'damaged' } ])
		if $query =~ /sqlite_master/;
	return FakeCount->new({ 'count(*)' => 7 }) if $query =~ /"good"/;
	return FakeCount->new(undef) if $query =~ /"empty"/;
	die "database disk image is malformed\n" if $query =~ /"damaged"/;
	return undef;
};

my $stats = eval { subs::database_table_stats() };
is( $@, '', 'a table that cannot be counted does not die' ) or diag($@);
is( scalar @{$stats}, 3, 'every table keeps a row' );

is( $stats->[0]->{'table'}, 'good', 'the first table is named' );
is( $stats->[0]->{'count'}, 7, 'and carries its count' );
ok( !$stats->[0]->{'unreadable'}, 'a readable table is not marked unreadable' );

is( $stats->[1]->{'table'}, 'empty', 'a count that comes back empty keeps its row' );
ok( $stats->[1]->{'unreadable'}, 'and is marked unreadable' );
ok( !defined $stats->[1]->{'count'}, 'with no invented count' );

is( $stats->[2]->{'table'}, 'damaged', 'a statement that dies keeps its row too' );
ok( $stats->[2]->{'unreadable'}, 'and is marked unreadable' );

# The panel draws the marker and points at the repair, instead of printing an
# empty count.
my $tpl = read_file("$FindBin::Bin/../templates/configure/system_setting_list.html.ep");
like( $tpl, qr/\$s->\{'unreadable'\}/, 'the totals draw the unreadable state' );
like( $tpl, qr/Doctor, in Enc, repairs the database/, 'and say where the repair lives' );

my $controller = read_file("$FindBin::Bin/../lib/JawnOS/Controller/manager_configure4.pm");
like( $controller, qr/database_table_stats/, 'the Sys action asks the guarded helper' );
unlike( $controller, qr/->hash->\{'count\(\*\)'\}/, 'and no longer dereferences the count itself' );

done_testing();
