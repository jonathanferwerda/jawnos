# tests-for: templates/apps/music/music.html.ep public/js/music.js
# covers:    The artists and albums shelves are the two halves of the Music
#            window. They used to be 50% content-box boxes, so their padding and
#            borders pushed the album shelf past the right edge once the window
#            was made slimmer; the two shelves are now pinned by left/right and
#            may only be resized in height.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# A content-box `width:50%` does not include the shelf's own 8px side padding
# and 1px borders (and the album's 5px left border), so two "halves" came to
# 50%+18px and 50%+22px. Measured in WebKitGTK against the real music.css, a
# 320px window put the album shelf's right edge at 338px: the album scrollbar,
# its right padding and the end of every album name sat outside the window. The
# artists shelf's own right edge was under the album shelf.
#
# Pinning the two sides (left+right, width auto) lets the browser subtract the
# padding and borders itself, so each shelf is exactly half at every window
# width, and the saved heights (which only ever tracked height) are untouched.
# The shelf resizable call offers only the south handle for the same reason: an
# east drag would pin a pixel width that goes off the side when the window is
# made slimmer again.

my $root = repo_root();
my $tpl  = read_file("$root/templates/apps/music/music.html.ep");
my $js   = js_source('public/js/music.js');

my ($artists) = $tpl =~ /^(.*id="music_artists".*)$/m;
my ($albums)  = $tpl =~ /^(.*id="music_albums".*)$/m;
ok($artists, 'the artists shelf is found');
ok($albums, 'the albums shelf is found');

# --- the desktop halves are pinned by their two sides -----------------------
like($artists, qr/else \{ %>right:50%;height:<%= \$shelf_height %>px;/,
	'the artists shelf fills from the left edge to the midpoint');
like($albums, qr/else \{ %>right:0px;height:<%= \$shelf_height %>px;.*?left:50%;/,
	'the albums shelf fills from the midpoint to the right edge');
unlike($artists, qr/width:50%/,
	'the artists shelf no longer asks for a content-box half');
unlike($albums, qr/width:50%/,
	'the albums shelf no longer asks for a content-box half');

# --- and the phone keeps its own full-width strips -------------------------
like($artists, qr/if \(\$phone_layout\) \{ %>width:100%;height:34px;/, 'the phone artists strip is full width');
like($albums, qr/if \(\$phone_layout\) \{ %>width:100%;height:34px;/, 'the phone albums strip is full width');

# --- the shelf drag is height only -----------------------------------------
my ($resizable) = $js =~ /(\$\('#music_artists, #music_albums'\)\.resizable\(\{.*?\n\t\}\);)/s;
ok($resizable, 'the shelf resizable call is found');
like($resizable, qr/handles: 's',/,
	'only the south handle is offered, so no pixel width can be pinned');
like($resizable, qr/\$\('#music_albums'\)\.height\(j\.size\.height\);/,
	'a vertical drag still keeps the two shelves the same height');
like($resizable, qr/var newTop = \(\$\('#music_albums'\)\.height\(\) \+ 100\) \+ 'px';/,
	'and still moves the track list under them');

done_testing();
