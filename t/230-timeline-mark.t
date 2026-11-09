# tests-for: public/js/manager/timelineprinter.js
# covers:    the timeline's occurrence mark is the printer family's mark - the
#            appointment colour in a disc with a thin ink edge - and the
#            pseudonym's plate is small enough to leave that colour showing.

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

# --- the plate fits inside the disc -----------------------------------------
# The icon sets are 512x512 rounded-square plates, so a plate wider than the
# disc covers its colour and cuts the edge into a sliver. Keep the plate inside
# the colour disc (dotRing is the half of the ink edge that sits inside it).
my ($radius) = $src =~ /var dotRadius = (\d+);/;
my ($ring)   = $src =~ /var dotRing = (\d+);/;
my ($icon)   = $src =~ /var dotIcon = (\d+);/;
ok(defined $radius && defined $ring && defined $icon, 'the three mark sizes were read');
is($radius, 14, 'the disc keeps its radius');
cmp_ok($ring, '<=', 2, "the edge is the other printers' thin ink line");
cmp_ok($icon, '<=', 2 * ($radius - $ring),
	'the pseudonym plate fits inside the colour disc, leaving a rim');
cmp_ok($icon, '>=', 16, 'and is still large enough to read');

# the plate must land after the disc it sits on
like($src, qr/ctx\.restore\(\);\s*\n\s*\/\/ the pseudonym's own plate.*?pseudoGenerator\(appts,l\['type'\], x - \(dotIcon \/ 2\)/s,
	'the plate is drawn on top of the disc');

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
