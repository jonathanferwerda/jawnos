# tests-for: lib/JawnOS/Domain/Coding.pm lib/JawnOS/Domain/Misc.pm perl/gb/03_engines_and_tools.pl perl/help.pl
# covers:    the Coding agent's live answer (the on_delta sink) and the `agent`
#           action: a bounded child loop with read/write scope, its own small
#           toolset, and a record the parent step carries.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use Test::More;

my $root = "$FindBin::Bin/..";

require JawnOS::Domain::Coding;
require JawnOS::Domain::Misc;

sub source {
	my ($rel) = @_;
	return read_file("$root/$rel");
}

sub put {
	my ($path, $text) = @_;
	open(my $fh, '>', $path) or die "open $path: $!";
	print $fh $text;
	close $fh;
}

# --- the pure child rules ----------------------------------------------------
{
	# the guard resolves symlinks, so it needs a repository to resolve against
	no warnings 'redefine';
	local *subs::coding_repo = sub { $root };
ok(&subs::coding_child_write_ok('lib/JawnOS/Domain/Coding.pm', ['lib/JawnOS/Domain']),
	'a write under an allowed directory is allowed');
ok(&subs::coding_child_write_ok('lib/JawnOS/Domain/Coding.pm', ['lib/JawnOS/Domain/Coding.pm']),
	'an exact allowed file is allowed');
ok(!&subs::coding_child_write_ok('lib/JawnOS/Manager/Part29.pm', ['lib/JawnOS/Domain']),
	'a sibling path is refused');
ok(!&subs::coding_child_write_ok('.git/config', ['.']),
	'the git store is refused even under a root scope');
ok(!&subs::coding_child_write_ok('VERSION', ['.']),
	'VERSION is refused even under a root scope');
ok(!&subs::coding_child_write_ok('database/jawnos.db', ['database']),
	'the database is refused even when its directory is allowed');
ok(!&subs::coding_child_write_ok('releases/jawn.apk', ['releases']),
	'staged releases are refused');
ok(!&subs::coding_child_write_ok('desktop/mkosi/x.conf', ['desktop']),
	'the image build is refused');
ok(!&subs::coding_child_write_ok('.secrets/ssh.txt', ['.']),
	'the key store is refused even under a root scope');
ok(!&subs::coding_child_write_ok('config.json', ['.']),
	'the machine config is refused even under a root scope');
ok(!&subs::coding_child_write_ok('.shots/ticket.txt', ['.']),
	'the live ticket is refused even under a root scope');
ok(&subs::coding_child_write_ok('.shots/notes.md', ['.']),
	'the rest of the scratch folder may be written');
ok(!&subs::coding_child_write_ok("lib/a\x00b", ['.']),
	'a control character is refused');
is(&subs::coding_child_norm_path('./'), '.', 'a scope written ./ means the repo root');
is(&subs::coding_child_norm_path('/'), '.', 'and so does a bare slash');
is(&subs::coding_child_norm_path(''), '', 'an empty scope stays empty, not everything');

ok(&subs::coding_child_allowed('list'), 'a child may list');
ok(&subs::coding_child_allowed('read'), 'a child may read');
ok(&subs::coding_child_allowed('run'), 'a child may run a checked command');
ok(!&subs::coding_child_allowed('write'), 'write needs the scope check, not the bare vocabulary');
ok(!&subs::coding_child_allowed('bump'), 'a child may not bump');
ok(!&subs::coding_child_allowed('commit'), 'a child may not commit');
ok(!&subs::coding_child_allowed('push'), 'a child may not push');
ok(!&subs::coding_child_allowed('restart'), 'a child may not restart');
ok(!&subs::coding_child_allowed('agent'), 'a child may not start another child');

ok(&subs::coding_child_run_ok('perl -c perl/Manager.pl'), 'a compile check is allowed');
ok(&subs::coding_child_run_ok('perl scripts/tests_for.pl --files lib/x.pm'), 'a test helper is allowed');
ok(!&subs::coding_child_run_ok('perl scripts/restart.pl --reason x'), 'a restart is refused');
ok(!&subs::coding_child_run_ok('perl scripts/manager_killer.pl'), 'the killer is refused');
ok(!&subs::coding_child_run_ok('git commit -m x'), 'a commit is refused');
ok(!&subs::coding_child_run_ok('git push'), 'a push is refused');

is(&subs::coding_unwrap_final(q({"action":"done","text":"the answer"})), 'the answer',
	'a final that is an action object is unwrapped');
is(&subs::coding_unwrap_final(q({"action":"done","text":"{\"action\":\"done\",\"text\":\"nested\"}"})), 'nested',
	'a nested action is unwrapped twice');
is(&subs::coding_unwrap_final('  plain prose  '), 'plain prose', 'prose is trimmed, not changed');
is(&subs::coding_unwrap_final(undef), '', 'an empty final stays empty');

ok(&subs::coding_child_limit_ok(0, 9, 10), 'the parent may start a child before the cap');
ok(!&subs::coding_child_limit_ok(0, 10, 10), 'a child at the cap is refused');
ok(!&subs::coding_child_limit_ok(0, 2, 2), 'a child at a lower cap is refused');
ok(!&subs::coding_child_limit_ok(0, 0, 0), 'a max of 0 refuses every child');
ok(!&subs::coding_child_limit_ok(1, 0, 10), 'a child at depth 1 may not start one');
}

# A symlink is not the folder it is named after.
{
	my $root = tempdir(CLEANUP => 1);
	my $outside = tempdir(CLEANUP => 1);
	mkdir "$root/lib" or die 'mkdir lib';
	symlink($outside, "$root/lib/out") or die 'symlink out';
	symlink("$root/lib", "$root/alias") or die 'symlink alias';
	no warnings 'redefine';
	local *subs::coding_repo = sub { $root };
	ok(!&subs::coding_child_write_ok('lib/out/evil.txt', ['lib']),
		'a symlink out of the repo is not a write under an allowed folder');
	ok(&subs::coding_child_write_ok('lib/fine.txt', ['lib']),
		'a real path under the allowed folder is still allowed');
	ok(!defined &subs::coding_path('lib/out/evil.txt'),
		'the repo guard refuses a path a symlink takes outside');
	ok(defined &subs::coding_path('lib/fine.txt'),
		'and still allows a real path inside');
	like(&subs::coding_child_batch_clash([
		{ task => 'a', scope => 'write', paths => ['lib'] },
		{ task => 'b', scope => 'write', paths => ['alias'] },
	]), qr/may both write/, 'two names for one folder clash');
	# the path handed to the writer is the one that was checked, not the alias
	my $handed = &subs::coding_path('alias/fine.txt');
	is($handed, &subs::coding_real_path("$root/lib/fine.txt"),
		'the path handed back is the resolved one, so a swap cannot redirect the write');
}

# The write itself: whole, and never through a symlink.
{
	my $dir = tempdir(CLEANUP => 1);
	my $outside = tempdir(CLEANUP => 1);
	is(&subs::coding_write_file("$dir/a.txt", "one\ntwo\n"), '', 'a plain write succeeds');
	is(read_file("$dir/a.txt"), "one\ntwo\n", 'and the content lands whole');
	my @temps = glob("$dir/a.txt.jawn-tmp-*");
	is(scalar @temps, 0, 'no temp file is left behind');
	is(&subs::coding_write_file("$dir/new/deep/b.txt", "x\n"), '', 'a missing folder is made');
	ok(-f "$dir/new/deep/b.txt", 'and the file is written');
	put("$outside/target.txt", "outside\n");
	symlink("$outside/target.txt", "$dir/link.txt") or die 'symlink target';
	like(&subs::coding_write_file("$dir/link.txt", "evil\n"), qr/symlink/,
		'a symlink is refused, not followed');
	is(read_file("$outside/target.txt"), "outside\n", 'and the file outside is untouched');
	# rewriting an executable must not hand it the plain file mode
	put("$dir/run.sh", "#!/bin/sh\n");
	chmod 0755, "$dir/run.sh";
	is(&subs::coding_write_file("$dir/run.sh", "#!/bin/sh\necho hi\n"), '', 'an existing file is rewritten');
	is((stat("$dir/run.sh"))[2] & 07777, 0755, 'and keeps its permissions');
}

# --- the configured subagent cap --------------------------------------------
{
	my $value;
	no warnings 'redefine';
	local *subs::setting_grabber = sub { $value };
	$value = undef;
	is(&subs::coding_child_max_setting(), 10, 'a missing setting falls back to ten');
	$value = '10';
	is(&subs::coding_child_max_setting(), 10, 'a setting of ten is ten');
	$value = '0';
	is(&subs::coding_child_max_setting(), 0, 'a setting of zero turns subagents off');
	$value = '99';
	is(&subs::coding_child_max_setting(), 10, 'anything above ten is capped at ten');
	$value = 'x';
	is(&subs::coding_child_max_setting(), 10, 'a non-numeric setting falls back to ten');
}

# --- the run loop, with the model and the tools stubbed ----------------------
{
	package FakeJob;
	sub new { bless { id => 999, done => 0, error => '', result => undef }, shift }
	sub id { $_[0]->{'id'} }
	sub finish { $_[0]->{'done'} = 1; $_[0]->{'result'} = $_[1]; 1 }
	sub fail { $_[0]->{'done'} = 1; $_[0]->{'error'} = $_[1]; 1 }
}

sub run_fake_job {
	my ($responder, $execute, $subagent_max) = @_;
	$subagent_max = '2' unless defined $subagent_max;
	my %state;
	my @snapshots;
	my @executed;
	my $calls = 0;
	my $saw_sink = 0;
	my $clock = 1000;
	my $job = FakeJob->new;
	{
		no warnings 'redefine';
		local *subs::rightNow = sub { $clock += 1000 };
		local *subs::setting_grabber = sub {
			my ($arg) = @_;
			return $subagent_max if ref $arg eq 'HASH' && ($arg->{'setting'} // '') eq 'coding_subagents';
			return 'fake-model';
		};
		local *subs::ai_role_thinking_effective = sub { '' };
		local *subs::ai_chat_parts_with_fallback = sub {
			my ($model, $fallback, $messages, $thinking, $role, $opt) = @_;
			$calls++;
			if (ref $opt eq 'HASH' && ref $opt->{'on_delta'} eq 'CODE') {
				$saw_sink = 1;
				$opt->{'on_delta'}->('reasoning', 'considering ');
				$opt->{'on_delta'}->('text', 'the answer');
			}
			my ($text, $err) = $responder->($calls);
			return (undef, $err) if $err;
			return ([ { type => 'reasoning', text => "why $calls" },
			          { type => 'text', text => $text } ], undef);
		};
		local *subs::ai_parts_text = sub {
			my ($parts, $type) = @_;
			$type = 'text' unless defined $type && length $type;
			return join '', map { $_->{'text'} } grep { ($_->{'type'} // '') eq $type } @{ $parts || [] };
		};
		local *subs::coding_run_state_save = sub {
			my ($id, $st) = @_;
			$state{$id} = $st;
			push @snapshots, {
				%$st,
				current => (ref $st->{'current'} eq 'HASH' ? { %{$st->{'current'}} } : $st->{'current'}),
			};
			1;
		};
		local *subs::coding_run_state_load = sub { $state{ $_[0] } || {} };
		local *subs::coding_run_push = sub { 1 };
		local *subs::coding_review_setting = sub { 0 };
		local *subs::jawn_version = sub { '9.9.9' };
		local *Manager::coding_conversation_load = sub { [] };
		local *Manager::coding_conversation_save = sub { 1 };
		local *Manager::coding_system_prompt = sub { 'system' };
		local *Manager::coding_execute = sub {
			my ($c, $action) = @_;
			push @executed, $action->{'action'} // '';
			return $execute ? $execute->(@_) : 'ok';
		};
		local *Manager::agent_registry_note = sub { { title => 'A title' } };
		&subs::coding_run_job($job, { task => 'do it', conversation => 'selftest' });
	}
	return ( $state{999} || {}, $job, $calls, \@executed, \@snapshots, $saw_sink );
}

# A parent hands one read to a child, the child finishes, and the parent ships.
{
	my ($state, $job, $calls, $executed, $snapshots, $saw_sink) = run_fake_job(sub {
		my $n = shift;
		return ('{"action":"agent","task":"find the cursor","scope":"read","paths":[]}', undef) if $n == 1;
		return ('{"action":"read","path":"lib/JawnOS/Domain/Coding.pm"}', undef) if $n == 2;
		return ('{"action":"done","text":"the cursor is in sync_cursors"}', undef) if $n == 3;
		return ('{"action":"done","text":"parent finished"}', undef);
	});
	is($calls, 4, 'the parent and the child each take their turns');
	ok($saw_sink, 'the parent passes an on_delta sink to the model');
	is($state->{'state'}, 'finished', 'the parent run finishes');
	is($state->{'final'}, 'parent finished', 'the parent keeps its own last word');
	is($state->{'children'}, 1, 'one child is counted on the run');
	is(scalar @{ $state->{'steps'} || [] }, 2, 'the agent step and the parent done step are recorded');
	is($state->{'steps'}[0]{'action'}{'action'}, 'agent', 'the first parent step is the agent action');
	like($state->{'steps'}[0]{'observation'}, qr/^subagent:/, 'the observation names the subagent');
	my $child = $state->{'steps'}[0]{'subagent'};
	ok(ref $child eq 'HASH', 'the parent step carries the child record');
	is($child->{'task'}, 'find the cursor', 'the child record keeps its task');
	is($child->{'scope'}, 'read', 'the scope defaults to read');
	is(scalar @{ $child->{'steps'} || [] }, 1, 'the child records the one read it did');
	is($child->{'steps'}[0]{'action'}{'action'}, 'read', 'the child step is the read');
	is($child->{'final'}, 'the cursor is in sync_cursors', 'the child final reaches the record');
	is_deeply($executed, [ 'read', 'done' ], 'the parent never sends agent to the toolset');
	ok($job->{'done'} && !$job->{'error'}, 'the Minion job is finished');

	my ($live) = grep { ref $_->{'current'} eq 'HASH' && length($_->{'current'}{'live_text'} // '') } @$snapshots;
	ok($live, 'a live snapshot reaches the panel while the model writes');
	is($live->{'current'}{'live_text'}, 'the answer', 'the live text is what the sink saw');
	is($live->{'current'}{'live_reasoning'}, 'considering ', 'the live reasoning is kept beside it');
	is($live->{'current'}{'state'}, 'thinking', 'the live line is a thinking state');
}

# A read-scope child that tries to write is refused, and the toolset never sees
# the write; the parent still finishes.
{
	my ($state, $job, $calls, $executed) = run_fake_job(sub {
		my $n = shift;
		return ('{"action":"agent","task":"edit it","scope":"read","paths":["lib/JawnOS/Domain"]}', undef) if $n == 1;
		return ('{"action":"write","path":"lib/JawnOS/Domain/Coding.pm","content":"x"}', undef) if $n == 2;
		return ('{"action":"done","text":"could not write"}', undef) if $n == 3;
		return ('{"action":"done","text":"parent done"}', undef);
	});
	my $child = $state->{'steps'}[0]{'subagent'};
	is(scalar @{ $child->{'steps'} || [] }, 1, 'the refused write is still a child step');
	like($child->{'steps'}[0]{'observation'}, qr/^refused:/, 'the child is told the write was refused');
	ok(!grep({ $_ eq 'write' } @$executed), 'the toolset never ran the refused write');
	is($state->{'state'}, 'finished', 'a refused child write does not fail the parent');
	is($state->{'final'}, 'parent done', 'the parent finishes its own run');
}

# The third child in one run is refused, and the parent is told why.
{
	my ($state, $job) = run_fake_job(sub {
		my $n = shift;
		return ('{"action":"agent","task":"one","scope":"read"}', undef) if $n == 1;
		return ('{"action":"done","text":"one done"}', undef) if $n == 2;
		return ('{"action":"agent","task":"two","scope":"read"}', undef) if $n == 3;
		return ('{"action":"done","text":"two done"}', undef) if $n == 4;
		return ('{"action":"agent","task":"three","scope":"read"}', undef) if $n == 5;
		return ('{"action":"done","text":"parent done"}', undef);
	});
	is($state->{'children'}, 2, 'two children are counted, the third is not');
	like($state->{'steps'}[2]{'observation'}, qr/^subagent failed: .*2 subagents/,
		'the refused third child says the run has used its two');
	is($state->{'state'}, 'finished', 'the parent continues after a refused child');
}

# A setting of zero refuses the agent action outright, and the parent continues.
{
	my ($state, $job) = run_fake_job(sub {
		my $n = shift;
		return ('{"action":"agent","task":"one","scope":"read"}', undef) if $n == 1;
		return ('{"action":"done","text":"parent done"}', undef);
	}, undef, '0');
	ok(!($state->{'children'} // 0), 'no child is counted when subagents are off');
	like($state->{'steps'}[0]{'observation'}, qr/^subagent failed: .*0 subagents/,
		'the refused child says subagents are off');
	is($state->{'state'}, 'finished', 'the parent continues with subagents off');
	is($state->{'final'}, 'parent done', 'the parent still finishes its run');
}

# --- one action may ask for several subagents --------------------------------
{
	my @one = &subs::coding_action_tasks({ action => 'agent', task => 'read it', scope => 'write', paths => ['lib'] });
	is(scalar @one, 1, 'a single task is one task');
	is($one[0]{'scope'}, 'write', 'the single task keeps its scope');

	my @many = &subs::coding_action_tasks({ action => 'agent', tasks => [
		{ task => 'a', scope => 'read' },
		'not an object',
		{ task => 'b', scope => 'read' },
	] });
	is(scalar @many, 2, 'a tasks list drops entries that are not objects');
	is($many[1]{'task'}, 'b', 'the list keeps the order it was asked for');

	is(scalar(&subs::coding_action_tasks({ action => 'agent' })), 0, 'no task is no task');
	is(scalar(&subs::coding_action_tasks({ action => 'agent', tasks => [], task => 'fallback' })), 1,
		'an empty list falls back to the single task');
}

# Two write-scope tasks may not share paths; read-only children may overlap.
{
	no warnings 'redefine';
	local *subs::coding_repo = sub { $root };
	like(&subs::coding_child_batch_clash(
		[ { task => 'a', scope => 'write', paths => ['lib/JawnOS'] },
		  { task => 'b', scope => 'write', paths => ['lib/JawnOS/Domain'] } ]),
		qr/may both write/, 'a nested write scope clashes with its parent');
	is(&subs::coding_child_batch_clash(
		[ { task => 'a', scope => 'write', paths => ['lib/JawnOS'] },
		  { task => 'b', scope => 'write', paths => ['public/js'] } ]),
		'', 'two separate write scopes do not clash');
	is(&subs::coding_child_batch_clash(
		[ { task => 'a', scope => 'read', paths => ['lib'] },
		  { task => 'b', scope => 'read', paths => ['lib'] } ]),
		'', 'read-only tasks may read the same paths at once');
	like(&subs::coding_child_batch_clash(
		[ { task => 'a', scope => 'write', paths => ['.'] },
		  { task => 'b', scope => 'write', paths => ['lib'] } ]),
		qr/may both write/, 'a root write scope clashes with anything');

	# the refusal names the tasks by their place in the list the model sent,
	# not by their place among the writers
	like(&subs::coding_child_batch_clash([
		{ task => 'read it', scope => 'read' },
		{ task => 'one', scope => 'write', paths => ['lib'] },
		{ task => 'two', scope => 'write', paths => ['lib/JawnOS'] },
	]), qr/tasks 2 and 3/, 'the refusal counts every task, not only the writers');
}

# A cancelled run stops the batch it is waiting on, and every task still gets
# an answer the parent can record.
{
	no warnings 'redefine';
	local *subs::coding_run_subagent = sub {
		select(undef, undef, undef, 1);
		return { task => 'x', scope => 'read', paths => [], steps => [], touched => [] };
	};
	local *subs::coding_run_state_load = sub { { cancel => 1 } };
	my $out = &subs::coding_run_subagents(
		[ { task => 'a', scope => 'read' }, { task => 'b', scope => 'read' } ],
		{ run => 5, model => 'm' }
	);
	is($out->{'stopped'}, 'cancelled', 'a cancelled run stops the batch');
	is(scalar @{ $out->{'records'} }, 2, 'every task still gets a record');
	like($out->{'records'}[0]{'error'} // '', qr/cancelled/, 'and is told the run stopped');
}

# A fork per task: the children run in their own processes, come back in the
# order asked for, and a child's write is the parent's to commit.
{
	my $dir = tempdir(CLEANUP => 1);
	my $pid_log = "$dir/pids";
	my %state;
	my @snaps;
	my @executed;
	my %commit_touched;
	my $parent_calls = 0;
	my $job = FakeJob->new;
	local $ENV{'SUBPID_LOG'} = $pid_log;
	{
		no warnings 'redefine';
		local *subs::coding_repo = sub { $root };
		local *subs::rightNow = sub { 1000 };
		local *subs::setting_grabber = sub {
			my ($arg) = @_;
			return '9' if ref $arg eq 'HASH' && ($arg->{'setting'} // '') eq 'coding_subagents';
			return 'fake-model';
		};
		local *subs::ai_role_thinking_effective = sub { '' };
		local *subs::ai_chat_parts_with_fallback = sub {
			my ($model, $fallback, $messages, $thinking, $role, $opt) = @_;
			my $prompt = ($messages && @$messages) ? ($messages->[-1]{'content'} // '') : '';
			if ($prompt =~ /SUBAGENT TASK:/) {
				# a child: say which process it is, write once, then finish
				if (open(my $fh, '>>', $ENV{'SUBPID_LOG'})) { print $fh "$$\n"; close $fh; }
				my $text = $prompt =~ /OBSERVATION:/
					? '{"action":"done","text":"child done"}'
					: '{"action":"write","path":"docs/kid.md","content":"x"}';
				return ([ { type => 'text', text => $text } ], undef);
			}
			$parent_calls++;
			my $text = $parent_calls == 1
				? '{"action":"agent","tasks":[{"task":"one","scope":"write","paths":["docs"]},{"task":"two","scope":"read"}]}'
				: $parent_calls == 2
				? '{"action":"commit","message":"kid work"}'
				: '{"action":"done","text":"parent done"}';
			return ([ { type => 'text', text => $text } ], undef);
		};
		local *subs::ai_parts_text = sub {
			my ($parts, $type) = @_;
			$type = 'text' unless defined $type && length $type;
			return join '', map { $_->{'text'} } grep { ($_->{'type'} // '') eq $type } @{ $parts || [] };
		};
		local *subs::coding_run_state_save = sub {
			$state{ $_[0] } = $_[1];
			push @snaps, {
				children => $_[1]{'children'},
				current  => (ref $_[1]{'current'} eq 'HASH' ? { %{ $_[1]{'current'} } } : $_[1]{'current'}),
			};
			1;
		};
		local *subs::coding_run_state_load = sub { $state{ $_[0] } || {} };
		local *subs::coding_run_push = sub { 1 };
		local *subs::coding_review_setting = sub { 0 };
		local *subs::jawn_version = sub { '9.9.9' };
		local *Manager::coding_conversation_load = sub { [] };
		local *Manager::coding_conversation_save = sub { 1 };
		local *Manager::coding_system_prompt = sub { 'system' };
		local *Manager::coding_execute = sub {
			my ($c, $action, $touched) = @_;
			$touched->{ $action->{'path'} } = 1 if ($action->{'action'} // '') eq 'write' && defined $action->{'path'};
			%commit_touched = %{ $touched || {} } if ($action->{'action'} // '') eq 'commit';
			push @executed, $action->{'action'} // '';
			return 'ok';
		};
		local *Manager::agent_registry_note = sub { { title => 'A title' } };
		&subs::coding_run_job($job, { task => 'do it', conversation => 'selftest' });
	}

	is($state{999}{'children'}, 2, 'both tasks are counted on the run');
	is(scalar @{ $state{999}{'steps'} || [] }, 4, 'each child is a step, then the commit and the done');
	is($state{999}{'steps'}[0]{'subagent'}{'task'}, 'one', 'the first record is the first task');
	is($state{999}{'steps'}[1]{'subagent'}{'task'}, 'two', 'the second record is the second task');
	like($state{999}{'steps'}[0]{'observation'}, qr/^subagent: child done/, 'a child answer reads as before');
	my @pids = -f $pid_log ? do { open(my $fh, '<', $pid_log); grep { /^\d+$/ } <$fh> } : ();
	ok(scalar @pids >= 2, 'the children asked the model');
	is(scalar(keys %{ +{ map { $_ => 1 } @pids } }), 2, 'and they asked from two different processes');
	is_deeply([ sort keys %commit_touched ], [ 'docs/kid.md' ],
		"a subagent's write reaches the parent's commit");
	# the panel is told the batch is running, and how far it has got
	my @prog = grep { ref $_->{'current'} eq 'HASH' && ($_->{'current'}{'state'} // '') eq 'subagents' } @snaps;
	ok(scalar @prog, 'a batch is shown as subagents working');
	is($prog[0]{'current'}{'total'}, 2, 'with the size of the batch');
	is($prog[0]{'current'}{'done'}, 0, 'starting at none done');
	my @done = map { $_->{'current'}{'done'} } @prog;
	ok(scalar(grep { $_ >= 1 } @done), 'and counts a child as it finishes');
	is((sort { $a <=> $b } @done)[-1], 2, 'until the batch is complete');
	# each finished child is named while the others still run
	my @kids = map { @{ $_->{'current'}{'children'} || [] } } grep {
		ref $_->{'current'} eq 'HASH' && ($_->{'current'}{'state'} // '') eq 'subagents'
	} @snaps;
	ok(scalar @kids, 'a finished child is listed while the batch runs');
	is($kids[0]{'ok'}, 1, 'a child that answered is shown as done');
	like($kids[0]{'said'}, qr/child done/, 'with what it said');
}

# A batch whose write scopes overlap is refused whole, and the run continues.
{
	my %state;
	my $calls = 0;
	my $job = FakeJob->new;
	{
		no warnings 'redefine';
		local *subs::coding_repo = sub { $root };
		local *subs::rightNow = sub { 1000 };
		local *subs::setting_grabber = sub {
			my ($arg) = @_;
			return '9' if ref $arg eq 'HASH' && ($arg->{'setting'} // '') eq 'coding_subagents';
			return 'fake-model';
		};
		local *subs::ai_role_thinking_effective = sub { '' };
		local *subs::ai_chat_parts_with_fallback = sub {
			$calls++;
			my $text = $calls == 1
				? '{"action":"agent","tasks":[{"task":"a","scope":"write","paths":["lib/JawnOS"]},{"task":"b","scope":"write","paths":["lib/JawnOS/Domain"]}]}'
				: '{"action":"done","text":"parent done"}';
			return ([ { type => 'text', text => $text } ], undef);
		};
		local *subs::ai_parts_text = sub {
			my ($parts, $type) = @_;
			$type = 'text' unless defined $type && length $type;
			return join '', map { $_->{'text'} } grep { ($_->{'type'} // '') eq $type } @{ $parts || [] };
		};
		local *subs::coding_run_state_save = sub { $state{ $_[0] } = $_[1]; 1 };
		local *subs::coding_run_state_load = sub { $state{ $_[0] } || {} };
		local *subs::coding_run_push = sub { 1 };
		local *subs::coding_review_setting = sub { 0 };
		local *subs::jawn_version = sub { '9.9.9' };
		local *Manager::coding_conversation_load = sub { [] };
		local *Manager::coding_conversation_save = sub { 1 };
		local *Manager::coding_system_prompt = sub { 'system' };
		local *Manager::coding_execute = sub { 'ok' };
		local *Manager::agent_registry_note = sub { { title => 'A title' } };
		&subs::coding_run_job($job, { task => 'do it', conversation => 'selftest' });
	}
	is($calls, 2, 'an overlapping batch never reaches the model');
	ok(!($state{999}{'children'} // 0), 'and no child is counted');
	like($state{999}{'steps'}[0]{'observation'}, qr/may both write/, 'the refusal names the clash');
	is($state{999}{'state'}, 'finished', 'the parent continues after the refusal');
}

# The view says how much of the subagent budget the run has used, so a panel can
# show it without reading the saved state itself.
{
	no warnings 'redefine';
	local *subs::coding_run_state_load = sub { { state => 'active', children => 3 } };
	local *subs::coding_worker_alive = sub { 1 };
	local *subs::coding_minion = sub { undef };
	my $view = &subs::coding_run_view(11);
	is($view->{'children'}, 3, 'the view says how many subagents the run has used');
}

# --- patch: exact, unique, and small ----------------------------------------
{
	my ($out, $line, $count) = &subs::coding_patch_text("a\nb\nc\n", 'b', 'B');
	is($out, "a\nB\nc\n", 'an exact block is replaced');
	is($line, 2, 'and the line is reported');
	is($count, 1, 'with one match');

	my (undef, undef, undef, $why) = &subs::coding_patch_text("a\n", 'z', 'y');
	like($why, qr/no match/, 'a missing block is refused');

	my ($many, undef, $n) = &subs::coding_patch_text("x\ny\nx\n", 'x', 'z', 1);
	is($many, "z\ny\nz\n", 'all replaces every match');
	is($n, 2, 'and says how many');

	(undef, undef, undef, $why) = &subs::coding_patch_text("x\ny\nx\n", 'x', 'z');
	like($why, qr/ambiguous/, 'a repeated block is ambiguous without all');

	(undef, undef, undef, $why) = &subs::coding_patch_text("a\n", 'a', 'a');
	like($why, qr/identical/, 'an unchanged patch is refused');

	my ($literal) = &subs::coding_patch_text("a\n", 'a', '$x\\1');
	is($literal, "\$x\\1\n", 'the replacement is literal, not interpolated');
	my ($meta) = &subs::coding_patch_text("a+b\n", 'a+b', 'a-b');
	is($meta, "a-b\n", 'the old block is literal, not a pattern');
}

# --- a read can be one range ------------------------------------------------
{
	is(&subs::coding_read_range("a\nb\nc\nd\n", 2, 2), "b\nc", 'a range reads only those lines');
	is(&subs::coding_read_range("a\nb\n", 2, 99), 'b', 'a short file stops at its end');
	is(&subs::coding_read_range("a\nb\n", 9, 2), 'no such range', 'past the end is refused');
}

# --- the prompt and the tool list -------------------------------------------
my $tools = source('perl/gb/03_engines_and_tools.pl');
like($tools, qr/name => 'agent'/, 'the Coding tool list offers agent');
like($tools, qr/"action":"agent"/, 'the agent entry has an example');
like($tools, qr/scope.*read|read.*scope/s, 'the agent entry names the read scope');
like($tools, qr/scope.*write|write.*scope/s, 'the agent entry names the write scope');
like($tools, qr/cannot ship/, 'the agent entry says it cannot ship');
like($tools, qr/"tasks"/, 'the agent entry offers the batch form');
like($tools, qr/at the same time/, 'the agent entry says a batch runs at once');
like($tools, qr/name => 'patch'/, 'the Coding tool list offers patch');
like($tools, qr/"offset"\s*:\s*10/, 'the read entry shows a range example');

my $help = source('perl/help.pl');
like($help, qr/Use agent for a self-contained investigation or a scoped edit/,
	'the coding prompt tells the agent when to use a subagent');
like($help, qr/Never ask a subagent to spawn/, 'the coding prompt forbids nesting');
like($help, qr/they run at the same\s+time/, 'the coding prompt says a batch runs at once');
like($help, qr/Prefer patch to write/, 'the coding prompt tells the agent to prefer patch');

done_testing();
