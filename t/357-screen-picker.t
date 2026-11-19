# tests-for: public/js/manager/screen_sources.js public/js/manager/jp.js public/js/manager/manager/06_appointment_distance.js templates/appointment_wrapper.html.ep
# covers:    the desktop app's screen picker: the page asks the shell for the
#            screens and windows of a pending getDisplayMedia request, names the
#            chosen row for the real capture, and falls back to the browser's
#            own picker with no desktop bridge; the appointment's Media group
#            fills a screen-source select when it opens and a screen record
#            uses the chosen row.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);

my $root = "$FindBin::Bin/..";
my $picker = read_file("$root/public/js/manager/screen_sources.js");
my $jp = read_file("$root/public/js/manager/jp.js");
my $menu = read_file("$root/public/js/manager/manager/06_appointment_distance.js");
my $template = read_file("$root/templates/appointment_wrapper.html.ep");

# --- the page's half of the picker ------------------------------------------
like($picker, qr/window\.JawnScreen = \{/, 'the picker is one global');
like($picker, qr/whenReady\('screen_list'\)/, 'the page asks for the list');
like($picker, qr/whenReady\('screen_want'/, 'names the chosen row for the capture');
like($picker, qr/post\('screen_cancel'\)/, 'and cancels the preflight when it is done');
like($picker, qr/window\.jawnosScreenSources = function/, 'the shell answers with the rows');
like($picker, qr/getDisplayMedia/, 'the preflight is a real getDisplayMedia request');
like($jp, qr/row\.kind === 'window'\) \? 'Windows' : 'Screens'/,
	'windows and screens are told apart');
like($picker, qr/available: available/, 'a browser without the bridge can see it is unavailable');
like($picker, qr/capture: capture/, 'and keeps one capture entry point');

# --- the appointment's Media group -------------------------------------------
like($jp, qr/function jpScreenSourceFill\(app\)/, 'the appointment fills a source list');
like($jp, qr/function jpScreenSource\(app\)/, 'and reads the chosen row');
like($jp, qr/JawnScreen\.capture\(jpScreenSource\(app\)\)/,
	'a screen record captures that row');
like($jp, qr/JawnScreen\.refresh\(\)/, 'the list comes from the desktop app');
like($menu, qr/group == 'media' && typeof jpScreenSourceFill === 'function'/,
	'the Media group asks for the list when it opens');
like($menu, qr/jpScreenSourceFill\(appointment\.attr\('app'\)\)/,
	'for the appointment it opened');
like($template, qr/class="screen_source" app="<%= \$a %>"/,
	'the wrapper carries a screen-source select');
like($template, qr/Which screen or window to share/,
	'with a hint naming what it chooses');

done_testing();
