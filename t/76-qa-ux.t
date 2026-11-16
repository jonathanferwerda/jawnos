# tests-for: qa/budgets.json qa/lib/ qa/run.pl qa/systemd/jawnos-qa-ux.service qa/systemd/jawnos-qa-ux.timer qa/ux/attempt.js qa/ux/run
# covers:    l6 is the nightly UX loop: it reads the owner's JawnOS notes, seeds a fenced copy, and turns an attempt into a...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../qa/lib", "qa/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);
use JSON::PP;
use Ux;
use Node;
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

# --- node: the CDP scripts need a node with a global WebSocket ---------------
{
	local $ENV{'JAWNOS_NODE'} = '/tmp/qa-ux-first-node';
	local $ENV{'HOME'} = '/tmp/qa-ux-home';
	my @c = Node::candidates();
	is($c[0], '/tmp/qa-ux-first-node', 'JAWNOS_NODE is the first candidate');
	is($c[1], '/tmp/qa-ux-home/.local/opt/node/bin/node', 'the local node is next');
	my $on_path = `command -v node 2>/dev/null`;
	chomp $on_path if defined $on_path;
	if (defined $on_path && length $on_path) {
		is($c[2], $on_path, 'the PATH node is the last candidate');
	}
	else {
		is(scalar @c, 2, 'with no node on PATH there are two candidates');
	}
}
{
	# A systemd unit's PATH answers /usr/bin/node (v20, no global WebSocket);
	# the box's own node is newer. Only a box with no node at all may skip.
	my @real = Node::candidates();
	SKIP: {
		skip 'no node is installed on this box; the CDP attempt cannot run', 2
			unless @real;
		my $node = Node::resolve();
		ok($node, 'a node that can open a WebSocket is resolved');
		if ($node) {
			is(system($node->{'command'}, @{ $node->{'args'} }, '-e',
				'process.exit(typeof WebSocket === "function" ? 0 : 1)'), 0,
				'the resolved node passes the capability check');
		}
		else {
			fail('no node candidate has a global WebSocket (set JAWNOS_NODE to a newer node)');
		}
	}
}
{
	my $ux = read_file("$qa/lib/Ux.pm");
	like($ux, qr/Node::resolve\(\)/, 'Ux.pm asks the shared resolver for node');
	unlike($ux, qr/_which\(\s*'node'\s*\)/,
		'Ux.pm no longer takes whatever node PATH answers');
	my $ui = read_file("$qa/lib/Ui.pm");
	like($ui, qr/Node::resolve\(\)/, 'Ui.pm asks the shared resolver for node');
	unlike($ui, qr{'timeout',\s*'150',\s*'node'}, 'Ui.pm no longer runs bare node');
}

# --- note selection: category, newest first, limit -----------------------------
my $sqlite = `command -v sqlite3 2>/dev/null`;
chomp $sqlite if defined $sqlite;
SKIP: {
	skip 'sqlite3 is not installed', 16 unless $sqlite;

	my $dir = tempdir(CLEANUP => 1);
	my $db = "$dir/notes.db";
	my @sql = (
		'create table notes (uuid varchar(255) unique, timestamp varchar(255),'
			. ' server_time varchar(255), app varchar(255), device varchar(255),'
			. ' text longtext, ost varchar(25), category varchar(255), status varchar(255))',
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
		# The queue is open work: a note the nightlies filed, a finished one and
		# a tombstone must never be selected, however new they are.
		"insert into notes (uuid,timestamp,app,text,category,status) values"
			. " ('g-completed','2026-10-07 09:00','notes','a finished JawnOS task','jawnos','completed')",
		"insert into notes (uuid,timestamp,app,text,category,status,ost) values"
			. " ('h-tombstone','2026-10-08 09:00','notes','a deleted JawnOS thought','jawnos','open','deleting')",
		"insert into notes (uuid,timestamp,app,text,category,status) values"
			. " ('i-failed','2026-10-09 09:00','notes','Nightly failed: the UX loop died','jawnos','open')",
		"insert into notes (uuid,timestamp,app,text,category,status) values"
			. " ('j-report','2026-10-10 09:00','notes','# Nightly UX report: 3 notes, 0 failures','jawnos','open')",
		"insert into notes (uuid,timestamp,app,text,category,status) values"
			. " ('k-open','2026-09-30 09:00','notes','an older still-open JawnOS task','jawnos','open')",
	);
	is(system($sqlite, $db, join(";\n", @sql) . ';'), 0, 'fixture notes are inserted');

	my $all = Ux->select_notes($db, limit => 10, category => 'jawnos');
	is(scalar @$all, 4, 'only the four open, hand-written JawnOS notes are selected');
	is_deeply([ map { $_->{'id'} } @$all ], [qw(b-new c-mid a-old k-open)],
		'JawnOS notes are newest first');
	is($all->[0]->{'title'}, 'newest JawnOS bug', 'the title is the first line');
	is($all->[3]->{'status'}, 'open', 'the queue carries the status column');

	my %selected = map { $_->{'id'} => 1 } @$all;
	for my $gone (qw(g-completed h-tombstone i-failed j-report)) {
		ok(!$selected{$gone}, "$gone is not a queue item");
	}

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

# --- the filed report must be this run's -------------------------------------
{
	my $dir = tempdir(CLEANUP => 1);
	my $md = "$dir/ux-report.md";
	my $json = "$dir/report.json";
	my $started = time - 60;

	write_file($json, JSON::PP->new->canonical->encode({ run_started => 1000 }));
	write_file($md, "# Nightly UX report\nold\n");
	utime($started - 3600, $started - 3600, $md);

	my ($text, $why) = Ux->handbook_report($dir, status => 0, started => $started);
	ok(!defined $text, 'a stale report is not filed even when the child exits 0');
	like($why, qr/older than this run/, 'the reason names the staleness');

	write_file($md, "# Nightly UX report\nnew\n");
	($text, $why) = Ux->handbook_report($dir, status => 255, started => $started);
	ok(!defined $text, 'a failed child files nothing');
	like($why, qr/exited 255/, 'the reason names the child status');

	($text, $why) = Ux->handbook_report($dir, status => 0, started => $started);
	is($text, "# Nightly UX report\nnew\n", 'a fresh report from a clean child is filed');

	# The report's own start time also proves freshness when mtime is unreliable.
	utime($started - 3600, $started - 3600, $md);
	write_file($json, JSON::PP->new->canonical->encode({ run_started => $started + 1 }));
	($text) = Ux->handbook_report($dir, status => 0, started => $started);
	ok(defined $text, "the report's own start time is also proof");
}

# --- the panel document -------------------------------------------------------
{
	my $dir = tempdir(CLEANUP => 1);
	my $entries = [ {
		id => 'n1', title => 'Save a note', overall => 'fail',
		verdicts => {
			easy  => { verdict => 'warn' },
			help  => { verdict => 'pass' },
			works => { verdict => 'fail' },
		},
	} ];
	my $path = Ux->panel_table("$dir/ux-panel.tsv", $entries);
	ok($path && -f $path, 'the panel writes a TSV');
	my $tsv = read_file($path);
	like($tsv, qr/^Note\tVerdict\tOverall\n/, 'the columns are Note, Verdict, Overall');
	like($tsv, qr/^Save a note\teasy=warn help=pass works=fail\tfail$/m,
		'a row carries the three verdicts and the overall');

	is(Ux->handbook_category({ notes => $entries }), 'journal',
		'the UX summary is filed as a Journal note, never a JawnOS queue item');
	is(Ux->handbook_category({}), 'journal', 'a run with no notes is a Journal note too');
}

# --- the parent assembles the judgement from the child's raw attempts --------
{
	my $notes = [ {
		id => 'n1', title => 'Save a note', text => 'save it',
		timestamp => '2026-10-01 09:00', category => 'jawnos',
	} ];
	my $attempts = [ {
		id => 'n1', steps => ['notes', 'save'], console_errors => [],
		stuck => '', probe => { title => 'Notes', noteVisible => 1 },
	} ];
	my @asked;
	my $report = Ux->assemble_report($notes, $attempts,
		model => 'test-model', limit => 3,
		live_db => '/tmp/live.db', live_read_only => 1, run_started => 1234,
		model_call => sub {
			push @asked, [@_];
			return ('{"easy":"yes","help":"yes","works":"yes"}', undef);
		});
	is(ref $report, 'HASH', 'assemble_report returns a report');
	is(scalar @asked, 1, 'the injected model is asked once per note');
	is($report->{'notes'}->[0]->{'overall'}, 'pass', 'a passing answer becomes a pass');
	is($report->{'summary'}->{'verdicts'}->{'pass'}, 1, 'the summary counts the pass');
	is($report->{'live_db'}, '/tmp/live.db', 'the live db is carried into the report');
	is($report->{'run_started'}, 1234, 'the run start is carried for the stale guard');

	# A model call that dies is a skip with its reason, never a pass.
	my $died = Ux->assemble_report($notes, $attempts,
		model => 'test-model', limit => 3,
		model_call => sub { die "connect: Connection refused\n" });
	is($died->{'notes'}->[0]->{'overall'}, 'skip', 'a dead model call leaves the note at skip');
	like($died->{'notes'}->[0]->{'verdicts'}->{'works'}->{'evidence'},
		qr/Connection refused/, 'the skip quotes the failure');

	my $prose = Ux->assemble_report($notes, $attempts,
		model => 'test-model', limit => 3,
		model_call => sub { return ('I think it was fine.', undef) });
	is($prose->{'notes'}->[0]->{'overall'}, 'skip', 'a non-JSON answer is a skip');

	my $bare = Ux->assemble_report($notes, [], limit => 3, ui => 1, booted => 1);
	is($bare->{'notes'}->[0]->{'overall'}, 'skip', 'no model is skip');
	is($bare->{'notes'}->[0]->{'attempt'}->{'stuck'}, 'no attempt was recorded',
		'the missing attempt says why');
}

# --- the runner loads the app and reports to the panel ------------------------
{
	my $run = read_file("$qa/ux/run");
	unlike($run, qr{require\s+"?\$repo/lib/JawnOS/Domain/Ai2\.pm},
		'the UX run no longer requires Ai2 behind the domain loader');
	like($run, qr{require\s+'\./perl/subroutines\.pl'},
		'it loads the app so every subs:: helper exists');
	like($run, qr{chdir\(\$repo\)}, 'it chdirs to the tree for the relative perl requires');
	like($run, qr{\\&subs::evaluation_model_call}, 'it injects the app model call');
	like($run, qr{raw\.json}, 'the fenced child hands raw.json to the parent');
	like($run, qr{Ux->assemble_report\(}, 'the parent assembles the judgement');
	like($run, qr{JAWNOS_QA_UX_CHILD}, 'the child knows when its work ends at raw.json');
	my $finish_at = index($run, 'sub finish_phase');
	my $model_at = index($run, 'evaluation_model_call');
	ok($finish_at >= 0 && $model_at > $finish_at,
		'the model call lives in the parent half, not the fenced child');
	like($run, qr{Ux->handbook_report\(},
		'the handbook post asks whether the report is this run\'s');
	like($run, qr{status => \$status, started => \$started},
		'the child status and the parent start go to the guard');
	like($run, qr{qa_report\.pl}, 'the night writes a panel report');
	like($run, qr{'--kind=ux'}, 'the panel kind is ux');
	like($run, qr{'--schedule=nightly'}, 'the panel schedule is nightly');
	like($run, qr{'--status='}, 'the panel gets a status');
	like($run, qr{'--table=Notes:'}, 'the note table is attached');
	like($run, qr{status => 'failed'},
		'a child that died still publishes a failed night');
}

done_testing();
