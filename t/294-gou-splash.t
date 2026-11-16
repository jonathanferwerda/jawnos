# tests-for: scripts/gou_splash.pl scripts/gou_provision.pl perl/help/topics_apps.pl
# covers:    the Go Ultra's boot face: one full-screen frame instead of a tiled
#            icon, the mark and its halo, the step and the progress bar, and the
#            unit that starts it before the kiosk.

use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file);

my $root = "$Bin/..";
my $splash = "$root/scripts/gou_splash.pl";

ok(-f $splash, 'scripts/gou_splash.pl is in the tree');
ok(-x $splash, 'it is executable');
is(system($^X, '-c', $splash) >> 8, 0, 'it compiles');

# --help is the only mode that must work without X or ImageMagick.
my $help = `$^X "$splash" --help 2>&1`;
like($help, qr/--status TEXT/, 'the face names its status option');
like($help, qr/--percent N/, 'and its progress option');

# The dry run shows the whole ImageMagick argv without running it. HOME is a
# temp dir so the tree's own logo is the one chosen, not a laptop install's.
my $home = tempdir(CLEANUP => 1);
my $plan = `HOME="$home" $^X "$splash" --once --dry-run --status 'Checking the card' --percent 35 --width 854 --height 480 2>&1`;
like($plan, qr/^size 854x480$/m, 'the frame is the root size, not the icon size');
like($plan, qr/^phase 35 Checking the card$/m, 'the phase is the one asked for');
like($plan, qr/xc:#000000/, 'the face is on black');
like($plan, qr/-blur 0x30/, 'the mark carries a blurred halo');
like($plan, qr/-fill #c9ced8/, 'the line is light grey');
like($plan, qr/-annotate \+0\+118 Checking the card/, 'the step is under the mark');
like($plan, qr/roundrectangle 177,398 676,408 5,5/, 'the progress track spans the face');
like($plan, qr/roundrectangle 177,398 351,408 5,5/, 'and the fill stops at the percentage');
my $marks = () = $plan =~ /jawnos\.png/g;
is($marks, 2, 'the mark is composited twice: its halo and the face');

# A real compose proves the geometry scales and the file is an image. The test
# skips on a machine without ImageMagick rather than failing the suite for it.
my $identify = '';
foreach my $dir ( split /:/, ($ENV{'PATH'} || '') ) {
	next unless length $dir;
	if (-x "$dir/identify") { $identify = "$dir/identify"; last }
}
SKIP: {
	skip 'ImageMagick identify is not installed', 3 unless length $identify;
	my $out = "$home/gou-splash.png";
	is(system($^X, $splash, '--once', '--out', $out, '--status', 'Starting the house',
		'--percent', 55, '--width', 200, '--height', 120) >> 8, 0, 'the frame is composed');
	my $size = `"$identify" -format '%wx%h' "$out" 2>/dev/null`;
	is($size, '200x120', 'the face takes the size it was given');
	ok(-s $out, 'and leaves a non-empty image');
}

# The unit runs the script, not display(1), and the rotation is up first.
my $provision = read_file("$root/scripts/gou_provision.pl");
like($provision, qr{ExecStart=-?/usr/bin/perl /home/jawn/jawnos/scripts/gou_splash\.pl --watch},
	'the splash unit runs the compositor');
like($provision, qr/After=gou-x\.service gou-rotate\.service/,
	'after X and the rotation that presents it');
unlike($provision, qr{display -window root /home/jawn/\.local/share/jawnos/desktop/icons/jawnos\.png},
	'the tiling display(1) call is gone');
like($provision, qr{for my \$name \(qw\(gou_first_boot\.pl gou_recovery\.pl gou_splash\.pl gou_first_run\.py\)\)},
	'the flash copies the splash script onto the board');
like($provision, qr/'splash-script'/, 'and reports it as filled in');

# The user-facing account of the flashed board explains the card hold.
my $help_topics = read_file("$root/perl/help/topics_apps.pl");
like($help_topics, qr/holds that automatic sync until its card is mounted/,
	'the Controllers help says a controller waits for the card');

done_testing();
