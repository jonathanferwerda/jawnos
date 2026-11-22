# tests-for: public/js/music.js templates/apps/video.html.ep templates/apps/video/
# covers:    The player bar's seek, clock and title are drawn by one interval created by templates/apps/video.html.ep.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# The player bar's seek, clock and title are drawn by one interval created by
# templates/apps/video.html.ep. Once that interval is cleared nothing restarts
# it: the music window's script only runs when the window is first appended, and
# a search has updated the lists in place since v0.1.xxx instead of re-rendering
# the window.
#
# searchMusic used to clear the interval at the top of its success handler, so
# after any artist/album pick (the ordinary way to choose a show) the next track
# played with the seek stuck at 0 - onloadedmetadata writes the one zero - and
# the previous title still on screen, while #interface's own clock, restarted by
# the element's 'playing' event, ran on correctly.
#
# Pin the three parts of the fix so a future cleanup cannot quietly restore the
# clear: music.js must not clear the tick, it must re-arm it on every open and
# search, and the include must publish the tick for that.

my $music = read_file("$FindBin::Bin/../public/js/music.js");
my $video = template_source('apps/video');

# The seek preview asks the server for one frame at a position. It used
# v.src and an unguarded bucket, so an unloaded video (or one whose duration
# was still NaN) requested /&thumb=ya&position=NaN - the home page, once per
# hover. Read the loaded URL and refuse anything that is not a file_open
# address or a finite position.
my $video_script = read_file("$FindBin::Bin/../templates/apps/video/script.html.ep");
like($video_script, qr/var previewSrc = v\.currentSrc \|\| v\.src/,
	'the seek preview reads the loaded URL, not only the src attribute');
like($video_script, qr/!isFinite\(bucket\)/,
	'and never asks for a NaN position');
like($video_script, qr/previewSrc\.indexOf\('\/file_open\?'\)/,
	'and only builds a preview for a file_open URL');
unlike($video_script, qr/attr\('src', v\.src \+ '&thumb=ya/,
	'so an unloaded video cannot request /&thumb=ya&position=NaN');

# 1. nothing in music.js clears the bar tick any more
unlike($music, qr/clearInterval\(\s*vidControls\[\s*'video_video_interval'\s*\]\s*\)/,
	'music.js no longer clears the player bar tick');

# 2. searchMusic leaves it alone
my ($search_success) = $music =~ /function searchMusic\(data\)\s*\{(.*?)\n\}/s;
ok(defined $search_success, 'searchMusic is found');
unlike($search_success // '', qr/video_video_interval/,
	'the search success handler does not touch the bar tick');

# 3. musicInit re-arms it, and the helper reaches the include's hook
like($music, qr/function musicBarIntervalArm\(\)\s*\{\s*\n\s*if \(typeof window\.jawnosMusicBarInterval == 'function'\) \{ window\.jawnosMusicBarInterval\(\); \}/,
	'the arm helper calls the include hook');
my ($init) = $music =~ /async function musicInit\(method\)\s*\{(.*?)\n\}/s;
like($init // '', qr/\bmusicBarIntervalArm\(\)/,
	'musicInit arms the bar tick on every open and search');

# 4. the include publishes the interval for music only
like($video, qr/<% if \(\$source eq 'music'\) \{ %>\s*\n\s*(?:\/\/[^\n]*\n\s*)*window\.jawnosMusicBarInterval = <%= \$miss %>VideoInterval;/,
	'the video include publishes its bar interval for music');

# 5. a missing element (a list swap or a refresh) does not kill the tick while
#    the music window is still there
like($video, qr/if \(!el\) \{\s*\n\s*if \(\$\('#music'\)\.length == 0\) \{\s*\n\s*clearInterval/,
	'a missing player element only stops the tick when the window is gone');

# 6. the seek is written to the input the element actually wears, so a refresh
#    that hands the window a new miss cannot leave the bar frozen
like($video, qr/var bar_miss = \$\('#<%= \$id %>'\)\.attr\('miss'\) \|\| '<%= \$miss %>';/,
	'the tick resolves the seek input from the element current miss');

# 7. the bar title falls back to the queue manifest, so a playing row that is
#    not mounted does not blank the title on every tick
like($video_script, qr/typeof musicCurrentEntry == 'function'[\s\S]*?display_track \|\| played_entry\.song/,
	'the tick falls back to the manifest when the playing row is not mounted');

done_testing();
