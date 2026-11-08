# tests-for: public/js/manager/keyboard/03_editor_switcher.js templates/apps/video/markup.html.ep perl/help/topics_apps.pl
# covers:    Escape leaves a fullscreen picture in the Music window, even though
#           the window's global key handler calls preventDefault for every key,
#           and the More tools toggle sits beside Repeat rather than after the
#           title.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);

my $root = "$FindBin::Bin/..";
my $keys = read_file("$root/public/js/manager/keyboard/03_editor_switcher.js");
my $markup = read_file("$root/templates/apps/video/markup.html.ep");
my $help = read_file("$root/perl/help/topics_apps.pl");

# The music block calls preventDefault before it looks at the key, so the
# browser's own Escape handling never runs. It must leave fullscreen itself,
# with the prefixed fallback the player already uses.
like($keys, qr/keyCode == 27/, 'the music key handler sees Escape');
like($keys, qr/document\.exitFullscreen \? document\.exitFullscreen\(\)/,
	'and leaves fullscreen through the standard API');
like($keys, qr/webkitExitFullscreen/, 'with the prefixed fallback');
my $escape_at = index($keys, 'keyCode == 27');
my $f_at = index($keys, 'keyCode == 70');
ok($escape_at >= 0 && $f_at > $escape_at,
	'the Escape branch sits with the player shortcuts');

# The music bar's order is transport, theatre, shuffle, repeat, tools, title.
# The title takes the row's slack, so the toggle must come before it to sit
# beside Repeat.
my $repeat_at = index($markup, 'music_repeat');
my $toggle_at = index($markup, '_tools_toggle');
my $title_at = index($markup, '_full_title');
ok($repeat_at >= 0 && $toggle_at > $repeat_at && $title_at > $toggle_at,
	'More tools is next to Repeat, before the title');

like($help, qr/Escape leaves it/,
	'the Music help says Escape leaves fullscreen');
like($help, qr/button or Escape leaves fullscreen/,
	'and the video help names Escape too');

done_testing();
