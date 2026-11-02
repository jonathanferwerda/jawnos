# tests-for: scripts/settings_image_files.pl
# covers:    a data URI in a settings row may be replaced by an absolute path
#            whose local sealed copy hashes to the same bytes; a bare filename
#            (relative to the owning device's photo folder) is never
#            transplanted, because it would stop resolving on that device.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(write_file read_file);
use MIME::Base64 qw(encode_base64);
use DBI;

my $dir = tempdir(CLEANUP => 1);
my $photos = "$dir/photos";
make_path("$photos/dave_raes", "$photos/me");

my $picture = "\x89PNG\r\n\x1a\n" . 'dave-picture';
my $mug = "\x89PNG\r\n\x1a\n" . 'mugshot-picture';
write_file("$photos/dave_raes/pic.png", $picture);
write_file("$photos/me/mugshot.png", $mug);

my $db = "$dir/jawnos.db";
my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0 });
$dbh->do(q{create table settings (uuid VARCHAR(255), app LONGTEXT, setting VARCHAR(255),
	device VARCHAR(10), value LONGTEXT, server_time VARCHAR(255), ost VARCHAR(25))});
my $insert = $dbh->prepare(q{insert into settings (uuid, app, setting, device, value, server_time) values (?,?,?,?,?,?)});
$insert->execute('photo', 'misc', 'photo_location', 'computer', $photos, '1000');
$insert->execute('dave_mobile', 'dave_raes', 'main_image', 'mobile', 'data:image/png;base64,' . encode_base64($picture, ''), '1000');
$insert->execute('dave_computer', 'dave_raes', 'main_image', 'computer', '/sdcard/DCIM/dave_raes/pic.png', '1000');
$insert->execute('me_mobile', 'me', 'mugshot', 'mobile', 'data:image/png;base64,' . encode_base64($mug, ''), '1000');
$insert->execute('me_computer', 'me', 'mugshot', 'computer', 'mugshot.png', '1000');
$insert->finish;
$dbh->disconnect;

my $script = "$FindBin::Bin/../scripts/settings_image_files.pl";
my $out = qx{$^X "$script" --database="$db" --device=computer --apply --no-backup 2>&1};
my $rc = $? >> 8;
is($rc, 0, 'the migration runs') or diag($out);

$dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0 });
my ($dave) = $dbh->selectrow_array("select value from settings where uuid = 'dave_mobile'");
is($dave, '/sdcard/DCIM/dave_raes/pic.png',
	'an identical absolute-path row stands in for the data URI (the phone path keeps working)');
my ($me) = $dbh->selectrow_array("select value from settings where uuid = 'me_mobile'");
like($me, qr/^data:image\/png;base64,/, 'a bare filename is not transplanted across devices');
$dbh->disconnect;

done_testing();
