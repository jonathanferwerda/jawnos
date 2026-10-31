use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# A replay can deliver the same start twice a moment apart. The start branch
# used to mint a fresh uuid each time, so the stop closed the row it named and
# the twin stayed open on whichever machine held the other write (a tablet kept
# a `programming` session running hours after it was stopped). These tests pin
# the two selectors that make one press mean one session, and the deletion rail
# that lets a row pull settle a deletion even when the peer never handshakes.

{
	package FakeRows;
	sub new   { my ($class, $rows) = @_; return bless { rows => $rows }, $class }
	sub hashes { return $_[0]->{'rows'} }
}

# --------------------------------------------------------------- open near
{
	my @seen;
	local *subs::db_query = sub {
		my ($sql, @args) = @_;
		push @seen, { sql => $sql, args => \@args };
		return FakeRows->new([ { uuid => 'twin-uuid', timestamp => 1000130 } ]);
	};
	my $rows = &subs::session_open_near('programming', 'start', 1000000, 2000);
	is scalar @{$rows}, 1, 'an open row near the start is returned';
	is $rows->[0]->{'uuid'}, 'twin-uuid', 'with its uuid';
	like $seen[0]->{'sql'}, qr/stop_seen is null/, 'only an open session is a twin';
	like $seen[0]->{'sql'}, qr/abs\(cast\(timestamp as integer\) - \?\) <= \?/, 'the window is a tolerance, not an exact stamp';
	is $seen[0]->{'args'}->[0], 'programming', 'the app is named';
	is $seen[0]->{'args'}->[1], 'start', 'and the type must match';
	is $seen[0]->{'args'}->[4], 2000, 'the default tolerance is two seconds';
}

# ------------------------------------------------------------- twin rows
{
	my @seen;
	local *subs::db_query = sub {
		my ($sql, @args) = @_;
		push @seen, { sql => $sql, args => \@args };
		return FakeRows->new([ { uuid => 'left-open', timestamp => 1000050 } ]);
	};
	my $rows = &subs::session_twin_rows('programming', 'named-uuid', 1000000, 2000);
	is scalar @{$rows}, 1, 'a sibling open start is returned';
	is $rows->[0]->{'uuid'}, 'left-open', 'with the sibling uuid';
	like $seen[0]->{'sql'}, qr/uuid != \?/, 'the row the stop already closed is excluded';
	like $seen[0]->{'sql'}, qr/\(type=\? or type=\?\)/, 'start and record both count';
	is $seen[0]->{'args'}->[3], 'named-uuid', 'the named row is excluded by uuid';
}

# --------------------------------------------------------------- wiring
{
	my $read = sub {
		open(my $fh, '<', $_[0]) or die "$_[0]: $!";
		local $/;
		my $text = <$fh>;
		close $fh;
		return $text;
	};
	my $root = root();
	my $manager = $read->("$root/Manager.pl");
	like $manager, qr/session_open_near\(\$app, \$type, \$timestamp, 2000\)/, 'the start branch reuses a nearby open row';
	like $manager, qr/session_twin_rows\(\$app, \$stop_row->\{'uuid'\}/, 'the stop branch retires the twins';
	like $manager, qr/get '\/manager\/sync_tombstones'/, 'the deletion log has a peer route';
	like $manager, qr/sub apply_peer_tombstones/, 'and one applier for handshake and pull';
	like $manager, qr/apply_peer_tombstones\(\$tj, \$remote_signatorial\)/, 'the row pull asks for and applies tombstones';
	my $subs = $read->("$root/subroutines.pl");
	like $subs, qr/sub session_open_near/, 'the open-near selector lives in the core';
	like $subs, qr/sub session_twin_rows/, 'so does the twin selector';
	my $hooks = $read->("$root/hooks.pl");
	like $hooks, qr{\$path eq '/manager/sync_tombstones'}, 'the deletion route is gate-exempt for a signed peer';
}

done_testing();
