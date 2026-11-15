# tests-for: lib/JawnOS/Domain/Travel.pm lib/JawnOS/Domain/Headless.pm lib/JawnOS/Domain/Render.pm lib/JawnOS/Controller/manager_travel.pm public/js/manager/manager/07_timeshift.js public/js/manager/travel/01_map_render_points.js public/js/manager/travel/02_maps_config_guess.js public/js/universal/02_settings_ajax_hidden.js scripts/navigation_probe.pl
# covers:    the Travel window keeps the span the person asked for however long
#            the app is left unopened; the place list's distance and compass on
#            the WGS84 ellipsoid; a navigation capture that no longer skips its
#            due slot on a fresh process; and the probe's verdict on a pace

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

my $win = &subs::travel_window({ settings => { start_time_ago => $hour, end_time_ago => 0 }, timestamp => $now });
is( $win->{'start'}, $now - $hour, 'a saved age is measured back from the moment being viewed' );
is( $win->{'end'},   $now,          'and an end age of zero is that moment' );

my $week_later = &subs::travel_window({
	settings => { start_time_ago => $hour, end_time_ago => 0 },
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
ok( !&subs::travel_window_legacy({ start_time => $now - $hour, start_time_ago => $hour }), 'an age beside the moment is not' );
ok( !&subs::travel_window_legacy({}), 'and no window is not' );

# a window typed backwards is read in the order it lies
my $backwards = &subs::travel_window({ settings => { start_time => $now, end_time => $now - $hour }, timestamp => $now });
is( $backwards->{'start'}, $now - $hour, 'the earlier moment is the start' );
is( $backwards->{'end'},   $now,         'and the later one the end' );

# ---- distance and direction ----------------------------------------------
my $north = &subs::geodesic_offset( 43.0000, -81.9400, 43.0027, -81.9400 );
cmp_ok( $north->{'metres'}, '>', 250, '0.0027 degrees of latitude is about 300 metres' );
cmp_ok( $north->{'metres'}, '<', 350, 'and not kilometres' );
cmp_ok( abs( $north->{'bearing'} ), '<', 0.5, 'straight north is a bearing of 0' );

my $east = &subs::geodesic_offset( 43.0000, -81.9400, 43.0000, -81.9360 );
cmp_ok( $east->{'metres'}, '>', 250, '0.004 degrees of longitude is a distance too' );
cmp_ok( abs( $east->{'bearing'} - 90 ), '<', 1, 'straight east is a bearing of 90' );

my $south = &subs::geodesic_offset( 43.0027, -81.9400, 43.0000, -81.9400 );
cmp_ok( abs( $south->{'bearing'} - 180 ), '<', 0.5, 'back the other way is south' );

is( &subs::geodesic_offset( 'x', -81, 43, -81 )->{'metres'}, 0, 'a row without a position is no distance' );

# Vincenty's own worked example (WGS84): Flinders Peak -> Buninyong. The
# published answer is 54972.271 m at an initial bearing of 306 52 05.37 (that
# is 306.8681583 degrees clockwise from north), so a mistyped constant, a
# swapped argument or a degrees/radians slip shows up here and nowhere else.
my $flinders = &subs::geodesic_offset(
	-37.9510334167, 144.4248678889,
	-37.6528211389, 143.9264955278
);
cmp_ok( abs( $flinders->{'metres'} - 54972.271 ), '<', 0.01, 'Vincenty lands on the reference distance' );
cmp_ok( abs( $flinders->{'bearing'} - 306.8681583 ), '<', 0.001, 'and on the reference bearing' );

# The ellipsoid is not the sphere. Over a county the difference is tens of
# metres, which is why the sphere was never good enough for a distance read off
# a map; the antipodal fallback has to answer in the same shape.
my $ellipsoid = &subs::geodesic_offset( 43.0024, -81.9421, 42.9776, -82.3669 );  # home -> Sarnia
my $sphere    = &subs::geodesic_offset_sphere( 43.0024, -81.9421, 42.9776, -82.3669 );
cmp_ok( abs( $ellipsoid->{'metres'} - $sphere->{'metres'} ), '>', 20, 'the ellipsoid differs from the sphere over ~33 km' );
cmp_ok( $ellipsoid->{'metres'}, '>', 33000, 'and the county really is about 34 km away' );
my $antipode = &subs::geodesic_offset_sphere( 43, -82, -43, 98 );
cmp_ok( $antipode->{'metres'}, '>', 19000000, 'the fallback measures a half-world trip' );

# the words a person reads
is( &subs::travel_distance_phrase(340),   '340 m',  'metres up to a kilometre' );
is( &subs::travel_distance_phrase(1200),  '1.2 km', 'one decimal place near the house' );
is( &subs::travel_distance_phrase(33000), '33 km',  'whole kilometres far away' );
is( &subs::travel_compass(0),   'N',  'north' );
is( &subs::travel_compass(45),  'NE', 'north east' );
is( &subs::travel_compass(350), 'N',  'a bearing just west of north still reads north' );
is( &subs::travel_compass(-90), 'W',  'a negative bearing wraps' );

# one row per place: an app's fixes at the same spot are one place to go, and a
# second visit in another place stays its own row
my $collapse = &subs::travel_collapse_places([
	{ app => 'president', name => 'President', latitude => '43.002400', longitude => '-81.942100' },
	{ app => 'president', name => 'President', latitude => '43.002420', longitude => '-81.942120' },  # ~3 m away
	{ app => 'water',     name => 'Water',     latitude => '43.002400', longitude => '-81.942100' },  # other app, same spot
	{ app => 'president', name => 'President', latitude => '43.005000', longitude => '-81.942100' },  # ~290 m away
], 50 );
is( scalar @{ $collapse }, 3, 'a duplicate collapses, another app and another visit do not' );
is( $collapse->[0]->{'latitude'}, '43.002400', 'the nearest row is the one kept' );
is( &subs::travel_collapse_places( [] )->[0], undef, 'an empty list is empty' );

# ---- the viewer and the scheduler read the shared rule --------------------
my $viewer = read_file("$root/lib/JawnOS/Controller/manager_travel.pm");
like( $viewer, qr/&subs::travel_window\(\{/,          'the viewer builds its window with the shared rule' );
like( $viewer, qr/&subs::travel_window_legacy\(\$settings\)/, 'and drops the stale fixed pair once' );
like( $viewer, qr/&subs::geodesic_offset\(/,          'the place list measures distance with the shared rule' );
like( $viewer, qr/\$proxies->\{'origin'\}/,           'and names what it measures from' );
like( $viewer, qr/&subs::travel_collapse_places\(/,   'and collapses an app\'s fixes at one spot' );

my $headless = read_file("$root/lib/JawnOS/Domain/Headless.pm");
unlike( $headless, qr/\$now - \$gb::timeouts->\{'navigation'\}->\{'lasted_run'\}/,
	'the navigation capture no longer gates on the persisted marker' );
like( $headless, qr/our \$navigation_captured_at;/, 'a marker this process keeps debounces a duplicate call' );

# ---- what the probe says about a pace ------------------------------------
# scripts/navigation_probe.pl only collects; the judgement is a pure helper, so
# it is fed fixtures here rather than waiting three hours on a phone.
sub probe_sample {
	my ( $at, @devices ) = @_;
	return { at => $at, devices => [@devices] };
}
sub probe_device {
	my (%arg) = @_;
	return { sig => ( $arg{'sig'} || 'phone' ), toggle => 'on', pace => 240, %arg };
}
my $t0 = 1_800_000_000_000;
# ten minutes of watching, a sample a minute: the phone's last_run moves every
# two minutes (a pace of 120) so the window is long enough to judge.
my @samples;
for my $minute ( 0 .. 10 ) {
	push @samples, probe_sample( $t0 + $minute * 60000,
		probe_device(
			sig      => 'phone',
			pace     => 120,
			last_run => $t0 + int( $minute / 2 ) * 120000,
			temp_ts  => $t0 + int( $minute / 2 ) * 120000,
		),
		probe_device( sig => 'tablet', pace => 600, last_run => $t0 ),
		probe_device( sig => 'lone', pace => 240, last_run => $t0 ),
		probe_device( sig => 'laptop', toggle => 'off' ),
	);
}
my $summary = &subs::navigation_probe_summary( \@samples );
is( scalar @{ $summary->{'lines'} }, 4, 'one line per machine seen' );
is( $summary->{'devices'}->{'phone'}->{'runs'}, 6, 'six runs on the phone' );
is( $summary->{'devices'}->{'phone'}->{'late'}, 0, 'and none of them late' );
like( join( '', @{ $summary->{'lines'} } ), qr/kept the 120s pace/, 'the phone is judged to keep its pace' );
is( $summary->{'devices'}->{'phone'}->{'longest_gap_ms'}, 120000, 'the beat is the pace' );
is( $summary->{'devices'}->{'tablet'}->{'runs'}, 1, 'a single run is one run' );
my $lone_line = ( grep { /one run seen/ } @{ $summary->{'lines'} } )[0];
ok( $lone_line, 'a machine with one beat is not called steady' );
my $laptop_line = ( grep { /navigation is off/ } @{ $summary->{'lines'} } )[0];
ok( $laptop_line, 'a machine with the job off says so' );

# a missed slot is named, and a window too short to judge is not
my $late = &subs::navigation_probe_summary(
	[ probe_sample( $t0, probe_device( last_run => $t0 ) ),
	  probe_sample( $t0 + 600000, probe_device( last_run => $t0 + 600000 ) ) ]
);
is( $late->{'devices'}->{'phone'}->{'late'}, 1, 'a ten-minute gap is a missed beat' );
like( $late->{'lines'}->[0], qr/gap\(s\) longer than the 240s pace/, 'and the line says so' );

my $short = &subs::navigation_probe_summary(
	[ probe_sample( $t0, probe_device( last_run => $t0 ) ),
	  probe_sample( $t0 + 60000, probe_device( last_run => $t0 + 60000 ) ) ]
);
like( $short->{'lines'}->[0], qr/not watched long enough/, 'a minute of watching cannot judge a four-minute pace' );

my $silent = &subs::navigation_probe_summary(
	[ probe_sample( $t0, probe_device( last_run => 0 ) ),
	  probe_sample( $t0 + 600000, probe_device( last_run => 0 ) ) ]
);
like( $silent->{'lines'}->[0], qr/no run or capture seen/, 'no run in the window is named' );

like( read_file("$root/scripts/navigation_probe.pl"), qr/navigation_probe_summary/, 'the script asks the shared rule for its verdict' );

# ---- the age's name is one name on both sides of the wire ----------------
# The time field writes the age under the field's own setting plus _ago
# (setting="start_time" -> start_time_ago). v0.1.2996 read start_ago in the
# window, so a window the person had just set looked like a legacy fixed moment,
# was dropped, and Travel reopened on the default scope with no fixes in view.
my $timeshift = read_file("$root/public/js/manager/manager/07_timeshift.js");
like( $timeshift, qr/input\.attr\('setting'\) \+ '_ago'/, 'the time field writes <setting>_ago' );
my $travel_domain = read_file("$root/lib/JawnOS/Domain/Travel.pm");
like( $travel_domain, qr/\{'start_time_ago'\}/, 'and the window reads the age of start_time' );
unlike( $travel_domain, qr/\{'start_ago'\}/, 'no shorter name is read by the window' );
my $now_js = read_file("$root/public/js/manager/travel/02_maps_config_guess.js");
like( $now_js, qr/'setting': 'start_time_ago'/, 'Now clears the key the field writes' );

# A change to Start is written as the field blurs, which is the same press as
# Update; the viewer must wait for that write or it is answered with the window
# from before the edit.
my $settings_js = read_file("$root/public/js/universal/02_settings_ajax_hidden.js");
like( $settings_js, qr/function settingWritesSettled/, 'pending setting writes can be awaited' );
my $map_points = read_file("$root/public/js/manager/travel/01_map_render_points.js");
like( $map_points, qr/settingWritesSettled\('travel'\)/, 'and Travel Update waits for them before reading the window' );

done_testing();
