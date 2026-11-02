# tests-for: lib/JawnOS/Domain/File.pm
# covers:    a cache write updates its row in place and inserts only when none exists, so an
#            interrupted write can never erase the value that was there (the balance history's month).

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# The domain layer is lazy: load the real definition before the local *subs::
# stubs below, or a later module load would replace them.
subs::preload('cache_set');

# The smallest stand-in for a Mojo::SQLite::Results: what cache_set asks of it
# is ->hashes (a row lookup) and, for a write, ->rows.
package FakeRows;
sub new {
	my ($class, $rows, $hashes) = @_;
	return bless { rows => $rows, hashes => $hashes || [] }, $class;
}
sub rows   { $_[0]->{'rows'} }
sub hashes { $_[0]->{'hashes'} }

package main;

my $NOW = 1_700_000_000_000;

# cache_set reads these through the package (not lexically), so a local glob
# replaces them for the call. The write helpers are recorded so the test can
# prove what was and was not attempted.
my (@calls, $existing, $lookup_fails);
sub _install {
	@calls = ();
	local $subs::device = 'computer';
	local *subs::rightNow = sub { $NOW };
	local *subs::unformat_name = sub { $_[0] };
	local *subs::ago_calc = sub { my ($spec, $now) = @_; return defined $now ? $now : $NOW };
	local *subs::setting_grabber = sub { {} };
	local *subs::database_grabber = sub { return () };
	local *subs::random_string_creator = sub { 'fresh-uuid' };
	local *subs::db_select_simple = sub {
		push @calls, 'select';
		die "database is locked\n" if $lookup_fails;
		return FakeRows->new($existing ? 1 : 0, $existing ? [ { uuid => $existing } ] : []);
	};
	local *subs::db_update = sub {
		my ($table, $data, $where) = @_;
		push @calls, [ 'update', $table, $data, $where ];
		return FakeRows->new(1);
	};
	local *subs::db_insert = sub {
		my ($table, $data) = @_;
		push @calls, [ 'insert', $table, $data ];
		return FakeRows->new(1);
	};
	# The old implementation deleted first; any hit here is the regression.
	local *subs::db_delete = sub { push @calls, 'delete'; return FakeRows->new(1) };
	&subs::cache_set({ app => '__president', context => 'ai_balance', warranty => '-40d' }, { history => { deepseek => [ 1, 2 ] } });
}

my $printed = sub { map { ref $_ eq 'ARRAY' ? $_->[0] : $_ } @calls };

# An existing row is updated where it stands: no delete, no second row.
$existing = 'row-uuid';
$lookup_fails = 0;
{
	_install();
}
is_deeply([ $printed->() ], [ 'select', 'update' ], 'an existing row is updated in place, not deleted and re-inserted');
my ($update) = grep { ref $_ eq 'ARRAY' && $_->[0] eq 'update' } @calls;
is($update->[3]->{'uuid'}, 'row-uuid', 'the update is addressed by the row it found');
ok(defined $update->[2]->{'data'} && length $update->[2]->{'data'}, 'the serialized value is written');
is($update->[2]->{'warranty'}, $NOW, 'the warranty is written with the value');
is($update->[2]->{'server_time'}, $NOW, 'the server time is written with the value');

# No row yet: one insert, and still no delete.
$existing = undef;
$lookup_fails = 0;
{
	_install();
}
is_deeply([ $printed->() ], [ 'select', 'insert' ], 'only a missing row is inserted');
my ($insert) = grep { ref $_ eq 'ARRAY' && $_->[0] eq 'insert' } @calls;
is($insert->[2]->{'app'}, '__president', 'the insert carries the app');
is($insert->[2]->{'context'}, 'ai_balance', 'the insert carries the context');
is($insert->[2]->{'device'}, 'computer', 'the insert is per device');
is($insert->[2]->{'uuid'}, 'fresh-uuid', 'the insert mints a uuid');

# A write that cannot read the row must not erase it (and must not guess).
$existing = 'row-uuid';
$lookup_fails = 1;
{
	_install();
}
is_deeply([ $printed->() ], [ 'select' ], 'an unreadable row is left alone, not overwritten or deleted');

done_testing();
