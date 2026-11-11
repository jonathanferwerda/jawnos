# tests-for: scripts/agent_help.pl scripts/where.pl scripts/tests_for.pl .githooks/pre-commit perl/help/ templates/apps/ database/schema.sql qa/coding_night/agent-index.md
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

# --- the brief is a lookup, not a dump --------------------------------------
{
	my $text = agent_help::brief('configure');
	ok(defined $text, 'a large app has a brief');
	cmp_ok(length $text, '<', 8_000, 'the default brief stays small');
	like($text, qr/^routes \(134\)$/m, 'it counts every route');
	like($text, qr/brace form: .*means/, 'and explains the shorthand');
	like($text, qr{^  get\s+/manager/configure$}m, 'a parent route is printed whole');
	like($text, qr{^  get\s+/manager\{/configure/\{}m,
		'and a prefix shared by branches is printed once');
	like($text, qr{dns_client/\{}m, 'nested branches stay nested');
	like($text, qr/pseudonym_defaulter/,
		'a late route is still present, not truncated');
	like($text, qr{perl scripts/where\.pl <a path above>},
		'with a pointer at the single lookup');

	# --routes is the exact-route form: full rows, controller lines, no grouping.
	my @rows;
	if (open my $fh, '-|', $^X, "$root/scripts/agent_help.pl", '--routes', 'configure') {
		@rows = grep { m{^\s+(?:any|get|post)\s+/manager/} } <$fh>;
		close $fh;
	}
	cmp_ok(scalar @rows, '>', 15, '--routes prints the full row list');
	like(join('', @rows), qr{/manager/configure\s+Routes/},
		'with the module and controller line');
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

# --- the schema tier --------------------------------------------------------
{
	my $text = agent_help::schema_brief('appointments');
	ok(defined $text, 'a table has a schema brief');
	like($text, qr/^appointments - \d+ columns, \d+ index\(es\)/m, 'it counts columns and indexes');
	like($text, qr/\bserver_time\b/, 'and names a real column');
	like($text, qr/\bost\b/, 'including one that only the sync rail needs');
	like($text, qr/^  indexes: /m, 'it lists the indexes it found');
	like($text, qr/^  used by: .*\bbudget\b/m, 'and the apps that name the table');

	like(agent_help::schema_brief('not_a_table_at_all'),
		qr/not declared in database\/schema\.sql/, 'an unknown table says so');

	# The parser must find columns for every table: a table with none means the
	# CREATE TABLE body was misread, and the brief would lie about the schema.
	my $all = agent_help::schema_brief();
	my @blocks = split /\n(?=\S+ - \d+ columns)/, $all;
	my @columnless = grep { / - 0 columns/ } @blocks;
	is_deeply(\@columnless, [], 'every table in schema.sql parses at least one column');
}

# --- the hook keeps the committed index fresh --------------------------------
{
	my $hook = eval { read_file("$root/.githooks/pre-commit") } // '';
	like($hook, qr{agent_help\.pl --write-index}, 'the pre-commit hook regenerates the index');
	like($hook, qr{git diff --quiet -- lib templates public/js perl/help database/schema\.sql},
		'and only from a settled tree, so it cannot bake in uncommitted work');
}

# --- the committed index is the tree ----------------------------------------
{
	my $generated = agent_help::index_text();
	for my $section (qw(apps tables routes helpers firmware)) {
		like($generated, qr/^## \Q$section\E$/m, "the index has a $section section");
	}
	cmp_ok(length $generated, '<=', 16 * 1024, 'the index fits the nightly context budget');
	unlike($generated, qr{/home/}, 'and carries no absolute home path');
	like($generated, qr/^- appointments \(\d+\): app, timestamp/m,
		'the tables section carries the schema, not just the names');

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
