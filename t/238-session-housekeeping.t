# tests-for: lib/JawnOS/Domain/Appointment.pm perl/jobs.pl
# covers: an open session whose machine stopped reporting closes at its last heartbeat, not at the housekeeping tick

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

require JawnOS::Domain::Appointment;
require JawnOS::Domain::File;

my $NOW  = 1_800_000_000_000;
my $base = $NOW - 20 * 60_000;
my %cache;

{
	no warnings 'redefine';
	no warnings 'once';
	local *subs::rightNow = sub { $NOW };
	local *subs::intelligent_automation_toggle = sub { return 1 };
	local *Websocket::send = sub { return 1 };
	local *subs::cache_set = sub {
		my ( $key, $value ) = @_;
		$cache{ ( $key->{'context'} // '' ) . '|' . ( $key->{'subcontext'} // '' ) } = $value;
		return 1;
	};
	local *subs::cache_get = sub {
		my ($key) = @_;
		return $cache{ ( $key->{'context'} // '' ) . '|' . ( $key->{'subcontext'} // '' ) };
	};
	local *subs::cache_delete = sub {
		my ($key) = @_;
		delete $cache{ ( $key->{'context'} // '' ) . '|' . ( $key->{'subcontext'} // '' ) };
		return 1;
	};

	my $uuid = 'ghostrow-housekeeping-test';
	&subs::db_insert( 'appointments', {
		app        => 'ghostapp',
		uuid       => $uuid,
		type       => 'start',
		timestamp  => $base,
		server_time => $base + 60_000,
		source     => 'internet',
		device     => 'computer',
		seen       => 'yes',
	} );

	my $closed = &subs::session_housekeeping_tick();
	cmp_ok( $closed, '>=', 1, 'the housekeeping closes the forgotten session' );
	my $row = &subs::db_query( 'select * from appointments where uuid = ?', $uuid )->hash;
	is( $row->{'type'}, 'stop', 'as a stop' );
	is( int( $row->{'stop_timestamp'} ), $base + 60_000, 'at the last heartbeat' );
	is( int( $row->{'duration'} ), -60_000, 'with the time it was actually heard' );
	ok( !defined $row->{'stop_seen'} || $row->{'stop_seen'} eq 'yes', 'and it is sealed' );

	my $browser_uuid = 'browserrow-housekeeping-test';
	&subs::db_insert( 'appointments', {
		app => 'games',
		uuid => $browser_uuid,
		type => 'start',
		timestamp => $base + 30_000,
		server_time => $base + 60_000,
		source => 'browser_game',
		device => 'phone',
		project => 'Solitaire',
		seen => 'yes',
	} );

	my $closed_browser = &subs::session_housekeeping_tick();
	cmp_ok( $closed_browser, '>=', 1, 'the housekeeping closes a forgotten browser game' );
	my $browser_row = &subs::db_query( 'select * from appointments where uuid = ?', $browser_uuid )->hash;
	is( $browser_row->{'type'}, 'stop', 'as a stop' );
	is( int( $browser_row->{'stop_timestamp'} ), $base + 60_000, 'at its last heartbeat' );
	is( int( $browser_row->{'duration'} ), -30_000, 'with the time it was heard' );
}

my $jobs = read_file(root() . '/perl/jobs.pl');
like($jobs, qr/name => 'session housekeeping'/, 'the housekeeping runs on a schedule');
like($jobs, qr/name => 'game play'/, 'the game play tick runs on a schedule');

done_testing();
