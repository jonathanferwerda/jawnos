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

done_testing();
