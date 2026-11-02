# tests-for: scripts/help_audit.pl
# covers:    the help auditor CLI - exit 0 on the real registry, the OK line,
#           --all listing the orphan app templates, --quiet filtering, and exit
#           1 only for hard errors

use strict;
use warnings;

use Cwd qw(abs_path getcwd);
use Data::Dumper;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

# scripts/help_audit.pl is a thin CLI over help::audit(): it buckets the
# findings, decides which sections to show, and chooses the exit code. Those
# decisions are pinned twice - once against the real registry, and once against
# a fake one in a throwaway tree, because the real tree has no hard error to
# prove that an error is what fails the run.
#
# The fake is the tested script itself, copied byte for byte, with a stub
# perl/help.pl beside it: the script chdir's to its own parent and requires
# './perl/help.pl', so the copy reads the fake registry and nothing of the
# real one.

my $root   = abs_path("$FindBin::Bin/..");
my $script = "$root/scripts/help_audit.pl";

sub run_audit {
	my ($path, @args) = @_;
	my $err  = gensym;
	my $pid  = open3(my $in, my $out, $err, $^X, $path, @args);
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	close $out;
	close $err;
	waitpid($pid, 0);
	return ($? >> 8, $stdout, $stderr);
}

# A throwaway root holding a copy of the auditor and a registry that returns
# exactly @findings. Returns the path to the copied script.
sub fake_audit {
	my (@findings) = @_;
	my $dir = tempdir(CLEANUP => 1);
	make_path("$dir/scripts", "$dir/perl");
	my $copy = "$dir/scripts/help_audit.pl";
	copy($script, $copy) or die "cannot copy the auditor: $!";

	local $Data::Dumper::Indent = 1;
	local $Data::Dumper::Terse  = 1;
	my $dump = Dumper(\@findings);
	open my $fh, '>', "$dir/perl/help.pl" or die "cannot seed the fake registry: $!";
	print $fh "package help;\nuse strict;\nmy \$findings = $dump;\nsub audit { return \@\$findings }\n1;\n";
	close $fh or die "cannot write the fake registry: $!";
	return $copy;
}

# --- the real registry ------------------------------------------------------
require "$root/perl/help.pl";

my $cwd = getcwd();
chdir $root or die "cannot enter $root: $!";
my @findings = help::audit();
chdir $cwd or die "cannot return to $cwd: $!";

my %bucket;
push @{ $bucket{ $_->[0] } }, $_ for @findings;
my $info = $bucket{'info'} || [];

{
	my ($code, $out, $err) = run_audit($script, '--quiet');
	is($code, 0, 'the real registry exits 0 (it has no hard error)')
		or diag("stderr: $err");
	like($out, qr{^Help registry OK\.$}m, 'it prints the OK line');
	like($out, qr{^ERRORS \(must fix\)$}m, '--quiet still reports the error section');
	unlike($out, qr{^WARNINGS$}m, '--quiet drops the warnings section');
	unlike($out, qr{^INFO }m, '--quiet drops the info section');

	my ($e, $s, $w, $i) = $out =~ /^(\d+) error\(s\), (\d+) stale, (\d+) warning\(s\), (\d+) info$/m;
	ok(defined $e, 'the summary line is present');
	is_deeply([ @{ $bucket{'error'} || [] } ], [], 'help::audit() finds no hard errors in the registry');
	is($e // -1, scalar @{ $bucket{'error'} || [] }, 'the error count matches help::audit()');
	is($s // -1, scalar @{ $bucket{'stale'} || [] }, 'the stale count matches help::audit()');
	is($w // -1, scalar @{ $bucket{'warn'}  || [] }, 'the warning count matches help::audit()');
	is($i // -1, scalar @$info, 'the info count matches help::audit()');
}

{
	my ($code, $out) = run_audit($script, '--all');
	is($code, 0, '--all still exits 0 when only advisory findings exist');
	like($out, qr{^INFO \(app templates with no topic\)$}m, '--all adds the info section');

	my @listed   = $out =~ /^\s+\(orphan\)\s+(templates\/apps\/\S+ has no topic)$/mg;
	my @expected = map { $_->[2] } @$info;
	cmp_ok(scalar @$info, '>', 0, 'the tree has orphan app templates for --all to list');
	is_deeply([ sort @listed ], [ sort @expected ],
		'--all lists exactly the orphans help::audit() reports, and no others');
}

# --- the exit code is about hard errors, and nothing else -------------------
my @mixed = (
	[ 'error', 'broken_link', "related 'nope' has no topic" ],
	[ 'stale', 'old_app',     'source changed since it was vetted on 2026-01-01 (2 commit(s))' ],
	[ 'warn',  'no_sources',  "no source files resolved for app 'ghost'" ],
	[ 'info',  '(orphan)',    'templates/apps/ghost.html.ep has no topic' ],
);

{
	my $fake = fake_audit(@mixed);
	my ($code, $out) = run_audit($fake);
	is($code, 1, 'one hard error exits 1');
	unlike($out, qr{Help registry OK}, 'there is no OK line while an error stands');
	like($out, qr{^ERRORS \(must fix\)$}m, 'the error section is shown');
	like($out, qr{^\s+broken_link\s+related 'nope' has no topic$}m,
		'the row names the topic and the problem');
	like($out, qr{^STALE \(source changed since vetted\)$}m, 'the stale section is shown');
	like($out, qr{^WARNINGS$}m, 'the warnings section is shown');
	unlike($out, qr{^INFO }m, 'info is withheld without --all');
	like($out, qr{^1 error\(s\), 1 stale, 1 warning\(s\), 1 info$}m, 'the summary counts every bucket');

	my $e = index($out, 'ERRORS (must fix)');
	my $s = index($out, 'STALE (source changed since vetted)');
	my $w = index($out, 'WARNINGS');
	ok($e >= 0 && $e < $s && $s < $w, 'the sections keep the severity order');

	my ($qcode, $qout) = run_audit($fake, '--quiet');
	is($qcode, 1, '--quiet still exits 1 on a hard error');
	like($qout, qr{^STALE }m, '--quiet keeps the stale section');
	unlike($qout, qr{^WARNINGS$}m, '--quiet drops warnings');
	unlike($qout, qr{^INFO }m, '--quiet drops info');
	like($qout, qr{^1 error\(s\), 1 stale, 1 warning\(s\), 1 info$}m,
		'--quiet still prints the full summary');
}

{
	my @advisory = grep { $_->[0] ne 'error' } @mixed;
	my $fake = fake_audit(@advisory);
	my ($code, $out) = run_audit($fake);
	is($code, 0, 'stale, warnings and info alone exit 0');
	like($out, qr{^Help registry OK\.$}m, 'it says the registry is OK');
	like($out, qr{^0 error\(s\), 1 stale, 1 warning\(s\), 1 info$}m,
		'the summary still counts the advisory findings');

	my ($acode, $aout) = run_audit($fake, '--all');
	is($acode, 0, '--all does not turn an advisory finding into a failure');
	like($aout, qr{^INFO \(app templates with no topic\)$}m, '--all shows the info section');
	like($aout, qr{^\s+\(orphan\)\s+templates/apps/ghost\.html\.ep has no topic$}m,
		'the orphan template is listed');
}

{
	my $fake = fake_audit();
	my ($code, $out) = run_audit($fake);
	is($code, 0, 'a clean registry exits 0');
	like($out, qr{^Help registry OK\.$}m, 'and says so');
	my @none = $out =~ /^  \(none\)$/mg;
	is(scalar @none, 3, 'the three shown sections each report (none)');
	like($out, qr{^0 error\(s\), 0 stale, 0 warning\(s\), 0 info$}m, 'the summary is all zeros');
}

done_testing();
