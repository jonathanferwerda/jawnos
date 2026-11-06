# tests-for: scripts/security_audit.pl qa/security/allowlist.json qa/systemd/jawnos-security-audit.service qa/systemd/jawnos-security-audit.timer
# covers:    The nightly audit runs clean on this tree, reports its vectors, and
#           leaves the run where Configure -> Plat -> QA reads it.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Cwd qw(abs_path);
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use JSON::PP;

my $root = abs_path("$FindBin::Bin/..");

my $json = `perl "$root/scripts/security_audit.pl" --check --json --root "$root" 2>&1`;
my $rc = $? >> 8;
my $report = eval { JSON::PP->new->decode($json) };
ok($report, 'the audit emits a JSON report') or diag($json);
is($rc, 0, 'no new finding at or above high');
is($report->{'summary'}{'new_fail'}, 0, 'the summary reports no failing finding');
ok($report->{'summary'}{'ok'}, 'the summary is ok');
ok(ref $report->{'findings'} eq 'ARRAY' && scalar @{$report->{'findings'}} > 0,
	'it reports the vectors it checked');

my @legacy = grep { $_->{'id'} eq 'perl.console.string' } @{$report->{'findings'}};
is(scalar @legacy, 0, 'no console send is a JS string any more');

my $allow_text = read_file("$root/qa/security/allowlist.json");
my $allow = eval { JSON::PP->new->decode($allow_text) };
ok(ref $allow eq 'ARRAY' && scalar @{$allow} > 0, 'the allowlist is a JSON list');

# The units put the audit in the QA lane: the same device gate and the same
# writable root as the rest of the nightly, so its report shows in the panel.
ok(-e "$root/qa/systemd/jawnos-security-audit.service", 'the service unit is present');
ok(-e "$root/qa/systemd/jawnos-security-audit.timer", 'the timer unit is present');
my $timer = read_file("$root/qa/systemd/jawnos-security-audit.timer");
like($timer, qr/04:45:00/, 'the timer runs nightly');
my $unit = read_file("$root/qa/systemd/jawnos-security-audit.service");
like($unit, qr/security_audit\.pl --write-report/, 'the unit runs the audit and writes a report');
like($unit, qr/^User=jawn$/m, 'the audit runs as the house user, not root');
like($unit, qr/JAWNOS_QA_ROOT=/, 'the unit names the QA root');
like($unit, qr/ExecCondition=.*device_target\.pl/, 'the unit is gated by the QA nightly choice');
unlike($unit, qr/^ReadWritePaths=\/root/m, 'it no longer writes to a root-only directory');

# --write-report leaves the run under the QA root, in the shape the panel reads.
my $qa = tempdir(CLEANUP => 1);
local $ENV{'JAWNOS_QA_ROOT'} = $qa;
system('perl', "$root/scripts/security_audit.pl", '--check', '--write-report', '--root', $root);
is($? >> 8, 0, 'the writing run exits clean');
my ($dir) = glob("$qa/reports/security/*");
ok($dir && -e "$dir/report.json" && -e "$dir/status.txt", 'report.json and status.txt land in the QA root')
	or diag("no report under $qa/reports/security");
SKIP: {
	skip 'no report to read', 4 unless $dir && -e "$dir/report.json";
	my $doc = eval { JSON::PP->new->decode(scalar read_file("$dir/report.json")) } || {};
	is($doc->{'kind'}, 'security', 'the report is the security kind');
	is($doc->{'schedule'}, 'nightly', 'and says it is nightly');
	is(scalar read_file("$dir/status.txt"), "ok\n", 'a clean run writes the ok status');
	is($doc->{'sections'}[0]{'title'}, 'Findings', 'it carries the findings table the panel renders');
}

done_testing();
