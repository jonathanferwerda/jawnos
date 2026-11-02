use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# Six buttons and a title in one bar left the title a sliver. Help and the pin
# now live behind the app icon: the bar shows the name and the four window
# controls, and the two quiet controls are revealed on a press of the icon. The
# name is what pushes them to the right edge, so a title is clipped rather than
# overlapped.
#
# The first cut of this shipped the comment that described it *inside the Perl
# string*, which became a text node in the flex row - an anonymous item 460px
# wide that squeezed the title to 22px. The bar's children are checked for that
# here so a comment can never be pasted into the markup again.

my $root = repo_root();
my $maker = read_file("$root/lib/JawnOS/Manager/Part22.pm");
my $fit = read_file("$root/public/js/manager/windows/02_fit.js");
my $back = read_file("$root/public/js/manager/manager/09_app_back.js");
my $css = read_file("$root/public/css/manager.css");
my $help = read_file("$root/perl/help.pl");

# --- the two quiet controls live behind the icon ---------------------------
like($maker, qr/class="navbar_reveal">' \. \$navbar_agent_control \. \$navbar_place_control/, 
	'Help and the pin are in the revealed group');
like($maker, qr/revealed="no"/, 'a bar starts with the group put away');
like($maker, qr/onclick="navbarReveal\(this\)"/, 'the app icon reveals it');
like($fit, qr/function navbarReveal\(el\)/, 'there is one toggle for it');
like($fit, qr/\.top_navbar\[revealed="yes"\]'\)\.attr\('revealed', 'no'\)/, 'only one bar is open at a time');
like($fit, qr/if \(e\.key != 'Escape'\) \{ return; \}/, 'Escape puts it away');
like($css, qr/\.top_navbar\[revealed="yes"\] \.navbar_reveal \{ display: flex; \}/,
	'the group is hidden until the bar says otherwise');

# --- the markup carries no comment and no duplicate control ---------------
unlike($maker, qr/<%# The bar keeps its room/, 'no template comment is pasted into the bar markup');
unlike($maker, qr/class="navbar_buttons">\s*'\s*\.\s*\$navbar_agent_control/,
	'the help button is not also in the right-hand group');
my $help_ids = () = $maker =~ /_help_button window_action help_button/g;
is($help_ids, 1, 'the help button is built once');

# --- the name is what pushes the controls right ---------------------------
unlike($css, qr/\.top_navbar \.navbar_buttons \{[^}]*margin-left: auto/,
	'the buttons do not take the free space the name needs');
like($css, qr/\.top_navbar \.appointment_name \{ flex: 1 1 auto; min-width: 0/, 'the name keeps the room');
like($css, qr/\.top_navbar \.navbar_reveal \.window_action \{/, 'a revealed control is the same size as the others');

# --- a press inside the group is not a window press -----------------------
like($back, qr/closest\('\.navbar_buttons, \.navbar_reveal, \.window_icon_holder'\)/,
	'a phone tap on the icon does not also walk the pile');

# --- and the help says so -------------------------------------------------
like($help, qr/The pin is the map-pin button in the title bar/, 'the Windows topic describes the pin');

done_testing();
