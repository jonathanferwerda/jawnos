use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

# A music card draws a video only when its cached media info has a duration and
# a height, and its thumbnail is the poster that /file_open makes or serves.
#
# Two defects hid the posters for whole shows (Friends, Scrubs, Star Trek, That
# '70s Show):
#
#   1. file_media_information assigned the undef ffprobe format and then wrote
#      chapters into it, autovivifying { chapters => undef }. That is a truthy
#      hash, so Music.pl cached it as an answer and re-probed never again - the
#      card saw no duration and no height and fell back to the generic icon.
#   2. the sealed thumb path always seeked to 00:00:00.010, which is a fade or a
#      black frame on most encodes, so a generated poster could be blank.
#
# The rule is now: never cache a probe that answered nothing, treat an entry
# without the facts as a miss (so the old entries heal on the next render), and
# take a poster at a position that is actually past the fade.

my $video = read_file("$FindBin::Bin/../Music.pl");
my $manager = read_file("$FindBin::Bin/../Manager.pl");
my $subs = read_file("$FindBin::Bin/../subroutines.pl");

# --- the poster position -----------------------------------------------------
is(subs::thumbnail_seek_position(5), '00:00:01.000', 'a short clip takes a frame at one second');
is(subs::thumbnail_seek_position(30), '00:00:12.000', 'a half-minute clip takes a frame at twelve seconds');
is(subs::thumbnail_seek_position(90), '00:01:01.000', 'a short episode takes a frame at a minute');
is(subs::thumbnail_seek_position(1300), '00:02:00.020', 'an episode takes a frame at two minutes');
is(subs::thumbnail_seek_position(undef), '00:00:01.000', 'an unknown duration still avoids the fade-in');
is(subs::thumbnail_seek_position('-4'), '00:00:01.000', 'a nonsense duration is treated as unknown');

# --- a failed probe is not an answer -----------------------------------------
my $missing = &subs::file_media_information({ type => 'video', f => '/nonexistent/thumb-test.mp4' });
ok(!$missing->{'info'} || !scalar keys %{$missing->{'info'}},
	'a video ffprobe cannot read yields no info hash to cache');

ok(subs::music_info_usable({ duration => '1300.9', height => 360 }), 'a duration and height is usable');
ok(subs::music_info_usable({ width => 640 }), 'a width alone is usable');
ok(subs::music_info_usable({ tags => { title => 'x' } }), 'non-empty tags are usable');
is(subs::music_info_usable({ chapters => undef, tags => {} }), 0, 'the old failed-probe shape is not usable');
is(subs::music_info_usable({ duration => '' }), 0, 'an empty duration is not usable');
is(subs::music_info_usable(undef), 0, 'no entry is not usable');
is(subs::music_info_usable('x'), 0, 'a scalar entry is not usable');

# --- Music.pl asks the rule and heals the old entries -------------------------
like($video, qr/if \(&subs::music_info_usable\(\$file_information->\{\$filename\}\)\)/,
	'the cached info is reused only when it is usable');
like($video, qr/delete \$file_information->\{\$filename\};/,
	'a failed probe is removed from the cache so the next render retries');

# --- no thumbnail path still takes the fade-in frame -------------------------
unlike($manager, qr/-ss 00:00:00\.010/,
	'Manager.pl no longer takes every poster at ten milliseconds');
unlike($subs, qr/-ss 00:00:00\.010/,
	'subroutines.pl no longer takes a generated video poster at ten milliseconds');
like($manager, qr/&subs::thumbnail_seek_position\(/,
	'Manager.pl takes the poster at a frame past the fade');

done_testing();
