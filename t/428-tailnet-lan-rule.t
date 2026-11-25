# tests-for: scripts/tailnet_lan_rule.pl
# covers:    The unit that keeps a machine's own LAN on the main routing table
#           when the tailnet serves that LAN through another machine. A board on
#           the house LAN could not reach the laptop while the laptop was up and
#           answering, because the laptop's own traffic for 192.168.1.0/24 went
#           into the tunnel and the subnet router SNATed the reply to an address
#           a plain LAN peer cannot answer (2026-11-25). The rule is written for
#           this machine only; --print writes nothing and --install is testable
#           against a temporary unit directory.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file);

my $script = "$FindBin::Bin/../scripts/tailnet_lan_rule.pl";

sub run_script {
	my (@args) = @_;
	my @quoted = map { my $a = $_; $a =~ s/'/'\\''/g; "'$a'" } @args;
	my $out = qx{$^X "$script" @quoted 2>&1};
	return ($out, $? >> 8);
}

my ($body, $rc) = run_script('--print', '--prefix', '192.168.1.0/24');
is($rc, 0, '--print exits 0');
like($body, qr/^\[Unit\]/m, 'the output is a unit file');
like($body, qr/^PartOf=tailscaled\.service$/m,
	'it restarts with the daemon that installs the routes it corrects');
like($body, qr{ExecStart=/bin/sh -c "ip rule del to 192\.168\.1\.0/24 lookup main priority 4999 2>/dev/null; ip rule add to 192\.168\.1\.0/24 lookup main priority 4999"},
	'the rule sends the LAN to the main table, removing an old copy first');
like($body, qr{ExecStop=/bin/sh -c "ip rule del to 192\.168\.1\.0/24 lookup main priority 4999 2>/dev/null},
	'shutting the unit down takes the rule away again');
like($body, qr/^WantedBy=multi-user\.target$/m, 'it comes up with the boot');
is(scalar(() = $body =~ /^ExecStart=/mg), 1, 'one rule per prefix');

# tailscaled's own rules sit at 5210-5270; a rule for our prefix has to sort
# ahead of the 5270 lookup that sends it into the tunnel.
my ($priority) = $body =~ /lookup main priority (\d+)/;
is($priority, 4999, 'the rule is placed ahead of tailscaled rule 5270');
ok($priority < 5270, 'and below the lookup that pulls the LAN into the tunnel');

# A person names an address; the rule names the network it is on.
my ($host_bits) = run_script('--print', '--prefix', '192.168.1.76/24');
like($host_bits, qr/to 192\.168\.1\.0\/24 lookup main/, 'host bits are cleared');
unlike($host_bits, qr/192\.168\.1\.76/, 'the address itself is not part of the rule');

# The same prefix twice (an interface and its alias) is one rule.
my ($twice) = run_script('--print', '--prefix', '10.20.0.0/24', '--prefix', '10.20.0.10/24');
is(scalar(() = $twice =~ /^ExecStart=.*to 10\.20\.0\.0\/24 /mg), 1,
	'a prefix named twice is written once');

# --print is the default and writes nothing.
my $dir = tempdir(CLEANUP => 1);
my ($none) = run_script('--prefix', '192.168.1.0/24');
is($none, $body, '--print is what a bare run does');
is_deeply([ glob("$dir/*") ], [], 'nothing is written to a unit directory');

# The install and remove paths, against a directory instead of systemd.
my ($installed, $install_rc) = run_script('--install', '--unit-dir', $dir, '--prefix', '192.168.1.0/24');
is($install_rc, 0, '--install into an explicit directory exits 0');
like($installed, qr/wrote \Q$dir\E\/tailscale-lan-main\.service/, 'it names the unit it wrote');
my $unit = "$dir/tailscale-lan-main.service";
ok(-f $unit, 'the unit file exists');
is((stat($unit))[2] & 07777, 0644, 'and is readable the way systemd units are');
like(read_file($unit), qr/to 192\.168\.1\.0\/24 lookup main/, 'with the rule inside it');

my ($removed, $remove_rc) = run_script('--remove', '--unit-dir', $dir);
is($remove_rc, 0, '--remove exits 0');
ok(!-e $unit, 'and the unit is gone');

# A bad prefix is refused rather than written into a unit systemd cannot run.
my ($bad, $bad_rc) = run_script('--print', '--prefix', 'not-a-subnet');
isnt($bad_rc, 0, 'a name that is not a prefix fails');
like($bad, qr/not an IPv4 prefix/, 'and says so');

done_testing();
