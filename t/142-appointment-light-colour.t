# tests-for: lib/JawnOS/Domain/Contrast.pm lib/JawnOS/Domain/Name.pm lib/JawnOS/Domain/Log.pm
# covers:    A colour is the light face of an appointment and dark_colour the dark one. An app born
#            on a dark desktop stored that cut's own step as its colour, so a later light theme painted
#            its plates near-black. The light face now comes back from the dark cut's pair.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Slurp qw(read_file);
use Mojo::SQLite;

# The desktop's colour schemes ship a light and a dark cut with the same six-step
# ramp. An appointment's stored colour is the light face and dark_colour the dark
# one; dark_colour_for() maps a light step onto its dark pair. The reverse was
# missing, so an app whose colour was seeded while a dark cut was in charge (it
# took the step from that cut's ramp) stayed near-black on every later light
# theme - the phone report "the appointments look like a dark theme".

# --- the light pair of a dark step ------------------------------------------
is( &subs::light_colour_for('#1a1f27'), '#eef2f7',
	'Nord Dark step 0 comes back as Nord light step 0' );
is( &subs::light_colour_for('#394658'), '#a7b8d0',
	'Nord Dark step 3 comes back as Nord light step 3' );

# --- a colour that already is the light face is left alone ------------------
is( &subs::light_colour_for('#eef2f7'), '#eef2f7', 'a light scheme step is unchanged' );
is( &subs::light_colour_for('#6e6e73'), '#6e6e73',
	'a step both cuts share (Graphite last) is not mistaken for a dark one' );
is( &subs::light_colour_for('#123456'), '#123456',
	'a hand-picked colour no scheme knows is untouched' );
is( &subs::light_colour_for(undef), undef, 'no colour, no change' );

# --- the pair ---------------------------------------------------------------
my ($light, $dark) = &subs::appointment_colours('#394658', '#374456');
is( $light, '#a7b8d0', 'a dark-cut colour becomes the light face' );
is( $dark, '#394658', 'and the stored colour it replaced is the dark face' );

($light, $dark) = &subs::appointment_colours('#dba0c4', undef);
is( $light, '#dba0c4', 'a real light face is kept' );
is( $dark, &subs::dark_colour_for('#dba0c4'), 'its dark face is still derived' );

($light, $dark) = &subs::appointment_colours('#dba0c4', '#a03d79');
is( $dark, '#a03d79', 'a row that already names its dark face keeps it' );

# --- the settings getter hands both faces to every render -------------------
my $sandbox = JawnOSTest::sandbox();
my $dbfile  = "$sandbox/appointment-light-colour.db";
my $sql     = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db      = $sql->db;
$db->query('create table settings (setting text, value text, timestamp text, '
	. 'id integer primary key autoincrement, app text, server_time text, device text, '
	. 'browser_tab_id text, uuid text, ost text, subsetting text)');
my @st = stat($dbfile);
$gb::database_holder = {
	server_time => &subs::rightNow(), database => $dbfile, db => $db,
	dbh => $db->dbh, sql => $sql, pid => $$, dev => $st[0], ino => $st[1],
};
$subs::say_quiet = 1;

my $now = &subs::rightNow();
my $add = sub {
	my ($app, $setting, $value) = @_;
	$db->query('insert into settings (uuid, app, setting, device, value, server_time) values (?,?,?,?,?,?)',
		'row-' . $app . '-' . $setting, $app, $setting, 'computer', $value, $now);
};
$add->('warwick_appt', 'uuid', 'u-warwick');
$add->('warwick_appt', 'colour', '#394658');
$add->('warwick_appt', 'dark_colour', '#374456');
$add->('free_appt', 'uuid', 'u-free');
$add->('free_appt', 'colour', '#dba0c4');

my $warwick = &subs::settings_grabber({ app => 'warwick_appt' });
is( $warwick->{'colour'}, '#a7b8d0',
	'the settings getter paints a light desk with the light pair' );
is( $warwick->{'dark_colour'}, '#394658',
	'and a dark desk with the colour the row stored' );

my $free = &subs::settings_grabber({ app => 'free_appt' });
is( $free->{'colour'}, '#dba0c4', 'a light appointment keeps its colour' );
is( $free->{'dark_colour'}, &subs::dark_colour_for('#dba0c4'),
	'and gets the usual derived dark face' );

# --- the appointment viewer reads the same pair -----------------------------
my $root = root();
my $log  = read_file("$root/lib/JawnOS/Domain/Log.pm");
like( $log, qr/&subs::appointment_colours\(/,
	'the appointment viewer normalises the pair with the shared helper' );
unlike( $log, qr/\$appts->\{\$a->\{'app'\}\}->\{'setting'\}->\{'dark_colour'\} = &subs::dark_colour_for\(/,
	'the viewer no longer derives the dark face alone' );

done_testing();
