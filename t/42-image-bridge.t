use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use JawnOSTest;

use MIME::Base64 ();

# M3's ImageMagick diet: the tree asks the device bridge to resize and re-encode
# images. A desktop has no bridge, so these helpers answer undef and the caller
# keeps its magick pipeline. The bridge method list is pinned in
# t/23-device-methods.t; this file pins the argument mapping and the fallback.

my $tmp = tempdir(CLEANUP => 1);
my $png = "$tmp/x.png";
open(my $fh, '>', $png) or die "$png: $!";
print $fh "not really a png\n";
close $fh;

is_deeply( [ subs::image_resolution_parts('1920x1080') ], [ 1920, 1080 ],
	'a WxH setting is parsed' );
is_deeply( [ subs::image_resolution_parts(' 640 x 480 ') ], [ 640, 480 ],
	'whitespace around the x is accepted' );
is_deeply( [ subs::image_resolution_parts('Raw') ], [], 'Raw is not a size' );
is_deeply( [ subs::image_resolution_parts(undef) ], [], 'no setting is not a size' );

{
	local *subs::device_call = sub {
		my ( $method, $args ) = @_;
		return { path => $args->{'out'}, width => $args->{'width'}, height => $args->{'height'} }
			if $method eq 'image.resize';
		return { path => $args->{'out'}, width => 1, height => 1 }
			if $method eq 'image.save';
		return undef;
	};

	my $resized = subs::image_bridge_resize($png, 100, 50);
	ok( ref $resized eq 'HASH', 'a bridge answer is returned' );
	is( $resized->{'path'}, $png, 'the resize writes in place by default' );
	is( $resized->{'width'}, 100, 'the requested width is passed through' );
	is( $resized->{'height'}, 50, 'the requested height is passed through' );

	my $out = "$tmp/y.jpg";
	my $saved = subs::image_bridge_save($png, $out, 'jpeg', 80);
	ok( ref $saved eq 'HASH', 'a save answer is returned' );
	is( $saved->{'path'}, $out, 'the save writes the named file' );

	my $other = "$tmp/z.jpg";
	my $placed = subs::image_bridge_resize($png, 10, 10, $other);
	is( $placed->{'path'}, $other, 'a resize can name its output' );
}

{
	local *subs::device_call = sub { return undef };
	ok( !defined subs::image_bridge_resize($png, 100, 50),
		'no bridge answer means the caller keeps magick' );
	ok( !defined subs::image_bridge_save($png, "$tmp/no.jpg", 'jpeg', 90),
		'and the save fallback is the same' );
}

ok( !defined subs::image_bridge_resize("$tmp/missing.png", 10, 10),
	'a missing source is not sent to the bridge' );
ok( !defined subs::image_bridge_resize($png, 0, 0),
	'zero dimensions are not sent to the bridge' );
ok( !defined subs::image_bridge_save($png, '', 'jpeg', 90),
	'a save without an output path is refused' );

# The palette's steps: the bridge gets the whole list in one call, with
# save/copy/clear filtered out (the route handles those itself) and an unknown
# duty name refused before it can reach the app.
{
	my @asked;
	local *subs::device_call = sub {
		my ( $method, $args ) = @_;
		push @asked, [ $method, $args ];
		return { path => $args->{'out'}, width => 4, height => 4, applied => 2, skipped => [] }
			if $method eq 'image.edit';
		return undef;
	};

	my $edited = subs::image_bridge_edit($png, [
		{ duty => 'rotate', value => '90' },
		{ duty => 'save',   value => '' },
		{ duty => 'crop',   value => '10x10+1+1' },
	]);
	ok( ref $edited eq 'HASH', 'the edit answer is returned' );
	is( $edited->{'path'}, $png, 'the edit writes in place by default' );
	is( scalar @asked, 1, 'one bridge call carries the whole list' );
	is( $asked[0]->[0], 'image.edit', 'the method is image.edit' );
	is_deeply( $asked[0]->[1]->{'duties'},
		[ { duty => 'rotate', value => '90' }, { duty => 'crop', value => '10x10+1+1' } ],
		'save is not sent as an edit step' );

	my $named = subs::image_bridge_edit($png, [ { duty => 'sharpen', value => '2' } ], "$tmp/out.png");
	is( $named->{'path'}, "$tmp/out.png", 'an edit can name its output' );

	ok( !defined subs::image_bridge_edit($png, [ { duty => 'save' } ]),
		'a list of only route-handled duties is not sent' );
	ok( !defined subs::image_bridge_edit($png, [ { duty => 'evil; rm -rf /' } ]),
		'a duty name outside the step alphabet is refused' );
	ok( !defined subs::image_bridge_edit($png, []), 'an empty list is not sent' );
	ok( !defined subs::image_bridge_edit("$tmp/missing.png", [ { duty => 'rotate', value => '90' } ]),
		'a missing source is not sent' );
}

{
	local *subs::device_call = sub { return undef };
	ok( !defined subs::image_bridge_edit($png, [ { duty => 'rotate', value => '90' } ]),
		'no bridge answer means the caller keeps magick' );
}

# The avatar/cover copy: the bridge fills a square from the centre.
{
	my @asked;
	local *subs::device_call = sub {
		my ( $method, $args ) = @_;
		push @asked, [ $method, $args ];
		return { path => $args->{'out'}, width => $args->{'size'}, height => $args->{'size'} }
			if $method eq 'image.cover';
		return undef;
	};

	my $cover = subs::image_bridge_cover($png, 160, "$tmp/avatar.jpg", 82);
	ok( ref $cover eq 'HASH', 'the cover answer is returned' );
	is( $cover->{'path'}, "$tmp/avatar.jpg", 'the cover writes the named file' );
	is( $asked[0]->[0], 'image.cover', 'the method is image.cover' );
	is( $asked[0]->[1]->{'size'}, 160, 'the square side is passed through' );
	is( $asked[0]->[1]->{'quality'}, 82, 'the JPEG quality is passed through' );

	ok( !defined subs::image_bridge_cover($png, 160, ''), 'a cover without an output is refused' );
	ok( !defined subs::image_bridge_cover("$tmp/missing.png", 160, "$tmp/x.jpg"),
		'a missing source is not sent' );
}

# A thumbnail file: the bridge's PNG bytes land where the caller asked.
{
	my $png_bytes = "\x89PNG\r\n\x1a\nbridge-thumb";
	my @asked;
	local *subs::device_call = sub {
		my ( $method, $args ) = @_;
		push @asked, [ $method, $args ];
		return { data => MIME::Base64::encode_base64($png_bytes, ''), width => 2, height => 2, kind => 'image' }
			if $method eq 'media.thumbnail';
		return undef;
	};

	my $file = "$tmp/thumb.png";
	my $made = subs::image_bridge_thumbnail($png, 128, $file);
	is( $made, $file, 'the thumbnail is written at the named path' );
	my $written = '';
	if (open(my $rf, '<', $file)) { binmode $rf; local $/; $written = <$rf>; close $rf; }
	is( $written, $png_bytes, 'the bridge bytes are what was written' );
	is( $asked[0]->[0], 'media.thumbnail', 'the bridge thumbnail method is asked' );
	is( $asked[0]->[1]->{'max'}, 128, 'the size is passed through' );
}

{
	local *subs::device_call = sub { return undef };
	ok( !defined subs::image_bridge_thumbnail($png, 128, "$tmp/none.png"),
		'no bridge answer leaves the ffmpeg pipeline in place' );
	ok( !defined subs::image_bridge_cover($png, 160, "$tmp/none.jpg"),
		'and the cover falls back to magick' );
}

# Identify: the bridge reports the source's shape and kind, and nothing else
# is sent. A missing source never reaches the bridge.
{
	my @asked;
	local *subs::device_call = sub {
		my ( $method, $args ) = @_;
		push @asked, [ $method, $args ];
		return { width => 1920, height => 1080, kind => 'image' }
			if $method eq 'image.identify';
		return undef;
	};

	my $info = subs::image_bridge_identify($png);
	ok( ref $info eq 'HASH', 'an identify answer is returned' );
	is( $info->{'width'}, 1920, 'the reported width is kept' );
	is( $info->{'height'}, 1080, 'the reported height is kept' );
	is( $info->{'kind'}, 'image', 'the reported kind is kept' );
	is( $asked[0]->[0], 'image.identify', 'the method is image.identify' );
	is_deeply( $asked[0]->[1], { path => $png }, 'identify sends only the path' );
}

ok( !defined subs::image_bridge_identify("$tmp/missing.png"),
	'a missing source is not identified' );

{
	local *subs::device_call = sub { return undef };
	ok( !defined subs::image_bridge_identify($png),
		'no bridge answer means identify falls back' );
}

# Convert: path and out are always sent, the five options only when supplied.
{
	my @asked;
	local *subs::device_call = sub {
		my ( $method, $args ) = @_;
		push @asked, [ $method, $args ];
		return { path => $args->{'out'} } if $method eq 'image.convert';
		return undef;
	};

	my $converted = subs::image_bridge_convert($png, "$tmp/out.webp",
		format => 'webp', quality => 77, max_width => 800, max_height => 600, auto_orient => 1);
	ok( ref $converted eq 'HASH', 'a convert answer is returned' );
	is( $converted->{'path'}, "$tmp/out.webp", 'the convert writes the named file' );
	is( $asked[0]->[0], 'image.convert', 'the method is image.convert' );
	is( $asked[0]->[1]->{'path'}, $png, 'the source is passed through' );
	is( $asked[0]->[1]->{'out'}, "$tmp/out.webp", 'the output is passed through' );
	is( $asked[0]->[1]->{'format'}, 'webp', 'the format is passed through' );
	is( $asked[0]->[1]->{'quality'}, 77, 'the quality is passed through' );
	is( $asked[0]->[1]->{'max_width'}, 800, 'the maximum width is passed through' );
	is( $asked[0]->[1]->{'max_height'}, 600, 'the maximum height is passed through' );
	is( $asked[0]->[1]->{'auto_orient'}, 1, 'auto-orient is passed through' );

	subs::image_bridge_convert($png, "$tmp/bare.jpg");
	is_deeply( $asked[1]->[1], { path => $png, out => "$tmp/bare.jpg" },
		'the options are absent when not supplied' );
}

ok( !defined subs::image_bridge_convert("$tmp/missing.png", "$tmp/none.jpg"),
	'a convert with no source is refused' );
ok( !defined subs::image_bridge_convert($png, ''),
	'a convert without an output path is refused' );

{
	local *subs::device_call = sub { return undef };
	ok( !defined subs::image_bridge_convert($png, "$tmp/none.jpg"),
		'no bridge answer means the caller keeps magick' );
}

# Gray: the answer's base64 data is decoded to raw bytes. Width and height are
# required and must be positive.
{
	my $gray_bytes = "\x89PNG\r\n\x1a\ngray-bytes";
	my @asked;
	local *subs::device_call = sub {
		my ( $method, $args ) = @_;
		push @asked, [ $method, $args ];
		return { data => MIME::Base64::encode_base64($gray_bytes, '') }
			if $method eq 'image.gray';
		return undef;
	};

	my $gray = subs::image_bridge_gray($png, 64, 32);
	is( $gray, $gray_bytes, 'the gray answer is decoded to raw bytes' );
	is( $asked[0]->[0], 'image.gray', 'the method is image.gray' );
	is_deeply( $asked[0]->[1], { path => $png, width => 64, height => 32 },
		'path, width and height are passed through' );
}

ok( !defined subs::image_bridge_gray("$tmp/missing.png", 8, 8),
	'a missing source is not grayed' );
ok( !defined subs::image_bridge_gray($png, 0, 8),
	'a zero width is not sent to the bridge' );
ok( !defined subs::image_bridge_gray($png, 8, -1),
	'a negative height is not sent to the bridge' );

{
	local *subs::device_call = sub { return undef };
	ok( !defined subs::image_bridge_gray($png, 8, 8),
		'no bridge answer means gray falls back' );
}

# Normalize: the helper reports the output path it named, and passes the cap
# through untouched.
{
	my @asked;
	local *subs::device_call = sub {
		my ( $method, $args ) = @_;
		push @asked, [ $method, $args ];
		return { path => $args->{'out'} } if $method eq 'image.normalize';
		return undef;
	};

	my $normalized = subs::image_bridge_normalize($png, "$tmp/normal.png", 1024);
	is( $normalized, "$tmp/normal.png", 'normalize returns the named output' );
	is( $asked[0]->[0], 'image.normalize', 'the method is image.normalize' );
	is_deeply( $asked[0]->[1], { path => $png, out => "$tmp/normal.png", max => 1024 },
		'path, out and max are passed through' );
}

ok( !defined subs::image_bridge_normalize("$tmp/missing.png", "$tmp/none.png", 512),
	'a missing source is not normalized' );
ok( !defined subs::image_bridge_normalize($png, '', 512),
	'a normalize without an output path is refused' );

{
	local *subs::device_call = sub { return undef };
	ok( !defined subs::image_bridge_normalize($png, "$tmp/none.png", 512),
		'no bridge answer means normalize falls back' );
}

# Montage: the whole list goes in one call and the bridge's PNG bytes come
# back. The app may answer the bytes as base64 data or write the named temp
# file, so the fixture does both.
{
	my $montage_png = "\x89PNG\r\n\x1a\nmontage-bytes";
	my @asked;
	local *subs::device_call = sub {
		my ( $method, $args ) = @_;
		push @asked, [ $method, $args ];
		if ( $method eq 'image.montage' ) {
			if ( open(my $of, '>', $args->{'out'}) ) {
				binmode $of;
				print $of $montage_png;
				close $of;
			}
			return {
				path => $args->{'out'},
				data => MIME::Base64::encode_base64($montage_png, ''),
			};
		}
		return undef;
	};

	my $montage = subs::image_bridge_montage([ $png, $png ]);
	is( $montage, $montage_png, 'the montage returns the PNG bytes' );
	is( $asked[0]->[0], 'image.montage', 'the method is image.montage' );
	is_deeply( $asked[0]->[1]->{'paths'}, [ $png, $png ],
		'the path list is passed through' );
	ok( defined $asked[0]->[1]->{'out'} && length $asked[0]->[1]->{'out'},
		'the montage names a temporary output' );

	ok( !defined subs::image_bridge_montage([ "$tmp/missing-a.png", "$tmp/missing-b.png" ]),
		'a montage list with no existing files is refused' );
}

{
	local *subs::device_call = sub { return undef };
	ok( !defined subs::image_bridge_montage([$png]),
		'no bridge answer means montage falls back' );
}

done_testing();
