# tests-for: lib/JawnOS/Domain/Appointment.pm lib/JawnOS/Domain/Loader.pm scripts/jawnos_game_launch.pl perl/help/topics_people.pl
# covers: a GOU game session starts at the launch, pauses when the controls go quiet, resumes the same row within five minutes, and leaves the pause out of the play time

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use Mojo::JSON qw(encode_json decode_json);
use JawnOSTest;

# Force the lazy domain modules the tick reaches before overriding their subs.
require JawnOS::Domain::Appointment;
require JawnOS::Domain::Name;
require JawnOS::Domain::Calendar;
require JawnOS::Domain::Generate;
require JawnOS::Domain::Resolve;
require JawnOS::Domain::Render;
require JawnOS::Domain::Say;
require JawnOS::Domain::Embedded2;
require JawnOS::Domain::File;

my $dir = tempdir('jawnos-games-XXXXXX', TMPDIR => 1, CLEANUP => 1);
$ENV{'JAWNOS_GAMES_STATE'} = $dir;
my $app  = 'games';
my $NOW  = 1_800_000_000_000;
my $base = $NOW - 10 * 60_000;
my %cache;

sub launch_state {
	my ($state, $at, $finished) = @_;
	my $data = { state => $state, at => int($at / 1000), game => 'g1', title => 'Test Game' };
	$data->{'finished'} = int($finished / 1000) if defined $finished;
	write_file("$dir/launch.json", encode_json($data));
}

sub activity {
	write_file("$dir/activity", int($_[0]) . "\n");
}

sub sessions {
	return &subs::db_query('select * from appointments where app = ? order by cast(timestamp as integer)', $app)->hashes || [];
}

{
	no warnings 'redefine';
	no warnings 'once';
	local *subs::rightNow = sub { $NOW };
	local *subs::setting_grabber = sub { return '' };
	local *subs::settings_grabber = sub { return {} };
	local *subs::device_setter = sub { return 'computer' };
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

	&subs::db_delete('appointments', { app => $app });

	# the launch is the start; the first control is 20 seconds in
	launch_state('running', $base);
	activity($base + 20_000);
	$NOW = $base + 25_000;
	is( &subs::game_play_appointment_tick( { force => 1 } ), 1, 'the launch starts a session' );
	my $rows = sessions();
	is( scalar @{$rows}, 1, 'one game appointment' );
	my $uuid = $rows->[0]->{'uuid'};
	is( $rows->[0]->{'type'}, 'start', 'running' );
	is( int( $rows->[0]->{'timestamp'} ), $base, 'it starts at the launch' );

	# no touch for over 30 seconds: a pause at the last control
	$NOW = $base + 60_000;
	&subs::game_play_appointment_tick( { force => 1 } );
	$rows = sessions();
	is( $rows->[0]->{'type'}, 'stop', 'the quiet game pauses' );
	is( int( $rows->[0]->{'stop_timestamp'} ), $base + 20_000, 'at the last control' );
	is( int( $rows->[0]->{'duration'} ), -20_000, 'with the first play segment' );

	# no new control: the paused game must not start a fresh session each tick
	$NOW = $base + 70_000;
	&subs::game_play_appointment_tick( { force => 1 } );
	$rows = sessions();
	is( scalar @{$rows}, 1, 'a paused game without a touch makes no new session' );
	is( $rows->[0]->{'type'}, 'stop', 'and stays paused' );

	# a touch within five minutes resumes the same row
	activity($base + 80_000);
	$NOW = $base + 90_000;
	&subs::game_play_appointment_tick( { force => 1 } );
	$rows = sessions();
	is( scalar @{$rows}, 1, 'a resume does not make a second appointment' );
	is( $rows->[0]->{'uuid'}, $uuid, 'the same row is reopened' );
	is( $rows->[0]->{'type'}, 'start', 'and it is running' );

	# the game ends: the 60-second pause is left out of the play time
	activity($base + 120_000);
	launch_state('done', $base, $base + 130_000);
	$NOW = $base + 140_000;
	&subs::game_play_appointment_tick( { force => 1 } );
	$rows = sessions();
	is( scalar @{$rows}, 1, 'still one appointment' );
	is( $rows->[0]->{'type'}, 'stop', 'closed when the game ends' );
	is( int( $rows->[0]->{'stop_timestamp'} ), $base + 120_000, 'at the last control' );
	is( int( $rows->[0]->{'duration'} ), -60_000, '20s + 40s of play, the 60s pause left out' );

	# ---- a browser game reports its own touches ----
	my $browser_device = 'phone';
	my $b1 = $base + 200_000;
	my $browser = sub {
		return &subs::db_query('select * from appointments where app = ? and source = ? and device = ? order by cast(timestamp as integer)', $app, 'browser_game', $browser_device)->hashes || [];
	};

	$NOW = $b1 + 1_000;
	my $answer = &subs::browser_game_play({ device => $browser_device, game => 'Solitaire', state => 'play', at => $b1 });
	is( $answer->{'ok'}, 1, 'a browser play starts a session' );
	my $browsed = $browser->();
	is( scalar @{$browsed}, 1, 'one browser game appointment' );
	is( $browsed->[0]->{'type'}, 'start', 'running' );
	is( $browsed->[0]->{'project'}, 'Solitaire', 'named for its game' );
	is( $browsed->[0]->{'source'}, 'browser_game', 'and marked as the browser’s' );
	my $browser_uuid = $browsed->[0]->{'uuid'};

	my $browser_row = &subs::db_query('select * from appointments where uuid = ?', $browser_uuid)->hash;
	my $browser_options = eval { decode_json($browser_row->{'options'}) } || [];
	is( scalar @{$browser_options}, 1, 'the game is an option of the appointment' );
	is( $browser_options->[0]->{'name'}, 'Solitaire', 'named Solitaire' );
	my $browser_catalog = &subs::db_select('option', undef, { app => 'games', name => 'Solitaire' })->hashes->[0];
	ok( $browser_catalog->{'uuid'}, 'with a row in the model/option table' );
	is( $browser_catalog->{'def'}, 'off', 'and it is not a default option' );

	# a quiet game pauses at the last touch
	$NOW = $b1 + 50_000;
	&subs::browser_game_play({ device => $browser_device, game => 'Solitaire', state => 'pause', at => $b1 + 20_000 });
	$browsed = $browser->();
	is( $browsed->[0]->{'type'}, 'stop', 'the quiet browser game pauses' );
	is( int( $browsed->[0]->{'stop_timestamp'} ), $b1 + 20_000, 'at the last touch' );
	is( int( $browsed->[0]->{'duration'} ), -20_000, 'with the first play segment' );

	# a touch within five minutes resumes the same row
	$NOW = $b1 + 90_000;
	&subs::browser_game_play({ device => $browser_device, game => 'Solitaire', state => 'play', at => $b1 + 80_000 });
	$browsed = $browser->();
	is( scalar @{$browsed}, 1, 'a resume does not make a second appointment' );
	is( $browsed->[0]->{'uuid'}, $browser_uuid, 'the same row reopens' );
	is( $browsed->[0]->{'type'}, 'start', 'and it runs again' );

	# leaving stops it, with the pause left out of the play time
	$NOW = $b1 + 140_000;
	&subs::browser_game_play({ device => $browser_device, game => 'Solitaire', state => 'stop', at => $b1 + 120_000 });
	$browsed = $browser->();
	is( $browsed->[0]->{'type'}, 'stop', 'leaving closes the session' );
	is( int( $browsed->[0]->{'duration'} ), -60_000, '20s + 40s of play, the 60s pause left out' );

	# another game on the same device is its own row
	$NOW = $b1 + 150_000;
	&subs::browser_game_play({ device => $browser_device, game => 'Twirl', state => 'play', at => $b1 + 150_000 });
	$browsed = $browser->();
	is( scalar @{$browsed}, 2, 'Twirl gets its own session' );
	is( ($browsed->[1]->{'project'} // ''), 'Twirl', 'named Twirl' );

	is( &subs::browser_game_play({ device => $browser_device, game => 'Tarot', state => 'play' })->{'ok'}, 0,
		'tarot is not a play session' );
}

my $helper = read_file(root() . '/scripts/jawnos_game_launch.pl');
like($helper, qr/\$STATUS\{'state'\} = 'running'/, 'the helper marks the game running for the tick');

done_testing();
