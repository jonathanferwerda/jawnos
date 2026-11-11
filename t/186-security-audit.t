# tests-for: scripts/security_audit.pl qa/security/allowlist.json qa/systemd/jawnos-security-audit.service qa/systemd/jawnos-security-audit.timer
# covers:    The nightly audit runs clean on this tree, reports its vectors, and
#           leaves the run where Configure -> Plat -> QA reads it.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Cwd qw(abs_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
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

# The TLS rule reports the call, not the prose around it: a comment that names
# the call is not verification being disabled.
my @tls = grep { $_->{'id'} eq 'tls.insecure' } @{$report->{'findings'}};
ok(scalar @tls > 0, 'the tree keeps its genuine insecure-TLS calls');
ok(!(grep { $_->{'evidence'} =~ m{^\s*(?://|/\*|\*|#)} } @tls),
	'no comment-only line is reported as an insecure-TLS call');

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

# A fixture repo proves the guards fire, so a rule that silently stops matching
# is caught. The audit greps git-tracked source, so the fixture is committed,
# not merely written.
my $fx = tempdir(CLEANUP => 1);
make_path("$fx/lib", "$fx/perl");
write_file("$fx/lib/Bad.pm", join "\n",
	'package Bad;',
	'my $x = $row->{\'secret\'};',
	'my $y = `echo "$x" | base64 --decode`;',
	'my $w = system("cd \"$repo\" && ls $x");',
	'my $z = subs::peer_verify($c, $rm);',
	'my $q = system("ls ".quote($x));',
	'1;',
	'');
write_file("$fx/perl/Keep.pl", "1;\n");
# One real call, four shapes of prose. Only the call is a finding, and the
# trailing comment proves a line is judged by how it starts.
write_file("$fx/perl/Tls.pl", join "\n",
	'package Tls;',
	'my $ua = Mojo::UserAgent->new;',
	'# $ua->insecure(1) is disabled in prose only',
	'// setInsecure() only clears optional CA pointers',
	'/* setInsecure() in a block comment */',
	' * setInsecure() in a continuation line',
	'$ua->insecure(1)->get($url); # a real call, trailing note or not',
	'1;',
	'');
system('git', '-C', $fx, 'init', '-q');
system('git', '-C', $fx, 'config', 'user.email', 'test@example.invalid');
system('git', '-C', $fx, 'config', 'user.name', 'JawnOS test');
system('git', '-C', $fx, 'add', '-A');
is(system('git', '-C', $fx, 'commit', '-q', '-m', 'fixture'), 0, 'the fixture repo commits');
my $fx_json = `perl "$root/scripts/security_audit.pl" --check --json --root "$fx" 2>&1`;
my $fx_report = eval { JSON::PP->new->decode($fx_json) } || {};
my %fx_ids = map { $_->{'id'} => 1 } @{ $fx_report->{'findings'} || [] };
ok($fx_ids{'perl.shell.base64'}, 'the shell-base64 rule fires on a fixture') or diag($fx_json);
ok($fx_ids{'perl.shell.double_quoted'}, 'the double-quoted-system rule fires on a fixture') or diag($fx_json);
ok($fx_ids{'perl.shell.mojo_quote'}, 'the Mojo quote rule fires on a fixture') or diag($fx_json);
ok($fx_ids{'peer.no_pin'}, 'the unpinned-peer rule fires on a fixture') or diag($fx_json);
my @fx_tls = grep { $_->{'id'} eq 'tls.insecure' } @{ $fx_report->{'findings'} || [] };
is(scalar @fx_tls, 1, 'only the insecure-TLS call is reported, not the comments about it')
	or diag($fx_json);
is($fx_tls[0]{'line'}, 7, 'the call with a trailing comment is the hit')
	or diag($fx_json);

# --- host fixtures ---------------------------------------------------------
# The SSH comment is the whole tail of the line, not its last word: an accepted
# two-word comment must not be reported, and a stranger must be.
my $hostdir = tempdir(CLEANUP => 1);
write_file("$hostdir/authorized_keys", join "\n",
	'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureKeyBlobOne jawnos-dev nightly',
	'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureKeyBlobTwo stranger@laptop',
	'');
write_file("$hostdir/ss.txt", join "\n",
	'Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process',
	'tcp   LISTEN 0      4096   0.0.0.0:39001      0.0.0.0:*',
	'tcp   LISTEN 0      4096   127.0.0.1:39002    0.0.0.0:*',
	'tcp   LISTEN 0      100    *:8022             *:*',
	'udp   UNCONN 0      0      0.0.0.0:41641      0.0.0.0:*',
	'');
my $host_json = `perl "$root/scripts/security_audit.pl" --host --json --root "$root" --authorized-keys-file "$hostdir/authorized_keys" --ss-file "$hostdir/ss.txt" 2>/dev/null`;
my $host_report = eval { JSON::PP->new->decode($host_json) } || {};
my @host_findings = @{ $host_report->{'findings'} || [] };
my @keys = grep { $_->{'id'} eq 'host.ssh.key' } @host_findings;
is(scalar @keys, 1, 'only the unknown SSH key is reported') or diag($host_json);
is($keys[0]{'evidence'}, 'stranger@laptop', 'the unknown comment is the whole tail');
ok(!(grep { $_->{'evidence'} =~ /jawnos-dev nightly/ } @keys), 'a two-word accepted comment is not reported');
my @public = grep { $_->{'id'} eq 'host.public_listener' } @host_findings;
my %public_ports = map { $_->{'evidence'} =~ /(\d+)/ ? ($1 => 1) : () } @public;
ok($public_ports{'39001'}, 'an unexpected 0.0.0.0 bind is reported');
ok(!$public_ports{'39002'}, 'a loopback bind is not reported');
ok(!$public_ports{'8022'}, 'a known static port is not reported');
ok(!$public_ports{'41641'}, 'the tailscale port is not reported');

# --- allowlist evidence pinning -----------------------------------------------
# An evidence-pinned entry names the accepted code, wherever a reflow pushed it.
# A second eval in the same file, with different code, must stay new: the pin is
# the line's text, not its number.
my $al = tempdir(CLEANUP => 1);
make_path("$al/public/js", "$al/qa/security");
write_file("$al/public/js/fixture.js", join "\n",
	"var pad = 1;",
	"var pad = 2;",
	"var pad = 3;",
	"var a = eval('one');",
	"var b = eval('two');",
	"");
write_file("$al/qa/security/allowlist.json", JSON::PP->new->canonical->pretty->encode([
	{ id => 'js.eval', path => 'public/js/fixture.js', evidence => "eval('one')", reason => 'fixture' },
]));
system('git', '-C', $al, 'init', '-q');
system('git', '-C', $al, 'config', 'user.email', 'test@example.invalid');
system('git', '-C', $al, 'config', 'user.name', 'JawnOS test');
system('git', '-C', $al, 'add', '-A');
is(system('git', '-C', $al, 'commit', '-q', '-m', 'fixture'), 0, 'the allowlist fixture repo commits');
my $al_json = `perl "$root/scripts/security_audit.pl" --check --json --root "$al" 2>&1`;
my $al_report = eval { JSON::PP->new->decode($al_json) } || {};
my @al_evals = grep { $_->{'id'} eq 'js.eval' } @{ $al_report->{'findings'} || [] };
my ($pinned) = grep { index($_->{'evidence'}, "eval('one')") >= 0 } @al_evals;
my ($loose)  = grep { index($_->{'evidence'}, "eval('two')") >= 0 } @al_evals;
ok($pinned && $pinned->{'line'} == 4, 'the accepted eval is found three lines below the file head');
ok($pinned && $pinned->{'known'}, 'a shifted finding matching the evidence stays known')
	or diag($al_json);
ok($loose && !$loose->{'known'}, 'a different eval at a new line in the same file is new')
	or diag($al_json);

# The real allowlist pins every eval it accepts by evidence, so a reflow above
# the entry cannot break the trunk and a new instance cannot inherit it.
my @eval_entries = grep { $_->{'id'} eq 'perl.eval.string' || $_->{'id'} eq 'js.eval' } @{ $allow };
ok(scalar @eval_entries >= 4, 'the accepted evals are listed');
ok(!(grep { defined $_->{'line'} } @eval_entries), 'and none is pinned by line');
ok(!(grep { !defined $_->{'evidence'} || !length $_->{'evidence'} } @eval_entries),
	'each accepted eval is pinned by evidence');
my %eval_pin = map { $_->{'evidence'} => 1 } @eval_entries;
is(scalar keys %eval_pin, scalar @eval_entries, 'no two accepted evals share one pin');
my @js = grep { $_->{'id'} eq 'js.eval' } @{$report->{'findings'}};
is(scalar @js, 2, 'the console router carries the two accepted evals');
ok(!(grep { !$_->{'known'} } @js), 'both are known through their evidence-pinned entries');

# The accepted-by-design TLS fallbacks are evidence-pinned too: the entry names
# the source line, so a reflow cannot break the trunk and a new insecure call
# cannot inherit the accepted one. Fifteen entries cover sixteen findings
# because Remote's helper line appears in two branches under one entry.
my @tls_entries = grep { $_->{'id'} eq 'tls.insecure' } @{$allow};
is(scalar @tls_entries, 15, 'the accepted insecure-TLS sites are listed');
ok(!(grep { !defined $_->{'evidence'} || !length $_->{'evidence'} } @tls_entries),
	'each accepted insecure-TLS site is pinned by evidence');
ok(!(grep { defined $_->{'line'} } @tls_entries), 'none is pinned by line');
my %tls_pin = map { (($_->{'path'} // '') . "\0" . $_->{'evidence'}) => 1 } @tls_entries;
is(scalar keys %tls_pin, scalar @tls_entries, 'no two accepted insecure-TLS sites share a path and pin');

# The run marks those sixteen known (one entry covers two findings) and leaves
# the design sites and firmware unallowed.
my @tls_known = grep { $_->{'known'} } @tls;
is(scalar @tls_known, 16, 'the accepted insecure-TLS findings are known');
my $design_path = qr{^(?:lib/JawnOS/Domain/(?:Tunnel|Lan)\.pm|lib/JawnOS/Domain/Device\.pm|lib/JawnOS/Controller/manager_configure2\.pm|perl/tunnel\.pl)$};
my $firmware_path = qr{^(?:jp|jt|jw)/};
my @design = grep { $_->{'path'} =~ $design_path } @tls;
ok(scalar @design >= 6, 'the design sites are still reported');
ok(!(grep { $_->{'known'} } @design), 'the design sites stay unallowed');
my @firmware = grep { $_->{'path'} =~ $firmware_path } @tls;
ok(scalar @firmware > 0, 'firmware insecure-TLS calls are still reported');
ok(!(grep { $_->{'known'} } @firmware), 'firmware setInsecure stays unallowed');
my @stray = grep { !$_->{'known'} && $_->{'path'} !~ $design_path && $_->{'path'} !~ $firmware_path } @tls;
is(scalar @stray, 0, 'the only unallowed insecure-TLS calls are the design sites and firmware');

done_testing();
