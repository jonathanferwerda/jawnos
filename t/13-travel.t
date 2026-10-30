use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# Which device was with the person. One appointment can hold fixes from more than
# one machine - a tablet left in the house and the phone that went for the walk -
# so the house picks the device that covered the most ground. This is the door the
# travel viewer and the appointment's Dist map both read.

sub fix {
	my ( $t, $sig, $lat, $lon ) = @_;
	return { timestamp => $t, signatorial => $sig, latitude => $lat, longitude => $lon };
}

# ------------------------------------------------------------ nothing to choose
is( &subs::carrier_device([]), undef, 'no fixes means no carrier' );
is( &subs::carrier_device(undef), undef, 'undef is not a list of fixes' );

# A route passes db_query(...)->hashes, which is a Mojo::Collection rather than a
# plain arrayref; both shapes must reach the same answer.
my $collection = Mojo::Collection->new( fix( 1000, 'phone', 43.0024, -81.9419 ) );
is( &subs::carrier_device($collection)->{'signatorial'}, 'phone', 'a Mojo::Collection is a list of fixes too' );

my $only = &subs::carrier_device( [ fix( 1000, 'phone', 43.0024, -81.9419 ) ] );
is( $only->{'signatorial'}, 'phone', 'one fix names its device' );
is( $only->{'metres'},      0,       'one fix has covered no ground' );
is( $only->{'fixes'},       1,       'one fix is counted' );
is( $only->{'devices'},     1,       'one device recorded' );

# ------------------------------------------------------ the walk versus the house
# 0.002 degrees of latitude is about 222 m: four steps make a walk of ~890 m.
my @walk;
for my $i ( 1 .. 5 ) {
	push @walk, fix( $i * 60000, 'phone', 43 + $i * 0.002, -81.94 );
}
# The tablet stayed home: forty readings shuffling by ~11 m, every step under the
# 25 m jitter floor, so it never travels anywhere however many rows it writes.
my @tablet;
for my $i ( 1 .. 40 ) {
	push @tablet, fix( $i * 30000, 'tablet', 43.0024 + ( $i % 2 ? 0.00005 : -0.00005 ), -81.9419 );
}
my $carrier = &subs::carrier_device( [ @tablet, @walk ] );
is( $carrier->{'signatorial'}, 'phone', 'the device that walked carries the appointment' );
cmp_ok( $carrier->{'metres'}, '>', 800, 'the walk is measured' );
cmp_ok( $carrier->{'metres'}, '<', 1000, 'the walk is measured in metres, not kilometres' );
is( $carrier->{'fixes'},  5, 'the carrier is counted in its own fixes' );
is( $carrier->{'devices'}, 2, 'both devices are known' );

my $reversed = &subs::carrier_device( [ reverse @tablet, reverse @walk ] );
is( $reversed->{'signatorial'}, 'phone', 'the answer does not depend on row order' );
is( $reversed->{'metres'}, $carrier->{'metres'}, 'the path is the same read backwards' );

# ------------------------------------------------------------- parked machines
my @quiet  = map { fix( $_, 'tablet', 43.0024, -81.9419 ) } 1 .. 3;
my @busier = map { fix( $_, 'phone',  43.0024, -81.9419 ) } 1 .. 7;
is( &subs::carrier_device( [ @quiet, @busier ] )->{'signatorial'}, 'phone',
	'when neither moved, the device with more fixes wins' );

is( &subs::carrier_device( [ fix( 1, 'beta', 43, -81 ), fix( 2, 'alpha', 43, -81 ) ] )->{'signatorial'}, 'alpha',
	'a dead heat is settled by name, so two reads agree' );

# ------------------------------------------------------------------- bad rows
my $partial = &subs::carrier_device( [
	{ timestamp => 1, signatorial => 'tablet' },                    # no position
	fix( 2, 'phone', '', '' ),                                      # an empty position
	{ timestamp => 3, latitude => 'nonsense', longitude => '-81' },  # not a number
	fix( 4, 'phone', 43.0024, -81.9419 ),                           # the only real one
] );
is( $partial->{'signatorial'}, 'phone', 'rows without a position are skipped' );
is( $partial->{'devices'},     1,       'a device is only counted when it has a fix' );

# Database rows arrive as strings; they must read the same as numbers.
my $strings = &subs::carrier_device( [
	{ timestamp => '1000', signatorial => 'phone', latitude => '43.0000', longitude => '-81.9400' },
	{ timestamp => '2000', signatorial => 'phone', latitude => '43.0027', longitude => '-81.9400' },
] );
is( $strings->{'signatorial'}, 'phone', 'numeric strings are positions too' );
cmp_ok( $strings->{'metres'}, '>', 250, 'a 0.0027 degree step is counted' );
cmp_ok( $strings->{'metres'}, '<', 350, 'and counted once, not doubled' );

# A device missing its signatorial still takes part, under the empty name.
my $anon = &subs::carrier_device( [ fix( 1, undef, 43, -81 ), fix( 2, undef, 43.0027, -81 ) ] );
is( $anon->{'signatorial'}, '', 'a fix with no signatorial is its own device' );

# -------------------------------------------------------- jitter floor details
# A shuffle under the floor does not reset the anchor: the next real step is
# measured from where the device last truly was.
my $jitter = &subs::carrier_device( [
	fix( 1, 'phone', 43.0000, -81 ),
	fix( 2, 'phone', 43.00009, -81 ), # ~10 m, under the floor: still standing
	fix( 3, 'phone', 43.0027, -81 ),  # ~300 m from the first fix
] );
cmp_ok( $jitter->{'metres'}, '>', 250, 'a real step after a shuffle is still counted' );
cmp_ok( $jitter->{'metres'}, '<', 350, 'the shuffle itself adds nothing' );

# ------------------------------------------------------ who records the trip
# One device files an appointment's movement. movement_choice is the decision
# with the rows already read, so it is tested without a database.

is( &subs::movement_choice({ choice => 'every', signatorial => 'phone' }), 'phone',
	'"every device" lets this device record' );
is( &subs::movement_choice({ choice => 'tablet', signatorial => 'phone' }), 'tablet',
	'a named device is the recorder' );
is( &subs::movement_choice({ choice => 'auto', signatorial => 'phone' }), 'phone',
	'with no fixes yet, the device that is filing records' );

is( &subs::movement_choice({ choice => 'auto', signatorial => 'phone', now => 900000, rows => [
	fix( 1000, 'phone', 43.0000, -81 ),
	fix( 2000, 'phone', 43.0027, -81 ),
] }), 'phone', 'a lone moving device records its own trip' );

# The tablet is in the house writing jitter; the phone went for the walk.
my @walking = (
	fix( 1000, 'tablet', 43.00240, -81.9419 ),
	fix( 2000, 'tablet', 43.00245, -81.9419 ),
	fix( 3000, 'tablet', 43.00240, -81.9419 ),
	fix( 4000, 'phone',  43.00000, -81.9400 ),
	fix( 5000, 'phone',  43.00270, -81.9400 ),
);
is( &subs::movement_choice({ choice => 'auto', signatorial => 'phone', now => 6000, rows => [@walking] }), 'phone',
	'the moving device takes the trip from the one left at home' );
is( &subs::movement_choice({ choice => 'auto', signatorial => 'tablet', now => 6000, rows => [@walking] }), 'phone',
	'and the device at home defers even when it has more fixes' );

# Both travelled together: the first to start recording keeps the trip, so the
# role does not swap from fix to fix.
my @together = (
	fix( 1000, 'tablet', 43.0000, -81 ),
	fix( 2000, 'tablet', 43.0027, -81 ),
	fix( 2500, 'phone',  43.0000, -81 ),
	fix( 3000, 'phone',  43.0030, -81 ),
);
is( &subs::movement_choice({ choice => 'auto', signatorial => 'phone', now => 4000, rows => [@together] }), 'tablet',
	'when both are moving, the one that started recording keeps it' );

# The recorder left its fixes behind a quarter of an hour ago: hand the trip on
# rather than lose it.
my @gone = (
	fix( 1000, 'tablet', 43.0000, -81 ),
	fix( 2000, 'tablet', 43.0027, -81 ),
	fix( 1000 + 20 * 60 * 1000, 'phone', 43.0000, -81 ),
);
is( &subs::movement_choice({ choice => 'auto', signatorial => 'phone', now => 1000 + 20 * 60 * 1000, rows => [@gone] }), 'phone',
	'a recorder that went quiet is replaced' );

# Both parked: it does not matter which one records, but it must be one of them.
my @parked = ( fix( 1, 'tablet', 43.0024, -81.9419 ), fix( 2, 'phone', 43.0024, -81.9419 ) );
is( &subs::movement_choice({ choice => 'auto', signatorial => 'phone', now => 3, rows => [@parked] }), 'tablet',
	'with nothing moving the earliest recorder keeps it' );

# A device parked for hours can creep a hundred metres of jitter without going
# anywhere. It must not take a real walk from the device that recorded it, even
# if it was writing first.
my @creep = ( fix( 1000, 'tablet', 43.00000, -81 ), fix( 2000, 'tablet', 43.00024, -81 ) );
for my $i ( 3 .. 6 ) {
	push @creep, fix( $i * 1000, 'tablet', ( $i % 2 ? 43.00024 : 43.00000 ), -81 );
}
push @creep, fix( 7000, 'phone', 43.0000, -81 ), fix( 8000, 'phone', 43.0020, -81 ),
	fix( 9000, 'phone', 43.0040, -81 ), fix( 10000, 'phone', 43.0060, -81 ),
	fix( 11000, 'phone', 43.0080, -81 );
my $creep = &subs::movement_choice({ choice => 'auto', signatorial => 'phone', now => 12000, rows => [@creep] });
is( $creep, 'phone', 'a creeping device does not take a real walk' );

# ------------------------------------------------- the plate arms the autostop
# The details bar offers the autostop switch only where navigation_automation can
# act on the session: a duty with a radius and an action, and somewhere for that
# plate to measure from. Anything less is a switch nothing would honour.
is( &subs::home_plate_stop_armed({}), 0, 'no data arms nothing' );
is( &subs::home_plate_stop_armed({ duties => undef }), 0, 'undef duties arm nothing' );
is( &subs::home_plate_stop_armed({ duties => [] }), 0, 'an app with no plate arms nothing' );
is( &subs::home_plate_stop_armed({ duties => [ { action => 'stop' } ], plate => { latitude => 43, longitude => -81 } }),
	0, 'an action with no radius arms nothing' );
is( &subs::home_plate_stop_armed({ duties => [ { distance => '0.200' } ], plate => { latitude => 43, longitude => -81 } }),
	0, 'a radius with the action left on none arms nothing' );
is( &subs::home_plate_stop_armed({ duties => [ { distance => 0, action => 'stop' } ], plate => { latitude => 43, longitude => -81 } }),
	0, 'a zero radius arms nothing' );
is( &subs::home_plate_stop_armed({ duties => [ { distance => '0.200', action => 'stop', latitude => 43, longitude => -81 } ] }),
	1, 'radius, action and its own ground arm the switch' );
is( &subs::home_plate_stop_armed({ duties => [ { distance => '0.200', action => 'start' } ], plate => { latitude => 43, longitude => -81 } }),
	1, 'the app base plate is ground enough' );
is( &subs::home_plate_stop_armed({ duties => [ { distance => '0.200', action => 'command' } ], house => { latitude => 43, longitude => -81 } }),
	1, 'the house plate is ground enough' );
is( &subs::home_plate_stop_armed({ duties => [ { distance => '0.200', action => 'stop' } ] }),
	0, 'a plate with no coordinates anywhere arms nothing' );
is( &subs::home_plate_stop_armed({ duties => [
	{ distance => '0.200', action => 'none', latitude => 43, longitude => -81 },
	{ distance => '0.300', action => 'record', latitude => 43, longitude => -81 }
] }), 1, 'one armed duty is enough among several' );

done_testing();
