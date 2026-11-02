# tests-for: qa/coding_night/lib/CodingContext.pm qa/coding_night/lib/CodingEdit.pm qa/coding_night/agent.pl qa/coding_night/run.pl
# covers:    The 06:00 agent's context assembly: section retrieval for the deep
#           notes, the fixed prompt order, the generated repository index, the
#           reply cap and the token accounting.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../qa/coding_night/lib";
use Test::More;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);

require CodingContext;
require CodingEdit;

my $repo = abs_path("$FindBin::Bin/..");

# --- fixtures ---------------------------------------------------------------
# A deep-notes document whose sections are distinctive enough that a selected
# section is provable and an unselected one is provably absent.
my $NOTES = <<'MD';
# Deep notes

Intro prose that names nothing in particular.

## Data model

The notes table is the big one. Sync bookkeeping lives in sync_log and
sync_cursors, and every synced table carries ost and server_time.

## Soft keyboard

The soft keyboard covers the send button in the Android app, and the ime
inset is applied twice.

## Sync

A sync job runs in a loop; a stale cursor stalls the rail for an hour.

## Budget

Budget totals are wrong when a category is renamed.

## Unrelated widget

This section is about the widget gallery and its colours.
MD

sub fixture_context {
	my (%a) = @_;
	my $dir = tempdir(CLEANUP => 1);
	make_path("$dir/docs", "$dir/qa/coding_night", "$dir/perl", "$dir/database");
	write_file("$dir/AGENTS.md",
		"# AGENTS.md - fixture rules\n\n"
		. "- RULE 1 - Stop and ask after 3 attempts.\n"
		. "- Every behaviour change ships with a test.\n");
	write_file("$dir/docs/AGENTS-notes.md", $a{'notes'} // $NOTES);
	write_file("$dir/qa/README.md", "# QA suite\n\nRun the suite from this file.\n");
	write_file("$dir/database/schema.sql",
		"CREATE TABLE notes (id INTEGER PRIMARY KEY);\n"
		. "CREATE TABLE appointments (id INTEGER PRIMARY KEY);\n");
	write_file("$dir/perl/help.pl", <<'PL');
%help::topic = (
	keyboard => {
		title   => 'Soft keyboard',
		app     => 'keyboard',
		summary => 'HELP-TOPIC-SENTINEL the on-screen keyboard.',
		body    => [ 'HELP-TOPIC-SENTINEL body paragraph.' ],
		steps   => [],
	},
);
1;
PL
	if ($a{'index'}) {
		write_file("$dir/qa/coding_night/agent-index.md", <<'IDX');
# Repository index

## apps

- chat - the messaging app (templates/apps/chat.html.ep)

## routes

- GET /manager/chat -> action_chat

## helpers

- subs::chat_open

## tables

- appointments (id, start, stop)

## firmware

- jp/alarmclock
IDX
	}
	return $dir;
}

sub doc_named {
	my ($context, $rel) = @_;
	for my $doc ( @{ $context->{'documents'} || [] } ) {
		return $doc if ($doc->{'rel'} // '') eq $rel;
	}
	return undef;
}

# --- retrieval picks the sections the note is about -------------------------
my $dir = fixture_context();
my $note = 'the notes table and sync are out of step; the soft keyboard covers the send button';

my $ctx = CodingContext::assemble(context_dir => $dir, note_text => $note);
my $notes_doc = doc_named($ctx, 'docs/AGENTS-notes.md');
ok($notes_doc, 'the deep notes are in the assembled context');
my @titles = map { $_->{'title'} } @{ $notes_doc->{'sections'} || [] };
ok(grep({ $_ eq 'Data model' } @titles), 'a note naming the notes table gets the data model');
ok(grep({ $_ eq 'Sync' } @titles), 'a note naming sync gets the sync section');
ok(grep({ $_ eq 'Soft keyboard' } @titles), 'a note naming the soft keyboard gets that section');
unlike($notes_doc->{'text'}, qr/widget gallery/,
	'a section the note does not name was not sent');

# Forced sections: a note that names a table gets the data model even when a
# shorter section scores higher.
my $sync_ctx = CodingContext::assemble(
	context_dir => $dir, note_text => 'sync_log is behind');
my $sync_doc = doc_named($sync_ctx, 'docs/AGENTS-notes.md');
my @sync_titles = map { $_->{'title'} } @{ $sync_doc->{'sections'} || [] };
ok(grep({ $_ eq 'Data model' } @sync_titles),
	'a note naming a table forces the data model section');

# Determinism: the same note twice is the same bytes.
my $again = CodingContext::assemble(context_dir => $dir, note_text => $note);
is($again->{'system'}, $ctx->{'system'}, 'assembling the same note twice is byte-identical');

# --- the retrieval budget ----------------------------------------------------
my $total = 0;
$total += $_->{'bytes'} for @{ $notes_doc->{'sections'} || [] };
cmp_ok($total, '<=', CodingContext::max_notes_bytes(),
	'the selected sections fit inside the 6 KB retrieval budget');
cmp_ok(scalar @titles, '<=', CodingContext::max_notes_sections(),
	'at most four sections are sent');

# A note that names one very large section must not undo the budget.
my $big_dir = fixture_context(
	notes => "# Deep notes\n\n## Data model\n\nThe notes table.\n\n## Sync\n"
		. ("filler line for the sync rail\n" x 3000)
		. "\n## Other\n\nsomething else\n",
);
my $big = CodingContext::assemble(context_dir => $big_dir, note_text => 'the sync rail is stuck');
my $big_doc = doc_named($big, 'docs/AGENTS-notes.md');
my $big_total = 0;
$big_total += $_->{'bytes'} for @{ $big_doc->{'sections'} || [] };
cmp_ok($big_total, '<=', CodingContext::max_notes_bytes(), 'a huge section is cut to the budget');
cmp_ok($big_doc->{'kept'}, '<=', CodingContext::max_notes_bytes() + 3000,
	'the sent document is bounded even with the heading index');
ok($big_doc->{'truncated'}, 'a cut section is declared truncated');

# --- the heading index -------------------------------------------------------
like($notes_doc->{'heading_index'}, qr/Data model/, 'the heading index names a selected section');
like($notes_doc->{'heading_index'}, qr/Unrelated widget/,
	'the heading index names a section that was not sent');
like($notes_doc->{'text'}, qr/^docs\/AGENTS-notes\.md sections \(\d+\):/m,
	'the heading index is the first line of the retrieved document');
unlike($notes_doc->{'heading_index'}, qr/\n/, 'the heading index is one line');

# --- the fixed order ---------------------------------------------------------
my $system = $ctx->{'system'};
my $at_rules = index($system, 'RULE 1 - Stop and ask after 3 attempts');
my $at_notes = index($system, '## Data model');
my $at_help = index($system, 'HELP-TOPIC-SENTINEL');
ok($at_rules >= 0, 'the core rules are in the system prompt');
ok($at_notes > $at_rules, 'the retrieved sections come after the core');
is($at_help, -1, 'the help topic is not in the system prompt prefix');

# --- the rules that stop the nightly -----------------------------------------
# The two rules that failed the 2026-11-02 run: a new JS part missing from the
# index manifest (t/63) and a test without its tests-for header (t/93).
like($system, qr/\[\[js-split\]\]/, 'the prompt names the js-split manifest');
like($system, qr/# tests-for:/, 'the prompt names the tests-for header');
like($system, qr{t/63-js-parts\.t}, 'the prompt names the test the manifest fails');
like($system, qr/t\/93-test-map\.t/, 'the prompt names the test that reads the map');
like($system, qr/%manager_app_scripts/, 'the prompt names the lazy-app bundle map');
like($system, qr{lib/JawnOS/Manager/Core1_tables_hooks\.pm},
	'the prompt names the file that holds the lazy-app maps');
like($system, qr{scripts/run_tests\.pl}, 'the prompt names the fast test runner');
unlike($system, qr{/home/}, 'the new rules carry no absolute home path');

# Nothing the note changes may appear before the retrieved block: two notes
# must share a byte-identical system prefix.
my $other = CodingContext::assemble(context_dir => $dir, note_text => 'budget totals are wrong');
my ($prefix_a) = $ctx->{'system'} =~ /^(.*?## Retrieved context\n)/s;
my ($prefix_b) = $other->{'system'} =~ /^(.*?## Retrieved context\n)/s;
ok(defined $prefix_a && defined $prefix_b, 'the retrieved block is marked in the prompt');
is($prefix_a, $prefix_b, 'the core prefix is identical for a different note');

# The note comes before the help topic, and the help topic is last.
my ($note_message) = CodingContext::note_message({
	id => 'n1', title => 'soft keyboard', text => 'the soft keyboard covers the button',
});
my $help_block = CodingContext::help_block($ctx);
like($help_block, qr/HELP-TOPIC-SENTINEL/, 'the help topic text is in the help block');
my $sent = $note_message . $help_block;
my $at_note = index($sent, '## The note');
my $at_topic = index($sent, '## The help topic');
ok($at_note >= 0, 'the note block is present');
cmp_ok($at_topic, '>', $at_note, 'the help topic follows the note');
cmp_ok($at_topic, '>=', length($note_message), 'the help topic follows the whole note');

# --- the generated index: absent means today's behaviour --------------------
is($ctx->{'index'}, 0, 'no index file means no index contribution');
ok(doc_named($ctx, 'qa/README.md'), 'without an index the full QA README is sent');
unlike($system, qr/agent-index\.md/, 'no index document is invented');

# --- the generated index: present replaces the README -----------------------
my $idx_dir = fixture_context(index => 1);
my $idx_ctx = CodingContext::assemble(context_dir => $idx_dir, note_text => 'chat drops messages');
is($idx_ctx->{'index'}, 1, 'the index is consumed when it is there');
my $idx_doc = doc_named($idx_ctx, 'qa/coding_night/agent-index.md');
ok($idx_doc, 'the index is a document in the prompt');
ok(!doc_named($idx_ctx, 'qa/README.md'), 'the index replaces the full QA README');
for my $section (qw(apps routes helpers)) {
	like($idx_ctx->{'system'}, qr/^## $section$/m, "the index contributes its $section section");
}
cmp_ok($idx_doc->{'kept'}, '<=', CodingContext::max_index_bytes(), 'the index is capped at 16 KB');

# The repo line is in the core when the context directory is a checkout.
{
	my $git_ok = system('git', '-C', $idx_dir, 'init', '-q') == 0
		&& system('git', '-C', $idx_dir, 'add', '-A') == 0
		&& system('git', '-C', $idx_dir, '-c', 'user.email=t@example.test',
			'-c', 'user.name=fixture', 'commit', '-qm', 'fixture context') == 0;
	SKIP: {
		skip 'git is not available for the repo-sha check', 2 unless $git_ok;
		my $sha = CodingContext::repo_sha($idx_dir);
		like($sha // '', qr/^[0-9a-f]{4,}$/, 'the short sha is readable');
		my $with_sha = CodingContext::assemble(
			context_dir => $idx_dir, note_text => 'chat drops messages');
		like($with_sha->{'system'}, qr/^repo: \Q$sha\E$/m,
			'the core carries the repo sha on one line');
	}
}

# --- the reply cap -----------------------------------------------------------
is(CodingEdit::max_reply_bytes(), 64 * 1024, 'the reply cap is 64 KB');
my $at_cap = '{"done":true,"note":"' . ('x' x (CodingEdit::max_reply_bytes() - 24)) . '"}';
cmp_ok(CodingEdit::reply_bytes($at_cap), '<=', CodingEdit::max_reply_bytes(), 'the fixture is at or under the cap');
my ($at_cap_parsed) = CodingEdit::parse_model_response($at_cap);
ok($at_cap_parsed && $at_cap_parsed->{'done'}, 'a reply at the cap is still parsed');

my $over = '{"done":true,"note":"' . ('x' x CodingEdit::max_reply_bytes()) . '"}';
my ($over_parsed, $over_err) = CodingEdit::parse_model_response($over);
ok(!defined $over_parsed, 'a reply over 64 KB is refused');
like($over_err // '', qr/over the 65536-byte cap/, 'the refusal names the cap');

# --- token accounting --------------------------------------------------------
is(CodingContext::est_tokens(4096), 1024, 'the estimate is bytes/4');
is(CodingContext::est_tokens(0), 0, 'nothing is zero tokens');

my $account = {
	context_bytes      => 4000,
	context_est_tokens => 1000,
	sections           => [
		{ name => 'AGENTS.md', bytes => 2000, est_tokens => 500 },
		{ name => 'docs/AGENTS-notes.md', bytes => 1000, est_tokens => 250 },
	],
	reply_bytes        => [ 120, 80 ],
};
my $summary = CodingContext::context_summary($account);
like($summary, qr/^context: 4000 bytes \(~1000 est tokens\)/, 'the summary names bytes and tokens');
like($summary, qr/AGENTS\.md 2000/, 'the summary lists a section');
like($summary, qr/replies: 120\/80 bytes/, 'the summary lists the reply sizes');
unlike($summary, qr/\n/, 'the summary is one line');

# The agent's account is in the prompt it prints, and the runner reads it back.
like($ctx->{'system'}, qr/\S/, 'the assembled system prompt is not empty');
cmp_ok($ctx->{'context_bytes'}, '>', 0, 'the assembled context reports its bytes');
is($ctx->{'context_est_tokens'}, CodingContext::est_tokens($ctx->{'context_bytes'}),
	'the assembled context reports bytes/4');

# --- the run report reads the agent's own account ----------------------------
my $log_dir = tempdir(CLEANUP => 1);
my $log = "$log_dir/note-1-agent.log";
write_file($log,
	"ordinary agent output\n"
	. 'ACCOUNTING {"context_bytes":400,"context_est_tokens":100,'
	. '"sections":[{"name":"AGENTS.md","bytes":300}]}' . "\n"
	. 'REPLY {"turn":1,"bytes":120,"over_cap":0}' . "\n"
	. 'REPLY {"turn":2,"bytes":80,"over_cap":0}' . "\n");
my ($logged, $replies) = CodingContext::read_agent_log($log);
is($logged->{'context_bytes'}, 400, 'the runner reads context_bytes from the agent log');
is($logged->{'context_est_tokens'}, 100, 'the runner reads the token estimate');
is(scalar @{$replies}, 2, 'every reply is read back');
is_deeply([ map { $_->{'bytes'} } @{$replies} ], [120, 80],
	'reply bytes are recorded per turn');
my ($no_log, $no_replies) = CodingContext::read_agent_log("$log_dir/absent.log");
ok(!defined $no_log, 'a missing agent log is not an error');
is_deeply($no_replies, [], 'a missing agent log has no replies');

my $agent_src = read_file("$repo/qa/coding_night/agent.pl");
like($agent_src, qr/'ACCOUNTING ' \. JSON::PP::encode_json/, 'the agent logs the ACCOUNTING line');
like($agent_src, qr/'REPLY ' \. JSON::PP::encode_json/, 'the agent logs a REPLY line per turn');
like($agent_src, qr/CodingContext::help_block\(\$context\)/, 'the agent places the help block after the note');

my $run_src = read_file("$repo/qa/coding_night/run.pl");
like($run_src, qr/context_md\(\$report->\{'runs'\}\)/, 'report.md carries the context section');
like($run_src, qr/CodingContext::read_agent_log/, 'the runner reads the agent log back');
like($run_src, qr/\$run->\{'context_bytes'\}/, 'the run report records context_bytes');
like($run_src, qr/\$run->\{'reply_bytes'\}/, 'the run report records reply_bytes per turn');
like($run_src, qr/\$run->\{'context_sections'\}/, 'the run report records the per-section list');

done_testing();
