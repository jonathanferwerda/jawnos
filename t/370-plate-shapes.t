# tests-for: lib/JawnOS/Domain/Plates.pm lib/JawnOS/Domain/Accounting.pm lib/JawnOS/Domain/Loader.pm
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

# ----------------------------------------------------------------------- box
my $box = { kind => 'area', areas => [ { shape => 'box', nw => { lat => 43.002, lon => -81.002 }, se => { lat => 43.000, lon => -81.000 } } ] };
is( &subs::plate_contains($box, 43.001, -81.001), 1, 'a point inside the box is within the plate' );
is( &subs::plate_contains($box, 43.001, -80.999), 0, 'a point east of the box is outside' );
$b = &subs::plate_anchor($box);
is( $b->{'lat'}, 43.001, 'the box anchor is its centre' );
is( $b->{'lon'}, -81.001, 'on both axes' );

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

done_testing();
