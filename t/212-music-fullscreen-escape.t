# tests-for: public/js/manager/keyboard/03_editor_switcher.js templates/apps/video/markup.html.ep perl/help/topics_apps.pl
# covers:    Escape leaves a fullscreen picture before the Music window's
#           shortcut block can swallow it, and the More tools toggle sits
#           beside Repeat rather than after the title.

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

# Escape is handled by the keydown chain's first Escape branch (the one that
# also dismisses a dialog), not by the later Music shortcut block. The branch
# must leave a fullscreen picture itself, with the prefixed fallback.
like($keys, qr/keyCode == 27\) \{.*?document\.exitFullscreen \? document\.exitFullscreen\(\)/s,
	'the first Escape branch leaves fullscreen');
like($keys, qr/webkitExitFullscreen/, 'with the prefixed fallback');
my $escape_at = index($keys, 'keyCode == 27');
my $exit_at = index($keys, 'document.exitFullscreen');
my $music_at = index($keys, "topWindow() == 'music'");
ok($escape_at >= 0 && $exit_at > $escape_at
	&& ($music_at < 0 || $exit_at < $music_at),
	'and it runs before the Music shortcut block');

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
