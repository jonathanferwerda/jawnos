# tests-for: lib/JawnOS/Domain/Travel.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_misc5.pm lib/JawnOS/Controller/manager_misc.pm lib/JawnOS/Manager/Part02.pm public/js/manager/camera.js public/js/manager/manager/02_web_nfc.js perl/help/topics_web.pl
# covers:    a picture remembers which way the phone was facing: the heading
#            rule, the fields the Camera app sends on both capture paths, the
#            range check on the way in, and the file's own record that keeps it

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

my $root = root();

# ---- the heading rule -----------------------------------------------------
# alpha turns the device counter-clockwise, so a clockwise compass heading is
# 360 - alpha; iOS's webkitCompassHeading is already clockwise from true north.
my $north = &subs::camera_heading( 0, undef, 1 );
is( $north->{'heading'}, 0, 'alpha 0 is north' );
is( $north->{'source'}, 'absolute', 'and an absolute event is true north' );

my $east = &subs::camera_heading( 90, undef, 0 );
is( $east->{'heading'}, 270, 'alpha 90 turns into a heading of 270' );
is( $east->{'source'}, 'relative', 'a plain event is the device frame, not true north' );

my $absolute = &subs::camera_heading( 90, undef, 1 );
is( $absolute->{'heading'}, 270, 'an absolute event reads the same heading' );
is( $absolute->{'source'}, 'absolute', 'but is provenance a later reader can trust' );

my $near_north = &subs::camera_heading( 359.9, undef, 1 );
is( $near_north->{'heading'}, 0.1, 'a hair short of a full turn is a hair east of north' );

my $compass = &subs::camera_heading( 90, 12.5, 0 );
is( $compass->{'heading'}, 12.5, 'webkitCompassHeading wins over alpha' );
is( $compass->{'source'}, 'absolute', 'and is true north even on a relative event' );

is( &subs::camera_heading( 0, 360, 0 )->{'heading'}, 0, 'a full compass turn normalises to north' );
is( &subs::camera_heading( -90, undef, 0 )->{'heading'}, 90, 'an alpha below zero wraps' );

my $unknown = &subs::camera_heading( 'north', undef, 1 );
is( $unknown->{'heading'}, undef, 'a non-numeric alpha is no heading' );
is( $unknown->{'source'}, undef, 'and names no source' );
is( &subs::camera_heading( undef, undef, 0 )->{'heading'}, undef, 'no reading is no heading' );
is( &subs::camera_heading( '9' x 400, undef, 1 )->{'heading'}, undef,
	'a number too long to be a turn is refused rather than normalised' );

# ---- what a file record may keep ------------------------------------------
my $reading = &subs::camera_orientation_reading( 45.67, 12.34, -179.95, 'relative' );
is( $reading->{'heading'}, 45.7, 'a heading keeps one decimal' );
is( $reading->{'pitch'}, 12.3, 'so does pitch' );
is( $reading->{'roll'}, -179.9, 'and roll' );
is( $reading->{'heading_source'}, 'relative', 'with the source beside it' );

my $bad = &subs::camera_orientation_reading( 361, -91, 181, 'sideways' );
is_deeply( $bad, {}, 'out-of-range and unknown-source fields are dropped' );

my $mixed = &subs::camera_orientation_reading( 120, 'NaN', '-12abc', 'absolute' );
is_deeply( $mixed, { heading => 120, heading_source => 'absolute' },
	'a good heading survives a junk pitch and roll' );

is_deeply( &subs::camera_orientation_reading( undef, undef, undef, 'absolute' ), {},
	'a source with no heading is nothing' );
is( &subs::camera_orientation_reading( 360, 90, 180, 'absolute' )->{'heading'}, 360,
	'the end of the heading range is kept' );
is( &subs::camera_orientation_reading( 0, -90, -180, 'relative' )->{'roll'}, -180,
	'and the end of the roll range' );

# ---- the Camera app sends the reading -------------------------------------
my $camera_js = read_file("$root/public/js/manager/camera.js");
like( $camera_js, qr/deviceorientationabsolute/, 'the absolute sensor event is listened for' );
like( $camera_js, qr/addEventListener\('deviceorientation'/, 'with the plain event as the fallback' );
like( $camera_js, qr/webkitCompassHeading/, 'the compass heading is preferred where iOS offers it' );
like( $camera_js, qr/360 - alpha/, 'and alpha is turned into a clockwise heading' );
like( $camera_js, qr/Math\.round\([^)]*\)\s*\/\s*10/, 'a reading is rounded to one decimal' );
like( $camera_js, qr/DeviceOrientationEvent\.requestPermission/, 'iOS is asked for the sensor grant' );
like( $camera_js, qr/removeEventListener\('deviceorientation/, 'the listeners are removed' );
like( $camera_js, qr/MutationObserver/, 'and stop when the camera window goes' );
like( $camera_js, qr/\['heading', 'pitch', 'roll'\]/, 'the three angles are sent together' );
like( $camera_js, qr/formData\.append\(key, value\)/, 'the fields ride on the webcam upload' );
like( $camera_js, qr/heading_source/, 'including whether the heading is true north' );
like( $camera_js, qr/pending\.orientation = fields/, 'a native capture carries the page reading' );

my ($ready) = $camera_js =~ /(\$\(document\)\.ready\(function \(\) \{.*?\n\}\);)/s;
ok( $ready, 'the page-load block was found' );
unlike( $ready, qr/requestPermission/, 'the sensor grant is never asked for at page load' );

my ($photo) = $camera_js =~ /(\$\(document\)\.on\('click', '\.camera_app_photo'.*?\n\}\);)/s;
ok( $photo, 'the photo press handler was found' );
like( $photo, qr/jawnCameraAppOrientationEnable\(\)/, 'the press is what asks for the sensor' );

my $bridge = read_file("$root/public/js/manager/manager/02_web_nfc.js");
like( $bridge, qr/\$\.extend\(data, pending\.orientation\)/,
	'the native bridge forwards the reading to take_picture' );
like( $bridge, qr/\$\.each\(pending\.orientation/, 'and on the base64 capture path too' );

# ---- the server keeps it on the picture, not a column ---------------------
my $upload = read_file("$root/lib/JawnOS/Controller/manager_misc5.pm");
like( $upload, qr/&subs::camera_orientation_reading\(/,
	'the upload route validates with the shared rule' );
like( $upload, qr/\$u_data->\{\$key\} = \$orientation->\{\$key\}/,
	"the reading lands on the file's own record" );
like( $upload, qr/push \@uploaded_files, \$u_data/, 'which is the record the appointment keeps' );
like( $upload, qr/my \$jfile = encode_json \\\@uploaded_files;/, 'and the JSON written to `file`' );
unlike( $upload, qr/db_update\([^;]*heading/s, 'no heading is written to a schema column' );
like( $upload, qr/TODO:.*?continent_record.*?heading column/s,
	'a fix cannot carry the reading yet, and the TODO names the missing column' );

my $native_route = read_file("$root/lib/JawnOS/Controller/manager_misc.pm");
like( $native_route, qr/&subs::camera_orientation_reading\(/,
	'the native capture route validates the reading' );
like( $native_route, qr/%\{\$orientation\}/, 'and keeps it on the capture data' );

my $take_picture = read_file("$root/lib/JawnOS/Manager/Part02.pm");
like( $take_picture, qr/\$u_data->\{\$key\} = \$orientation->\{\$key\}/,
	"take_picture puts it on the picture's own record too" );

# ---- the rule is registered, and the help says what it means -------------
my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like( $loader, qr/JawnOS::Domain::Travel' for qw\([^)]*\bcamera_heading\b/,
	'camera_heading is in the domain map' );
like( $loader, qr/JawnOS::Domain::Travel' for qw\([^)]*\bcamera_orientation_reading\b/,
	'and so is the reading rule' );

my $help = read_file("$root/perl/help/topics_web.pl");
like( $help, qr/which way the phone was facing/,
	'the Camera help says a picture remembers its direction' );

done_testing();
