# tests-for: public/js/manager/studio/02_canvas.js public/js/manager/studio/03_editing.js public/js/manager/studio/06_controls.js public/js/universal/07_hints_long_press_multiselect.js t/354-studio-timeline-zoom.t
# covers:    The Studio timeline's visible window: a zoom factor and a start
#            second that every time/pixel mapping reads (lanes, ruler, hit
#            tests, the loop menu and the ruler click), the ctrl+wheel and
#            pinch that narrow it about the pointer, and the page-wide wheel
#            handler that keeps the WebUI itself from zooming. The strip's ten
#            LEDs are re-asserted here because the same painter file owns them.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root   = repo_root();
my $canvas = read_file("$root/public/js/manager/studio/02_canvas.js");
my $edit   = read_file("$root/public/js/manager/studio/03_editing.js");
my $ctrl   = read_file("$root/public/js/manager/studio/06_controls.js");
my $univ   = read_file("$root/public/js/universal/07_hints_long_press_multiselect.js");

# --- the window's state ------------------------------------------------------
like($canvas, qr/var studioTimelineZoom = 1;/, 'the timeline opens unzoomed');
like($canvas, qr/var studioTimelineStart = 0;/, 'the window opens at the song start');
like($canvas, qr/var STUDIO_TIMELINE_ZOOM_MAX = 32;/, 'the zoom tops out at 32');
like($canvas, qr/function studioTimelineView\(\)/, 'one function describes the window');

my ($view) = $canvas =~ /function studioTimelineView\(\) \{(.*?)\n\}/s;
ok(defined $view, 'the view function is found');
$view = '' unless defined $view;
like($view, qr/var duration = studioTimelineDuration\(\);/, 'the view is measured against the song');
like($view, qr/var span = duration \/ zoom;/, 'the visible span is the song over the zoom');
like($view, qr/start: start, span: span, end: start \+ span, duration: duration/,
	'the view exposes start, span, end and duration');
like($view, qr/Math\.max\(0, Math\.min\(studioTimelineStart \|\| 0, duration - span\)\)/,
	'the start is clamped to 0..duration-span');
like($view, qr/if \(zoom > STUDIO_TIMELINE_ZOOM_MAX\)/, 'the zoom is clamped to the top');

my ($set_start) = $canvas =~ /function studioTimelineSetStart\(seconds\) \{(.*?)\n\}/s;
ok(defined $set_start, 'the start setter is found');
$set_start = '' unless defined $set_start;
like($set_start, qr/studioTimelineStart = Math\.max\(0, Math\.min\(seconds \|\| 0, view\.duration - view\.span\)\)/,
	'a moved window is clamped the same way');

my ($reset) = $canvas =~ /function studioTimelineReset\(\) \{(.*?)\n\}/s;
ok(defined $reset, 'there is a view reset');
$reset = '' unless defined $reset;
like($reset, qr/studioTimelineZoom = 1;/, 'the reset clears the zoom');
like($reset, qr/studioTimelineStart = 0;/, 'the reset clears the start');

my ($load) = $ctrl =~ /function studioLoad\(uuid\) \{(.*?)\n\}/s;
ok(defined $load, 'the song loader is found');
$load = '' unless defined $load;
like($load, qr/studioTimelineReset\(\);/, 'loading a song resets the window');

# --- mapping a pixel to a time and back --------------------------------------
like($canvas, qr/function studioTimelineTimeAt\(canvas, clientX\)/, 'a lane x maps to a song time');
my ($time_at) = $canvas =~ /function studioTimelineTimeAt\(canvas, clientX\) \{(.*?)\n\}/s;
ok(defined $time_at, 'the time mapping is found');
$time_at = '' unless defined $time_at;
like($time_at, qr/var rect = studioTimelineWindowRect\(canvas\);/, 'the time mapping reads the window rect');
like($time_at, qr/studioTimelineDuration\(\);/, 'the song\'s own scale maps the point');

like($canvas, qr/function studioTimelineXAt\(canvas, seconds\)/, 'a song time maps back to a lane x');
my ($x_at) = $canvas =~ /function studioTimelineXAt\(canvas, seconds\) \{(.*?)\n\}/s;
ok(defined $x_at, 'the inverse mapping is found');
$x_at = '' unless defined $x_at;
like($x_at, qr/\(\(seconds \|\| 0\) - view\.start\)/, 'the inverse measures from the window start');
like($x_at, qr/\/ view\.span\) \* rect\.width/, 'the inverse scales by the window span');

like($canvas, qr/function studioTimelineWidth\(canvas, seconds\)/, 'a duration has its own lane width');
my ($width_at) = $canvas =~ /function studioTimelineWidth\(canvas, seconds\) \{(.*?)\n\}/s;
ok(defined $width_at, 'the width mapping is found');
$width_at = '' unless defined $width_at;
like($width_at, qr/\(\(seconds \|\| 0\) \/ view\.span\) \* rect\.width/, 'a width is a length over the span');

# --- the lanes draw through the view ----------------------------------------
my ($channel) = $canvas =~ /function studioDrawChannel\(ch\) \{(.*?)\n\}/s;
ok(defined $channel, 'the lane painter is found');
$channel = '' unless defined $channel;
like($channel, qr/region_x = studioTimelineXAt\(canvas, region\.start\);/, 'the loop region starts on the view');
like($channel, qr/region_w = Math\.max\(2, studioTimelineWidth\(canvas, region\.end - region\.start\)\);/,
	'the loop region is as wide as the view says');
like($channel, qr/var x = studioTimelineXAt\(canvas, take\.startTime\);/, 'a clip starts where the view puts it');
like($channel, qr/var tw = Math\.max\(2, studioTimelineWidth\(canvas, take\.duration \|\| 0\)\);/,
	'a clip is as wide as the view says');
like($channel, qr/for \(var gx = x \+ tw; gx < w; gx \+= tw\)/,
	'a looping take ghosts across the visible window');
like($channel, qr/var b0 = Math\.max\(0, Math\.floor\(-x\)\);/, 'the waveform only paints peaks the window can show');
like($channel, qr/var fx = studioTimelineXAt\(canvas, from\);/, 'crossfade shading starts on the view');
like($channel, qr/var px = studioTimelineXAt\(canvas, mixer\['time'\]\['position'\]\);/, 'the lane playhead is on the view');
like($channel, qr/if \(px >= 0 && px <= w\)/, 'the lane playhead only shows when the window holds it');
unlike($channel, qr/\/ duration\) \* w/, 'no lane mapping ignores the view');

# --- the ruler reads the window, with absolute labels -----------------------
my ($ruler) = $canvas =~ /function studioDrawRuler\(\) \{(.*?)\n\}/s;
ok(defined $ruler, 'the ruler painter is found');
$ruler = '' unless defined $ruler;
like($ruler, qr/var view = studioTimelineView\(\);/, 'the ruler reads the view');
like($ruler, qr/Math\.ceil\(view\.start \/ minor\)/, 'second ticks begin at the window start');
like($ruler, qr/mi \* minor <= view\.end \+ 1e-9/, 'second ticks stop at the window end');
like($ruler, qr/studioTimelineXAt\(canvas, mi \* minor\)/, 'second ticks use the view mapping');
like($ruler, qr/Math\.ceil\(view\.start \/ beat\)/, 'beat ticks begin at the window start');
like($ruler, qr/bi \* beat <= view\.end \+ 1e-9/, 'beat ticks stop at the window end');
like($ruler, qr/Math\.ceil\(view\.start \/ bar\)/, 'bar lines begin at the window start');
like($ruler, qr/ni \* bar <= view\.end \+ 1e-9/, 'bar lines stop at the window end');
like($ruler, qr/studioTimelineXAt\(canvas, ni \* bar\)/, 'bar lines use the view mapping');
like($ruler, qr/String\(ni\)/, 'the bar labels stay absolute, not window-relative');
like($ruler, qr/studioTimelineXAt\(canvas, position\)/, 'the ruler playhead is on the view');
like($ruler, qr/if \(px >= 0 && px <= w\)/, 'the ruler playhead only shows when the window holds it');
unlike($ruler, qr/\/ duration\) \* w/, 'no ruler mapping ignores the view');

# --- the ruler click maps through the window --------------------------------
like($canvas, qr/studioTimelineWindowRect\(this\)/, 'the ruler click maps through the visible window');
my ($window_rect) = $canvas =~ /function studioTimelineWindowRect\(canvas\) \{(.*?)\n\}/s;
ok(defined $window_rect, 'the window rect is found');
$window_rect = '' unless defined $window_rect;
like($window_rect, qr/rect\.width \* \(view\.duration \/ view\.span\)/, 'the window rect is the whole song wide');
like($window_rect, qr/view\.start \/ view\.span/, 'the window rect is shifted to the window start');
like($canvas, qr/studioSeek\(\(\(e\.clientX - rect\.left\) \/ rect\.width\) \* studioTimelineDuration\(\)\)/,
	'a ruler click still becomes a song time and a seek');

# --- a seek is the whole song's, not the window's ---------------------------
my ($seek) = $canvas =~ /function studioSeek\(t\) \{(.*?)\n\}/s;
ok(defined $seek, 'the seek function is found');
$seek = '' unless defined $seek;
like($seek, qr/t = Math\.min\(t, duration\)/, 'a seek still clamps to the whole song');
unlike($seek, qr/view\.span/, 'a seek never clamps to the visible window');

# --- hit testing, moves and trims read the same view ------------------------
my ($hit) = $edit =~ /function studioCanvasHit\(canvas, clientX\) \{(.*?)\n\}/s;
ok(defined $hit, 'the take hit test is found');
$hit = '' unless defined $hit;
like($hit, qr/var view = studioTimelineView\(\);/, 'the hit test reads the view');
like($hit, qr/var t = studioTimelineTimeAt\(canvas, clientX\);/, 'the pointer is a time in the window');
like($hit, qr/var tpp = view\.span \/ rect\.width;/, 'a pixel step is the window span');
like($hit, qr/studioTimelineXAt\(canvas, take\.startTime\)/, 'the trim-start edge is on the view');
like($hit, qr/studioTimelineXAt\(canvas, end\)/, 'the trim-end edge is on the view');
unlike($hit, qr/\* duration/, 'the hit test no longer maps by the whole song');

my ($canvas_time) = $edit =~ /function studioCanvasTime\(canvas, clientX\) \{(.*?)\n\}/s;
ok(defined $canvas_time, 'the loop-menu time is found');
$canvas_time = '' unless defined $canvas_time;
like($canvas_time, qr/var rect = studioTimelineWindowRect\(canvas\);/, 'the loop-menu time maps through the window');
like($canvas_time, qr/return Math\.max\(0, Math\.min\(duration, t\)\);/, 'the loop-menu time clamps to the whole song');

like($edit, qr/var dt = \(e\.originalEvent\.clientX - d\.x\) \* d\.tpp;/,
	'a cross-track drag uses the hit test\'s window scale');
like($edit, qr/studioSplitTake\(hit\.ch, hit\.take, hit\.t\)/,
	'a split lands on the window-mapped click time');
like($edit, qr/studioPasteTake\(hit\.ch, hit\.t\)/,
	'a paste lands on the window-mapped click time');

# --- ctrl+wheel and pinch zoom about the pointer ----------------------------
like($canvas, qr/function studioTimelineWheel\(event\)/, 'there is one wheel-to-zoom entry point');
my ($wheel) = $canvas =~ /function studioTimelineWheel\(event\) \{(.*?)\n\}/s;
ok(defined $wheel, 'the wheel handler is found');
$wheel = '' unless defined $wheel;
like($wheel, qr/Math\.exp\(-event\.deltaY \* 0\.0015\)/, 'the wheel delta is an exponential zoom step');
like($wheel, qr/studioTimelineZoomAt\(canvas, event\.clientX, Math\.exp\(-event\.deltaY \* 0\.0015\)\)/,
	'the pointer is the zoom anchor');
like($wheel, qr/event\.preventDefault\(\);/, 'a zoomed wheel cancels the browser gesture');

my ($zoom_at) = $canvas =~ /function studioTimelineZoomAt\(canvas, clientX, factor\) \{(.*?)\n\}/s;
ok(defined $zoom_at, 'the anchored zoom is found');
$zoom_at = '' unless defined $zoom_at;
like($zoom_at, qr/var time = studioTimelineTimeAt\(canvas, clientX\);/, 'the anchor is the time under the pointer');
like($zoom_at, qr/Math\.max\(1, Math\.min\(STUDIO_TIMELINE_ZOOM_MAX, view\.zoom \* factor\)\)/,
	'the zoom stays inside 1..32');
like($zoom_at, qr/var frac = rect\.width \? \(clientX - rect\.left\) \/ rect\.width : 0\.5;/,
	'the anchor keeps its fraction of the window');
like($zoom_at, qr/studioTimelineSetStart\(time - \(frac \* \(view\.duration \/ studioTimelineZoom\)\)\)/,
	'the anchored time stays under the pointer');
like($zoom_at, qr/studioDrawTracks\(\);/, 'a zoom repaints the lanes');

# --- the wheel listener's surface and guards --------------------------------
my ($listener) = $canvas =~ /document\.addEventListener\('wheel', function \(event\) \{\n(.*?)\n\}, \{ capture: true, passive: false \}\);/s;
ok(defined $listener, 'the timeline binds one native capture-phase wheel listener');
$listener = '' unless defined $listener;
like($listener, qr/if \(!event\.ctrlKey && !event\.metaKey\) \{ return; \}/,
	'a plain wheel is left to scroll the panel');
like($listener, qr/if \(studioTimelineGestureActive\) \{ return; \}/,
	'a pinch that arrives as a gesture is not applied twice by the wheel');
like($listener, qr/studioTimelineWheel\(event\)/, 'a ctrl wheel zooms the timeline');
ok(index($listener, 'if (!event.ctrlKey && !event.metaKey) { return; }') < index($listener, 'studioTimelineWheel(event)'),
	'the plain-wheel guard runs before any zoom');

like($canvas, qr/target\.closest\('#studio_ruler_canvas'\)/, 'the ruler is a zoom surface');
like($canvas, qr/target\.closest\('#studio_viewer'\)/, 'the lanes are a zoom surface');

my ($gesture) = $canvas =~ /document\.addEventListener\('gesturechange', function \(event\) \{\n(.*?)\n\}, \{ capture: true, passive: false \}\);/s;
ok(defined $gesture, 'a pinch has a gesture handler');
$gesture = '' unless defined $gesture;
like($gesture, qr/var scale = event\.scale \|\| 1;/, 'the gesture reads its scale');
like($gesture, qr/var factor = scale \/ \(studioTimelineGestureScale \|\| 1\);/,
	'only the change since the last gesture event is applied');
like($gesture, qr/studioTimelineZoomAt\(canvas, event\.clientX, factor\)/,
	'the gesture keeps its centre fixed');
like($canvas, qr/document\.addEventListener\('gesturestart'/, 'a pinch opens a gesture');
like($canvas, qr/document\.addEventListener\('gestureend'/, 'a pinch closes a gesture');

# --- the WebUI never zooms itself on ctrl+wheel -----------------------------
my ($global) = $univ =~ /document\.addEventListener\('wheel', function \(event\) \{\n(.*?)\n\}, \{ passive: false \}\);/s;
ok(defined $global, 'the universal script owns one non-passive wheel handler');
$global = '' unless defined $global;
like($global, qr/if \(!event\.ctrlKey && !event\.metaKey\) \{ return; \}/, 'a plain wheel is untouched');
like($global, qr/event\.preventDefault\(\);/, 'a ctrl wheel never zooms the whole page');
unlike($global, qr/stopPropagation/, 'the event still travels to Studio and Marker');
unlike($global, qr/preventDefault\(\);[\s\S]*return false/, 'the handler does not swallow the event');

# --- the strip's LEDs are the same painter's work ---------------------------
my ($metre) = $canvas =~ /function studioDrawMetre\(ch\) \{(.*?)\n\}/s;
ok(defined $metre, 'the metre painter is found');
$metre = '' unless defined $metre;
like($metre, qr/co\.meterAnalyser\.getFloatTimeDomainData\(co\.meterData\)/, 'the strip meter follows the analyser');
like($metre, qr/var lit = Math\.round\(mlevel \* 10\);/, 'ten LEDs follow the level');
like($metre, qr/\.studio_strip_led/, 'the painter lights the strip LEDs');
like($metre, qr/attr\('data-led'\)/, 'each LED knows its place on the ladder');
like($metre, qr/toggleClass\('lit', index < lit\)/, 'an LED lights below the level and goes out above it');

done_testing();
