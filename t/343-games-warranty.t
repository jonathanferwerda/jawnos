# tests-for: lib/JawnOS/Domain/Appointment.pm lib/JawnOS/Domain/Render.pm
# covers:    a Games play session is born with a warranty: the first run adopts
#            the house's `me` default (through setting_initializer, like
#            appointment_writer), later runs read the row it adopted, and the
#            row is never stamped with a warranty that is already behind now.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

require JawnOS::Domain::Appointment;
require JawnOS::Domain::Name;
require JawnOS::Domain::Resolve;
require JawnOS::Domain::Render;
require JawnOS::Domain::Calendar;
require JawnOS::Domain::Generate;
require JawnOS::Domain::Embedded2;
require JawnOS::Domain::File;

my $NOW  = 1_800_000_000_000;
my $game = 'Solitaire';
my $device = 'phone';
my %cache;

{
	no warnings 'redefine';
	no warnings 'once';
	local *subs::rightNow = sub { $NOW };
	local *subs::device_setter = sub { $device };
	local *subs::intelligent_automation_toggle = sub { return 1 };
	local *Websocket::send = sub { return 1 };
	# source_appt_writer builds a controller for the house writer; this test has
	# no Manager app object, so hand it an empty one and capture the child row.
	local *subs::controller_builder = sub { return {} };
	local *Manager::appointment_writer = sub {
		my ($c, $row) = @_;
		my %r = %{$row};
		delete $r{'quiet_child'};
		&subs::db_insert('appointments', \%r);
		return \%r;
	};
	local *subs::cache_set = sub {
		$cache{ ( $_[0]->{'context'} // '' ) . '|' . ( $_[0]->{'subcontext'} // '' ) } = $_[1];
		return 1;
	};
	local *subs::cache_get = sub {
		return $cache{ ( $_[0]->{'context'} // '' ) . '|' . ( $_[0]->{'subcontext'} // '' ) };
	};
	local *subs::cache_delete = sub {
		delete $cache{ ( $_[0]->{'context'} // '' ) . '|' . ( $_[0]->{'subcontext'} // '' ) };
		return 1;
	};

	&subs::db_delete('appointments', { app => 'games' });
	&subs::db_delete('settings', { app => 'games' });
	&subs::db_delete('settings', { app => 'me', setting => 'warranty' });

	# The house default a new app is born with. It is deliberately not the
	# writer's -10y fallback, so the assertions can tell them apart.
	&subs::db_insert('settings', {
		app => 'me', setting => 'warranty', value => '-7y', device => 'all',
		timestamp => $NOW, server_time => $NOW, uuid => 'me-warranty-1',
	});

	my $answer = &subs::browser_game_play({ device => $device, game => $game, state => 'play', at => $NOW });
	is( $answer->{'ok'}, 1, 'the first play starts a session' );

	my $row = &subs::db_query('select * from appointments where app = ? and source = ? and device = ?', 'games', 'browser_game', $device)->hash;
	ok( $row && $row->{'uuid'}, 'the play appointment is written' );
	is( $row->{'warranty'}, &subs::ago_calc('-7y', $NOW), 'and it carries the me default warranty' );

	my $seeded = &subs::db_query('select * from settings where app = ? and setting = ?', 'games', 'warranty')->hashes;
	is( scalar @{$seeded}, 1, 'the app adopted a warranty row of its own on the first run' );
	is( $seeded->[0]->{'value'}, '-7y', 'with the me default value' );
	is( $seeded->[0]->{'device'}, 'all', 'and it is the house row every machine reads' );

	# A later run reads the row it adopted, not the house default again.
	&subs::db_query('update settings set value = ? where app = ? and setting = ?', '-3y', 'games', 'warranty');
	my $later = $NOW + 10 * 60_000;
	$NOW = $later;
	&subs::browser_game_play({ device => $device, game => 'Twirl', state => 'play', at => $later });
	my $twirl = &subs::db_query('select * from appointments where app = ? and source = ? and project = ?', 'games', 'browser_game', 'Twirl')->hash;
	ok( $twirl && $twirl->{'uuid'}, 'a later play is written' );
	is( $twirl->{'warranty'}, &subs::ago_calc('-3y', $later), 'and it reads the adopted value' );
}

done_testing();
