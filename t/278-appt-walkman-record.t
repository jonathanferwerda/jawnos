# tests-for: lib/JawnOS/Controller/manager_misc2.pm public/js/manager/manager.js
# covers:    The appointment window's reverse/forward walkman steps to the app's
#           adjacent record. It used to widen the pivot by the view's span (a
#           span before the record for prev, two spans after it for next), so a
#           press skipped the next record and landed on the one after next.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

my $root = root();
require "$root/lib/JawnOS/Controller/manager_misc2.pm";

package FakeWalkmanRows;
sub new { return bless { hashes => $_[1] || [] }, $_[0] }
sub hashes { return $_[0]->{'hashes'} }

package FakeWalkmanController;
sub new { return bless { params => $_[1], json => undef }, $_[0] }
sub param { return $_[0]->{'params'}->{$_[1]} }
sub render {
	my ($self, @args) = @_;
	$self->{'json'} = $args[1] if @args && $args[0] eq 'json';
	return;
}

package main;

my @records = map { { timestamp => $_ } } (100, 200, 300, 400);

sub run_jump {
	my (%params) = @_;
	my @calls;
	local *subs::database_grabber = sub { return (undef, undef, undef) };
	# If the action still uses a view span, make it large enough to overshoot
	# the adjacent record: 200 with a 1000ms span gives pivots -800 and 2200.
	local *subs::time_span = sub { return ($_[1] // 0) - 1000 };
	local *subs::iso_local = sub { return $_[0] };
	local *subs::db_query = sub {
		my ($sql, @args) = @_;
		push @calls, [ $sql, @args ];
		my $pivot = $args[-1];
		my @hit;
		if ($sql =~ /<\s*\?/) {
			@hit = sort { $b->{'timestamp'} <=> $a->{'timestamp'} }
				grep { $_->{'timestamp'} < $pivot } @records;
		}
		elsif ($sql =~ />\s*\?/) {
			@hit = sort { $a->{'timestamp'} <=> $b->{'timestamp'} }
				grep { $_->{'timestamp'} > $pivot } @records;
		}
		else {
			@hit = grep { $_->{'timestamp'} == $pivot } @records;
		}
		return FakeWalkmanRows->new(@hit ? [ $hit[0] ] : []);
	};
	my $c = FakeWalkmanController->new({ app => 'walk', timestamp => 200, filter => 'all', %params });
	Manager::action_7994($c);
	return ($c->{'json'}, \@calls);
}

my ($next, $next_calls) = run_jump(type => 'next');
is($next->{'new_timestamp'}, 300, 'next steps to the adjacent record');
is($next_calls->[0]->[-1], 200, 'next compares against the record moment, not a widened span');

my ($prev, $prev_calls) = run_jump(type => 'prev');
is($prev->{'new_timestamp'}, 100, 'prev steps to the adjacent record');
is($prev_calls->[0]->[-1], 200, 'prev compares against the record moment too');

my ($filtered) = run_jump(type => 'next', filter => 'start');
is($filtered->{'new_timestamp'}, 300, 'a filtered walk still lands on the adjacent record');

# The client no longer sends the view span the server stopped using.
my $js = read_file("$root/public/js/manager/manager.js");
like($js, qr/data: \{ timestamp: timestamp, filter: filter, type: type, app: app \}/,
	'the walkman request carries the record moment');
unlike($js, qr/data: \{ timestamp: timestamp, filter: filter, type: type, app: app, scope:/,
	'and no view span');

done_testing();
