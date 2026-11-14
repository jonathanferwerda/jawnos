# tests-for: lib/JawnOS/Domain/Accounting.pm lib/JawnOS/Domain/Appointment.pm
# covers:    one Games option category, one catalog row per game, and the game's
#            own app: a hand-made lowercase `solitaire` option and the browser's
#            `Solitaire` collapse to one row, every appointment's options list
#            is repointed at the row that survives, and save_app is restored so
#            the game records the existing `solitaire` app.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use Mojo::JSON qw(decode_json encode_json);

require JawnOS::Domain::Accounting;
require JawnOS::Domain::Appointment;

my $now = 1_800_000_000_000;

&subs::db_delete('option', { app => 'games' });
&subs::db_delete('option_category', { app => 'games' });
&subs::db_delete('appointments', { app => 'games' });

# A person made an option by hand for the game they already tracked, in lower
# case and with save_app on; the browser later made its own row for the same
# game. The appointment that selected the hand-made one names it in its options
# list, which is what the details view reads.
&subs::db_insert('option', {
	app => 'games', name => 'solitaire', uuid => 'hand-made-solitaire',
	timestamp => $now - 2_000, server_time => $now - 2_000,
	def => 'false', quantity => 1, unit => 'games', save_app => 'on', description => 'Solitaire',
});
&subs::db_insert('option', {
	app => 'games', name => 'Solitaire', uuid => 'browser-solitaire',
	timestamp => $now - 1_000, server_time => $now - 1_000,
	def => 'off', quantity => 1, unit => 'games', save_app => '', description => 'Solitaire',
});
&subs::db_insert('appointments', {
	app => 'games', uuid => 'appt-games-1', type => 'stop', timestamp => $now - 1_500,
	server_time => $now - 1_500, seen => 'yes', stop_seen => 'yes',
	options => encode_json([ {
		uuid => 'hand-made-solitaire', name => 'solitaire', quantity => 1, unit => 'games', timestamp => $now - 1_500,
	} ]),
});

my $backfills = &subs::backfills();
ok( $backfills->{'games_options_v1'}, 'the games-options backfill is registered' );
ok( $backfills->{'games_options_v1'}->(), 'it runs' );

my $rows = &subs::db_query("select * from option where app = 'games' and lower(name) = 'solitaire'")->hashes;
is( scalar @{$rows}, 1, 'one catalog row per game' );
my $keep = $rows->[0];
is( $keep->{'uuid'}, 'browser-solitaire', 'the browser row is kept over the hand-made one' );
is( $keep->{'name'}, 'Solitaire', 'with the game spelling' );
is( $keep->{'def'}, 'off', 'not a default' );
is( $keep->{'save_app'}, '', 'the first pass leaves save_app clear' );

my $category = &subs::db_select('option_category', undef, { app => 'games', uuid => 'games_option_category_v1' })->hashes->[0];
ok( $category && $category->{'name'} eq 'Games', 'the Games option category exists' );
my $chars = eval { decode_json($keep->{'characteristics'}) } || [];
is( ($chars->[0] // {})->{'value'}, 'games_option_category_v1', 'the kept row points at Games' );

my $appt = &subs::db_query('select options from appointments where uuid = ?', 'appt-games-1')->hash;
my $options = eval { decode_json($appt->{'options'}) } || [];
is( scalar @{$options}, 1, 'the appointment keeps its one option' );
is( $options->[0]->{'uuid'}, 'browser-solitaire', 'repointed at the surviving row' );
is( $options->[0]->{'name'}, 'Solitaire', 'with the canonical name' );

# Running it again changes nothing: the survivor is already canonical, and a
# hand edit of another game is the only thing a second pass would touch.
ok( $backfills->{'games_options_v1'}->(), 'a second pass is harmless' );
my $again = &subs::db_query("select count(*) as n from option where app = 'games' and lower(name) = 'solitaire'")->hash;
is( int($again->{'n'}), 1, 'still one row' );

# The second pass restores the separate app. The child's key comes from
# unformat_name, so `Solitaire` lands on the existing `solitaire` app.
ok( $backfills->{'games_options_v2'}, 'the second games-options backfill is registered' );
ok( $backfills->{'games_options_v2'}->(), 'it runs' );
my $recorded = &subs::db_query("select * from option where app = 'games' and lower(name) = 'solitaire'")->hash;
is( $recorded->{'save_app'}, 'on', 'the game records its own app' );
is( $recorded->{'name'}, 'Solitaire', 'still with the game spelling' );
my $recorded_chars = eval { decode_json($recorded->{'characteristics'}) } || [];
is( ($recorded_chars->[0] // {})->{'value'}, 'games_option_category_v1', 'still filed under Games' );

# unformat_name on the option name is what makes the child the same app.
is( &subs::unformat_name($recorded->{'name'}), 'solitaire', 'the child app key is the unformatted name' );

done_testing();
