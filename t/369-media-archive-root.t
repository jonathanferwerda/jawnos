# tests-for: lib/JawnOS/Domain/Format.pm lib/JawnOS/Domain/File.pm
# covers:    media_path_allowed accepts this machine's archive root and still
#            refuses paths outside every house root; a controller's root only
#            counts while the card is mounted on its own device.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use JawnOSTest;

# The machine that holds the archive drive keeps Music, Gallery photos and
# video thumbnails under archive_dir, so the routes that serve media have to
# accept that root. Everything here works in a tempdir; no real archive root
# is read or written.

# archive_root() asks the misc setting first. Calling it once loads
# setting_grabber, so the stub below shadows a defined sub instead of being
# replaced when its module loads later inside the local scope.
subs::archive_root();

my $tmp     = tempdir(CLEANUP => 1);
my $house   = "$tmp/house";
my $archive = "$tmp/archive_drive";
my $scratch = "$tmp/scratch";
my $outside = "$tmp/elsewhere";
make_path("$house/Music", "$archive/Photos/banana", "$archive/Videos", "$scratch", $outside);

my $home_file     = "$house/Music/song.mp3";
my $archive_photo = "$archive/Photos/banana/p.jpg.enc";
my $archive_video = "$archive/Videos/clip.mp4";
my $outside_file  = "$outside/secret.jpg";
write_file($_, 'x') for ($home_file, $archive_photo, $archive_video, $outside_file);

# ---- the archive drive is a house root --------------------------------------

{
	# a sandbox home, the archive in config as archive_root() reads it, and a
	# temp root that is this run's scratch folder: tempdir lives under /tmp,
	# which would otherwise make the "outside" file an allowed path
	local $subs::home_dir = $house;
	local $subs::config = { archive_dir => $archive };
	local *subs::setting_grabber = sub { return undef };
	local $gb::tmp_dir = $scratch;

	is(subs::archive_root(), $archive, 'the machine has an archive root from config');

	ok(subs::media_path_allowed($archive_photo), 'a Gallery photo under the archive root is media');
	ok(subs::media_path_allowed($archive_video), 'a video under the archive root is media too');
	ok(subs::media_path_allowed($home_file), 'a file under home is still media');

	ok(!subs::media_path_allowed($outside_file), 'a file outside every house root is refused');
	ok(!subs::media_path_allowed('/etc/passwd'), 'a system file is still refused');

	symlink($outside_file, "$archive/escape") or die "symlink: $!";
	ok(!subs::media_path_allowed("$archive/escape"),
		'a link inside the archive root cannot point out of it');
}

# ---- no archive on this machine: answer, do not crash -----------------------

{
	local $subs::home_dir = $house;
	local $subs::config = {};
	local *subs::setting_grabber = sub { return undef };
	local $gb::tmp_dir = $scratch;

	is(subs::archive_root(), undef, 'a machine without an archive has no root');
	ok(subs::media_path_allowed($home_file), 'home is still media with no archive');
	ok(!subs::media_path_allowed($outside_file), 'and a path outside every root is still refused');
	ok(!subs::media_path_allowed("$archive/Photos/banana/p.jpg.enc"),
		'an archive path is refused when this machine has no archive root');
}

# ---- a controller's archive is its card ------------------------------------
# When the card is out, the automount mountpoint is an empty directory on the
# eMMC. The device number tells it from the card, so a read or a write cannot
# land on the eMMC just because the path exists.
is(subs::archive_card_mounted($archive, { device => 'controller', archive_dev => 1, root_dev => 1 }),
	0, 'a controller refuses an archive root on the eMMC');
is(subs::archive_card_mounted($archive, { device => 'controller', archive_dev => 2, root_dev => 1 }),
	1, 'a controller accepts a root on its own card');
is(subs::archive_card_mounted($archive, { device => 'computer', archive_dev => 1, root_dev => 1 }),
	1, 'a computer may archive on its own disk');
is(subs::archive_card_mounted("$tmp/missing", { device => 'controller', archive_dev => 2, root_dev => 1 }),
	0, 'a root that does not exist is not a card');

# A controller reads its own config.json value, not the shared misc pick, and
# the root is refused while it is only the eMMC mountpoint. The tempdir here is
# under the repo, on the same device as /.
my $same = tempdir(DIR => "$FindBin::Bin/..", CLEANUP => 1);
{
	local *subs::device_setter = sub { 'controller' };
	local *subs::config_reader = sub { { archive_dir => $same } };
	local *subs::setting_grabber = sub { "$tmp/other_drive" };
	is(subs::archive_root(), undef,
		'a controller uses its own config and refuses the eMMC mountpoint');
}

like(read_file("$FindBin::Bin/../lib/JawnOS/Domain/File.pm"),
	qr/archive_card_mounted/,
	'archive_root is gated on the card being mounted');

done_testing();
