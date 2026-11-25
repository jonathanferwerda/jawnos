#!/usr/bin/perl
#
# tailnet_lan_rule.pl - keep this machine's own LAN out of the tailnet's route.
#
#   perl scripts/tailnet_lan_rule.pl [--print] [--install] [--remove]
#                                    [--unit-dir DIR] [--priority N]
#                                    [--prefix CIDR]...
#
# The house tailnet serves its LAN through one machine, and every node installs
# that prefix in tailscale's table 52. tailscaled's rule 5270 then sends all
# traffic for the prefix into the tunnel, including the traffic a machine that
# lives on that same LAN sends to its neighbours. The subnet router SNATs the
# reply to its own tailnet address, which a plain LAN peer cannot answer: the
# machine looks unreachable on its own wire while it is up and answering (the
# gou's re-admit, 2026-11-25, where a board could not reach the laptop).
#
# A rule ahead of 5270 puts this machine's own prefixes back on the main table.
# It changes only this machine's policy routing: no router, no other host, and
# nothing on the wire changes, so a network with machines this house does not
# own is untouched.
#
# The prefixes come from this machine's own interfaces unless --prefix says
# otherwise, so nothing here is hardwired to one house's subnet. --print is the
# default and writes nothing; --install needs root (or an explicit --unit-dir,
# which writes the unit without touching systemd).
#
# Exit codes: 0 ok, 1 bad usage or nothing to do, 2 refused (not root).

use strict;
use warnings;

use Getopt::Long ();
use Socket qw(inet_aton inet_ntoa);

my $UNIT_NAME = 'tailscale-lan-main.service';
my $DEFAULT_UNIT_DIR = '/etc/systemd/system';
# tailscaled uses 5210-5270 for its own tables; a rule below 5270 and above the
# local table wins for our prefixes without touching its fwmark rules.
my $DEFAULT_PRIORITY = 4999;

my %opt = (action => 'print', priority => $DEFAULT_PRIORITY, unit_dir => $DEFAULT_UNIT_DIR, prefix => []);
Getopt::Long::Configure('no_ignore_case');
Getopt::Long::GetOptions(
	'print'      => sub { $opt{'action'} = 'print' },
	'install'    => sub { $opt{'action'} = 'install' },
	'remove'     => sub { $opt{'action'} = 'remove' },
	'unit-dir=s' => \$opt{'unit_dir'},
	'priority=i' => \$opt{'priority'},
	'prefix=s'   => $opt{'prefix'},
	'help|h'     => \$opt{'help'},
) or usage(1);

usage(0) if $opt{'help'};

unless ($opt{'priority'} > 0 && $opt{'priority'} < 32766) {
	print STDERR "tailnet_lan_rule: --priority must be 1..32765\n";
	exit 1;
}

my @prefixes = @{ $opt{'prefix'} || [] };
@prefixes = &local_prefixes() unless @prefixes;
my @nets = &normalize_prefixes(@prefixes);
unless (@nets) {
	print STDERR "tailnet_lan_rule: no LAN prefix to keep; nothing to do\n";
	exit 1;
}

if ($opt{'action'} eq 'remove') {
	&remove_unit();
	exit 0;
}

my $body = &unit_body(\@nets, $opt{'priority'});

if ($opt{'action'} eq 'print') {
	print $body;
	exit 0;
}

&install_unit($body);
exit 0;

# ---------------------------------------------------------------------------

sub usage {
	my ($code) = @_;
	print STDERR <<'USAGE';
tailnet_lan_rule.pl [--print] [--install] [--remove]
                    [--unit-dir DIR] [--priority N] [--prefix CIDR]...
USAGE
	exit $code;
}

# This machine's own IPv4 LAN prefixes. A tunnel or a container bridge is not
# the LAN: its traffic belongs on the tunnel, not on the main table.
sub local_prefixes {
	my @out;
	my $text = '';
	if (open(my $fh, '-|', 'ip', '-4', '-o', 'addr', 'show')) {
		local $/;
		$text = <$fh> // '';
		close $fh;
	}
	foreach my $line (split /\n/, $text) {
		next unless $line =~ m{^\d+:\s+(\S+)\s+inet\s+(\d+\.\d+\.\d+\.\d+)/(\d+)(?:\s|$)};
		my ($iface, $ip, $len) = ($1, $2, $3);
		next if $iface =~ /^(?:lo|tailscale.*|tun.*|tap.*|wg.*|zt.*|ppp.*|utun.*|docker.*|veth.*|br-.*|virbr.*|cni.*|flannel.*)$/i;
		next if $len == 32 || $ip =~ /^(?:127\.|169\.254\.)/;
		push @out, "$ip/$len";
	}
	return @out;
}

# A person names an address; the rule names the network it is on.
sub normalize_prefixes {
	my (@list) = @_;
	my %seen;
	my @out;
	foreach my $entry (@list) {
		next unless defined $entry && length $entry;
		unless ($entry =~ m{^(\d{1,3}(?:\.\d{1,3}){3})(?:/(\d{1,2}))?$}) {
			print STDERR "tailnet_lan_rule: not an IPv4 prefix: $entry\n";
			exit 1;
		}
		my ($ip, $len) = ($1, defined $2 ? $2 : 32);
		my $addr = inet_aton($ip);
		unless (defined $addr && $len >= 8 && $len <= 32) {
			print STDERR "tailnet_lan_rule: not an IPv4 prefix: $entry\n";
			exit 1;
		}
		my $mask = $len >= 32 ? 0xffffffff : (0xffffffff << (32 - $len)) & 0xffffffff;
		my $net = inet_ntoa(pack('N', unpack('N', $addr) & $mask));
		my $cidr = $net . '/' . $len;
		push @out, $cidr unless $seen{$cidr}++;
	}
	return @out;
}

sub unit_body {
	my ($nets, $priority) = @_;
	my $text = <<"HEAD";
[Unit]
Description=Keep this machine's LAN on the LAN when tailscale routes it
After=tailscaled.service network-online.target
Wants=tailscaled.service network-online.target
PartOf=tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=yes
# The house tailnet serves its LAN through one machine, and every node installs
# that prefix in tailscale's table 52. Rule 5270 then sends this machine's own
# LAN traffic into the tunnel, where the subnet router SNATs the reply to its
# tailnet address and a plain LAN peer cannot answer. These rules sit ahead of
# 5270 and put the prefixes back on the main table. This machine only: no
# router, no other host, and nothing on the wire changes.
HEAD
	my @stops;
	foreach my $net ( @{$nets} ) {
		my $rule = "to $net lookup main priority $priority";
		$text .= qq{ExecStart=/bin/sh -c "ip rule del $rule 2>/dev/null; ip rule add $rule"\n};
		push @stops, qq{ExecStop=/bin/sh -c "ip rule del $rule 2>/dev/null; exit 0"\n};
	}
	$text .= join('', @stops);
	$text .= "\n[Install]\nWantedBy=multi-user.target\n";
	return $text;
}

sub install_unit {
	my ($body) = @_;
	my $custom = $opt{'unit_dir'} ne $DEFAULT_UNIT_DIR;
	unless ($< == 0 || $custom) {
		print STDERR "tailnet_lan_rule: --install needs root (or an explicit --unit-dir)\n";
		exit 2;
	}
	my $path = $opt{'unit_dir'} . '/' . $UNIT_NAME;
	unless (-d $opt{'unit_dir'}) {
		print STDERR "tailnet_lan_rule: no such directory: $opt{'unit_dir'}\n";
		exit 1;
	}
	my $fh;
	unless (open($fh, '>', $path)) {
		print STDERR "tailnet_lan_rule: cannot write $path: $!\n";
		exit 1;
	}
	print {$fh} $body;
	close $fh;
	chmod 0644, $path;
	&systemctl('daemon-reload') unless $custom;
	&systemctl('enable', '--now', $UNIT_NAME) unless $custom;
	print "tailnet_lan_rule: wrote $path\n";
	return 1;
}

sub remove_unit {
	my $custom = ($opt{'unit_dir'} ne $DEFAULT_UNIT_DIR) ? 1 : 0;
	unless ($< == 0 || $custom) {
		print STDERR "tailnet_lan_rule: --remove needs root (or an explicit --unit-dir)\n";
		exit 2;
	}
	my $path = $opt{'unit_dir'} . '/' . $UNIT_NAME;
	&systemctl('disable', '--now', $UNIT_NAME) unless $custom;
	if (-e $path) {
		unlink($path) or do {
			print STDERR "tailnet_lan_rule: cannot remove $path: $!\n";
			exit 1;
		};
		print "tailnet_lan_rule: removed $path\n";
	}
	else {
		print "tailnet_lan_rule: nothing at $path\n";
	}
	return 1;
}

sub systemctl {
	my @args = @_;
	system('systemctl', @args);
	return $? == 0 ? 1 : 0;
}
