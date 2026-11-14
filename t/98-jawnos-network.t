# tests-for: scripts/jawnos_network.pl
# covers:    the Network app's command set - argument validation, the JSON answer
#           each command prints, the parsers behind a fake iwctl/ip, and the
#           message a missing source produces

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;

use File::Temp qw(tempdir);
use File::Copy qw(copy);
use IPC::Open3 qw(open3);
use Mojo::JSON qw(decode_json);
use Symbol qw(gensym);

# This script is what the Network app shells out to, and every answer it makes is
# a JSON object (an operational failure is { ok => 0, error }, not an exit status).
# So the pinned facts are: the argv validation that runs before any command, the
# fields of each answer, and the shape a command's output is parsed into.
#
# Nothing here may read this machine's real network. The script finds its tools
# on PATH, so a child is run with PATH pointing at a temp directory: one case has
# an empty directory (a source that is not installed), the other has fake `iwctl`
# and `ip` that print fixed text. The only address in the fake is 192.0.2.10,
# reserved for documentation.

my $script = "$FindBin::Bin/../scripts/jawnos_network.pl";
my $scratch = tempdir(CLEANUP => 1);
my $empty   = "$scratch/empty";
my $fake    = "$scratch/bin";
mkdir $empty or die "cannot make $empty: $!";
mkdir $fake  or die "cannot make $fake: $!";
mkdir "$scratch/networkd" or die "cannot make $scratch/networkd: $!";

sub write_exe {
	my ($path, $body) = @_;
	open my $fh, '>', $path or die "cannot write $path: $!";
	print $fh "#!/bin/sh\n$body\n";
	close $fh;
	chmod 0755, $path or die "cannot chmod $path: $!";
}

write_exe("$fake/iwctl", <<'FAKE_IWCTL');
args="$*"
case "$args" in
	"adapter list") printf 'Name  Powered  Adapter\nphy0  on       phy0\n' ;;
	"station wlan0 get-networks") printf '  jawn-test-net   psk   ****\n  open-test-net   open  **\n' ;;
	"station wlan0 show") name="jawn-test-net"; if [ -n "$IWCTL_STATE" ] && [ -s "$IWCTL_STATE" ]; then IFS= read -r name < "$IWCTL_STATE"; fi; printf 'Station: wlan0\n  State                     connected\n  Connected network         %s\n' "$name" ;;
	"known-networks list") printf '  jawn-test-net\n' ;;
	*disconnect*) exit 0 ;;
	*"station wlan0 connect "*) if [ -n "$IWCTL_STATE" ]; then printf '%s' "${args#*station wlan0 connect }" > "$IWCTL_STATE"; fi; exit 0 ;;
	*forget*) exit 0 ;;
	*set-property*) exit 0 ;;
	"station wlan0 scan") exit 0 ;;
	*) exit 1 ;;
esac
FAKE_IWCTL

write_exe("$fake/ip", <<'FAKE_IP');
if [ "$*" = "-j address show" ]; then
	printf '[{"ifname":"jawn0","address":"00:11:22:33:44:55","operstate":"up","addr_info":[{"family":"inet","local":"192.0.2.10","prefixlen":24}]}]'
	exit 0
fi
exit 0
FAKE_IP

# systemd-networkd's reload/reconfigure answers are enough here: the helper
# writes the drop-in into the scratch directory and only needs a zero status.
write_exe("$fake/networkctl", q{exit 0});

sub run_net {
	my %opt = @_;
	local $ENV{'PATH'} = defined $opt{'path'} ? $opt{'path'} : $empty;
	local $ENV{'HOME'} = $scratch;
	# The fake iwctl remembers the network the last connect named, so a test can
	# use a real SSID (including one with a space) end to end.
	unlink "$scratch/iwctl-state";
	local $ENV{'IWCTL_STATE'} = "$scratch/iwctl-state";
	# Keep every static write inside the test's scratch directory. The helper
	# honours this for its systemd-networkd drop-ins.
	local $ENV{'JAWNOS_NETWORKD_DIR'} = defined $opt{'networkd'} ? $opt{'networkd'} : "$scratch/networkd";
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, $^X, $script, @{ $opt{'args'} || [] });
	print {$in} $opt{'stdin'} if defined $opt{'stdin'};
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	waitpid($pid, 0);
	return ($? >> 8, $stdout, $stderr);
}

sub read_text {
	my ($path) = @_;
	open my $fh, '<', $path or return '';
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}

# One JSON object on stdout, and the exit status is always 0: the app reads the
# answer, not the shell's verdict.
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
	my ($rc, $out, $err) = run_net(%opt);
	my $data = answer($rc, $out, $err, $what);
	is($data->{'ok'}, 0, "$what reports ok 0");
	is($data->{'error'}, $want, "$what says why");
	is_deeply([ sort keys %{$data} ], [qw(error ok)], "$what is an ok/error answer only");
	return $data;
}

# --- the dispatch -------------------------------------------------------------
{
	my ($rc, $out) = run_net('args' => ['__no_such_command__']);
	my $data = answer($rc, $out, '', 'an unknown command');
	is($data->{'error'}, 'Unknown network command.', 'an unknown command is named');
	is_deeply([ sort keys %{$data} ], [qw(error ok)], 'and answers in the error shape');
}

# the built-in ansi self-check: iwctl's colour escapes must not reach a parser
{
	my ($rc, $out) = run_net('args' => ['--test-ansi']);
	is($rc, 0, '--test-ansi passes');
	is($out, "Adapters phy0\n", 'the escape is stripped and the layout kept');
}

# --- argv validation runs before any command ---------------------------------
expect_error('The radio can only be turned on or off.', 'radio with a bad state',
	args => ['radio', 'maybe']);
expect_error('The interface can only be brought up or down.', 'interface with a bad action',
	args => ['interface', 'sideways', 'wlan0']);
expect_error('That interface name is not valid.', 'interface with a bad name',
	args => ['interface', 'up', 'bad iface']);
expect_error('That interface name is not valid.', 'connect with a bad interface',
	args => ['wifi_connect', 'bad iface', 'jawn-test-net']);
expect_error('That network name is not valid.', 'connect with an over-long ssid',
	args => ['wifi_connect', 'wlan0', 'x' x 33]);
expect_error('The passphrase must be 8 to 63 characters, or 64 hexadecimal digits.',
	'connect with a short passphrase',
	args => ['wifi_connect', 'wlan0', 'jawn-test-net'], stdin => "short\n");
expect_error('Tailscale can only be brought up or down.', 'vpn_tailscale with a bad state',
	args => ['vpn_tailscale', 'maybe']);
expect_error('The VPN action is not valid.', 'vpn_unit with a bad action',
	args => ['vpn_unit', 'restart', 'wg', 'fixture']);
expect_error('The VPN kind must be wg or openvpn.', 'vpn_unit with a bad kind',
	args => ['vpn_unit', 'start', 'l2tp', 'fixture']);
expect_error('That configuration name is not valid.', 'vpn_unit with a bad name',
	args => ['vpn_unit', 'start', 'wg', 'bad name']);
expect_error('No such VPN configuration.', 'vpn_unit naming a config that is not there',
	args => ['vpn_unit', 'start', 'wg', 'jawnos-test-no-such-vpn-4f2']);

# --- a source that is not installed ------------------------------------------
expect_error('No WiFi tool is installed (iwctl or nmcli).', 'wifi_scan with no WiFi tool',
	args => ['wifi_scan', 'wlan0']);
expect_error('No WiFi tool is installed (iwctl or nmcli).', 'wifi_connect with no WiFi tool',
	args => ['wifi_connect', 'wlan0', 'jawn-test-net'], stdin => "correcthorse\n");
expect_error('iwd is not installed.', 'wifi_disconnect with no iwctl',
	args => ['wifi_disconnect', 'wlan0']);
expect_error('iwd is not installed.', 'wifi_forget with no iwctl',
	args => ['wifi_forget', 'jawn-test-net']);
expect_error('iwd is not installed.', 'radio on with no iwctl',
	args => ['radio', 'on']);
expect_error('Tailscale is not installed.', 'vpn_tailscale up with no tailscale',
	args => ['vpn_tailscale', 'up']);
like(( run_net('args' => ['interface', 'up', 'wlan0']) )[1],
	qr/ip link set dev wlan0 up/,
	'a command that is missing is named back to the caller');

# --- the parsers, behind a fake iwctl/ip -------------------------------------
{
	my ($rc, $out) = run_net(path => $fake, args => ['status']);
	my $data = answer($rc, $out, '', 'status');

	is_deeply([ sort keys %{$data} ], [qw(interfaces ok vpn wifi)], 'status carries ok/interfaces/wifi/vpn');
	is($data->{'ok'}, 1, 'status succeeds');
	is_deeply([ sort keys %{ $data->{'wifi'} } ],
		[ qw(adapters can_connect interfaces iwd present radio_powered saved) ],
		'wifi carries the documented fields');

	my $interfaces = $data->{'interfaces'};
	is(scalar @{$interfaces}, 1, 'the ip JSON becomes one interface');
	my $if = $interfaces->[0];
	is($if->{'name'}, 'jawn0', 'with its name');
	is($if->{'state'}, 'up', 'and operstate');
	is($if->{'mac'}, '00:11:22:33:44:55', 'and address');
	is_deeply($if->{'ipv4'}, [ { address => '192.0.2.10', prefix => 24 } ],
		'and its IPv4 address/prefix');
	is_deeply($if->{'ipv6'}, [], 'with no IPv6');
	is($if->{'wireless'}, 0, 'a non-wireless interface is not called wireless');
	like($if->{'method'}, qr/\A(?:none|dhcp|static|unknown)\z/,
		'the address method is one of the documented four');
	is(defined $if->{'rx'} && defined $if->{'tx'}, 1, 'rx/tx are always present');

	my $wifi = $data->{'wifi'};
	is($wifi->{'iwd'}, 1, 'iwctl on PATH is reported as present');
	is($wifi->{'present'}, 0, 'with no wireless interface on this machine');
	is_deeply($wifi->{'interfaces'}, [], 'so the wireless list is empty');
	is_deeply($wifi->{'adapters'}, [ { name => 'phy0', powered => 1 } ],
		'adapter list is parsed into name/powered');
	is($wifi->{'radio_powered'}, 1, 'and the radio state follows the first adapter');
	is_deeply($wifi->{'saved'}, ['jawn-test-net'], 'known networks are listed');
}

{
	my ($rc, $out) = run_net(path => $fake, args => [qw(wifi_scan wlan0)]);
	my $data = answer($rc, $out, '', 'wifi_scan');
	is($data->{'ok'}, 1, 'wifi_scan succeeds');
	is($data->{'interface'}, 'wlan0', 'and names the interface it scanned');
	my $nets = $data->{'networks'};
	is(scalar @{$nets}, 2, 'both rows are read');
	is_deeply($nets->[0],
		{ ssid => 'jawn-test-net', security => 'psk', secure => 1, signal => 100, bars => 4 },
		'a secured network: full signal, four bars, secure');
	is_deeply($nets->[1],
		{ ssid => 'open-test-net', security => 'open', secure => 0, signal => 50, bars => 2 },
		'an open network: two bars, not secure');
	is_deeply([ sort keys %{ $nets->[0] } ], [qw(bars secure security signal ssid)],
		'a network row is the documented five fields');
}

{
	# A machine on NetworkManager has no iwctl at all: the Table is one, and Scan
	# used to answer "No wireless interface found." there, which is why a network
	# name with a space had to be typed by hand.
	my $nm = "$scratch/nm";
	mkdir $nm or die "cannot make $nm: $!";
	write_exe("$nm/ip", q{exit 0});
	write_exe("$nm/nmcli", <<'FAKE_NMCLI');
	if [ -n "$NM_LOG" ]; then printf '%s\n' "$*" >> "$NM_LOG"; fi
	case "$*" in
		*"--fields SSID,SECURITY,SIGNAL"*)
			printf 'jawn-test-net:WPA2:80\ntest net with space:WPA2:60\nopen-test-net::40\ncolon\\:name:WPA2:20\n' ;;
		*"--fields 802-11-wireless.ssid connection show"*) if [ -n "$NM_EXISTING" ]; then printf 'jawn-test-net\n'; fi; exit 0 ;;
		*"--fields NAME,TYPE connection show"*) if [ -n "$NM_EXISTING" ]; then printf 'Home:802-11-wireless\n'; fi; exit 0 ;;
		*"--fields NAME connection show"*) exit 0 ;;
		*"connection add"*) exit 0 ;;
		*"connection modify"*) exit 0 ;;
		*"connection up"*) exit 0 ;;
		*"802-11-wireless.ssid"*) if [ -n "$NM_EXISTING" ]; then printf 'jawn-test-net\n'; else printf '\n'; fi ;;
		*"device disconnect"*) exit 0 ;;
		*"connection delete"*) exit 0 ;;
		"radio wifi on"|"radio wifi off") exit 0 ;;
		"radio wifi") printf 'enabled\n' ;;
		*) exit 1 ;;
	esac
FAKE_NMCLI

	my ($rc, $out) = run_net(path => $nm, args => [qw(wifi_scan wlan0)]);
	my $data = answer($rc, $out, '', 'wifi_scan on a NetworkManager machine');
	is($data->{'ok'}, 1, 'the nmcli fallback scans');
	is($data->{'interface'}, 'wlan0', 'and names the interface');
	my $nets = $data->{'networks'};
	is(scalar @{$nets}, 4, 'every advertised network is read');
	my %by_ssid = map { $_->{'ssid'} => $_ } @{$nets};
	ok($by_ssid{'test net with space'}, 'a name with a space survives intact')
		or diag(join(', ', sort keys %by_ssid));
	is($by_ssid{'test net with space'}->{'signal'}, 60, 'with its signal');
	is($by_ssid{'colon:name'}->{'ssid'}, 'colon:name', 'an escaped colon in the name is unescaped');
	is($by_ssid{'open-test-net'}->{'secure'}, 0, 'an empty security field is an open network');
	is($by_ssid{'open-test-net'}->{'security'}, 'open', 'and says open');
	is($by_ssid{'jawn-test-net'}->{'secure'}, 1, 'a named security is a secured network');
	is_deeply([ sort keys %{ $nets->[0] } ], [qw(bars secure security signal ssid)],
		'the fallback answers the same five fields');
	is($nets->[0]->{'signal'}, 80, 'and sorts by signal');

	# A NetworkManager machine has no iwctl, so the radio switch and the radio
	# state must come from nmcli instead.
	{
		my (undef, $out) = run_net(path => $nm, args => [qw(radio on)]);
		my $data = eval { decode_json($out) };
		is_deeply($data, { ok => 1, powered => 1 }, 'radio on goes through nmcli and reports powered');
	}
	{
		my (undef, $out) = run_net(path => $nm, args => [qw(radio off)]);
		my $data = eval { decode_json($out) };
		is_deeply($data, { ok => 1, powered => 0 }, 'radio off goes through nmcli and reports unpowered');
	}
	expect_error('The radio can only be turned on or off.', 'radio with a bad state on a NetworkManager machine',
		path => $nm, args => ['radio', 'maybe']);
	{
		my ($rc, $out) = run_net(path => $nm, args => ['status']);
		my $data = answer($rc, $out, '', 'status on a NetworkManager machine');
		my $wifi = $data->{'wifi'};
		is($wifi->{'iwd'}, 0, 'iwd is reported absent without iwctl');
		is($wifi->{'radio_powered'}, 1, 'the radio state comes from nmcli radio wifi');
	}
	{
		local $ENV{'NM_EXISTING'} = '1';
		my (undef, $out) = run_net(path => $nm, args => ['status']);
		my $data = answer(0, $out, '', 'status with saved nmcli profiles');
		is_deeply($data->{'wifi'}->{'saved'}, ['jawn-test-net'],
			'nmcli saved networks are listed');
	}
}

{
	my (undef, $out) = run_net(path => $fake, args => [qw(wifi_disconnect wlan0)]);
	my $data = eval { decode_json($out) };
	is_deeply($data, { ok => 1, message => 'Disconnected.' }, 'wifi_disconnect answers its message');
}

{
	my (undef, $out) = run_net(path => $fake, args => [qw(wifi_forget jawn-test-net)]);
	my $data = eval { decode_json($out) };
	is_deeply($data, { ok => 1, message => 'Forgot jawn-test-net.' }, 'wifi_forget names the ssid');
}

{
	my (undef, $out) = run_net(path => $fake, args => [qw(radio on)]);
	my $data = eval { decode_json($out) };
	is_deeply($data, { ok => 1, powered => 1 }, 'radio on reports the radio as powered');
}

{
	my (undef, $out) = run_net(path => $fake, args => [qw(interface up wlan0)]);
	my $data = eval { decode_json($out) };
	is_deeply($data, { ok => 1, message => 'Interface wlan0 is up.' },
		'interface up reports the name and the state');
}

{
	# the connect path polls the station report once, then answers
	my (undef, $out) = run_net(path => $fake,
		args => ['wifi_connect', 'wlan0', 'jawn-test-net'], stdin => "correcthorse\n");
	my $data = eval { decode_json($out) };
	is_deeply($data, { ok => 1, message => 'Connected to jawn-test-net.' },
		'wifi_connect confirms the station really joined');
}

{
	my (undef, $out) = run_net(path => $fake, args => ['vpn_status']);
	my $data = eval { decode_json($out) };
	is_deeply([ sort keys %{$data} ], [qw(ok vpn)], 'vpn_status wraps its report');
	is_deeply([ sort keys %{ $data->{'vpn'} } ], [qw(openvpn tailscale wireguard)],
		'the VPN report has the three sources');
	is_deeply($data->{'vpn'}->{'tailscale'}, { present => 0 },
		'a machine without tailscale says so, and nothing else');
}

# --- the outward address ----------------------------------------------------
# Local first: the helper reads the machine's own interfaces and classifies the
# address, so a private LAN address is not called public.
my $ipbin = "$scratch/ipbin";
mkdir $ipbin or die "cannot make $ipbin: $!";
write_exe("$ipbin/ip", q{printf '[{"ifname":"wlan0","addr_info":[{"family":"inet","local":"10.0.0.5","scope":"global"}]}]'});
{
	my (undef, $out) = run_net(path => $ipbin, args => ['public_ip']);
	my $data = answer(0, $out, '', 'public_ip on a private address');
	is($data->{'behind_nat'}, 1, 'a private address is not called public');
	is($data->{'ip'}, '', 'and no address is claimed');
}
write_exe("$ipbin/ip", q{printf '[{"ifname":"eth0","addr_info":[{"family":"inet","local":"1.1.1.1","scope":"global"}]}]'});
{
	my (undef, $out) = run_net(path => $ipbin, args => ['public_ip']);
	my $data = answer(0, $out, '', 'public_ip on a public address');
	is($data->{'ip'}, '1.1.1.1', 'the interface address is returned');
	is($data->{'family'}, 'IPv4', 'and named as IPv4');
	is($data->{'source'}, 'local', 'without asking anything outside');
	is($data->{'behind_nat'}, 0, 'and it is not behind NAT');
}

# The explicit lookup is the only outbound call, and it is a different command.
my $curlbin = "$scratch/curlbin";
mkdir $curlbin or die "cannot make $curlbin: $!";
write_exe("$curlbin/curl", q{printf '198.51.100.7\n'});
{
	my (undef, $out) = run_net(path => $curlbin, args => ['public_ip_lookup']);
	my $data = answer(0, $out, '', 'public_ip_lookup');
	is($data->{'ip'}, '198.51.100.7', 'the lookup returns the outward address');
	is($data->{'source'}, 'lookup', 'and says it came from the lookup');
	is($data->{'service'}, 'curl', 'through the tool that answered');
}
write_exe("$curlbin/curl", q{printf '<html>login</html>\n'});
expect_error('the public address was not an address',
	'a captive portal page is not an address',
	path => $curlbin, args => ['public_ip_lookup']);
expect_error('the public address could not be read',
	'public_ip_lookup with no curl or wget', path => $empty, args => ['public_ip_lookup']);

# --- the connect choices -----------------------------------------------------
# A connect can carry an addressing choice and DNS servers. Every value is
# validated before any command runs, so a mistyped field is named back.
expect_error('The addressing method is DHCP or static.', 'connect with an unknown method',
	args => ['wifi_connect', 'wlan0', 'jawn-test-net', 'sometimes'], stdin => '');
expect_error('The address is not a valid IPv4 address.', 'static with no address',
	args => ['wifi_connect', 'wlan0', 'jawn-test-net', 'static', '', '24'], stdin => '');
expect_error('The address is not a valid IPv4 address.', 'static with an out-of-range address',
	args => ['wifi_connect', 'wlan0', 'jawn-test-net', 'static', '192.0.2.300', '24'], stdin => '');
expect_error('The prefix length must be 1 to 32.', 'static with a bad prefix',
	args => ['wifi_connect', 'wlan0', 'jawn-test-net', 'static', '192.0.2.50', '33'], stdin => '');
expect_error('The gateway is not a valid IPv4 address.', 'static with a bad gateway',
	args => ['wifi_connect', 'wlan0', 'jawn-test-net', 'static', '192.0.2.50', '24', 'router'], stdin => '');
expect_error('The DNS server is not a valid address.', 'connect with a hostname for DNS',
	args => ['wifi_connect', 'wlan0', 'jawn-test-net', 'dhcp', '', '', '', 'one.one.one.one'], stdin => '');
expect_error('At most four DNS servers can be given.', 'connect with five DNS servers',
	args => ['wifi_connect', 'wlan0', 'jawn-test-net', 'dhcp', '', '', '', '1.1.1.1,8.8.8.8,9.9.9.9,4.4.4.4,2.2.2.2'], stdin => '');

# A static address and DNS go into a systemd-networkd drop-in scoped to this
# interface and SSID, so the other networks keep their DHCP.
{
	my (undef, $out) = run_net(path => $fake,
		args => ['wifi_connect', 'wlan0', 'jawn-test-net', 'static', '192.0.2.50', '24', '192.0.2.1', '1.1.1.1,8.8.8.8'],
		stdin => "correcthorse\n");
	my $data = answer(0, $out, '', 'wifi_connect with a static address');
	is($data->{'ok'}, 1, 'the static connect succeeds');
	is($data->{'message'},
		'Connected to jawn-test-net. Address 192.0.2.50/24, gateway 192.0.2.1, DNS 1.1.1.1, 8.8.8.8.',
		'and names the address, gateway and DNS it applied');
	my @files = glob("$scratch/networkd/*.network");
	is(scalar @files, 1, 'one drop-in is written');
	my $unit = read_text($files[0]);
	like($unit, qr/^\[Match\]$/m, 'it starts with a Match section');
	like($unit, qr/^Name=wlan0$/m, 'the interface is named');
	like($unit, qr/^SSID="jawn-test-net"$/m, 'and the network it belongs to');
	like($unit, qr/^DHCP=no$/m, 'DHCP is off');
	like($unit, qr/^Address=192\.0\.2\.50\/24$/m, 'the address is written');
	like($unit, qr/^Gateway=192\.0\.2\.1$/m, 'with its gateway');
	like($unit, qr/^DNS=1\.1\.1\.1 8\.8\.8\.8$/m, 'and both DNS servers');
	unlike($unit, qr/^\[DHCP\]$/m, 'a static unit has no DHCP section');
}

# A name with a space is quoted, because the Match parser splits unquoted
# whitespace.
{
	my (undef, $out) = run_net(path => $fake,
		args => ['wifi_connect', 'wlan0', 'my home net', 'static', '192.0.2.60', '24', '', ''],
		stdin => "correcthorse\n");
	my $data = answer(0, $out, '', 'static connect to a name with a space');
	is($data->{'ok'}, 1, 'a name with a space connects');
	my ($unit) = grep { read_text($_) =~ /my home net/ } glob("$scratch/networkd/*.network");
	ok($unit, 'its drop-in is written');
	like(read_text($unit), qr/^SSID="my home net"$/m, 'and the name is quoted');
}

# DHCP with a chosen DNS server keeps the lease but replaces its resolver.
{
	my (undef, $out) = run_net(path => $fake,
		args => ['wifi_connect', 'wlan0', 'jawn-test-net', 'dhcp', '', '', '', '2606:4700:4700::1111'],
		stdin => "correcthorse\n");
	my $data = answer(0, $out, '', 'wifi_connect with DHCP and a DNS server');
	is($data->{'ok'}, 1, 'the DHCP connect succeeds');
	is($data->{'message'}, 'Connected to jawn-test-net. DNS 2606:4700:4700::1111.',
		'and names the DNS server it applied');
	my @files = grep { read_text($_) =~ /^SSID="jawn-test-net"$/m } glob("$scratch/networkd/*.network");
	is(scalar @files, 1, 'the drop-in is rewritten');
	my $unit = read_text($files[0]);
	like($unit, qr/^DHCP=yes$/m, 'DHCP stays on');
	like($unit, qr/^DNS=2606:4700:4700::1111$/m, 'the DNS server is written');
	like($unit, qr/^UseDNS=no$/m, 'and the lease DNS is ignored');
	unlike($unit, qr/^Address=/m, 'there is no static address');
}

# Choosing plain DHCP again removes the drop-in, returning the interface to
# the image's own 20-wireless.network.
{
	my (undef, $out) = run_net(path => $fake,
		args => ['wifi_connect', 'wlan0', 'jawn-test-net'], stdin => "correcthorse\n");
	my $data = answer(0, $out, '', 'wifi_connect returning to DHCP');
	is($data->{'message'}, 'Connected to jawn-test-net.', 'plain DHCP keeps the short message');
	my @files = grep { read_text($_) =~ /^SSID="jawn-test-net"$/m } glob("$scratch/networkd/*.network");
	is(scalar @files, 0, 'the old drop-in is removed');
}

# A machine without systemd-networkd can still take the address and DNS now,
# through ip and resolvectl.
{
	my $plain = "$scratch/plain";
	mkdir $plain or die "cannot make $plain: $!";
	copy("$fake/iwctl", "$plain/iwctl") or die "cannot copy iwctl: $!";
	copy("$fake/ip", "$plain/ip") or die "cannot copy ip: $!";
	chmod 0755, "$plain/iwctl", "$plain/ip";
	write_exe("$plain/resolvectl", q{exit 0});
	my (undef, $out) = run_net(path => $plain,
		args => ['wifi_connect', 'wlan0', 'jawn-test-net', 'static', '192.0.2.50', '24', '192.0.2.1', '1.1.1.1'],
		stdin => "correcthorse\n");
	my $data = answer(0, $out, '', 'static connect without networkd');
	is($data->{'ok'}, 1, 'the fallback connect succeeds');
	like($data->{'message'}, qr/Address 192\.0\.2\.50\/24/, 'and reports the address it set');
}

# --- NetworkManager: the same choices in the profile itself -------------------
{
	my $nm = "$scratch/nm";
	my $log = "$scratch/nm-dhcp.log";
	unlink $log;
	local $ENV{'NM_LOG'} = $log;
	my (undef, $out) = run_net(path => $nm,
		args => ['wifi_connect', 'wlan0', 'jawn-test-net', 'dhcp', '', '', '', ''],
		stdin => "correcthorse\n");
	my $data = answer(0, $out, '', 'nmcli DHCP connect');
	is($data->{'ok'}, 1, 'the connection is created');
	is($data->{'message'}, 'Connected to jawn-test-net.', 'and reported');
	my $calls = read_text($log);
	like($calls, qr/connection add type wifi con-name jawnos-wifi-\w+ ifname wlan0 ssid jawn-test-net/,
		'a profile is created for the SSID');
	like($calls, qr/wifi-sec\.key-mgmt wpa-psk wifi-sec\.psk correcthorse/,
		'with the passphrase');
	like($calls, qr/ipv4\.method auto/, 'DHCP is automatic');
	like($calls, qr/ipv4\.ignore-auto-dns no/, 'and the lease DNS is kept');
	like($calls, qr/connection up jawnos-wifi-/, 'the profile is activated');
}
{
	my $nm = "$scratch/nm";
	my $log = "$scratch/nm-static.log";
	unlink $log;
	local $ENV{'NM_LOG'} = $log;
	my (undef, $out) = run_net(path => $nm,
		args => ['wifi_connect', 'wlan0', 'jawn-test-net', 'static', '192.0.2.50', '24', '192.0.2.1', '1.1.1.1'],
		stdin => "correcthorse\n");
	my $data = answer(0, $out, '', 'nmcli static connect');
	is($data->{'ok'}, 1, 'the static connect succeeds');
	is($data->{'message'},
		'Connected to jawn-test-net. Address 192.0.2.50/24, gateway 192.0.2.1, DNS 1.1.1.1.',
		'and names the chosen address and DNS');
	my $calls = read_text($log);
	like($calls, qr/ipv4\.method manual/, 'the method is manual');
	like($calls, qr/ipv4\.addresses 192\.0\.2\.50\/24/, 'the address is set');
	like($calls, qr/ipv4\.gateway 192\.0\.2\.1/, 'the gateway is set');
	like($calls, qr/ipv4\.dns 1\.1\.1\.1/, 'the DNS server is set');
	like($calls, qr/ipv4\.ignore-auto-dns yes/, 'and the lease DNS is ignored');
}
{
	my $nm = "$scratch/nm";
	my $log = "$scratch/nm-existing.log";
	unlink $log;
	local $ENV{'NM_LOG'} = $log;
	local $ENV{'NM_EXISTING'} = '1';
	my (undef, $out) = run_net(path => $nm,
		args => ['wifi_connect', 'wlan0', 'jawn-test-net', 'dhcp', '', '', '', ''],
		stdin => "");
	my $data = answer(0, $out, '', 'nmcli connect to a saved profile');
	is($data->{'ok'}, 1, 'the saved profile connects');
	my $calls = read_text($log);
	unlike($calls, qr/connection add/, 'no second profile is created');
	like($calls, qr/connection modify Home/, 'the existing profile is modified');
	unlike($calls, qr/wifi-sec\.key-mgmt/, 'its saved passphrase is left alone');
	like($calls, qr/connection up Home/, 'and it is activated');
}
{
	my $nm = "$scratch/nm";
	my (undef, $out) = run_net(path => $nm, args => [qw(wifi_disconnect wlan0)]);
	is_deeply(eval { decode_json($out) }, { ok => 1, message => 'Disconnected.' },
		'wifi_disconnect works through nmcli');
	(undef, $out) = run_net(path => $nm, args => ['wifi_forget', 'jawn-test-net']);
	is_deeply(eval { decode_json($out) }, { ok => 1, message => 'Forgot jawn-test-net.' },
		'wifi_forget removes an nmcli profile');
}
{
	my $nm = "$scratch/nm";
	my $log = "$scratch/nm-forget.log";
	unlink $log;
	local $ENV{'NM_LOG'} = $log;
	local $ENV{'NM_EXISTING'} = '1';
	my (undef, $out) = run_net(path => $nm, args => ['wifi_forget', 'jawn-test-net']);
	my $data = answer(0, $out, '', 'wifi_forget on a named profile');
	is($data->{'ok'}, 1, 'the named profile is forgotten');
	like(read_text($log), qr/connection delete Home/, 'the profile that owns the SSID is deleted');
}

done_testing();
