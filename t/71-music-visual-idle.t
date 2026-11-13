# tests-for: public/js/music.js
# covers:    The Music player's visualiser is a canvas fed to the muted video the person actually sees.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# The Music player's visualiser is a canvas fed to the muted video the person
# actually sees. It used to draw at 60 frames a second whether or not anything
# was playing, capture the canvas at a fixed 30 a second whether or not anything
# had changed, keep drawing a full 1920px bitmap, and spin the frame loop when
# the player had no box to paint into. On this machine that was the difference
# between ~25-33% of a core and ~7% with the player idle (measured in
# WebKitGTK: see .shots/webkit_capture_bench.py and .shots/webkit_cpu_probe.py).

my $root = repo_root();
my $js = read_file("$root/public/js/music.js");

# --- it draws only when there is something to draw for ----------------------
like($js, qr/function musicVisualFrame\(ts\) \{[\s\S]{0,900}?if \(document\.hidden\) \{ musicVisualPark\(\); return; \}/,
	'a hidden page parks the drawing instead of painting it');
like($js, qr/function musicVisualWait\(ms\)/, 'there is a way to look again later');
unlike($js, qr/there is nothing to paint, but the loop stays on for when it has one/,
	'the no-box case no longer keeps asking for frames it cannot draw');
like($js, qr/musicVisualWait\(400\)/, 'a player with no box waits instead of spinning');
like($js, qr/musicVisualWait\(1000\)/, 'a video track waits instead of spinning');

# --- it draws no more often than it needs to -------------------------------
like($js, qr/var budget = playing \? 1000 \/ 30 : 1000 \/ 8;/,
	'thirty frames a second while playing, eight while still');
like($js, qr/function musicVisualPlaying\(parts\)/, 'the player itself says whether it is making sound');
unlike($js, qr/captureStream\(30\)\);\n\t\}/, 'the stream is not opened at a fixed 30 a second');
like($js, qr/musicVisual\.stream = parts\.canvas\.captureStream\(0\)/,
	'the stream is opened with on-demand frames');

# --- the bitmap follows the box, not the screen ----------------------------
like($js, qr/if \(long \* scale > 1280\) \{ scale = 1280 \/ long; \}/,
	'the big drawing is capped at 1280 on its long edge');

# --- a frame is pushed only when one was drawn -----------------------------
like($js, qr/function musicVisualPush\(\)/, 'a drawn frame is handed to the feed');
like($js, qr/musicVisualPush\(\);\n\tmusicVisual\.raf = requestAnimationFrame/, 'the push follows the drawing, not a timer');

# --- and it comes back on its own ------------------------------------------
like($js, qr/\$\(document\)\.on\('play pause playing waiting ended seeked', 'video, audio'/,
	'a player that starts or stops brings the drawing back');
like($js, qr/\$\(document\)\.on\('visibilitychange', function\(\) \{\n\tif \(!musicVisual\.mode/,
	'so does a page that comes back');
like($js, qr/musicVisual\.stream\.getTracks\(\)\.forEach\(function\(t\) \{ t\.stop\(\); \}\)/,
	'a replaced canvas closes the stream that fed it');

# --- an interrupted audio context comes back without a reload ----------------
like($js, qr/function musicContextRecover\(\) \{[\s\S]{0,300}?tree\.sound\.paused/,
	'a playing track recovers an interrupted audio context');
like($js, qr/\$\(window\)\.on\('focus pageshow'/, 'and coming back to the window does it at once');
like($js, qr/setInterval\(musicContextRecover, 5000\)/, 'on a slow watch, never on a reload');

done_testing();
