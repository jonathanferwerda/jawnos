# tests-for: lib/JawnOS/Domain/Travel.pm lib/JawnOS/Domain/Headless.pm lib/JawnOS/Controller/manager_travel.pm
# covers:    the Travel window keeps the span the person asked for however long
#            the app is left unopened; the place list's distance and compass;
#            and a navigation capture that no longer skips its due slot on a
#            fresh process

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

my $root = root();

# ---- the window the Start and End fields mean -----------------------------
# "an hour ago" is a distance from the moment being looked at, so opening
# Travel a week later still means an hour.
my $hour = 60 * 60 * 1000;
my $now  = 1_800_000_000_000;

my $win = &subs::travel_window({ settings => { start_ago => $hour, end_ago => 0 }, timestamp => $now });
is( $win->{'start'}, $now - $hour, 'a saved age is measured back from the moment being viewed' );
is( $win->{'end'},   $now,          'and an end age of zero is that moment' );

my $week_later = &subs::travel_window({
	settings => { start_ago => $hour, end_ago => 0 },
	timestamp => $now + 7 * 24 * 3600 * 1000,
});
is( $week_later->{'end'} - $week_later->{'start'}, $hour, 'the window keeps its span a week later' );

# no window at all opens on the time scope either side of the moment
my $default = &subs::travel_window({ settings => {}, timestamp => $now, scope => '5minute' });
is( $default->{'start'}, $now - 5 * 60 * 1000, 'the default window reaches the scope back' );
is( $default->{'end'},   $now + 5 * 60 * 1000, 'and the same forward' );

# a fixed moment from an older version is still read as one by the helper
my $legacy = &subs::travel_window({
	settings  => { start_time => $now - $hour, end_time => $now },
	timestamp => $now + 1000,
});
is( $legacy->{'start'}, $now - $hour, 'a fixed start still bounds the window' );
is( $legacy->{'end'},   $now,         'and a fixed end still bounds it' );

ok( &subs::travel_window_legacy({ start_time => $now - $hour }), 'a fixed moment with no age beside it is the old shape' );
ok( !&subs::travel_window_legacy({ start_time => $now - $hour, start_ago => $hour }), 'an age beside the moment is not' );
ok( !&subs::travel_window_legacy({}), 'and no window is not' );

# a window typed backwards is read in the order it lies
my $backwards = &subs::travel_window({ settings => { start_time => $now, end_time => $now - $hour }, timestamp => $now });
is( $backwards->{'start'}, $now - $hour, 'the earlier moment is the start' );
is( $backwards->{'end'},   $now,         'and the later one the end' );

# ---- distance and direction ----------------------------------------------
my $north = &subs::travel_offset( 43.0000, -81.9400, 43.0027, -81.9400 );
cmp_ok( $north->{'metres'}, '>', 250, '0.0027 degrees of latitude is about 300 metres' );
cmp_ok( $north->{'metres'}, '<', 350, 'and not kilometres' );
cmp_ok( abs( $north->{'bearing'} ), '<', 0.5, 'straight north is a bearing of 0' );

my $east = &subs::travel_offset( 43.0000, -81.9400, 43.0000, -81.9360 );
cmp_ok( $east->{'metres'}, '>', 250, '0.004 degrees of longitude is a distance too' );
cmp_ok( abs( $east->{'bearing'} - 90 ), '<', 1, 'straight east is a bearing of 90' );

my $south = &subs::travel_offset( 43.0027, -81.9400, 43.0000, -81.9400 );
cmp_ok( abs( $south->{'bearing'} - 180 ), '<', 0.5, 'back the other way is south' );

is( &subs::travel_offset( 'x', -81, 43, -81 )->{'metres'}, 0, 'a row without a position is no distance' );

# the words a person reads
is( &subs::travel_distance_phrase(340),   '340 m',  'metres up to a kilometre' );
is( &subs::travel_distance_phrase(1200),  '1.2 km', 'one decimal place near the house' );
is( &subs::travel_distance_phrase(33000), '33 km',  'whole kilometres far away' );
is( &subs::travel_compass(0),   'N',  'north' );
is( &subs::travel_compass(45),  'NE', 'north east' );
is( &subs::travel_compass(350), 'N',  'a bearing just west of north still reads north' );
is( &subs::travel_compass(-90), 'W',  'a negative bearing wraps' );

# ---- the viewer and the scheduler read the shared rule --------------------
my $viewer = read_file("$root/lib/JawnOS/Controller/manager_travel.pm");
like( $viewer, qr/&subs::travel_window\(\{/,          'the viewer builds its window with the shared rule' );
like( $viewer, qr/&subs::travel_window_legacy\(\$settings\)/, 'and drops the stale fixed pair once' );
like( $viewer, qr/&subs::travel_offset\(/,            'the place list measures distance with the shared rule' );
like( $viewer, qr/\$proxies->\{'origin'\}/,           'and names what it measures from' );

my $headless = read_file("$root/lib/JawnOS/Domain/Headless.pm");
unlike( $headless, qr/\$now - \$gb::timeouts->\{'navigation'\}->\{'lasted_run'\}/,
	'the navigation capture no longer gates on the persisted marker' );
like( $headless, qr/our \$navigation_captured_at;/, 'a marker this process keeps debounces a duplicate call' );

done_testing();
