# tests-for: scripts/security_audit.pl qa/security/allowlist.json qa/systemd/jawnos-security-audit.service qa/systemd/jawnos-security-audit.timer
# covers:    The nightly audit runs clean on this tree and reports its vectors.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Cwd qw(abs_path);
use File::Slurp qw(read_file);
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

my $allow_text = read_file("$root/qa/security/allowlist.json");
my $allow = eval { JSON::PP->new->decode($allow_text) };
ok(ref $allow eq 'ARRAY' && scalar @{$allow} > 0, 'the allowlist is a JSON list');
ok(-e "$root/qa/systemd/jawnos-security-audit.service", 'the service unit is present');
ok(-e "$root/qa/systemd/jawnos-security-audit.timer", 'the timer unit is present');
my $timer = read_file("$root/qa/systemd/jawnos-security-audit.timer");
like($timer, qr/04:15:00/, 'the timer runs nightly');
my $unit = read_file("$root/qa/systemd/jawnos-security-audit.service");
like($unit, qr/security_audit\.pl --write-report/,
	'the unit runs the audit and writes a report');

done_testing();
