# tests-for: scripts/bake_agents_rules.pl docs/coding_agent_protocols.md
# covers:    the bake - only the protocol sections travel, and it is idempotent

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

# AGENTS.md is gitignored, so a fresh clone only has the baked file - which is
# what the Coding agent there follows. The bake must therefore carry every rule
# section and nothing else: the map's prose, and anything personal in it, must
# not ride into every machine's protocol file.

my $script = "$FindBin::Bin/../scripts/bake_agents_rules.pl";

my $SOURCE = <<'MD';
# AGENTS.md — JawnOS map

## Worktree per task

Every source write happens in a worktree; the primary checkout is read-only.

## Look it up — do not grep for it

A locator section that is helpful but not a protocol.

## RULE 1 — Stop and ask after 3 attempts

If you cannot find a file after three attempts, stop and ask.

## Run & restart

`perl scripts/restart.pl --reason "vX - why"` and never start the tree yourself.

## Crash-resilient agent work

Checkpoint the work, commit it, and start a fresh thread after a crash.

## Layout

SECRET-LOCAL-ONLY: /home/somebody/private/path

## Rules

- **Every behaviour change ships with a test.**
- **Look it up before grepping.** `perl scripts/where.pl <name>`.

## Token economy

Ask for the hunk.
MD

sub bake {
	my @args = @_;
	my $err  = gensym;
	my $pid  = open3(my $in, my $out, $err, $^X, $script, @args);
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	waitpid($pid, 0);
	return ($? >> 8, $stdout, $stderr);
}

my $dir = tempdir(CLEANUP => 1);
my $src = "$dir/AGENTS.md";
my $out = "$dir/protocols.md";
write_file($src, $SOURCE);

my ($rc) = bake('--src', $src, '--out', $out);
is($rc, 0, 'the bake runs');
ok(-s $out, 'and writes the protocol file');
my $baked = read_file($out);

# --- the protocol sections travel -------------------------------------------
for my $wanted ('RULE 1', 'Run & restart') {
	like($baked, qr/^## \Q$wanted\E\b/m, "the $wanted section is carried");
}
like($baked, qr/^## Crash-resilient agent work$/m, 'so is the crash-resilient protocol');
like($baked, qr/^## Worktree per task$/m, 'the worktree rule travels, so a fresh clone has it');
like($baked, qr/Every source write happens in a worktree/, 'with its instruction, not just its heading');
like($baked, qr/^## Rules$/m, 'and the Rules');
like($baked, qr/Every behaviour change ships with a test/, 'with their content, not just their headings');

# --- and the map does not ---------------------------------------------------
unlike($baked, qr/^## Look it up/m, 'the locator section is not protocol');
unlike($baked, qr/^## Layout$/m, 'nor the folder map');
unlike($baked, qr/^## Token economy$/m, 'nor the cost advice');
unlike($baked, qr/SECRET-LOCAL-ONLY/, 'and nothing from the sections it leaves behind');

# --- the header says where it came from and that it is generated -------------
like($baked, qr/^# Coding agent protocols$/m, 'it names itself');
like($baked, qr/^GENERATED — do not edit by hand/m, 'and says it is generated');
like($baked, qr{scripts/bake_agents_rules\.pl}, 'naming the script that builds it');

# --- a second bake is a no-op ------------------------------------------------
{
	my ($rc2, $log2) = bake('--src', $src, '--out', $out);
	is($rc2, 0, 'a second bake runs');
	is(read_file($out), $baked, 'and leaves the same bytes');
	unlike($log2, qr/wrote/, 'writing only what changed (an unchanged file is left alone)');
}

# --- no source is not an error ----------------------------------------------
{
	my $absent = "$dir/nothing.md";
	my ($rc3, $out3) = bake('--src', "$dir/missing.md", '--out', $absent);
	is($rc3, 0, 'a missing AGENTS.md is not a failure');
	ok(!-e $absent, 'and writes nothing');
}

done_testing();
