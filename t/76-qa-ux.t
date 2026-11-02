use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../qa/lib", "qa/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file);
use JSON::PP;
use Ux;
use Budget;

# l6 is the nightly UX loop: it reads the owner's JawnOS notes, seeds a fenced
# copy, and turns an attempt into a verdict. The parts that can go wrong
# quietly are the note selection, the read-only guard, and a missing model
# being scored as a pass. These checks pin those contracts.

my $qa = "$FindBin::Bin/../qa";

# --- the module compiles ------------------------------------------------------
is(system($^X, '-c', "$qa/lib/Ux.pm"), 0, 'Ux.pm compiles');

# --- the read-only guard ------------------------------------------------------
{
	my $db = '/home/jawn/jawnos/database/jawnos.db';
	like(Ux->ro_uri($db), qr/^\Qfile:$db\E\?mode=ro$/, 'the live read opens with mode=ro');
	ok(eval { Ux->refuse_live_write($db, $db); 1 } ? 0 : 1,
		'a write to the live database is refused');
	ok(eval { Ux->refuse_live_write("$db.copy", $db); 1 }, 'a copy is allowed');
	ok(eval { Ux->seed_notes($db, [], live_db => $db); 1 } ? 0 : 1,
		'seed_notes refuses the live path before it touches SQL');
}

# --- note selection: category, newest first, limit -----------------------------
my $sqlite = `command -v sqlite3 2>/dev/null`;
chomp $sqlite if defined $sqlite;
SKIP: {
	skip 'sqlite3 is not installed', 12 unless $sqlite;

	my $dir = tempdir(CLEANUP => 1);
	my $db = "$dir/notes.db";
	my @sql = (
		'create table notes (uuid varchar(255) unique, timestamp varchar(255),'
			. ' server_time varchar(255), app varchar(255), device varchar(255),'
			. ' text longtext, ost varchar(25), category varchar(255))',
		"insert into notes (uuid,timestamp,app,text,category) values"
			. " ('a-old','2026-10-01 09:00','notes','oldest JawnOS idea','jawnos')",
		"insert into notes (uuid,timestamp,app,text,category) values"
			. " ('b-new','2026-10-03 09:00','notes','newest JawnOS bug','jawnos')",
		"insert into notes (uuid,timestamp,app,text,category) values"
			. " ('c-mid','2026-10-02 09:00','notes','middle JawnOS task','jawnos')",
		"insert into notes (uuid,timestamp,app,text,category) values"
			. " ('d-journal','2026-10-04 09:00','notes','a journal thought','journal')",
		"insert into notes (uuid,timestamp,app,text,category) values"
			. " ('e-blank','2026-10-05 09:00','notes','no category means journal',NULL)",
		"insert into notes (uuid,timestamp,app,text,category) values"
			. " ('f-draft','2026-10-06 09:00','appointments','a half-typed draft',NULL)",
	);
	is(system($sqlite, $db, join(";\n", @sql) . ';'), 0, 'fixture notes are inserted');

	my $all = Ux->select_notes($db, limit => 10, category => 'jawnos');
	is(scalar @$all, 3, 'only JawnOS-category notes are selected');
	is_deeply([ map { $_->{'id'} } @$all ], [qw(b-new c-mid a-old)],
		'JawnOS notes are newest first');
	is($all->[0]->{'title'}, 'newest JawnOS bug', 'the title is the first line');

	my $two = Ux->select_notes($db, limit => 2, category => 'jawnos');
	is(scalar @$two, 2, '--limit N keeps N notes');
	is_deeply([ map { $_->{'id'} } @$two ], [qw(b-new c-mid)], 'the limit keeps the newest');

	my $journal = Ux->select_notes($db, limit => 10, category => 'journal');
	is_deeply([ map { $_->{'id'} } @$journal ], [qw(e-blank d-journal)],
		'a blank category reads as journal and a draft belongs to none');

	# The select must not mutate the file it reads.
	my $before = (stat $db)[9];
	Ux->select_notes($db, limit => 1);
	is((stat $db)[9], $before, 'a read leaves the database untouched');

	# The copy seed really lands in the copy.
	my $copy = "$dir/copy.db";
	my $rc = system($sqlite, $copy, 'create table notes (uuid varchar(255) unique,'
		. ' timestamp varchar(255), server_time varchar(255), app varchar(255),'
		. ' device varchar(255), text longtext, ost varchar(25), category varchar(255))');
	is($rc, 0, 'a writable copy exists');
	my $seeded = Ux->seed_notes($copy, $two, live_db => $db);
	is($seeded, 2, 'two notes are seeded into the QA copy');
	my $copied = Ux->select_notes($copy, limit => 10, category => 'jawnos');
	is_deeply([ map { $_->{'id'} } @$copied ], [qw(b-new c-mid)],
		'the copy carries the selected notes');
}

# --- rubric: no model is skip, never pass -------------------------------------
{
	my $no_model = Ux->rubric({ console_errors => [] });
	is_deeply([ map { $no_model->{$_}->{'verdict'} } qw(easy help works) ],
		[qw(skip skip skip)], 'no model means every question is skip');
	like($no_model->{'easy'}->{'evidence'}, qr/no model configured/,
		'the skip says why');

	my $judged = Ux->rubric(
		{ console_errors => [] },
		model => 'test-model',
		answers => {
			easy  => { verdict => 'yes', evidence => 'two clicks' },
			help  => { verdict => 'partly', evidence => 'the topic omits the chip' },
			works => { verdict => 'yes', evidence => 'the note saved' },
		});
	is($judged->{'easy'}->{'verdict'}, 'pass', 'workable maps to pass');
	is($judged->{'help'}->{'verdict'}, 'warn', 'unclear help maps to warn');
	is($judged->{'works'}->{'verdict'}, 'pass', 'a working attempt maps to pass');
	like($judged->{'help'}->{'evidence'}, qr/chip/, 'the evidence is quoted');

	# A console error is evidence the model cannot overrule.
	my $broken = Ux->rubric(
		{ console_errors => ['ReferenceError: notesReload is not defined'] },
		model => 'test-model',
		answers => { easy => 'yes', help => 'yes', works => 'yes' });
	is($broken->{'works'}->{'verdict'}, 'fail', 'a console error fails the works question');
	like($broken->{'works'}->{'evidence'}, qr/notesReload/, 'the error is quoted');

	# A model name with no answers (the call failed) is still skip.
	my $failed = Ux->rubric({}, model => 'test-model', answers => {},
		skip_reason => 'the call timed out');
	is($failed->{'works'}->{'verdict'}, 'skip', 'a failed model call does not become a pass');
}

# --- the queue is the Coding agent's handoff ----------------------------------
{
	my $entries = [
		{ id => 'n1', title => 'Save a note', overall => 'fail',
		  verdicts => {
			works => { verdict => 'fail', evidence => 'the save button did nothing' },
			help  => { verdict => 'pass', evidence => 'the topic matched' },
			easy  => { verdict => 'warn', evidence => 'hard to find' },
		  },
		  attempt => { stuck => 'save button did nothing' } },
		{ id => 'n2', title => 'No model', overall => 'skip',
		  verdicts => { works => { verdict => 'skip' }, help => { verdict => 'skip' },
			easy => { verdict => 'skip' } }, attempt => {} },
	];
	my $report = { notes => $entries,
		summary => Ux->summary($entries, model => '', limit => 2) };
	my $queue = Ux->queue($report);
	is(ref $queue->{'notes'}, 'ARRAY', 'the queue has a notes array');
	is_deeply([ map { $_->{'note_id'} } @{ $queue->{'notes'} } ], [qw(n1 n2)],
		'each note has an id');
	for my $item (@{ $queue->{'notes'} }) {
		ok(exists $item->{$_}, "queue item has $_")
			for qw(note_id title verdict suggested_next_action);
	}
	like($queue->{'notes'}->[0]->{'suggested_next_action'}, qr/fix the broken step/i,
		'a failed task names the next action');
	like($queue->{'notes'}->[1]->{'suggested_next_action'}, qr/skip, never pass/i,
		'a skipped note asks for a model');
	is($report->{'summary'}->{'ux_failures'}, 1, 'the failure count is the works-fail count');
}

# --- budgets know l6 -----------------------------------------------------------
{
	my %known = map { $_ => 1 } Budget->known_metrics();
	ok($known{'l6.ux_failures'}, 'Budget.pm knows l6.ux_failures');
	ok($known{'l6.duration_s'}, 'Budget.pm knows l6.duration_s');
	my $cfg = Budget->load("$qa/budgets.json");
	ok($cfg->{'l6'}->{'ux_failures'}, 'budgets.json carries an l6 section');

	my $m = Budget->metrics_from_report({ ux => {
		'l6.ux_failures' => 1, 'l6.duration_s' => 300,
	} });
	is($m->{'l6.ux_failures'}, 1, 'the runner report merges l6 metrics');
	my $rows = Budget->check($m, $cfg);
	my %v = map { $_->{'metric'} => $_->{'verdict'} } @$rows;
	is($v{'l6.ux_failures'}, 'warn', 'a UX failure warns until there is a baseline');
	is($v{'l6.duration_s'}, 'pass', 'a short run is inside the time limit');
}

# --- the runner accepts l6 -----------------------------------------------------
{
	my $out = `JAWNOS_QA_PLAN_ONLY=1 $^X $qa/run.pl --layers l6 2>&1`;
	is($? >> 8, 0, '--layers l6 is accepted');
	like($out, qr/layers=l6/, 'the plan names l6');
	my $src = read_file("$qa/run.pl");
	like($src, qr/l\[0-6\]/, 'the layer pattern accepts l6');
	like($src, qr/qa\/ux\/run|ux\/run/, 'the runner launches qa/ux/run');
	like($src, qr/\$report\{'ux'\}/, 'the UX metrics merge into the report');
}

# --- the scheduler and the browser probe exist --------------------------------
{
	ok(-f "$qa/systemd/jawnos-qa-ux.service", 'the UX service exists');
	ok(-f "$qa/systemd/jawnos-qa-ux.timer", 'the UX timer exists');
	like(read_file("$qa/systemd/jawnos-qa-ux.timer"), qr/OnCalendar=.*05:30/,
		'the UX timer does not ride the 04:00 job');
	like(read_file("$qa/systemd/jawnos-qa-ux.service"), qr/qa\/ux\/run/,
		'the service runs the UX runner');
	ok(-f "$qa/ux/attempt.js", 'the CDP attempt exists');
	my $node = `command -v node 2>/dev/null`;
	chomp $node if defined $node;
	SKIP: {
		skip 'node is not installed', 1 unless $node;
		is(system($node, '--check', "$qa/ux/attempt.js"), 0, 'the attempt.js parses');
	}
}

done_testing();
