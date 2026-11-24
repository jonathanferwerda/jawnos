# tests-for: templates/apps/video/script.html.ep
# covers:    The seek preview thumb follows the pointer in a fullscreen. The
#            preview is fixed to the viewport, where the fullscreen player
#            fills the screen; clamping it to the window's frame - still behind
#            the player at its old size - left the thumb over the window's own
#            seek bar instead of the fullscreen one. The restored full-screen
#            dress counts as the same box.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $script = read_file("$root/templates/apps/video/script.html.ep");

my ($hover) = $script =~ /(vidOn\('hover mousemove mouseover touchmove'.*?\n\t\t\t\}\);)/s;
ok($hover, 'the seek bar hover handler is where the preview is placed');

like($hover, qr/var fullscreen = document\.fullscreenElement \|\| document\.webkitFullscreenElement;/,
	'the placement asks whether the player is fullscreen');
like($hover, qr/if \(fullscreen && fullscreen\.contains\(this\)\)/,
	'and follows it only when the bar is inside the fullscreen element');
like($hover, qr/fullscreen && fullscreen\.contains\(this\)[\s\S]*?var full = fullscreen\.getBoundingClientRect\(\);[\s\S]*?wl = full\.left;[\s\S]*?wr = full\.right;/,
	'the clamp spans the fullscreen element, not the window behind it');
like($hover, qr/else \{[\s\S]*?numeral\(\$\(this\)\.closest\('\.wind'\)\.css\('left'\)\)\.value\(\);[\s\S]*?numeral\(\$\(this\)\.closest\('\.wind'\)\.css\('right'\)\)\.value\(\)/,
	'a windowed player still clamps to its window frame');

# A reload restores the full screen as the music_fullscreen class instead of the
# top layer, so the preview must follow that element when there is no
# document.fullscreenElement.
like($hover, qr/if \(!fullscreen\) \{ fullscreen = \$\('#<%= \$id %>'\)\.closest\('\.music_fullscreen'\)\[0\] \|\| null; \}/,
	'a restored full screen is the same box as the top-layer one');

done_testing();
