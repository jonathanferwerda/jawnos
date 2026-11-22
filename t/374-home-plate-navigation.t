# tests-for: lib/JawnOS/Domain/Appointment.pm lib/JawnOS/Domain/Headless.pm lib/JawnOS/Domain/Plates.pm
# covers:    navigation_automation and the headless information pass act on a
#            plate with many shapes, close the named session when the fix leaves,
#            and survive a malformed home_plate_duties row instead of aborting
#            every app behind it

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use Mojo::JSON qw(encode_json);

my $dir = JawnOSTest::isolate();

my $app      = 'hpnavtest';
my $bad_app  = 'hpnavbad';
my $now      = &subs::rightNow();
my $appt     = 'hpnav-appt-1';
my $start_sign = 'hpnav-sign-start';
my $stop_sign  = 'hpnav-sign-stop';
my $bad_sign   = 'hpnav-sign-bad';

# The isolated copy is otherwise a snapshot of the house. Remove every other
# duties row so a real plate can never be the one this test acts on.
my $rows = &subs::db_query("select uuid from settings where setting='home_plate_duties'")->hashes;
foreach my $row ( @{$rows} ) {
	&subs::db_delete('settings', { uuid => $row->{'uuid'} }) if defined $row->{'uuid'};
}

# A plate with many shapes: 300 small circles in a grid around the test point.
my @areas;
for my $i (0 .. 299) {
	push @areas, {
		shape => 'circle',
		lat => sprintf('%.7f', 43.0 + ($i % 20) * 0.0002),
		lon => sprintf('%.7f', -81.0 + int($i / 20) * 0.0002),
		radius_m => 25,
	};
}
my $duty = { uuid => 'hpnav-duty-many', placement => 'within', action => 'start', areas => \@areas };
&subs::setting_setter({ app => $app, setting => 'home_plate_duties', value => encode_json([ $duty ]) });
&subs::setting_setter({ app => $app, setting => 'toggle', value => 'off' });
&subs::setting_setter({ app => $app, setting => 'site_type', value => 'public' });

# The plate itself is the duty's own ground.
ok( &subs::plate_contains(&subs::plate_ground_for($duty, {}), 43.0, -81.0),
	'the fixture plate contains the inside fix' );
ok( !&subs::plate_contains(&subs::plate_ground_for($duty, {}), 44.0, -82.0),
	'and not the outside fix' );

my @writes;
{
	no warnings 'redefine';
	local *Manager::appointment_writer = sub { push @writes, [ @_ ]; return 1 };
	local *subs::navigation_information = sub { return {} };
	&subs::navigation_automation({
		signatorial => $start_sign,
		latitude => 43.0, longitude => -81.0, accuracy => '5', timestamp => $now,
	}, 'gps');
}
is( scalar @writes, 1, 'an inside fix on a 300-shape plate acts once' );
is( $writes[0]->[1]->{'type'}, 'start', 'and starts the app' );
is( $writes[0]->[1]->{'app'}, $app, 'for the plate\'s own app' );

# A running navigation session is what the plate is leaving.
&subs::db_insert('appointments', {
	app => $app, uuid => $appt, type => 'start', subtype => 'navigation',
	timestamp => $now - 60000, server_time => $now - 60000,
	stop_seen => undef, autostop => undef, warranty => '-1h',
});

@writes = ();
{
	no warnings 'redefine';
	local *Manager::appointment_writer = sub { push @writes, [ @_ ]; return 1 };
	local *subs::navigation_information = sub { return {} };
	&subs::navigation_automation({
		signatorial => $stop_sign,
		latitude => 44.0, longitude => -82.0, accuracy => '5', timestamp => $now,
	}, 'gps');
}
is( scalar @writes, 1, 'an outside fix acts once' );
is( $writes[0]->[1]->{'type'}, 'stop', 'and stops the running session' );
is( $writes[0]->[1]->{'uuid'}, $appt, 'closing exactly the named row' );

# A malformed row must not take the whole pass down before the next app.
&subs::setting_setter({ app => $bad_app, setting => 'home_plate_duties', value => '{"not":"an array"}' });

my $nav_ok = eval {
	local $SIG{'__WARN__'} = sub { };
	local *subs::navigation_information = sub { return {} };
	&subs::navigation_automation({
		signatorial => $bad_sign,
		latitude => 43.0, longitude => -81.0, accuracy => '5', timestamp => $now,
	}, 'gps');
	1;
};
ok( $nav_ok, 'navigation_automation survives a malformed home_plate_duties row' )
	or diag("died: $@");

my $headless_ok = eval {
	local $SIG{'__WARN__'} = sub { };
	&subs::navigation_information({});
	1;
};
ok( $headless_ok, 'the headless information pass survives a malformed row' )
	or diag("died: $@");

done_testing();
