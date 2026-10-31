use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);

# The gate template asks for $webauthn_available. A render that leaves it out
# raises "Global symbol ... requires explicit package name" under strict and the
# route answers 500 - which is what /gate and /manager/leave were doing on every
# machine, so the app's "Pair this device" link landed on "This is an error!"
# and a device with no session could not pair at all (found on the tablet,
# 2026-10-31). Every `template => 'gate'` render must pass it.

my $dir = tempdir(CLEANUP => 1);
my $manager = "$FindBin::Bin/../Manager.pl";
open(my $fh, '<', $manager) or die "$manager: $!\n";
local $/;
my $text = <$fh>;
close $fh;

my @renders;
while ($text =~ /render\((.*?)\);/gs) {
	my $call = $1;
	next unless $call =~ /template\s*=>\s*'gate'/;
	my $line = 1 + (() = substr($text, 0, $-[0]) =~ /\n/g);
	push @renders, { line => $line, call => $call };
}

ok(scalar @renders >= 3, 'the gate template has several renderers') or diag("found " . scalar(@renders));

for my $r (@renders) {
	like($r->{'call'}, qr/webauthn_available\s*=>/, "gate render at line $r->{'line'} passes webauthn_available");
}

# The template really does use it - a rename would make the check above vacuous.
my $template = "$FindBin::Bin/../templates/gate.html.ep";
open(my $tf, '<', $template) or die "$template: $!\n";
my $tpl = <$tf>;
close $tf;
like($tpl, qr/\$webauthn_available/, 'gate.html.ep uses $webauthn_available');

# A signed-in session must be able to pair from the app gate, which is the page
# a reinstalled device lands on before the manager is reachable. device.js does
# that (its signed-in branch posts /manager/device/pair); without it the page
# dead-ends and the unlock button can never work.
my $app_required = "$FindBin::Bin/../templates/app_required.html.ep";
open(my $af, '<', $app_required) or die "$app_required: $!\n";
my $ar = <$af>;
close $af;
like($ar, qr{<script src="/js/device\.js}, 'app_required loads device.js so a signed-in session can pair');

done_testing();
