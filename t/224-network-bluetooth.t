# tests-for: scripts/jawnos_bluetooth.pl lib/JawnOS/Controller/manager_misc2.pm lib/JawnOS/Routes/manager_misc2.pm lib/JawnOS/Manager/Part08.pm lib/JawnOS/Manager/Index.pm lib/JawnOS/Manager/Declarations.pm templates/apps/network.html.ep templates/apps/network/controller.html.ep public/js/manager/network.js public/js/manager/network/02_tabs_bluetooth_remote.js public/js/manager/taskbar_network.js public/js/manager/taskbar_edit.js public/css/manager.css perl/help/topics_web.pl
# covers:    The Network app's Bluetooth tab and Remote Machines tab, the
#            Bluetooth helper's fixed command set and parsers behind a fake
#            bluetoothctl, the scroll limits, and the taskbar's Bluetooth read.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Path qw(make_path);
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Mojo::JSON qw(decode_json);
use Symbol qw(gensym);

my $root = "$FindBin::Bin/..";

sub source {
	my ($path) = @_;
	my $text = read_file("$root/$path");
	return defined $text ? $text : '';
}

# --- the helper's fixed command set -----------------------------------------
my $script = "$root/scripts/jawnos_bluetooth.pl";
ok(-f $script, 'the Bluetooth helper exists');

my $scratch = tempdir(CLEANUP => 1);
my $empty = "$scratch/empty";
my $fake = "$scratch/bin";
make_path($empty);
make_path($fake);

sub write_exe {
	my ($path, $body) = @_;
	open my $fh, '>', $path or die "cannot write $path: $!";
	print $fh "#!/bin/sh\n$body\n";
	close $fh;
	chmod 0755, $path or die "cannot chmod $path: $!";
}

write_exe("$fake/bluetoothctl", <<'FAKE_BLUETOOTHCTL');
case "$*" in
	"show")
		printf 'Controller 00:11:22:33:44:55 (public)\n\tName: jawn-host\n\tAlias: jawn-host\n\tPowered: yes\n\tDiscoverable: no\n'
		;;
	"devices")
		printf 'Device AA:BB:CC:DD:EE:01 Headphones\n'
		printf 'Device AA:BB:CC:DD:EE:02 Keyboard\n'
		printf 'Device AA:BB:CC:DD:EE:03 Untrusted Pad\n'
		;;
	"info AA:BB:CC:DD:EE:01")
		printf 'Device AA:BB:CC:DD:EE:01 (public)\n\tName: Headphones\n\tAlias: Headphones\n\tIcon: audio-headphones\n\tPaired: yes\n\tTrusted: yes\n\tConnected: yes\n'
		;;
	"info AA:BB:CC:DD:EE:02")
		printf 'Device AA:BB:CC:DD:EE:02 (public)\n\tName: Keyboard\n\tAlias: Keyboard\n\tIcon: input-keyboard\n\tPaired: yes\n\tTrusted: no\n\tConnected: no\n'
		;;
	"info AA:BB:CC:DD:EE:03")
		printf 'Device AA:BB:CC:DD:EE:03 (public)\n\tName: Untrusted Pad\n\tAlias: Untrusted Pad\n\tIcon: input-gaming\n\tPaired: no\n\tTrusted: no\n\tConnected: no\n'
		;;
	"pair AA:BB:CC:DD:EE:0F")
		printf 'Failed to pair: org.bluez.Error.AuthenticationFailed\n' >&2
		exit 1
		;;
	*"scan on"*|"scan off"|"power on"|"power off")
		exit 0
		;;
	"pair "*|"connect "*|"disconnect "*|"trust "*|"remove "*)
		exit 0
		;;
	*)
		exit 1
		;;
esac
FAKE_BLUETOOTHCTL

sub run_bt {
	my %opt = @_;
	local $ENV{'PATH'} = defined $opt{'path'} ? $opt{'path'} : $fake;
	local $ENV{'HOME'} = $scratch;
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, $^X, $script, @{ $opt{'args'} || [] });
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	waitpid($pid, 0);
	return ($? >> 8, $stdout, $stderr);
}

sub answer {
	my ($rc, $out, $err, $what) = @_;
	is($rc, 0, "$what exits 0");
	my $data = eval { decode_json($out) };
	unless (ref $data eq 'HASH') {
		BAIL_OUT("$what did not print one JSON object: " . ($err || $out));
	}
	return $data;
}

sub expect_error {
	my ($want, $what, %opt) = @_;
	my ($rc, $out, $err) = run_bt(%opt);
	my $data = answer($rc, $out, $err, $what);
	is($data->{'ok'}, 0, "$what reports ok 0");
	is($data->{'error'}, $want, "$what says why");
	return $data;
}

{
	my ($rc, $out) = run_bt('args' => ['__no_such_command__']);
	my $data = answer($rc, $out, '', 'an unknown command');
	is($data->{'error'}, 'Unknown Bluetooth command.', 'an unknown command is named');
}

expect_error('That device address is not valid.', 'pair with a malformed address',
	args => ['pair', 'not-a-mac']);
expect_error('Scanning can only be turned on or off.', 'scan with a bad state',
	args => ['scan', 'maybe']);
expect_error('The adapter can only be turned on or off.', 'power with a bad state',
	args => ['power', 'maybe']);
expect_error('Bluetooth is not available (bluetoothctl was not found).',
	'status with no bluetoothctl', args => ['status'], path => $empty);
expect_error('Bluetooth is not available (bluetoothctl was not found).',
	'pair with no bluetoothctl', args => ['pair', 'AA:BB:CC:DD:EE:01'], path => $empty);

# A bluetoothctl that fails for a reason other than "no adapter" is an error,
# not an empty list; a machine with no adapter is still a normal answer.
my $fail = "$scratch/fail";
my $noadapter = "$scratch/noadapter";
make_path($fail);
make_path($noadapter);
write_exe("$fail/bluetoothctl", q{printf 'Failed to open Bluetooth socket\n' >&2; exit 1});
write_exe("$noadapter/bluetoothctl", <<'SH');
case "$*" in
	"show") printf 'No default controller available\n' >&2; exit 1 ;;
	*) exit 1 ;;
esac
SH

{
	my ($rc, $out) = run_bt('args' => ['status'], path => $fail);
	my $data = answer($rc, $out, '', 'status with a failing bluetoothctl');
	is($data->{'ok'}, 0, 'a failing bluetoothctl reports ok 0');
	like($data->{'error'}, qr/Bluetooth socket/, 'and its reason reaches the caller');
}

{
	my ($rc, $out) = run_bt('args' => ['status'], path => $noadapter);
	my $data = answer($rc, $out, '', 'status with no adapter');
	is($data->{'ok'}, 1, 'a machine with no adapter is a normal answer');
	is($data->{'adapter'}->{'present'}, 0, 'with no adapter present');
	is_deeply($data->{'connected'}, [], 'no connected devices');
	is_deeply($data->{'paired'}, [], 'no paired devices');
	is_deeply($data->{'found'}, [], 'and nothing found');
}

# --- status parsing ----------------------------------------------------------
{
	my ($rc, $out) = run_bt('args' => ['status']);
	my $data = answer($rc, $out, '', 'status');
	is($data->{'ok'}, 1, 'status succeeds behind the fake');
	is($data->{'adapter'}->{'present'}, 1, 'the adapter is present');
	is($data->{'adapter'}->{'powered'}, 1, 'and powered');
	is($data->{'adapter'}->{'discoverable'}, 0, 'and not discoverable');
	is($data->{'adapter'}->{'address'}, '00:11:22:33:44:55', 'the adapter address is kept');
	is($data->{'adapter'}->{'name'}, 'jawn-host', 'the adapter alias is kept');

	my $found = $data->{'found'};
	is(scalar @{$found}, 3, 'every known device is listed');
	my %by_name = map { $_->{'name'} => $_ } @{$found};
	ok($by_name{'Headphones'}, 'a device name is read from info');
	is($by_name{'Headphones'}->{'address'}, 'AA:BB:CC:DD:EE:01', 'with its address');
	is($by_name{'Headphones'}->{'connected'}, 1, 'and connected state');
	is($by_name{'Headphones'}->{'paired'}, 1, 'and paired state');
	is($by_name{'Headphones'}->{'trusted'}, 1, 'and trusted state');
	is($by_name{'Headphones'}->{'icon'}, 'audio-headphones', 'and its icon');
	is($by_name{'Keyboard'}->{'paired'}, 1, 'a paired device is called paired');
	is($by_name{'Keyboard'}->{'connected'}, 0, 'and not connected');
	ok(!exists $by_name{'Keyboard'}->{'icon'} || $by_name{'Keyboard'}->{'icon'} eq 'input-keyboard',
		'an icon is carried when info has one');

	is(scalar @{ $data->{'connected'} }, 1, 'only the connected device is in the connected list');
	is($data->{'connected'}->[0]->{'name'}, 'Headphones', 'and it is the headphones');
	is(scalar @{ $data->{'paired'} }, 2, 'both paired devices are in the paired list');
}

# --- the actions -------------------------------------------------------------
{
	my ($rc, $out) = run_bt('args' => ['pair', 'AA:BB:CC:DD:EE:01']);
	my $data = answer($rc, $out, '', 'pair');
	is($data->{'ok'}, 1, 'pair succeeds');
	is($data->{'message'}, 'Paired with AA:BB:CC:DD:EE:01.', 'and names the device');
}

{
	my ($rc, $out) = run_bt('args' => ['remove', 'AA:BB:CC:DD:EE:01']);
	my $data = answer($rc, $out, '', 'remove');
	is($data->{'ok'}, 1, 'remove succeeds');
	is($data->{'message'}, 'Forgot AA:BB:CC:DD:EE:01.', 'and says it was forgotten');
}

{
	my ($rc, $out) = run_bt('args' => ['connect', 'AA:BB:CC:DD:EE:0F']);
	my $data = answer($rc, $out, '', 'connect');
	is($data->{'ok'}, 1, 'connect succeeds');
}

{
	my ($rc, $out) = run_bt('args' => ['pair', 'AA:BB:CC:DD:EE:0F']);
	my $data = answer($rc, $out, '', 'a failed pair');
	is($data->{'ok'}, 0, 'a failed pair reports ok 0');
	like($data->{'error'}, qr/AuthenticationFailed/, 'and bluetoothctl\'s reason reaches the caller');
}

{
	my ($rc, $out) = run_bt('args' => ['scan', 'on']);
	my $data = answer($rc, $out, '', 'scan on');
	is($data->{'ok'}, 1, 'scan on succeeds');
	is($data->{'scanning'}, 1, 'and reports scanning');
}

{
	my ($rc, $out) = run_bt('args' => ['power', 'on']);
	my $data = answer($rc, $out, '', 'power on');
	is($data->{'ok'}, 1, 'power on succeeds');
	is($data->{'powered'}, 1, 'and reports powered');
}

# --- the route and action wiring --------------------------------------------
my $routes = source('lib/JawnOS/Routes/manager_misc2.pm');
like($routes, qr/\[\s*7849\s*,\s*'get'\s*,\s*'\/manager\/network\/bluetooth\/status'\s*,\s*'action_7849'\s*\]/,
	'the Bluetooth status route is registered');
like($routes, qr/\[\s*7852\s*,\s*'post'\s*,\s*'\/manager\/network\/bluetooth\/scan'\s*,\s*'action_7852'\s*\]/,
	'the Bluetooth scan route is registered');
like($routes, qr/\[\s*7855\s*,\s*'post'\s*,\s*'\/manager\/network\/bluetooth\/action'\s*,\s*'action_7855'\s*\]/,
	'the Bluetooth action route is registered');

my $controller = source('lib/JawnOS/Controller/manager_misc2.pm');
like($controller, qr/^sub action_7849\b/m, 'the status action exists');
like($controller, qr/^sub action_7852\b/m, 'the scan action exists');
like($controller, qr/^sub action_7855\b/m, 'the action route exists');
like($controller, qr/bluetooth_helper\(\['status'\]\)/, 'the status action calls the Bluetooth helper');
like($controller, qr/bluetooth_helper\(\['scan'/, 'the scan action calls the Bluetooth helper');
like($controller, qr/\[\^?0-9A-Fa-f:\]\{17\}/, 'the controller validates a MAC before the helper runs');

my $part08 = source('lib/JawnOS/Manager/Part08.pm');
like($part08, qr/^sub bluetooth_helper\b/m, 'the Bluetooth helper is a Manager helper');
like(source('lib/JawnOS/Manager/Index.pm'),
	qr/'bluetooth_helper'\s*=>\s*'JawnOS\/Manager\/Part08\.pm'/, 'and is in the name index');
like(source('lib/JawnOS/Manager/Declarations.pm'), qr/^sub bluetooth_helper;/m,
	'and is forward-declared');

# --- the tabs, the lists and the scroll limits ------------------------------
my $template = source('templates/apps/network.html.ep');
like($template, qr/data-network-tab="network"/, 'the Network tab exists');
like($template, qr/data-network-tab="bluetooth"/, 'the Bluetooth tab exists');
like($template, qr/data-network-tab="remote"/, 'the Remote Machines tab exists');
like($template, qr/id="network_panel_bluetooth"/, 'the Bluetooth panel exists');
like($template, qr/id="network_panel_remote"/, 'the Remote Machines panel exists');
like($template, qr/id="network_bluetooth_power"/, 'the adapter power toggle exists');
like($template, qr/id="network_bluetooth_scan"/, 'the Bluetooth Scan button exists');
like($template, qr/id="network_bluetooth_connected"/, 'the connected list exists');
like($template, qr/id="network_bluetooth_paired"/, 'the paired list exists');
like($template, qr/id="network_bluetooth_found"/, 'the found list exists');
like($template, qr/id="network_bluetooth_jawnos"/, 'the JawnOS devices list exists');
like($template, qr/ble_device_listing/, 'the JawnOS list comes from the BLE listing');
like($template, qr/remote_manager_open/, 'a remote machine can open its Manager');
like($template, qr/network_remote_toggle/, 'and its Remote control accordion toggle');
like($template, qr/id="remote_control"/, 'the shared remote control panel is in the tab');
like($template, qr/remote_control_machine_select/, 'a hidden machine list feeds it');
like(source('public/js/manager/network/02_tabs_bluetooth_remote.js'), qr/function networkRemoteControlOpen/, 'the accordion moves it under the row');
like($template, qr/remote_machine_lister/, 'Remote Machines uses the same lister as the keyboard');

my $tabs = source('public/js/manager/network/02_tabs_bluetooth_remote.js');
like($tabs, qr/localStorage\.getItem\(network_tab_storage\)/, 'the last tab is read from localStorage');
like($tabs, qr/localStorage\.setItem\(network_tab_storage/, 'and written back');
like($tabs, qr/bluetooth\/status/, 'the tab reads the Bluetooth status route');
like($tabs, qr/bluetooth\/action/, 'and posts Bluetooth actions');
like($tabs, qr/bluetooth\/scan/, 'and scans');
like(source('public/js/manager/network.js'), qr/02_tabs_bluetooth_remote\.js/,
	'the index names the new part');

like($template, qr/\.network_list\s*\{[^}]*max-height[^}]*overflow-y:auto/s,
	'a list has a vertical scroll limit');
like($template, qr/#network_wifi_state[^{]*\{[^}]*max-height[^}]*overflow-y:auto/s,
	'the Wi-Fi state box scrolls');
like($template, qr/#network_wifi_list[^{]*\{[^}]*max-height[^}]*overflow-y:auto/s,
	'the Wi-Fi list scrolls');
like($template, qr/#network_saved_list[^{]*\{[^}]*max-height[^}]*overflow-y:auto/s,
	'the saved list scrolls');
like($template, qr/#network_vpn_content[^{]*\{[^}]*max-height[^}]*overflow-y:auto/s,
	'the VPN list scrolls');
like($template, qr/\.network_android_list[^{]*\{[^}]*max-height[^}]*overflow-y:auto/s,
	'the Android list scrolls');
like($template, qr/\.network_bluetooth_list\s*\{[^}]*max-height[^}]*overflow-y:auto/s,
	'the Bluetooth lists scroll');
like($template, qr/\.network_remote_list\s*\{[^}]*max-height[^}]*overflow:auto/s,
	'the Remote Machines table scrolls both ways');
like($template, qr/\.network_table_wrap\s*\{\s*width:100%;\s*overflow-x:auto;/, 
	'table wrappers keep horizontal scrolling');

# --- the taskbar widget reads Bluetooth too ---------------------------------
my $taskbar = source('public/js/manager/taskbar_network.js');
like($taskbar, qr{url: '/manager/network/status'}, 'the widget still reads the network status');
like($taskbar, qr{url: '/manager/network/bluetooth/status'}, 'and reads Bluetooth separately');
like($taskbar, qr/function jawnosNetworkTaskbarBluetooth\(/, 'it has a Bluetooth renderer');
like($taskbar, qr/jawnosNetworkTaskbarBluetoothConnected\(/, 'it finds a connected device');
like($taskbar, qr/taskbar_network_bluetooth/, 'it names the Bluetooth glyph');
like($taskbar, qr/bluetooth_name/, 'and appends the connected name');
like(source('public/js/manager/taskbar_edit.js'), qr/taskbar_network_bluetooth/,
	'the widget builder carries the glyph');
my $css = source('public/css/manager.css');
like($css, qr/\.taskbar_network_bluetooth/, 'the glyph has a style');
like($css, qr/\[bluetooth=on\].*taskbar_network_bluetooth/s, 'and lights up when connected');

# --- the help topic names the new tabs and the widget ------------------------
{
	no warnings 'once';
	require "$root/perl/help.pl";
	my $body = join(' ', @{ $help::topic{'network'}->{'body'} });
	like($body, qr/four tabs/, 'the topic names the tabs');
	like($body, qr/Controller/, 'the topic explains the Controller tab');
	like($body, qr/Bluetooth/, 'the topic explains Bluetooth');
	like($body, qr/Remote Machines/, 'the topic explains Remote Machines');
	like($body, qr/scroll/, 'the topic explains the scroll limits');
	like($body, qr/Bluetooth glyph/, 'the topic names the widget\'s Bluetooth glyph');
}


like($template, qr/data-network-tab="controller"/, 'the Network has a Controller tab');
like($template, qr/network_panel_controller/, 'and its panel');
like(source('public/js/manager/network/02_tabs_bluetooth_remote.js'), qr/tab === 'controller'/, 'the tab is a valid Network tab');

done_testing();
