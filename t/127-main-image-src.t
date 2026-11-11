# tests-for: lib/JawnOS/Domain/Say.pm lib/JawnOS/Manager/Part21.pm lib/JawnOS/Controller/apps_misc.pm templates/apps/gallery_home.html.ep
# covers:    An appointment's main_image is drawable on every device: a path this
#            machine can open is used as it stands, a path another machine wrote is
#            mapped through this device's photo folder, and a snapshot's data URI is
#            used directly. The gallery, the taskbar/start-menu icon and the app
#            search icon all resolve the row the same way. An icon only takes a
#            path that really holds a picture, so a synced stub falls back.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use MIME::Base64 qw(encode_base64);
use Mojo::SQLite;

# A main_image row is written per device. A row synced from the phone names the
# phone's path, and the gallery learned to fall back to this machine's copy; the
# icon and the gallery cover did not, so a laptop drew nothing while the phone
# draw the picture. These are the shared resolver's rules.

my $sandbox = JawnOSTest::sandbox();
my $photos  = "$sandbox/Pictures";
make_path("$photos/programming", "$photos/my%20app");
my $picture = "\xff\xd8\xff\xe0jpeg-picture";
write_file("$photos/programming/pic.jpg", $picture);
write_file("$photos/programming/phone pic.jpg", $picture);
write_file("$photos/my%20app/pic.jpg", $picture);

my $dbfile = "$sandbox/main-image.db";
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
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
$db->query('insert into settings (uuid, app, setting, device, value, server_time) values (?,?,?,?,?,?)',
	'p1', 'misc', 'photo_location', 'computer', '~/Pictures', $now);

my $data_uri = 'data:image/png;base64,' . encode_base64($picture, '');

# --- a snapshot main image names its own bytes ------------------------------
is( subs::main_image_src($data_uri, 'programming'), $data_uri,
	'a data URI main image is the picture itself' );
is( subs::main_icon_source({ app => 'programming', settings => { main_image => $data_uri } }), $data_uri,
	'the icon maker draws a data URI main image' );

# --- a path this machine can open is used as it stands ----------------------
my $local = "$photos/programming/pic.jpg";
my $src = subs::main_image_src($local, 'programming');
like( $src, qr{\A/file_open\?file=}, 'a local path becomes a /file_open src' );
like( $src, qr{pic\.jpg}, 'and names the picture' );
like( $src, qr{&app=programming\z}, 'the app travels with the file so /file_open can gate it' );
unlike( $src, qr{\Q$photos\E}, 'the filesystem path is percent-encoded, not raw' );
like( subs::main_image_src($local, 'programming', 1), qr{&thumb=ya\z},
	'an icon asks /file_open for the cached thumbnail' );

# --- the icon maker puts the custom picture in the title bar ----------------
my $custom = subs::main_icon_maker({ app => 'programming', timestamp => 1, settings => { main_image => $local } });
like( $custom, qr{<img }, 'a custom main image becomes an image' );
like( $custom, qr{&amp;thumb=ya}, 'and asks for its thumbnail (the src is HTML-escaped)' );
unlike( $custom, qr/class="little_thumb"/, 'the image carries one class attribute' );

# --- an app with no picture still gets its window icon ----------------------
my $fallback_src = subs::main_icon_source({ app => 'zz_no_such_custom_app', settings => {} });
like( $fallback_src, qr/gear/, 'an app with no picture falls back to the gear' );
my $fallback = subs::main_icon_maker({ app => 'zz_no_such_custom_app', timestamp => 1, settings => {} });
like( $fallback, qr{<img }, 'so its title bar wears an image, not nothing' );
like( $fallback, qr/gear/, 'the same gear the start menu draws' );

# --- a path another machine wrote is mapped onto this one -------------------
my $phone = '/sdcard/DCIM/programming/pic.jpg';
like( subs::main_image_src($phone, 'programming'), qr{pic\.jpg},
	'a phone path finds the copy in this machine photo folder' );
is( subs::main_image_src('/no/such/place/missing.jpg', 'programming'), '',
	'a path naming nothing here is empty, not a broken src' );
is( subs::main_image_src(undef, 'programming'), '', 'no value, no src' );

# --- the name survives the query string -------------------------------------
my $spaced = subs::main_image_src("$photos/programming/phone pic.jpg", 'programming');
like( $spaced, qr{phone%20pic\.jpg}, 'a space in the file name is encoded' );
unlike( $spaced, qr{phone pic}, 'and never sent raw' );

# path_name already percent-encodes an app folder, so the URL must encode the
# percent too or /file_open decodes it back into a space and misses the file
my $skewed = subs::main_image_src('/sdcard/DCIM/my%20app/pic.jpg', 'my app');
like( $skewed, qr{my%2520app}, 'an app folder path_name encoded stays encoded in the URL' );

# --- a placeholder is not a picture -----------------------------------------
# A settings row can arrive on this device as a one-byte stub while its bytes
# still live on the machine that wrote it; /file_open answers that with nothing,
# so an icon must not take the stub as its picture and go blank. A sealed photo
# is the house's own container: "Salted__", an 8-byte salt, then the ciphertext.
my $stub = "$photos/programming/stub.jpg.enc";
write_file($stub, "\0");
is( subs::main_image_src($stub, 'programming', 1, 1), '',
	'a one-byte stub is not a picture, so it yields no icon src' );
like( subs::main_image_src($stub, 'programming'), qr{stub\.jpg\.enc},
	'but a caller not asking for a real picture still names the row' );

my $sealed = "$photos/programming/sealed.jpg.enc";
write_file($sealed, 'Salted__' . ('x' x 32));
like( subs::main_image_src($sealed, 'programming', 1, 1), qr{sealed\.jpg\.enc},
	'a sealed container is a picture this device holds' );
like( subs::main_image_src($sealed, 'programming', 1, 1), qr{&thumb=ya\z},
	'a sealed picture still asks for its thumbnail' );

my $words = "$photos/programming/notes.txt";
write_file($words, "just some words\n");
is( subs::main_image_src($words, 'programming', 1, 1), '',
	'an open file that is not an image is not an icon' );
like( subs::main_image_src($words, 'programming', 1), qr{notes\.txt},
	'while the plain resolver still returns its path' );

# --- the stub falls through to the app's own picture -------------------------
my $stub_icon = subs::main_icon_source({ app => 'programming', settings => { main_image => $stub, pos => 'product' } });
like( $stub_icon, qr{product}, 'a missing picture falls back to the pos icon' );
unlike( $stub_icon, qr{stub\.jpg}, 'and never points at the stub' );
my $stub_gear = subs::main_icon_source({ app => 'zz_no_such_custom_app', settings => { main_image => $stub } });
like( $stub_gear, qr/gear/, 'a stub on a custom app falls through to the gear' );

# --- the other surfaces follow the same rule --------------------------------
my $root = root();
like( read_file("$root/templates/apps/gallery_home.html.ep"), qr/main_image_src/,
	'the gallery cover uses the shared resolver' );
like( read_file("$root/lib/JawnOS/Manager/Part21.pm"), qr/main_image_src/,
	'the app search icon uses the shared resolver' );
like( read_file("$root/lib/JawnOS/Controller/apps_misc.pm"), qr/data:image/,
	'/apps/icon answers a data URI as bytes rather than a redirect' );
like( read_file("$root/public/js/manager/windows.js"), qr/find\('\.window_icon'\)/,
	'the taskbar clones the same window icon' );

done_testing();
