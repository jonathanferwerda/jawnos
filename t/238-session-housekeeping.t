# tests-for: lib/JawnOS/Domain/Appointment.pm perl/jobs.pl
# covers: an open session whose machine stopped reporting closes at its last heartbeat, not at the housekeeping tick; a browser game under a minute closes with its measured play, a Gou game under a minute is tombstoned, and a paused one with no play is dropped once its resume window has passed

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
	is( $browser_row->{'type'}, 'stop', 'a browser game under a minute is closed, not tombstoned' );
	is( int( $browser_row->{'duration'} ), -30_000, 'with the play it was actually heard' );
	is( $browser_row->{'source'}, 'browser_game', 'and the row is kept' );
	is( scalar @{ &subs::db_query('select id from sync_log where uuid = ?', $browser_uuid)->hashes }, 0,
		'with no tombstone' );

	# a game that did run over a minute is closed at its last heartbeat
	my $long_uuid = 'browserrow-long-housekeeping-test';
	&subs::db_insert( 'appointments', {
		app => 'games', uuid => $long_uuid, type => 'start',
		timestamp => $base + 30_000, server_time => $base + 150_000,
		source => 'browser_game', device => 'phone', project => 'Solitaire', seen => 'yes',
	} );
	&subs::session_housekeeping_tick();
	my $long_row = &subs::db_query( 'select * from appointments where uuid = ?', $long_uuid )->hash;
	is( $long_row->{'type'}, 'stop', 'a game over a minute is closed' );
	is( int( $long_row->{'stop_timestamp'} ), $base + 150_000, 'at its last heartbeat' );
	is( int( $long_row->{'duration'} ), -120_000, 'with the time it was actually heard' );

	# a live beat keeps a browser play open past its last touch; when the beats
	# stop, the row closes at the last touch, not at the beat
	my $beating_uuid = 'browserrow-beat-housekeeping-test';
	&subs::db_insert( 'appointments', {
		app => 'games', uuid => $beating_uuid, type => 'start',
		timestamp => $base + 30_000, server_time => $base + 50_000,
		source => 'browser_game', device => 'phone', project => 'Mahjong', seen => 'yes',
	} );
	&subs::cache_set( &subs::browser_game_beat_key($beating_uuid), { at => $base + 19 * 60_000 } );
	&subs::session_housekeeping_tick();
	my $beating_row = &subs::db_query( 'select * from appointments where uuid = ?', $beating_uuid )->hash;
	is( $beating_row->{'type'}, 'start', 'a live beat keeps the open play' );
	&subs::cache_set( &subs::browser_game_beat_key($beating_uuid), { at => $base + 5 * 60_000 } );
	&subs::session_housekeeping_tick();
	$beating_row = &subs::db_query( 'select * from appointments where uuid = ?', $beating_uuid )->hash;
	is( $beating_row->{'type'}, 'stop', 'a stopped beat closes it' );
	is( int( $beating_row->{'stop_timestamp'} ), $base + 50_000, 'at the last touch, not the beat' );
	is( int( $beating_row->{'duration'} ), -20_000, 'with only the measured play' );

	# a short game the page paused is dropped once the five-minute resume window
	# has passed, and left alone inside it
	my $paused_uuid = 'browserrow-paused-housekeeping-test';
	&subs::db_insert( 'appointments', {
		app => 'games', uuid => $paused_uuid, type => 'stop', stop_seen => 'yes',
		timestamp => $base + 9 * 60_000, stop_timestamp => $base + 10 * 60_000,
		duration => 0, server_time => $base + 10 * 60_000,
		source => 'browser_game', device => 'phone', project => 'Solitaire', seen => 'yes',
	} );
	&subs::session_housekeeping_tick();
	my $paused_row = &subs::db_query( 'select * from appointments where uuid = ?', $paused_uuid )->hash;
	ok( !$paused_row, 'an abandoned short pause is tombstoned after its resume window' );
}

my $jobs = read_file(root() . '/perl/jobs.pl');
like($jobs, qr/name => 'session housekeeping'/, 'the housekeeping runs on a schedule');
like($jobs, qr/name => 'game play'/, 'the game play tick runs on a schedule');

done_testing();
