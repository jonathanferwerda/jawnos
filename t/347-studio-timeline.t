# tests-for: public/js/manager/studio/01_transport.js public/js/manager/studio/02_canvas.js public/js/manager/studio/03_editing.js public/js/manager/studio/04_knobs.js public/js/manager/studio/05_inputs.js public/js/manager/studio/06_controls.js templates/studio/markup.html.ep templates/studio/style.html.ep t/347-studio-timeline.t
# covers:    The Studio timeline: the ruler over the take canvases (bars/beats
#            or seconds, click to seek while stopped or playing), the clip
#            context menu (split, cut, copy, paste), cross-track drag and drop,
#            and the per-track colour the canvas paints its clips with.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root   = repo_root();
my $markup = read_file("$root/templates/studio/markup.html.ep");
my $style  = read_file("$root/templates/studio/style.html.ep");
my $canvas = read_file("$root/public/js/manager/studio/02_canvas.js");
my $edit   = read_file("$root/public/js/manager/studio/03_editing.js");
my $transport = read_file("$root/public/js/manager/studio/01_transport.js");
my $knobs     = read_file("$root/public/js/manager/studio/04_knobs.js");
my $inputs    = read_file("$root/public/js/manager/studio/05_inputs.js");
my $ctrl      = read_file("$root/public/js/manager/studio/06_controls.js");

# --- the ruler's markup -----------------------------------------------------
like($markup, qr/<div id="studio_ruler" class="studio_ruler">/, 'the tracks panel carries a ruler');
like($markup, qr/<span class="studio_ruler_pad"><\/span>/, 'the ruler has a pad over the track panels');
like($markup, qr/<canvas id="studio_ruler_canvas" class="studio_ruler_canvas"/, 'the ruler is a canvas');
like($markup, qr/Click the ruler to move the playhead/, 'the ruler says what a click does');
like($markup, qr/while stopped or playing/, 'the ruler says when a click may move the playhead');
my $ruler_at  = index($markup, 'id="studio_ruler_canvas"');
my $viewer_at = index($markup, 'id="studio_viewer"');
ok($ruler_at != -1 && $viewer_at != -1 && $ruler_at < $viewer_at,
	'the ruler sits above the take canvases');

# --- its style --------------------------------------------------------------
like($style, qr/\.studio_ruler\s*\{[\s\S]*?display:\s*flex/, 'the ruler is a flex row');
like($style, qr/\.studio_ruler_pad\s*\{[\s\S]*?flex:\s*0 0 150px/, 'the pad is a track panel wide');
like($style, qr/\.studio_ruler_canvas\s*\{[\s\S]*?flex:\s*1 1 auto/, 'the ruler canvas takes the lane width');
like($style, qr/\.studio_menu\s*\{[\s\S]*?position:\s*fixed[\s\S]*?z-index:\s*60000/,
	'the clip menu is a fixed card above the window');
like($style, qr/\.studio_menu_row\[disabled\]\s*\{[\s\S]*?opacity:/, 'a disabled menu row reads disabled');

# --- drawing the ruler ------------------------------------------------------
like($canvas, qr/function studioDrawRuler\(\)/, 'the ruler has one draw function');
like($canvas, qr/studioFitCanvas\(canvas\)/, 'the ruler canvas is fitted to its element');
like($canvas, qr/mixer\['time'\]\['duration'\][\s\S]{0,40}\?\s*duration\s*:\s*60/,
	'an empty song still has a 60 second scale');
like($canvas, qr/function studioDrawTracks\(\)[\s\S]{0,200}studioDrawRuler\(\)/,
	'every tracks repaint repaints the ruler');
like($canvas, qr/getComputedStyle\(canvas\)/, 'the ruler takes its colours from the theme');
for my $name (qw(--ink --line --accent)) {
	like($canvas, qr/\Q$name\E/, "the ruler reads $name");
}

my ($ruler) = $canvas =~ /function studioDrawRuler\(\) \{(.*?)\n\}/s;
ok(defined $ruler, 'the ruler painter is found');
$ruler = '' unless defined $ruler;
like($ruler, qr/mixer\['time'\]\['display'\] == 'beats'/,
	'the ruler mirrors the transport display switch');
like($ruler, qr/studioBarSeconds\(\)/, 'bar mode uses the song tempo');
like($ruler, qr/studioBeatSeconds\(\)/, 'bar mode draws beats');
like($ruler, qr/var ladder = \[/, 'seconds mode steps a scale instead of labelling every tick');
like($ruler, qr/ctx\.fillText\(/, 'the ruler labels its ticks');
like($ruler, qr/var position = \(mixer\['time'\] && mixer\['time'\]\['position'\]\) \|\| 0;/,
	'the playhead comes from the transport position');
like($ruler, qr/ctx\.strokeStyle = accent;/, 'the playhead marker takes the theme accent');

# --- clicking the ruler seeks -----------------------------------------------
like($canvas, qr/\$\(document\)\.on\('click', '#studio_ruler_canvas'/,
	'the ruler click is delegated, so a rebuilt window keeps it');
like($canvas, qr/studioSeek\(\(\(e\.clientX - rect\.left\) \/ rect\.width\) \* studioTimelineDuration\(\)\)/,
	'a ruler x becomes a time');

my ($seek) = $canvas =~ /function studioSeek\(t\) \{(.*?)\n\}/s;
ok(defined $seek, 'the seek function is found');
$seek = '' unless defined $seek;
like($seek, qr/mixer\['time'\]\['position'\] = t;/, 'a seek sets the transport position');
like($seek, qr/t = Math\.min\(t, duration\)/, 'a seek clamps to the end of the song');
like($seek, qr/studioTimeDisplay\(\)[\s\S]{0,60}studioDrawTracks\(\)/,
	'a seek updates the display and the lanes');
like($seek, qr/studioClockStart\(t\)/,
	'a running transport re-anchors instead of overwriting the seek');
unlike($seek, qr/status'\]\s*=[^=]/, 'a seek never changes the transport status');

# --- seeking is refused while a take records --------------------------------
my ($can_seek) = $transport =~ /function studioCanSeek\(\) \{(.*?)\n\}/s;
ok(defined $can_seek, 'one guard decides who may seek');
$can_seek = '' unless defined $can_seek;
like($can_seek, qr/status == 'stop' \|\| status == 'play'/, 'only stop and play may seek');
like($seek, qr/if \(!studioCanSeek\(\)\) \{ return false; \}/,
	'the ruler refuses a seek while recording');
unlike($seek, qr/status == 'record'/, 'the seek path no longer lets recording through');
like($ctrl, qr/on\('click', '#studio_prev, #studio_next'[\s\S]{0,160}!studioCanSeek\(\)/,
	'Previous and Next refuse while recording');
like($knobs, qr/#studio_jog_wheel'[\s\S]{0,240}!studioCanSeek\(\)/,
	'the wheel on the jog refuses while recording');
like($inputs, qr/#studio_jog_wheel'[\s\S]{0,240}!studioCanSeek\(\)/,
	'the jog drag refuses while recording');

# --- the track colour in the canvas -----------------------------------------
my ($channel) = $canvas =~ /function studioDrawChannel\(ch\) \{(.*?)\n\}/s;
ok(defined $channel, 'the channel painter is found');
$channel = '' unless defined $channel;
like($channel, qr/typeof studioTrackColour === 'function'\) \? studioTrackColour\(ch\) : '#145abe'/,
	'the clip colour is the track colour, with the old blue as fallback');
like($channel, qr/typeof studioColourRgba === 'function'\) \? studioColourRgba\(colour, 0\.5\)/,
	'the clip fill takes that colour at half alpha');
like($channel, qr/studioColourRgba\(colour, 0\.16\)/,
	'a looping take ghosts in the same colour at 0.16');
like($channel, qr/ctx\.strokeStyle = selected \? colour : '#04325f';/,
	'the selected clip is outlined in its track colour');
like($channel, qr/'rgba\(220,0,0,0\.55\)'/, 'a recording clip stays red');
like($channel, qr/'rgba\(120,60,190,0\.5\)'/, 'a video clip stays purple');
like($channel, qr/studioTakeDrag\.over == ch/, 'the lane a cross-track drag would land in is tinted');
unlike($channel, qr/recAnalyser/, 'the lane no longer paints the live input across the timeline');
like($channel, qr/take\.waveform && take\.waveform\.length/,
	'the lane paints the recorded take\'s own peaks');

# --- the clip context menu ---------------------------------------------------
like($edit, qr/\$\(document\)\.on\('contextmenu', '\.track'/, 'a right-press on a take opens a menu');
like($edit, qr/var hit = studioCanvasHit\(this, e\.clientX\);/,
	'the menu target is the take under the pointer');
like($edit, qr/if \(!hit\) \{ return; \}[\s\S]{0,60}e\.preventDefault\(\)/,
	'only a take swallows the browser context menu');
like($edit, qr/function studioClipMenu\(hit, px, py\)/, 'there is one menu builder');
for my $command (qw(split cut copy paste)) {
	like($edit, qr/studioClipMenuRow\(menu, '\Q$command\E'/, "the menu offers $command");
}
like($edit, qr/studioClipMenuRow\(menu, 'paste'[\s\S]{0,80}!studioClipboard/,
	'paste is disabled while the clipboard is empty');
like($edit, qr/var left = Math\.min\(px, \$\(window\)\.width\(\) - menu\.outerWidth\(\) - margin\);/,
	'the menu is clamped to the window');

# --- what the rows do -------------------------------------------------------
like($edit, qr/function studioClipSnapshot\(take\)/, 'a copy keeps a snapshot');
my ($snap) = $edit =~ /function studioClipSnapshot\(take\) \{(.*?)\n\}/s;
ok(defined $snap, 'the snapshot function is found');
$snap = '' unless defined $snap;
for my $field (qw(src uuid data offset duration encoding loop)) {
	like($snap, qr/\b\Q$field\E:/, "the snapshot carries $field");
}
like($edit, qr/studioSplitTake\(hit\.ch, hit\.take, hit\.t\)/, 'Split cuts at the clicked time');
like($edit, qr/studioClipboard = studioClipSnapshot\(hit\.take\);\s*\n\s*studioRemoveTake\(hit\.ch, hit\.take\);/,
	'Cut copies the clip and then removes it');
like($edit, qr/studioPasteTake\(hit\.ch, hit\.t\)/, 'Paste places the snapshot on the clicked track');

my ($paste) = $edit =~ /function studioPasteTake\(ch, t\) \{(.*?)\n\}/s;
ok(defined $paste, 'the paste builder is found');
$paste = '' unless defined $paste;
like($paste, qr/if \(!studioClipboard\) \{ return null; \}/, 'paste needs a clipboard');
like($paste, qr/document\.createElement\('video'\)/, 'a pasted clip gets a hidden media element');
like($paste, qr/className = 'studio_video'/, 'the element is a studio video');
like($paste, qr/startTime: Math\.max\(0, t\)/, 'the pasted clip starts at the clicked time');
like($paste, qr/offset: clip\.offset \|\| 0/, 'it keeps the snapshot in-point');
like($paste, qr/duration: clip\.duration \|\| 0/, 'it keeps the snapshot length');
like($paste, qr/if \(!clip\.uuid\) \{ pasted\.data = clip\.data; \}/,
	'an unsaved clip carries its blob so the copy uploads too');
like($paste, qr/loop: false/, 'a looping clip pastes as an ordinary clip');
like($paste, qr/m\.media\.out\.push\(pasted\)/, 'the clip joins the track');
like($paste, qr/studioReindexTakes\(ch\)/, 'the track is reindexed after the paste');
like($paste, qr/studioSaver\(\)/, 'the paste saves the song');
like($paste, qr/studioTakesChanged\(\)/, 'the paste re-schedules playback');

# --- the menu's dismissal ---------------------------------------------------
like($edit, qr/on\('pointerdown', function \(e\) \{[\s\S]{0,120}studio_menu/,
	'a press elsewhere closes the menu');
like($edit, qr/on\('keydown', function \(e\) \{[\s\S]{0,120}'Escape'/,
	'Escape closes the menu');
like($edit, qr/addEventListener\('scroll'/, 'a scroll closes the menu');

# --- cross-track drag and drop ----------------------------------------------
like($edit, qr/document\.elementFromPoint\(e\.originalEvent\.clientX/,
	'the drag watches the lane under the pointer');
like($edit, qr/under\.closest\('\.track'\)/, 'the hovered lane is a track canvas');
like($edit, qr/function studioMoveTake\(take, from, to\)/, 'a take can move between tracks');
my ($move) = $edit =~ /function studioMoveTake\(take, from, to\) \{(.*?)\n\}/s;
ok(defined $move, 'the move function is found');
$move = '' unless defined $move;
like($move, qr/media\.out\.splice\(index, 1\)/, 'the take leaves its old track');
like($move, qr/target\.out\.push\(take\)/, 'the same take joins the new track, not a copy');
like($move, qr/studioReindexTakes\(from\)[\s\S]{0,40}studioReindexTakes\(to\)/,
	'both tracks are reindexed');
like($move, qr/status == 'recording'\) \{ return false; \}/, 'a recording take never moves');
like($edit, qr/if \(d\.mode == 'move' && to && to != from\) \{ studioMoveTake\(d\.take, from, to\); \}/,
	'the drop moves only a moved take');
like($edit, qr/if \(e\.button !== 0\) \{ return; \}/,
	'a right-press does not start a drag or clear the selection');

# --- a close releases the transport and the takes ---------------------------
like($ctrl, qr/function studioReleaseTimers\(\)/, 'one place clears the transport timers');
my ($timers) = $ctrl =~ /function studioReleaseTimers\(\) \{(.*?)\n\}/s;
ok(defined $timers, 'the timer release is found');
$timers = '' unless defined $timers;
like($timers, qr/clearInterval\(mixer\['time'\]\['interval'\]\)/, 'the 25 ms transport tick is cleared');
like($timers, qr/clearInterval\(v\['interval'\]\)/, 'and every button blink timer');
like($ctrl, qr/function studioReleaseTakes\(\)/, 'takes are released in one place too');
my ($takes) = $ctrl =~ /function studioReleaseTakes\(\) \{(.*?)\n\}/s;
ok(defined $takes, 'the take release is found');
$takes = '' unless defined $takes;
like($takes, qr/URL\.revokeObjectURL\(take\.src\)/, 'each take object URL is revoked');
like($takes, qr/URL\.revokeObjectURL\(take\.track\.src\)/, 'and the element\'s URL, which an import never copies onto the take');
like($takes, qr/take\.data = null/, 'and its Blob dropped');
like($takes, qr/!take\.track\.paused.*?take\.track\.pause\(\)/, 'a take still marked playing is paused first');
like($ctrl, qr/function studioTeardown\(\)/, 'one close hook ties them together');
like($ctrl, qr/jawnosAppTeardown\['studio'\] = studioTeardown/, 'the shell registry learns about it');
my $release_at = index($knobs, 'studioTeardown');
my $mixer_at = index($knobs, 'mixer = {');
ok($release_at != -1 && $mixer_at != -1 && $release_at < $mixer_at,
	'studioInit releases the previous mixer before replacing it');

# --- the editing that was already there -------------------------------------
like($edit, qr/on\('dblclick', '\.track'/, 'double-click still splits');
like($edit, qr/if \(e\.key == 'Delete' \|\| e\.key == 'Backspace'\)/, 'Delete still removes the selected take');
like($edit, qr/studioSelectedTake = \{ ch: hit\.ch, take: hit\.take \};/, 'a press still selects the take');

done_testing();
