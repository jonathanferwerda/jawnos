# tests-for: public/js/manager/jp.js public/js/manager/studio/05_inputs.js templates/studio/plug_selection.html.ep
# covers:    the channel's input picker names its devices: enumerateDevices is
#            asked again after the microphone permission, the "default" and
#            "communications" pseudo entries are not shown, and a device that
#            still has no label is named by its kind and number instead of
#            showing a blank row; the screen-share plug asks getDisplayMedia
#            for the chosen screen - by row and by name, so a recorder on
#            another machine can find it - rather than opening a camera.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);

my $root = "$FindBin::Bin/..";
my $jp = read_file("$root/public/js/manager/jp.js");
my $template = read_file("$root/templates/studio/plug_selection.html.ep");
my $inputs = read_file("$root/public/js/manager/studio/05_inputs.js");

# --- the browser's list is named, not blank ----------------------------------
like($jp, qr/function studioDeviceLabel\(/, 'jp.js names a device that has no label');
like($jp, qr/function studioDeviceList\(/, 'and builds the list the picker shows');
like($jp, qr/v\.deviceId == 'default' \|\| v\.deviceId == 'communications'/,
	'the default and communications pseudo entries are skipped');
like($jp, qr/'Camera'.*'Speaker'.*'Microphone'/s, 'a blank device falls back to its kind');
like($jp, qr/function studioDeviceLabelsReady\(/, 'a saved pick can ask whether labels are still missing');

# --- permission first, then enumerate ----------------------------------------
like($jp, qr/studioDevicePermissionProbe\(constraints\)[\s\S]*?enumerateDevices\(\)[\s\S]*?studioDeviceList/,
	'the list is read again after the permission grant');
like($jp, qr/probe\.getTracks[\s\S]*?track\.stop\(\)/, 'the permission probe is closed at once');
unlike($jp, qr/test\.onstart/, 'the old onstart stop is gone');
like($jp, qr/constraints\['all'\] = all;/, 'the named list is what the picker receives');

# --- the template cannot print an empty cell ---------------------------------
like($template, qr/my %device_number;/, 'the template numbers devices by kind');
like($template, qr/my \$label = defined/, 'and keeps a label only when it has text');
like($template, qr/&subs::ui\(\$word\) \. ' ' \. \$device_number/,
	'blank devices get a translatable kind name');
like($template, qr/<td style="font-size:20px;vertical-align:top;"><%= \$label %><\/td>/,
	'the row prints the resolved label');

# --- the screen-share plug is a display capture, not a camera ----------------
like($inputs, qr/var screen_share = \(plug\['type'\] == 'screen_share'\)/,
	'the plug type is remembered as a screen share');
like($inputs, qr/navigator\.mediaDevices\.getDisplayMedia\(\{[\s\S]*?displaySurface: 'monitor'/,
	'and asks for the monitor rather than a video device');
like($inputs, qr/stream\.getAudioTracks\(\)\.length \? studioAttachInput/,
	'a screen stream with no audio still records its picture');

# --- the input offers this machine's capture sources -------------------------
# A laptop with a built-in mic and a UM2 must be able to say which one a take
# means. The picker lists the machine's sources (minus a sink's own monitor),
# shows the human name, and saves the choice on the plan's input source.
like($template, qr/studio_input_node/, 'the input picker offers a capture-source select');
like($template, qr/&subs::ui\('This machine\\'s input'\)/,
	'named in on-screen words rather than a device id');
like($template, qr/&subs::ui\('The machine\\'s default input'\)/,
	'with the default source as a row of its own');
like($template, qr/\$source->\{'name'\}/, 'each row shows the source\'s human name');
like($template, qr/selected/, 'the node the plan already names is the one selected');
like($template, qr/hint="<%= &subs::ui\('Choose which of this machine/, 'and the choice says what it does');
like($inputs, qr#url: '/manager/studio/input/node'#,
	'choosing one saves it on the plan, which the engine reads');
like($inputs, qr/data: \{ channel: Math\.floor\(input\), node: select\.val\(\) \|\| '' \}/,
	'the device channel and the chosen node are the two facts saved');
like($inputs, qr/var name = option\.text\(\) \|\| '';/,
	'and the answer names the node a person chose');
like($inputs, qr/jawnosT\('The input source is saved'\)/,
	'the result is said in the page language');

# --- the channel's screen list and its app inputs ----------------------------
like($inputs, qr/function studioScreenSourceFill/, 'the channel offers the desktop screen list');
like($inputs, qr/studio_screen_source/, 'through a source select');
like($inputs, qr/return \{ id: select\.val\(\) \|\| '', name: option\.text\(\) \|\| '' \};/,
	'reading both the chosen row and its label');
like($inputs, qr/data\.screen_name = source\.name;/,
	'a changed row stores the label with the plug');
like($inputs, qr/if \(screen\.name\) \{ data\.screen_name = screen\.name; \}/,
	'and a chosen row sends it when the plug opens');
like($inputs, qr/\.index\(sis\)/, 'a real audio input is numbered by its place in the list');
like($inputs, qr/data\.input = input;/, 'and that number is stored with the plug');
like($inputs, qr/if \(direction == 'input' && type == 'usermedia' && av == 'a'\)/,
	'only an audio input gets the engine number');
like($inputs, qr/JawnScreen\.capture\(plug\['screen'\] \|\| '', plug\['screen_name'\] \|\| ''\)/,
	'and captures the chosen row by id and name');
like($inputs, qr/plug\['app'\] == 'marker'/, 'Marker is a channel input');
like($inputs, qr/whiteboard\.captureStream\(30\)/, 'through its canvas stream');
like($inputs, qr/plug\['app'\] == 'music'/, 'Music is a channel input');
like($inputs, qr/player\.captureStream\(\)/, 'through the #video element');
like($inputs, qr/plug\['app'\] == 'synth'[\s\S]*?studioAttachSynth/,
	'Synth still routes its real output node into the channel');
like($inputs, qr/function studioAttachCapturedStream/, 'one attach path serves them all');

done_testing();
