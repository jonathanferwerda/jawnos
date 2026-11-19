# tests-for: lib/JawnOS/Domain/Appointment.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Log.pm lib/JawnOS/Manager/Part16.pm scripts/jawnos_game_launch.pl perl/help/topics_people.pl
# covers: a GOU game session starts at the launch, pauses when the controls go quiet, resumes the same row within five minutes, and leaves the pause out of the play time; a browser game does the same, a play on an already-open row after a quiet spell is a pause, and a short browser play is kept with its own-app child

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
	# source_appt_writer builds a controller for the house writer; this test has
	# no Manager app object, so hand it an empty one and capture the child row.
	local *subs::controller_builder = sub { return {} };
	# The browser game's option writes its own app through the house writer; this
	# test wants the row it writes, not the window and bookkeeping around it.
	local *Manager::appointment_writer = sub {
		my ($c, $row) = @_;
		my %r = %{$row};
		delete $r{'quiet_child'};
		&subs::db_insert('appointments', \%r);
		return \%r;
	};
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
	ok( (int( $rows->[0]->{'warranty'} ) > $NOW ), 'and it carries a warranty ahead of now' );

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
	my $solitaire_rows = sub {
		my ($parent_uuid) = @_;
		return &subs::db_query('select * from appointments where app = ? and source_uuid = ? order by cast(timestamp as integer)', 'solitaire', $parent_uuid)->hashes || [];
	};
	# A hand-made option wrote the name in whatever case the person chose. The
	# browser's lookup must find it rather than make a second row, keeping the
	# one the person already had and giving it the game's own spelling.
	&subs::db_delete('option', { app => 'games' });
	&subs::db_delete('option_category', { app => 'games' });
	&subs::db_insert('option', {
		app => 'games', name => 'solitaire', uuid => 'hand-made-solitaire',
		timestamp => $b1 - 1_000, server_time => $b1 - 1_000,
		def => 'false', quantity => 1, unit => 'games', save_app => 'on', description => 'Solitaire',
	});

	$NOW = $b1 + 1_000;
	my $answer = &subs::browser_game_play({ device => $browser_device, game => 'Solitaire', state => 'play', at => $b1 });
	is( $answer->{'ok'}, 1, 'a browser play starts a session' );
	my $browsed = $browser->();
	is( scalar @{$browsed}, 1, 'one browser game appointment' );
	is( $browsed->[0]->{'type'}, 'start', 'running' );
	is( $browsed->[0]->{'project'}, 'Solitaire', 'named for its game' );
	is( $browsed->[0]->{'source'}, 'browser_game', 'and marked as the browser’s' );
	ok( (int( $browsed->[0]->{'warranty'} ) > $NOW ), 'with a warranty the culler can retire it by' );
	my $browser_uuid = $browsed->[0]->{'uuid'};

	my $browser_row = &subs::db_query('select * from appointments where uuid = ?', $browser_uuid)->hash;
	my $browser_options = eval { decode_json($browser_row->{'options'}) } || [];
	is( scalar @{$browser_options}, 1, 'the game is an option of the appointment' );
	is( $browser_options->[0]->{'name'}, 'Solitaire', 'named Solitaire' );
	my $browser_catalog = &subs::db_select('option', undef, { app => 'games', name => 'Solitaire' })->hashes->[0];
	ok( $browser_catalog->{'uuid'}, 'with a row in the model/option table' );
	is( $browser_catalog->{'uuid'}, 'hand-made-solitaire', 'the hand-made row is reused, not duplicated' );
	my $game_rows = &subs::db_query("select * from option where app = 'games' and lower(name) = 'solitaire'")->hashes;
	is( scalar @{$game_rows}, 1, 'one catalog row per game, whatever the name case' );
	is( $browser_catalog->{'def'}, 'off', 'and it is not a default option' );
	is( $browser_catalog->{'save_app'}, 'on', 'a game option records its own app' );
	my $games_category = &subs::db_select('option_category', undef, { app => 'games', uuid => 'games_option_category_v1' })->hashes->[0];
	ok( $games_category && $games_category->{'name'} eq 'Games', 'the option is filed under a Games category' );
	my $browser_chars = eval { decode_json($browser_catalog->{'characteristics'}) } || [];
	is( ($browser_chars->[0] // {})->{'value'}, 'games_option_category_v1',
		'and the catalog row points at that category' );
	# the game's own app is the existing `solitaire`, written by unformat_name
	my $solitaire = $solitaire_rows->($browser_uuid);
	is( scalar @{$solitaire}, 1, 'the game also records its own app' );
	is( $solitaire->[0]->{'app'}, 'solitaire', 'under the unformatted app key' );
	is( $solitaire->[0]->{'type'}, 'start', 'running with the play session' );
	is( int( $solitaire->[0]->{'timestamp'} ), $b1, 'from the play session start' );

	# a quiet game pauses at the last touch
	$NOW = $b1 + 50_000;
	&subs::browser_game_play({ device => $browser_device, game => 'Solitaire', state => 'pause', at => $b1 + 20_000 });
	$browsed = $browser->();
	is( $browsed->[0]->{'type'}, 'stop', 'the quiet browser game pauses' );
	is( int( $browsed->[0]->{'stop_timestamp'} ), $b1 + 20_000, 'at the last touch' );
	is( int( $browsed->[0]->{'duration'} ), -20_000, 'with the first play segment' );
	$solitaire = $solitaire_rows->($browser_uuid);
	is( $solitaire->[0]->{'type'}, 'stop', 'the child pauses with the session' );
	is( int( $solitaire->[0]->{'stop_timestamp'} ), $b1 + 20_000, 'at the same last touch' );
	is( int( $solitaire->[0]->{'duration'} ), -20_000, 'with the same play time' );

	# a touch within five minutes resumes the same row
	$NOW = $b1 + 90_000;
	&subs::browser_game_play({ device => $browser_device, game => 'Solitaire', state => 'play', at => $b1 + 80_000 });
	$browsed = $browser->();
	is( scalar @{$browsed}, 1, 'a resume does not make a second appointment' );
	is( $browsed->[0]->{'uuid'}, $browser_uuid, 'the same row reopens' );
	is( $browsed->[0]->{'type'}, 'start', 'and it runs again' );
	$solitaire = $solitaire_rows->($browser_uuid);
	is( $solitaire->[0]->{'type'}, 'start', 'the child resumes with the session' );
	ok( !defined $solitaire->[0]->{'stop_seen'}, 'and is open again' );

	# leaving stops it, with the pause left out of the play time
	$NOW = $b1 + 140_000;
	&subs::browser_game_play({ device => $browser_device, game => 'Solitaire', state => 'stop', at => $b1 + 120_000 });
	$browsed = $browser->();
	is( $browsed->[0]->{'type'}, 'stop', 'leaving closes the session' );
	is( int( $browsed->[0]->{'duration'} ), -60_000, '20s + 40s of play, the 60s pause left out' );
	$solitaire = $solitaire_rows->($browser_uuid);
	is( scalar @{$solitaire}, 1, 'still one row in the game\'s own app' );
	is( $solitaire->[0]->{'type'}, 'stop', 'the child stops with the session' );
	is( int( $solitaire->[0]->{'duration'} ), -60_000, 'and keeps the same play time' );

	# another game on the same device is its own row
	$NOW = $b1 + 150_000;
	&subs::browser_game_play({ device => $browser_device, game => 'Twirl', state => 'play', at => $b1 + 150_000 });
	$browsed = $browser->();
	is( scalar @{$browsed}, 2, 'Twirl gets its own session' );
	is( ($browsed->[1]->{'project'} // ''), 'Twirl', 'named Twirl' );

	# Spider Solitaire is a play session, and its own app records the same span
	my $spider_start = $b1 + 200_000;
	$NOW = $spider_start;
	&subs::browser_game_play({ device => $browser_device, game => 'Spider Solitaire', state => 'play', at => $spider_start });
	my ($spider) = grep { ($_->{'project'} // '') eq 'Spider Solitaire' } @{ $browser->() };
	ok( $spider && $spider->{'uuid'}, 'Spider Solitaire starts its own session' );
	my $spider_uuid = $spider ? ($spider->{'uuid'} // '') : '';
	my $spider_child = &subs::db_query(
		'select * from appointments where app = ? and source_uuid = ?', 'spider_solitaire', $spider_uuid
	)->hashes || [];
	is( scalar @{$spider_child}, 1, 'and records the game\'s own app' );
	is( ($spider_child->[0] // {})->{'app'}, 'spider_solitaire', 'under the unformatted app key' );
	$NOW = $spider_start + 60_000;
	&subs::browser_game_play({ device => $browser_device, game => 'Spider Solitaire', state => 'stop', at => $NOW });

	is( &subs::browser_game_play({ device => $browser_device, game => 'Tarot', state => 'play' })->{'ok'}, 0,
		'tarot is not a play session' );

	# a play that lands on a still-open row after a quiet spell is a reopened
	# window, not continuous play: the gap is a pause and is left out
	my $bj_start = $b1 + 1_000_000;
	$NOW = $bj_start;
	&subs::browser_game_play({ device => $browser_device, game => 'Blackjack', state => 'play', at => $bj_start });
	$NOW = $bj_start + 10 * 60_000;
	&subs::browser_game_play({ device => $browser_device, game => 'Blackjack', state => 'play', at => $NOW });
	$NOW = $bj_start + 10 * 60_000 + 120_000;
	&subs::browser_game_play({ device => $browser_device, game => 'Blackjack', state => 'stop', at => $NOW });
	my ($bj) = grep { ($_->{'project'} // '') eq 'Blackjack' } @{ $browser->() };
	is( int( $bj->{'duration'} ), -120_000, 'the quiet spell on an open row is a pause, not play' );

	# a browser play is touch-started, so a short stop with measured play is kept
	my $short_start = $NOW + 10_000;
	$NOW = $short_start;
	&subs::browser_game_play({ device => $browser_device, game => 'Mahjong', state => 'play', at => $short_start });
	my ($short) = grep { ($_->{'project'} // '') eq 'Mahjong' } @{ $browser->() };
	ok( $short && $short->{'uuid'}, 'a short game starts a session' );
	my $short_uuid = $short->{'uuid'};
	$NOW = $short_start + 20_000;
	&subs::browser_game_play({ device => $browser_device, game => 'Mahjong', state => 'stop', at => $NOW });
	my @short_rows = grep { ($_->{'project'} // '') eq 'Mahjong' } @{ $browser->() };
	is( scalar @short_rows, 1, 'a browser game under a minute is kept' );
	is( int( $short_rows[0]->{'duration'} ), -20_000, 'with its measured play' );
	is( scalar @{ &subs::db_query('select uuid from appointments where source_uuid = ?', $short_uuid)->hashes }, 1,
		'and the game\'s own app child stays' );
}

my $helper = read_file(root() . '/scripts/jawnos_game_launch.pl');
like($helper, qr/\$STATUS\{'state'\} = 'running'/, 'the helper marks the game running for the tick');

# A play session measures the play. Games carries a usual `duration` setting
# (the default length for a hand-made appointment), and neither the timeline nor
# a future/just-started bar may borrow it for a game.
my $log_pm = read_file(root() . '/lib/JawnOS/Domain/Log.pm');
like($log_pm, qr/my \$play_session = .*?eq 'games';.*?if \(!\$a->\{'duration'\} && !\$play_session/s,
	'the timeline keeps the usual duration off a play session');
my $part16 = read_file(root() . '/lib/JawnOS/Manager/Part16.pm');
like($part16, qr/\? 0 : &subs::time_abbrev_translator\(\$settings->\{'duration'\}\)/,
	'and a future play bar is zero, not the setting');

done_testing();
