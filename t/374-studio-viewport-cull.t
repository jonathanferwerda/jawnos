# tests-for: public/js/manager/studio/02_canvas.js
# covers:    Studio's per-tick painting only visits what the viewer can show. A
#            minimized window, a hidden tab or Configure's sheet stops the paint
#            (the ruler included) while the transport keeps ticking; otherwise
#            the ruler is painted whole and only the lanes and mixer strips that
#            intersect their scroller are redrawn. The lane boxes are cached so
#            the 25 ms path never measures one per lane, and a scroll or resize
#            repaints the lanes that just scrolled into view.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root   = repo_root();
my $canvas = read_file("$root/public/js/manager/studio/02_canvas.js");

sub body {
	my ($name) = @_;
	my ($fn) = $canvas =~ /function \Q$name\E\(.*?\) \{(.*?)\n\}/s;
	return defined $fn ? $fn : '';
}

# --- the window gate ---------------------------------------------------------
my $window = body('studioWindowVisible');
ok(length $window, 'there is one gate for the window itself');
like($window, qr/\$\('#studio'\)/, 'the gate asks the Studio element');
like($window, qr/studio\.is\(':visible'\)/, 'a hidden Studio is not painted');
like($window, qr/studio\.closest\('\.wind'\)/, 'the gate climbs to the window frame');
like($window, qr/wind\.is\(':visible'\)/, 'a minimized frame (windows.js hides it) is not painted');

my $viewer = body('studioViewerVisible');
ok(length $viewer, 'there is one gate for the lanes');
like($viewer, qr/if \(document\.hidden\) \{ return false; \}/, 'a hidden tab stops the paint');
like($viewer, qr/if \(!studioWindowVisible\(\)\) \{ return false; \}/, 'the window gate runs first');
like($viewer, qr/\$\('#studio_config'\)\.is\(':visible'\)/,
	'Configure, the full-window sheet, covers the viewer');
like($viewer, qr/\$\('#studio_viewer'\)\.is\(':visible'\)/,
	'the viewer must itself be on screen (it is display:none under the sheet)');

# --- the draw loop is bounded ------------------------------------------------
my $draw = body('studioDrawTracks');
ok(length $draw, 'the tracks painter is found');
like($draw, qr/\A\n\tif \(!studioViewerVisible\(\)\) \{ return; \}/,
	'the paint returns before touching a canvas when the viewer is hidden');
like($draw, qr/studioDrawRuler\(\);/, 'the ruler is still painted');

my $ruler_at = index($draw, 'studioDrawRuler()');
my $loop_at  = index($draw, 'studioPaintViewport()');
ok($ruler_at != -1 && $loop_at != -1 && $ruler_at < $loop_at,
	'the ruler is painted before the lane loop reads the viewport');

like($draw, qr/var view = studioPaintViewport\(\);/, 'one viewport snapshot feeds the loop');
like($draw, qr/if \(studioLaneVisible\(view, ch\)\) \{ studioDrawChannel\(ch\); \}/,
	'a lane is painted only when the viewer can show it');
like($draw, qr/if \(studioStripVisible\(view, ch\)\) \{ studioDrawMetre\(ch\); \}/,
	'a strip\'s LEDs and metre are painted only when the mixer can show it');

my @channel_calls = $draw =~ /studioDrawChannel\(/g;
is(scalar(@channel_calls), 1, 'the draw loop calls studioDrawChannel exactly once');
my @metre_calls = $draw =~ /studioDrawMetre\(/g;
is(scalar(@metre_calls), 1, 'the draw loop calls studioDrawMetre exactly once');
unlike($draw, qr/\n\t\tstudioDrawChannel\(ch\);/, 'no unguarded channel call is left in the loop');
unlike($draw, qr/getBoundingClientRect/, 'the 25 ms paint measures no rectangle');

# --- the lane boxes are cached, not re-measured ------------------------------
like($canvas, qr/var studioLaneRectsCache = null;/, 'the lane boxes are cached');
like($canvas, qr/var studioLaneRectsKey = '';/, 'the cache carries the layout it describes');
my $lanes = body('studioLaneRects');
ok(length $lanes, 'there is one lane-measuring function');
like($lanes, qr/getElementsByClassName\('studio_track'\)/, 'it reads the lane rows');
like($lanes, qr/key = rows\.length.*viewer\.clientHeight.*viewer\.scrollHeight/,
	'its key moves when a lane or the viewer changes size');
like($lanes, qr/if \(studioLaneRectsCache && studioLaneRectsKey === key\) \{ return studioLaneRectsCache; \}/,
	'a warm cache is returned without measuring');
like($lanes, qr/getBoundingClientRect\(\)/, 'a cold cache measures the boxes once');
like($lanes, qr/rect\.top - box\.top \+ viewer\.scrollTop/, 'a lane is kept in the viewer\'s scroll coordinates');
like($lanes, qr/overscan: tallest \|\| 1/, 'one lane height is the overscan');
like($lanes, qr/getAttribute\('data-channel'\)/, 'each box names its channel');

my $lane_visible = body('studioLaneVisible');
ok(length $lane_visible, 'there is a lane visibility helper');
like($lane_visible, qr/if \(!view \|\| !view\.lanes\) \{ return false; \}/,
	'with no view nothing is visible');
like($lane_visible, qr/lanes\[i\]\.top \+ lanes\[i\]\.height \+ over > view\.scrollTop/,
	'a lane whose foot is below the viewport top is partly visible, so it is painted');
like($lane_visible, qr/lanes\[i\]\.top - over < view\.scrollTop \+ view\.height/,
	'a lane above the viewport top is skipped');
unlike($lane_visible, qr/getBoundingClientRect/, 'the per-lane test measures nothing');

# --- strips follow the same rule --------------------------------------------
my $strips = body('studioStripRects');
ok(length $strips, 'the mixer strips get the same cached box');
like($strips, qr/getElementsByClassName\('channel'\)/, 'it reads the mixer strips');
like($strips, qr/scrollWidth.*scrollHeight/, 'the strip cache follows the mixer\'s scroll extent');
like($strips, qr/channel_\(\[0-9\]\+\)/, 'a strip\'s box names its channel');

my $strip_visible = body('studioStripVisible');
ok(length $strip_visible, 'there is a strip visibility helper');
like($strip_visible, qr/if \(!view \|\| !view\.strips\) \{ return false; \}/,
	'a hidden mixer has no visible strip');
like($strip_visible, qr/strips\[i\]\.top \+ strips\[i\]\.height \+ over > view\.stripTop/,
	'a strip below the mixer fold is skipped');
like($strip_visible, qr/strips\[i\]\.left \+ strips\[i\]\.width \+ over > view\.stripLeft/,
	'a strip scrolled out sideways is skipped');

my $paint_view = body('studioPaintViewport');
ok(length $paint_view, 'one snapshot describes the paint');
like($paint_view, qr/var viewer = document\.getElementById\('studio_viewer'\)/, 'the snapshot reads the viewer');
like($paint_view, qr/if \(!viewer\) \{ return null; \}/, 'a missing viewer has no paint');
like($paint_view, qr/\$\('#studio_mixer_strips'\)|document\.getElementById\('studio_mixer_strips'\)/,
	'the snapshot includes the mixer strips');
like($paint_view, qr/lanes: studioLaneRects\(viewer\)/, 'the lane cache is read once per paint');
like($paint_view, qr/scrollTop: viewer\.scrollTop/, 'the viewer scroll position is read once per paint');

# --- a scroll or resize repaints what arrived -------------------------------
like($canvas, qr/var studioRedrawQueued = false;/, 'a redraw is queued at most once');
my $queue = body('studioQueueRedraw');
ok(length $queue, 'there is one redraw queue');
like($queue, qr/if \(studioRedrawQueued \|\| !studioViewerVisible\(\)\) \{ return; \}/,
	'nothing is queued while the window is hidden');
like($queue, qr/window\.requestAnimationFrame\(run\)/, 'the redraw runs on the next frame');
like($queue, qr/studioDrawTracks\(\);/, 'the queued frame repaints the visible lanes');
my $run_at = index($queue, 'var run = function () {');
my $guard_at = index($queue, '!studioViewerVisible()', $run_at);
ok($run_at != -1 && $guard_at > $run_at, 'the frame re-checks visibility before painting');

like($canvas, qr/document\.addEventListener\('scroll',[\s\S]{0,400}?\{ capture: true, passive: true \}\);/,
	'a capture-phase scroll listener sees the viewer and the strips');
like($canvas, qr/target\.id !== 'studio_viewer' && target\.id !== 'studio_mixer_strips'/,
	'only the scrollers a paint depends on queue a redraw');
like($canvas, qr/target\.id !== 'studio_mixer_strips'\)\) \{ return; \}\s*if \(!studioViewerVisible\(\)\) \{ return; \}/,
	'a hidden window queues no scroll redraw');
like($canvas, qr/window\.addEventListener\('resize', function \(\) \{\s*if \(!studioViewerVisible\(\)\) \{ return; \}\s*studioQueueRedraw\(\);/,
	'a resize queues the same redraw, unless the window is hidden');

# --- the painters themselves are untouched ----------------------------------
like($canvas, qr/function studioDrawChannel\(ch\)/, 'the lane painter still exists');
like($canvas, qr/function studioDrawMetre\(ch\)/, 'the strip painter still exists');
like($canvas, qr/co\.meterAnalyser\.getFloatTimeDomainData\(co\.meterData\)/,
	'painting a visible strip still samples its analyser');
like($canvas, qr/function studioFitCanvas\(canvas\)/, 'the canvas fit is unchanged');

done_testing();
