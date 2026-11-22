# tests-for: lib/JawnOS/Domain/Plates.pm lib/JawnOS/Domain/Accounting.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Key.pm
# covers:    a plate is a union of areas - circle, box, path with a width, and
#            polygon - plus cached pattern branches; a legacy point/radius row
#            becomes a circle, and the anchor/radius stay mirrored for old readers

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JSON::PP ();
use JawnOSTest;

my $root = root();
my $canonical = JSON::PP->new->canonical;

# --------------------------------------------------------------- legacy plate
my $legacy = { latitude => 43, longitude => -81, distance => '0.250', placement => 'within', action => 'stop' };
&subs::plate_normalize($legacy);
is( $legacy->{'kind'}, 'area', 'a legacy duty is an area flag' );
is( scalar @{ $legacy->{'areas'} || [] }, 1, 'and gets one area' );
is( $legacy->{'areas'}->[0]->{'shape'}, 'circle', 'the area is the point it already had' );
is( $legacy->{'areas'}->[0]->{'radius_m'}, '250', 'with the radius it already had' );
is( $legacy->{'distance'}, '0.250', 'the radius stays mirrored for old readers' );
is( $legacy->{'latitude'}, '43.0000000', 'and so does the point' );

my $before = $canonical->encode($legacy);
&subs::plate_normalize($legacy);
is( $canonical->encode($legacy), $before, 'normalizing twice changes nothing' );

# A flag whose last shape was removed is empty, not a legacy circle.
my $cleared = { kind => 'area', latitude => 43, longitude => -81, areas => [] };
is( scalar @{ &subs::plate_areas($cleared) }, 0, 'an explicitly empty area list is no ground' );
&subs::plate_normalize($cleared);
is( scalar @{ $cleared->{'areas'} || [] }, 0, 'and normalization keeps it explicitly empty' );
is( scalar @{ &subs::plate_areas($cleared) }, 0, 'so no circle is read back out of the old point' );
is( scalar @{ &subs::plate_areas($cleared) }, 0, 'and the stale point is not a shape' );
ok( !exists $cleared->{'latitude'} && !exists $cleared->{'longitude'}, 'normalization drops the stale point mirror' );
ok( !exists $cleared->{'distance'}, 'and the stale radius mirror' );
ok( &subs::plate_has_ground($cleared), 'a cleared flag still owns its empty ground' );
my $cleared_base = { kind => 'area', areas => [ { shape => 'circle', lat => 43, lon => -81, radius_m => 200 } ] };
is( &subs::plate_ground_for($cleared, $cleared_base), $cleared, 'so it does not silently fall back to the base plate' );
is( &subs::plate_reach_km($cleared), 0, 'and it reaches nowhere' );
is( &subs::plate_contains($cleared, 43, -81), 0, 'and matches no fix' );

# -------------------------------------------------------------------- circle
my $circle = { kind => 'area', areas => [ { shape => 'circle', lat => 43, lon => -81, radius_m => 200 } ] };
is( &subs::plate_contains($circle, 43.001, -81), 1, '111 m from the centre is inside a 200 m circle' );
is( &subs::plate_contains($circle, 43.003, -81), 0, '333 m from the centre is outside it' );
is( &subs::plate_distance_km($circle, 43, -81), 0, 'inside has no distance' );
ok( &subs::plate_distance_km($circle, 43.003, -81) > 0.10, 'outside is the distance past the edge' );
is( &subs::plate_reach_km($circle), 0.2, 'a circle reaches its radius' );

my $a = &subs::plate_anchor($circle);
is( $a->{'lat'}, 43, 'the anchor is the circle centre' );
is( $a->{'lon'}, -81, 'on both axes' );

# Distance is final once an area contains the fix; a later far area must not
# make the scan keep working.
my $inside_then_far = { kind => 'area', areas => [
	$circle->{'areas'}[0],
	{ shape => 'circle', lat => 43.5, lon => -81, radius_m => 200 },
] };
is( &subs::plate_distance_km($inside_then_far, 43.001, -81), 0, 'an inside area ends the distance scan at zero' );

# ----------------------------------------------------------------------- box
my $box = { kind => 'area', areas => [ { shape => 'box', nw => { lat => 43.002, lon => -81.002 }, se => { lat => 43.000, lon => -81.000 } } ] };
is( &subs::plate_contains($box, 43.001, -81.001), 1, 'a point inside the box is within the plate' );
is( &subs::plate_contains($box, 43.001, -80.999), 0, 'a point east of the box is outside' );
$b = &subs::plate_anchor($box);
is( $b->{'lat'}, 43.001, 'the box anchor is its centre' );
is( $b->{'lon'}, -81.001, 'on both axes' );

# A foreign or hand-edited row may store the corners in the other order. The
# map's hit test already treats the corners as min/max; navigation must agree.
my $box_rev = { kind => 'area', areas => [ { shape => 'box', nw => { lat => 43.000, lon => -81.000 }, se => { lat => 43.002, lon => -81.002 } } ] };
is( &subs::plate_contains($box_rev, 43.001, -81.001), 1, 'a box stored with swapped corners still contains its middle' );
&subs::plate_normalize($box_rev);
is( $box_rev->{'areas'}[0]{'nw'}{'lat'}, '43.0020000', 'normalization canonicalises the north-west corner' );
is( $box_rev->{'areas'}[0]{'nw'}{'lon'}, '-81.0020000', 'on both axes' );
is( $box_rev->{'areas'}[0]{'se'}{'lat'}, '43.0000000', 'and the south-east corner' );

# ------------------------------------------------------- path with a width
my $path = { kind => 'area', areas => [ { shape => 'path', width_m => 100, points => [ { lat => 43, lon => -81 }, { lat => 43, lon => -80.99 } ] } ] };
is( &subs::plate_contains($path, 43.0004, -80.995), 1, '44 m off a 100 m corridor is inside' );
is( &subs::plate_contains($path, 43.0008, -80.995), 0, '89 m off it is outside' );
is( &subs::plate_reach_km($path), 0.05, 'a corridor reaches half its width' );

# ------------------------------------------------------------------- polygon
my $polygon = { kind => 'area', areas => [ { shape => 'polygon', points => [
	{ lat => 43.002, lon => -81.002 },
	{ lat => 43.002, lon => -80.998 },
	{ lat => 42.998, lon => -80.998 },
	{ lat => 42.998, lon => -81.002 },
] } ] };
is( &subs::plate_contains($polygon, 43.000, -81.000), 1, 'a point inside the polygon is within the plate' );
is( &subs::plate_contains($polygon, 43.003, -81.000), 0, 'a point north of it is outside' );

# ---------------------------------------------------------------- union of areas
my $union = { kind => 'area', areas => [
	{ shape => 'circle', lat => 43.000, lon => -81.000, radius_m => 200 },
	{ shape => 'circle', lat => 43.010, lon => -81.000, radius_m => 200 },
] };
is( &subs::plate_contains($union, 43.0005, -81), 1, 'the first area counts' );
is( &subs::plate_contains($union, 43.0105, -81), 1, 'and so does the second' );
is( &subs::plate_contains($union, 43.005, -81), 0, 'the gap between them does not' );

# A flag may carry a lot of shapes; the union and its normalization must keep
# every one of them and still answer a fix near either end.
my @many;
for my $i (0 .. 1999) {
	push @many, {
		shape => 'circle',
		lat => sprintf('%.7f', 43.0 + ($i % 50) * 0.0001),
		lon => sprintf('%.7f', -81.0 + int($i / 50) * 0.0001),
		radius_m => 5,
	};
}
my $many = { kind => 'area', areas => \@many };
is( scalar @{ &subs::plate_areas($many) }, 2000, 'a 2000-area plate keeps every area' );
is( &subs::plate_contains($many, 43.0, -81.0), 1, 'and matches the first' );
is( &subs::plate_contains($many, 43.0 + 49 * 0.0001, -81.0 + 39 * 0.0001), 1, 'and a far one' );
is( &subs::plate_contains($many, 42.0, -81.0), 0, 'while a distant fix is outside' );
&subs::plate_normalize($many);
is( scalar @{ $many->{'areas'} || [] }, 2000, 'normalization keeps all 2000 areas' );
my $many_once = $canonical->encode($many);
&subs::plate_normalize($many);
is( $canonical->encode($many), $many_once, 'and a large plate normalizes idempotently' );

# ---------------------------------------------------------- pattern branches
my $pattern = {
	kind => 'pattern',
	match => { brand => 'Walmart', region => { lat => 43, lon => -81, radius_m => 50000 } },
	branches => [
		{ name => 'Sarnia', latitude => 43.000, longitude => -81.000, areas => [ { shape => 'circle', lat => 43.000, lon => -81.000, radius_m => 200 } ] },
		{ name => 'London', latitude => 43.010, longitude => -81.000, areas => [ { shape => 'circle', lat => 43.010, lon => -81.000, radius_m => 200 } ] },
	],
};
is( &subs::plate_contains($pattern, 43.0005, -81), 1, 'a pattern matches its cached branches' );
is( &subs::plate_contains($pattern, 43.0105, -81), 1, 'any branch, not only the first' );
is( &subs::plate_contains($pattern, 43.005, -81), 0, 'the search region is not itself a plate' );
is( scalar @{ &subs::plate_areas($pattern) }, 2, 'the two branches give two areas' );

my $empty_pattern = { kind => 'pattern', match => { brand => 'Walmart' }, latitude => 43, longitude => -81, branches => [] };
is( scalar @{ &subs::plate_areas($empty_pattern) }, 0, 'a pattern with no branches covers nothing, even with a region centre' );
&subs::plate_normalize($empty_pattern);
is( $empty_pattern->{'kind'}, 'pattern', 'and normalization keeps it a pattern' );
is( &subs::plate_ground_for($empty_pattern, $circle), $empty_pattern, 'an empty pattern does not fall back to the base plate' );
is( &subs::plate_contains($empty_pattern, 43.001, -81), 0, 'so it matches nothing until a branch is found' );

# The editor positions a pattern marker at its search region. The server anchor
# must agree (the cached branches remain the ground).
my $pattern_anchor = {
	kind => 'pattern',
	match => { brand => 'TestMart', region => { lat => 44, lon => -82, radius_m => 50000 } },
	branches => [ { latitude => 43.000, longitude => -81.000, areas => [ { shape => 'circle', lat => 43.000, lon => -81.000, radius_m => 200 } ] } ],
};
my $pa = &subs::plate_anchor($pattern_anchor);
is( $pa->{'lat'}, 44, 'a pattern is anchored at its search region' );
is( $pa->{'lon'}, -82, 'on both axes' );
is( &subs::plate_contains($pattern_anchor, 43.0005, -81), 1, 'while its cached branches stay the ground' );

# ---------------------------------------------------------- branch lookup helpers
my $escaped = &subs::plate_branch_escape('Walmart (Supercentre) "North"');
like( $escaped, qr/\\\(/, 'a parenthesis is escaped for the Overpass regex' );
like( $escaped, qr/\\\)/, 'and the closing one' );
like( $escaped, qr/\\"/, 'a quote cannot end the query string' );
is( &subs::plate_branch_escape("  \n "), '', 'a blank brand escapes to nothing' );

my $near = &subs::plate_branch_dedupe([
	{ name => 'one', lat => 43.0000, lon => -81.0000 },
	{ name => 'same', lat => 43.0004, lon => -81.0000 },
], 150);
is( scalar @{$near}, 1, 'two points 44 m apart are one branch' );

my $far = &subs::plate_branch_dedupe([
	{ name => 'one', lat => 43.0000, lon => -81.0000 },
	{ name => 'another', lat => 43.0090, lon => -81.0000 },
], 150);
is( scalar @{$far}, 2, 'two points a kilometre apart are two branches' );

# --------------------------------------------------------------- the backfill
like( read_file("$root/lib/JawnOS/Domain/Accounting.pm"), qr/'home_plate_shapes_v1' => sub/,
	'the backfill that shapes existing plates is registered' );
like( read_file("$root/lib/JawnOS/Domain/Accounting.pm"), qr/&subs::plate_normalize\(\$plate\)/,
	'and it runs the same normalizer' );
like( read_file("$root/lib/JawnOS/Domain/Loader.pm"), qr/'JawnOS::Domain::Plates' for qw\([^)]*plate_contains/,
	'the domain loader knows the plate helpers' );

# ------------------------------------------------- the backfill writes one row
# A settings row has no usable id (all are null); the uuid is the key. The old
# backfill updated by id, a null matched every row, and one boot wrote a home
# plate over all 43k settings. This pins the write to the row it read.
{
	package PlateFakeRows;
	sub hashes { return $_[0]->{'rows'} }
}
{
	my @updates;
	no warnings 'redefine';
	local *subs::db_select = sub {
		my ($table, $columns, $where) = @_;
		my $setting = ref $where eq 'HASH' ? ($where->{'setting'} // '') : '';
		my @rows = $setting eq 'home_plate'
			? ( { uuid => 'u-plate', app => 'me', setting => 'home_plate', id => undef,
				value => '{"latitude":43,"longitude":-81,"distance":"0.200"}' } )
			: ();
		return bless { rows => \@rows }, 'PlateFakeRows';
	};
	local *subs::db_update = sub { push @updates, [ @_ ]; return 1 };
	local *subs::rightNow = sub { return 1795296000000 };
	local *subs::say_it = sub { };
	my $registry = &subs::backfills();
	my $status = $registry->{'home_plate_shapes_v1'}->();
	is( $status, 1, 'the backfill reports that it ran' );
	is( scalar @updates, 1, 'it writes only the row it selected' );
	is( $updates[0]->[2]->{'uuid'}, 'u-plate', 'by the settings row uuid' );
	ok( !exists $updates[0]->[2]->{'id'}, 'never by the nullable id column' );
	is( $updates[0]->[1]->{'server_time'}, 1795296000000, 'and stamps the row for sync' );
	like( $updates[0]->[1]->{'value'}, qr/"areas"/, 'the value is the normalized plate' );
}

like( read_file("$root/lib/JawnOS/Domain/Key.pm"), qr/\$contexts = \[\] unless ref \$contexts eq 'ARRAY'/,
	'the gate survives a context row that is not an array' );

done_testing();
