#!/usr/bin/env perl
# JawnOS cursor-set generator.
#
#   perl public/cursors/build.pl
#
# Writes public/cursors/sets/<set>/<role>.svg and the matching .png for every
# cursor a theme may wear. The app serves the PNGs: Chromium (Qt WebEngine on the
# desktop, Android System WebView on a phone) renders raster CSS cursors, not
# SVG ones, so the SVG beside each PNG is the editable source and the raster is
# what a browser actually loads.
#
# A set is a fill/halo pair and an outline weight. The same glyph library is
# drawn in each pair, so the whole pointer changes with the theme while every
# role keeps its meaning (an I-beam still marks text, a hand still marks a link).
# The halo is what makes one cut work on a light and a dark desktop, so a set
# does not need a _dark twin the way the icon sets do.
#
# The raster is drawn with ImageMagick's MVG primitives rather than by rasterising
# the SVG: on a box without librsvg, ImageMagick's internal SVG renderer drops
# stroke-only paths (an I-beam, a crosshair, a resize shaft), so the PNGs came
# out with floating arrowheads and no shafts. MVG draws the same parts reliably.

use strict;
use warnings;

use FindBin;
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use POSIX qw(cos sin);

my $DIR = $FindBin::Bin;
my $MAGICK = $ENV{'MAGICK'} || 'magick';
my $SIZE = 32;
# The sizes the server offers. 32 is the base tile written beside the SVG;
# the others live in a numbered folder and are only written when asked for.
our @SIZES = ( 16, 24, 40, 48 );

# Each role's hotspot (the point the browser aligns with the pointer) is shared
# by every set: it is geometry, not dressing. The renderer never reads this; the
# server writes it into the CSS.
our %HOTSPOT = (
	'default'      => '5 5',
	'pointer'      => '12 7',
	'text'         => '16 16',
	'vertical-text'=> '16 16',
	'move'         => '16 16',
	'grab'         => '16 16',
	'grabbing'     => '16 16',
	'not-allowed'  => '16 16',
	'no-drop'      => '16 16',
	'wait'         => '16 16',
	'progress'     => '16 16',
	'crosshair'    => '16 16',
	'cell'         => '16 16',
	'col-resize'   => '16 16',
	'row-resize'   => '16 16',
	'ns-resize'    => '16 16',
	'ew-resize'    => '16 16',
	'n-resize'     => '16 16',
	's-resize'     => '16 16',
	'e-resize'     => '16 16',
	'w-resize'     => '16 16',
	'ne-resize'    => '16 16',
	'sw-resize'    => '16 16',
	'nw-resize'    => '16 16',
	'se-resize'    => '16 16',
	'nesw-resize'  => '16 16',
	'nwse-resize'  => '16 16',
);

# Sets. fill is the glyph, halo is the outline that keeps it legible on either
# desktop, weight is the glyph's own stroke in px. glow draws a translucent copy
# behind the halo in the fill colour (the neon set).
our @SETS = (
	{ name => 'bold',    fill => '#111111', halo => '#ffffff', weight => 2.2 },
	{ name => 'white',   fill => '#ffffff', halo => '#101820', weight => 2.0 },
	{ name => 'outline', fill => '#ffffff', halo => '#000000', weight => 2.6 },
	{ name => 'neon',    fill => '#22e6ff', halo => '#050a0c', weight => 2.0, glow => 1 },
	{ name => 'pastel',  fill => '#ffb0c8', halo => '#3a1f2b', weight => 2.0 },
	{ name => 'mono',    fill => '#c8ccd2', halo => '#161a20', weight => 2.0 },
	# High contrast: a yellow pointer inside a heavy black outline. It stays
	# legible on any desktop and is the set to reach for when the ordinary
	# arrow is hard to find.
	{ name => 'contrast', fill => '#ffdd00', halo => '#000000', weight => 2.6 },
);

sub num { return sprintf '%.2f', $_[0] }

sub rotate_point {
	my ($deg, $x, $y) = @_;
	my $r = $deg * 3.14159265358979 / 180;
	my ($dx, $dy) = ( $x - 16, $y - 16 );
	return (
		16 + $dx * cos($r) - $dy * sin($r),
		16 + $dx * sin($r) + $dy * cos($r),
	);
}

# A double-headed resize arrow: shaft plus two arrowheads, rotated to point along
# the role's axis. 0 is horizontal, 90 vertical, -45 rises to the right.
sub double_arrow {
	my ($deg) = @_;
	my @p = map { [ &rotate_point($deg, @{$_}) ] } (
		[ 7, 16 ], [ 25, 16 ],                # shaft ends
		[ 3, 16 ], [ 9, 11.5 ], [ 9, 20.5 ],  # left head
		[ 29, 16 ], [ 23, 11.5 ], [ 23, 20.5 ], # right head
	);
	my $path = sub {
		my @pts = @_;
		return 'M' . &num($pts[0]->[0]) . ' ' . &num($pts[0]->[1])
			. join('', map { ' L' . &num($_->[0]) . ' ' . &num($_->[1]) } @pts[1..$#pts]);
	};
	return [
		{ el => 'path', d => $path->(@p[0, 1]), fill => 0 },
		{ el => 'path', d => $path->(@p[2, 3, 4]) . ' Z', fill => 1 },
		{ el => 'path', d => $path->(@p[5, 6, 7]) . ' Z', fill => 1 },
	];
}

# A part is { el => 'path'|'rect'|'circle', %attrs, fill => 0|1 }.
# fill 0 is a stroke-only part (an I-beam, a crosshair, a double arrow's shaft).
# Every role is the union of its parts; the renderer draws all halos first and
# then all glyphs, so overlapping parts do not punch holes in each other.
our %SHAPES = (
	'default' => [
		{ el => 'path', d => 'M5 4 L5 26 L11 20.2 L14.6 28 L18.6 26.3 L15 18.6 L24 18.4 Z', fill => 1 },
	],
	'pointer' => [
		{ el => 'path', d => 'M10 16 V7.5 a2.6 2.6 0 0 1 5.2 0 V16 h1.2 V10.5 a2.4 2.4 0 0 1 4.8 0 v5.5 h1.2 v-2.5 a2.4 2.4 0 0 1 4.8 0 v8.5 c0 4.2-2.8 7.5-7 7.5 h-3.2 c-2.8 0-5.2-1.5-6.6-3.9 l-3.1-5.1 a2.4 2.4 0 0 1 4.1-2.4 z', fill => 1 },
	],
	'text' => [
		{ el => 'path', d => 'M11 6 H21 M16 6 V26 M11 26 H21', fill => 0 },
	],
	'vertical-text' => [
		{ el => 'path', d => 'M6 11 V21 M6 16 H26 M26 11 V21', fill => 0 },
	],
	'move' => [
		{ el => 'path', d => 'M16 6 V26 M6 16 H26', fill => 0 },
		{ el => 'path', d => 'M16 3 L11.5 9 H20.5 Z', fill => 1 },
		{ el => 'path', d => 'M16 29 L11.5 23 H20.5 Z', fill => 1 },
		{ el => 'path', d => 'M3 16 L9 11.5 V20.5 Z', fill => 1 },
		{ el => 'path', d => 'M29 16 L23 11.5 V20.5 Z', fill => 1 },
	],
	'grab' => [
		{ el => 'rect', x => 7, y => 14, width => 19, height => 13, rx => 6, fill => 1 },
		{ el => 'rect', x => 8.5, y => 7, width => 3.4, height => 10, rx => 1.7, fill => 1 },
		{ el => 'rect', x => 12.5, y => 5, width => 3.4, height => 12, rx => 1.7, fill => 1 },
		{ el => 'rect', x => 16.5, y => 6, width => 3.4, height => 11, rx => 1.7, fill => 1 },
		{ el => 'rect', x => 20.5, y => 8, width => 3.4, height => 9, rx => 1.7, fill => 1 },
		{ el => 'rect', x => 3.8, y => 17, width => 3.6, height => 8, rx => 1.8, fill => 1 },
	],
	'grabbing' => [
		{ el => 'rect', x => 7, y => 13, width => 19, height => 14, rx => 6, fill => 1 },
		{ el => 'rect', x => 9, y => 10.5, width => 4, height => 5, rx => 2, fill => 1 },
		{ el => 'rect', x => 13.2, y => 9.5, width => 4, height => 5, rx => 2, fill => 1 },
		{ el => 'rect', x => 17.4, y => 10, width => 4, height => 5, rx => 2, fill => 1 },
		{ el => 'rect', x => 21, y => 11, width => 3.6, height => 4.6, rx => 1.8, fill => 1 },
	],
	'not-allowed' => [
		{ el => 'circle', cx => 16, cy => 16, r => 10, fill => 0 },
		{ el => 'path', d => 'M9.2 22.8 L22.8 9.2', fill => 0 },
	],
	'no-drop' => [
		{ el => 'circle', cx => 16, cy => 16, r => 10, fill => 0 },
		{ el => 'path', d => 'M9.2 22.8 L22.8 9.2', fill => 0 },
	],
	'wait' => [
		{ el => 'path', d => 'M9 4 H23 V8 L17.5 16 L23 24 V28 H9 V24 L14.5 16 L9 8 Z', fill => 1 },
	],
	'progress' => [
		{ el => 'path', d => 'M9 4 H23 V8 L17.5 16 L23 24 V28 H9 V24 L14.5 16 L9 8 Z', fill => 1 },
	],
	'crosshair' => [
		{ el => 'path', d => 'M16 4 V11 M16 21 V28 M4 16 H11 M21 16 H28', fill => 0 },
		{ el => 'circle', cx => 16, cy => 16, r => 1.6, fill => 1 },
	],
	'cell' => [
		{ el => 'path', d => 'M16 4 V11 M16 21 V28 M4 16 H11 M21 16 H28', fill => 0 },
		{ el => 'circle', cx => 16, cy => 16, r => 1.6, fill => 1 },
	],
	'col-resize' => &double_arrow(0),
	'ew-resize'  => &double_arrow(0),
	'row-resize' => &double_arrow(90),
	'ns-resize'  => &double_arrow(90),
	'n-resize'   => &double_arrow(90),
	's-resize'   => &double_arrow(90),
	'e-resize'   => &double_arrow(0),
	'w-resize'   => &double_arrow(0),
	'ne-resize'  => &double_arrow(-45),
	'sw-resize'  => &double_arrow(-45),
	'nesw-resize'=> &double_arrow(-45),
	'nw-resize'  => &double_arrow(45),
	'se-resize'  => &double_arrow(45),
	'nwse-resize'=> &double_arrow(45),
);

sub part_attrs {
	my ($part) = @_;
	my $el = $part->{'el'} || 'path';
	my @keys = $el eq 'path' ? ('d')
		: $el eq 'rect' ? ('x', 'y', 'width', 'height', 'rx')
		: ('cx', 'cy', 'r');
	my $out = '';
	foreach my $key ( @keys ) {
		next unless defined $part->{$key};
		$out .= qq{ $key="$part->{$key}"};
	}
	return $out;
}

sub part_svg {
	my ($part, $style) = @_;
	my $el = $part->{'el'} || 'path';
	return "<$el" . &part_attrs($part) . " $style/>";
}

# The editable source. Browsers draw SVG cursors correctly; the PNGs are what
# Chromium actually loads.
sub svg_for {
	my ($set) = @_;
	my ($fill, $halo, $weight) = ( $set->{'fill'}, $set->{'halo'}, $set->{'weight'} );
	my $halo_weight = $weight + 4.5;
	my %out;
	foreach my $role ( sort keys %SHAPES ) {
		my @parts = @{ $SHAPES{$role} };
		my $svg = qq{<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $SIZE $SIZE" width="$SIZE" height="$SIZE">};
		if ($set->{'glow'}) {
			$svg .= '<g opacity="0.35">';
			foreach my $part ( @parts ) {
				my $style = $part->{'fill'}
					? qq{fill="$fill" stroke="$fill" stroke-width="10" stroke-linejoin="round" stroke-linecap="round"}
					: qq{fill="none" stroke="$fill" stroke-width="11" stroke-linejoin="round" stroke-linecap="round"};
				$svg .= &part_svg($part, $style);
			}
			$svg .= '</g>';
		}
		$svg .= '<g>';
		foreach my $part ( @parts ) {
			my $style = $part->{'fill'}
				? qq{fill="$halo" stroke="$halo" stroke-width="$halo_weight" stroke-linejoin="round" stroke-linecap="round"}
				: qq{fill="none" stroke="$halo" stroke-width="$halo_weight" stroke-linejoin="round" stroke-linecap="round"};
			$svg .= &part_svg($part, $style);
		}
		foreach my $part ( @parts ) {
			my $style = $part->{'fill'}
				? qq{fill="$fill" stroke="$halo" stroke-width="1.4" stroke-linejoin="round" stroke-linecap="round"}
				: qq{fill="none" stroke="$fill" stroke-width="$weight" stroke-linejoin="round" stroke-linecap="round"};
			$svg .= &part_svg($part, $style);
		}
		$svg .= '</g></svg>';
		$out{$role} = $svg;
	}
	return \%out;
}

sub mvg_primitive {
	my ($part) = @_;
	my $el = $part->{'el'} || 'path';
	if ($el eq 'path') {
		return "path '$part->{'d'}'";
	}
	if ($el eq 'rect') {
		my $x2 = $part->{'x'} + $part->{'width'};
		my $y2 = $part->{'y'} + $part->{'height'};
		my $rx = $part->{'rx'} || 0;
		return 'roundrectangle ' . &num($part->{'x'}) . ',' . &num($part->{'y'}) . ' '
			. &num($x2) . ',' . &num($y2) . ' ' . &num($rx) . ',' . &num($rx);
	}
	my $r = $part->{'r'};
	return 'circle ' . &num($part->{'cx'}) . ',' . &num($part->{'cy'}) . ' '
		. &num($part->{'cx'} + $r) . ',' . &num($part->{'cy'});
}

# One -draw string: glow, every halo, then every glyph. MVG keeps the last
# fill/stroke/width, so each primitive states its own and the order is explicit.
sub mvg_for {
	my ($set) = @_;
	my ($fill, $halo, $weight) = ( $set->{'fill'}, $set->{'halo'}, $set->{'weight'} );
	my $halo_weight = $weight + 4.5;
	my %out;
	foreach my $role ( sort keys %SHAPES ) {
		my @parts = @{ $SHAPES{$role} };
		my @draw;
		push @draw, 'stroke-linejoin round stroke-linecap round';
		if ($set->{'glow'}) {
			push @draw, "stroke-opacity 0.35 fill-opacity 0.35";
			foreach my $part ( @parts ) {
				my $style = $part->{'fill'}
					? "fill '$fill' stroke '$fill' stroke-width 10"
					: "fill none stroke '$fill' stroke-width 11";
				push @draw, $style, &mvg_primitive($part);
			}
			push @draw, "stroke-opacity 1 fill-opacity 1";
		}
		foreach my $part ( @parts ) {
			my $style = $part->{'fill'}
				? "fill '$halo' stroke '$halo' stroke-width $halo_weight"
				: "fill none stroke '$halo' stroke-width $halo_weight";
			push @draw, $style, &mvg_primitive($part);
		}
		foreach my $part ( @parts ) {
			my $style = $part->{'fill'}
				? "fill '$fill' stroke '$halo' stroke-width 1.4"
				: "fill none stroke '$fill' stroke-width $weight";
			push @draw, $style, &mvg_primitive($part);
		}
		$out{$role} = join ' ', @draw;
	}
	return \%out;
}

my $made = 0;
foreach my $set ( @SETS ) {
	my $name = $set->{'name'};
	my $dir = "$DIR/sets/$name";
	make_path($dir);
	my $svg = &svg_for($set);
	my $mvg = &mvg_for($set);
	foreach my $role ( sort keys %SHAPES ) {
		my $svg_path = "$dir/$role.svg";
		my $png_path = "$dir/$role.png";
		open(my $fh, '>', $svg_path) or die "$svg_path: $!";
		print $fh $svg->{$role}, "\n";
		close $fh;
		# Draw once at three times the design size, then scale down. A 16px
		# cursor drawn at 16 directly loses the outline; a 48px one drawn at 48
		# would need every coordinate tripled by hand.
		my ($tmp_fh, $master) = tempfile(SUFFIX => '.png', UNLINK => 1);
		close $tmp_fh;
		my $draw = 'scale 3,3 ' . $mvg->{$role};
		system($MAGICK, '-size', '96x96', 'xc:none', '-draw', $draw, '-depth', '8', '-strip', $master) == 0
			or die "could not draw $master: $?\n";
		foreach my $size ( $SIZE, @SIZES ) {
			my $target = $size == $SIZE ? $png_path : "$dir/$size/$role.png";
			make_path("$dir/$size") if $size != $SIZE;
			system($MAGICK, $master, '-resize', "${size}x${size}", '-depth', '8', '-strip', $target) == 0
				or die "could not write $target: $?\n";
			$made++;
		}
	}
	print "wrote $name: " . scalar(keys %SHAPES) . " roles\n";
}
print "wrote $made files under $DIR/sets\n";
