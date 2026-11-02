# tests-for: scripts/agent_help.pl scripts/where.pl perl/help/ templates/apps/ qa/coding_night/agent-index.md
# covers:    The second tier of help - the generated technical brief, its
#           exhaustiveness, and the committed repository index staying current

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use File::Slurp qw(read_file);
use Test::More;

# JawnOS has two tiers of help. Tier 1 is the hand-written prose in
# perl/help/topics_*.pl (t/11 and help_audit.pl police it). Tier 2 is this
# script: facts derived from the tree, in both directions - what an app is made
# of, and what claims it. It is generated, so the two things that can go wrong
# are a brief that cannot be produced for a real name, and a committed index
# that no longer matches the tree.

my $root = "$FindBin::Bin/..";
require "$root/scripts/agent_help.pl";

# --- one brief, in full -----------------------------------------------------
{
	my $text = agent_help::brief('budget');
	ok(defined $text, 'an app has a brief');
	like($text, qr/^budget - /m, 'it names the app and its tier-1 title');
	like($text, qr/tier 1: help topic 'budget'/, 'and points at the hand-written entry');
	like($text, qr{/manager/budget}, 'the routes that reach it are derived');
	like($text, qr{templates/budget\.html\.ep}, 'so are its source files');
	like($text, qr/^sources$/m, 'the brief has its sections');
	like($text, qr/^tests that claim these files/m, 'including what pins it');
}

# --- every name has one, including the pages with no user help --------------
{
	my @names = agent_help::names();
	cmp_ok(scalar @names, '>=', 80, 'the second tier covers every topic and app page');

	my @missing = grep { !defined agent_help::brief($_) } @names;
	is_deeply(\@missing, [], 'every name resolves to a brief')
		or diag('no brief for: ' . join(', ', @missing[0 .. ($#missing > 9 ? 9 : $#missing)]));

	# The 23 pages with no topic are exactly where tier 2 has to carry the load.
	my @pages = sort map { (my $b = $_) =~ s{.*/}{}; $b =~ s{\.html\.ep$}{}; $b }
		grep { -f } glob("$root/templates/apps/*.html.ep");
	my @uncovered = grep { !defined agent_help::brief($_) } @pages;
	is_deeply(\@uncovered, [], 'an app page answers even when no topic covers it');
}

# --- a name nobody has ------------------------------------------------------
is(agent_help::brief('definitely-not-an-app'), undef, 'an unknown name has no brief');

# --- the committed index is the tree ----------------------------------------
{
	my $generated = agent_help::index_text();
	for my $section (qw(apps tables routes helpers firmware)) {
		like($generated, qr/^## \Q$section\E$/m, "the index has a $section section");
	}
	cmp_ok(length $generated, '<=', 16 * 1024, 'the index fits the nightly context budget');
	unlike($generated, qr{/home/}, 'and carries no absolute home path');

	my $committed = eval { read_file("$root/qa/coding_night/agent-index.md") };
	ok(defined $committed, 'qa/coding_night/agent-index.md is committed');

	# The index is derived from the tree, so it can only be compared with a tree
	# that is not moving: more than one agent works in this checkout, and a file
	# being edited for a commit that has not happened yet would make this fail on
	# somebody else's work. The pre-commit hook regenerates it with every commit,
	# so a clean tree - a fresh clone, a CI run, or just after a commit - is the
	# state where the comparison means something.
	my @watched = qw(lib/JawnOS/Routes lib/JawnOS/Domain lib/JawnOS/Manager
		templates public/js perl/help database/schema.sql qa/coding_night/agent-index.md);
	my @dirty;
	if (open my $fh, '-|', 'git', 'status', '--porcelain', '--', @watched) {
		@dirty = grep { /\S/ } <$fh>;
		close $fh;
	}
	SKIP: {
		skip 'the working tree has uncommitted changes; the index matches its commit', 1
			if @dirty;
		is($committed, $generated,
			'the committed index matches the tree (run perl scripts/agent_help.pl --write-index)');
	}
}

done_testing();
