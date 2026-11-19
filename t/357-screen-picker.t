# tests-for: public/js/manager/screen_sources.js public/js/manager/jp.js public/js/manager/manager/06_appointment_distance.js public/js/manager/manager/09_app_back.js public/js/manager/websocket/00_console_router.js lib/JawnOS/Manager/Part14.pm perl/Alarm.pl templates/appointment_wrapper.html.ep
# covers:    the desktop app's screen picker: the page asks the shell for the
#            screens and windows of a pending getDisplayMedia request, names the
#            chosen row for the real capture, and falls back to the browser's
#            own picker with no desktop bridge; the appointment's Media group
#            fills a screen-source select when it opens and a screen record
#            uses the chosen row. The row's label travels with the press - in
#            the appointment's data and again when the Alarm fires - so a
#            recorder on another machine can match it against its own list.

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
my $app_back = read_file("$root/public/js/manager/manager/09_app_back.js");
my $router = read_file("$root/public/js/manager/websocket/00_console_router.js");
my $part14 = read_file("$root/lib/JawnOS/Manager/Part14.pm");
my $alarm = read_file("$root/perl/Alarm.pl");
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

# --- the chosen row travels by name ------------------------------------------
# The list a remote recorder sees is its own: a row number there points at a
# different screen. The label the person chose is the only thing both machines
# can agree on, so the capture carries it beside the id.
like($picker, qr/function capture\(id, name\)/, 'a capture takes the row and its name');
like($picker, qr/whenReady\('screen_want', \{[\s\S]*?name: String\(name \|\| ''\)/,
	'and sends the name to the shell with the id');

# --- the appointment's Media group -------------------------------------------
like($jp, qr/function jpScreenSourceFill\(app\)/, 'the appointment fills a source list');
like($jp, qr/function jpScreenSource\(app\)/, 'and reads the chosen row');
like($jp, qr/return \{ id: select\.val\(\) \|\| '', name: option\.text\(\) \|\| '' \};/,
	'reading both the row id and its label');
like($jp, qr/function jpScreen\(app,uuid,source_id,source_name\)/,
	'a console screen record may name its own source');
like($jp, qr/JawnScreen\.capture\(source\.id, source\.name\)/,
	'a screen record captures that row by name');
like($jp, qr/if \(!source\.id && !source\.name\) \{ source = jpScreenSource\(app\); \}/,
	'and falls back to this machine\'s select when the call names none');
like($jp, qr/JawnScreen\.refresh\(\)/, 'the list comes from the desktop app');
like($menu, qr/group == 'media' && typeof jpScreenSourceFill === 'function'/,
	'the Media group asks for the list when it opens');
like($menu, qr/jpScreenSourceFill\(appointment\.attr\('app'\)\)/,
	'for the appointment it opened');
like($template, qr/class="screen_source" app="<%= \$a %>"/,
	'the wrapper carries a screen-source select');
like($template, qr/Which screen or window to share/,
	'with a hint naming what it chooses');

# --- the press carries the name to the recording machine ----------------------
# managerReset runs on the pressing machine and on a peer. Only the recorder has
# the screen, so the name must ride the appointment the peer reads, not a
# message from the screen that chose it.
like($app_back, qr/recorder == 'screen' && typeof jpScreenSource === 'function'/,
	'a screen press reads this machine\'s chosen row');
like($app_back, qr/screen: screen_source\.id,/,
	'and sends the row id with the appointment');
like($app_back, qr/screen_name: screen_source\.name,/,
	'along with the label a remote recorder can match');

like($part14, qr/my \$screen_source = \$c->param\('screen'\) \|\| '';/,
	'the server reads the row id');
like($part14, qr/my \$screen_name = \$c->param\('screen_name'\) \|\| '';/,
	'and its label');
my ($id_guard) = $part14 =~ /\$screen_source = '' unless \$screen_source =~ (\/\\A.*?\\z\/);/;
ok($id_guard, 'the row id is validated by a pattern');
SKIP: {
	skip 'the row pattern is not a literal in Part14', 4 unless $id_guard;
	my $row_re = eval "qr$id_guard";
	skip "the row pattern did not compile: $@", 4 unless $row_re;
	like('screen:0', $row_re, 'a screen row is accepted');
	like('window:12', $row_re, 'and a window row');
	unlike('screen:', $row_re, 'a row with no index is refused');
	unlike("window:0\x01", $row_re, 'and one with a control character');
}
like($part14, qr/\$screen_name =~ s\/\[\\x00-\\x1f\]\/\/g;/,
	'the label is stripped of control characters');
like($part14, qr/\$screen_name = substr\(\$screen_name, 0, 300\);/,
	'and capped at 300 characters');
like($part14, qr/\$dat->\{'screen'\} = \$screen_source if length \$screen_source;/,
	'an empty row is left out of the data');
like($part14, qr/\$dat->\{'screen_name'\} = \$screen_name if length \$screen_name;/,
	'and so is an empty label');

like($alarm, qr/my \$screen_source = \$data->\{'screen'\} \|\| '';/,
	'the Alarm reads the saved row when it fires');
like($alarm, qr/console_command\('jpScreen', \$a->\{'app'\}, \$a->\{'uuid'\}, \$screen_source, \$screen_name\)/,
	'and hands both to the recording machine');
like($router, qr/jpScreen\(String\(a\[0\]\), String\(a\[1\]\), String\(a\[2\] \|\| ''\), String\(a\[3\] \|\| ''\)\)/,
	'whose console router forwards both arguments');

done_testing();
