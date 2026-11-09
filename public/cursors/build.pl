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
# Each set is a silhouette as well as a paint: the classic arrow, a slim needle,
# a hollow wireframe, a cyber cutout, a rounded blob, a pixel staircase and an
# oversized high-contrast block. The same role keeps its meaning (an I-beam still
# marks text, a hand still marks a link) while the pointer's character changes.
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
# desktop, weight is the glyph's own stroke in px. head picks the resize
# arrowhead (solid, chevron, hollow, rounded, block), edge is the glyph's rim and
# halo_extra how far the halo reaches past it. glow draws a translucent copy
# behind the halo in the fill colour (the neon set).
our @SETS = (
	{ name => 'bold',     fill => '#111111', halo => '#ffffff', weight => 2.2, edge => 1.8, halo_extra => 4.5, head => 'solid' },
	{ name => 'white',    fill => '#ffffff', halo => '#101820', weight => 1.6, edge => 1.0, halo_extra => 3.2, head => 'chevron' },
	{ name => 'outline',  fill => '#ffffff', halo => '#000000', weight => 3.2, edge => 2.0, halo_extra => 4.0, head => 'hollow' },
	{ name => 'neon',     fill => '#22e6ff', halo => '#050a0c', weight => 2.0, edge => 1.6, halo_extra => 4.8, head => 'chevron', gap => 1, glow => 1 },
	{ name => 'pastel',   fill => '#ffb0c8', halo => '#3a1f2b', weight => 2.0, edge => 2.0, halo_extra => 4.5, head => 'rounded' },
	{ name => 'mono',     fill => '#c8ccd2', halo => '#161a20', weight => 2.0, edge => 1.2, halo_extra => 3.8, head => 'block' },
	# High contrast: a yellow pointer inside a heavy black outline. It stays
	# legible on any desktop and is the set to reach for when the ordinary
	# arrow is hard to find.
	{ name => 'contrast', fill => '#ffdd00', halo => '#000000', weight => 3.0, edge => 2.6, halo_extra => 5.5, head => 'block' },
);

use constant PI => 3.14159265358979;

sub num { return sprintf '%.2f', $_[0] }

sub rotate_point {
	my ($deg, $x, $y) = @_;
	my $r = $deg * PI / 180;
	my ($dx, $dy) = ( $x - 16, $y - 16 );
	return (
		16 + $dx * cos($r) - $dy * sin($r),
		16 + $dx * sin($r) + $dy * cos($r),
	);
}

sub rot_path {
	my ($deg, @pts) = @_;
	my @p = map { [ &rotate_point($deg, @{$_}) ] } @pts;
	my $out = 'M' . &num($p[0]->[0]) . ' ' . &num($p[0]->[1]);
	$out .= join('', map { ' L' . &num($_->[0]) . ' ' . &num($_->[1]) } @p[1..$#p]);
	return $out;
}

sub rot_rect {
	my ($deg, $cx, $cy, $w, $h) = @_;
	my ($hw, $hh) = ( $w / 2, $h / 2 );
	return &rot_path($deg,
		[ $cx - $hw, $cy - $hh ], [ $cx + $hw, $cy - $hh ],
		[ $cx + $hw, $cy + $hh ], [ $cx - $hw, $cy + $hh ],
	) . ' Z';
}

# A double-headed resize arrow: shaft plus two heads, rotated to point along the
# role's axis. 0 is horizontal, 90 vertical, -45 rises to the right. The head
# style is part of a set's character: a solid triangle for the classic sets, a
# chevron for the thin and cyber cuts, a hollow triangle for the wireframe, a
# round dumbbell for pastel and a square block for the terminal and contrast.
sub resize_shapes {
	my ($deg, $style, $gap) = @_;
	$style ||= 'solid';
	my $line = sub {
		my ($x1, $y1, $x2, $y2) = @_;
		return &rot_path($deg, [ $x1, $y1 ], [ $x2, $y2 ]);
	};
	my $tri = sub {
		my ($tipx, $tipy, $ax, $ay, $bx, $by) = @_;
		return &rot_path($deg, [ $tipx, $tipy ], [ $ax, $ay ], [ $bx, $by ]) . ' Z';
	};
	my @parts;
	if ($style eq 'chevron') {
		if ($gap) {
			push @parts, { el => 'path', d => $line->(9, 16, 14, 16), fill => 0 };
			push @parts, { el => 'path', d => $line->(18, 16, 23, 16), fill => 0 };
		}
		else {
			push @parts, { el => 'path', d => $line->(9, 16, 23, 16), fill => 0 };
		}
		push @parts, { el => 'path', d => $line->(3, 16, 9, 11.5), fill => 0 };
		push @parts, { el => 'path', d => $line->(3, 16, 9, 20.5), fill => 0 };
		push @parts, { el => 'path', d => $line->(29, 16, 23, 11.5), fill => 0 };
		push @parts, { el => 'path', d => $line->(29, 16, 23, 20.5), fill => 0 };
	}
	elsif ($style eq 'hollow') {
		push @parts, { el => 'path', d => $line->(7, 16, 25, 16), fill => 0 };
		push @parts, { el => 'path', d => $tri->(3, 16, 9, 11.5, 9, 20.5), fill => 0 };
		push @parts, { el => 'path', d => $tri->(29, 16, 23, 11.5, 23, 20.5), fill => 0 };
	}
	elsif ($style eq 'rounded') {
		push @parts, { el => 'path', d => $line->(9, 16, 23, 16), fill => 0 };
		my ($ax, $ay) = &rotate_point($deg, 7, 16);
		my ($bx, $by) = &rotate_point($deg, 25, 16);
		push @parts, { el => 'circle', cx => &num($ax), cy => &num($ay), r => 3.2, fill => 1 };
		push @parts, { el => 'circle', cx => &num($bx), cy => &num($by), r => 3.2, fill => 1 };
	}
	elsif ($style eq 'block') {
		push @parts, { el => 'path', d => $line->(8, 16, 24, 16), fill => 0 };
		push @parts, { el => 'path', d => &rot_rect($deg, 5, 16, 5.5, 11), fill => 1 };
		push @parts, { el => 'path', d => &rot_rect($deg, 27, 16, 5.5, 11), fill => 1 };
	}
	else {
		push @parts, { el => 'path', d => $line->(7, 16, 25, 16), fill => 0 };
		push @parts, { el => 'path', d => $tri->(3, 16, 9, 11.5, 9, 20.5), fill => 1 };
		push @parts, { el => 'path', d => $tri->(29, 16, 23, 11.5, 23, 20.5), fill => 1 };
	}
	return \@parts;
}

my $CLASSIC_ARROW = 'M5 4 L5 26 L11 20.2 L14.6 28 L18.6 26.3 L15 18.6 L24 18.4 Z';
my $CLASSIC_HAND  = 'M10 16 V7.5 a2.6 2.6 0 0 1 5.2 0 V16 h1.2 V10.5 a2.4 2.4 0 0 1 4.8 0 v5.5 h1.2 v-2.5 a2.4 2.4 0 0 1 4.8 0 v8.5 c0 4.2-2.8 7.5-7 7.5 h-3.2 c-2.8 0-5.2-1.5-6.6-3.9 l-3.1-5.1 a2.4 2.4 0 0 1 4.1-2.4 z';
my $SLIM_ARROW    = 'M6 3 L6 26 L10.4 21.2 L13.2 28.6 L16.2 27.4 L13.4 19.6 L22.4 19.4 Z';
my $SLIM_HAND     = 'M11 16 V7.8 a1.8 1.8 0 0 1 3.6 0 V15 h1.2 V10.4 a1.8 1.8 0 0 1 3.6 0 v4.6 h1.2 v-1.8 a1.8 1.8 0 0 1 3.6 0 v8.4 c0 3.8-2.6 6.8-6.4 6.8 h-3 c-2.6 0-4.8-1.4-6.1-3.6 l-3-5 a1.9 1.9 0 0 1 3.3-1.9 z';
my $CYBER_ARROW   = 'M5 3 L5 27 L10.6 21.2 L13.4 29 L17.6 27.4 L14.8 19.6 L24 19.4 Z';
my $ROUND_ARROW   = 'M6 4 Q6 2 8 3.6 L23 17.4 Q24 18.4 22.5 18.8 L16.8 19 L19 25.6 Q19.7 27.2 18.2 27.6 L14.4 26 L12 20.6 L8.2 25.6 Q7.2 26.6 6.6 25.6 Z';
my $PIXEL_ARROW   = 'M5 3 H11 V9 H17 V15 H23 V21 H17 V15 H11 V27 H5 Z';
my $BIG_ARROW     = 'M4 3 L4 28 L10.5 22 L14.5 30 L19.5 28 L15.5 19.5 L25 19.3 Z';

# The classic library, worn by bold and used for any role a set does not
# override. Every set draws every one of these roles, so the cursor never has a
# hole in it when a set changes.
our %SHAPES = (
	'default' => [ { el => 'path', d => $CLASSIC_ARROW, fill => 1 } ],
	'pointer' => [ { el => 'path', d => $CLASSIC_HAND, fill => 1 } ],
	'text' => [ { el => 'path', d => 'M11 6 H21 M16 6 V26 M11 26 H21', fill => 0 } ],
	'vertical-text' => [ { el => 'path', d => 'M6 11 V21 M6 16 H26 M26 11 V21', fill => 0 } ],
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
	'wait' => [ { el => 'path', d => 'M9 4 H23 V8 L17.5 16 L23 24 V28 H9 V24 L14.5 16 L9 8 Z', fill => 1 } ],
	'progress' => [ { el => 'path', d => 'M9 4 H23 V8 L17.5 16 L23 24 V28 H9 V24 L14.5 16 L9 8 Z', fill => 1 } ],
	'crosshair' => [
		{ el => 'path', d => 'M16 4 V11 M16 21 V28 M4 16 H11 M21 16 H28', fill => 0 },
		{ el => 'circle', cx => 16, cy => 16, r => 1.6, fill => 1 },
	],
	'cell' => [
		{ el => 'path', d => 'M16 4 V11 M16 21 V28 M4 16 H11 M21 16 H28', fill => 0 },
		{ el => 'circle', cx => 16, cy => 16, r => 1.6, fill => 1 },
	],
);

# The silhouettes that make a set its own. A role named here replaces the
# classic part list; a role left out keeps the classic glyph in this set's
# paint. Resize roles are generated from the set's head style, not listed here.
our %SET_SHAPES = (
	bold => {},
	white => {
		'default' => [ { el => 'path', d => $SLIM_ARROW, fill => 1 } ],
		'pointer' => [ { el => 'path', d => $SLIM_HAND, fill => 1 } ],
		'text' => [ { el => 'path', d => 'M12 6 H20 M16 6 V26 M12 26 H20', fill => 0 } ],
		'wait' => [ { el => 'path', d => 'M10 5 L22 27 M22 5 L10 27 M10 5 H22 M10 27 H22', fill => 0 } ],
		'crosshair' => [ { el => 'path', d => 'M16 4 V11 M16 21 V28 M4 16 H11 M21 16 H28', fill => 0 } ],
	},
	outline => {
		'default' => [ { el => 'path', d => $CLASSIC_ARROW, fill => 0 } ],
		'pointer' => [ { el => 'path', d => $CLASSIC_HAND, fill => 0 } ],
		'text' => [ { el => 'path', d => 'M10 6 H13 M19 6 H22 M16 6 V26 M10 26 H13 M19 26 H22', fill => 0 } ],
		'vertical-text' => [ { el => 'path', d => 'M6 10 V13 M6 19 V22 M6 16 H26 M26 10 V13 M26 19 V22', fill => 0 } ],
		'wait' => [ { el => 'path', d => 'M10 5 H22 L16 16 L22 27 H10 L16 16 Z', fill => 0 } ],
		'crosshair' => [
			{ el => 'path', d => 'M16 4 V11 M16 21 V28 M4 16 H11 M21 16 H28', fill => 0 },
			{ el => 'circle', cx => 16, cy => 16, r => 4, fill => 0 },
		],
	},
	neon => {
		'default' => [
			{ el => 'path', d => $CYBER_ARROW, fill => 1 },
			{ el => 'path', d => 'M5 13 L8.5 16.5 L5 20 Z', paint => 'halo' },
		],
		'pointer' => [
			{ el => 'rect', x => 8, y => 13, width => 15, height => 14, rx => 2, fill => 1 },
			{ el => 'rect', x => 9, y => 5, width => 3.2, height => 10, rx => 0.8, fill => 1 },
			{ el => 'rect', x => 12.8, y => 4, width => 3.2, height => 11, rx => 0.8, fill => 1 },
			{ el => 'rect', x => 16.6, y => 5, width => 3.2, height => 10, rx => 0.8, fill => 1 },
			{ el => 'rect', x => 20.4, y => 7, width => 3.2, height => 8, rx => 0.8, fill => 1 },
			{ el => 'rect', x => 5, y => 17, width => 3.2, height => 7, rx => 0.8, fill => 1 },
			{ el => 'circle', cx => 16, cy => 27, r => 2.2, fill => 0 },
		],
		'text' => [
			{ el => 'path', d => 'M11 6 H21 M16 6 V26 M11 26 H21 M12 16 H20', fill => 0 },
			{ el => 'circle', cx => 16, cy => 16, r => 1.6, fill => 1 },
		],
		'wait' => [
			{ el => 'path', d => 'M16 5 A11 11 0 1 1 5 16', fill => 0 },
			{ el => 'path', d => 'M5 16 L2 12 H8 Z', fill => 1 },
			{ el => 'circle', cx => 16, cy => 16, r => 1.4, fill => 1 },
		],
		'crosshair' => [
			{ el => 'path', d => 'M16 4 V9 M16 23 V28 M4 16 H9 M23 16 H28', fill => 0 },
			{ el => 'circle', cx => 16, cy => 16, r => 5, fill => 0 },
			{ el => 'circle', cx => 16, cy => 16, r => 1.5, fill => 1 },
		],
	},
	pastel => {
		'default' => [ { el => 'path', d => $ROUND_ARROW, fill => 1 } ],
		'pointer' => [ { el => 'path', d => 'M9 16 V9 a3 3 0 0 1 6 0 v4 a2.8 2.8 0 0 1 5.6 0 v10 c0 3.8-2.5 6.8-6.4 6.8 h-2.6 c-2.7 0-5-1.4-6.3-3.7 l-2.6-4.7 a2.6 2.6 0 0 1 4.4-2.5 z', fill => 1 } ],
		'text' => [
			{ el => 'path', d => 'M11 6 H21 M16 6 V26 M11 26 H21', fill => 0 },
			{ el => 'circle', cx => 16, cy => 16, r => 1.5, fill => 1 },
		],
		'wait' => [
			{ el => 'circle', cx => 16, cy => 6, r => 2.2, fill => 1 },
			{ el => 'circle', cx => 26, cy => 16, r => 2.2, fill => 1 },
			{ el => 'circle', cx => 16, cy => 26, r => 2.2, fill => 1 },
			{ el => 'circle', cx => 6, cy => 16, r => 2.2, fill => 1 },
		],
	},
	mono => {
		'default' => [ { el => 'path', d => $PIXEL_ARROW, fill => 1 } ],
		'pointer' => [
			{ el => 'rect', x => 9, y => 14, width => 14, height => 13, rx => 1, fill => 1 },
			{ el => 'rect', x => 10, y => 7, width => 3, height => 9, rx => 0.5, fill => 1 },
			{ el => 'rect', x => 13.5, y => 5, width => 3, height => 11, rx => 0.5, fill => 1 },
			{ el => 'rect', x => 17, y => 6, width => 3, height => 10, rx => 0.5, fill => 1 },
			{ el => 'rect', x => 20.5, y => 8, width => 3, height => 8, rx => 0.5, fill => 1 },
			{ el => 'rect', x => 6, y => 17, width => 3, height => 7, rx => 0.5, fill => 1 },
		],
		'grab' => [
			{ el => 'rect', x => 7, y => 14, width => 19, height => 13, rx => 1, fill => 1 },
			{ el => 'rect', x => 8.5, y => 7, width => 3.4, height => 10, rx => 0.5, fill => 1 },
			{ el => 'rect', x => 12.5, y => 5, width => 3.4, height => 12, rx => 0.5, fill => 1 },
			{ el => 'rect', x => 16.5, y => 6, width => 3.4, height => 11, rx => 0.5, fill => 1 },
			{ el => 'rect', x => 20.5, y => 8, width => 3.4, height => 9, rx => 0.5, fill => 1 },
			{ el => 'rect', x => 3.8, y => 17, width => 3.6, height => 8, rx => 0.5, fill => 1 },
		],
		'grabbing' => [
			{ el => 'rect', x => 7, y => 13, width => 19, height => 14, rx => 1, fill => 1 },
			{ el => 'rect', x => 9, y => 10.5, width => 4, height => 5, rx => 0.5, fill => 1 },
			{ el => 'rect', x => 13.2, y => 9.5, width => 4, height => 5, rx => 0.5, fill => 1 },
			{ el => 'rect', x => 17.4, y => 10, width => 4, height => 5, rx => 0.5, fill => 1 },
			{ el => 'rect', x => 21, y => 11, width => 3.6, height => 4.6, rx => 0.5, fill => 1 },
		],
		'text' => [ { el => 'path', d => 'M11 5 H21 V8 H18 V24 H21 V27 H11 V24 H14 V8 H11 Z', fill => 1 } ],
		'wait' => [ { el => 'path', d => 'M9 4 H23 V8 H19 V12 H15 V16 H19 V20 H23 V24 H9 V20 H13 V16 H9 V12 H13 V8 H9 Z', fill => 1 } ],
		'crosshair' => [
			{ el => 'rect', x => 14, y => 4, width => 4, height => 24, rx => 0, fill => 1 },
			{ el => 'rect', x => 4, y => 14, width => 24, height => 4, rx => 0, fill => 1 },
		],
		'not-allowed' => [
			{ el => 'rect', x => 6, y => 6, width => 20, height => 20, rx => 1, fill => 0 },
			{ el => 'path', d => 'M9.5 22.5 L22.5 9.5', fill => 0 },
		],
		'no-drop' => [
			{ el => 'rect', x => 6, y => 6, width => 20, height => 20, rx => 1, fill => 0 },
			{ el => 'path', d => 'M9.5 22.5 L22.5 9.5', fill => 0 },
		],
	},
	contrast => {
		'default' => [ { el => 'path', d => $BIG_ARROW, fill => 1 } ],
		'text' => [ { el => 'path', d => 'M10 5 H22 M16 5 V27 M10 27 H22', fill => 0 } ],
		'wait' => [ { el => 'path', d => 'M8 3 H24 V8 L18 16 L24 24 V29 H8 V24 L14 16 L8 8 Z', fill => 1 } ],
		'crosshair' => [
			{ el => 'path', d => 'M16 3 V10 M16 22 V29 M3 16 H10 M22 16 H29', fill => 0 },
			{ el => 'circle', cx => 16, cy => 16, r => 2, fill => 1 },
		],
		'not-allowed' => [
			{ el => 'circle', cx => 16, cy => 16, r => 11, fill => 0 },
			{ el => 'path', d => 'M8.5 23.5 L23.5 8.5', fill => 0 },
		],
	},
);

# The full role map for a set: the classic library, the set's own silhouettes,
# then the resize roles generated from its head style.
sub shapes_for {
	my ($set) = @_;
	my $name = $set->{'name'};
	my %shapes = map { $_ => $SHAPES{$_} } keys %SHAPES;
	my $over = $SET_SHAPES{$name} || {};
	foreach my $role ( keys %{$over} ) { $shapes{$role} = $over->{$role}; }
	my $head = $set->{'head'} || 'solid';
	my $gap = $set->{'gap'} ? 1 : 0;
	foreach my $spec (
		[ 'col-resize', 0 ], [ 'ew-resize', 0 ],
		[ 'row-resize', 90 ], [ 'ns-resize', 90 ],
		[ 'n-resize', 90 ], [ 's-resize', 90 ],
		[ 'e-resize', 0 ], [ 'w-resize', 0 ],
		[ 'ne-resize', -45 ], [ 'sw-resize', -45 ], [ 'nesw-resize', -45 ],
		[ 'nw-resize', 45 ], [ 'se-resize', 45 ], [ 'nwse-resize', 45 ],
	) {
		$shapes{ $spec->[0] } = &resize_shapes($spec->[1], $head, $gap);
	}
	return \%shapes;
}

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
	my $edge = defined $set->{'edge'} ? $set->{'edge'} : 1.4;
	my $halo_extra = defined $set->{'halo_extra'} ? $set->{'halo_extra'} : 4.5;
	my $halo_weight = $weight + $halo_extra;
	my $shapes = &shapes_for($set);
	my %out;
	foreach my $role ( sort keys %{$shapes} ) {
		my @parts = @{ $shapes->{$role} };
		my $svg = qq{<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $SIZE $SIZE" width="$SIZE" height="$SIZE">};
		if ($set->{'glow'}) {
			$svg .= '<g opacity="0.35">';
			foreach my $part ( @parts ) {
				next if ($part->{'paint'} || '') eq 'halo';
				my $style = $part->{'fill'}
					? qq{fill="$fill" stroke="$fill" stroke-width="10" stroke-linejoin="round" stroke-linecap="round"}
					: qq{fill="none" stroke="$fill" stroke-width="11" stroke-linejoin="round" stroke-linecap="round"};
				$svg .= &part_svg($part, $style);
			}
			$svg .= '</g>';
		}
		$svg .= '<g>';
		foreach my $part ( @parts ) {
			next if ($part->{'paint'} || '') eq 'halo';
			my $style = $part->{'fill'}
				? qq{fill="$halo" stroke="$halo" stroke-width="$halo_weight" stroke-linejoin="round" stroke-linecap="round"}
				: qq{fill="none" stroke="$halo" stroke-width="$halo_weight" stroke-linejoin="round" stroke-linecap="round"};
			$svg .= &part_svg($part, $style);
		}
		foreach my $part ( @parts ) {
			if (($part->{'paint'} || '') eq 'halo') {
				$svg .= &part_svg($part, qq{fill="$halo" stroke="$halo" stroke-width="$edge" stroke-linejoin="round" stroke-linecap="round"});
				next;
			}
			my $style = $part->{'fill'}
				? qq{fill="$fill" stroke="$halo" stroke-width="$edge" stroke-linejoin="round" stroke-linecap="round"}
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
		# a zero-radius roundrectangle draws nothing in MVG; the pixel crosshair
		# and the block resize heads are square rectangles
		return 'rectangle ' . &num($part->{'x'}) . ',' . &num($part->{'y'}) . ' '
			. &num($x2) . ',' . &num($y2) if $rx <= 0;
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
	my $edge = defined $set->{'edge'} ? $set->{'edge'} : 1.4;
	my $halo_extra = defined $set->{'halo_extra'} ? $set->{'halo_extra'} : 4.5;
	my $halo_weight = $weight + $halo_extra;
	my $shapes = &shapes_for($set);
	my %out;
	foreach my $role ( sort keys %{$shapes} ) {
		my @parts = @{ $shapes->{$role} };
		my @draw;
		push @draw, 'stroke-linejoin round stroke-linecap round';
		if ($set->{'glow'}) {
			push @draw, "stroke-opacity 0.35 fill-opacity 0.35";
			foreach my $part ( @parts ) {
				next if ($part->{'paint'} || '') eq 'halo';
				my $style = $part->{'fill'}
					? "fill '$fill' stroke '$fill' stroke-width 10"
					: "fill none stroke '$fill' stroke-width 11";
				push @draw, $style, &mvg_primitive($part);
			}
			push @draw, "stroke-opacity 1 fill-opacity 1";
		}
		foreach my $part ( @parts ) {
			next if ($part->{'paint'} || '') eq 'halo';
			my $style = $part->{'fill'}
				? "fill '$halo' stroke '$halo' stroke-width $halo_weight"
				: "fill none stroke '$halo' stroke-width $halo_weight";
			push @draw, $style, &mvg_primitive($part);
		}
		foreach my $part ( @parts ) {
			if (($part->{'paint'} || '') eq 'halo') {
				push @draw, "fill '$halo' stroke '$halo' stroke-width $edge", &mvg_primitive($part);
				next;
			}
			my $style = $part->{'fill'}
				? "fill '$fill' stroke '$halo' stroke-width $edge"
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
	foreach my $role ( sort keys %{$svg} ) {
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
	print "wrote $name: " . scalar(keys %{$svg}) . " roles\n";
}
print "wrote $made files under $DIR/sets\n";
