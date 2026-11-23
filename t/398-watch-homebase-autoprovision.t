# tests-for: lib/JawnOS/Domain/Network.pm lib/JawnOS/Domain/Ble.pm lib/JawnOS/Manager/Part35.pm lib/JawnOS/Manager/Part34.pm lib/JawnOS/Controller/manager_embedded.pm lib/JawnOS/Controller/manager_misc13.pm perl/watch.pl lib/JawnOS/Domain/Loader.pm
# covers:    A device paired before a machine was renamed carries a durable id no
#            machine answers to. ble_homebase_alive treated that phantom as alive,
#            so every machine yielded and the watch was stranded with no link.
#            An unknown id is now stale, the bridge repairs it on the next
#            sighting, and an explicit Now Me / BT Now Me hands the device this
#            machine's current Wi-Fi (stored on its own keyed row and carried
#            over the Bluetooth link), so a watch joins the network with no key.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JSON::PP ();
use RepoSource;

my $root = repo_root();
my $network = read_file("$root/lib/JawnOS/Domain/Network.pm");
my $ble     = read_file("$root/lib/JawnOS/Domain/Ble.pm");
my $part35  = read_file("$root/lib/JawnOS/Manager/Part35.pm");
my $watch   = read_file("$root/perl/watch.pl");
my $loader  = read_file("$root/lib/JawnOS/Domain/Loader.pm");

# --- the helpers, lifted out of Network.pm -------------------------------
my ($match_src) = $network =~ /(sub ble_machine_match \{.*?\n\})/s;
my ($known_src) = $network =~ /(sub ble_homebase_known \{.*?\n\})/s;
my ($alive_src) = $network =~ /(sub ble_homebase_alive \{.*?\n\})/s;
my ($wifi_src)  = $network =~ /(sub embedded_wifi_current \{.*?\n\})/s;
my ($row_src)   = $network =~ /(sub embedded_wifi_row \{.*?\n\})/s;
my ($home_src)  = $network =~ /(sub embedded_homebase_ip \{.*?\n\})/s;
ok($match_src && $known_src && $alive_src && $wifi_src && $row_src && $home_src,
	'the six helpers are still one function each');

{
	no warnings 'redefine';
	eval $match_src; is($@, '', 'ble_machine_match compiles');
	eval $known_src; is($@, '', 'ble_homebase_known compiles');
	eval $alive_src; is($@, '', 'ble_homebase_alive compiles');
	eval $wifi_src;  is($@, '', 'embedded_wifi_current compiles');
	eval $row_src;   is($@, '', 'embedded_wifi_row compiles');
	eval $home_src;  is($@, '', 'embedded_homebase_ip compiles');
}

# The dependencies the lifted subs ask for: one device spec, this machine's id,
# the peer rows and the network helper's answer.
our $DEVICE_SPECS = {};
our $MANAGER_FILE = 'Jon Ferwerda@jawnos.Laptop';
our @REMOTE = ();
our $SIGHTING;
our $NETWORK_ANSWER;
our $NOW = 1_790_000_000_000;

sub ble_device_specs { return $DEVICE_SPECS }
sub ble_manager_file { return $MANAGER_FILE }
sub ble_homebase_sighting { return $SIGHTING }
sub ble_fallback_grace { return 900_000 }
sub ble_fallback_stop_grace { return 180_000 }
sub subs::rightNow { return $NOW }
sub decode_json { return JSON::PP::decode_json($_[0]) }
sub Manager::network_helper { return $NETWORK_ANSWER }
sub lan_address_ok {
	my ($ip) = @_;
	return 0 unless defined $ip && $ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
	return 0 if $ip =~ /^(?:0|127)\./;
	return 0 if $ip =~ /^169\.254\./;
	return 0 if $ip =~ /^192\.0\.0\./;
	return 0 if $ip =~ /^100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./;
	return 0 if $ip eq '255.255.255.255';
	return 1;
}
sub subs::same_net_test {
	my ($a, $b) = @_;
	return 'no' unless defined $a && defined $b && $a =~ /^\d+\.\d+\.\d+\.\d+$/ && $b =~ /^\d+\.\d+\.\d+\.\d+$/;
	my @a = split /\./, $a;
	my @b = split /\./, $b;
	return ($a[0] == $b[0] && $a[1] == $b[1] && $a[2] == $b[2]) ? 'yes' : 'no';
}
{ package MockRows; sub hashes { return $_[0] } }
sub subs::db_select { return bless \@REMOTE, 'MockRows' }
our @WIFI_ROWS = ();
sub subs::db_query { return bless \@WIFI_ROWS, 'MockRows' }

# --- a stale id is not a live homebase -----------------------------------
$DEVICE_SPECS = { computer => 'Jonathan Ferwerda@jawnos.Fe' };
$MANAGER_FILE = 'Jon Ferwerda@jawnos.Laptop';
@REMOTE = ({ manager_file => 'Jon Ferwerda@jawnos.Table' });
ok(!ble_homebase_known('watch', '4929592'),
	'an id no machine holds is stale, not a homebase');
is(ble_homebase_alive('watch', '4929592'), 0,
	'and it no longer blocks a takeover for ever');

$DEVICE_SPECS = { computer => 'Jon Ferwerda@jawnos.Laptop' };
ok(ble_homebase_known('watch', '4929592'), 'this machine recognizes its own id');
$DEVICE_SPECS = { computer => 'Jon Ferwerda@jawnos.Table' };
ok(ble_homebase_known('watch', '4929592'), 'it knows a peer the mesh holds');
$SIGHTING = [ $NOW - 1000, 1 ];
is(ble_homebase_alive('watch', '4929592'), 1,
	'a known homebase seen inside the grace is alive');
$SIGHTING = [ $NOW - 1_000_000, 1 ];
is(ble_homebase_alive('watch', '4929592'), 0,
	'a known homebase gone past the grace is not');
$DEVICE_SPECS = {};
is(ble_homebase_alive('watch', '4929592'), 1,
	'a record that names no machine keeps the legacy address rule');

ok(ble_machine_match('Jonathan@initial.Table', 'Jonathan@jawnos.Table'),
	'a database rename still matches');
ok(!ble_machine_match('Jonathan@jawnos.Table', 'Jon@jawnos.Table'),
	'a different person does not');
ok(!ble_machine_match('Jon@jawnos.Table', 'Jon@jawnos.Laptop'),
	'a different computer does not');

# --- this machine's current Wi-Fi ---------------------------------------
$NETWORK_ANSWER = { ok => 1, ssid => 'jawn', passphrase => 'F1r3w00d' };
is_deeply(embedded_wifi_current(), { ssid => 'jawn', password => 'F1r3w00d' },
	'a protected network is carried as the password the watch joins with');
$NETWORK_ANSWER = { ok => 1, ssid => 'open', passphrase => '' };
is_deeply(embedded_wifi_current(), { ssid => 'open', password => '' },
	'an open network is usable too');
$NETWORK_ANSWER = { ok => 1, ssid => 'jawn', passphrase => 'short' };
ok(!defined embedded_wifi_current(), 'a malformed key is refused');
$NETWORK_ANSWER = { ok => 1, ssid => "bad\nssid", passphrase => 'F1r3w00d' };
ok(!defined embedded_wifi_current(), 'a newline in the name is refused');
my $hex = 'A' x 64;
$NETWORK_ANSWER = { ok => 1, ssid => 'jawn', passphrase => $hex };
is_deeply(embedded_wifi_current(), { ssid => 'jawn', password => $hex },
	'a 64-digit hex key is accepted');
$NETWORK_ANSWER = { ok => 0, error => 'This computer is not on Wi-Fi.' };
ok(!defined embedded_wifi_current(), 'a machine off Wi-Fi hands nothing over');

# --- the stored row is read by chip, not by this machine's device class ---
@WIFI_ROWS = (
	{ value => '{"ssid":"jawn","password":"new","ap_ssid":"Pico"}' },
	{ value => '{"ssid":"jawn","password":"old"}' },
);
my ($stored, $stored_json) = embedded_wifi_row('watch', '4929592');
is($stored->{'password'}, 'new', 'the newest row on the chip key wins');
is($stored_json, '{"ssid":"jawn","password":"new","ap_ssid":"Pico"}',
	'and the raw JSON is handed back to the device');
@WIFI_ROWS = ();
is_deeply((embedded_wifi_row('watch', '4929592'))[0], {}, 'no row is an empty hash');
is((embedded_wifi_row('watch', '4929592'))[1], '{}', 'and a JSON empty object');

# --- an embedded homebase is a LAN address ------------------------------
my $nics = {
	wlo1 => { ip => '192.168.1.123' },
	tailscale0 => { ip => '100.64.0.3' },
	lo => { ip => '127.0.0.1' },
};
is(embedded_homebase_ip('', $nics), '192.168.1.123',
	'a Tailscale-first machine still hands out its LAN address');
is(embedded_homebase_ip('192.168.1.55', $nics), '192.168.1.123',
	'the NIC on the device\'s subnet wins');
my $multi = { eth0 => { ip => '10.20.0.10' }, wlo1 => { ip => '192.168.1.123' } };
is(embedded_homebase_ip('192.168.1.55', $multi), '192.168.1.123',
	'not merely the first LAN when the device named its subnet');
is(embedded_homebase_ip('', { tailscale0 => { ip => '100.64.0.3' }, lo => { ip => '127.0.0.1' } }),
	undef, 'a machine with no LAN address has none to hand over');

# --- the wiring ----------------------------------------------------------
like($network, qr/return 0 unless &ble_homebase_known\(\$edt, \$chip_id\)/,
	'ble_homebase_alive refuses a stale machine id');
like($ble, qr/my \$stale_homebase = !&ble_homebase_known\(\$edt, \$chip_id\)/,
	'the bridge recognizes a stale homebase');
like($ble, qr/return unless &ble_owns\(\$edt, \$chip_id\) \|\| \$stale_homebase/,
	'and repairs it on the next sighting');
like($ble, qr/return if !\$stale_homebase && defined \$stored_host/,
	'the matching-address shortcut does not stop a stale-id repair');

like($part35, qr/my \$lan_home = &subs::embedded_homebase_ip\(\$ip, \$address\)/,
	'now_me chooses a LAN homebase for the device');
like($part35, qr/!\&subs::lan_address_ok\(\$watch->\{'homebase'\}\)/,
	'and replaces a Tailscale or p2p homebase');
unlike($part35, qr/foreach my \$nic \( keys %\{\$address\} \)/,
	'the old first-interface loop is gone');
like($part35, qr/my \$wifi_push;.*?unless \(\$keep_pairing\).*?&subs::embedded_wifi_current\(\)/s,
	'Now Me reads this machine\'s Wi-Fi only for an explicit pairing');
like($part35, qr/setting => 'wifi', value => encode_json\(\$wifi_push\),\s*subsetting => \$chip_id/s,
	'it stores the network on the device\'s keyed wifi row');
like($part35, qr/message => \{ type => 'wifi', data => \{/,
	'and carries it over the Bluetooth link beside Now Me');

like($watch, qr/my \(undef, \$json_wifi\) = &subs::embedded_wifi_row\(\$edt, \$chip_id\)/,
	'the device\'s wifi_update reads the row keyed by its chip');
like(read_file("$root/lib/JawnOS/Manager/Part34.pm"),
	qr/my \(\$wifi\) = &subs::embedded_wifi_row\(\$edt, \$chip_id\)/,
	'the Embedded panel reads the same keyed row');
like(read_file("$root/lib/JawnOS/Controller/manager_embedded.pm"),
	qr/my \(\$wifi\) = &subs::embedded_wifi_row\(\$edt, \$chip_id\)/,
	'the USB provision reads the same keyed row');
like(read_file("$root/lib/JawnOS/Controller/manager_misc13.pm"),
	qr/setting => 'wifi', value => \$json_wifi, subsetting => \$chip_id, device => 'all'/,
	'the panel stores wifi under the house-wide key');

like($loader, qr/'JawnOS::Domain::Network' for qw\([^)]*\bembedded_wifi_current\b/,
	'Loader.pm maps embedded_wifi_current to Network.pm');
like($loader, qr/'JawnOS::Domain::Network' for qw\([^)]*\bembedded_wifi_row\b/,
	'Loader.pm maps embedded_wifi_row to Network.pm');
like($loader, qr/'JawnOS::Domain::Network' for qw\([^)]*\bble_homebase_known\b/,
	'Loader.pm maps ble_homebase_known to Network.pm');
like($loader, qr/'JawnOS::Domain::Network' for qw\([^)]*\bembedded_homebase_ip\b/,
	'Loader.pm maps embedded_homebase_ip to Network.pm');

done_testing();
