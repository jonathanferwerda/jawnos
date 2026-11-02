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
	"station wlan0 show") printf 'Station: wlan0\n  State                     connected\n  Connected network         jawn-test-net\n' ;;
	"known-networks list") printf '  jawn-test-net\n' ;;
	*disconnect*) exit 0 ;;
	*"station wlan0 connect "*) exit 0 ;;
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

sub run_net {
	my %opt = @_;
	local $ENV{'PATH'} = defined $opt{'path'} ? $opt{'path'} : $empty;
	local $ENV{'HOME'} = $scratch;
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
expect_error('No wireless interface found.', 'wifi_scan with no iwctl',
	args => ['wifi_scan', 'wlan0']);
expect_error('iwd is not installed.', 'wifi_connect with no iwctl',
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
		[ qw(adapters interfaces iwd present radio_powered saved) ],
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

done_testing();
