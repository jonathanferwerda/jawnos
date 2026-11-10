# tests-for: public/js/manager/timelineprinter.js
# covers:    the timeline's occurrence mark is the printer family's mark - the
#            appointment colour in a disc with a thin ink edge - with the
#            pseudonym icon's own ink scaled and rounded to fill that disc.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $src  = read_file("$root/public/js/manager/timelineprinter.js");

# --- the mark matches the other printers ------------------------------------
# calendar, clockface and continent all fill the occurrence with the app's
# colour and outline it in ink; the timeline was the one that inverted the two.
like($src, qr/jawnosTextureFillCircle\(ctx, x, rowY, dotRadius, colour, darkTheme\)/,
	'the occurrence is filled with the appointment colour');
like($src, qr/ctx\.strokeStyle = ink;\s*\n\s*ctx\.lineWidth = dotRing;\s*\n\s*ctx\.beginPath\(\);\s*\n\s*ctx\.arc\(x, rowY, dotRadius/,
	'and edged in ink, the family grammar');
unlike($src, qr/ctx\.fillStyle = ink;/,
	'no data mark is filled with ink any more');

# --- the ghost wears the same mark, faded -----------------------------------
like($src, qr/jawnosTextureFillCircle\(ctx, gx, rowY, dotRadius, colour, darkTheme\)/,
	'a ghost is the same colour disc');
like($src, qr/ctx\.strokeStyle = ink;\s*\n\s*ctx\.lineWidth = dotRing;\s*\n\s*ctx\.beginPath\(\);\s*\n\s*ctx\.arc\(gx, rowY, dotRadius/,
	'with the same ink edge');

# --- the icon's ink fills and rounds into the disc ---------------------------
# Icon sets place the glyph differently (a plated square, or the bare outline
# glyph) and all of them leave a transparent margin. The printer measures the
# opaque pixels and scales those to the disc, clipping the square's corners to
# a circle that meets the ink edge - so no appointment colour shows round it.
my ($radius) = $src =~ /var dotRadius = (\d+);/;
my ($ring)   = $src =~ /var dotRing = (\d+);/;
my ($icon)   = $src =~ /var dotIcon = (\d+);/;
my ($round)  = $src =~ /var dotIconClip = (\d+);/;
ok(defined $radius && defined $ring && defined $icon && defined $round,
	'the mark sizes and the icon\'s round clip were read');
cmp_ok($radius, '>=', 19, 'the disc is big enough for a legible icon');
cmp_ok($ring, '<=', 2, "the edge is the other printers' thin ink line");
cmp_ok($icon, '>=', 34, 'the icon is given a large box to fill');
# the ink edge's inner radius is dotRadius - dotRing/2; the clip meets it so
# the scaled ink reaches the edge instead of leaving a margin of app colour
cmp_ok($round, '==', $radius - $ring / 2, 'the round clip meets the ink edge');
cmp_ok($round, '>=', 14, 'the round clip still fills the disc');

# the icon's opaque ink is measured once it loads, and the draw crops to it
like($src, qr/icon\.ink = iconInk\(icon\.img\)/, 'the icon is measured for its opaque ink');
like($src, qr/getImageData\(0, 0, probe, probe\)/, 'the measurement reads the icon\'s pixels');
like($src, qr/ctx\.drawImage\(icon\.img, icon\.ink\.x, icon\.ink\.y, icon\.ink\.w, icon\.ink\.h,/,
	'the drawn ink is cropped to those bounds');
# the cropped ink is scaled to the clip's diameter and clipped to its circle
like($src, qr/var box = roundRadius \* 2;.*?var scale = box \/ Math\.max\(icon\.ink\.w, icon\.ink\.h\);/s,
	'the ink is scaled to the round circle');
like($src, qr/ctx\.arc\(x \+ \(size \/ 2\), y \+ \(size \/ 2\), roundRadius, 0, \(Math\.PI \* 2\)\);\s*\n\s*ctx\.clip\(\);/,
	'the ink is clipped to the round radius before it is drawn');
like($src, qr/ctx\.restore\(\);\s*\n\s*\/\/ the pseudonym's own glyph.*?pseudoGenerator\(appts,l\['type'\], x - \(dotIcon \/ 2\).*?dotIconClip\)/s,
	'the icon is drawn on top of the disc, rounded');

# --- the band is untouched --------------------------------------------------
like($src, qr/jawnosTextureStroke\(ctx, colour, darkTheme, bandHeight\)/,
	'the span still wears the appointment colour as a textured band');

# --- and the file parses ----------------------------------------------------
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
if ($node && -x $node) {
	my $out = `$node --check "$root/public/js/manager/timelineprinter.js" 2>&1`;
	my $status = $?;
	diag($out) if $status != 0;
	is($status, 0, 'node --check accepts the timeline printer');
}

done_testing();
