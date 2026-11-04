# tests-for: lib/JawnOS.pm lib/JawnOS/Controller/ lib/JawnOS/Manager.pm lib/JawnOS/Manager/ lib/JawnOS/Routes.pm lib/JawnOS/Routes/ perl/Manager.pl perl/hooks.pl public/js/device.js public/js/universal.js public/js/universal/ templates/app_required.html.ep templates/gate.html.ep
# covers:    The gate template asks for $webauthn_available.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use RepoSource;
use File::Temp qw(tempdir);

# The gate template asks for $webauthn_available. A render that leaves it out
# raises "Global symbol ... requires explicit package name" under strict and the
# route answers 500 - which is what /gate and /manager/leave were doing on every
# machine, so the app's "Pair this device" link landed on "This is an error!"
# and a device with no session could not pair at all (found on the tablet,
# 2026-10-31). Every `template => 'gate'` render must pass it.

my $dir = tempdir(CLEANUP => 1);
my $text = manager_source();
local $/;    # the reads below take a whole file

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

# The app gate steps aside only for paths in its allowlist. The peer levers
# authenticate themselves with the pinned peer signature, so each must be there -
# a missing entry answered the peer with the Gate page while the route's own
# peer_verify never ran. self_deploy (deploy_neighbours) was missing and the
# deploy silently did nothing behind Enforce.
my $hooks = "$FindBin::Bin/../perl/hooks.pl";
open(my $hf, '<', $hooks) or die "$hooks: $!\n";
my $hook = <$hf>;
close $hf;
like($hook, qr{\$path eq '/manager/configure/remote_upgrade'}, 'the pull-now lever is exempt from the app gate');
like($hook, qr{\$path eq '/manager/self_deploy'}, 'the deploy lever is exempt from the app gate');
like($hook, qr{\$path eq '/manager/president'}, 'the peer restart rail is exempt from the app gate');
# A remote QA readiness or schedule read carries no cookie on purpose, so the
# signed rail is its only proof. Missing these two entries made every machine in
# the picker answer with the Gate page, which the JSON read reports as "did not
# answer the readiness check".
like($hook, qr{\$path eq '/manager/configure/qa_device_ready'},
	'the QA readiness read is exempt from the app gate');
like($hook, qr{\$path eq '/manager/configure/qa_schedule'},
	'the QA schedule read is exempt from the app gate');
like($text, qr{GET /manager/configure/qa_device_ready\nsub action_\d+ \{.*?peer_verify}ms,
	'qa_device_ready peer_verifies the caller');
like($text, qr{GET /manager/configure/qa_schedule\nsub action_\d+ \{.*?peer_verify}ms,
	'qa_schedule peer_verifies the caller');
# universal.js is an index plus public/js/universal/ parts; the gate and the
# public layouts load them with no session, so the whole folder must pass the
# allowlist or the login gate eats the script.
like($hook, qr!\$path =~ m\{\^/js/universal/\}!,
	'the universal.js parts are exempt from the app gate');

# And the route really does verify the caller before it pulls and restarts.
# The route is registered from lib/JawnOS/Routes and its action carries the
# path as a comment, so that is what the source shows now.
like($text, qr{POST /manager/self_deploy\nsub action_\d+ \{.*?peer_verify}ms,
	'self_deploy peer_verifies the caller');

done_testing();
