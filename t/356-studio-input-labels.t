# tests-for: public/js/manager/jp.js templates/studio/plug_selection.html.ep
# covers:    the channel's input picker names its devices: enumerateDevices is
#            asked again after the microphone permission, the "default" and
#            "communications" pseudo entries are not shown, and a device that
#            still has no label is named by its kind and number instead of
#            showing a blank row.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);

my $root = "$FindBin::Bin/..";
my $jp = read_file("$root/public/js/manager/jp.js");
my $template = read_file("$root/templates/studio/plug_selection.html.ep");

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

done_testing();
