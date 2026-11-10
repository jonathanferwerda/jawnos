# tests-for: jawn
# covers:    the tree guard runs off the master's one-second tick - the verdict
#            is parsed by a pure function, and the tick starts the guard through
#            the runner instead of blocking the loop on a synchronous backtick.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# clean_text is the one thing verify_proof depends on.
require File::Spec->rel2abs("$FindBin::Bin/../perl/control.pl");

my $root = repo_root();
my $src = read_file("$root/jawn");

# ---------------------------------------------------------------- the verdict
# The sub is extracted and compiled: ./jawn is a script, not a module, and a
# pure parser is the one part worth pinning without a master.
my ($proof_sub) = $src =~ /(\bsub verify_proof\b.*?\n\})/s;
ok(defined $proof_sub, 'jawn defines verify_proof');
{
	my $ok = eval $proof_sub;
	is($@, '', 'verify_proof compiles against control::clean_text') or diag($@);
}

my $pass = &verify_proof(0, "checking perl\n744 file(s) pass (base HEAD)\n");
is($pass->{'ok'}, 1, 'a zero exit is a pass');
is($pass->{'summary'}, '744 file(s) pass (base HEAD)', 'the last non-empty line is the summary');

is(&verify_proof(0, "only line\n\n  \n")->{'summary'}, 'only line',
	'trailing blank lines are not the summary');

my $empty = &verify_proof(0, '');
is($empty->{'ok'}, 1, 'empty output with a zero exit is a pass');
is($empty->{'summary'}, '', 'and has no summary to quote');

my $fail = &verify_proof(1, "FAIL perl/Manager.pl\n  perl -c: syntax error\n");
is($fail->{'ok'}, 0, 'a non-zero exit is a refusal');
ok(!defined $fail->{'summary'}, 'a refusal carries no summary');
like($fail->{'report'}, qr/^FAIL perl\/Manager\.pl perl -c: syntax error$/,
	'a refusal is one flattened line');

my $empty_fail = &verify_proof(1, '');
is($empty_fail->{'ok'}, 0, 'an empty failure is still a refusal');
is($empty_fail->{'report'}, '', 'with no report to invent');

my $long = &verify_proof(1, 'x' x 5000);
cmp_ok(length($long->{'report'}), '<=', 2000, 'a failure report is bounded');

# ------------------------------------------------------- the tick stays live
# Source order, not behaviour: this is what stops the 642s sweep being put back
# inside the tick where it starved the control listener.
my ($tick) = $src =~ /(\bsub master_time_looper\b.*?\n\})/s;
ok(defined $tick, 'the master tick is present');
like($tick, qr/&verify_start\(\s*'restart'\s*\)/, 'the restart path starts the guard as an event');
like($tick, qr/verify_expire/, 'and bounds how long it may run');
unlike($tick, qr/&tree_verify\(\s*\)/, 'the tick never calls the synchronous guard');

my ($start) = $src =~ /(\bsub verify_start\b.*?\n\})/s;
ok(defined $start, 'verify_start is present');
like($start, qr/JawnOS::Platform::Runner->new/, 'the guard starts through the platform runner');
like($start, qr/conduit\(\s*\{\s*type\s*=>\s*'pipe'\s*\}\s*\)/, 'over a pipe, where stderr arrives with stdout');
like($start, qr/--all.*--quiet.*--manifest/, 'with the full sweep and its manifest');
like($src, qr/my \$verify_timeout\s*=\s*20\s*\*\s*60/, 'the bound is twenty minutes');
like($src, qr/refused\s*=>\s*'verify-timeout'/, 'a timeout is refused by name');

my ($tree) = $src =~ /(\bsub tree_verify\(\)\s*\{.*?\n\})/s;
ok(defined $tree, 'tree_verify is kept for the explicit verify command');
like($tree, qr/&verify_proof\(/, 'and parses through the same pure function');

done_testing();
