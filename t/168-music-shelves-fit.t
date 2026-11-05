# tests-for: templates/apps/music/music.html.ep public/js/music.js public/css/music.css
# covers:    The artists and albums shelves are the two halves of the Music
#            window. They used to be 50% content-box boxes, so their padding and
#            borders pushed the album shelf past the right edge once the window
#            was made slimmer; a narrow window now stacks them full width, and
#            the saved band is never read back from a stacked shelf.

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
my $css  = read_file("$root/public/css/music.css");

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

# --- a narrow window stacks the shelves ------------------------------------
like($tpl, qr/--music-shelf-height:<%= \$shelf_height %>px;/,
    'the window carries the shelf band as a custom property');
like($css, qr/\@container \(max-width: 440px\) \{/,
    'a narrow Music container has its own draw');
like($css, qr/#music:not\(\[phone_layout="yes"\]\) #music_artists,\s*\n\s*#music:not\(\[phone_layout="yes"\]\) #music_albums \{[^}]*left: 0 !important;[^}]*right: 0 !important;[^}]*height: var\(--music-stack-shelf\) !important;/s,
    'both shelves take the full width and the split height');
like($css, qr/--music-stack-shelf: max\(90px, calc\(\(var\(--music-shelf-height, 125px\) - 6px\) \/ 2\)\);/,
    'the band is split with a floor so neither shelf is a single row');
like($css, qr/#music:not\(\[phone_layout="yes"\]\) #music_albums \{\s*\n\s*top: calc\(100px \+ var\(--music-stack-shelf\) \+ 6px\) !important;/,
    'the albums sit under the artists');
like($css, qr/#music:not\(\[phone_layout="yes"\]\) #music_files \{[^}]*top: calc\(100px \+ var\(--music-stack-shelf\) \+ 6px \+ var\(--music-stack-shelf\)\) !important;[^}]*height: auto !important;/s,
    'the list starts under both shelves and lets its foot decide its height');
like($css, qr/#music:not\(\[phone_layout="yes"\]\) #music_artists \.ui-resizable-handle,\s*\n\s*#music:not\(\[phone_layout="yes"\]\) #music_albums \.ui-resizable-handle \{ display: none; \}/,
    'the shelf handles are put away while stacked');

# --- and the stacked boxes are never what the band remembers --------------
like($js, qr/function musicShelfBand\(\) \{/,
    'the band has its own reader');
like($js, qr/getComputedStyle\(el\)\.getPropertyValue\('--music-shelf-height'\)/,
    'it reads the measured band, not a stacked box');
like($js, qr/music_albums: \{ bottom: \$\('#music_albums'\)\.css\('top'\), height: musicShelfBand\(\) \}/,
    'the player cache saves the band');
like($js, qr/music_albums: \{ bottom: \$\('#music_albums'\)\.css\('top'\), height: band, scrollTop:/,
    'the search save records the band');

done_testing();
