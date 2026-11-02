# tests-for: lib/JawnOS.pm lib/JawnOS/Controller/ lib/JawnOS/Domain/Edt.pm lib/JawnOS/Domain/File.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Say.pm lib/JawnOS/Domain/Warehouse.pm lib/JawnOS/Manager.pm lib/JawnOS/Manager/ lib/JawnOS/Routes.pm lib/JawnOS/Routes/ perl/Manager.pl templates/
# covers:    Captures from the Android camera arrive as whatever the OS wrote: .jpeg, .webp, .heic, .tif, sometimes .xcf.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use RepoSource;
use JawnOSTest;

# Captures from the Android camera arrive as whatever the OS wrote: .jpeg, .webp,
# .heic, .tif, sometimes .xcf. Two failures followed them through filing:
#
#   1. the media row recognised only jpg|png|bmp|tiff|xcf, so a .jpeg or .heic
#      row had no file_type and app_file rendered nothing;
#   2. a TIFF or XCF cannot be drawn by the Android WebView at all, so even a
#      stored one had no picture in the details view.
#
# The rule now: recognise every common extension (case-insensitively, through a
# sealed .enc tail), and flatten the formats the WebView cannot draw into a PNG
# `preview` at filing time while keeping the original as the download. The app
# bridge is also kept away from formats it cannot read or would re-encode
# sideways, so the magick fallback - which auto-orients - does the work.

my $root = repo_root();
my $manager = manager_source();
my $file_pm = read_file("$root/lib/JawnOS/Domain/File.pm");
my $warehouse = read_file("$root/lib/JawnOS/Domain/Warehouse.pm");
my $part13 = read_file("$root/lib/JawnOS/Manager/Part13.pm");
my $upload = read_file("$root/lib/JawnOS/Controller/manager_misc5.pm");
my $app_file = read_file("$root/templates/apps/app_file.html.ep");

subs::preload($_) for qw(log_reader_file_preparer file_media_information image_bridge_resize image_bridge_convert);

# --- every common extension names its kind -----------------------------------
my %kind = (
	'photo.jpg'    => 'img', 'photo.JPG'   => 'img', 'photo.jpeg' => 'img',
	'photo.JPEG'   => 'img', 'photo.png'   => 'img', 'photo.webp' => 'img',
	'photo.HEIC'   => 'img', 'photo.heif'  => 'img', 'photo.bmp'  => 'img',
	'photo.tif'    => 'img', 'photo.TIFF'  => 'img', 'photo.xcf'  => 'img',
	'photo.gif'    => 'img',
	'song.wav'     => 'snd', 'song.MP3'    => 'snd', 'song.aiff' => 'snd',
	'song.m4a'     => 'snd', 'song.flac'   => 'snd', 'song.ogg'  => 'snd',
	'clip.mp4'     => 'vid', 'clip.MOV'    => 'vid', 'clip.webm' => 'vid',
	'clip.mkv'     => 'vid',
	'paper.pdf'    => 'pdf', 'paper.PDF'   => 'pdf',
	'notes.txt'    => 'doc', 'notes.DOCX'  => 'doc',
	'blob.zzz'     => undef, 'noextension' => undef,
);
foreach my $name ( sort keys %kind ) {
	is( subs::media_file_type("/home/jawn/photos/$name"), $kind{$name},
		"$name is recognised as " . ( $kind{$name} // 'nothing' ) );
}

is( subs::media_file_type('/home/jawn/photos/photo.tiff.enc'), 'img',
	'a sealed picture is read through its .enc tail' );
is( subs::media_file_type('/home/jawn/jpg_folder/photo'), undef,
	'a directory name that looks like an extension is not the extension' );

# --- the media row carries the kind (and the preview) ------------------------
{
	local $subs::a = { app => 'shot' };
	foreach my $ext (qw/jpeg JPG png webp heic heif bmp tif tiff xcf gif/) {
		my $row = subs::log_reader_file_preparer({ f => "pictures/shot_1.$ext", uuid => 'u1' });
		is( $row->{'file_type'}, 'img', "a .$ext media row is an image" );
	}
	my $sealed = subs::log_reader_file_preparer({ f => 'pictures/shot_1.jpg.enc', uuid => 'u2' });
	is( $sealed->{'file_type'}, 'img', 'a sealed .jpg.enc media row is an image' );
	my $carried = subs::log_reader_file_preparer({ f => 'pictures/shot_1.tif', preview => 'pictures/shot_1.preview.png', uuid => 'u3' });
	is( $carried->{'preview'}, 'pictures/shot_1.preview.png',
		'the preview travels with the row the details view reads' );
	my $sound = subs::log_reader_file_preparer({ f => 'music/song.MP3', uuid => 'u4' });
	is( $sound->{'file_type'}, 'snd', 'audio is still audio' );
}

# --- which pictures need a preview -------------------------------------------
is( subs::image_preview_needed('a.tiff'), 1,  'a TIFF needs a preview' );
is( subs::image_preview_needed('a.TIF'),  1,  'the suffix is case-insensitive' );
is( subs::image_preview_needed('a.xcf'),  1,  'an XCF needs a preview' );
is( subs::image_preview_needed('a.heic'), 1,  'a HEIC gets a preview too' );
is( subs::image_preview_needed('a.jpg'),  0,  'a JPEG is already viewable' );
is( subs::image_preview_needed('a.png'),  0,  'a PNG is already viewable' );
is( subs::image_preview_needed('a.mp4'),  0,  'a video is not a picture' );
is( subs::image_preview_needed(undef),    0,  'no name means no preview' );

# --- the preview is made by magick, and its absence is harmless ---------------
{
	my $dir = tempdir(CLEANUP => 1);
	my $tiff = "$dir/scan.tiff";
	write_file($tiff, "tiff-bytes\n");
	my $bin = "$dir/bin";
	make_path($bin);
	write_file("$bin/magick", <<'SH');
#!/bin/sh
out=''
for a in "$@"; do out="$a"; done
if [ -n "$JAWN_ARGS" ]; then printf '%s\n' "$@" > "$JAWN_ARGS"; fi
printf '\211PNG\r\n\032\npreview' > "$out"
SH
	chmod 0755, "$bin/magick";
	local $ENV{PATH} = $bin;
	local $ENV{JAWN_ARGS} = "$dir/args.txt";
	my $data = subs::file_preview_maker({ f => $tiff });
	is( $data->{'preview'}, "$dir/scan.preview.png", 'the preview path is recorded' );
	ok( -e "$dir/scan.preview.png" && (-s "$dir/scan.preview.png") > 0, 'the preview was written' );
	my $args = read_file("$dir/args.txt");
	like( $args, qr/-auto-orient/, 'the preview is auto-oriented' );
	like( $args, qr/-strip/, 'the preview drops the EXIF block' );
	like( $args, qr/\[0\]/, 'the preview reads the first page/layer' );
}

{
	my $dir = tempdir(CLEANUP => 1);
	my $tiff = "$dir/plain.tiff";
	write_file($tiff, "tiff-bytes\n");
	my $empty = "$dir/empty";
	make_path($empty);
	local $ENV{PATH} = $empty;
	my $data = eval { subs::file_preview_maker({ f => $tiff }) };
	is( $@, '', 'no ImageMagick does not raise' );
	ok( !$data->{'preview'}, 'no ImageMagick means no preview, not a broken row' );
}

# --- the details view draws the preview, downloads the original --------------
like( $app_file, qr/my \$display = \(\$f->\{'preview'\} && -e \$f->\{'preview'\}\)/,
	'app_file picks the preview when it exists' );
like( $app_file, qr/src="\/file_open\?app=<%= \$l->\{'app'\} %>&file=<%= \$display %>/,
	'the detail image opens the preview' );
like( $app_file, qr/file="<%= \$f->\{'file'\} %>"/,
	'the original stays the file attribute (download) while the preview is drawn' );
like( $file_pm, qr/qw\/f thumb preview\//, 'the encrypter seals the preview too' );

# --- rotation: the fallback auto-orients, and the bridge is kept away ---------
like( $manager, qr/system\('magick', \$filename, '-auto-orient', '-strip', '-resize'/,
	'the capture resize auto-orients before stripping EXIF' );
like( $manager, qr/system\('magick', 'convert', \$scan, '-auto-orient', '-strip', '-resize'/,
	'the scan resize auto-orients too' );
like( $upload, qr/system\('magick', \$filename, '-auto-orient', '-strip', '-resize'/,
	'the upload resize auto-orients' );
like( $part13, qr/shell_quote\(\$filename \. '\[0\]'\) \. ' -auto-orient -strip -resize '/,
	'the thumbnail auto-orients and reads the first page/layer' );

{
	my $dir = tempdir(CLEANUP => 1);
	my $png = "$dir/pic.png";
	my $tiff = "$dir/pic.tiff";
	my $jpg = "$dir/pic.jpg";
	write_file($_, "bytes\n") for ($png, $tiff, $jpg);
	my @asked;
	local *subs::device_call = sub {
		my ( $method, $args ) = @_;
		push @asked, $method;
		return { path => $args->{'out'}, width => $args->{'width'}, height => $args->{'height'} };
	};
	is( subs::image_bridge_resize($tiff, 10, 10), undef, 'a TIFF is not sent to the bridge' );
	is( subs::image_bridge_resize($jpg, 10, 10), undef, 'a JPEG is not re-encoded by the bridge and left sideways' );
	ok( ref subs::image_bridge_resize($png, 10, 10) eq 'HASH', 'a PNG still uses the bridge' );
	is( subs::image_bridge_convert($tiff, "$dir/out.jpg"), undef, 'a TIFF is not converted by the bridge' );
	is_deeply( \@asked, ['image.resize'], 'only the PNG resize reached the device bridge' );
}

# --- deleting a row leaves no file behind -----------------------------------
my $part32 = read_file("$root/lib/JawnOS/Manager/Part32.pm");
like($part32, qr/&subs::secure_unlink\(\$thumb\)/, 'the thumb is removed without a shred binary');
like($part32, qr/&subs::secure_unlink\(\$file\)/, 'the picture is removed without a shred binary');
like($part32, qr/secure_unlink\(\$preview\)/, 'a TIFF/XCF preview is removed with its picture');
unlike($part32, qr/`shred -u/, 'no shred backtick remains on the delete path (the Android runtime has none)');

done_testing();
