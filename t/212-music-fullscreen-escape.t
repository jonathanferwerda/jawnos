# tests-for: public/js/manager/keyboard/03_editor_switcher.js templates/apps/video/markup.html.ep perl/help/topics_apps.pl
# covers:    Escape and F leave a fullscreen picture before the Music window's
#           shortcut block can swallow them, and the fullscreen toggle sits to
#           the right of the track title rather than in the More tools panel.

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

# The manager page keeps a hidden #alert_dialog .dialog_box in the DOM all the
# time, so Escape must look for a *visible* dialog. Testing the class alone
# always matched the hidden shell and spent Escape on it.
like($keys, qr/\.dialog_box:visible/, 'Escape only cancels a visible dialog');

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

# F leaves fullscreen from its own early branch too: the Music block is skipped
# while a slider has focus or another window is on top, which is when the
# picture fills the screen.
my $f_at = index($keys, 'keyCode == 70');
ok($f_at >= 0 && ($music_at < 0 || $f_at < $music_at),
	'F has a fullscreen-exit branch before the Music block');
my $f_exit_at = index($keys, 'document.exitFullscreen', $f_at);
ok($f_exit_at > $f_at, 'and that branch exits fullscreen');

# The music bar's order is transport, theatre, shuffle, repeat, tools, title,
# fullscreen. The title takes the row's slack, so the toggle after it sits at
# the right of the title, outside the tools panel.
my $repeat_at = index($markup, 'music_repeat');
my $toggle_at = index($markup, '_tools_toggle');
my $title_at = index($markup, '_full_title');
my $screen_at = index($markup, '_full_screen');
my $panel_at = index($markup, '_tools_panel');
ok($repeat_at >= 0 && $toggle_at > $repeat_at && $title_at > $toggle_at,
	'More tools is next to Repeat, before the title');
ok($title_at >= 0 && $screen_at > $title_at && $panel_at > $screen_at,
	'the fullscreen button is right of the title, outside the tools panel');

# The corner picture (a video or the visualiser played into a muted video) wears
# thumb_style. The playing track row is z-index 1100, so without a lift the
# picture is hidden under it when the library is up. The theatre picture needs
# no lift: the library is put away there.
like($markup, qr/thumb_style="[^"]*z-index:1200;/,
	'the corner picture sits over the playing track');
unlike($markup, qr/big_style="[^"]*z-index:/,
	'the theatre picture keeps its own layer');

like($help, qr/Escape leaves it/,
	'the Music help says Escape leaves fullscreen');
like($help, qr/button or Escape leaves fullscreen/,
	'and the video help names Escape too');
like($help, qr/player button beside the track title/,
	'the Music help says where the fullscreen button is');

done_testing();
