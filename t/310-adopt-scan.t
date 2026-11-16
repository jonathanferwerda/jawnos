# tests-for: lib/JawnOS/Domain/File.pm lib/JawnOS/Controller/manager_configure5.pm public/js/manager/configure/04_currency_backup.js lib/JawnOS/Manager/Part05.pm
# covers:    the adopt scan and dialog: media types, folder/file filtering, path vs name suppression, the missing-location fallback, and the listing/confirm wiring

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use RepoSource qw(js_source);

# --- the media family of a name ---------------------------------------------

is( &subs::adopt_media_type('a.jpg'),  'image',    'jpg is an image' );
is( &subs::adopt_media_type('a.jpeg'), 'image',    'jpeg is an image' );
is( &subs::adopt_media_type('a.png'),  'image',    'png is an image' );
is( &subs::adopt_media_type('a.gif'),  'image',    'gif is an image' );
is( &subs::adopt_media_type('a.webp'), 'image',    'webp is an image' );
is( &subs::adopt_media_type('a.bmp'),  'image',    'bmp is an image' );
is( &subs::adopt_media_type('a.tif'),  'image',    'tif is an image' );
is( &subs::adopt_media_type('a.tiff'), 'image',    'tiff is an image' );
is( &subs::adopt_media_type('a.heic'), 'image',    'heic is an image' );
is( &subs::adopt_media_type('a.heif'), 'image',    'heif is an image' );
is( &subs::adopt_media_type('a.xcf'),  'image',    'xcf is an image' );

is( &subs::adopt_media_type('a.mp4'),  'video',    'mp4 is a video' );
is( &subs::adopt_media_type('a.webm'), 'video',    'webm is a video' );
is( &subs::adopt_media_type('a.mov'),  'video',    'mov is a video' );
is( &subs::adopt_media_type('a.m4v'),  'video',    'm4v is a video' );
is( &subs::adopt_media_type('a.mkv'),  'video',    'mkv is a video' );
is( &subs::adopt_media_type('a.avi'),  'video',    'avi is a video' );
is( &subs::adopt_media_type('a.mpeg'), 'video',    'mpeg is a video' );
is( &subs::adopt_media_type('a.mpg'),  'video',    'mpg is a video' );

is( &subs::adopt_media_type('a.mp3'),  'audio',    'mp3 is audio' );
is( &subs::adopt_media_type('a.m4a'),  'audio',    'm4a is audio' );
is( &subs::adopt_media_type('a.flac'), 'audio',    'flac is audio' );
is( &subs::adopt_media_type('a.aif'),  'audio',    'aif is audio' );
is( &subs::adopt_media_type('a.aiff'), 'audio',    'aiff is audio' );
is( &subs::adopt_media_type('a.weba'), 'audio',    'weba is audio' );
is( &subs::adopt_media_type('a.wav'),  'audio',    'wav is audio' );
is( &subs::adopt_media_type('a.ogg'),  'audio',    'ogg is audio' );
is( &subs::adopt_media_type('a.oga'),  'audio',    'oga is audio' );
is( &subs::adopt_media_type('a.opus'), 'audio',    'opus is audio' );

is( &subs::adopt_media_type('a.pdf'),  'document', 'pdf is a document' );

is( &subs::adopt_media_type('A.JPG'),  'image',    'an uppercase extension is accepted' );
is( &subs::adopt_media_type('B.MP4'),  'video',    'and an uppercase video one too' );

is( &subs::adopt_media_type('notes.txt'), 'software', 'anything else is software' );

is( &subs::adopt_media_type('x.jpg.enc'), undef, 'a sealed file is not adopted again' );
is( &subs::adopt_media_type('x.jpg.ENC'), undef, 'the .enc check is case-insensitive' );
is( &subs::adopt_media_type('.hidden.jpg'), undef, 'a dotfile is skipped' );
is( &subs::adopt_media_type(undef), undef, 'undef has no media type' );
is( &subs::adopt_media_type(''), undef, 'the empty name has no media type' );

# --- the scan over a temp tree ----------------------------------------------

my $tree = tempdir( TMPDIR => 1, CLEANUP => 1 );
make_path("$tree/Pictures/demo/sub", "$tree/Documents/demo");

for my $f (qw(a.JPG b.mp4 c.wav d.pdf e.bin f.jpg.enc .hidden.jpg)) {
	write_file("$tree/Pictures/demo/$f");
}
write_file("$tree/Documents/demo/a.JPG");
write_file("$tree/Documents/demo/g.png");

my $sections = &subs::adopt_scan_candidates(
	[
		{ key => 'photo',    name => 'Photo',    path => "$tree/Pictures/demo" },
		{ key => 'document', name => 'Document', path => "$tree/Documents/demo" },
		{ key => 'scan',     name => 'Scan',     path => "$tree/Documents/demo" },
	],
	{},
	{ 'g.png' => 1 },
);

is( scalar @{$sections}, 2, 'the duplicate folder path collapses to one section' );
is_deeply( [ map { $_->{'key'} } @{$sections} ],
	[qw(photo document)], 'input order is preserved and the first folder wins' );

my ($photo, $document) = @{$sections};

is_deeply( [ map { $_->{'name'} } @{ $photo->{'files'} } ],
	[qw(a.JPG b.mp4 c.wav d.pdf e.bin)],
	'the Pictures scan keeps its files, sorted, and drops the sealed and hidden ones' );

my %photo_type = map { $_->{'name'} => $_->{'type'} } @{ $photo->{'files'} };
is_deeply( \%photo_type, {
	'a.JPG' => 'image',
	'b.mp4' => 'video',
	'c.wav' => 'audio',
	'd.pdf' => 'document',
	'e.bin' => 'software',
}, 'every adopted file carries its media type' );

ok( !grep({ $_->{'name'} eq 'f.jpg.enc' } @{ $photo->{'files'} }), 'a sealed file is not offered' );
ok( !grep({ $_->{'name'} eq '.hidden.jpg' } @{ $photo->{'files'} }), 'a dotfile is not offered' );
ok( !grep({ $_->{'name'} eq 'sub' } @{ $photo->{'files'} }), 'a directory is not offered' );

is_deeply( [ map { $_->{'name'} } @{ $document->{'files'} } ],
	[qw(a.JPG)], 'the Documents scan keeps a.JPG and suppresses g.png by name' );

my ($photo_a) = grep { $_->{'name'} eq 'a.JPG' } @{ $photo->{'files'} };
my ($document_a) = grep { $_->{'name'} eq 'a.JPG' } @{ $document->{'files'} };
ok( defined $photo_a && defined $document_a, 'the same basename in two folders is offered twice' );
isnt( $photo_a->{'file'}, $document_a->{'file'}, 'and the two entries are different real files' );

# --- a full path already in the library is suppressed ------------------------

my $filtered = &subs::adopt_scan_candidates(
	[ { key => 'photo', name => 'Photo', path => "$tree/Pictures/demo" } ],
	{ "$tree/Pictures/demo/b.mp4" => 1 },
	{},
);
my @filtered_names = map { $_->{'name'} } @{ $filtered->[0]->{'files'} };
ok( !grep({ $_ eq 'b.mp4' } @filtered_names), 'a file whose full path is known is not offered again' );
ok( grep({ $_ eq 'a.JPG' } @filtered_names), 'its neighbours are still offered' );

# --- file_device_renamer: a missing location never means '/<app>' ------------

{
	local $subs::device = 'computer';
	local *subs::setting_grabber = sub { return undef };

	my ($dest, $asset, $type) = &subs::file_device_renamer({
		file          => "$tree/Pictures/demo/b.mp4",
		app           => 'demo',
		type          => 'video',
		is_thumb      => 1,
		misc_settings => { computer => {} },
	});
	is( $type,  'video',  'the requested video type is kept' );
	is( $asset, 'b.mp4',  'the asset basename is returned' );
	like( $dest, qr{/Pictures/demo/\.thumbs/\z}, 'a thumbnail with no location falls back to its source folder' );
	unlike( $dest, qr{^/[^/]+/\.thumbs/\z}, 'never a bare /<app> destination' );
}

# --- and a configured location still names the destination -------------------

{
	local $subs::device = 'computer';
	local *subs::setting_grabber = sub {
		my $s = shift;
		return "$tree/Pictures" if (($s->{'setting'} // '') eq 'photo_location');
		return undef;
	};

	my ($dest) = &subs::file_device_renamer({
		file          => "$tree/Pictures/demo/a.JPG",
		app           => 'demo',
		type          => 'image',
		is_thumb      => 1,
		misc_settings => { computer => {} },
	});
	like( $dest, qr{/demo/\.thumbs/\z}, 'a configured photo location is used' );
}

# --- the non-thumbnail fallback is the person's Downloads folder -------------

{
	local $subs::device = 'computer';
	local *subs::setting_grabber = sub { return undef };

	my ($dest) = &subs::file_device_renamer({
		file          => "$tree/Pictures/demo/e.bin",
		app           => 'demo',
		is_thumb      => 0,
		misc_settings => { computer => {} },
	});
	like( $dest, qr{/Downloads/demo/}, 'a non-thumbnail with no location falls back to Downloads' );
	unlike( $dest, qr{^/demo/}, 'and not to /<app>' );
}

# --- the listing and confirm wiring -----------------------------------------

my $controller = read_file("$FindBin::Bin/../lib/JawnOS/Controller/manager_configure5.pm");
my ($listing) = $controller =~ /sub action_41659 \{(.*?)\n\}/s;
my ($confirm) = $controller =~ /sub action_41704 \{(.*?)\n\}/s;

ok( defined $listing, 'the adopt listing action is present' );
unlike( $listing, qr/rock_and_roll/, 'the listing does not serve or encode whole files' );
unlike( $listing, qr/encode_base64/, 'the listing builds no data URI' );
like( $listing, qr/adopt_scan_candidates/, 'the listing uses the scan helper' );
like( $listing, qr/adopted="yes"/, 'every candidate starts selected' );
like( $listing, qr/thumb=ya/, 'previews are lazy thumbnail requests' );
like( $listing, qr/xml_escape/, 'markup is escaped' );

ok( defined $confirm, 'the adopt confirm action is present' );
like( $confirm, qr/Nothing was selected to adopt/, 'an empty selection is refused' );
like( $confirm, qr/adopt_media_type/, 'the type is derived from the path' );
like( $confirm, qr/path_is_within/, 'a path is checked against a location' );
like( $confirm, qr/\.enc/, 'a sealed file is refused' );
ok( index($confirm, "delete \$data->{'thumb'}") >= 0, 'a thumb that was not written is dropped' );

my $js = js_source('js/manager/configure.js');
like( $js, qr/\.adopt_file\[adopted="yes"\]/, 'the confirm selector has its closing bracket' );
unlike( $js, qr/\[adopted="yes"(?!\])/, 'no adopt selector is left malformed' );
like( $js, qr/result\.ok === 0/, 'the dialog keeps itself open when the server refuses' );
unlike( $js, qr/timestamp, timestamp/, 'the duplicate data key is gone' );

my $writer = read_file("$FindBin::Bin/../lib/JawnOS/Manager/Part05.pm");
like( $writer, qr/select type,file,timestamp,uuid from appointments.*?order by timestamp desc limit 1/s, 'adopted media joins the newest start/record' );

done_testing();
