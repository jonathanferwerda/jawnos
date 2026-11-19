# tests-for: lib/JawnOS/Domain/Appointment.pm lib/JawnOS/Domain/Appointment2.pm lib/JawnOS/Domain/Device2.pm lib/JawnOS/Domain/Headless.pm lib/JawnOS/Domain/Render.pm lib/JawnOS/Manager/Part13.pm lib/JawnOS/Controller/manager_misc5.pm lib/JawnOS/Controller/manager_misc7.pm lib/JawnOS/Controller/manager_travel.pm
# covers:    Which device was with the person, which one files the activity, the track the distance reads (including a handover mid-trip), and how long a stopped home-plate visit stays resumable (three navigation intervals)

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

my $root = root();

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
is( &subs::movement_choice({ choice => 'auto', signatorial => 'tablet', now => 6000, rows => [@walking] }), 'none',
	'and the device at home is told to file nothing, even with more fixes' );

# Both travelled together: the first to start recording keeps the trip, so the
# role does not swap from fix to fix. The other device is told to file nothing
# rather than told the winner's name.
my @together = (
	fix( 1000, 'tablet', 43.0000, -81 ),
	fix( 2000, 'tablet', 43.0027, -81 ),
	fix( 2500, 'phone',  43.0000, -81 ),
	fix( 3000, 'phone',  43.0030, -81 ),
);
is( &subs::movement_choice({ choice => 'auto', signatorial => 'tablet', now => 4000, rows => [@together] }), 'tablet',
	'when both are moving, the one that started recording keeps it' );
is( &subs::movement_choice({ choice => 'auto', signatorial => 'phone', now => 4000, rows => [@together] }), 'none',
	'and the other device files nothing while it does' );

# The recorder left its fixes behind a quarter of an hour ago: hand the trip on
# rather than lose it.
my @gone = (
	fix( 1000, 'tablet', 43.0000, -81 ),
	fix( 2000, 'tablet', 43.0027, -81 ),
	fix( 1000 + 20 * 60 * 1000, 'phone', 43.0000, -81 ),
);
is( &subs::movement_choice({ choice => 'auto', signatorial => 'phone', now => 1000 + 20 * 60 * 1000, rows => [@gone] }), 'phone',
	'a recorder that went quiet is replaced' );

# Both parked where they last filed: this device answers for itself, and a fix
# that has not left the place of the last one it filed is drift.
my @parked = ( fix( 1, 'tablet', 43.0024, -81.9419 ), fix( 2, 'phone', 43.0024, -81.9419 ) );
is( &subs::movement_choice({ choice => 'auto', signatorial => 'phone', now => 2000, rows => [@parked],
	fix => { latitude => 43.00242, longitude => -81.9419, timestamp => 2000 } }), 'none',
	'a device standing where it last filed files nothing' );

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
is( &subs::movement_choice({ choice => 'auto', signatorial => 'tablet', now => 12000, rows => [@creep] }), 'none',
	'and the creeping device itself is told to file nothing' );

# ------------------------------------- the tablet in the house, on its own
# The device filed the walk's first fix, then stayed in the house. Its own fixes
# wander a few metres at a time for as long as it is left on, and it is the only
# device this manager can see - the phone's fixes can be an hour behind, or never
# arrive. Its drift must not stand in for the trip.
my @home_alone;
for my $i ( 1 .. 40 ) {
	push @home_alone, fix( $i * 120000, 'tablet', 43.0024 + ( $i % 2 ? 0.00005 : -0.00005 ), -81.9419 );
}
is( &subs::movement_choice({ choice => 'auto', signatorial => 'tablet', now => 40 * 120000 + 120000, rows => [@home_alone],
	fix => { latitude => 43.00245, longitude => -81.9419, timestamp => 40 * 120000 + 120000 } }), 'none',
	'a device left in the house files nothing, even when it is the only one in view' );

# The same device, actually carried out of the house: its fix has left the place
# it last filed, so it records again - a tablet is not banned, it just has to move.
is( &subs::movement_choice({ choice => 'auto', signatorial => 'tablet', now => 40 * 120000 + 120000, rows => [@home_alone],
	fix => { latitude => 43.00375, longitude => -81.9419, timestamp => 40 * 120000 + 120000 } }), 'tablet',
	'and the same device carried out of the house files again' );

# A walk with a long stop in it: the gap since the last filed fix widens the test,
# but only to ten minutes' worth, so the second leg still records.
my @stopped = ( fix( 1, 'phone', 43.0000, -81 ) );
is( &subs::movement_choice({ choice => 'auto', signatorial => 'phone', now => 20 * 60000 + 120000, rows => [@stopped],
	fix => { latitude => 43.0018, longitude => -81, timestamp => 20 * 60000 + 120000 } }), 'phone',
	'a walk resumed after a long stop records its second leg' );

# ------------------------------------------ one activity, one device's track
# The appointment's distance reads the carrier's fixes only. The parked device's
# rows stay in the table - its own place and home plates keep running, and the
# person asked for that - they just do not make the track, or the kilometres it
# reports. Reading every row in time order is what zigzags the line: home, walk,
# home, walk, and a leg it never travelled between each pair.
my @both = ( @tablet, @walk );
my $track = &subs::carrier_track( \@both )->{'fixes'};
is( scalar @{ $track }, scalar @walk, 'the carrier\'s fixes make the track' );
is_deeply( [ sort keys %{ { map { $_->{'signatorial'} => 1 } @{$track} } } ], ['phone'],
	'and none of the device left at home' );
is( scalar @{ &subs::carrier_track( \@walk )->{'fixes'} }, scalar @walk, 'one device: the list is handed back whole' );
is_deeply( &subs::carrier_track( undef )->{'fixes'}, [], 'no rows is no track' );
is_deeply( &subs::carrier_track( [] )->{'fixes'}, [], 'an empty appointment is no track' );
is( scalar @{ &subs::carrier_track( Mojo::Collection->new( @both ) )->{'fixes'} }, scalar @walk,
	'a route\'s collection is read the same way' );

my $walk_metres = 0;
my $prev_fix;
foreach my $f ( sort { $a->{'timestamp'} <=> $b->{'timestamp'} } @{$track} ) {
	$walk_metres += &subs::geodesic_offset( $prev_fix->{'latitude'}, $prev_fix->{'longitude'}, $f->{'latitude'}, $f->{'longitude'} )->{'metres'} if $prev_fix;
	$prev_fix = $f;
}
my $zigzag_metres = 0;
$prev_fix = undef;
foreach my $f ( sort { $a->{'timestamp'} <=> $b->{'timestamp'} } @both ) {
	$zigzag_metres += &subs::geodesic_offset( $prev_fix->{'latitude'}, $prev_fix->{'longitude'}, $f->{'latitude'}, $f->{'longitude'} )->{'metres'} if $prev_fix;
	$prev_fix = $f;
}
cmp_ok( $walk_metres, '>', 800, 'the walk is measured' );
cmp_ok( $walk_metres, '<', 1000, 'and measured once, not twice' );
cmp_ok( $zigzag_metres, '>', 2 * $walk_metres, 'reading every row in time order is what zigzags it' );

# ---------------------------------------- the device with you changes mid-trip
# The phone records the first leg and then dies. The tablet, which was in the
# bag, carries on. The track is one leg each: the carrier's fixes up to where it
# stopped, then the next moving device's from where it took over.
my @swap;
for my $i ( 1 .. 5 ) {
	push @swap, fix( $i * 120000, 'phone', 43.0000 + $i * 0.0025, -81 );
}
my $resumed_at = 5 * 120000 + 20 * 60000;
for my $i ( 1 .. 5 ) {
	push @swap, fix( $resumed_at + $i * 120000, 'tablet', 43.0125 + $i * 0.0025, -81 );
}
my $swap_track = &subs::carrier_track( \@swap );
is_deeply( $swap_track->{'carriers'}, [ 'phone', 'tablet' ],
	'a carrier silent for a quarter of an hour hands the trip to the moving device' );
is( scalar @{ $swap_track->{'fixes'} }, 10, 'and both legs make the track' );
is( $swap_track->{'fixes'}[0]->{'signatorial'}, 'phone', 'the leg that was recorded first leads' );
is( $swap_track->{'fixes'}[-1]->{'signatorial'}, 'tablet', 'and the new carrier closes the trip' );

# The tablet was left in the house when the phone died. It must not inherit the
# trip: its drift is not a leg.
my @died = (@walk);
for my $i ( 1 .. 20 ) {
	push @died, fix( 400000 + $i * 30000, 'tablet', 43.0024 + ( $i % 2 ? 0.00005 : -0.00005 ), -81.9419 );
}
my $died_track = &subs::carrier_track( \@died );
is_deeply( $died_track->{'carriers'}, ['phone'], 'a parked device never inherits a trip from one that died' );
is( scalar @{ $died_track->{'fixes'} }, scalar @walk, 'the track is the leg that was actually recorded' );

# A short gap is not a handover: the carrier comes back, and what the other
# device filed meanwhile was a gap, not a leg.
my @blip = (
	fix( 1000, 'phone', 43.0000, -81 ),
	fix( 2000, 'phone', 43.0020, -81 ),
	fix( 150000, 'tablet', 43.0200, -81 ),
	fix( 250000, 'tablet', 43.0230, -81 ),
	fix( 260000, 'phone', 43.0040, -81 ),
	fix( 270000, 'phone', 43.0060, -81 ),
);
my $blip_track = &subs::carrier_track( \@blip );
is_deeply( $blip_track->{'carriers'}, ['phone'], 'a carrier that comes back keeps its trip' );
is( scalar @{ $blip_track->{'fixes'} }, 4, 'and the gap is not joined as a leg' );

# Two devices carried together both move, but only one records: the trip does not
# change hands just because the other one is also walking.
my @convoy;
for my $i ( 1 .. 5 ) {
	push @convoy, fix( $i * 120000, 'phone', 43 + $i * 0.0020, -81 );
	push @convoy, fix( $i * 120000 + 60000, 'tablet', 43 + $i * 0.0020, -81.0001 );
}
my $convoy_track = &subs::carrier_track( \@convoy );
is_deeply( $convoy_track->{'carriers'}, ['phone'], 'two devices travelling together still make one track' );
is( scalar @{ $convoy_track->{'fixes'} }, 5, 'and only the one that started makes it' );

# One device needs no decision: every fix it filed is the track.
my $one_track = &subs::carrier_track( \@walk );
is( scalar @{ $one_track->{'fixes'} }, scalar @walk, 'one device: every fix is the track' );
is_deeply( $one_track->{'carriers'}, [], 'and there is no handover to report' );

# Every door that files a fix into an activity asks one question, so a door
# added later cannot forget the rule. The answer is the device's own name, or
# 'none' when it should file nothing.
{
	no warnings 'redefine';
	local *subs::movement_recorder = sub { return 'phone' };
	is( &subs::movement_records_here({ signatorial => 'phone' }), 1, 'the carrying device files' );
	is( &subs::movement_records_here({ signatorial => 'tablet' }), 0, 'the other device does not' );
	local *subs::movement_recorder = sub { return 'none' };
	is( &subs::movement_records_here({ signatorial => 'tablet' }), 0, 'a trip nobody in view is carrying files nothing' );
	local *subs::movement_recorder = sub { return '' };
	is( &subs::movement_records_here({ signatorial => 'tablet' }), 1, 'no answer still files, so a trip can start' );
}

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

# ------------------------------------------- how long a stopped visit can resume
# The reopen window is three navigation intervals, capped at twenty minutes, so
# it follows the utility controller's navigation pace on the machine that
# produced the fix without letting a very slow pace hold an old visit.
use Mojo::JSON qw(encode_json);
{
	no warnings 'redefine';
	local *subs::signatorial_designer = sub { return 'sig' };
	local *subs::setting_grabber = sub {
		return encode_json({
			sig    => { navigation => { interval => 240 } },
			other  => { navigation => { interval => 600 } },
			brisk  => { navigation => { interval => 60 } },
		});
	};
	is(&subs::navigation_interval(), 240, 'the local navigation interval comes from the utility controller');
	is(&subs::navigation_interval('other'), 600, 'another machine reads its own interval');
	is(&subs::navigation_reopen_window('brisk'), 180_000, 'three intervals at a brisk pace');
	is(&subs::navigation_reopen_window('sig'), 720_000, 'and three at the default four-minute pace');
}
{
	no warnings 'redefine';
	local *subs::navigation_interval = sub { return 600 };
	is(&subs::navigation_reopen_window('slow'), 1_200_000, 'a slow pace is capped at twenty minutes');
	local *subs::navigation_interval = sub { return 3600 };
	is(&subs::navigation_reopen_window('slower'), 1_200_000, 'an hour-long pace is capped too');
}

my $appointment_src = read_file("$root/lib/JawnOS/Domain/Appointment.pm");
like($appointment_src, qr/my \$reopen_window = &subs::navigation_reopen_window\(\$signatorial\);/,
	'the plate asks the shared rule for its reopen window');
like($appointment_src, qr/return \$window > \$cap \? \$cap : \$window;/,
	'and the rule caps the window rather than scaling without bound');
unlike($appointment_src, qr/stop_timestamp >= \? order by stop_timestamp desc limit 1', \$app, 'navigation', 'stop', &subs::rightNow\(\) - 15 \* 60 \* 1000/,
	'and no longer the fixed fifteen minutes');

# No door may file a fix into an activity without asking the one-device rule: the
# record route, the "anyway" route, the headless navigator and the plate
# automation all ask it. A door that stops asking is the bug this test exists for.
like($appointment_src, qr/movement_records_here/, 'the plate automation asks the one-device rule');
foreach my $door (
	'lib/JawnOS/Manager/Part13.pm',
	'lib/JawnOS/Controller/manager_misc5.pm',
	'lib/JawnOS/Domain/Headless.pm',
) {
	like( read_file("$root/$door"), qr/movement_records_here/, "$door asks the one-device rule" );
}

# The appointment's own distance and list read the track carrier_track builds,
# so the number beside the appointment is the trip and not the trip plus the
# house - and a trip that changed devices is still one trip.
my $detail_src = read_file("$root/lib/JawnOS/Controller/manager_misc7.pm");
like( $detail_src, qr/my \$carried = &subs::carrier_track\(\$continental\);/,
	'the appointment distance reads the carrier track' );
like( $detail_src, qr/my \$track = \$carried->\{'fixes'\};/,
	'and every point and step comes from it' );
like( $detail_src, qr/\@\{ \$carried->\{'carriers'\}/,
	'and the carrier line names every device that carried it' );

# The Travel map draws the same track, so a handover there is one line too.
like( read_file("$root/lib/JawnOS/Controller/manager_travel.pm"),
	qr/my \$track = &subs::carrier_track\( \$by_appt\{\$appt\} \);/,
	'the travel map marks the track carrier_track builds' );

# Both halves use one silence window, so the fixes the record side files after a
# handover are exactly the ones the read side joins.
like( read_file("$root/lib/JawnOS/Domain/Device2.pm"), qr/movement_quiet_gap/,
	'the record side asks the shared silence window' );

# The headless navigator is the path an app on a phone actually takes, and it
# names the appointment it is filing for - not the machine's current place.
like( read_file("$root/lib/JawnOS/Domain/Headless.pm"),
	qr/movement_records_here\(\{ app => \$nd->\{'app'\}, appt => \$nd->\{'uuid'\}/,
	'the headless navigator asks for the appointment before filing a fix' );

done_testing();
