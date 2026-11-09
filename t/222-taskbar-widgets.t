# tests-for: public/js/manager/taskbar_edit.js public/js/manager/taskbar_edit/01_window_events.js public/js/manager/taskbar_power.js public/js/manager/taskbar_network.js public/js/manager/taskbar_sound.js public/js/manager/taskbar_panel.js templates/manager.html.ep public/css/manager.css scripts/jawnos_network.pl public/icons/network.svg perl/help/topics_features.pl perl/help/topics_web.pl perl/help/topics_apps.pl
# covers:    Taskbar widgets - the add-items list, the three display modes, the
#            widget order, and the network widget's Wi-Fi/Ethernet reading.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Mojo::JSON qw(decode_json);
use Symbol qw(gensym);
use RepoSource;

my $root = repo_root();

# --- the registry and the add-items list ------------------------------------
my $edit = read_file("$root/public/js/manager/taskbar_edit.js");
like($edit, qr/jawnosTaskbarWidgets = \{/, 'the widget registry exists');
like($edit, qr/power: \{ hint: 'Battery'/, 'Battery is a widget');
like($edit, qr/network: \{ hint: 'Network'/, 'Network is a widget');
like($edit, qr/function jawnosTaskbarWidgetSet\(/, 'a widget mode can be written');
like($edit, qr/function jawnosTaskbarWidgetToggle\(/, 'a widget can be turned on and off');
like($edit, qr/function jawnosTaskbarWidgetMake\(/, 'a widget builds its element');
like($edit, qr/fill_widgets/, 'the add-items list has a widget section');
like($edit, qr/add_label\('Widgets'\)/, 'the section is called Widgets');
like($edit, qr/pin_widget/, 'a widget row is marked as one');
like($edit, qr/function jawnosTaskbarWidgetContextBuild\(/, 'a widget has its own context menu');
like($edit, qr/act="widget_mode"/, 'the menu offers the display modes');
like($edit, qr/\['icon', 'Icon'\], \['full', 'Icon and status'\], \['off', 'Disabled'\]/,
	'and the three modes are Icon, Icon and status and Disabled');
like($edit, qr/jawnosTaskbarWidgetItem\('power', 'full'\)/, 'the battery widget is the default');
like($edit, qr/!has_widget/, 'an order from before widgets gains the default once');
like($edit, qr/\.taskbar_widget/, 'widgets are removed and rebuilt with the pins');
like($edit, qr/> \.taskbar_widget/, 'edit mode can drag a widget');

my $events = read_file("$root/public/js/manager/taskbar_edit/01_window_events.js");
like($events, qr/jawnosTaskbarWidgetContextBuild\(widget\)/, 'right-clicking a widget opens its menu');
like($events, qr/act == 'widget_mode'/, 'the mode rows are handled');
like($events, qr/jawnosTaskbarWidgetToggle\(widget\)/, 'the add-items row toggles a widget');
like($events, qr/pin_widget/, 'the row carries the widget name');

# --- the pollers ------------------------------------------------------------
my $power = read_file("$root/public/js/manager/taskbar_power.js");
like($power, qr/jawnosTaskbarEditing/, 'a press in edit mode does not open the app');
like($power, qr/\#taskbar_power/, 'the battery poller finds the built widget');

my $network = read_file("$root/public/js/manager/taskbar_network.js");
like($network, qr{url: '/manager/network/status'}, 'the network widget reads the network status');
like($network, qr/function jawnosNetworkTaskbarRender\(/, 'it has a renderer');
like($network, qr/jawnosT\('Ethernet'\)/, 'it names Ethernet');
like($network, qr/jawnosT\('Disconnected'\)/, 'and Disconnected');
like($network, qr/taskbar_network_bars/, 'it draws signal bars');

my $sound = read_file("$root/public/js/manager/taskbar_sound.js");
my $css = read_file("$root/public/css/manager.css");
my $core = read_file("$root/lib/JawnOS/Manager/Core1_tables_hooks.pm");

# --- the widget panels ------------------------------------------------------
# Each widget hangs one panel under itself. taskbar_panel.js owns the frame, so
# the three widgets can share the placing and the closing rather than grow
# three near-copies of the clock's menu.
my $panel = read_file("$root/public/js/manager/taskbar_panel.js");
like($panel, qr/function jawnosTaskbarPanelToggle\(/, 'a panel can be toggled');
like($panel, qr/function jawnosTaskbarPanelPlace\(/, 'a panel is placed against its widget');
like($panel, qr/function jawnosTaskbarPanelClose\(/, 'and closed as one');
like($panel, qr/addClass\('taskbar_panel'\)/, 'the panel wears the shared plate');
like($panel, qr/\.taskbar_panel_open/, 'a footer button opens the app');
like($panel, qr/closest\('\.taskbar_panel'\)/, 'a press outside closes it');
like($panel, qr/keyCode == 27/, 'Escape closes it');
like($core, qr{/js/manager/taskbar_panel\.js}, 'the panel frame is in the core bundle');
like($css, qr/\.taskbar_panel\.open\s*\{\s*display:\s*flex/, 'the panel is shown by its open class');
like($css, qr/\.taskbar_panel \.taskbar_panel_device/, 'a device row has a style');
like($css, qr/\.taskbar_panel \.taskbar_panel_footer/, 'and so does the footer');

like($sound, qr/jawnosTaskbarPanelToggle\('taskbar_sound_panel'/, 'the sound widget opens its panel');
like($sound, qr/\.on\('wheel'/, 'a wheel over the sound widget is heard');
like($sound, qr/function jawnosSoundTaskbarWheelAdjust\(/, 'and adjusts the output volume');
like($sound, qr/jawnosSoundTaskbarWheelRate = 2\.5/, 'a notch is half the old five-point rate');
like($sound, qr/#taskbar_sound_panel \[data-sound-volume\]/, 'a wheel over a panel slider is heard too');
like($sound, qr/\{ kind: kind, id: id, volume: volume \}/, 'the panel writes a device volume by id');
like($sound, qr{/manager/sound/default}, 'and can make a device the default');
like($sound, qr/jawnosT\('Open Sound'\)/, 'its footer opens Sound');

like($power, qr/jawnosTaskbarPanelToggle\('taskbar_power_panel'/, 'the battery widget opens its panel');
like($power, qr/data-power-plan/, 'the panel offers the power profiles');
like($power, qr{/manager/power/plan}, 'and saves one');
like($power, qr/jawnosT\('Open Power'\)/, 'its footer opens Power');
like($power, qr/jawnosT\('Power is managed by'\)/, 'the panel names who manages power');

like($network, qr/jawnosTaskbarPanelToggle\('taskbar_network_panel'/, 'the network widget opens its panel');
like($network, qr{/manager/network/wifi_scan}, 'the panel scans for networks');
like($network, qr{/manager/network/wifi_connect}, 'and joins one');
like($network, qr{/manager/network/vpn}, 'and starts or stops a VPN');
like($network, qr/jawnosT\('Open Network'\)/, 'its footer opens Network');
like($network, qr{/manager/network/public_ip}, 'the panel reads the outward address');
like($network, qr/jawnosT\('Public address'\)/, 'and names it');

# --- the shell and the styles ----------------------------------------------
my $manager = read_file("$root/templates/manager.html.ep");
unlike($manager, qr/id="taskbar_power"/, 'the widget is not fixed in the template');
$css = read_file("$root/public/css/manager.css");
like($css, qr/\.taskbar_widget\b/, 'the shared widget plate exists');
like($css, qr/\.taskbar_widget\[mode=icon\] \.taskbar_widget_text/, 'Icon mode hides the text');
like($css, qr/\.taskbar_network_bars/, 'the network bars have a style');
like($css, qr/\[kind=ethernet\].*taskbar_network_wire/s, 'Ethernet swaps in the wire glyph');
$core = read_file("$root/lib/JawnOS/Manager/Core1_tables_hooks.pm");
like($core, qr{/js/manager/taskbar_network\.js}, 'the network poller is in the core bundle');
ok(-e "$root/public/icons/network.svg", 'the add-items icon exists');

# --- help -------------------------------------------------------------------
require "$root/perl/help.pl";
like($help::topic{'taskbar'}->{summary}, qr/widgets/i, 'the taskbar topic names widgets');
like(join(' ', @{ $help::topic{'taskbar'}->{body} }), qr/Add items.*Widgets/s,
	'the taskbar topic points at Add items -> Widgets');
like(join(' ', @{ $help::topic{'network'}->{body} }), qr/Network widget/,
	'the Network topic names its widget');

# --- the Wi-Fi signal the widget shows --------------------------------------
# The helper is driven through a fake PATH: ip reports one wireless and one
# wired link, iw answers "this is wireless" and "-55 dBm", and iwctl names the
# connected network. Nothing here touches this machine's real network.
my $scratch = tempdir(CLEANUP => 1);
my $bin = "$scratch/bin";
make_path($bin);
my $script = "$root/scripts/jawnos_network.pl";

sub write_exe {
	my ($path, $body) = @_;
	write_file($path, "#!/bin/sh\n$body\n");
	chmod 0755, $path;
}

write_exe("$bin/ip", <<'SH');
if [ "$1" = "-j" ]; then
	cat <<'JSON'
[{"ifindex":1,"ifname":"lo","operstate":"unknown","address":"00:00:00:00:00:00","addr_info":[{"family":"inet","local":"127.0.0.1","prefixlen":8}]},
 {"ifindex":2,"ifname":"wlan0","operstate":"up","address":"00:11:22:33:44:55","addr_info":[{"family":"inet","local":"192.0.2.20","prefixlen":24}]},
 {"ifindex":3,"ifname":"eth0","operstate":"down","address":"00:11:22:33:44:66","addr_info":[]}]
JSON
	exit 0
fi
exit 1
SH

write_exe("$bin/iw", <<'SH');
if [ "$1" = "dev" ] && [ "$3" = "info" ]; then
	if [ "$2" = "wlan0" ]; then printf 'Interface wlan0\n\ttype managed\n'; exit 0; fi
	exit 1
fi
if [ "$1" = "dev" ] && [ "$3" = "link" ]; then
	if [ "$2" = "wlan0" ]; then printf 'Connected to 00:11:22:33:44:55\n\tSSID: jawn-iw-net\n\tsignal: -55 dBm\n'; exit 0; fi
	exit 1
fi
exit 1
SH

write_exe("$bin/iwctl", <<'SH');
case "$*" in
	"adapter list") printf 'Name Powered\n----\nphy0 on\n' ;;
	"station wlan0 show") printf 'Station: wlan0\n  State                     connected\n  Connected network         jawn-test-net\n' ;;
	"known-networks list") printf 'Known networks\n----\njawn-test-net\n' ;;
	*) exit 1 ;;
esac
exit 0
SH

sub helper_status {
	my ($path) = @_;
	$path ||= $bin;
	local $ENV{PATH} = "$path:/bin";
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, $^X, $script, 'status');
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	close $out;
	close $err;
	waitpid($pid, 0);
	return (decode_json($stdout), $stderr);
}

{
	my ($data, $stderr) = helper_status();
	is($data->{'ok'}, 1, 'the network status is readable with fake tools');
	my ($wifi) = grep { ($_->{'name'} || '') eq 'wlan0' } @{ $data->{'interfaces'} };
	ok($wifi, 'the wireless interface is found');
	is($wifi->{'wireless'}, 1, 'and iw says it is wireless even without /sys');
	my $link = $data->{'wifi'}{'interfaces'}->[0];
	is($link->{'ssid'}, 'jawn-test-net', 'the connected network is named');
	is($link->{'state'}, 'connected', 'and its state');
	is($link->{'rssi'}, -55, 'the signal is read from iw');
	is($link->{'quality'}, 90, 'and turned into a 0-100 quality');
	is($link->{'bars'}, 4, 'and four bars');
}

# A NetworkManager desktop has no iwctl. The same reading must come from iw's
# own link report, or the widget would say Disconnected on that machine.
{
	my $bin2 = "$scratch/bin2";
	make_path($bin2);
	write_file("$bin2/ip", read_file("$bin/ip"));
	chmod 0755, "$bin2/ip";
	write_file("$bin2/iw", read_file("$bin/iw"));
	chmod 0755, "$bin2/iw";
	foreach my $missing (qw(iwctl tailscale sudo)) {
		write_exe("$bin2/$missing", 'exit 1');
	}
	my ($data, $stderr) = helper_status($bin2);
	is($data->{'ok'}, 1, 'the status is readable without iwctl');
	my $link = $data->{'wifi'}{'interfaces'}->[0];
	is($link->{'ssid'}, 'jawn-iw-net', 'the SSID falls back to iw');
	is($link->{'state'}, 'connected', 'and so does the state');
	is($link->{'rssi'}, -55, 'the signal still comes from iw');
}

done_testing();
